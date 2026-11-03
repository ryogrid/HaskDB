-- | Control file (internal-design/11 §11.4).  Module name is an
--   implementation choice (the docs name the flow, not the module).
--   Human-readable text format on purpose; written only by bootstrap
--   and checkpoints (§3.5).  Atomicity: tmp + fsync + rename + dir fsync.
module HaskDB.Server.Control where

import qualified Data.ByteString as BS
import Data.Text (Text, lines, strip, pack, unpack, splitOn)
import Data.Text.Encoding (encodeUtf8, decodeUtf8Lenient)
import Data.Char (isSpace)
import System.Directory (renameFile)
import System.FilePath (takeDirectory, dropTrailingPathSeparator)
import System.IO (Handle, openFile, hFlush, hClose, hFileSize, IOMode(ReadMode))
import System.Posix.IO (openFd, fdToHandle, closeFd, OpenMode(ReadOnly, WriteOnly), defaultFileFlags, directory, creat, trunc)
import System.Posix.Types (Fd(..))
import System.Posix.Files (stdFileMode)
import System.Posix.Process (getProcessID)
import HaskDB.Common.Types (LSN, TxnId)
import HaskDB.Common.Error (throwSql)
import HaskDB.Storage.FileManager (fsyncFd)

data ControlFile = ControlFile
  { cfPageSize      :: !Int
  , cfCheckpointLSN :: !LSN
  , cfNextTid       :: !TxnId }
  deriving (Eq, Show)

renderControl :: ControlFile -> Text
renderControl cf
  = "format=1\n"
    <> "pageSize=" <> pack (show (cfPageSize cf)) <> "\n"
    <> "checkpointLSN=" <> pack (show (cfCheckpointLSN cf)) <> "\n"
    <> "nextTid=" <> pack (show (cfNextTid cf)) <> "\n"

parseControl :: Text -> Either Text ControlFile
parseControl t = do
  let ls = filter (not . isNil . strip) (Data.Text.lines t)
  kv <- mapM lineKV ls
  fmt <- req "format" kv
  f <- readNum "format" fmt
  if f /= (1 :: Int) then Left "control: unsupported format version"
    else do
      ps <- readNonNeg "pageSize" =<< req "pageSize" kv
      ck <- readNonNeg "checkpointLSN" =<< req "checkpointLSN" kv
      nt <- readNonNeg "nextTid" =<< req "nextTid" kv
      pure ControlFile { cfPageSize = ps
                       , cfCheckpointLSN = fromIntegral ck
                       , cfNextTid = fromIntegral nt }
  where
    isNil x = x == ""
    lineKV l = case splitOn "=" (strip l) of
      [k, v] -> Right (strip k, strip v)
      _      -> Left "control: malformed line"
    req k kv = case [ v | (k', v) <- kv, k' == k ] of
      [v] -> Right v
      _   -> Left ("control: missing key " <> k)
    readNum what v = case reads (unpack v) of
      [(n, rest)] | all isSpace rest -> Right (fromIntegral n)
      _ -> Left ("control: bad number for " <> what)
    readNonNeg what v = do
      n <- readNum what v
      if n < 0 then Left ("control: negative value for " <> what)
        else Right n

-- parse errors = die (internal/11 §11.4); Server layer decides how to die.
readControl :: FilePath -> IO ControlFile
readControl path = do
  h <- openFile path ReadMode
  sz <- hFileSize h
  bs <- BS.hGet h (fromIntegral sz)
  hClose h
  case parseControl (decodeUtf8Lenient bs) of
    Left e  -> throwSql "XX000" e
    Right cf -> pure cf

-- unique tmp name per process (review note: avoid reuse between crashed
-- checkpoint attempts) + O_TRUNC (unix openFd does not truncate by default).
writeControl :: FilePath -> ControlFile -> IO ()
writeControl path cf = do
  pid <- getProcessID
  let bytes = encodeUtf8 (renderControl cf)
      tmp = path <> ".tmp." <> show pid
  fd <- openFd tmp WriteOnly defaultFileFlags { creat = Just stdFileMode
                                              , trunc = True }
  h <- fdToHandle fd
  BS.hPut h bytes
  hFlush h
  fsyncFd fd
  hClose h
  renameFile tmp path
  let dir = dropTrailingPathSeparator (takeDirectory path)
  dfd <- openFd dir ReadOnly defaultFileFlags { directory = True }
  fsyncFd dfd
  closeFd dfd
