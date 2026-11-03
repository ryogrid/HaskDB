-- Phase-2 milestone test suite (design/10 §10.2):
--   * WAL format: round-trip of every payload type, CRC corruption, torn tail
--   * WAL manager: buffered appends + flushWalUpTo + fsync durability
--   * control file: pure parse round-trip + atomic file write/read
--   * crash simulation: redo winners / undo loser / garbage tail truncate
--   * recovery idempotence: a second recovery changes nothing
module Main where

import System.Exit (exitSuccess, exitFailure)
import qualified Data.ByteString as BS
import Data.Text (Text, unpack)
import Data.Bits (xor)
import Data.IORef
import Control.Monad (replicateM_, when)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, removeDirectoryRecursive)
import System.Posix.Files (getFileStatus, fileSize)
import System.FilePath ((</>))

import HaskDB.Common.Types
import HaskDB.Common.Config (defaultConfig, cfgPageSize)
import HaskDB.Heap.TupleCodec (ColumnDesc(..))
import HaskDB.Wal.Format
import HaskDB.Wal.Manager
import HaskDB.Server.Control
import HaskDB.Server.Env (Env(envFileMgr, envWalMgr))
import HaskDB.Wal.Recovery (recoverDatabase)
import HaskDB.Storage.FileManager
import HaskDB.Storage.Page (PageRef(..), PageKind(PKHeap), PageHeader(phLsn), initPage, readHeader, writeHeader, readSlot, pageSlice, pageInsertTuple)

checkT :: Text -> Bool -> [Text] -> [Text]
checkT name ok errs = if ok then errs else name : errs

-- ---------------------------------------------------------------------------
-- WAL format
-- ---------------------------------------------------------------------------
sampleRecords :: [WalRecord]
sampleRecords =
  [ WalRecord WTInsertTuple 7 100 (PInsertTuple 1 0 "TUPLE_A")
  , WalRecord WTDeleteTuple 8 200 (PDeleteTuple 1 2 "BEF")
  , WalRecord WTUpdateTuple 9 300 (PUpdateTuple 1 0 "AAA" "BBBBBB")
  , WalRecord WTIndexInsert 1 0   (PIndexInsert 42 (VInt 7) (RID 5 3))
  , WalRecord WTIndexDelete 1 0   (PIndexDelete 42 (VText "k") (RID 5 3))
  , WalRecord WTPageImage 0 0     (PPageImage 3 (BS.replicate 64 7))
  , WalRecord WTAllocPage 1 0     (PAllocPage 6 5)
  , WalRecord WTCreateTable 1 0   (PCreateTable 5 "widgets" [ColumnDesc "n" TyInt64])
  , WalRecord WTCreateIndex 1 0   (PCreateIndex 7 "widgets.n" 5 0 9)
  , WalRecord WTCommit 7 100      PCommit
  , WalRecord WTabort 8 200       PAbort
  , WalRecord WTCheckpoint 0 0    (PCheckpoint [(7, 100), (9, 150)])
  ]

flipByte :: BS.ByteString -> Int -> BS.ByteString
flipByte bs i =
  let w = BS.index bs i
  in BS.take i bs <> BS.pack [w `xor` 0x20] <> BS.drop (i + 1) bs

