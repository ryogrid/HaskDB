-- | Heap operations with transaction integration (internal-design/01 §1.8
--   flows + design/03 §3.2 row locking).  Invariants:
--   * WAL record via txnAppend BEFORE any page mutation (design/02 §2.4
--     durability rule — frames only reach the file after their WAL LSN),
--   * row locks: X on write targets, S on fetch, taken on the target RID
--     BEFORE the page is touched.  Deviation: internal/01 §1.8 step 8
--     takes the X lock after the page write; before is strictly stronger
--     (no dirty-read window under steal/no-force), TODO.md log,
--   * scan is lock-free at the storage level (deviation: design/03 §3.4's
--     "S per returned tuple" is an executor call site, document 09),
--   * compact-on-insert logs BOTH a PAGE_IMAGE (new layout) and the
--     INSERT_TUPLE: redo installs the image then the insert re-places
--     (pageSetTuple no-op guard), undo deletes the slot (undo-never-
--     installs-image rule) — both orders land on the same logical state
--     (the scratch-copy pattern of §1.4, TODO.md log),
--   * update-grow replays deterministically via the UPDATE_TUPLE record
--     (no extra image; §3.4 guards = phLsn + content), TODO.md note.
module HaskDB.Heap.Heap where

import qualified Data.ByteString as BS
import Control.Monad (when)
import Data.Maybe (isJust, fromJust)
import Data.IORef (newIORef, readIORef)
import HaskDB.Common.Types (PageId, RID(..), Tuple)
import HaskDB.Common.Config (Config(cfgPageSize))
import HaskDB.Common.Error (throwSql)
import HaskDB.Server.Env (Env, envBufferPool, envFileMgr, envFreeSpace, envConfig)
import HaskDB.Catalog.Types (RelationDesc(rdId, rdColumns, rdPages))
import HaskDB.Heap.TupleCodec (encodeTuple, decodeTuple, checkInsertableIO)
import HaskDB.Storage.Page (PageRef(..), PageKind(PKHeap), readHeader, writeHeader,
  PageHeader(phNext, phKind), itemSize, pageUpdateTuple, pageDeleteTuple,
  pageSetTuple, installPageImage, pageFreeContiguous, pageFragmentedFree, readSlot,
  pageSlice, pageReadTuple, pageFrameLen, findUnusedSlot, slotCount)
import HaskDB.Storage.FileManager (extendFile)
import HaskDB.Storage.BufferPool (withPage, withPageDirty, pinNewPage, unpinPage)
import HaskDB.Storage.FreeSpace (fsmFindPage, fsmNoteFree)
import HaskDB.Txn.Manager (TxnCtx, txnAppend, lockRow, lockTable)
import HaskDB.Txn.LockManager (LockMode(LS, LX, LIx))
import HaskDB.Wal.Format (WalPayload(PInsertTuple, PDeleteTuple, PUpdateTuple, PAllocPage, PPageImage))

-- | New heap page: extend the file, WAL ALLOC_PAGE before first use,
--   init under pin, chain from the relation's current last page — the
--   predecessor's PAGE_IMAGE is built on a scratch copy, logged, THEN
--   installed (WAL-before-mutation, design/02 §2.4; internal/01 §1.8 step 3).
heapAllocPage :: Env -> TxnCtx -> RelationDesc -> IO PageId
heapAllocPage env ctx rel = do
  pid <- extendFile (envFileMgr env)
  _ <- txnAppend ctx (PAllocPage pid (rdId rel))
  let bp = envBufferPool env
  pp <- pinNewPage bp pid PKHeap
  unpinPage bp pp True
  case reverse (rdPages rel) of
    (prev : _) -> withPageDirty bp prev $ \pr -> do
      PageRef r <- pure pr
      img <- readIORef r
      sr <- newIORef img
      let spr = PageRef sr
      hdr <- readHeader spr
      writeHeader spr hdr { phNext = pid }
      newImg <- readIORef sr
      lsn <- txnAppend ctx (PPageImage prev newImg)
      installPageImage pr newImg lsn
    [] -> pure ()
  pure pid

-- | FSM note after a mutation: record the page's remaining contiguous
--   free space (advisory; internal/01 §1.8 last steps).
noteFree :: Env -> RelationDesc -> PageId -> PageRef -> IO ()
noteFree env rel pid pr = do
  hdr <- readHeader pr
  fsmNoteFree (envFreeSpace env) (rdId rel) pid (pageFreeContiguous hdr)

