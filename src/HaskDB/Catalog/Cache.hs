-- | In-memory catalog cache (internal-design/06 §6.3 + design/06 §6.5).
--   DML/DDL never mutate ccState directly: changes are staged as closures
--   in the TxnCtx (internal/06 §6.3 staging model) and applied at commit
--   by commitTxn after the WAL flush; aborts discard them.  Deviations
--   recorded in TODO.md: ccRows and ccLatches are extra cache fields
--   (class-row RIDs and internal/05 §5.2 per-index latches); stage*
--   functions take the cache receiver explicitly because our cache does
--   NOT live inside Env (internal/11 §11.2 assumption, see Server.Env).
module HaskDB.Catalog.Cache where

import qualified Data.Map.Strict as Map
import Control.Monad (forM_, when)
import Data.List (sortOn)
import Control.Monad.STM (atomically)
import GHC.Internal.Conc.Sync (TVar, newTVarIO, readTVar, writeTVar, readTVarIO)
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar)
import Data.Word
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8Lenient)
import HaskDB.Common.Types (RelId, RID(..), PageId, Tuple, Value(VInt, VText), SqlType(TyInt64))
import HaskDB.Common.Error (throwSql)
import HaskDB.Server.Env (Env, envBufferPool, envFreeSpace)
import HaskDB.Storage.BufferPool (withPage)
import HaskDB.Storage.Page (readHeader, PageHeader(..), liveSlots, pageReadTuple)
import HaskDB.Catalog.Types (RelationDesc(..), IndexDesc(..), indexDescOf, RelKind(RelTable, RelIndex)
  , classCols, attrCols, classFirstPage, attrFirstPage
  , classTupleToDesc, codeToSqlType)
import HaskDB.Heap.TupleCodec (ColumnDesc(..), decodeTuple)
import HaskDB.Txn.Manager (TxnCtx, stageAppend)
import HaskDB.Wal.Format (WalPayload(..))
import HaskDB.Storage.FreeSpace (fsmRebuild)

data CacheState = CacheState
  { csById   :: !(Map.Map RelId RelationDesc)
  , csByName :: !(Map.Map Text RelId) }
  deriving (Eq, Show)

data CatalogCache = CatalogCache
  { ccState   :: TVar CacheState
  , ccVersion :: TVar Word64          -- bumped by every applied staged update
  , ccRows    :: TVar (Map.Map RelId RID)      -- hask_class row per relation
  , ccLatches :: MVar (Map.Map RelId (MVar ())) -- per-index split latches (§5.2)
  }

newCatalogCache :: IO CatalogCache
newCatalogCache = CatalogCache
  <$> newTVarIO CacheState { csById = Map.empty, csByName = Map.empty }
  <*> newTVarIO 0
  <*> newTVarIO Map.empty
  <*> newMVar Map.empty

lookupByName :: CatalogCache -> Text -> IO (Maybe RelationDesc)
lookupByName cc nm = do
  st <- readTVarIO (ccState cc)
  case Map.lookup nm (csByName st) of
    Nothing  -> pure Nothing
    Just rid -> pure (Map.lookup rid (csById st))

lookupById :: CatalogCache -> RelId -> IO (Maybe RelationDesc)
lookupById cc rid = do
  st <- readTVarIO (ccState cc)
  pure (Map.lookup rid (csById st))

indexesOf :: CatalogCache -> RelId -> IO [IndexDesc]
indexesOf cc tbl = do
  st <- readTVarIO (ccState cc)
  pure [ d | rd <- Map.elems (csById st)
           , rdOwner rd == tbl
           , d <- maybe [] pure (indexDescOf rd) ]

catalogVersion :: CatalogCache -> IO Word64
catalogVersion cc = readTVarIO (ccVersion cc)

-- | Direct (non-staged) insertion — ONLY for startup (loadCatalog) and
--   bootstrap paths outside any transaction.  The RID is the relation's
--   hask_class row RID (RID 0 0 = unknown, e.g. WAL replay).
ccInsert :: CatalogCache -> RelationDesc -> RID -> IO ()
ccInsert cc rd rowRid = atomically $ do
  st <- readTVar (ccState cc)
  writeTVar (ccState cc)
    st { csById = Map.insert (rdId rd) rd (csById st)
       , csByName = Map.insert (rdName rd) (rdId rd) (csByName st) }
  when (rowRid /= RID 0 0) $ do
    old <- readTVar (ccRows cc)
    writeTVar (ccRows cc) (Map.insert (rdId rd) rowRid old)
  v <- readTVar (ccVersion cc)
  writeTVar (ccVersion cc) (v + 1)

ccReplace :: CatalogCache -> RelationDesc -> IO ()
ccReplace cc rd = atomically $ do
  st <- readTVar (ccState cc)
  writeTVar (ccState cc)
    st { csById = Map.insert (rdId rd) rd (csById st)
       , csByName = Map.insert (rdName rd) (rdId rd) (csByName st) }

-- | DDL staging (internal/06 §6.3): registered in the TxnCtx, applied at
--   commit by commitTxn; each application bumps the catalog version.
stageCreateTable :: CatalogCache -> TxnCtx -> RelationDesc -> IO ()
stageCreateTable cc ctx rd = stageAppend ctx (applyCreate cc rd)

