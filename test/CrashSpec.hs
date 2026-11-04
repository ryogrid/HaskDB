-- Phase-8 crash matrix, IN PROCESS (design/10 §10.2 "full crash-test matrix
-- (kill -9 during each phase's operations, including during checkpoint and
-- during recovery itself)"; design/02 §2.6; internal-design/03 §3.5/§3.6;
-- internal-design/11 §11.2/§11.4).
--
-- scripts/crash-smoke.sh covers the PROCESS-level matrix (a real SIGKILL).
-- These cases cover the crash states that need the disk doctored at BYTE
-- level, which a shell cannot time deterministically:
--
--   A. a checkpoint that completed the CHECKPOINT record + flushAll + data
--      fsync but died BEFORE writeControl: the control file still names the
--      PREVIOUS checkpoint, and the fresh CHECKPOINT record lists an ACTIVE
--      transaction.  Recovery must find that txn through the record and undo
--      it (this is exactly the window internal/03 §3.5's crash-equivalence
--      rule — runCheckpointWith's snapshot inside the lock + beginTxn taking
--      the same lock — exists to close),
--   B. checkpoint-boundary equivalence: replaying from cp = 0 and replaying
--      from the checkpoint's own offset must produce the same visible state
--      (redo guards make the below-the-boundary prefix a no-op),
--   C. an ABORTED transaction whose pages were stolen and flushed before it
--      failed (no-force + steal, design/02 §2.4): the redo pass skips the
--      page (phLsn guards) and the undo pass must still erase it — the
--      "losers = Running AND Aborted" deviation of Wal.Recovery,
--   D. recovery idempotence: a recovery interrupted at any point can be
--      resumed, a second recovery changes nothing,
--   E. the reopen/compatibility guards (internal/11 §11.2/§11.4): a page 0
--      without the HaskDB magic, a page-0 pageSize echo that disagrees with
--      the control file, a control pageSize that disagrees with the
--      configuration — each REFUSES, it never guesses.
module Main where

import System.Exit (exitFailure)
import qualified Data.ByteString as BS
import Data.Text (pack, unpack, isInfixOf)
import Data.IORef (newIORef, readIORef)
import Control.Monad (replicateM_, when)
import Control.Exception (SomeException, try, fromException)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, removeDirectoryRecursive)
import System.FilePath ((</>))

import HaskDB.Common.Types (LSN, SlotNum)
import HaskDB.Common.Config (Config, defaultConfig, cfgPageSize, cfgBufferFrames)
import HaskDB.Common.Error (SqlError(seMessage))
import HaskDB.Server.Env (envFileMgr, envWalMgr)
import HaskDB.Server.Control
import HaskDB.Wal.Recovery (recoverDatabase, scanRecords, scanEnd, dataFileName,
                                              walFileName, controlFileName)
import HaskDB.Wal.Manager
import HaskDB.Wal.Format
import HaskDB.Storage.FileManager
import HaskDB.Storage.Page (PageRef(..), PageKind(PKHeap), initPage, readSlot, pageSlice,
                            pageInsertTuple, pageSetTuple)
import HaskDB.Catalog.Bootstrap (checkPage0, mkPage0Image)
import HaskDB.Catalog.Types (page0PayloadOff)
import HaskDB.Common.Codec (buildToBytes, putW32le)

checkS :: String -> Bool -> [String] -> [String]
checkS name ok errs = if ok then errs else name : errs

-- The doctored-disk builders below use these fixed page/tuple names.  The
-- redo/undo layer works at byte level, so plain ByteStrings are enough here.
ps :: Int
ps = 512

tupA, tupB, tupC, tupD, tupD2, tupE, tupE2 :: BS.ByteString
tupA = "TA"
tupB = "TB"
tupC = "TC"
tupD = "TD"
tupD2 = "TD2"
tupE = "TE"
tupE2 = "TE2"

garbageTail :: BS.ByteString
garbageTail = "GARBAGE-NOT-A-RECORD"

