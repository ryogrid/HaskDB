-- | Transaction manager + transaction context (internal-design/04 §4.1-4.2,
--   design/03 §3.3).  `txnAppend` is the single WAL choke point: it chains
--   wrPrevTxn from tlsLastLSN and records the undo LSN, so the undo list
--   can never desync from the WAL (the §4.1 guarantee).
--   Structure deviations vs the docs (TODO.md log):
--   * the txn/lock/WAL managers travel inside TxnCtx instead of inside
--     Env (internal/11 §11.2 assumed them there): the module graph stays
--     acyclic, and the docs' heap-op signatures (Env -> TxnCtx -> ...)
--     keep working unchanged,
--   * beginTxn takes the managers explicitly (the session/server bundle
--     owns them); commitTxn/abortTxn/abortStatement take only the ctx,
--     as the docs' §4.2 flows show,
--   * tmActive maps to ActiveInfo = (status, oldest-undo IORef, abort-
--     channel TVar): the docs' (TxnStatus, IORef LSN) plus the §4.3
--     channel so the deadlock policy signals without a second registry.
module HaskDB.Txn.Manager where

import qualified Data.Map.Strict as Map
import Control.Monad.STM (atomically)
import GHC.Internal.Conc.Sync (TVar, newTVarIO, readTVar, writeTVar, readTVarIO, newTVar)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Control.Exception (try, throwIO, SomeException, fromException)
import HaskDB.Common.Types (TxnId, LSN, RID, RelId)
import Data.Text (pack)
import HaskDB.Common.Error (SqlError(..), errInternal)
import HaskDB.Server.Env (Env(envWalMgr))
import HaskDB.Wal.Manager (WalManager, appendRecord, flushWalUpTo, readRecordAt)
import HaskDB.Wal.Format (WalPayload(..), walRecord)
import HaskDB.Wal.Apply (applyUndo)
import HaskDB.Txn.LockManager (LockManager, lock, unlockAll, unlockObj, LockObject(..), LockMode(..))

data TxnStatus = TxnActive | TxnCommitting | TxnAborting
  deriving (Eq, Show)

-- internal/04 §4.1 TxnLocalState (+ statement/lock marks of §4.2)
data TxnLocalState = TxnLocalState
  { tlsLastLSN  :: !LSN
  , tlsUndo     :: [LSN]        -- change-record LSNs, newest first
  , tlsStmtMark :: !Int         -- length of tlsUndo at statement start
  , tlsLockMark :: !Int }       -- length of tcLocks at statement start
  deriving (Show)

data ActiveInfo = ActiveInfo
  { aiStatus :: !TxnStatus
  , aiOldest :: !(IORef LSN)                  -- oldest still-undone LSN
  , aiAbort  :: !(TVar (Maybe SqlError)) }    -- §4.3 abort channel

data TxnManager = TxnManager
  { tmNextTid :: TVar TxnId
  , tmActive  :: TVar (Map.Map TxnId ActiveInfo) }

-- | Transaction context (internal/04 §4.1) plus manager handles
--   (deviation: managers live here, not in Env — see header).
data TxnCtx = TxnCtx
  { tcEnv      :: Env
  , tcTxnId    :: !TxnId
  , tcState    :: TVar TxnLocalState
  , tcAbort    :: TVar (Maybe SqlError)   -- same TVar as ActiveInfo's
  , tcLocks    :: TVar [LockObject]       -- acquired, newest first
  , tcWalMgr   :: WalManager
  , tcLockMgr  :: LockManager
  , tcTxnMgr   :: TxnManager }

newTxnManager :: TxnId -> IO TxnManager
newTxnManager tid0 = do
  n <- newTVarIO tid0
  a <- newTVarIO Map.empty
  pure TxnManager { tmNextTid = n, tmActive = a }

-- | beginTxn flow (internal/04 §4.2): allocate id, register as active.
beginTxn :: TxnManager -> LockManager -> Env -> IO TxnCtx
beginTxn tm lm env = do
  ref0 <- newIORef 0        -- IORef created outside STM (per-txn oldest LSN)
  (tid, ai) <- atomically $ do
    tid <- readTVar (tmNextTid tm)
    writeTVar (tmNextTid tm) (tid + 1)
    fl <- newTVar Nothing
    let info = ActiveInfo { aiStatus = TxnActive, aiOldest = ref0, aiAbort = fl }
    act <- readTVar (tmActive tm)
    writeTVar (tmActive tm) (Map.insert tid info act)
    pure (tid, info)
  st <- newTVarIO TxnLocalState { tlsLastLSN = 0
                                , tlsUndo = [], tlsStmtMark = 0, tlsLockMark = 0 }
  lck <- newTVarIO []
  pure TxnCtx { tcEnv = env, tcTxnId = tid, tcState = st
              , tcAbort = aiAbort ai, tcLocks = lck
              , tcWalMgr = envWalMgr env, tcLockMgr = lm, tcTxnMgr = tm }

