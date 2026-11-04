-- | Catalog bootstrap + DDL primitives (internal-design/06 §6.2/6.4 +
--   design/06 §6.2/6.3).  Page 0 is a slotted page (header at 0..19,
--   kind PKCatalog) whose PAYLOAD at offset 20 carries the file header
--   (internal/06 §6.2 listing, offsets relative to 20; nextRelId u64 at
--   absolute 40).  The two bootstrap relations have fixed relids
--   (hask_class = 1, hask_attribute = 2) and describe themselves with
--   rows (self-describing bootstrap, like PostgreSQL's).
--   Deviations recorded in TODO.md (Phase 4):
--   * bootstrap writes page 0 and the two catalog heap pages DIRECTLY
--     (outside any transaction — the database is not open yet, docs §6.2
--     step order), then an initial checkpoint so recovery starts past it;
--   * DDL ops take (Env, CatalogCache, TxnCtx) explicitly (docs assume
--     the cache lives inside Env);
--   * the relid counter bump is logged as PPageUndo+PPageImage on page 0
--     plus the PCreateTable/PCreateIndex semantic record;
--   * CREATE TABLE/INDEX catalog-row writes go through the HEAP layer
--     (INSERT_TUPLE records), so an aborted DDL undoes its catalog rows.
module HaskDB.Catalog.Bootstrap where

import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.IO (openFile, hClose, IOMode(ReadMode))
import System.FilePath ((</>))
import Control.Monad (forM_, when)
import qualified Data.ByteString as BS
import Data.List (sortBy)
import Data.IORef (newIORef, readIORef)
import Data.Text (Text, pack)
import Data.Word
import HaskDB.Common.Types (PageId, RelId, RID(..), Value, compareSql)
import HaskDB.Common.Config (Config, cfgDataDir, cfgPageSize, cfgBufferFrames)
import HaskDB.Common.Error (throwSql)
import HaskDB.Server.Env (Env, envBufferPool, envConfig, envControl, envFileMgr, envFreeSpace, newEnv)
import HaskDB.Server.Control (ControlFile(..), writeControl)
import HaskDB.Storage.FileManager (openDataFile, extendFile, writePageBytes, readPageBytes)
import HaskDB.Storage.BufferPool (newBufferPool, withPageDirty, pinNewPage, unpinPage, ppPage)
import GHC.Internal.Conc.Sync (readTVarIO)
import HaskDB.Wal.Manager (newWalManager, flushWalUpTo)
import HaskDB.Wal.Recovery (runCheckpointWith, dataFileName, walFileName, controlFileName)
import HaskDB.Wal.Format (WalPayload(PCreateTable, PCreateIndex, PPageImage, PPageUndo, PAllocPage))
import HaskDB.Catalog.Types (classCols, attrCols, classRelId, attrRelId,
  classFirstPage, attrFirstPage, page0PayloadOff, page0NextRelOff, page0Magic,
  classTupleOf, attrTupleOf, RelationDesc(..), IndexDesc(..), RelKind(RelTable))
import HaskDB.Catalog.Cache (CatalogCache, loadCatalog, lookupById, lookupByName, classRowOf,
  stageCreateTable, stageCreateIndex, stageClassRow, stageSetRoot, descOfIndex)
import HaskDB.Heap.Heap (heapInsert, heapUpdate, heapScan)
import HaskDB.Heap.TupleCodec (ColumnDesc(..), encodeTuple)
import HaskDB.Storage.Page (PageRef(..), PageKind(PKCatalog, PKHeap), initPage,
  pageSplice, pageSlice, installPageImage, buildSlottedImage, readHeader,
  pageFreeContiguous)
import HaskDB.Storage.FreeSpace (fsmNoteFree)
import HaskDB.Common.Codec (runDecode, getW64le, getW32le, putW32le, putW64le, buildToBytes)
import HaskDB.Txn.Manager (TxnCtx, txnAppend, lockTable)
import HaskDB.Txn.LockManager (LockMode(LX))
import HaskDB.Index.BTree (btreeBuild)

-- ---------------------------------------------------------------------------
-- Bootstrap descriptors (rdPages = head page; chains loaded by loadCatalog)
-- ---------------------------------------------------------------------------
bootClassRel, bootAttrRel :: RelationDesc
bootClassRel = RelationDesc
  { rdId = classRelId, rdName = "hask_class", rdKind = RelTable
  , rdColumns = classCols, rdPages = [classFirstPage], rdRoot = 0
  , rdTuples = 0, rdOwner = 0, rdIdxCol = -1 }
bootAttrRel = RelationDesc
  { rdId = attrRelId, rdName = "hask_attribute", rdKind = RelTable
  , rdColumns = attrCols, rdPages = [attrFirstPage], rdRoot = 0
  , rdTuples = 0, rdOwner = 0, rdIdxCol = -1 }

-- | Fresh page-0 image: slotted header (PKCatalog) + file-header payload
--   (internal/06 §6.2 listing, laid at payload offset 0..20).
mkPage0Image :: Int -> RelId -> IO BS.ByteString
mkPage0Image ps nextRel = do
  r <- newIORef (BS.replicate ps 0)
  let pr = PageRef r
  initPage pr PKCatalog ps
  let payload = page0Magic
             <> buildToBytes (putW32le 1)                    -- formatVersion
             <> buildToBytes (putW32le (fromIntegral ps))    -- pageSize echo
             <> buildToBytes (putW32le (fromIntegral classFirstPage))
             <> buildToBytes (putW32le (fromIntegral attrFirstPage))
             <> buildToBytes (putW64le (fromIntegral nextRel))
      rest = ps - page0PayloadOff - BS.length payload
  if rest < 0
    then throwSql "XX000" "bootstrap: page 0 payload exceeds page size"
    else do
      pageSplice pr page0PayloadOff (ps - page0PayloadOff)
        (payload <> BS.replicate rest 0)
      readIORef r

-- | Build one catalog heap page image; Nothing = rows do not fit.
catalogHeapImage :: Int -> [BS.ByteString] -> IO BS.ByteString
catalogHeapImage ps rows = do
  m <- buildSlottedImage ps PKHeap 0 0 rows
  case m of
    Just img -> pure img
    Nothing -> throwSql "XX000" "bootstrap: catalog rows do not fit one page"

-- ---------------------------------------------------------------------------
-- createDatabase (internal/06 §6.2): init page 0, create the catalog heaps
--   (one page each, OUTSIDE any transaction), then checkpoint.  Recovery
--   must not re-apply bootstrap content — nothing of it is in the WAL, and
--   the checkpoint advances the boundary.
-- ---------------------------------------------------------------------------
createDatabase :: Config -> CatalogCache -> IO Env
createDatabase cfg cache = do
  let dir = cfgDataDir cfg
      ps  = cfgPageSize cfg
  createDirectoryIfMissing True dir
  let dataPath = dir </> dataFileName
      walPath  = dir </> walFileName
      ctlPath  = dir </> controlFileName
  fm <- openDataFile dataPath ps
  wal <- newWalManager walPath
  let ctl0 = ControlFile { cfPageSize = ps, cfCheckpointLSN = 0, cfNextTid = 1 }
  writeControl ctlPath ctl0
  bp <- newBufferPool ps (cfgBufferFrames cfg) fm (\l -> flushWalUpTo wal l)
  env <- newEnv cfg ctlPath ctl0 fm wal bp
  -- pages 0,1,2 materialised (zero-filled by extendFile)
  _p0 <- extendFile fm
  _p1 <- extendFile fm
  _p2 <- extendFile fm
  img0 <- mkPage0Image ps 3     -- relids 1,2 used => nextRelId = 3
  writePageBytes fm 0 img0
  classImg <- catalogHeapImage ps
    [ encodeTuple classCols (classTupleOf bootClassRel)
    , encodeTuple classCols (classTupleOf bootAttrRel) ]
  writePageBytes fm classFirstPage classImg
  attrImg <- catalogHeapImage ps
    (concatMap (\(rid, cols) -> map (encodeTuple attrCols)
                  (attrTupleOf rid cols))
               [ (classRelId, classCols), (attrRelId, attrCols) ])
  writePageBytes fm attrFirstPage attrImg
  bootstrapCheckpoint env
  loadCatalog env cache
  pure env

-- | Initial checkpoint after bootstrap (docs §6.2 step 4).
bootstrapCheckpoint :: Env -> IO ()
bootstrapCheckpoint env = do
  ctl <- readTVarIO (envControl env)
  -- nothing can be active at bootstrap, so the §3.5 step-1 snapshot is empty
  -- and the control file's nextTid is the one nothing has bumped.
  runCheckpointWith env (pure ([], cfNextTid ctl))

-- | internal/11 §11.2/§11.4: page 0 echoes the page size (internal/06
--   §6.2's file-header listing) and that echo must be cross-checked AT OPEN
--   against the control file, else two databases written with different page
--   sizes are silently mixed.  The docs attribute the check to @readControl@,
--   whose signature cannot see the data file, so it lives here; it takes the
--   @Config@ + the just-parsed @ControlFile@ and reads the RAW file, because
--   §11.2's ordering puts the check BEFORE any replay (a mismatched replay
--   would already have written wrongly-aligned page images) and the FileManager
--   handle only exists after recovery (logged deviation).
checkPage0 :: Config -> ControlFile -> IO ()
checkPage0 cfg ctl
  | cfPageSize ctl /= cfgPageSize cfg =
      throwSql "XX000"
        ("open: the control file's pageSize " <> pack (show (cfPageSize ctl))
        <> " disagrees with the configuration's "
        <> pack (show (cfgPageSize cfg)))
  | otherwise = do
      let ps = cfPageSize ctl
          path = cfgDataDir cfg </> dataFileName
      exists <- doesFileExist path
      if not exists
        then pure ()        -- no data file yet: nothing to cross-check
        else do
          h <- openFile path ReadMode
          bs <- BS.hGet h ps                      -- page 0 sits at offset 0
          hClose h
          if BS.length bs < ps
            then throwSql "XX000"
              "open: the data file is shorter than one page (pageSize mismatch?)"
            else if BS.take 4 (BS.drop page0PayloadOff bs) /= page0Magic
              then throwSql "XX000"
                "open: page 0 is not a bootstrapped HaskDB page-0 (magic missing)"
              else case runDecode getW32le
                     (BS.take 4 (BS.drop (page0PayloadOff + 8) bs)) of
                Left e -> throwSql "XX000"
                  ("open: page 0's file header is unreadable: " <> e)
                Right w
                  | w /= (fromIntegral ps :: Word32) ->
                      throwSql "XX000"
                        ("open: page 0's pageSize " <> pack (show w)
                        <> " disagrees with the control file's "
                        <> pack (show ps))
                  | otherwise -> pure ()

-- | Allocate the next relation id: page-0 counter bump logged with the
--   before/after images of page 0 (undo restores the counter on abort; a
--   committed bump past a crash replays via redo of PPageImage).
allocRelId :: Env -> TxnCtx -> IO RelId
allocRelId env ctx = withPageDirty (envBufferPool env) 0 $ \pr -> do
  let ps = cfgPageSize (envConfig env)
  cur <- pageSlice pr 0 ps
  next <- case runDecode getW64le (BS.take 8 (BS.drop page0NextRelOff cur)) of
            Left e  -> throwSql "XX000" ("catalog: page 0 relid counter corrupt: " <> e)
            Right w -> pure (fromIntegral (w :: Word64))
  new <- pure (BS.take page0NextRelOff cur
            <> buildToBytes (putW64le (fromIntegral (next + 1)))
            <> BS.drop (page0NextRelOff + 8) cur)
  _u <- txnAppend ctx (PPageUndo 0 cur)
  li <- txnAppend ctx (PPageImage 0 new)
  installPageImage pr new li
  pure next

-- | Write the relation's hask_class row through the heap layer (WAL-logged
--   INSERT_TUPLE) and stage its RID for later counter/root updates.
insertClassRow :: Env -> CatalogCache -> TxnCtx -> RelationDesc -> IO ()
insertClassRow env cache ctx rd = do
  mcls <- lookupById cache classRelId
  case mcls of
    Nothing -> throwSql "XX000" "catalog: hask_class relation missing"
    Just cls -> do
      rowRid <- heapInsert env ctx cls (classTupleOf rd)
      stageClassRow cache ctx (rdId rd) rowRid

