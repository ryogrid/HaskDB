-- | STM lock manager (internal-design/04 §4.4, design/03 §3.4) —
--   S2PL baseline: intention modes IS/IX on tables, S/X on rows,
--   FIFO fairness, S->X upgrade via the coverage+conflict rule.
--   Structure refinements vs the docs (TODO.md log):
--   * `lock` takes the txn id and the abort-channel TVar explicitly
--     instead of a TxnCtx (avoids a Txn.Manager <-> LockManager module
--     cycle; the ctx-taking helpers live in Txn.Manager),
--   * `lmWaitIdx` is the docs' waiter-index map, extended to record
--     GRANTED objects too, so unlockAll never scans the whole table.
module HaskDB.Txn.LockManager where

import qualified Data.Map.Strict as Map
import Control.Monad (when)
import Data.List (find)
import Control.Monad.STM (atomically, retry)
import GHC.Internal.Conc.Sync (TVar, newTVarIO, readTVar, writeTVar, readTVarIO, newTVar, STM)
import Control.Exception (throwIO)
import HaskDB.Common.Error (SqlError(..))
import HaskDB.Common.Types (TxnId, RelId, RID)

-- internal/04 §4.4 lockable objects + modes
data LockObject
  = LTable RelId
  | LRow   RelId RID
  deriving (Eq, Ord, Show)

data LockMode = LIs | LIx | LS | LX   -- intention-shared / intention-excl / shared / excl
  deriving (Eq, Show)

data LockEntry = LockEntry
  { leGranted :: !(Map.Map TxnId LockMode)
  , leWaiters :: ![(TxnId, LockMode, TVar Bool)] }  -- FIFO; flag flips True on grant

-- | Standard IS/IX/S/X conflict matrix (internal/04 §4.4): X conflicts
--   with everything (incl. IS); IX conflicts with S and X; S conflicts
--   with IX and X; IS conflicts only with X.
modeConflict :: LockMode -> LockMode -> Bool
modeConflict granted req
  | granted == LX = True
  | req == LX = True
  | granted == LIx = req == LS
  | granted == LS = req == LIx
  | otherwise = False   -- granted == LIs: only X (handled above) conflicts

-- | Lattice IS < {S, IX} < X (S and IX incomparable; IX beats S on
--   combine = writer intent kept).
coversLock :: LockMode -> LockMode -> Bool
coversLock own req
  | own == req = True
  | own == LX = True
  | own == LIx && req == LIs = True
  | own == LS && req == LIs = True
  | otherwise = False

combineMode :: LockMode -> LockMode -> LockMode
combineMode own req
  | own == LX || req == LX = LX
  | own == LIx || req == LIx = LIx
  | own == LS || req == LS = LS
  | otherwise = LIs

-- | Is `req` compatible with all granted modes except the txn's own?
compatible :: LockEntry -> TxnId -> LockMode -> Bool
compatible entry txn req =
  all (\m -> not (modeConflict m req))
      [ m | (t, m) <- Map.toList (leGranted entry), t /= txn ]

-- | FIFO fairness (design/03 §3.4): no granted request may jump ahead
--   of an earlier waiter whose mode conflicts.
noEarlierConflict :: [(TxnId, LockMode, TVar Bool)] -> TxnId -> LockMode -> Bool
noEarlierConflict ws txn req =
  all (\(_, m, _) -> not (modeConflict m req))
      (takeWhile (\(w, _, _) -> w /= txn) ws)

data LockManager = LockManager
  { lmTable    :: TVar (Map.Map LockObject LockEntry)
  , lmWaitIdx  :: TVar (Map.Map TxnId [LockObject]) }

newLockManager :: IO LockManager
newLockManager = do
  t <- newTVarIO Map.empty
  i <- newTVarIO Map.empty
  pure LockManager { lmTable = t, lmWaitIdx = i }

-- docs record granted objects here too (see header)
recordObj :: LockManager -> TxnId -> LockObject -> STM ()
recordObj lm txn obj = do
  idx <- readTVar (lmWaitIdx lm)
  let cur = Map.findWithDefault [] txn idx
  if obj `elem` cur then pure ()
    else writeTVar (lmWaitIdx lm) (Map.insert txn (cur ++ [obj]) idx)

-- | Grant: also DEQUEUE the txn's queued request if any (a granted entry
--   must not linger in leWaiters — review MUST-FIX #2).
grantEntry :: LockEntry -> TxnId -> LockMode -> LockEntry
grantEntry e txn mode =
  e { leGranted = Map.insert txn (combineMode (Map.findWithDefault LIs txn (leGranted e)) mode)
                 (leGranted e)
    , leWaiters = filter (\(w, _, _) -> w /= txn) (leWaiters e) }