-- | Abort-channel check at operation boundaries (internal/04 §4.3
--   "checked by lock waits and statement boundaries").
checkAbort :: TxnCtx -> IO ()
checkAbort ctx = do
  e <- readTVarIO (tcAbort ctx)
  case e of
    Just err -> throwIO err
    Nothing  -> pure ()

-- | Statement marks (internal/04 §4.2): statement-atomicity rollback
--   undoes down to these marks.
beginStatement :: TxnCtx -> IO ()
beginStatement ctx = do
  n <- readTVarIO (tcState ctx)
  ls <- readTVarIO (tcLocks ctx)
  atomically $ writeTVar (tcState ctx)
    (n { tlsStmtMark = length (tlsUndo n), tlsLockMark = length ls })

findActive :: TxnCtx -> IO (Maybe ActiveInfo)
findActive ctx = do
  act <- readTVarIO (tmActive (tcTxnMgr ctx))
  pure (Map.lookup (tcTxnId ctx) act)

setStatusOf :: TxnManager -> TxnId -> TxnStatus -> IO ()
setStatusOf tm tid st = atomically $ do
  act <- readTVar (tmActive tm)
  case Map.lookup tid act of
    Nothing  -> pure ()
    Just ai  -> writeTVar (tmActive tm)
                  (Map.insert tid ai { aiStatus = st } act)

removeActive :: TxnCtx -> IO ()
removeActive ctx = atomically $ do
  act <- readTVar (tmActive (tcTxnMgr ctx))
  writeTVar (tmActive (tcTxnMgr ctx))
    (Map.delete (tcTxnId ctx) act)

-- | Lock entry points for the executor/storage layers (design/03 §3.4:
--   the only ways to take locks).  noteLock BEFORE the wait: a request
--   that throws via the abort channel must still be releasable at
--   statement boundaries (internal/04 §4.2 reads stricter than a
--   grant-only record).
noteLock :: TxnCtx -> LockObject -> IO ()
noteLock ctx obj = atomically $ do
  ls <- readTVar (tcLocks ctx)
  if obj `elem` ls then pure ()
    else writeTVar (tcLocks ctx) (obj : ls)

lockObj :: TxnCtx -> LockObject -> LockMode -> IO ()
lockObj ctx obj mode = do
  noteLock ctx obj
  lock (tcLockMgr ctx) (tcTxnId ctx) (tcAbort ctx) obj mode

lockTable :: TxnCtx -> RelId -> LockMode -> IO ()
lockTable ctx rel mode = lockObj ctx (LTable rel) mode

lockRow :: TxnCtx -> RelId -> RID -> LockMode -> IO ()
lockRow ctx rel rid mode = lockObj ctx (LRow rel rid) mode

