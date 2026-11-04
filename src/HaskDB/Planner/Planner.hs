-- | HaskDB.Planner.Planner (internal-design/08 §8.1-8.8; design/07 §7.2-7.8).
--   Consumes the Analyzed AST + a catalog snapshot, produces the physical
--   plan tree ('HaskDB.Executor.Types').  Deviations from the docs (also
--   recorded in TODO.md):
--   * §8.2 'classify' runs on the PHYSICAL predicate type (PPred): §8.5
--     rewrites EXISTS/IN/scalar subqueries BEFORE classification and already
--     produces a separate physical type, so classification sees PPred.
--   * 'planSlotScan' takes the pre-planned 'Materialize' for derived slots
--     (planning a subplan is IO; planSlotScan is pure).  §8.3 rule 5's
--     Filter over a derived-table scan is instead accumulated into the
--     top-level residual Filter (§8.4's pseudocode accumulates the same
--     way; same predicate set, same semantics).
--   * Extra equijoin predicates connecting a slot become top-level
--     residuals (§8.4 pseudocode): 'PIndexNestedLoop' has no residual
--     slot (its driving equality is enforced by the index probe), and
--     'PHashJoin' jsResidual stays Nothing (equality enforced by the
--     hash key).  'PNestedLoop' carries the driving equality re-localized
--     to its own row layout.
--   * Derived-table subplans have their own preamble subqueries HOISTED
--     into the enclosing statement's 'planSubqueries' and cleared on the
--     node: 'openPlan' never runs a preamble for tree nodes, and
--     "materialised once per statement" (§7.6) is what the preamble gives.
--   * 'PInsert' carries the target column ordinals (§9.1 omits them; the
--     VALUES column order may differ from schema order).  A PARTIAL
--     column list is rejected at plan time with 0A000: this dialect has
--     no NULL and no defaults, so unassigned columns have no value to
--     write (design/05 is silent; PostgreSQL fills NULLs).
--   * One SubqueryId counter per statement threaded through every nested
--     'planSelect' (per-plan counters could collide once derived-table
--     subqueries are hoisted).
--   * §7.4 rule 2's `rows(T) * rows(R)` threshold and the build-side choice
--     use the CATALOG reltuples for the base relation R (planRows of an
--     IndexScanned slot is a filtered estimate, not the docs' figure); the
--     accumulated tree T has no reltuples so its estimate stands.  Cost
--     annotations keep the planRows figures.
--   * Scan bounds accept LITERAL operands only; design/07 §7.3 line 55 also
--     allows an uncorrelated SUBQUERY value as a scan bound, but §8.5 keeps
--     those operands as SubqueryId refs, so such a predicate stays a
--     residual Filter (correct rows, SeqScan instead of IndexScan) — the
--     docs' "rewritten to literals in §8.5" parenthetical is unimplementable
--     as the docs stand, reported both ways, TODO.md note.
--   * The INLJ branch discards slot i's planned scan (the probe replaces it,
--     §7.4 rule 1), so the predicates that scan CONSUMED into bounds rejoin
--     the top-level residual Filter (internal/08 §8.4's pseudocode has the
--     same hole; design/07 §7.3's every-conjunct rule demands it).
module HaskDB.Planner.Planner where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.List (find, findIndex, nub, sort)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Control.Monad (when, forM)

import HaskDB.Common.Types (RelId, Value, SqlType(..))
import HaskDB.Common.Error (SqlError(..), throwSql, errInternal)
import HaskDB.Catalog.Cache (CatalogCache, lookupById, indexesOf)
import HaskDB.Catalog.Types (IndexDesc, RelationDesc, rdName, rdColumns, rdPages, rdTuples,
                             ixColumn)
import HaskDB.Sql.Analyzer (Analyzed(..), RSelect(..), FromSlot(..),
                            RSelectItem(..), RPred(..), ROperand(..), RAssign(..),
                            RColRef,
                            rsFrom, rsWhere, rsItems, rsGroupBy, rsOrderBy, rsIsAgg,
                            fsRelId, fsColumns, fsSubplan,
                            rcFrom, rcCol, rcType)
import qualified HaskDB.Sql.Ast as SA
import HaskDB.Executor.Types
import HaskDB.Planner.CostModel

-- ---------------------------------------------------------------------------
-- Plan environment (internal/08 §8.1)
-- ---------------------------------------------------------------------------
data PlanEnv = PlanEnv { peTables  :: Map RelId RelationDesc
                       , peIndexes :: Map RelId [IndexDesc] }

mkPlanEnv :: CatalogCache -> [FromSlot] -> IO PlanEnv
mkPlanEnv cache sls = do
  let rels = [ r | sl <- sls, Just r <- [fsRelId sl] ]
  ts <- mapM (\r -> lookupById cache r >>= \dm -> pure (r, dm)) rels
  ix <- mapM (\r -> indexesOf cache r >>= \is -> pure (r, is)) rels
  pure PlanEnv { peTables  = M.fromList [ (r, d) | (r, Just d) <- ts ]
               , peIndexes = M.fromList [ (r, is) | (r, is) <- ix ] }

-- ---------------------------------------------------------------------------
-- Plan construction helpers (internal/08 §8.8 wrapper)
-- ---------------------------------------------------------------------------
throwSqlOf :: SqlError -> IO a
throwSqlOf (SqlError st msg) = throwSql st msg

mkPlan :: PlanNode -> Double -> Int64 -> Plan
mkPlan node cost rows =
  Plan { planNode = node, planCost = cost, planRows = rows
       , planSubqueries = [] }

withSubs :: Plan -> [(SubqueryId, Plan, SQKind)] -> Plan
withSubs p subs = p { planSubqueries = subs }

clearSubs :: Plan -> Plan
clearSubs p = p { planSubqueries = [] }

nextSubq :: IORef Int -> IO SubqueryId
nextSubq r = do
  n <- readIORef r
  writeIORef r (n + 1)
  pure (SubqueryId n)

-- ---------------------------------------------------------------------------
-- Flat layout (internal/08 §8.4)
-- ---------------------------------------------------------------------------
slotWidth :: FromSlot -> Int
slotWidth = length . fsColumns

flatOfCol :: [FromSlot] -> Int -> Int -> FlatRef
flatOfCol sls i j = sum (map slotWidth (take i sls)) + j

flatWidth :: [FromSlot] -> Int
flatWidth = sum . map slotWidth

flatToCol :: [FromSlot] -> FlatRef -> Maybe (Int, Int)
flatToCol sls f = go 0 0 sls
  where
    go _ _ [] = Nothing
    go acc j (sl : rest)
      | acc <= f, f < acc + w = Just (j, f - acc)
      | otherwise             = go (acc + w) (j + 1) rest
      where w = slotWidth sl

-- ---------------------------------------------------------------------------
-- Predicate normalisation and classification (internal/08 §8.2/§8.5)
-- ---------------------------------------------------------------------------
conjuncts :: PPred -> [PPred]
conjuncts p = case p of
  PPAnd a b -> conjuncts a ++ conjuncts b
  _         -> [p]

predCols :: PPred -> [FlatRef]
predCols p = case p of
  PPAnd a b       -> predCols a ++ predCols b
  PPOr a b        -> predCols a ++ predCols b
  PPNot a         -> predCols a
  PPCmp o1 _ o2   -> opCols o1 ++ opCols o2
  PPIn f _ _      -> [f]
  PPExistsRef _   -> []
  where opCols (POCol f) = [f]
        opCols _         = []

-- | Re-localize a predicate's flat refs from the global (all-slots) layout
--   to a NestedLoop node's own outer ++ inner row layout: refs below the
--   outer width stay, refs at/above it shift down by that width.
relocalize :: Int -> PPred -> PPred
relocalize w p = case p of
  PPAnd a b          -> PPAnd (relocalize w a) (relocalize w b)
  PPOr a b           -> PPOr (relocalize w a) (relocalize w b)
  PPNot a            -> PPNot (relocalize w a)
  PPCmp o1 op o2     -> PPCmp (ro o1) op (ro o2)
  PPIn f neg sid     -> PPIn (adj f) neg sid
  PPExistsRef sid    -> PPExistsRef sid
  where adj f = if f < w then f else f - w
        ro (POCol f) = POCol (adj f)
        ro o         = o

data ClassifiedPred
  = CmpSingle Int PPred
  | CmpEquiJoin (Int, Int) (Int, Int) PPred
  | CmpOther PPred
  deriving (Show)

singleOrOther :: [FromSlot] -> PPred -> ClassifiedPred
singleOrOther sls p =
  let rs = predCols p
      ms = mapMaybe (flatToCol sls) rs
  in if length ms /= length rs
       then CmpOther p
       else case nub (map fst ms) of
              [s] -> CmpSingle s p
              _   -> CmpOther p

classify :: [FromSlot] -> PPred -> ClassifiedPred
classify sls p = case p of
  PPCmp o1 op o2
    | op == OpEq
    , Just (fa, fb) <- eqCols o1 o2
    , Just (sa, ca) <- flatToCol sls fa
    , Just (sb, cb) <- flatToCol sls fb
    , sa /= sb -> CmpEquiJoin (sa, ca) (sb, cb) p
  _ -> singleOrOther sls p
  where eqCols (POCol a) (POCol b) = Just (a, b)
        eqCols _ _                 = Nothing

-- | Selectivity divisors for the §7.5 fixed fractions: equality 1/10,
--   range and "other" 1/3 (annotation only).
predDivisor :: PPred -> Int64
predDivisor p = case p of
  PPCmp _ OpEq _ -> 10
  PPCmp _ OpLt _ -> 3
  PPCmp _ OpLe _ -> 3
  PPCmp _ OpGt _ -> 3
  PPCmp _ OpGe _ -> 3
  _              -> 3

andAll :: [PPred] -> PPred
andAll (p:ps) = foldl PPAnd p ps
andAll []     = error "planner invariant: andAll of an empty predicate list"

filterPlan :: [PPred] -> Plan -> Plan
filterPlan []     p = p
filterPlan preds@(_:_) p =
  mkPlan (PFilter (andAll preds) p)
         (planCost p + fromIntegral (planRows p) * cpuOperatorCost)
         (estFilterRows (planRows p) (map predDivisor preds))

-- ---------------------------------------------------------------------------
-- Subquery rewriting before classification (internal/08 §8.5)
-- ---------------------------------------------------------------------------
mapCmpOp :: SA.CmpOp -> CmpOp
mapCmpOp o = case o of
  SA.OpEq -> OpEq
  SA.OpNe -> OpNe
  SA.OpLt -> OpLt
  SA.OpLe -> OpLe
  SA.OpGt -> OpGt
  SA.OpGe -> OpGe

rewriteOperand :: CatalogCache -> IORef Int -> [FromSlot]
               -> ROperand -> IO (POperand, [(SubqueryId, Plan, SQKind)])
rewriteOperand cache cnt sls o = case o of
  ROCol cr  -> pure (POCol (flatOfCol sls (rcFrom cr) (rcCol cr)), [])
  ROLit v   -> pure (POLit v, [])
  ROScalar sub -> do
    sp <- planSelect cache cnt sub
    sid <- nextSubq cnt
    pure (POScalar sid, [(sid, sp, KindScalar)])

rewritePred :: CatalogCache -> IORef Int -> [FromSlot]
            -> RPred -> IO (PPred, [(SubqueryId, Plan, SQKind)])
rewritePred cache cnt sls p = case p of
  RPAnd a b -> do
    (a', s1) <- rewritePred cache cnt sls a
    (b', s2) <- rewritePred cache cnt sls b
    pure (PPAnd a' b', s1 ++ s2)
  RPOr a b -> do
    (a', s1) <- rewritePred cache cnt sls a
    (b', s2) <- rewritePred cache cnt sls b
    pure (PPOr a' b', s1 ++ s2)
  RPNot a -> do
    (a', s) <- rewritePred cache cnt sls a
    pure (PPNot a', s)
  RPCmp o1 op o2 -> do
    (o1', s1) <- rewriteOperand cache cnt sls o1
    (o2', s2) <- rewriteOperand cache cnt sls o2
    pure (PPCmp o1' (mapCmpOp op) o2', s1 ++ s2)
  RPExists sub -> do
    sp <- planSelect cache cnt sub
    sid <- nextSubq cnt
    pure (PPExistsRef sid, [(sid, sp, KindExists)])
  RPIn cr neg sub -> do
    sp <- planSelect cache cnt sub
    sid <- nextSubq cnt
    pure (PPIn (flatOfCol sls (rcFrom cr) (rcCol cr)) neg sid
          , [(sid, sp, KindSet)])

rewriteMaybePred :: CatalogCache -> IORef Int -> [FromSlot]
                 -> Maybe RPred -> IO (Maybe PPred, [(SubqueryId, Plan, SQKind)])
rewriteMaybePred cache cnt sls mw = case mw of
  Nothing -> pure (Nothing, [])
  Just rp -> do
    (p', s) <- rewritePred cache cnt sls rp
    pure (Just p', s)

-- ---------------------------------------------------------------------------
-- Scan planning per slot (internal/08 §8.3; design/07 §7.4)
-- ---------------------------------------------------------------------------
data ScanBound = SBEqual FlatRef Value
               | SBLower FlatRef Value Bool     -- (bound, inclusive?)
               | SBUpper FlatRef Value Bool
  deriving (Show)

asBound :: PPred -> Maybe ScanBound
asBound p = case p of
  PPCmp (POCol f) o (POLit v) -> mkB f o v
  PPCmp (POLit v) o (POCol f) -> mkB f (flipCmp o) v
  _ -> Nothing
  where mkB f OpEq v = Just (SBEqual f v)
        mkB f OpLt v = Just (SBUpper f v False)
        mkB f OpLe v = Just (SBUpper f v True)
        mkB f OpGt v = Just (SBLower f v False)
        mkB f OpGe v = Just (SBLower f v True)
        mkB _ OpNe _ = Nothing

flipCmp :: CmpOp -> CmpOp
flipCmp o = case o of
  OpEq -> OpEq
  OpNe -> OpNe
  OpLt -> OpGt
  OpLe -> OpGe
  OpGt -> OpLt
  OpGe -> OpLe

sbFlat :: ScanBound -> FlatRef
sbFlat (SBEqual f _)   = f
sbFlat (SBLower f _ _) = f
sbFlat (SBUpper f _ _) = f

sbIsEq :: ScanBound -> Bool
sbIsEq (SBEqual _ _) = True
sbIsEq _             = False

lowerOf :: ScanBound -> Maybe (Value, Bool)
lowerOf (SBLower _ v inc) = Just (v, inc)
lowerOf _                 = Nothing

upperOf :: ScanBound -> Maybe (Value, Bool)
upperOf (SBUpper _ v inc) = Just (v, inc)
upperOf _                 = Nothing

-- | The scan plan for one FROM slot + the single-slot predicates it did
--   NOT consume (they join the top-level residual Filter — see the
--   deviation note in rule 5) + the predicates it DID consume into scan
--   bounds.  The third component exists for the §7.4 INLJ branch, which
--   discards this scan: those bounds rejoin the residuals there (the
--   §8.4 pseudocode's `IndexNestedLoop(tree, table_i, index)` has the
--   same hole; design/07 §7.3's "every conjunct is a scan bound, a
--   join-node predicate or a residual filter" demands it — TODO.md).
--   The 'Maybe Plan' is the pre-planned 'Materialize' for derived slots.
planSlotScan :: PlanEnv -> [FromSlot] -> Int -> FromSlot -> Maybe Plan
             -> [PPred] -> (Plan, [PPred], [PPred])
planSlotScan env sls i sl dm singles = case dm of
  Just mat -> (mat, singles, [])
  Nothing ->
    let rd = fsRelId sl >>= \r -> M.lookup r (peTables env)
    in case rd of
      Nothing -> (mkPlan (PSeqScan 0) 0.0 0, singles, [])  -- defensive
      Just d ->
        let relid  = fromMaybe (error "planner invariant: base slot without relid")
                           (fsRelId sl)
            ixList = M.findWithDefault [] relid (peIndexes env)
            rowsR  = rdTuples d
            cands :: [(Int, ScanBound, IndexDesc, PPred)]
            cands = [ (k, b, ix, p)
                    | (k, p) <- zip [0 :: Int ..] singles
                    , Just b <- [asBound p]
                    , Just (s, c) <- [flatToCol sls (sbFlat b)]
                    , s == i
                    , Just ix <- [find (\x -> ixColumn x == c) ixList] ]
            rC = [ (k, b, ix, p) | (k, b, ix, p) <- cands, not (sbIsEq b) ]
            seqPlan = mkPlan (PSeqScan relid)
                             (costSeqScan (length (rdPages d)) rowsR) rowsR
        in case (find (\(_, b, _, _) -> sbIsEq b) cands, rC) of
          (Just (k, SBEqual _ v, ix, _), _) ->
            ( mkPlan (PIndexScan relid ix (IBEqual v))
                     (costIndexScan (indexDepthEst rowsR) (matchedEq rowsR))
                     (matchedEq rowsR)
            , [ q | (k', q) <- zip [0 :: Int ..] singles, k' /= k ]
            , [ q | (k', q) <- zip [0 :: Int ..] singles, k' == k ] )
          (Nothing, ((_, b0, ix0, _):_)) ->
            let sameCol b = flatToCol sls (sbFlat b) == flatToCol sls (sbFlat b0)
                rOn = [ (k, b, ix, p) | (k, b, ix, p) <- rC, sameCol b ]
                lo = [ (k, vl) | (k, b, _, _) <- rOn, Just vl <- [lowerOf b] ]
                up = [ (k, vl) | (k, b, _, _) <- rOn, Just vl <- [upperOf b] ]
                picked = map fst (take 1 lo) ++ map fst (take 1 up)
                rowsE = matchedRange rowsR
            in ( mkPlan (PIndexScan relid ix0
                           (IBRange (fmap snd (listToMaybe lo))
                                    (fmap snd (listToMaybe up))))
                    (costIndexScan (indexDepthEst rowsR) rowsE) rowsE
               , [ q | (k', q) <- zip [0 :: Int ..] singles, k' `notElem` picked ]
               , [ q | (k', q) <- zip [0 :: Int ..] singles, k' `elem` picked ] )
          (_, _) -> (seqPlan, singles, [])  -- defensive

-- ---------------------------------------------------------------------------
-- Join tree construction (internal/08 §8.4; design/07 §7.4)
-- ---------------------------------------------------------------------------
data EquiJ = EquiJ { ejA :: (Int, Int), ejB :: (Int, Int)
                   , ejPred :: PPred, ejIdx :: Int }

planJoins :: PlanEnv -> [FromSlot] -> [Plan] -> [[PPred]] -> [EquiJ]
          -> (Plan, [PPred])
planJoins env sls scans consumed eqs0 = go (scans !! 0) [0] 1 eqs0 []
  where
    n = length sls
    go tree joined i es resAcc
      | i >= n = (tree, resAcc ++ map ejPred es)  -- leftovers: defensive
      | otherwise =
          let connects e = (fst (ejA e) == i && fst (ejB e) `elem` joined)
                        || (fst (ejB e) == i && fst (ejA e) `elem` joined)
              conn = filter connects es
              rest = filter (not . connects) es
              scan = scans !! i
              rowsT = planRows tree
              -- §7.4 rule 2/§7.5 speak of rows(R) = reltuples for the base
              -- relation; planRows of an IndexScanned slot is a filtered
              -- estimate, so the catalog figure is what the docs mean.
              rowsRelI = case fsRelId (sls !! i) of
                           Just r  -> maybe (planRows scan) rdTuples
                                        (M.lookup r (peTables env))
                           Nothing -> planRows scan   -- derived slot estimate
              rowsI = rowsRelI
              consI = if i < length consumed then consumed !! i else []
          in case conn of
            [] ->
              go (mkPlan (PNestedLoop tree scan Nothing)
                       (costNLJ (planCost tree) rowsT (planCost scan))
                       (estJoinRowsCross rowsT rowsI))
                 (joined ++ [i]) (i + 1) es resAcc
            (drive:extras) ->
              let (outSlot, outCol)
                    | fst (ejA drive) == i = ejB drive
                    | otherwise            = ejA drive
                  inCol | fst (ejA drive) == i = snd (ejA drive)
                        | otherwise            = snd (ejB drive)
                  keyOut = flatOfCol sls outSlot outCol
                  wOuter = flatWidth (take i sls)
                  mInl = case (fsSubplan (sls !! i), fsRelId (sls !! i)) of
                           (Nothing, Just r) ->
                               fmap ((,) r)
                                 (find (\x -> ixColumn x == inCol)
                                   (M.findWithDefault [] r (peIndexes env)))
                           _ -> Nothing
                  joinRows = estJoinRowsEqui rowsT rowsI
                  tree' = case mInl of
                    Just (r, ix) ->
                      mkPlan (PIndexNestedLoop tree r ix keyOut)
                             (costNLJ (planCost tree) rowsT
                              (costIndexScan (indexDepthEst rowsI) (matchedEq rowsI)))
                             joinRows
                    Nothing | rowsT * rowsI > fromIntegral nljHashThreshold ->
                      let buildLeft = rowsT <= rowsI
                          leftC = if buildLeft then matWrap tree else tree
                          matWrap t = mkPlan (PMaterialize t)
                                    (planCost t + fromIntegral (planRows t) * cpuOperatorCost)
                                    (planRows t)
                          js = JoinSides { jsBuild    = if buildLeft
                                                          then BuildLeft else BuildRight
                                         , jsBuildKey = if buildLeft then keyOut else inCol
                                         , jsProbeKey = if buildLeft then inCol else keyOut
                                         , jsResidual = Nothing }
                      in mkPlan (PHashJoin leftC scan js)
                               (costHashJoin (planCost leftC) (planCost scan) rowsT rowsI)
                               joinRows
                    Nothing ->
                      mkPlan (PNestedLoop tree scan
                                         (Just (relocalize wOuter (ejPred drive))))
                             (costNLJ (planCost tree) rowsT (planCost scan))
                             joinRows
              in go tree' (joined ++ [i]) (i + 1) rest
                   (resAcc ++ map ejPred extras
                    ++ case mInl of Just _ -> consI; Nothing -> [])

-- ---------------------------------------------------------------------------
-- SELECT planning (internal/08 §8.4/§8.6; design/07 §7.4/§7.7)
-- ---------------------------------------------------------------------------
planSelect :: CatalogCache -> IORef Int -> RSelect -> IO Plan
planSelect cache cnt rs = do
  let sls = rsFrom rs
  env <- mkPlanEnv cache sls
  slotRes <- forM sls $ \sl -> case fsSubplan sl of
    Nothing -> pure (Nothing, [])
    Just sub -> do
      sp <- planSelect cache cnt sub
      let hoisted = planSubqueries sp
          bare = clearSubs sp
          mat = mkPlan (PMaterialize bare)
                       (planCost bare + fromIntegral (planRows bare) * cpuOperatorCost)
                       (planRows bare)
      pure (Just mat, hoisted)
  (mpp, subs1) <- rewriteMaybePred cache cnt sls (rsWhere rs)
  let conj = maybe [] conjuncts mpp
      cls = map (classify sls) conj
      eqs = [ EquiJ ab bb q k | (k, CmpEquiJoin ab bb q) <- zip [0 :: Int ..] cls ]
      singlesOf i = [ q | (_, CmpSingle j q) <- zip [0 :: Int ..] cls, j == i ]
      others = [ q | CmpOther q <- cls ]
      scanPairs = zipWith (\(i, sl) dm -> planSlotScan env sls i sl dm (singlesOf i))
                          (zip [0 ..] sls) (map fst slotRes)
      (tree0, joinRes) = planJoins env sls (map (\(a, _, _) -> a) scanPairs)
                                           [ c | (_, _, c) <- scanPairs ] eqs
      treeF = filterPlan (others ++ concat [ l | (_, l, _) <- scanPairs ]
                                   ++ joinRes) tree0
  topPlan <- if rsIsAgg rs
    then do
      pj <- projItemsAgg rs
      let groupFrs = [ flatOfCol sls (rcFrom g) (rcCol g) | g <- rsGroupBy rs ]
          aggSpecs = [ AggSpec f (fmap (\rc -> flatOfCol sls (rcFrom rc) (rcCol rc)) m)
                         (aggOutType f m)
                     | (_, f, m) <- aggItemsOf (rsItems rs) ]
          aggPlan = mkPlan (PHashAggregate groupFrs aggSpecs treeF)
                           (planCost treeF + fromIntegral (planRows treeF) * cpuOperatorCost)
                           (estAggRows (planRows treeF))
      pure (mkPlan (PProject pj aggPlan)
                   (planCost aggPlan + fromIntegral (planRows aggPlan) * cpuOperatorCost)
                   (planRows aggPlan))
    else do
      pj <- projItemsPlain sls rs
      pure (mkPlan (PProject pj treeF)
                   (planCost treeF + fromIntegral (planRows treeF) * cpuOperatorCost)
                   (planRows treeF))
  pure (withSubs (wrapSort (rsOrderBy rs) topPlan)
               (subs1 ++ concatMap snd slotRes))

aggItemsOf :: [RSelectItem] -> [(Int, SA.AggFn, Maybe RColRef)]
aggItemsOf items = [ (k, f, m) | (k, it) <- zip [0 :: Int ..] items
                              , RIAgg f m <- [it] ]

aggOutType :: SA.AggFn -> Maybe RColRef -> SqlType
aggOutType f m = case f of
  SA.AggCount -> TyInt64
  SA.AggAvg   -> TyFloat64
  SA.AggSum   -> maybe TyInt64 rcType m
  _           -> maybe TyInt64 rcType m   -- MIN/MAX: argument's type (always present)

projItemsAgg :: RSelect -> IO [ProjItem]
projItemsAgg rs = mapM one (zip [0 :: Int ..] (rsItems rs))
  where
    gbs = rsGroupBy rs
    g = length gbs
    aggPos = [ j | (j, it) <- zip [0 :: Int ..] (rsItems rs)
                 , isRIAgg it ]
    isRIAgg (RIAgg _ _) = True
    isRIAgg _           = False
    one (k, it) = case it of
      RIColumn rc -> case findIndex
                        (\gr -> (rcFrom gr, rcCol gr) == (rcFrom rc, rcCol rc)) gbs of
                       Just t  -> pure (PJCol t)
                       Nothing -> throwSqlOf (errInternal
                         "planner: aggregate-query select column is not a GROUP BY column")
      RILiteral v -> pure (PJLit v)
      RIAgg _ _   -> pure (PJCol (g + length (filter (< k) aggPos)))

projItemsPlain :: [FromSlot] -> RSelect -> IO [ProjItem]
projItemsPlain sls rs = mapM item (rsItems rs)
  where
    item (RIColumn rc) = pure (PJCol (flatOfCol sls (rcFrom rc) (rcCol rc)))
    item (RILiteral v) = pure (PJLit v)
    item (RIAgg _ _)   = throwSqlOf (errInternal
      "planner: aggregate select item in a non-aggregate query")

wrapSort :: [(Int, Bool)] -> Plan -> Plan
wrapSort [] p = p
wrapSort keys p =
  mkPlan (PSort keys p)
         (planCost p + fromIntegral (planRows p) * cpuOperatorCost
                        * fromIntegral (max 1 (length keys)))
         (estSortRows (planRows p))

-- ---------------------------------------------------------------------------
-- DML planning (internal/08 §8.7; design/07 §7.8)
-- ---------------------------------------------------------------------------
dmlScope :: CatalogCache -> RelId -> IO (FromSlot, PlanEnv)
dmlScope cache rid = do
  mrd <- lookupById cache rid
  case mrd of
    Nothing -> throwSqlOf (errInternal "planner: DML target relation is not in the catalog")
    Just d -> do
      let sl = FromSlot { fsRelId = Just rid, fsName = rdName d
                        , fsColumns = rdColumns d, fsSubplan = Nothing }
      env <- mkPlanEnv cache [sl]
      pure (sl, env)

-- | Child plan for UPDATE/DELETE: target-table scan with the WHERE
--   conjuncts pushed (single-slot classification), residuals as Filter.
dmlChild :: CatalogCache -> IORef Int -> RelId -> Maybe RPred
        -> IO (Plan, [(SubqueryId, Plan, SQKind)])
dmlChild cache cnt rid wp = do
  (sl, env) <- dmlScope cache rid
  (pp, subs) <- rewriteMaybePred cache cnt [sl] wp
  let conj = maybe [] conjuncts pp
      (scan, left, _) = planSlotScan env [sl] 0 sl Nothing conj
  pure (filterPlan left scan, subs)

planInsert :: CatalogCache -> RelId -> [Int] -> [[Value]] -> IO Plan
planInsert cache rid ords rows = do
  mrd <- lookupById cache rid
  case mrd of
    Nothing -> throwSqlOf (errInternal "planner: INSERT target relation is not in the catalog")
    Just d -> do
      when (sort ords /= [0 .. length (rdColumns d) - 1]) $
        throwSqlOf (SqlError "0A000"
          "INSERT VALUES must assign every column: this dialect has no NULL and no defaults")
      pure (mkPlan (PInsert rid ords rows)
                   (fromIntegral (length rows) * cpuOperatorCost)
                   (fromIntegral (length rows)))

planUpdate :: CatalogCache -> IORef Int -> RelId
           -> [(Int, RAssign)] -> Maybe RPred -> IO Plan
planUpdate cache cnt rid asgn wp = do
  (sl, env) <- dmlScope cache rid
  (pp, subs) <- rewriteMaybePred cache cnt [sl] wp
  let conj = maybe [] conjuncts pp
      (scan, left, _) = planSlotScan env [sl] 0 sl Nothing conj
      child = filterPlan left scan
      toPA a = case a of
                 RAssignLit v  -> PALit v
                 RAssignCol rc -> PACol (flatOfCol [sl] (rcFrom rc) (rcCol rc))
      assigns = [ (j, toPA a) | (j, a) <- asgn ]
  pure (withSubs (mkPlan (PUpdate rid assigns child)
                  (planCost child + fromIntegral (planRows child) * cpuOperatorCost)
                  (planRows child)) subs)

planDelete :: CatalogCache -> IORef Int -> RelId -> Maybe RPred -> IO Plan
planDelete cache cnt rid wp = do
  (child, subs) <- dmlChild cache cnt rid wp
  pure (withSubs (mkPlan (PDelete rid child)
                  (planCost child + fromIntegral (planRows child) * cpuOperatorCost)
                  (planRows child)) subs)

-- ---------------------------------------------------------------------------
-- Entry point (internal/08 §8.1)
-- ---------------------------------------------------------------------------
planStatement :: CatalogCache -> Analyzed -> IO Plan
planStatement cache a = do
  cnt <- newIORef 0
  case a of
    ASelect rs          -> planSelect cache cnt rs
    AInsert rid ords rows -> planInsert cache rid ords rows
    AUpdate rid asgn wp -> planUpdate cache cnt rid asgn wp
    ADelete rid wp      -> planDelete cache cnt rid wp
    ACreateTable cs     -> pure (mkPlan (PCreateTable cs) 0.0 0)
    ACreateIndex ci     -> pure (mkPlan (PCreateIndex ci) 0.0 0)
    ACopy rid wantIn    -> do
      mrd <- lookupById cache rid
      case mrd of
        Nothing -> throwSqlOf (errInternal
          "planner: COPY relation is not in the catalog")
        Just rd -> let ords = [0 .. length (rdColumns rd) - 1]
                   in if wantIn
                    -- COPY IN: the row stream comes from the wire, which a
                    -- pure Plan cannot carry; the session layer feeds it to
                    -- 'runInsert' in chunks (T43 deviation).  The empty-rows
                    -- plan exists so the pipeline stays uniform.
                      then pure (mkPlan (PInsert rid ords []) 0.0 0)
                    -- COPY OUT: a plain whole-relation scan; the session
                    -- installs a COPY-text sink.
                      else pure (mkPlan (PSeqScan rid)
                               (fromIntegral (rdTuples rd) * cpuOperatorCost)
                               (rdTuples rd))
    ATxnControl _       -> throwSqlOf (errInternal
      "planner: transaction control statements are handled by the session layer")