-- | Write the relation's hask_attribute rows (WAL-logged).
insertAttrRows :: Env -> CatalogCache -> TxnCtx -> RelationDesc -> IO ()
insertAttrRows env cache ctx rd = do
  mattr <- lookupById cache attrRelId
  case mattr of
    Nothing -> throwSql "XX000" "catalog: hask_attribute relation missing"
    Just attrs -> forM_ (attrTupleOf (rdId rd) (rdColumns rd))
      (\t -> heapInsert env ctx attrs t >> pure ())

-- | CREATE TABLE allocates the relation's FIRST heap page immediately
--   (internal/06 §6.3 "INSERT ... allocates + relpages_head" collapsed at
--   DDL time so relpages_head is never 0 for a live table; the heap
--   layer's heapAllocPage then chains further pages onto it; deviation
--   recorded in TODO.md).
allocFirstHeapPage :: Env -> TxnCtx -> RelId -> IO PageId
allocFirstHeapPage env ctx rid = do
  pid <- extendFile (envFileMgr env)
  _ <- txnAppend ctx (PAllocPage pid rid)
  pp <- pinNewPage (envBufferPool env) pid PKHeap
  hdr <- readHeader (ppPage pp)
  fsmNoteFree (envFreeSpace env) rid pid (pageFreeContiguous hdr)
  unpinPage (envBufferPool env) pp True
  pure pid