-- | THE WAL choke point (internal/04 §4.1): every storage-writing path
--   appends through here; wrPrevTxn comes from tlsLastLSN, and the LSN
--   feeds the undo list and the manager's oldest-undo IORef.
txnAppend :: TxnCtx -> WalPayload -> IO LSN
txnAppend ctx payload = do
  checkAbort ctx
  st <- atomically (readTVar (tcState ctx))
  let rec = walRecord (tcTxnId ctx) (tlsLastLSN st) payload
  lsn <- appendRecord (tcWalMgr ctx) rec
  let undo' = lsn : tlsUndo st
  atomically $ writeTVar (tcState ctx) st { tlsLastLSN = lsn
                                          , tlsUndo = undo' }
  info <- findActive ctx
  case info of
    Just ai -> writeIORef (aiOldest ai) (last undo')
    Nothing -> pure ()
  pure lsn

-- | Release locks acquired by the failed statement (internal/04 §4.2).
releaseStmtLocks :: TxnCtx -> IO ()
releaseStmtLocks ctx = do
  ls <- readTVarIO (tcLocks ctx)
  st <- readTVarIO (tcState ctx)
  let n = length ls - tlsLockMark st
      fresh = take n ls
  mapM_ (\obj -> unlockObj (tcLockMgr ctx) (tcTxnId ctx) obj) fresh
  atomically $ writeTVar (tcLocks ctx) (drop n ls)

-- | commitTxn flow (internal/04 §4.2): Committing; PCommit chained but
--   NOT undo-logged; flushWalUpTo = commit point (design/00 §0.7);
--   locks released only after the flush completes (strictness).
commitTxn :: TxnCtx -> IO ()
commitTxn ctx = do
  checkAbort ctx
  setStatusOf (tcTxnMgr ctx) (tcTxnId ctx) TxnCommitting
  st <- atomically (readTVar (tcState ctx))
  let rec = walRecord (tcTxnId ctx) (tlsLastLSN st) PCommit
  lsn <- appendRecord (tcWalMgr ctx) rec
  atomically $ writeTVar (tcState ctx) st { tlsLastLSN = lsn }
  flushWalUpTo (tcWalMgr ctx) lsn            -- <<< commit point
  unlockAll (tcLockMgr ctx) (tcTxnId ctx)
  removeActive ctx

-- | abortTxn flow (internal/04 §4.2 live rollback): undo newest-first
--   through the SAME applyUndo used by recovery, then PAbort (not in
--   undo), release locks, deregister.
abortTxn :: TxnCtx -> IO ()
abortTxn ctx = do
  setStatusOf (tcTxnMgr ctx) (tcTxnId ctx) TxnAborting
  st <- readTVarIO (tcState ctx)
  let wal = tcWalMgr ctx
  mapM_ (\lsn -> do
           rec <- readRecordAt wal lsn
           applyUndo (tcEnv ctx) rec lsn)
        (tlsUndo st)
  st' <- atomically (readTVar (tcState ctx))
  _ab <- appendRecord wal (walRecord (tcTxnId ctx) (tlsLastLSN st') PAbort)
  unlockAll (tcLockMgr ctx) (tcTxnId ctx)
  removeActive ctx

-- | Statement-level rollback (internal/04 §4.2 "same loop with a
--   statement mark"): undo entries pushed since the undo mark, locks
--   acquired since the lock mark; NO PAbort record, txn stays active.
abortStatement :: TxnCtx -> IO ()
abortStatement ctx = do
  st <- readTVarIO (tcState ctx)
  let wal = tcWalMgr ctx
      n = length (tlsUndo st) - tlsStmtMark st
      fresh = take n (tlsUndo st)
  mapM_ (\lsn -> do
           rec <- readRecordAt wal lsn
           applyUndo (tcEnv ctx) rec lsn)
        fresh
  atomically $ do
    stv <- readTVar (tcState ctx)
    writeTVar (tcState ctx) stv { tlsUndo = drop n (tlsUndo stv) }
  -- repair the checkpoint anchor: the manager's oldest-undo IORef must
  -- match the SURVIVING undo list (review nice-to-have #10)
  info <- findActive ctx
  case info of
    Just ai -> do
      stv' <- readTVarIO (tcState ctx)
      writeIORef (aiOldest ai) (case tlsUndo stv' of [] -> 0; xs -> last xs)
    Nothing -> pure ()
  releaseStmtLocks ctx

-- | Autocommit wrapper (design/03 §3.1): every statement outside an
--   explicit block is its own implicit transaction.  The action receives
--   its TxnCtx (internal/04 §4.1: every executing statement carries one).
withTxnAuto :: TxnManager -> LockManager -> Env -> (TxnCtx -> IO a) -> IO a
withTxnAuto tm lm env act = do
  ctx <- beginTxn tm lm env
  r <- trySome (act ctx)
  case r of
    Left e  -> do
      abortTxn ctx
      throwIO (toSqlError e)
    Right a -> commitTxn ctx >> pure a

trySome :: IO a -> IO (Either SomeException a)
trySome = try

toSqlError :: SomeException -> SqlError
toSqlError e = case fromException e of
  Just se  -> se
  Nothing  -> errInternal (pack ("statement failure (non-SqlError): " ++ show e))

-- | Checkpoint support (internal/04 §4.2): each active txn's oldest undo
--   LSN — head of the reversed undo list, via the IORef updated by txnAppend.
activeTxnsOldestLSN :: TxnManager -> IO [(TxnId, LSN)]
activeTxnsOldestLSN tm = do
  act <- readTVarIO (tmActive tm)
  mapM (\(tid, ai) -> (,) tid <$> readIORef (aiOldest ai)) (Map.toList act)

-- | Deliver an abort signal to a running txn (deadlock policy, §4.3):
--   set the ctx's abort channel AND mark Aborting in ONE atomically so
--   a second detector scan cannot double-signal (review #9).
signalAborted :: TxnManager -> TxnId -> SqlError -> IO ()
signalAborted tm tid err = do
  act <- readTVarIO (tmActive tm)
  case Map.lookup tid act of
    Nothing  -> pure ()
    Just ai  -> atomically $ do
      writeTVar (aiAbort ai) (Just err)
      act' <- readTVar (tmActive tm)
      case Map.lookup tid act' of
        Nothing   -> pure ()
        Just ai'  -> writeTVar (tmActive tm)
                       (Map.insert tid ai' { aiStatus = TxnAborting } act')