scanAll :: BS.ByteString -> Int -> [(Int, WalRecord)]
scanAll bs off = case decodeRecord bs off of
  Left _ -> []
  Right (rec, off') -> (off, rec) : scanAll bs off'

scanEnd :: BS.ByteString -> Int -> Int
scanEnd bs off = case decodeRecord bs off of
  Left _ -> off
  Right (_, off') -> scanEnd bs off'

formatTests :: IO [Text]
formatTests = pure $ concat
  [ checkT "format roundtrip all types" rtOK []
  , case corrupted of
      Left _  -> []
      Right _ -> ["format: crc corruption not detected"]
  , case truncated of
      Left _  -> []
      Right _ -> ["format: torn tail not detected"]
  ]
  where
    encs = map encodeRecord sampleRecords
    chain = BS.concat encs
    walked = scanAll chain 0
    rtOK = length walked == length sampleRecords
        && and [ rec == orig | ((_, rec), orig) <- zip walked sampleRecords ]
        && scanEnd chain 0 == BS.length chain
    one = case encs of
            (e : _) -> e
            []      -> BS.empty
    mid = BS.length one `div` 2
    corrupted = decodeRecord (flipByte one mid) 0
    truncated = decodeRecord (BS.take (BS.length one - 3) one) 0

-- ---------------------------------------------------------------------------
-- WAL manager
-- ---------------------------------------------------------------------------
managerTests :: IO [Text]
managerTests = do
  let dir = "waltest-mgr"
  createDirectoryIfMissing True dir
  let wp = dir </> "m.wal"
  wal <- newWalManager wp
  l0 <- appendRecord wal (sampleRecords !! 0)
  l1 <- appendRecord wal (sampleRecords !! 2)
  l2 <- appendRecord wal (sampleRecords !! 11)
  _ <- flushWalUpTo wal l2
  f <- flushedLSN wal
  sz <- fileSize <$> getFileStatus wp
  let e1 = checkT "mgr flush durable" (f == fromIntegral sz) []
  raw <- readWalAll wal
  let e2 = checkT "mgr 3 records on disk" (length (scanAll raw 0) == 3) e1
  l3 <- appendRecord wal (sampleRecords !! 3)
  f2 <- flushedLSN wal
  let e3 = checkT "mgr unflushed stable" (f2 == f) e2
  _ <- flushWalUpTo wal l3
  sz2 <- fileSize <$> getFileStatus wp
  f3 <- flushedLSN wal
  let e4 = checkT "mgr flush to end" (f3 == fromIntegral sz2) e3
  let e5 = checkT "mgr lsn order" (l0 < l1 && l1 < l2 && l2 < l3) e4
  let e6 = checkT "mgr lsns distinct+contiguous-ish" (l0 == 0) e5
  closeWalManager wal
  removeDirectoryRecursive dir
  pure e6

-- ---------------------------------------------------------------------------
-- Control file
-- ---------------------------------------------------------------------------
controlTests :: IO [Text]
controlTests = do
  let cf = ControlFile 8192 123456 42
  let e1 = case parseControl (renderControl cf) of
        Right cf' -> checkT "ctl render/parse rt" (cf' == cf) []
        Left e -> ["ctl parse: " <> e]
  let e2 = case parseControl "format=1\npageSize=8192\nnextTid=3\n" of
        Left _ -> e1
        Right _ -> ["ctl missing-key accepted (bad)"]
  let e3 = case parseControl "format=2\npageSize=8192\ncheckpointLSN=0\nnextTid=1\n" of
        Left _ -> e2
        Right _ -> ["ctl bad format version accepted (bad)"]
  let dir = "waltest-ctl"
  createDirectoryIfMissing True dir
  let p = dir </> "haskdb.control"
  writeControl p cf
  cf2 <- readControl p
  let e4 = checkT "ctl file roundtrip" (cf2 == cf) e3
  removeDirectoryRecursive dir
  pure e4

-- ---------------------------------------------------------------------------
-- Crash simulation + recovery
-- ---------------------------------------------------------------------------
crashSimTests :: IO [Text]
crashSimTests = do
  let dir = "waltest-crash"
  dd <- doesDirectoryExist dir
  when dd (removeDirectoryRecursive dir)
  createDirectoryIfMissing True dir
  let cfg = defaultConfig dir
      ps = cfgPageSize cfg
      dataPath = dir </> "haskdb.data"
      walPath = dir </> "haskdb.wal"
      ctlPath = dir </> "haskdb.control"
      ta = "TUPLE_A"
      tbb = "TUPLE_BBBB"
      tb = "TUPLE_B"
  fm <- openDataFile dataPath ps
  replicateM_ 3 (extendFile fm)
  -- page 1: empty heap page, phLsn 5 (predates all post-checkpoint records)
  r1 <- newIORef (BS.replicate ps 0)
  let pr1 = PageRef r1
  initPage pr1 PKHeap ps
  h1 <- readHeader pr1
  writeHeader pr1 h1 { phLsn = 5 }
  img1 <- readIORef r1
  writePageBytes fm 1 img1
  -- page 2: already-durable tuple (pre-checkpoint era), phLsn 20
  r2 <- newIORef (BS.replicate ps 0)
  let pr2 = PageRef r2
  initPage pr2 PKHeap ps
  _ <- pageInsertTuple pr2 20 tb
  img2 <- readIORef r2
  writePageBytes fm 2 img2
  closeDataFile fm
  wal0 <- newWalManager walPath
  l5 <- appendRecord wal0 (WalRecord WTInsertTuple 5 0 (PInsertTuple 2 0 tb))
  _l5c <- appendRecord wal0 (WalRecord WTCommit 5 l5 PCommit)
  ck1 <- appendRecord wal0 (WalRecord WTCheckpoint 0 0 (PCheckpoint []))
  _ <- flushWalUpTo wal0 ck1
  l7 <- appendRecord wal0 (WalRecord WTInsertTuple 7 0 (PInsertTuple 1 0 ta))
  _l7c <- appendRecord wal0 (WalRecord WTCommit 7 l7 PCommit)
  l9 <- appendRecord wal0 (WalRecord WTUpdateTuple 9 0 (PUpdateTuple 1 0 ta tbb))
  _ <- flushWalUpTo wal0 l9
  closeWalManager wal0
  BS.appendFile walPath "GARBAGE-NOT-A-RECORD"
  writeControl ctlPath ControlFile { cfPageSize = ps
                                   , cfCheckpointLSN = ck1, cfNextTid = 8 }
  env <- recoverDatabase cfg
  let fm1 = envFileMgr env
  pg1 <- readPageBytes fm1 1
  rr <- newIORef pg1
  let pr = PageRef rr
  hdr <- readHeader pr
  ms <- readSlot pr 0
  content1 <- case ms of
    Just (o, l) -> pageSlice pr o l
    Nothing -> pure BS.empty
  let e1 = checkT "redo+undo: page1 slot0 = A" (content1 == ta) []
  let e2 = checkT "redo stamped page lsn" (phLsn hdr >= l9) e1
  pg2 <- readPageBytes fm1 2
  let e3 = checkT "page2 untouched" (pg2 == img2) e2
  ctl <- readControl ctlPath
  let e4 = checkT "ctl checkpoint advanced" (cfCheckpointLSN ctl > ck1) e3
  let e5 = checkT "ctl nextTid bumped past WAL txn ids" (cfNextTid ctl == 10) e4
  walBs <- readWalAll (envWalMgr env)
  let e6 = checkT "garbage tail truncated"
             (scanEnd walBs 0 == fromIntegral (BS.length walBs)) e5
  let e7 = checkT "7 valid records after recovery"
             (length (scanAll walBs 0) == 7) e6
  -- Close env1 before re-opening (flock is non-blocking in this toolchain:
  -- two concurrent open handles on one file -> EAGAIN "resource busy").
  closeDataFile fm1
  closeWalManager (envWalMgr env)
  env2 <- recoverDatabase cfg
  pg1b <- readPageBytes (envFileMgr env2) 1
  let e8 = checkT "idempotent page1" (pg1b == pg1) e7
  ctl2 <- readControl ctlPath
  let e9 = checkT "cp grows on 2nd recovery"
             (cfCheckpointLSN ctl2 > cfCheckpointLSN ctl) e8
  closeDataFile (envFileMgr env2)
  closeWalManager (envWalMgr env2)
  removeDirectoryRecursive dir
  pure e9

main :: IO ()
main = do
  e1 <- formatTests
  e2 <- managerTests
  e3 <- controlTests
  e4 <- crashSimTests
  let allErrs = e1 ++ e2 ++ e3 ++ e4
  if null allErrs
    then do
      putStrLn "wal-tests: PASS"
      exitSuccess
    else do
      mapM_ (putStrLn . unpack) allErrs
      exitFailure