-- | Read the tuple sitting in one slot of a page image (Nothing = free slot).
tupleAt :: BS.ByteString -> SlotNum -> IO (Maybe BS.ByteString)
tupleAt bytes n = do
  r <- newIORef bytes
  let pr = PageRef r
  ms <- readSlot pr n
  case ms of
    Just (o, l) -> fmap Just (pageSlice pr o l)
    Nothing     -> pure Nothing

-- | Run an IO action that must fail with a SqlError whose message contains
--   frag (the §11.2/§11.4 "die <message>" guards).
expectThrow :: String -> String -> IO () -> IO [String]
expectThrow note frag act = do
  r <- try act :: IO (Either SomeException ())
  pure $ case r of
    Right _ -> [note ++ ": the guard accepted a bad state (must refuse)"]
    Left e  -> case fromException e of
      Just ex  | isInfixOf (pack frag) (seMessage ex) -> []
               | otherwise -> [note ++ ": refused with the wrong message: "
                               ++ unpack (seMessage ex)]
      Nothing  -> [note ++ ": refused with a foreign exception: " ++ show e]

-- | An action that must NOT throw.
expectOk :: String -> IO () -> IO [String]
expectOk note act = do
  r <- try act :: IO (Either SomeException ())
  pure $ case r of
    Right _  -> []
    Left e   -> [note ++ ": unexpected error " ++ show e]

cfgFor :: FilePath -> Config
cfgFor dir = (defaultConfig dir) { cfgPageSize = ps, cfgBufferFrames = 16 }

