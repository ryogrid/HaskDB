-- | WAL manager (internal-design/03 §3.3, design/02 §2.3).
--   Deviations recorded in TODO.md:
--   (1) the docs' separate `wmFileSize` TVar is folded into `wsNextLSN`
--       inside the single `WalState` MVar — appends are serialised by
--       that same MVar, so LSN order is already guaranteed;
--   (2) the WAL file is opened with `openFd` + append flag so we keep
--       the raw `Fd` for `fdatasync` (same idiom as `Storage.FileManager`,
--       which also needed this for `fsync`);
--   (3) `truncateWal` (FFI `truncate` on the path) is a recovery helper:
--       after analysis, the torn/garbage tail beyond the last valid
--       record is discarded so later appends stay LSN-reachable. The
--       docs are silent on tail handling; chosen for restartability.
module HaskDB.Wal.Manager where

import qualified Data.ByteString as BS
import Data.Text (pack)
import System.IO (Handle, openFile, hSeek, hFlush, hClose, hFileSize, IOMode(WriteMode))
import System.Directory (doesFileExist)
import GHC.IO.Device (SeekMode(AbsoluteSeek))
import System.Posix.Files (getFileStatus, fileSize)
import System.Posix.IO (openFd, fdToHandle, OpenMode(ReadWrite), defaultFileFlags, append, creat)
import System.Posix.Types (Fd(..))
import System.Posix.Files (stdFileMode)
import Control.Concurrent.MVar (MVar, newMVar, withMVar, modifyMVar, modifyMVar_)
import Control.Monad (unless)
import Foreign.C.Types (CInt(..))
import Foreign.C.String (CString, withCString)
import HaskDB.Common.Types
import HaskDB.Common.Error (throwSql)
import HaskDB.Wal.Format (WalRecord, encodeRecord)

-- fdatasync via libc FFI (D-06 rationale: no extra package; internal/03
-- §3.3 prefers fileSynchronizeDataOnly — fdatasync is the same call).
foreign import ccall unsafe "fdatasync" cFdatasync :: CInt -> IO CInt
foreign import ccall unsafe "truncate" cTruncate :: CString -> CInt -> IO CInt

data WalManager = WalManager
  { wmPath   :: !FilePath
  , wmHandle :: Handle
  , wmFd     :: !Fd
  , wmState  :: MVar WalState }

-- Deviation (1): wsNextLSN replaces the docs' wmFileSize TVar.
data WalState = WalState
  { wsNextLSN    :: !LSN            -- logical end of WAL = next LSN
  , wsBuffer     :: !BS.ByteString  -- appended, not yet written out
  , wsWrittenLSN :: !LSN            -- written to the OS
  , wsFlushedLSN :: !LSN            -- fsynced (durable)
  }

fdatasyncFd :: Fd -> IO ()
fdatasyncFd (Fd n) = do
  r <- cFdatasync n
  if r /= 0
    then throwSql "XX000" ("fdatasync failed on WAL: " <> pack (show r))
    else pure ()

truncateFile :: FilePath -> LSN -> IO ()
truncateFile path n =
  withCString path $ \cptr -> do
    r <- cTruncate cptr (fromIntegral n)
    if r /= 0
      then throwSql "XX000" ("truncate failed on WAL: " <> pack (show r))
      else pure ()

-- Open/creates the WAL in append mode; initial LSNs = existing size
-- (internal/03 §3.3: "append mode").
newWalManager :: FilePath -> IO WalManager
newWalManager path = do
  exists <- doesFileExist path
  unless exists $ do
    h0 <- openFile path WriteMode
    hClose h0
  fd <- openFd path ReadWrite defaultFileFlags { append = True
                                               , creat = Just stdFileMode }
  h <- fdToHandle fd
  sz <- hFileSize h
  st <- newMVar WalState { wsNextLSN = fromIntegral sz
                         , wsBuffer = BS.empty
                         , wsWrittenLSN = fromIntegral sz
                         , wsFlushedLSN = fromIntegral sz }
  pure WalManager { wmPath = path, wmHandle = h, wmFd = fd, wmState = st }

closeWalManager :: WalManager -> IO ()
closeWalManager wm = hClose (wmHandle wm)

-- Appends are serialised by the MVar, so LSN order = call order
-- (internal/03 §3.3).  The caller fills wrPrevTxn BEFORE appending.
appendRecord :: WalManager -> WalRecord -> IO LSN
appendRecord wm rec = modifyMVar (wmState wm) $ \st -> do
  let bytes = encodeRecord rec
      lsn = wsNextLSN st
  pure ( st { wsNextLSN = lsn + fromIntegral (BS.length bytes)
            , wsBuffer = wsBuffer st <> bytes }
       , lsn )

-- internal/03 §3.3 flushWalUpTo flow with the docs' re-check loop:
-- concurrent flushers serialise on the MVar; a short sync re-loops.
-- Deviation: target > wsNextLSN is a caller error (prevents infinite
-- re-looping; D-15 group commit will batch inside this function only).
flushWalUpTo :: WalManager -> LSN -> IO ()
flushWalUpTo wm target = go
  where
    go = do
      reached <- flushStep wm target
      if reached then pure () else go
    flushStep wm' target' = modifyMVar (wmState wm') $ \st ->
      if wsFlushedLSN st >= target' && BS.null (wsBuffer st)
        then pure (st, True)
      else if target' > wsNextLSN st
        then throwSql "XX000" "flushWalUpTo: target beyond WAL end"
      else do
        let blen = BS.length (wsBuffer st)
            written' = wsWrittenLSN st + fromIntegral blen
        if blen > 0
          then do
            BS.hPut (wmHandle wm') (wsBuffer st)
            hFlush (wmHandle wm')   -- push to the OS before fdatasync
          else pure ()
        if written' >= target'
          then do
            fdatasyncFd (wmFd wm')
            pure ( st { wsBuffer = BS.empty
                      , wsWrittenLSN = written'
                      , wsFlushedLSN = written' }
                 , True )
          else pure ( st { wsBuffer = BS.empty
                         , wsWrittenLSN = written' }
                    , False )

flushedLSN :: WalManager -> IO LSN
flushedLSN wm = withMVar (wmState wm) $ \st -> pure (wsFlushedLSN st)

-- Recovery helper (deviation (3)): cut the WAL back to a valid end.
-- All buffered bytes past the cut are dropped; the three LSN markers
-- move to the cut.  Only used by recovery tail cleanup.
truncateWal :: WalManager -> LSN -> IO ()
truncateWal wm newEnd = modifyMVar_ (wmState wm) $ \st -> do
  truncateFile (wmPath wm) newEnd
  pure st { wsNextLSN = newEnd
          , wsBuffer = BS.empty
          , wsWrittenLSN = newEnd
          , wsFlushedLSN = newEnd }

-- Next logical LSN (see above).
nextLSN :: WalManager -> IO LSN
nextLSN wm = withMVar (wmState wm) $ \st -> pure (wsNextLSN st)

-- | Read ALL current WAL bytes (including a garbage tail) through the
--   manager's own handle — opening a second (GHC-level) handle on the
--   same file would flock-collide with the manager's unix flock.
--   O_APPEND keeps later appends at the logical end despite this seek.
readWalAll :: WalManager -> IO BS.ByteString
readWalAll wm = do
  let h = wmHandle wm
  sz <- fileSize <$> getFileStatus (wmPath wm)
  hSeek h AbsoluteSeek 0
  bs <- BS.hGet h (fromIntegral sz)
  pure bs
