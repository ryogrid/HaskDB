-- | Buffer pool with CLOCK (second-chance) replacement and per-frame
--   page content locks.  Refines internal-design/02 and design/02 §2.1-2.2.
--   The WAL rule ("a dirty frame is written to the data file only after
--   the WAL up to its page LSN is durable") holds at the single choke
--   point flushFrame via bpFlushUpTo (internal/02 §2.6 invariant).
module HaskDB.Storage.BufferPool where

import qualified Data.ByteString as BS
import qualified Data.Map as Map
import Data.Array (Array, listArray, (!))
import Control.Monad (when, forM_)
import Control.Monad.STM (atomically, retry)
import GHC.Internal.Conc.Sync (TVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Concurrent.MVar (MVar, newMVar, withMVar, modifyMVar)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Control.Exception (try, throwIO, SomeException, finally)
import HaskDB.Common.Types
import HaskDB.Common.Error (throwSql)
import HaskDB.Storage.Page (PageRef(..), PageKind, PageHeader(..), initPage, decodeHeader, headerSize)
import HaskDB.Storage.FileManager

-- try with a concrete exception type (avoids per-use annotations)
trySome :: IO a -> IO (Either SomeException a)
trySome = try

type FrameId = Int

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------
data Frame = Frame
  { frId       :: !Int
  , frPageId   :: TVar (Maybe PageId)  -- Just = frame is (or was) for this page
  , frLoaded   :: TVar Bool            -- frBytes is a valid image of frPageId
  , frBytes    :: IORef BS.ByteString  -- accessed under frLock or own-pin rule
  , frPinCount :: TVar Int
  , frDirty    :: TVar Bool
  , frRefBit   :: TVar Bool
  , frLock     :: TVar (Int, Bool)     -- content lock: #readers, writer?
  }

data PinnedPage = PinnedPage
  { ppFrameId :: !FrameId
  , ppFrame   :: Frame
  , ppId      :: !PageId
  , ppPage    :: PageRef }

data PoolState = PoolState { psTable :: !(Map.Map PageId FrameId), psHand :: !Int }

data BufferPool = BufferPool
  { bpPageSize  :: !Int
  , bpFrameCount :: !Int
  , bpFrames    :: Array Int Frame
  , bpFile      :: FileManager
  , bpFlushUpTo :: LSN -> IO ()   -- WAL-rule hook (phase-1 stub; phase 2
                                  --   injects Wal.Manager.flushWalUpTo)
  , bpState     :: MVar PoolState }

-- ---------------------------------------------------------------------------
-- Page content locks (STM read/write lock, internal/02 §2.1/2.5)
-- ---------------------------------------------------------------------------
newContentLock :: IO (TVar (Int, Bool))
newContentLock = newTVarIO (0, False)

acquireReadLock :: Frame -> IO ()
acquireReadLock f = atomically $ do
  (r, w) <- readTVar (frLock f)
  if w then retry else writeTVar (frLock f) (r + 1, w)

releaseReadLock :: Frame -> IO ()
releaseReadLock f = atomically $ do
  (r, w) <- readTVar (frLock f)
  writeTVar (frLock f) (max 0 (r - 1), w)

acquireWriteLock :: Frame -> IO ()
acquireWriteLock f = atomically $ do
  (r, w) <- readTVar (frLock f)
  if r > 0 || w then retry else writeTVar (frLock f) (0, True)

releaseWriteLock :: Frame -> IO ()
releaseWriteLock f = atomically $ writeTVar (frLock f) (0, False)

withFrameWriteLock :: Frame -> IO a -> IO a
withFrameWriteLock f act = do
  acquireWriteLock f
  r <- act
  releaseWriteLock f
  pure r

withFrameReadLock :: Frame -> IO a -> IO a
withFrameReadLock f act = do
  acquireReadLock f
  r <- act
  releaseReadLock f
  pure r

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------
newBufferPool :: Int -> Int -> FileManager -> (LSN -> IO ()) -> IO BufferPool
newBufferPool pageSize nFrames file flushUpTo = do
  fs <- mapM (mkFrame pageSize) [0 .. nFrames - 1]
  pool <- newMVar (PoolState Map.empty 0)
  pure BufferPool
    { bpPageSize = pageSize
    , bpFrameCount = nFrames
    , bpFrames = listArray (0, nFrames - 1) fs
    , bpFile = file
    , bpFlushUpTo = flushUpTo
    , bpState = pool }
  where
    mkFrame ps i = do
      bs <- newIORef (BS.replicate ps 0)
      pid <- newTVarIO Nothing
      ld <- newTVarIO False
      pn <- newTVarIO 0
      dr <- newTVarIO False
      rb <- newTVarIO False
      lk <- newTVarIO (0, False)
      pure Frame { frId = i, frPageId = pid, frLoaded = ld, frBytes = bs,
                   frPinCount = pn, frDirty = dr, frRefBit = rb, frLock = lk }

-- ---------------------------------------------------------------------------
-- pin / unpin (internal/02 §2.3 flow)
-- ---------------------------------------------------------------------------
-- installZero=True: install a zero image without reading from disk
-- (pinNewPage; caller must have extended the file).
pinWith :: BufferPool -> PageId -> Bool -> IO PinnedPage
pinWith bp pid installZero = do
  res <- modifyMVar (bpState bp) (\ps -> do
    case Map.lookup pid (psTable ps) of
      Just fid -> pure (ps, Right fid)
      Nothing -> do
        (fid, hand') <- pickVictim bp (psHand ps)
        let f = bpFrames bp ! fid
        oldL <- readTVarIO (frLoaded f)
        oldPid <- readTVarIO (frPageId f)
        dirty <- readTVarIO (frDirty f)
        let oldInfo = if oldL then oldPid else Nothing
        atomically $ do
          writeTVar (frPageId f) (Just pid)
          writeTVar (frLoaded f) False
          writeTVar (frPinCount f) 1
          writeTVar (frDirty f) False
        let ps' = ps { psHand = hand'
                     , psTable = Map.insert pid fid
                         (Map.filter (/= fid) (psTable ps)) }
        pure (ps', Left (fid, oldInfo, dirty))
    )
  case res of
    Right fid -> do
      let f = bpFrames bp ! fid
      atomically $ do
        ld <- readTVar (frLoaded f)
        if ld then pure () else retry
        writeTVar (frRefBit f) True
        pn0 <- readTVar (frPinCount f)
        writeTVar (frPinCount f) (pn0 + 1)
      pure (mkPinned bp fid pid)
    Left (fid, oldInfo, dirty) -> do
      let f = bpFrames bp ! fid
      -- evict the victim first (flush it if dirty — internal/02 §2.4).
      -- A throwing eviction flush must not leave the frame pinned: reuse
      -- the same reset path as a read failure (review MUST-FIX #5).
      ev <- trySome (case oldInfo of
                      Just op | dirty -> flushFrame bp f op
                      _               -> pure ())
      case ev of
        Left e -> do
          atomically $ do
            writeTVar (frPageId f) Nothing
            writeTVar (frLoaded f) False
            writeTVar (frPinCount f) 0
          _ <- withMVar (bpState bp) (\ps ->
            pure ps { psTable = Map.delete pid (psTable ps) })
          throwIO e
        Right _ -> pure ()
      mr <- trySome (if installZero
                   then pure (BS.replicate (bpPageSize bp) 0)
                   else readPageBytes (bpFile bp) pid)
      case mr of
        Right bytes -> do
          writeIORef (frBytes f) bytes
          atomically $ do
            writeTVar (frLoaded f) True
            writeTVar (frDirty f) False
            writeTVar (frRefBit f) True
          pure (mkPinned bp fid pid)
        Left e -> do
          atomically $ do
            writeTVar (frPageId f) Nothing
            writeTVar (frLoaded f) False
            writeTVar (frPinCount f) 0
          _ <- withMVar (bpState bp) (\ps ->
            pure ps { psTable = Map.delete pid (psTable ps) })
          throwIO e

mkPinned :: BufferPool -> FrameId -> PageId -> PinnedPage
mkPinned bp fid pid =
  let f = bpFrames bp ! fid
  in  PinnedPage fid f pid (PageRef (frBytes f))

-- ---------------------------------------------------------------------------
-- Victim selection: CLOCK sweep (internal/02 §2.4)
-- ---------------------------------------------------------------------------
pickVictim :: BufferPool -> Int -> IO (FrameId, Int)
pickVictim bp hand0 = go 0
  where
    n = bpFrameCount bp
    frames = bpFrames bp
    go i | i >= 2 * n = throwSql "XX000" "buffer pool exhausted: all frames pinned"
         | otherwise = do
            let fid = (hand0 + i) `mod` n
                f = frames ! fid
            pin <- readTVarIO (frPinCount f)
            if pin > 0
              then go (i + 1)
              else do
                curp <- readTVarIO (frPageId f)
                case curp of
                  -- empty frame: take it immediately (internal/02 §2.4)
                  Nothing -> pure (fid, hand0 + i + 1)
                  Just _ -> do
                    ref <- readTVarIO (frRefBit f)
                    if ref
                      then do atomically $ writeTVar (frRefBit f) False
                              go (i + 1)
                      else pure (fid, hand0 + i + 1)

-- ---------------------------------------------------------------------------
-- Flushing: THE WAL RULE lives only here (internal/02 §2.4)
-- ---------------------------------------------------------------------------
-- Assumes the caller already holds the frame's write lock and has
-- verified the frame still holds `pid` (checked paths do both).
-- The WAL rule (flushUpTo before data-file write) lives only here.
flushImageUnderLock :: BufferPool -> Frame -> PageId -> IO ()
flushImageUnderLock bp f pid = do
  bytes <- readIORef (frBytes f)
  case decodeHeader (BS.take headerSize bytes) of
    Left _  -> throwSql "XX000" "flushFrame: corrupt header"
    Right hdr -> do
      (bpFlushUpTo bp) (phLsn hdr)        -- <<< WAL rule, sole choke point
      writePageBytes (bpFile bp) pid bytes
      atomically $ writeTVar (frDirty f) False

-- Eviction flush (pinWith): frPageId already names the NEW page, so the
-- explicit old pid is passed (deviation: docs' pseudocode flushes
-- frPageId, which would write the wrong bytes at the wrong offset).
flushFrame :: BufferPool -> Frame -> PageId -> IO ()
flushFrame bp f pid = withFrameWriteLock f (flushImageUnderLock bp f pid)

-- bpState is held across the whole flush, and the frame's identity is
-- re-checked under its write lock (review MUST-FIX #3: without this a
-- concurrently-evicted frame's NEW bytes could be written at the OLD
-- page's offset).
flushPage :: BufferPool -> PageId -> IO ()
flushPage bp pid = withMVar (bpState bp) $ \ps ->
  case Map.lookup pid (psTable ps) of
    Nothing -> pure ()
    Just fid -> do
      let f = bpFrames bp ! fid
      acquireWriteLock f
      ok <- atomically (do
        cur <- readTVar (frPageId f)
        ld <- readTVar (frLoaded f)
        pure (ld && cur == Just pid))
      if ok then flushImageUnderLock bp f pid else pure ()
      releaseWriteLock f

-- snapshot under bpState (internal/02 §2.4), identity-checked flushes
flushAll :: BufferPool -> IO ()
flushAll bp = withMVar (bpState bp) $ \_ -> do
  let n = bpFrameCount bp
  fidspid <- fmap concat (mapM (\fid -> do
    let f = bpFrames bp ! fid
    cur <- readTVarIO (frPageId f)
    ld <- readTVarIO (frLoaded f)
    dr <- readTVarIO (frDirty f)
    pure [ (fid, p) | ld && dr, Just p <- [cur] ]) [0 .. n - 1])
  forM_ fidspid (\(fid, pid) -> do
    let f = bpFrames bp ! fid
    acquireWriteLock f
    ok <- atomically (do
      cur <- readTVar (frPageId f)
      ld <- readTVar (frLoaded f)
      pure (ld && cur == Just pid))
    if ok then flushImageUnderLock bp f pid else pure ()
    releaseWriteLock f)

-- ---------------------------------------------------------------------------
-- Public pin/unpin + bracket forms (internal/02 §2.2/2.5)
-- ---------------------------------------------------------------------------
pinPage :: BufferPool -> PageId -> IO PinnedPage
pinPage bp pid = pinWith bp pid False

unpinPage :: BufferPool -> PinnedPage -> Bool -> IO ()
unpinPage _bp pp dirty = do
  atomically $ do
    pn <- readTVar (frPinCount (ppFrame pp))
    writeTVar (frPinCount (ppFrame pp)) (max 0 (pn - 1))
    when dirty $ writeTVar (frDirty (ppFrame pp)) True
    writeTVar (frRefBit (ppFrame pp)) True

-- bracket form (internal/02 §2.2): lock release + unpin happen even when
-- act throws (review MUST-FIX #4)
withPage :: BufferPool -> PageId -> (PageRef -> IO a) -> IO a
withPage bp pid act = do
  pp <- pinPage bp pid
  finally
    (do acquireReadLock (ppFrame pp)
        finally (act (ppPage pp)) (releaseReadLock (ppFrame pp)))
    (unpinPage bp pp False)

withPageDirty :: BufferPool -> PageId -> (PageRef -> IO a) -> IO a
withPageDirty bp pid act = do
  pp <- pinPage bp pid
  finally
    (do acquireWriteLock (ppFrame pp)
        finally (act (ppPage pp)) (releaseWriteLock (ppFrame pp)))
    (unpinPage bp pp True)

withPageReadLock :: PinnedPage -> IO a -> IO a
withPageReadLock pp = withFrameReadLock (ppFrame pp)

withPageWriteLock :: PinnedPage -> IO a -> IO a
withPageWriteLock pp = withFrameWriteLock (ppFrame pp)

-- Allocate-and-pin a brand-new page (file already extended by caller;
-- internal/02 §2.2 pinNewPage).
pinNewPage :: BufferPool -> PageId -> PageKind -> IO PinnedPage
pinNewPage bp pid k = do
  pp <- pinWith bp pid True
  initPage (ppPage pp) k (bpPageSize bp)
  pure pp