stageCreateIndex :: CatalogCache -> TxnCtx -> IndexDesc -> IO ()
stageCreateIndex cc ctx ix = stageAppend ctx (applyCreate cc (descOfIndex ix))

applyCreate :: CatalogCache -> RelationDesc -> IO ()
applyCreate cc rd = atomically $ do
  st <- readTVar (ccState cc)
  writeTVar (ccState cc)
    st { csById = Map.insert (rdId rd) rd (csById st)
       , csByName = Map.insert (rdName rd) (rdId rd) (csByName st) }
  v <- readTVar (ccVersion cc)
  writeTVar (ccVersion cc) (v + 1)

descOfIndex :: IndexDesc -> RelationDesc
descOfIndex ix = RelationDesc
  { rdId = ixRelId ix, rdName = ixName ix, rdKind = RelIndex
  , rdColumns = [ColumnDesc (ixName ix) (ixKeyType ix)]
  , rdPages = [], rdRoot = ixRoot ix, rdTuples = 0
  , rdOwner = ixTable ix, rdIdxCol = ixColumn ix }

indexDescOfRel :: RelationDesc -> Maybe IndexDesc
indexDescOfRel rd
  | rdKind rd == RelIndex =
      Just IndexDesc { ixRelId = rdId rd, ixName = rdName rd
                     , ixTable = rdOwner rd, ixColumn = rdIdxCol rd
                     , ixKeyType = case rdColumns rd of
                         (c : _) -> colType c
                         []      -> TyInt64
                     , ixRoot = rdRoot rd }
  | otherwise = Nothing

-- | Append one heap page to a relation's page list, staged (applied at COMMIT
--   only, internal/06 §6.3).  IDempotent: one COPY/INSERT statement may stage
--   the same page several times (its chunks each walk the chain against the
--   frozen pre-txn page list), and listing a page twice would scan its tuples
--   twice — a live-vs-durable count mismatch, i.e. a design/00 §0.7 violation.
stageAllocPage :: CatalogCache -> TxnCtx -> RelId -> PageId -> IO ()
stageAllocPage cc ctx rid pg = stageAppend ctx $ atomically $ do
  st <- readTVar (ccState cc)
  writeTVar (ccState cc)
    st { csById = Map.adjust (\rd -> if pg `elem` rdPages rd
                                        then rd
                                        else rd { rdPages = rdPages rd ++ [pg] })
                  rid (csById st) }
  v <- readTVar (ccVersion cc)
  writeTVar (ccVersion cc) (v + 1)

stageTupleDelta :: CatalogCache -> TxnCtx -> RelId -> Int64 -> IO ()
stageTupleDelta cc ctx rid delta = stageAppend ctx $ atomically $ do
  st <- readTVar (ccState cc)
  writeTVar (ccState cc)
    st { csById = Map.adjust (\rd -> rd { rdTuples = rdTuples rd + delta })
                  rid (csById st) }
  v <- readTVar (ccVersion cc)
  writeTVar (ccVersion cc) (v + 1)

stageSetRoot :: CatalogCache -> TxnCtx -> RelId -> PageId -> IO ()
stageSetRoot cc ctx rid root = stageAppend ctx $ atomically $ do
  st <- readTVar (ccState cc)
  writeTVar (ccState cc)
    st { csById = Map.adjust (\rd -> rd { rdRoot = root }) rid (csById st) }
  v <- readTVar (ccVersion cc)
  writeTVar (ccVersion cc) (v + 1)

stageClassRow :: CatalogCache -> TxnCtx -> RelId -> RID -> IO ()
stageClassRow cc ctx rid rowRid = stageAppend ctx $ atomically $ do
  old <- readTVar (ccRows cc)
  writeTVar (ccRows cc) (Map.insert rid rowRid old)

classRowOf :: CatalogCache -> RelId -> IO (Maybe RID)
classRowOf cc rid = Map.lookup rid <$> readTVarIO (ccRows cc)

