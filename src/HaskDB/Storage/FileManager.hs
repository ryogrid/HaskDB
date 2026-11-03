-- | Raw positional page I/O on the data file (internal-design/01 §1.6).
--   The data-file Handle is shared by all buffer-pool threads, so every
--   seek-based read/write is serialised by one internal MVar (deviation
--   note: the docs serialise extend only; serialising all access keeps
--   the shared file position sound — the buffer pool provides the real
--   concurrency above this layer).
module HaskDB.Storage.FileManager where

import qualified Data.ByteString as BS
import System.IO (Handle, openFile, hSeek, hFlush, hClose, hFileSize, IOMode(WriteMode))
import System.Directory (doesFileExist)
import GHC.IO.Device (SeekMode(AbsoluteSeek))
import System.Posix.IO (openFd, fdToHandle, OpenMode(ReadWrite), defaultFileFlags)
import System.Posix.Types (Fd(..))
import Control.Monad (unless)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Foreign.C.Types (CInt(..))
import HaskDB.Common.Types
import HaskDB.Common.Error (throwSql)

-- fsync via FFI (unix FFI to libc, no extra package; D-06 rationale).
-- In this toolchain Fd is a newtype over CInt, so we unwrap it here.
foreign import ccall unsafe "fsync" cFsync :: CInt -> IO CInt

fsyncFd :: Fd -> IO ()
fsyncFd (Fd n) = do
  _ <- cFsync n
  pure ()

data FileManager = FileManager
  { fmHandle   :: Handle
  , fmFd       :: !Fd              -- raw fd, for fsync
  , fmPageSize :: !Int
  , fmIOLock   :: MVar ()          -- serialises seek/read/write/extend
  }

-- Open (creating if absent) the data file read/write; we keep both the
-- buffered Handle and the raw Fd (internal/01 §1.6: fsync after extend).
openDataFile :: FilePath -> Int -> IO FileManager
openDataFile path pageSize = do
  exists <- doesFileExist path
  unless exists $ do
    h0 <- openFile path WriteMode
    hClose h0
  fd <- openFd path ReadWrite defaultFileFlags
  h <- fdToHandle fd
  lock <- newMVar ()
  pure FileManager { fmHandle = h, fmFd = fd, fmPageSize = pageSize
                   , fmIOLock = lock }

closeDataFile :: FileManager -> IO ()
closeDataFile fm = hClose (fmHandle fm)

filePageCount :: FileManager -> IO PageId
filePageCount fm = withMVar (fmIOLock fm) $ \_ -> do
  sz <- hFileSize (fmHandle fm)
  pure (fromIntegral (sz `div` fromIntegral (fmPageSize fm)))

readPageBytes :: FileManager -> PageId -> IO BS.ByteString
readPageBytes fm pid = withMVar (fmIOLock fm) $ \_ -> do
  hSeek (fmHandle fm) AbsoluteSeek
        (fromIntegral pid * fromIntegral (fmPageSize fm))
  bs <- BS.hGet (fmHandle fm) (fmPageSize fm)
  if BS.length bs == fmPageSize fm
    then pure bs
    else throwSql "XX000" "short page read: file truncated?"

writePageBytes :: FileManager -> PageId -> BS.ByteString -> IO ()
writePageBytes fm pid bytes = withMVar (fmIOLock fm) $ \_ -> do
  if BS.length bytes /= fmPageSize fm
    then throwSql "XX000" "writePageBytes: image size mismatch"
    else do
      hSeek (fmHandle fm) AbsoluteSeek
            (fromIntegral pid * fromIntegral (fmPageSize fm))
      BS.hPut (fmHandle fm) bytes
      hFlush (fmHandle fm)

-- Append one zero page, return its id; fsync after extend (internal/01
-- §1.6).  fmIOLock is held, so two threads never extend concurrently.
extendFile :: FileManager -> IO PageId
extendFile fm = withMVar (fmIOLock fm) $ \_ -> do
  sz <- hFileSize (fmHandle fm)
  let pid = fromIntegral (sz `div` fromIntegral (fmPageSize fm))
  -- MUST seek to EOF: readers leave the shared handle position elsewhere
  hSeek (fmHandle fm) AbsoluteSeek sz
  BS.hPut (fmHandle fm) (BS.replicate (fmPageSize fm) 0)
  hFlush (fmHandle fm)
  fsyncFd (fmFd fm)
  pure pid

fsyncDataFile :: FileManager -> IO ()
fsyncDataFile fm = withMVar (fmIOLock fm) $ \_ -> do
  fsyncFd (fmFd fm)
  pure ()