-- | Insert on an advisory target page.  Returns Nothing when the page
--   could not take the tuple at this point (retry / fresh-page fallback
--   path).  Slot pick happens under a READ pin; the X row lock is taken
--   with NO frame lock held; the mutation happens under the frame WRITE
--   lock (row-then-frame order everywhere — review MUST-FIX #7 closed),
--   with bounded re-selection when another inserter took the slot first.
insertOnPage :: Env -> TxnCtx -> RelationDesc -> PageId -> BS.ByteString -> Int -> IO (Maybe RID)
insertOnPage env ctx rel pid bytes need = go (3 :: Int)
  where
    bp = envBufferPool env
    relId = rdId rel
    go n
      | n <= (0 :: Int) = pure Nothing
      | otherwise = do
          pick <- withPage bp pid $ \pr -> do
            hdr <- readHeader pr
            if phKind hdr /= PKHeap
              then pure Nothing
              else do
                ms <- findUnusedSlot pr
                let s = case ms of Just x -> x; Nothing -> slotCount hdr
                pure (Just (s, pageFreeContiguous hdr))
          case pick of
            Nothing -> pure Nothing
            Just (s, free)
              | free < need ->
                  fitsAfterCompact >>= \ok ->
                    if ok then placeLocked s n else pure Nothing
              | otherwise -> placeLocked s n
    fitsAfterCompact = withPage bp pid $ \pr -> do
      sz <- pageFrameLen pr
      frag <- pageFragmentedFree pr sz
      pure (frag >= need)
    placeLocked s n = do
      let rid = RID pid s
      lockRow ctx relId rid LX
      res <- withPageDirty bp pid $ \pr -> do
        hdr2 <- readHeader pr
        ms2 <- findUnusedSlot pr
        let s2 = case ms2 of Just x -> x; Nothing -> slotCount hdr2
            free2 = pageFreeContiguous hdr2
        if s2 /= s
          then pure Nothing
          else if free2 >= need
            then do
              lsn <- txnAppend ctx (PInsertTuple pid s bytes)
              pageSetTuple pr lsn s bytes
              noteFree env rel pid pr
              pure (Just rid)
            else scratchPlace rid s pr
      case res of
        Just r  -> pure (Just r)
        Nothing -> go (n - 1)
    -- scratch-copy placement (§1.4): copy the image, compact+place on the
    -- scratch, log PAGE_IMAGE + INSERT_TUPLE, then install — WAL before
    -- any mutation of the real frame.
    scratchPlace rid s pr = do
      PageRef r <- pure pr
      img <- readIORef r
      sr <- newIORef img
      let spr = PageRef sr
      sz <- pageFrameLen pr
      frag <- pageFragmentedFree pr sz
      if frag < need
        then pure Nothing
        else do
          hdrS <- readHeader spr
          msS <- findUnusedSlot spr
          let sS = case msS of Just x -> x; Nothing -> slotCount hdrS
          if sS /= s
            then pure Nothing
            else do
              pageSetTuple spr 0 s bytes   -- compacts on the scratch copy
              newImg <- readIORef sr
              lsnImg <- txnAppend ctx (PPageImage pid newImg)
              lsnIns <- txnAppend ctx (PInsertTuple pid s bytes)
              installPageImage pr newImg lsnImg
              pageSetTuple pr lsnIns s bytes  -- content no-op guard
              noteFree env rel pid pr
              pure (Just rid)

-- | heapInsert flow (internal/01 §1.8 steps 1-9).  54000 only when even
--   a freshly allocated page rejects the tuple (docs step-5 -> step-3
--   fallback loop; review MUST-FIX #6).
heapInsert :: Env -> TxnCtx -> RelationDesc -> Tuple -> IO RID
heapInsert env ctx rel tup = do
  let fsm = envFreeSpace env
      relId = rdId rel
      cols = rdColumns rel
      ps = cfgPageSize (envConfig env)
  checkInsertableIO ps cols tup
  let bytes = encodeTuple cols tup
      need = BS.length bytes + itemSize
  lockTable ctx relId LIx                  -- table intention (design/03 §3.2)
  mc <- fsmFindPage fsm relId need
  r1 <- case mc of
          Just p  -> insertOnPage env ctx rel p bytes need
          Nothing -> pure Nothing
  if isJust r1
    then pure (fromJust r1)
    else do
      pid <- heapAllocPage env ctx rel
      r2 <- insertOnPage env ctx rel pid bytes need
      case r2 of
        Just r  -> pure r
        Nothing -> throwSql "54000"
                     "tuple does not fit even a fresh page"

-- | heapUpdate flow (internal/01 §1.8, same-RID/same-page rule of
--   design/01 §1.5).  Grow beyond the slot = move-within-page via the
--   page layer's compact path; redo/undo replay the UPDATE record with
--   guards (no image record needed — placement is deterministic).
heapUpdate :: Env -> TxnCtx -> RelationDesc -> RID -> Tuple -> IO ()
heapUpdate env ctx rel rid tup = do
  let bp = envBufferPool env
      relId = rdId rel
      cols = rdColumns rel
      pid = ridPage rid
      n = ridSlot rid
  lockTable ctx relId LIx
  lockRow ctx relId rid LX
  let newB = encodeTuple cols tup
  withPageDirty bp pid $ \pr -> do
    ms <- readSlot pr n
    case ms of
      Just (off, len) -> do
        oldB <- pageSlice pr off len
        hdr <- readHeader pr
        sz <- pageFrameLen pr
        let newLen = BS.length newB
        when (newLen > len + pageFreeContiguous hdr) $
          throwSql "54000" "updated tuple too large for page (same-RID rule)"
        lsn <- txnAppend ctx (PUpdateTuple pid n oldB newB)
        pageUpdateTuple pr lsn sz n newB
        noteFree env rel pid pr
      Nothing -> throwSql "XX000" "heapUpdate: row slot not live"

-- | heapDelete flow (internal/01 §1.8): WAL before mutation.
heapDelete :: Env -> TxnCtx -> RelationDesc -> RID -> IO ()
heapDelete env ctx rel rid = do
  let bp = envBufferPool env
      relId = rdId rel
      pid = ridPage rid
      n = ridSlot rid
  lockTable ctx relId LIx
  lockRow ctx relId rid LX
  withPageDirty bp pid $ \pr -> do
    ms <- readSlot pr n
    case ms of
      Just _ -> do
        oldB <- pageReadTuple pr n
        lsn <- txnAppend ctx (PDeleteTuple pid n oldB)
        pageDeleteTuple pr lsn n
        noteFree env rel pid pr
      Nothing -> throwSql "XX000" "heapDelete: row slot not live"


-- | heapFetch: S row lock + read frame lock + decode (corrupt tuple =
--   XX000).
heapFetch :: Env -> TxnCtx -> RelationDesc -> RID -> IO (Maybe Tuple)
heapFetch env ctx rel rid = do
  let relId = rdId rel
      cols = rdColumns rel
  lockRow ctx relId rid LS
  withPage (envBufferPool env) (ridPage rid) $ \pr -> do
    ms <- readSlot pr (ridSlot rid)
    case ms of
      Just _ -> do
        b <- pageReadTuple pr (ridSlot rid)
        case decodeTuple cols b of
          Left e  -> throwSql "XX000" ("corrupt tuple: " <> e)
          Right t -> pure (Just t)
      Nothing -> pure Nothing

-- | heapScan: relation page list in order, ascending slots, skipping
--   unused slots (§1.8).  Lock-free at storage level (see header).
heapScan :: Env -> TxnCtx -> RelationDesc -> IO [(RID, Tuple)]
heapScan env _ctx rel = concat <$> mapM scanPage (rdPages rel)
  where
    cols = rdColumns rel
    scanPage p = withPage (envBufferPool env) p $ \pr -> do
      hdr <- readHeader pr
      pairs <- mapM (slotOf p pr) [0 .. slotCount hdr - 1]
      pure [ x | Just x <- pairs ]
    slotOf p pr s = do
      ms <- readSlot pr s
      case ms of
        Just _ -> do
          b <- pageReadTuple pr s
          case decodeTuple cols b of
            Left e  -> throwSql "XX000" ("corrupt tuple: " <> e)
            Right t -> pure (Just (RID p s, t))
        Nothing -> pure Nothing
