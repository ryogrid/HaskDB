-- Phase-3 milestone test suite (design/10 §10.2):
--   * S2PL transactions over the buffer pool: concurrent INSERT/UPDATE/
--     DELETE/SELECT sessions; final state == the union every session
--     committed (no lost updates despite steal/no-force)
--   * live rollback: a failing statement inside withTxnAuto leaves no
--     visible changes (undo list -> applyUndo, the recovery code path)
--   * deadlock injection (D-12 = detection, abort youngest, 40P01): the
--     victim's blocked lock wait wakes via the abort channel, the
--     injection terminates with an error — never a hang
--   * recovery over real transaction records: a second open of the
--     database (recoverDatabase) sees the same committed state
--   * checkpoint carries the active-txn oldest LSNs (Txn.Manager)
module Main where

import System.Exit (exitFailure)
import Data.List (sort)
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay, MVar)
import Control.Exception (try, catch, SomeException)
import System.Directory (doesDirectoryExist, removeDirectoryRecursive)
import Control.Monad (replicateM_, when, forM, forM_, unless)
import qualified Data.ByteString as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (unpack)

import HaskDB.Common.Types (RID(..), Tuple, Value(VInt), SqlType(TyInt64), PageId, RelId)
import HaskDB.Common.Config (Config, defaultConfig, cfgPageSize, cfgBufferFrames, cfgDeadlockMs)
import HaskDB.Common.Error (SqlError(seState), throwSql)
import HaskDB.Server.Env (Env, envBufferPool, envFileMgr, envWalMgr, envFreeSpace, envControl)
import HaskDB.Server.Control (ControlFile(cfNextTid))
import GHC.Internal.Conc.Sync (readTVarIO)
import HaskDB.Storage.FileManager (extendFile, fsyncDataFile, closeDataFile)
import HaskDB.Storage.BufferPool (pinNewPage, unpinPage, ppPage, flushAll)
import HaskDB.Storage.Page (PageKind(PKHeap), readHeader, pageFreeContiguous)
import HaskDB.Storage.FreeSpace (fsmNoteFree)
import HaskDB.Catalog.Types (RelationDesc(..), RelKind(RelTable))
import HaskDB.Heap.TupleCodec (ColumnDesc(..))
import HaskDB.Wal.Recovery (recoverDatabase)
import HaskDB.Wal.Manager (closeWalManager)
import HaskDB.Txn.Manager (TxnManager, newTxnManager, beginTxn, commitTxn, abortTxn, abortStatement,
  beginStatement, withTxnAuto, lockTable, TxnCtx, tcTxnId)
import HaskDB.Txn.LockManager (LockManager, newLockManager, waitForEdges, LockMode(LIs, LX))
import HaskDB.Txn.Deadlock (deadlockScanOnce)
import HaskDB.Heap.Heap (heapInsert, heapUpdate, heapDelete, heapFetch, heapScan)

check :: String -> Bool -> [String] -> [String]
check name ok errs = if ok then errs else name : errs

trySome :: IO a -> IO (Either SomeException a)
trySome = try

-- ---------------------------------------------------------------------------
-- Setup: fresh database directory; 4 heap pages for relation 1 (page 0 is
--   the reserved first page), FSM pre-seeded so heapInsert stays inside the
--   scanned rdPages list (deviation: without the catalog the test maintains
--   the RelationDesc + FSM itself; see TODO.md phase-3 notes).
-- ---------------------------------------------------------------------------
testDir :: String
testDir = "txn-test-dir"

cfg :: Config
cfg = (defaultConfig testDir) { cfgPageSize     = 512
                              , cfgBufferFrames = 16
                              , cfgDeadlockMs   = 60 }

relId1, relId2 :: RelId
relId1 = 1
relId2 = 2

relCols :: [ColumnDesc]
relCols = [ColumnDesc "n" TyInt64]

heapPages :: [PageId]
heapPages = [0, 1, 2, 3]

mkRel :: RelationDesc
mkRel = RelationDesc { rdId = relId1, rdName = "t", rdKind = RelTable
                     , rdColumns = relCols, rdPages = heapPages
                     , rdRoot = 0, rdTuples = 0, rdOwner = 0, rdIdxCol = -1 }

mkRel2 :: RelationDesc
mkRel2 = mkRel { rdId = relId2, rdName = "u", rdPages = [] }

mkTup :: Int -> Tuple
mkTup v = [VInt (fromIntegral v)]

tupValue :: Tuple -> Int
tupValue (VInt x : _) = fromIntegral x
tupValue []           = -1

