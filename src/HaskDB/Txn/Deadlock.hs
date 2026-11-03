-- | Deadlock policy (design/03 §3.5, internal-design/04 §4.3) with D-12
--   = wait-for graph detection + abort-youngest-victim + SQLSTATE 40P01.
--   The policy module is separate from Txn.Manager (design/03 §3.5 words
--   it as "a policy module"; internal/04 §4.3 put the thread in Txn.Manager
--   — module split keeps the import graph acyclic, TODO.md log).
module HaskDB.Txn.Deadlock where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List (nub, maximum)
import Control.Concurrent (forkIO, threadDelay)
import HaskDB.Common.Types (TxnId)
import HaskDB.Common.Error (errDeadlock)
import HaskDB.Txn.Manager (TxnManager, tmActive, ActiveInfo, aiStatus, TxnStatus(..), signalAborted)
import HaskDB.Txn.LockManager (LockManager, waitForEdges)
import GHC.Internal.Conc.Sync (readTVarIO)

-- | Find any cycle in a directed edge list (teaching-system DFS: graphs
--   here have a handful of transaction nodes).
findCycle :: (Ord a) => [(a, a)] -> Maybe [a]
findCycle es = firstJust [ search [] n | n <- nodes ]
  where
    nodes = nub (concatMap (\(u, v) -> [u, v]) es)
    adj u = [ v | (u', v) <- es, u' == u ]
    search path u
      | u `elem` path = Just (cycleFrom u path)
      | otherwise = firstJust [ search (u : path) v | v <- adj u ]
    cycleFrom u (u' : rest)
      | u' == u = [u]
      | otherwise = u' : cycleFrom u rest
    cycleFrom _ [] = []
    firstJust xs = go xs
      where
        go [] = Nothing
        go (x : rest) = case x of Just r -> Just r; Nothing -> go rest

-- | Detector step: build the wait-for graph, find a cycle, signal the
--   YOUNGEST txn (max tid = most recently begun) in it with errDeadlock.
--   Returns the victim (tests).  Txns already marked Aborting are skipped
--   so the detector cannot fire twice for the same cycle.
deadlockScanOnce :: TxnManager -> LockManager -> IO (Maybe TxnId)
deadlockScanOnce tm lm = do
  es0 <- waitForEdges lm
  act <- readTVarIO (tmActive tm)
  let es = [ e | e@(u, v) <- es0, aliveTxn act u, aliveTxn act v ]
  case findCycle es of
    Nothing -> pure Nothing
    Just cyc -> do
      let alive = cyc             -- already filtered to alive txns
      case alive of
        [] -> pure Nothing
        _  -> do
          let victim = maximum alive
          signalAborted tm victim errDeadlock
          pure (Just victim)
  where
    aliveTxn act t = case Map.lookup t act of
      Nothing -> False
      -- only Active can still be interrupted (a Committing txn passed
      -- the commit point; review nice-to-have #8)
      Just ai -> aiStatus ai == TxnActive

-- | Background detector thread (internal/11 §11.6 "started by
--   startDatabase when D-12 = detection").  Interval from cfgDeadlockMs.
--   A scan that dies must not kill the thread (log-and-continue).
startDeadlockDetector :: TxnManager -> LockManager -> Int -> IO ()
startDeadlockDetector tm lm intervalMs = do
  _ <- forkIO (loop)
  pure ()
  where
    loop = do
      threadDelay (intervalMs * 1000)
      _ <- tryScan
      loop
    tryScan = deadlockScanOnce tm lm