-- | The docs' lock flow: fast path and queueing in one STM transaction.
--   On queueing, returns the waiter's flag TVar for the wait loop.
tryGrant :: LockManager -> TxnId -> LockObject -> LockMode -> STM (Maybe (TVar Bool))
tryGrant lm txn obj mode = do
  tbl <- readTVar (lmTable lm)
  let entry = Map.findWithDefault (LockEntry Map.empty []) obj tbl
      own   = Map.lookup txn (leGranted entry)
  case own of
    Just g | coversLock g mode -> recordObj lm txn obj >> pure Nothing
    _ -> do
      let ws     = leWaiters entry
          others = compatible entry txn mode
          aheadOk = noEarlierConflict ws txn mode
      if others && aheadOk
        then case findQueued ws txn of
          Just (_, _, fl) -> do
            writeTVar fl True
            writeTVar (lmTable lm) (Map.insert obj (grantEntry entry txn mode) tbl)
            recordObj lm txn obj
            pure Nothing
          Nothing -> do
            writeTVar (lmTable lm) (Map.insert obj (grantEntry entry txn mode) tbl)
            recordObj lm txn obj
            pure Nothing
        else case findQueued ws txn of
          Just (_, _, fl) -> pure (Just fl)
          Nothing -> do
            fl <- newTVar False
            writeTVar (lmTable lm)
              (Map.insert obj (entry { leWaiters = ws ++ [(txn, mode, fl)] }) tbl)
            recordObj lm txn obj
            pure (Just fl)

-- | Wait loop racing the abort channel (internal/04 §4.3): the loop
--   reads the granted-flag and the txn's abort TVar; `retry` wakes on
--   either change.  A set abort flag throws the channel error
--   (re-raised to the session, which rolls back via abortTxn).
lock :: LockManager -> TxnId -> TVar (Maybe SqlError)
     -> LockObject -> LockMode -> IO ()
lock lm txn abort obj mode = do
  r <- atomically (tryGrant lm txn obj mode)
  case r of
    Nothing -> pure ()
    Just fl -> waitLoop fl abort
  where
    waitLoop fl abort = do
      ready <- atomically $ do
        e <- readTVar abort          -- abort channel wins over a grant
        case e of
          Just err -> pure (Left err)
          Nothing -> do
            b <- readTVar fl
            if b then pure (Right ()) else retry
      case ready of
        Left err -> throwIO err
        Right () -> pure ()

findQueued :: [(TxnId, LockMode, TVar Bool)] -> TxnId -> Maybe (TxnId, LockMode, TVar Bool)
findQueued ws txn = find (\(w, _, _) -> w == txn) ws

-- | Release one object held/waited by the txn and re-grant unblocked
--   waiters in FIFO order.  Fairness (design/03 §3.4): a waiter is
--   granted only if compatible with the (post-release) granted set
--   EXCLUDING its own held mode (upgrade case) and with all earlier
--   waiters that remain blocked.  Flags of granted waiters flip True,
--   waking their `lock` wait loops.
regrant :: LockEntry -> TxnId -> (LockEntry, [TVar Bool])
regrant e0 txn = walk (filter (\(w, _, _) -> w /= txn) (leWaiters e0)) granted0 [] []
  where
    granted0 = Map.delete txn (leGranted e0)
    walk [] granted blockedW flipped =
      ( LockEntry { leGranted = granted, leWaiters = reverse blockedW }
      , reverse flipped )
    walk ((wid, m, fl) : rest) granted blockedW flipped
      | ok = walk rest (Map.insert wid (combineMode own m) granted) blockedW (fl : flipped)
      | otherwise = walk rest granted ((wid, m, fl) : blockedW) flipped
      where
        own = Map.findWithDefault LIs wid granted
        ok = all (\mm -> not (modeConflict mm m))
                 [ mm | (t, mm) <- Map.toList granted, t /= wid ]
            && all (\bm -> not (modeConflict bm m)) [ bm | (_, bm, _) <- blockedW ]

unlock1 :: LockManager -> TxnId -> LockObject -> STM ()
unlock1 lm txnId obj = do
  tbl <- readTVar (lmTable lm)
  case Map.lookup obj tbl of
    Nothing -> pure ()
    Just entry -> do
      let (entry', flags) = regrant entry txnId
      mapM_ (\fl -> writeTVar fl True) flags
      if Map.null (leGranted entry') && null (leWaiters entry')
        then writeTVar (lmTable lm) (Map.delete obj tbl)
        else writeTVar (lmTable lm) (Map.insert obj entry' tbl)

-- | Release one object (used by statement-level lock release, internal/04
--   §4.2: "locks acquired by the failed statement are released").
unlockObj :: LockManager -> TxnId -> LockObject -> IO ()
unlockObj lm txnId obj = atomically (unlock1 lm txnId obj)

-- | Release everything the txn touched — granted objects and waiters —
--   via the wait-index map (no full-table scan, internal/04 §4.4).
unlockAll :: LockManager -> TxnId -> IO ()
unlockAll lm txnId = do
  idx <- readTVarIO (lmWaitIdx lm)
  let touched = Map.findWithDefault [] txnId idx
  mapM_ (\obj -> atomically (unlock1 lm txnId obj)) touched
  atomically $ do
    idx' <- readTVar (lmWaitIdx lm)
    writeTVar (lmWaitIdx lm) (Map.delete txnId idx')

-- | Deadlock-policy seam (internal/04 §4.3): edges waiter -> each
--   conflicting granted holder; the policy module finds the cycles.
waitForEdges :: LockManager -> IO [(TxnId, TxnId)]
waitForEdges lm = do
  tbl <- readTVarIO (lmTable lm)
  pure [ (wid, holder)
       | entry <- Map.elems tbl
       , (wid, wm, _) <- leWaiters entry
       , (holder, hg) <- Map.toList (leGranted entry)
       , holder /= wid
       , modeConflict hg wm ]