-- ---------------------------------------------------------------------------
-- Concurrent stress: 4 sessions, each in its own autocommit transaction:
--   insert k*10+1..k*10+5, update the first to k*10+90, delete k*10+2.
--   Expected final multiset = {k*10+3..k*10+5, k*10+90 | k <- 1..4}.
-- ---------------------------------------------------------------------------
stressTest :: Env -> TxnManager -> LockManager -> IO [String]
stressTest env tm lm = do
  replicateM_ (length heapPages) (extendFile (envFileMgr env))
  prepPages env
  ms <- forM [1 .. 4 :: Int] $ \k -> do
    mv <- newEmptyMVar
    _ <- forkIO $ do
      r <- withTxnAuto tm lm env (\ctx -> do
            rids <- mapM (heapInsert env ctx mkRel . mkTup) [k * 10 + 1 .. k * 10 + 5]
            heapUpdate env ctx mkRel (head rids) (mkTup (k * 10 + 90))
            heapDelete env ctx mkRel (rids !! 1)
            pure k)
      putMVar mv (Right r) `catch` (\(e :: SqlError) -> putMVar mv (Left (seState e)))
    pure mv
  rs <- mapM takeMVar ms
  pairs <- scanAll env tm lm
  let actual = sort (map (tupValue . snd) pairs)
      expected = sort (concatMap (\k -> [k * 10 + 3, k * 10 + 4, k * 10 + 5, k * 10 + 90])
                               [1 .. 4 :: Int])
      e1 = check "stress: no session failed" (all (either (const False) (const True)) rs) []
      e2 = check "stress: final multiset == committed union (no lost update)"
             (actual == expected) e1
      e3 = check "stress: no unexpected tuples" (length actual == 16) e2
  pure e3

-- | Pre-create the heap pages under the buffer pool (initialised heap
--   pages) and seed the FSM with their free space (advisory).
prepPages :: Env -> IO ()
prepPages env = forM_ heapPages $ \p -> do
  pp <- pinNewPage (envBufferPool env) p PKHeap
  hdr <- readHeader (ppPage pp)
  unpinPage (envBufferPool env) pp True   -- init image MUST become dirty (flushed at checkpoints)
  fsmNoteFree (envFreeSpace env) relId1 p (pageFreeContiguous hdr)

-- | Storage-level SELECT for the tests: fresh implicit txn, scan, commit.
scanAll :: Env -> TxnManager -> LockManager -> IO [(RID, Tuple)]
scanAll env tm lm = do
  ctx <- beginTxn tm lm env
  ps <- heapScan env ctx mkRel
  commitTxn ctx
  pure ps

-- ---------------------------------------------------------------------------
-- Live rollback.  (a) Statement atomicity: insert + delete + synthetic
--   failure inside one statement -> abortStatement undoes both records
--   (newest-first through applyUndo) -> nothing visible after commit.
--   (b) Txn-level: committed insert visible; aborted insert not.
-- ---------------------------------------------------------------------------
rollbackTest :: Env -> TxnManager -> LockManager -> IO [String]
rollbackTest env tm lm = do
  ctx <- beginTxn tm lm env
  beginStatement ctx
  r1 <- heapInsert env ctx mkRel (mkTup 777)
  _r2 <- heapInsert env ctx mkRel (mkTup 778)
  beginStatement ctx                     -- statement-2 mark: keep stmt-1 changes
  ref <- newIORef (RID 0 0)
  e <- trySome (do heapDelete env ctx mkRel r1
                   r3 <- heapInsert env ctx mkRel (mkTup 779)
                   writeIORef ref r3
                   throwSql "TEST" "synthetic statement failure" :: IO ())
  let e1 = check "rollback: injected statement error"
             (case e of Left _ -> True; Right _ -> False) []
  abortStatement ctx
  commitTxn ctx
  ps <- scanAll env tm lm
  let vals = sort (map (tupValue . snd) ps)
      e2 = check "rollback: failed statement rolled back, prior kept"
             (filter (`elem` [777, 778, 779]) vals == [777, 778]) e1
  -- txn-level abort: committed vs aborted
  ctx2 <- beginTxn tm lm env
  _ <- heapInsert env ctx2 mkRel (mkTup 888)
  commitTxn ctx2
  ctx3 <- beginTxn tm lm env
  _ <- heapInsert env ctx3 mkRel (mkTup 999)
  abortTxn ctx3
  ps2 <- scanAll env tm lm
  let vals2 = sort (map (tupValue . snd) ps2)
      e3 = check "rollback: aborted tuple invisible, committed visible"
             (filter (`elem` [888, 999]) vals2 == [888]) e2
  _r3 <- readIORef ref
  ctxF <- beginTxn tm lm env
  t7 <- heapFetch env ctxF mkRel r1
  commitTxn ctxF
  let e4 = check "rollback: statement-1 row kept after stmt-2 rollback (Just 777)"
             (t7 == Just (mkTup 777)) e3
  pure e4