-- | Replay CREATE_* WAL payloads into the cache (internal/06 §6.1 seam).
--   Recovery primarily reloads from the catalog heaps (committed tuple
--   records cover them); this keeps relations whose catalog rows fall
--   outside the reload window.  Idempotent, so replay is harmless.
applyCatalogRecords :: CatalogCache -> [WalPayload] -> IO ()
applyCatalogRecords cc pls = forM_ pls $ \p -> case p of
  PCreateTable rid nm cols -> do
    m <- lookupById cc rid
    case m of
      Just _  -> pure ()
      Nothing -> ccInsert cc RelationDesc
        { rdId = rid, rdName = nm, rdKind = RelTable
        , rdColumns = cols, rdPages = [], rdRoot = 0, rdTuples = 0
        , rdOwner = 0, rdIdxCol = -1 } (RID 0 0)
  PCreateIndex rid nm tbl col root -> do
    kt <- keyTypeOf cc tbl col
    case kt of
      Just ty -> ccInsert cc (descOfIndex
        IndexDesc { ixRelId = rid, ixName = nm, ixTable = tbl
                  , ixColumn = col, ixKeyType = ty, ixRoot = root }) (RID 0 0)
      Nothing -> pure ()
  _ -> pure ()
  where
    keyTypeOf cc' tbl' col' = do
      m <- lookupById cc' tbl'
      case m of
        Nothing -> pure Nothing
        Just rd -> let cols = rdColumns rd
                   in if col' >= 0 && col' < length cols
                        then pure (Just (colType (cols !! col')))
                        else pure Nothing

-- | Per-index structural latch (internal/05 §5.2 ihLatch), created on
--   demand so every handle of a relation shares one MVar.
btreeLatch :: CatalogCache -> RelId -> IO (MVar ())
btreeLatch cc rid = modifyMVar (ccLatches cc) $ \ls ->
  case Map.lookup rid ls of
    Just mv -> pure (ls, mv)
    Nothing -> do
      mv <- newMVar ()
      pure (Map.insert rid mv ls, mv)

-- ---------------------------------------------------------------------------
-- Startup cache (re)load from the catalog heaps (internal/06 §6.2 open
--   flow, docs §6.3 name loadCatalog).  Follows the phNext chains, parses
--   self-describing rows, rebuilds rdColumns (from hask_attribute) and
--   full page lists, and seeds the free-space map.  Deviation: loadCatalog
--   lives in Cache (docs) but the class-row scan helpers are shared with
--   Bootstrap through Catalog.Types constants only, so no cycle.
-- ---------------------------------------------------------------------------
followChain :: Env -> PageId -> IO [PageId]
followChain env p0
  | p0 == 0 = pure []
  | otherwise = do
      nxt <- withPage (envBufferPool env) p0 $ \pr -> do
        hdr <- readHeader pr
        pure (phNext hdr)
      (p0 :) <$> followChain env nxt

scanCatalogPages :: Env -> [PageId] -> [ColumnDesc] -> IO [(RID, Tuple)]
scanCatalogPages env pages cols = concat <$> mapM scanPage pages
  where
    scanPage p = withPage (envBufferPool env) p $ \pr -> do
      sls <- liveSlots pr
      pairs <- mapM (slotOf p pr) sls
      pure [ x | Just x <- pairs ]
    slotOf p pr (s, _, _) = do
      b <- pageReadTuple pr s
      case decodeTuple cols b of
        Left e  -> throwSql "XX000" ("corrupt catalog tuple: " <> e)
        Right t -> pure (Just (RID p s, t))

loadCatalog :: Env -> CatalogCache -> IO ()
loadCatalog env cache = do
  cpgs <- followChain env classFirstPage
  apgs <- followChain env attrFirstPage
  crows <- scanCatalogPages env cpgs classCols
  arows <- scanCatalogPages env apgs attrCols
  let base = [ (rdId d, (d, rowRid)) | (rowRid, t) <- crows
             , Just d <- [classTupleToDesc t] ]
      attrsQ = [ (aRel, (n, nm, ty)) | (_, t) <- arows
               , aRel <- [i64 0 t], n <- [i64 1 t]
               , Just nm <- [tName 2 t]
               , Just ty <- [codeToSqlType (fromIntegral (i64 3 t))] ]
  forM_ base $ \(rid, (rd0, rowRid)) ->
    case rdKind rd0 of
      RelTable -> do
        let attrs = sortOn (\(n, _, _) -> n)
                         [ a | (r, a) <- attrsQ, r == rid ]
            cols = [ ColumnDesc nm ty | (_, nm, ty) <- attrs ]
            rd = rd0 { rdColumns = cols }
        pages <- expandPages env rd
        ccInsert cache rd { rdPages = pages } rowRid
        fsmRebuild (envFreeSpace env) (envBufferPool env) rid pages
      RelIndex -> pure ()   -- second pass, tables first
  let tblColsMap = Map.fromList
        [ (rid, [ ColumnDesc nm ty | (_, nm, ty) <- sortOn (\(n, _, _) -> n)
                              [ a | (r, a) <- attrsQ, r == rid ] ])
        | (rid, (rd0, _)) <- base, rdKind rd0 == RelTable ]
  forM_ base $ \(_, (rd0, rowRid)) ->
    when (rdKind rd0 == RelIndex) $ do
      let kt = case [ colType (cols !! ci)
                     | tCols <- [Map.lookup (rdOwner rd0) tblColsMap]
                     , Just cols <- [tCols]
                     , let ci = rdIdxCol rd0
                     , ci >= 0, ci < length cols ]
                 of
                   (ty : _) -> Just ty
                   []       -> Nothing
      case kt of
        Just ty -> ccInsert cache rd0 { rdColumns = [ColumnDesc (rdName rd0) ty] } rowRid
        Nothing -> throwSql "XX000"
          "catalog: index column type unresolvable (owner table missing)"
  where
    expandPages ev rd = case rdPages rd of
      (p : _) -> followChain ev p
      []      -> pure []
    i64 n t = case drop n t of
      (VInt x : _) -> x
      _            -> 0
    tName n t = case drop n t of
      (VText s : _) -> Just (decodeUtf8Lenient s)
      _             -> Nothing