-- | Build a fresh page image holding one tuple at slot 0; the page header is
--   stamped with lsn' (below every checkpoint written below it = "already
--   durable before the crash").
mkHeapPage :: Int -> BS.ByteString -> LSN -> IO BS.ByteString
mkHeapPage ps' tup lsn' = do
  r <- newIORef (BS.replicate ps' 0)
  let pr = PageRef r
  initPage pr PKHeap ps'
  _ <- pageInsertTuple pr lsn' tup
  readIORef r

-- ---------------------------------------------------------------------------
-- A/B. The doctored state: a committed txn below AND above the checkpoint
--   boundary, plus an ACTIVE txn (txn 9) named by a CHECKPOINT record that
--   made it into the WAL while the control write never happened.
--   Returns: recovered page-1 image, the two checkpoint offsets, the
--   resulting control cp, the WAL record count, and whether the WAL tail is
--   clean (the garbage tail must have been truncated).
-- ---------------------------------------------------------------------------
activeTxnState :: FilePath -> Bool -> IO (BS.ByteString, LSN, LSN, LSN, Int, Bool)
activeTxnState dir seedCk1 = do
  dd <- doesDirectoryExist dir
  when dd (removeDirectoryRecursive dir)
  createDirectoryIfMissing True dir
  let cfg = cfgFor dir
      dpath = dir </> dataFileName
      wpath = dir </> walFileName
      cpath = dir </> controlFileName
  fm <- openDataFile dpath ps
  replicateM_ 3 (extendFile fm)
  img1 <- mkHeapPage ps tupA 5
  writePageBytes fm 1 img1
  closeDataFile fm
  wal <- newWalManager wpath
  la  <- appendRecord wal (WalRecord WTInsertTuple 5 0 (PInsertTuple 1 0 tupA))
  _   <- appendRecord wal (WalRecord WTCommit 5 la PCommit)
  ck1 <- appendRecord wal (WalRecord WTCheckpoint 0 0 (PCheckpoint []))
  lb  <- appendRecord wal (WalRecord WTInsertTuple 7 0 (PInsertTuple 1 1 tupB))
  _   <- appendRecord wal (WalRecord WTCommit 7 lb PCommit)
  lc  <- appendRecord wal (WalRecord WTInsertTuple 9 0 (PInsertTuple 1 2 tupC))
  ck2 <- appendRecord wal (WalRecord WTCheckpoint 0 0 (PCheckpoint [(9, lc)]))
  _   <- flushWalUpTo wal ck2
  closeWalManager wal
  BS.appendFile wpath garbageTail
  -- the crash landed between the data fsync and writeControl: the control
  -- file still names ck1 (seedCk1 = False models an even older view, cp = 0)
  writeControl cpath ControlFile { cfPageSize = ps
                                 , cfCheckpointLSN = if seedCk1 then ck1 else 0
                                 , cfNextTid = 8 }
  env <- recoverDatabase cfg
  img <- readPageBytes (envFileMgr env) 1
  walNow <- readWalAll (envWalMgr env)
  ctl <- readControl cpath
  closeDataFile (envFileMgr env)
  closeWalManager (envWalMgr env)
  pure ( img, ck1, ck2, cfCheckpointLSN ctl
       , length (scanRecords walNow 0)
       , scanEnd walNow 0 == BS.length walNow )

activeTxnCase :: IO [String]
activeTxnCase = do
  (img, _ck1, ck2, cpNew, nrec, tailClean) <- activeTxnState "crash-test-a" True
  t0 <- tupleAt img 0
  t1 <- tupleAt img 1
  t2 <- tupleAt img 2
  let e1 = checkS "A: the pre-crash durable row is intact (slot0 = A)"
             (t0 == Just tupA) []
      e2 = checkS "A: the committed post-checkpoint row was REDONE (slot1 = B)"
             (t1 == Just tupB) e1
      e3 = checkS "A: the ACTIVE txn named by the checkpoint record was UNDONE"
             (t2 == Nothing) e2
      e4 = checkS "A: the stale control cp still saw the fresh checkpoint record"
             (cpNew > ck2) e3
      e5 = checkS "A: the garbage tail was truncated" tailClean e4
      e6 = checkS "A: 7 pre-crash records + the fresh checkpoint survive"
             (nrec == 8) e5
  pure e6

boundaryCase :: IO [String]
boundaryCase = do
  (imgA, ck1A, ck2A, cpA, nrecA, cleanA) <- activeTxnState "crash-test-b1" True
  (imgB, ck1B, ck2B, cpB, nrecB, cleanB) <- activeTxnState "crash-test-b2" False
  t0 <- tupleAt imgB 0
  t1 <- tupleAt imgB 1
  t2 <- tupleAt imgB 2
  let e1 = checkS "B: replay from cp=0 reaches the SAME visible state"
             (imgA == imgB && cpA == cpB && ck1A == ck1B && ck2A == ck2B) []
      e2 = checkS "B: the deeper replay adds no duplicate row (slot0 = A, slot1 = B)"
             (t0 == Just tupA && t1 == Just tupB) e1
      e3 = checkS "B: the active txn is undone in BOTH replays (slot2 free)"
             (t2 == Nothing) e2
      e4 = checkS "B: both replays end at the same WAL (records + clean tail)"
             (nrecA == nrecB && cleanA && cleanB) e3
  pure e4

-- ---------------------------------------------------------------------------
-- C. An ABORTED txn whose pages were flushed (stolen) before it failed.
-- ---------------------------------------------------------------------------
abortedStealCase :: IO [String]
abortedStealCase = do
  let dir = "crash-test-c"
  dd <- doesDirectoryExist dir
  when dd (removeDirectoryRecursive dir)
  createDirectoryIfMissing True dir
  let cfg = cfgFor dir
      dpath = dir </> dataFileName
      wpath = dir </> walFileName
      cpath = dir </> controlFileName
  wal <- newWalManager wpath
  ck1 <- appendRecord wal (WalRecord WTCheckpoint 0 0 (PCheckpoint []))
  la  <- appendRecord wal (WalRecord WTInsertTuple 11 0 (PInsertTuple 1 1 tupD))
  lb  <- appendRecord wal (WalRecord WTUpdateTuple 11 la (PUpdateTuple 1 1 tupD tupD2))
  lc  <- appendRecord wal (WalRecord WTInsertTuple 11 lb (PInsertTuple 1 2 tupE))
  ld  <- appendRecord wal (WalRecord WTUpdateTuple 11 lc (PUpdateTuple 1 2 tupE tupE2))
  _   <- appendRecord wal (WalRecord WTabort 11 ld PAbort)
  _   <- flushWalUpTo wal ld
  closeWalManager wal
  -- the "steal": BOTH of the aborted txn's after-images reached the data file
  --   (slots 1 and 2), each stamped with the record's own LSN, and the page was
  --   never checkpointed.  Undo must therefore walk the whole UPDATE -> INSERT
  --   chain for BOTH slots: skipping an UPDATE undo would leave the pre-update
  --   tuple (TD / TE) visible, skipping an INSERT undo would leave the after-
  --   image (TD2 / TE2), and both slots belong to the aborted txn, so the only
  --   legal end state has slots 1 and 2 EMPTY while the committed slot 0 (A)
  --   survives.
  fm <- openDataFile dpath ps
  replicateM_ 3 (extendFile fm)
  r <- newIORef (BS.replicate ps 0)
  let pr = PageRef r
  initPage pr PKHeap ps
  _ <- pageInsertTuple pr 5 tupA
  _ <- pageSetTuple pr lb 1 tupD2
  _ <- pageSetTuple pr ld 2 tupE2
  img <- readIORef r
  writePageBytes fm 1 img
  closeDataFile fm
  writeControl cpath ControlFile { cfPageSize = ps, cfCheckpointLSN = ck1
                                 , cfNextTid = 12 }
  env <- recoverDatabase cfg
  img2 <- readPageBytes (envFileMgr env) 1
  t0 <- tupleAt img2 0
  t1 <- tupleAt img2 1
  t2 <- tupleAt img2 2
  let e1 = checkS "C: the aborted txn's UPDATE-then-INSERT undo reached slot 1"
             (t1 == Nothing) []
      e2 = checkS "C: the same chain for the second slot too (no shortcut)"
             (t2 == Nothing) e1
      e3 = checkS "C: the unrelated committed row survived (slot0 = A)"
             (t0 == Just tupA) e2
  closeDataFile (envFileMgr env)
  closeWalManager (envWalMgr env)
  pure e3

-- ---------------------------------------------------------------------------
-- D. Recovery idempotence: a second recovery over an already-recovered state
--    changes nothing (the fresh checkpoint sits above every live record).
-- ---------------------------------------------------------------------------
idempotenceCase :: IO [String]
idempotenceCase = do
  (img1, _, _, cp1, nrec1, clean1) <- activeTxnState "crash-test-d" True
  let cfg = cfgFor "crash-test-d"
      cpath = "crash-test-d" </> controlFileName
  env2 <- recoverDatabase cfg
  img2 <- readPageBytes (envFileMgr env2) 1
  wal2 <- readWalAll (envWalMgr env2)
  ctl2 <- readControl cpath
  t0 <- tupleAt img2 0
  t1 <- tupleAt img2 1
  t2 <- tupleAt img2 2
  let e1 = checkS "D: the interrupted-then-resumed recovery reached the state"
             (nrec1 == 8 && clean1) []
      e2 = checkS "D: the second recovery left the page alone" (img1 == img2) e1
      e3 = checkS "D: still A,B and no C after the second recovery"
             (t0 == Just tupA && t1 == Just tupB && t2 == Nothing) e2
      e4 = checkS "D: only a fresh checkpoint record was appended (8 -> 9)"
             (length (scanRecords wal2 0) == nrec1 + 1) e3
      e5 = checkS "D: the checkpoint boundary advanced, not the state"
             (cfCheckpointLSN ctl2 > cp1) e4
  closeDataFile (envFileMgr env2)
  closeWalManager (envWalMgr env2)
  removeDirectoryRecursive "crash-test-d"
  pure e5

-- ---------------------------------------------------------------------------
-- E. The reopen guards (internal/11 §11.2 + §11.4): refuse, never guess.
-- ---------------------------------------------------------------------------
guardCase :: IO [String]
guardCase = do
  let good = "crash-test-good"
  gd <- doesDirectoryExist good
  when gd (removeDirectoryRecursive good)
  createDirectoryIfMissing True good
  let cfgGood = cfgFor good
  gm <- openDataFile (good </> dataFileName) ps
  replicateM_ 3 (extendFile gm)
  p0 <- mkPage0Image ps 7
  writePageBytes gm 0 p0
  closeDataFile gm
  writeControl (good </> controlFileName)
               ControlFile { cfPageSize = ps, cfCheckpointLSN = 0, cfNextTid = 1 }
  g1 <- expectOk "E0: a bootstrapped page 0 is accepted"
                 (checkPage0 cfgGood ControlFile { cfPageSize = ps
                                                 , cfCheckpointLSN = 0, cfNextTid = 1 })
  removeDirectoryRecursive good

  let zeroed = "crash-test-zeroed"
  zd <- doesDirectoryExist zeroed
  when zd (removeDirectoryRecursive zeroed)
  createDirectoryIfMissing True zeroed
  BS.appendFile (zeroed </> dataFileName) (BS.replicate ps 0)
  writeControl (zeroed </> controlFileName)
               ControlFile { cfPageSize = ps, cfCheckpointLSN = 0, cfNextTid = 1 }
  g2 <- expectThrow "E1: zeroed page 0" "not a bootstrapped"
                    (checkPage0 (cfgFor zeroed) ControlFile { cfPageSize = ps
                     , cfCheckpointLSN = 0, cfNextTid = 1 })
  removeDirectoryRecursive zeroed

  let echoBad = "crash-test-echobad"
  ed <- doesDirectoryExist echoBad
  when ed (removeDirectoryRecursive echoBad)
  createDirectoryIfMissing True echoBad
  p0bad <- mkPage0Image ps 7
  let patched = BS.take (page0PayloadOff + 8) p0bad
                <> buildToBytes (putW32le 1024)
                <> BS.drop (page0PayloadOff + 12) p0bad
  BS.appendFile (echoBad </> dataFileName) patched
  writeControl (echoBad </> controlFileName)
               ControlFile { cfPageSize = ps, cfCheckpointLSN = 0, cfNextTid = 1 }
  g3 <- expectThrow "E2: page 0's pageSize echo" "pageSize"
                    (checkPage0 (cfgFor echoBad) ControlFile { cfPageSize = ps
                     , cfCheckpointLSN = 0, cfNextTid = 1 })
  removeDirectoryRecursive echoBad

  let ctlBad = "crash-test-ctlbad"
  cb <- doesDirectoryExist ctlBad
  when cb (removeDirectoryRecursive ctlBad)
  createDirectoryIfMissing True ctlBad
  p0ok <- mkPage0Image ps 7
  BS.appendFile (ctlBad </> dataFileName) p0ok
  writeControl (ctlBad </> controlFileName)
               ControlFile { cfPageSize = ps + 128, cfCheckpointLSN = 0, cfNextTid = 1 }
  g4 <- expectThrow "E3: control pageSize disagrees with the config" "pageSize"
                    (checkPage0 (cfgFor ctlBad) ControlFile { cfPageSize = ps + 128
                     , cfCheckpointLSN = 0, cfNextTid = 1 })
  g5 <- expectThrow "E4: recoverDatabase refuses the pageSize disagreement"
                    "page size differs"
                    (do envBad <- recoverDatabase (cfgFor ctlBad)
                        closeDataFile (envFileMgr envBad)
                        closeWalManager (envWalMgr envBad))
  removeDirectoryRecursive ctlBad
  pure (g1 ++ g2 ++ g3 ++ g4 ++ g5)

-- ---------------------------------------------------------------------------
main :: IO ()
main = do
  eA <- activeTxnCase
  eB <- boundaryCase
  eC <- abortedStealCase
  eD <- idempotenceCase
  eE <- guardCase
  removeDirectoryRecursive "crash-test-a"
  removeDirectoryRecursive "crash-test-b1"
  removeDirectoryRecursive "crash-test-b2"
  removeDirectoryRecursive "crash-test-c"
  let errs = eA ++ eB ++ eC ++ eD ++ eE
  mapM_ putStrLn errs
  if null errs
    then putStrLn "crash-tests: PASS (checkpoint-with-active-txn, boundary equivalence, aborted-then-stolen undo, idempotent replay, reopen guards)"
    else do
      putStrLn ("crash-tests: " ++ show (length errs) ++ " failure(s)")
      exitFailure