-- ---------------------------------------------------------------------------
-- DDL (design/06 §6.4 flows; design/03 §3.2: DDL takes the X lock —
-- deviation: we take X on the NEW relid and, for CREATE INDEX, on the
-- OWNING table too so the bulk heapScan cannot race concurrent DML).
-- CREATE TABLE/INDEX must run in the caller's transaction.
-- ---------------------------------------------------------------------------
createTableDDL :: Env -> CatalogCache -> TxnCtx -> Text -> [ColumnDesc]
               -> IO RelationDesc
createTableDDL env cache ctx nm cols = do
  dupe <- lookupByName cache nm
  case dupe of
    Just rd -> throwSql "XX000"
      ("catalog: duplicate relation name: " <> nm <> " (" <> rdName rd <> ")")
    Nothing -> pure ()
  rid <- allocRelId env ctx
  lockTable ctx rid LX
  pg <- allocFirstHeapPage env ctx rid
  let rd = RelationDesc { rdId = rid, rdName = nm, rdKind = RelTable
                        , rdColumns = cols, rdPages = [pg], rdRoot = 0
                        , rdTuples = 0, rdOwner = 0, rdIdxCol = -1 }
  _c <- txnAppend ctx (PCreateTable rid nm cols)
  insertClassRow env cache ctx rd
  insertAttrRows env cache ctx rd
  stageCreateTable cache ctx rd
  pure rd

