-- | HaskDB.Executor.Operators (design/08 §8.1-8.10; internal-design/09
--   §9.1-9.5): the volcano operators, the two-phase DML operators and the
--   DDL operators.  Deviations from the docs (also in TODO.md):
--   * state cells are IORef handles: 'openPlan' returns the root cell and
--     'nextRow'/'closePlan' take a handle, because 'ExecData' is a pure
--     record and cursors must advance in place (the docs' `next :: ExecState
--     -> IO ...` signature implies the same mutation);
--   * 'ExecState' keeps 'esPlan' so a NestedLoop inner can be closed and
--     re-opened without a plan stack;
--   * SeqScan loads ONE heap page per call through the buffer pool and takes
--     the LS row lock per returned tuple: the heap layer's `heapScan`
--     materialises the whole relation and is lock-free at the storage level;
--   * IndexScan materialises the whole match list at open (the docs' pinned
--     leaf cursor is an optimisation); the 'IBRange' inclusivity flags are
--     mapped onto the Phase-4 `btreeRange` window, which is [lo, hi): an
--     inclusive lower bound keeps the boundary, an exclusive lower bound
--     drops it, an inclusive upper bound is added with a point search and
--     the RID list is deduplicated — the lower-bound exclusion is applied
--     to the re-added boundary rows too (so `age > 5 and age <= 5` is
--     empty, review fix); heapFetch locks every hit at open and 'queueNext'
--     re-books S per row (S2PL re-grant, no downgrade), TODO.md note;
--   * HashAggregate drains its child and groups the collected rows (the
--     docs' streaming accumulators are memory-equivalent: the input is
--     materialised either way); the drained rows are charged then released
--     at open and the FINALISED group rows stay charged until close (D-08
--     covers hash tables, so the live table must be in the budget);
--   * DML operators run at OPEN (the §9.5 collect-then-modify phases) and
--     keep the affected count in the 'DModify' cell, which the statement
--     layer reports; their collected lists are charged then released;
--   * heap pages newly allocated during INSERT are staged into the catalog
--     relpages list by walking the heap chain after the fact (the heap layer
--     logs the PAllocPage WAL record but never touches the cache, Phase-4);
--   * index roots are tracked in a per-operator cell and published with ONE
--     'updateIndexRoot' call per index whose root changed (Phase-4 in-session
--     cache staleness); `btreeDelete` returns no root so shrinking is not
--     tracked;
--   * the join key equality of a HashJoin is enforced by the hash table key,
--     so 'jsResidual' stays 'Nothing' from the planner; residual predicates
--     of the other join nodes are applied at emit time;
--   * JoinSides' build/probe keys address each operand's OWN rows (the
--     planner emits the outer side's flat ref, which is also its side-local
--     index, and the inner side's slot column ordinal);
--   * NestedLoop and IndexNestedLoop emit the CONCATENATION outer ++ inner
--     (§8.5 'emit pairs') and the residual is evaluated on that joined row;
--   * Filter passes the child's source RID through (a Modify's child is the
--     WHERE-filter over the scan, §8.8 step 1) — §9.1's "RID only from a
--     base scan" wording refers to nodes that materialise or join;
--   * LIMITATION (Phase-4 cache staging lands at COMMIT): the catalog view
--     this layer reads at every open (relpages/reltuples/index roots) is
--     committed state plus this statement's own staging, so a SECOND
--     statement inside one explicit BEGIN...COMMIT block sees a stale page
--     list / root after an earlier statement of the same transaction grew
--     them; the suite drives one transaction per statement, TODO.md note.
{-# LANGUAGE LambdaCase, TupleSections, BangPatterns #-}
module HaskDB.Executor.Operators where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.List (findIndex, nub, sortBy)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Control.Monad (filterM, foldM, when, forM_, zipWithM)

import HaskDB.Common.Types (Value(..), RID(RID), RelId, PageId, SqlType(..), encodeValue, compareSql)
import HaskDB.Common.Error (SqlError(..), throwSql, errUndefinedTable, errInternal, errAggEmptyInput, errIntOverflow)
import HaskDB.Catalog.Types (RelationDesc(rdColumns, rdPages), IndexDesc(ixRelId, ixColumn, ixRoot))
import HaskDB.Catalog.Cache (lookupById, lookupByName, indexesOf, stageTupleDelta, stageAllocPage)
import HaskDB.Catalog.Bootstrap (createTableDDL, createIndexDDL, updateIndexRoot)
import HaskDB.Heap.TupleCodec (ColumnDesc(..), decodeTuple)
import HaskDB.Storage.BufferPool (withPage)
import HaskDB.Storage.Page (readHeader, PageHeader(phNext), liveSlots, pageReadTuple)
import HaskDB.Heap.Heap (heapInsert, heapUpdate, heapDelete, heapFetch)
import HaskDB.Index.BTree (btreeSearch, btreeRange, btreeInsert, btreeDelete)
import HaskDB.Txn.Manager (lockRow)
import HaskDB.Txn.LockManager (LockMode(LS, LX))
import HaskDB.Server.Env (Env(envBufferPool))
import HaskDB.Sql.Ast (AggFn(AggCount, AggSum, AggAvg, AggMin, AggMax), CreateTableStmt(ctName, ctCols), CreateIndexStmt(ciName, ciTable, ciCol))

import HaskDB.Executor.Types
import HaskDB.Executor.Eval (evalPred)
import HaskDB.Executor.MemoryBudget (rowByteSize, totalRowBytes)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
throwSqlOf :: SqlError -> IO a
throwSqlOf (SqlError st msg) = throwSql st msg

tshow :: (Show a) => a -> Text
tshow = T.pack . show

lookupDesc :: ExecCtx -> RelId -> IO RelationDesc
lookupDesc ec rid = lookupById (ecCatalog ec) rid >>= \case
  Nothing -> throwSqlOf (errInternal ("executor: relation " <> tshow rid <> " is not in the catalog"))
  Just d  -> pure d

newSt :: ExecCtx -> Plan -> ExecData -> [IORef ExecState] -> IO (IORef ExecState)
newSt _ec plan dat kids =
  newIORef ExecState { esPlan = plan, esNode = planNode plan, esChild = kids, esData = dat }

mkModify :: Int64 -> IO ExecData
mkModify n = DModify <$> newIORef n

readModify :: ExecData -> IO Int64
readModify (DModify r) = readIORef r
readModify _           = pure 0

chargeRows :: ExecCtx -> [[Value]] -> IO ()
chargeRows ec = mapM_ (\r -> chargeMem ec (rowByteSize r))

releaseRows :: ExecCtx -> [[Value]] -> IO ()
releaseRows ec = mapM_ (\r -> releaseMem ec (rowByteSize r))

projItem :: ProjItem -> [Value] -> Value
projItem (PJCol i) row = row !! i
projItem (PJLit v) _   = v

-- | INSERT VALUES -> a full schema tuple at the target column ordinals
--   (the planner rejects a partial column list: this dialect has no NULL).
assignTuple :: [ColumnDesc] -> [Int] -> [Value] -> [Value]
assignTuple cols ords vs =
  [ case lookup j (zip ords vs) of
      Just v  -> v
      Nothing -> error "planner invariant: INSERT VALUES must assign every column"
  | j <- [0 .. length cols - 1] ]

rhsOf :: PAssignRhs -> [Value] -> Value
rhsOf (PALit v) _   = v
rhsOf (PACol f) row = row !! f

-- ---------------------------------------------------------------------------
-- Heap page primitives
-- ---------------------------------------------------------------------------
loadHeapPage :: Env -> [ColumnDesc] -> PageId -> IO [(RID, [Value])]
loadHeapPage env cols pg = withPage (envBufferPool env) pg $ \pr -> do
  ss <- liveSlots pr
  mapM (\(s, _, _) -> do
          b <- pageReadTuple pr s
          case decodeTuple cols b of
            Right t -> pure (RID pg s, t)
            Left e  -> throwSql "XX000"
                          ("executor: corrupt tuple in heap page " <> tshow pg
                           <> " slot " <> tshow s <> ": " <> e)) ss

heapChain :: Env -> PageId -> IO [PageId]
heapChain env pg
  | pg == 0     = pure []
  | otherwise = do
      nxt <- withPage (envBufferPool env) pg $ \pr -> phNext <$> readHeader pr
      (pg :) <$> heapChain env nxt

stageNewHeapPages :: ExecCtx -> RelId -> [PageId] -> IO ()
stageNewHeapPages ec relid seed = case seed of
  []      -> pure ()
  (h : _) -> do
    chain <- heapChain (ecEnv ec) h
    mapM_ (\p -> stageAllocPage (ecCatalog ec) (ecTxn ec) relid p)
          [ p | p <- chain, p `notElem` seed ]

-- ---------------------------------------------------------------------------
-- Scan queue (SeqScan pages / IndexScan preloaded hits)
-- ---------------------------------------------------------------------------
queueNext :: ExecCtx -> RelId -> RelationDesc -> ScanCursor
          -> IO (Maybe (Maybe RID, [Value]), ScanCursor)
queueNext ec relid rd cur0 = go cur0
  where
    go cur
      | scSlot cur < length (scHits cur) = do
          let (rid, vals) = scHits cur !! scSlot cur
          lockRow (ecTxn ec) relid rid LS
          pure (Just (Just rid, vals), cur { scSlot = scSlot cur + 1 })
      | otherwise = case scPages cur of
          []         -> pure (Nothing, cur)
          (pg : rest) -> do
            rows <- loadHeapPage (ecEnv ec) (rdColumns rd) pg
            go cur { scPages = rest, scHits = rows, scSlot = 0 }

scanOf :: ExecData -> IO ScanCursor
scanOf (DScan c) = pure c
scanOf _         = throwSqlOf (errInternal "state mismatch: scan cursor")

-- | The whole match list of an IndexScan, computed at open (§9.3).
indexHits :: ExecCtx -> RelId -> RelationDesc -> IndexDesc -> IndexBound
          -> IO [(RID, [Value])]
indexHits ec _relid rd idx bound = do
  let env = ecEnv ec
      cc  = ecCatalog ec
      ixr = ixRelId idx
  rids <- case bound of
    IBEqual v -> btreeSearch env cc ixr v
    IBRange mlo mhi -> do
      pairs <- btreeRange env cc ixr (fmap fst mlo) (fmap fst mhi)
      let inLower (k, _) = case mlo of
            Just (lo, inc) | not inc -> compareSql k lo /= EQ
            _                        -> True
          ps = filter inLower pairs
      extra <- case mhi of
        Just (hi, True) -> map ((,) hi) <$> btreeSearch env cc ixr hi
        _               -> pure []
      pure (nub (map snd (filter inLower (ps ++ extra))))
  fetched <- mapM (\rid -> heapFetch env (ecTxn ec) rd rid >>= \t -> pure ((rid,) <$> t)) rids
  pure [ x | Just x <- fetched ]

-- ---------------------------------------------------------------------------
-- Drain helpers (materialising open phases)
-- ---------------------------------------------------------------------------
drainRows :: ExecCtx -> IORef ExecState -> IO [[Value]]
drainRows ec h = go
  where
    go = nextRow ec h >>= \r -> case r of
      Nothing        -> pure []
      Just (_, vals) -> (vals :) <$> go

drainPairs :: ExecCtx -> IORef ExecState -> IO [(RID, [Value])]
drainPairs ec h = go
  where
    go = nextRow ec h >>= \r -> case r of
      Nothing               -> pure []
      Just (Just rid, vals) -> ((rid, vals) :) <$> go
      Just (Nothing, _)     -> throwSqlOf (errInternal
                             "executor: a modify child must yield the source RID")

-- ---------------------------------------------------------------------------
-- rewind: close + re-open, materialised nodes replay from their row lists
-- ---------------------------------------------------------------------------
rewind :: ExecCtx -> IORef ExecState -> IO (IORef ExecState)
rewind ec h = do
  st <- readIORef h
  case esNode st of
    PMaterialize _ -> do
      d <- case esData st of
             DMat rs _ -> pure (DMat rs 0)
             other     -> pure other
      writeIORef h st { esData = d } >> pure h
    PSort _ _ -> do
      d <- case esData st of
             DSort rs _ -> pure (DSort rs 0)
             other      -> pure other
      writeIORef h st { esData = d } >> pure h
    PHashAggregate _ _ _ -> do
      d <- case esData st of
             DAgg rs _ -> pure (DAgg rs 0)
             other     -> pure other
      writeIORef h st { esData = d } >> pure h
    _ -> closePlan ec h >> openPlan ec (esPlan st)

-- ---------------------------------------------------------------------------
-- open
-- ---------------------------------------------------------------------------
openPlan :: ExecCtx -> Plan -> IO (IORef ExecState)
openPlan ec plan = case planNode plan of
  PSeqScan relid -> do
    rd <- lookupDesc ec relid
    newSt ec plan (DScan ScanCursor { scPages = rdPages rd, scSlot = 0, scHits = [] }) []

  PIndexScan relid idx bound -> do
    rd <- lookupDesc ec relid
    hits <- indexHits ec relid rd idx bound
    newSt ec plan (DScan ScanCursor { scPages = [], scSlot = 0, scHits = hits }) []

  PFilter _ sub -> do
    k <- openPlan ec sub
    newSt ec plan DFilter [k]

  PProject _ sub -> do
    k <- openPlan ec sub
    newSt ec plan DProject [k]

  PNestedLoop outer inner _ -> do
    ko <- openPlan ec outer
    newSt ec plan
      DNL { nlOuter = Nothing, nlInner = Nothing, nlDone = False
          , nlMat = isMatNode inner }
      [ko]

  PIndexNestedLoop outer _relid _idx _key -> do
    ko <- openPlan ec outer
    newSt ec plan DINL { inlOuter = Nothing, inlHits = [] } [ko]

  PHashJoin l r js -> do
    kl <- openPlan ec l
    kr <- openPlan ec r
    let buildLeft = jsBuild js == BuildLeft
    tbl <- buildTable ec (if buildLeft then kl else kr) (jsBuildKey js)
    newSt ec plan DHash { hjTable = Just tbl, hjMatches = [], hjProbeRow = Nothing
                       , hjBuildLeft = buildLeft } [kl, kr]

  PHashAggregate gfr specs sub -> do
    k <- openPlan ec sub
    rows <- drainRows ec k
    chargeRows ec rows
    fin <- finalizeAgg ec gfr specs rows
    releaseRows ec rows
    chargeRows ec fin
    newSt ec plan DAgg { aggRows = fin, aggIx = 0 } [k]

  PSort keys sub -> do
    k <- openPlan ec sub
    rows <- drainRows ec k
    chargeRows ec rows
    newSt ec plan DSort { sortRows = Just (sortRowsBy keys rows), sortIx = 0 } [k]

  PMaterialize sub -> do
    k <- openPlan ec sub
    rows <- drainRows ec k
    chargeRows ec rows
    newSt ec plan DMat { matRows = rows, matIx = 0 } [k]

  PInsert relid ords vals -> do
    n <- runInsert ec relid ords vals
    dat <- mkModify n
    newSt ec plan dat []

  PUpdate relid asgs sub -> do
    k <- openPlan ec sub
    n <- runUpdate ec relid asgs k
    dat <- mkModify n
    newSt ec plan dat [k]

  PDelete relid sub -> do
    k <- openPlan ec sub
    n <- runDelete ec relid k
    dat <- mkModify n
    newSt ec plan dat [k]

  PCreateTable cs -> do
    let cols = [ ColumnDesc n t | (n, t) <- ctCols cs ]
    _ <- createTableDDL (ecEnv ec) (ecCatalog ec) (ecTxn ec) (ctName cs) cols
    dat <- mkModify 1
    newSt ec plan dat []

  PCreateIndex cs -> do
    mtbl <- lookupByName (ecCatalog ec) (ciTable cs)
    case mtbl of
      Nothing -> throwSqlOf (errUndefinedTable (ciTable cs))
      Just tbl ->
        case findIndex (\c -> colName c == ciCol cs) (rdColumns tbl) of
          Nothing -> throwSqlOf (errInternal
                      ("executor: index column " <> ciCol cs <> " not found on " <> ciTable cs))
          Just ord -> do
            _ <- createIndexDDL (ecEnv ec) (ecCatalog ec) (ecTxn ec) (ciName cs) tbl ord
            dat <- mkModify 1
            newSt ec plan dat []
  where
    isMatNode p = case planNode p of
                    PMaterialize _ -> True
                    _              -> False

-- ---------------------------------------------------------------------------
-- nextRow
-- ---------------------------------------------------------------------------
nextRow :: ExecCtx -> IORef ExecState -> IO (Maybe (Maybe RID, [Value]))
nextRow ec h = do
  st <- readIORef h
  (res, dat) <- stepNode ec h st
  writeIORef h st { esData = dat }
  pure res

stepNode :: ExecCtx -> IORef ExecState -> ExecState
         -> IO (Maybe (Maybe RID, [Value]), ExecData)
stepNode ec _h st = case esNode st of
  PSeqScan relid -> do
    rd <- lookupDesc ec relid
    cur <- scanOf (esData st)
    (res, cur') <- queueNext ec relid rd cur
    pure (res, DScan cur')

  PIndexScan relid _idx _bound -> do
    rd <- lookupDesc ec relid
    cur <- scanOf (esData st)
    (res, cur') <- queueNext ec relid rd cur
    pure (res, DScan cur')

  PFilter p _ -> do
    (res, dat) <- filterNext ec p (esChild st !! 0)
    pure (res, dat)

  PProject items _ -> do
    r <- nextRow ec (esChild st !! 0)
    case r of
      Nothing        -> pure (Nothing, DProject)
      Just (_, vals) -> pure (Just (Nothing, map (\it -> projItem it vals) items), DProject)

  PNestedLoop _outerPlan innerPlan residual -> do
    let ko = esChild st !! 0
    (res, o', ih', done', mat') <- case esData st of
      DNL o ih done mat -> nlNext ec ko innerPlan residual (o, ih, done, mat)
      _                 -> throwSqlOf (errInternal "state mismatch: PNestedLoop")
    pure (res, DNL { nlOuter = o', nlInner = ih', nlDone = done', nlMat = mat' })

  PIndexNestedLoop _ relid idx key -> do
    let ko = esChild st !! 0
    rd <- lookupDesc ec relid
    (res, o', hits') <- case esData st of
      DINL o hits -> inlNext ec ko rd idx key (o, hits)
      _           -> throwSqlOf (errInternal "state mismatch: PIndexNestedLoop")
    pure (res, DINL { inlOuter = o', inlHits = hits' })

  PHashJoin _ _ js -> do
    let bl = case esData st of
               DHash _ _ _ x -> x
               _             -> error "state mismatch: PHashJoin"
        probeH = esChild st !! (if bl then 1 else 0)
    (res, dat) <- hjNext ec js probeH (esData st)
    pure (res, dat)

  PHashAggregate _ _ _ -> do
    (rs, i) <- case esData st of
      DAgg rs i -> pure (rs, i)
      _         -> throwSqlOf (errInternal "state mismatch: PHashAggregate")
    pure (rowAt rs i, DAgg { aggRows = rs, aggIx = i + 1 })

  PSort _ _ -> do
    (rs, i) <- case esData st of
      DSort rs i -> pure (rs, i)
      _          -> throwSqlOf (errInternal "state mismatch: PSort")
    case rs of
      Nothing -> pure (Nothing, DSort { sortRows = Nothing, sortIx = i })
      Just rows
        | i < length rows -> pure (Just (Nothing, rows !! i), DSort (Just rows) (i + 1))
        | otherwise       -> pure (Nothing, DSort (Just rows) i)

  PMaterialize _ -> do
    (rs, i) <- case esData st of
      DMat rs i -> pure (rs, i)
      _         -> throwSqlOf (errInternal "state mismatch: PMaterialize")
    pure (rowAt rs i, DMat { matRows = rs, matIx = i + 1 })

  PInsert _ _ _      -> pure (Nothing, esData st)
  PUpdate _ _ _      -> pure (Nothing, esData st)
  PDelete _ _        -> pure (Nothing, esData st)
  PCreateTable _     -> pure (Nothing, esData st)
  PCreateIndex _     -> pure (Nothing, esData st)

-- | Replay row of a materialising node (RIDs never survive these nodes,
--   §9.1: only rows straight from a base scan carry a RID).
rowAt :: [[Value]] -> Int -> Maybe (Maybe RID, [Value])
rowAt rows i
  | i < length rows = Just (Nothing, rows !! i)
  | otherwise       = Nothing

filterNext :: ExecCtx -> PPred -> IORef ExecState
           -> IO (Maybe (Maybe RID, [Value]), ExecData)
filterNext ec p k = loop
  where
    loop = nextRow ec k >>= \r -> case r of
      Nothing               -> pure (Nothing, DFilter)
      Just (mrid, vals)     -> do
        ok <- evalPred ec p vals
        if ok then pure (Just (mrid, vals), DFilter) else loop

-- | NestedLoop: re-open the inner per outer tuple unless it is materialised
--   (§8.5/§9.3).
nlNext :: ExecCtx -> IORef ExecState -> Plan -> Maybe PPred
       -> (Maybe [Value], Maybe (IORef ExecState), Bool, Bool)
       -> IO (Maybe (Maybe RID, [Value]), Maybe [Value], Maybe (IORef ExecState), Bool, Bool)
nlNext ec ko innerPlan residual cur0 = go cur0
  where
    go (mo, mih, done, mat)
      | done = pure (Nothing, Nothing, mih, True, mat)
      | otherwise = do
          mo' <- case mo of
                   Just r -> pure (Just r)
                   Nothing -> do
                     r0 <- nextRow ec ko
                     case r0 of
                       Nothing        -> pure Nothing
                       Just (_, vals) -> pure (Just vals)
          case mo' of
            Nothing -> pure (Nothing, Nothing, mih, True, mat)
            Just outerRow -> do
              ih <- case mih of
                      Just h  -> pure h
                      Nothing -> openPlan ec innerPlan
              r <- nextRow ec ih
              case r of
                Just (_, vals) -> do
                  let joined = outerRow ++ vals
                  ok <- case residual of
                          Nothing -> pure True
                          Just p  -> evalPred ec p joined
                  if ok
                    then pure (Just (Nothing, joined), Just outerRow, Just ih, False, mat)
                    else go (Just outerRow, Just ih, False, mat)
                Nothing
                  | mat -> do
                      ihs <- rewind ec ih
                      go (Nothing, Just ihs, False, mat)
                  | otherwise -> do
                      closePlan ec ih
                      go (Nothing, Nothing, False, mat)

-- | IndexNestedLoop: probe per outer row (§9.3).
inlNext :: ExecCtx -> IORef ExecState -> RelationDesc -> IndexDesc -> FlatRef
         -> (Maybe [Value], [(RID, [Value])])
         -> IO (Maybe (Maybe RID, [Value]), Maybe [Value], [(RID, [Value])])
inlNext ec ko rd idx key cur0 = go cur0
  where
    go (mo, hits)
      | Just outerRow <- mo, (_rid, vals) : rest <- hits =
          pure (Just (Nothing, outerRow ++ vals), Just outerRow, rest)
      | otherwise = do
          r0 <- nextRow ec ko
          case r0 of
            Nothing -> pure (Nothing, Nothing, [])
            Just (_, orow) -> do
              let ixc = ixRelId idx
              rids <- btreeSearch (ecEnv ec) (ecCatalog ec) ixc (orow !! key)
              fetched <- mapM (\rid -> heapFetch (ecEnv ec) (ecTxn ec) rd rid
                                          >>= \t -> pure ((rid,) <$> t)) rids
              let hits' = [ x | Just x <- fetched ]
              if null hits'
                then go (Just orow, [])
                else go (Just orow, hits')

-- | HashJoin: probe streaming, matches from the build table (§8.5/§9.3).
hjNext :: ExecCtx -> JoinSides -> IORef ExecState -> ExecData
       -> IO (Maybe (Maybe RID, [Value]), ExecData)
hjNext ec js probeH d0 = loop d0
  where
    loop d = case d of
      DHash mtb (row : rest) _ bl ->
        pure (Just (Nothing, row), DHash mtb rest Nothing bl)
      DHash mtb [] _ bl -> advance mtb bl
      _ -> throwSqlOf (errInternal "state mismatch: PHashJoin")
    advance mtb bl = nextRow ec probeH >>= \r -> case r of
      Nothing -> pure (Nothing, DHash mtb [] Nothing bl)
      Just (_, prow) -> do
        let tbl = case mtb of Just t -> t; Nothing -> M.empty
            matches = M.findWithDefault [] (encodeValue (prow !! jsProbeKey js)) tbl
            joined = [ if bl then b ++ prow else prow ++ b | b <- matches ]
        passed <- case jsResidual js of
                    Nothing -> pure joined
                    Just p  -> filterM (\v -> evalPred ec p v) joined
        case passed of
          (x : xs) -> pure (Just (Nothing, x), DHash mtb xs (Just prow) bl)
          []       -> advance mtb bl

buildTable :: ExecCtx -> IORef ExecState -> FlatRef -> IO (Map ByteString [[Value]])
buildTable ec kh key = go M.empty
  where
    go acc = nextRow ec kh >>= \r -> case r of
      Nothing -> pure acc
      Just (_, vals) -> do
        chargeMem ec (rowByteSize vals)
        go (M.insertWith (flip (++)) (encodeValue (vals !! key)) [vals] acc)

-- ---------------------------------------------------------------------------
-- close
-- ---------------------------------------------------------------------------
closePlan :: ExecCtx -> IORef ExecState -> IO ()
closePlan ec h = do
  st <- readIORef h
  mapM_ (closePlan ec) (esChild st)
  closeData ec st

closeData :: ExecCtx -> ExecState -> IO ()
closeData ec st = case esData st of
  DHash{hjTable = Just tbl} -> releaseMem ec (totalRowBytes (concat (M.elems tbl)))
  DSort{sortRows = Just rs} -> releaseMem ec (totalRowBytes rs)
  DMat{matRows = rs}        -> releaseMem ec (totalRowBytes rs)
  DAgg{aggRows = fin}       -> releaseRows ec fin
  DNL{nlInner = Just ih}    -> closePlan ec ih
  _                         -> pure ()

-- ---------------------------------------------------------------------------
-- Ordering + aggregation
-- ---------------------------------------------------------------------------
sortRowsBy :: [(Int, Bool)] -> [[Value]] -> [[Value]]
sortRowsBy keys = sortBy (cmpKeys keys)

cmpKeys :: [(Int, Bool)] -> [Value] -> [Value] -> Ordering
cmpKeys keys r1 r2 = mconcat (map (cmpKey r1 r2) keys)
  where
    cmpKey a b (i, asc) = case (atMay a i, atMay b i) of
      (Just x, Just y) -> let c = compareSql x y in if asc then c else revOrd c
      _                -> EQ

atMay :: [Value] -> Int -> Maybe Value
atMay row i = if i >= 0 && i < length row then Just (row !! i) else Nothing

revOrd :: Ordering -> Ordering
revOrd LT = GT
revOrd EQ = EQ
revOrd GT = LT

-- | Group table of HashAggregate: count, representative group column values,
--   per-spec argument value lists (a deviation: the docs keep streaming
--   accumulator cells; the drained input makes both shapes equivalent).
data Group = Group { gCount :: !Int64, gVals :: [Value], gArgs :: [[Value]] }

groupRow :: [FlatRef] -> [AggSpec] -> [Value] -> Group
groupRow gfr specs row =
  Group { gCount = 1, gVals = [ row !! f | f <- gfr ]
        , gArgs = [ case asArg s of Just f -> [row !! f]; Nothing -> [] | s <- specs ] }

mergeGroup :: Group -> Group -> Group
mergeGroup new old =
  Group { gCount = gCount old + gCount new, gVals = gVals old
        , gArgs = zipWith (++) (gArgs new) (gArgs old) }

gkey :: [FlatRef] -> [Value] -> ByteString
gkey gfr row = BS.concat (map (encodeValue . (row !!)) gfr)

finalizeSpec :: ExecCtx -> AggSpec -> [Value] -> Int64 -> IO Value
finalizeSpec _ec spec vals cnt = case asFn spec of
  AggCount -> pure (VInt cnt)
  AggSum
    | null vals                 -> throwSqlOf errAggEmptyInput
    | asOutType spec == TyInt64 -> VInt <$> intSum vals
    | otherwise                 -> pure (VFloat (floatSum vals))
  AggAvg
    | cnt == 0  -> throwSqlOf errAggEmptyInput
    | otherwise -> pure (VFloat (floatSum vals / fromIntegral cnt))
  AggMin -> extreme GT vals          -- keep the smaller
  AggMax -> extreme LT vals          -- keep the larger

intSum :: [Value] -> IO Int64
intSum = foldM step (0 :: Int64)
  where
    step a (VInt b) = do
      let s = toInteger a + toInteger b
      if s < toInteger (minBound :: Int64) || s > toInteger (maxBound :: Int64)
        then throwSqlOf errIntOverflow
        else pure (fromInteger s)
    step _ v = throwSqlOf (errInternal ("executor: SUM of a non-integer value " <> tshow v))

floatSum :: [Value] -> Double
floatSum = sum . map toFloat
  where
    toFloat (VFloat x) = x
    toFloat (VInt x)   = fromIntegral x
    toFloat _          = 0

extreme :: Ordering -> [Value] -> IO Value
extreme _ []     = throwSqlOf errAggEmptyInput
extreme worse (v:vs) = pure (foldl pick v vs)
  where
    pick a b = case compareSql a b of
                 c | c == worse -> b
                 _              -> a

finalizeAgg :: ExecCtx -> [FlatRef] -> [AggSpec] -> [[Value]] -> IO [[Value]]
finalizeAgg ec gfr specs rows
  | null gfr = do
      let cnt  = fromIntegral (length rows)
          full = [ case asArg s of Just f -> [ r !! f | r <- rows ]; Nothing -> [] | s <- specs ]
      fs <- zipWithM (\s vs -> finalizeSpec ec s vs cnt) specs full
      pure [ fs ]
  | otherwise = do
      let keyed = [ (gkey gfr r, groupRow gfr specs r) | r <- rows ]
          gmap  = foldl (\acc (bs, g) -> M.insertWith mergeGroup bs g acc) M.empty keyed
      mapM (oneGroup specs) (M.elems gmap)
  where
    oneGroup sp g = do
      fs <- zipWithM (\s vs -> finalizeSpec ec s vs (gCount g)) sp (gArgs g)
      pure (gVals g ++ fs)

-- ---------------------------------------------------------------------------
-- DML runs (§9.5): collect-then-modify, run at open
-- ---------------------------------------------------------------------------
rootOf :: IORef (Map RelId PageId) -> IndexDesc -> IO PageId
rootOf refs ix = do
  m <- readIORef refs
  pure (M.findWithDefault (ixRoot ix) (ixRelId ix) m)

-- | Index roots for the WHOLE statement, kept in the ExecCtx (see the
--   ecRoots deviation note): seeding them fresh from the catalog on every
--   call made a later COPY IN chunk descend the pre-split root, because the
--   staged root only lands at COMMIT.
newRoots :: ExecCtx -> RelId -> IO ([IndexDesc], IORef (Map RelId PageId))
newRoots ec relid = do
  ixs <- indexesOf (ecCatalog ec) relid
  let shared = ecRoots ec
  modifyIORef' shared $ \m ->
    foldl (\acc i -> if M.member (ixRelId i) acc
                       then acc
                       else M.insert (ixRelId i) (ixRoot i) acc) m ixs
  pure (ixs, shared)

syncIndexRoots :: ExecCtx -> [IndexDesc] -> IORef (Map RelId PageId) -> IO ()
syncIndexRoots ec ixs refs = forM_ ixs $ \ix -> do
  m <- readIORef refs
  case M.lookup (ixRelId ix) m of
    Just r | r /= ixRoot ix ->
      updateIndexRoot (ecEnv ec) (ecCatalog ec) (ecTxn ec) (ixRelId ix) r
    _ -> pure ()

runInsert :: ExecCtx -> RelId -> [Int] -> [[Value]] -> IO Int64
runInsert ec relid ords vals = do
  rd <- lookupDesc ec relid
  (ixs, roots) <- newRoots ec relid
  cnt <- newIORef (0 :: Int64)
  forM_ vals $ \vs -> do
    let tup = assignTuple (rdColumns rd) ords vs
    rid <- heapInsert (ecEnv ec) (ecTxn ec) rd tup
    modifyIORef' cnt (+ 1)
    forM_ ixs $ \ix -> do
      r0 <- rootOf roots ix
      newr <- btreeInsert (ecEnv ec) (ecCatalog ec) (ecTxn ec) (ixRelId ix) r0
                          (tup !! ixColumn ix) rid
      modifyIORef' roots (M.insert (ixRelId ix) newr)
  n <- readIORef cnt
  when (n > 0) $ do
    stageTupleDelta (ecCatalog ec) (ecTxn ec) relid n
    stageNewHeapPages ec relid (rdPages rd)
    syncIndexRoots ec ixs roots
  pure n

runUpdate :: ExecCtx -> RelId -> [(Int, PAssignRhs)] -> IORef ExecState -> IO Int64
runUpdate ec relid asgs childH = do
  pairs <- drainPairs ec childH
  chargeRows ec (map snd pairs)
  rd <- lookupDesc ec relid
  (ixs, roots) <- newRoots ec relid
  let nCols = length (rdColumns rd)
  cnt <- newIORef (0 :: Int64)
  forM_ pairs $ \(rid, old) -> do
    lockRow (ecTxn ec) relid rid LX
    let new = [ case lookup j asgs of
                  Just rhs -> rhsOf rhs old
                  Nothing  -> old !! j
              | j <- [0 .. nCols - 1] ]
    heapUpdate (ecEnv ec) (ecTxn ec) rd rid new
    forM_ ixs $ \ix -> do
      let c = ixColumn ix
      when (c < length old && c < length new && old !! c /= new !! c) $ do
        r0 <- rootOf roots ix
        btreeDelete (ecEnv ec) (ecCatalog ec) (ecTxn ec) (ixRelId ix) r0 (old !! c) rid
        newr <- btreeInsert (ecEnv ec) (ecCatalog ec) (ecTxn ec) (ixRelId ix) r0
                            (new !! c) rid
        modifyIORef' roots (M.insert (ixRelId ix) newr)
    modifyIORef' cnt (+ 1)
  n <- readIORef cnt
  releaseRows ec (map snd pairs)
  syncIndexRoots ec ixs roots
  pure n

runDelete :: ExecCtx -> RelId -> IORef ExecState -> IO Int64
runDelete ec relid childH = do
  pairs <- drainPairs ec childH
  chargeRows ec (map snd pairs)
  rd <- lookupDesc ec relid
  (ixs, roots) <- newRoots ec relid
  cnt <- newIORef (0 :: Int64)
  forM_ pairs $ \(rid, old) -> do
    lockRow (ecTxn ec) relid rid LX
    heapDelete (ecEnv ec) (ecTxn ec) rd rid
    forM_ ixs $ \ix -> do
      let c = ixColumn ix
      if c < length old
        then do
          r0 <- rootOf roots ix
          btreeDelete (ecEnv ec) (ecCatalog ec) (ecTxn ec) (ixRelId ix) r0 (old !! c) rid
        else pure ()
    modifyIORef' cnt (+ 1)
  n <- readIORef cnt
  when (n > 0) $ stageTupleDelta (ecCatalog ec) (ecTxn ec) relid (negate n)
  releaseRows ec (map snd pairs)
  syncIndexRoots ec ixs roots
  pure n