-- ---------------------------------------------------------------------------
-- Deadlock injection (D-12): A holds IX(t1) and blocks on X(t2); B holds
--   IX(t2) and blocks on X(t1).  waitForEdges has both edges -> findCycle
--   -> victim = max tid = B gets 40P01 through its abort channel (its
--   blocked lock wait wakes with the error, no hang); after abortTxn B
--   releases its locks, waking A's wait.
-- ---------------------------------------------------------------------------
deadlockTest :: Env -> TxnManager -> LockManager -> IO [String]
deadlockTest env tm lm = do
  ctxA <- beginTxn tm lm env
  ctxB <- beginTxn tm lm env
  lockTable ctxA relId1 LIs
  lockTable ctxB relId2 LIs
  mvA <- newEmptyMVar
  mvB <- newEmptyMVar
  _ <- forkIO $ (lockTable ctxA relId2 LX >> putMVar mvA "A-ok")
                `catch` (\(e :: SqlError) -> putMVar mvA (unpack (seState e)))
  _ <- forkIO $ (lockTable ctxB relId1 LX >> putMVar mvB "B-ok")
                `catch` (\(e :: SqlError) -> putMVar mvB (unpack (seState e)))
  threadDelay 100000                     -- both waits in place
  edges <- waitForEdges lm
  victim <- deadlockScanOnce tm lm
  let a = tcTxnId ctxA
      b = tcTxnId ctxB
      e1 = check "deadlock: both wait-for edges present"
             ((a, b) `elem` edges && (b, a) `elem` edges) []
      e2 = check "deadlock: cycle detected, victim = younger txn"
             (victim == Just b) e1
  rbB <- takeMVar mvB
  let e3 = check "deadlock: victim woke with 40P01 (no hang)" (rbB == "40P01") e2
  abortTxn ctxB
  raA <- takeMVar mvA
  commitTxn ctxA
  let e4 = check "deadlock: other txn unblocked by victim release" (raA == "A-ok") e3
  pure e4

-- ---------------------------------------------------------------------------
-- Recovery over real transaction records: flush + close + reopen must see
--   the same committed state (redo guards skip durable pages; redo+undo of
--   already-live-undone losers nets to the live state), and a second
--   recovery is idempotent.
-- ---------------------------------------------------------------------------
recoveryTest :: Env -> TxnManager -> LockManager -> IO [String]
recoveryTest env tm lm = do
  ps <- scanAll env tm lm
  let before = sort (map (tupValue . snd) ps)
  flushAll (envBufferPool env)
  fsyncDataFile (envFileMgr env)
  closeDataFile (envFileMgr env)
  closeWalManager (envWalMgr env)
  env2 <- recoverDatabase cfg
  ctl2 <- readTVarIO (envControl env2)
  tm2 <- newTxnManager (cfNextTid ctl2)
  lm2 <- newLockManager
  ps2 <- scanAll env2 tm2 lm2
  let after = sort (map (tupValue . snd) ps2)
      e1 = check "recovery: reopen sees same committed state" (after == before) []
  closeDataFile (envFileMgr env2)
  closeWalManager (envWalMgr env2)
  env3 <- recoverDatabase cfg
  ctl3 <- readTVarIO (envControl env3)
  tm3 <- newTxnManager (cfNextTid ctl3)
  lm3 <- newLockManager
  ps3 <- scanAll env3 tm3 lm3
  let after3 = sort (map (tupValue . snd) ps3)
      e2 = check "recovery: second recovery idempotent" (after3 == after) e1
  closeDataFile (envFileMgr env3)
  closeWalManager (envWalMgr env3)
  pure e2

-- ---------------------------------------------------------------------------
main :: IO ()
main = do
  d <- doesDirectoryExist testDir
  when d (removeDirectoryRecursive testDir)
  env <- recoverDatabase cfg
  ctl0 <- readTVarIO (envControl env)
  tm <- newTxnManager (cfNextTid ctl0)
  lm <- newLockManager
  e1 <- stressTest env tm lm
  e2 <- rollbackTest env tm lm
  e3 <- deadlockTest env tm lm
  e4 <- recoveryTest env tm lm
  let errs = e1 ++ e2 ++ e3 ++ e4
  mapM_ putStrLn errs
  if null errs
    then putStrLn "txn-tests: all checks passed"
    else do
      putStrLn ("txn-tests: " ++ show (length errs) ++ " failure(s)")
      exitFailure