-- | CREATE INDEX: bulk-build a B+-tree over the current table rows
--   (design/06 §6.4 + design/04 §4.4 "the index is built with CREATE
--   INDEX from the existing rows").
createIndexDDL :: Env -> CatalogCache -> TxnCtx -> Text -> RelationDesc -> Int
               -> IO IndexDesc
createIndexDDL env cache ctx ixNm tbl colOrd = do
  dupe <- lookupByName cache ixNm
  case dupe of
    Just _ -> throwSql "XX000" ("catalog: duplicate relation name: " <> ixNm)
    Nothing -> pure ()
  let cols = rdColumns tbl
  when (colOrd < 0 || colOrd >= length cols) $
    throwSql "XX000" "catalog: index column ordinal out of range"
  lockTable ctx (rdId tbl) LX
  rid <- allocRelId env ctx
  lockTable ctx rid LX
  let kt = colType (cols !! colOrd)
  rows <- heapScan env ctx tbl
  let keys = [ (t !! colOrd, r) | (r, t) <- rows, colOrd < length t ]
      sorted = sortBy cmpKV keys
  root <- btreeBuild env ctx rid kt sorted
  let ix = IndexDesc { ixRelId = rid, ixName = ixNm
                     , ixTable = rdId tbl, ixColumn = colOrd
                     , ixKeyType = kt, ixRoot = root }
  _c <- txnAppend ctx (PCreateIndex rid ixNm (rdId tbl) colOrd root)
  insertClassRow env cache ctx (descOfIndex ix)
  stageCreateIndex cache ctx ix
  pure ix

cmpKV :: (Value, RID) -> (Value, RID) -> Ordering
cmpKV (k1, r1) (k2, r2) = case compareSql k1 k2 of
  EQ -> compare r1 r2
  c  -> c

-- | Publish a root split: UPDATE the index's hask_class row on disk
--   (WAL-logged heapUpdate) and stage the cache rdRoot (design/04 §4.4
--   "a root split ... updates the catalog index_root for the index
--   (WAL-logged)").  Same transaction as the INSERT that caused it.
updateIndexRoot :: Env -> CatalogCache -> TxnCtx -> RelId -> PageId -> IO ()
updateIndexRoot env cache ctx idxRel newRoot = do
  mrd <- lookupById cache idxRel
  case mrd of
    Nothing -> throwSql "XX000" "catalog: index relation missing"
    Just rd0 -> do
      mrow <- classRowOf cache idxRel
      case mrow of
        Nothing -> throwSql "XX000" "catalog: index class row missing"
        Just rowRid -> do
          mcls <- lookupById cache classRelId
          case mcls of
            Nothing -> throwSql "XX000" "catalog: hask_class missing"
            Just cls -> do
              let rd = rd0 { rdRoot = newRoot }
              heapUpdate env ctx cls rowRid (classTupleOf rd)
              stageSetRoot cache ctx idxRel newRoot
