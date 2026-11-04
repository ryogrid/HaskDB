-- | HaskDB.Server.Listener (internal-design/11 §11.2-§11.6; design/09 §9.7):
--   database opening, the socket listener, background threads, graceful
--   shutdown.  The socket implementation lives entirely below this module —
--   D-06 chose the @network@ package, amended to D-24 (see "HaskDB.Server.Socket":
--   the package cannot be built with this toolchain, so the socket layer is a
--   libc shim reached through GHC's FFI).  Sessions only ever see 'Connection'.
--
--   Deviations from the docs (recorded in TODO.md):
--   * 'Connection' is declared in "HaskDB.Server.Session" rather than here
--     (internal/11 §11.3 shows it in this module, which would make
--     Listener <-> Session a module cycle);
--   * @startDatabase@ lives in this module: internal/11 §11.2 names the flow
--     but never its module;
--   * §11.2's "control pageSize must equal page 0's pageSize" check is
--     delegated to 'HaskDB.Wal.Recovery.recoverDatabase', which validates the
--     control file when it opens the data file;
--   * the flock is NON-BLOCKING ('System.Posix.IO.setLock' with an exclusive
--     write lock): a second server on the same directory fails with §11.2's
--     message instead of blocking until the first one exits; the §11.4 lock
--     file is created with 'writeFile' first — no 'OpenMode' of unix-2.8.7.0
--     creates a file (verified: every mode fails "does not exist");
--   * SIGINT/SIGTERM close the listening socket; the accept loop unwinds and
--     §11.5's shutdown runs in a finally handler (internal/11 gives the
--     sequence, not the mechanism).
{-# LANGUAGE LambdaCase, ScopedTypeVariables, OverloadedStrings, BlockArguments #-}

module HaskDB.Server.Listener where

import System.Posix.Signals (installHandler, Handler(Catch), sigINT, sigTERM)
import System.Posix.IO (openFd, closeFd, setLock, FileLock,
                        OpenMode(ReadWrite), defaultFileFlags,
                        LockRequest(WriteLock))
import System.Posix.Types (Fd)
import GHC.Internal.IO.Device (SeekMode(AbsoluteSeek))
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, try, finally, onException)
import Control.Monad (when, void, forever, unless)
import Data.List (isPrefixOf)
import Data.IORef
import Data.Text (Text, pack)
import Data.Word (Word32)
import GHC.Internal.Conc.Sync (readTVarIO)

import HaskDB.Common.Config (Config, cfgDataDir, cfgPort,
                             cfgCheckpointSecs, cfgDeadlockMs)
import HaskDB.Common.Types (TxnId)
import HaskDB.Server.Control (ControlFile(cfNextTid), readControl)
import HaskDB.Server.Env (Env, envConfig, envFileMgr, envWalMgr, envControl)
import HaskDB.Storage.FileManager (closeDataFile)
import HaskDB.Wal.Manager (closeWalManager)
import HaskDB.Wal.Recovery (recoverDatabase, runCheckpointWith, dataFileName,
                            walFileName, controlFileName)
import HaskDB.Catalog.Bootstrap (createDatabase, checkPage0)
import HaskDB.Catalog.Cache (CatalogCache, newCatalogCache, loadCatalog)
import HaskDB.Txn.Manager (TxnManager, newTxnManager, activeSnapshot, nextTidOf)
import HaskDB.Txn.LockManager (LockManager, newLockManager)
import HaskDB.Txn.Deadlock (startDeadlockDetector)
import HaskDB.Server.Session (runSession, logServer, Connection, connClose)
import HaskDB.Server.Socket (Socket, listenOnPort, acceptPeer, closeSocket,
                             connPending, newConnection)

-- ---------------------------------------------------------------------------
-- §11.4's advisory lock file (never written to, only flock'd)
-- ---------------------------------------------------------------------------
lockFileName :: FilePath
lockFileName = "haskdb.lock"

-- | The lock range covering the whole advisory lock file (§11.2's flock).
wholeFile :: FileLock
wholeFile = (WriteLock, AbsoluteSeek, 0, fromIntegral (maxBound :: Int))

-- §11.5's "wait briefly (up to 5 s)": poll in 0.1 s ticks.
waitTicks :: Int
waitTicks = 50

tickMicro :: Int
tickMicro = 100000

-- ---------------------------------------------------------------------------
-- §11.2: the open database
-- ---------------------------------------------------------------------------
data Database = Database
  { dbEnv     :: Env
  , dbCatalog :: CatalogCache
  , dbTxnMgr  :: TxnManager
  , dbLockMgr :: LockManager
  , dbLockFd  :: Fd }

startDatabase :: Config -> IO Database
startDatabase cfg = do
  let dir = cfgDataDir cfg
  createDirectoryIfMissing True dir
  lock <- acquireLock dir
  -- §11.2 keeps the flock for the WHOLE process lifetime, but an open/create
  --   that FAILS (a corrupt control file, a pageSize disagreement, a replay
  --   error) must release it too: the fd only reaches Database on success, so
  --   every throwing path closes it here.  (The kernel also drops the lock when
  --   the process finally exits, but a stale fd keeps the failure confusing.)
  onException (openFlow cfg dir lock) (closeFd lock)

-- | §11.2's open-or-create decision, split out so the flock-release handler
--   above sees one action.
openFlow :: Config -> FilePath -> Fd -> IO Database
openFlow cfg dir lock = do
  hasCtl <- doesFileExist (dir </> controlFileName)
  cache <- newCatalogCache
  if hasCtl
    then do
      ctl <- readControl (dir </> controlFileName)   -- §11.4 parse errors die
      -- §11.2's order: the pageSize cross-check comes BEFORE replay, so a
      --   control file that disagrees with the data file's page-0 echo is
      --   rejected without first writing wrongly-aligned page images.
      checkPage0 cfg ctl
      logServer "open: guards passed, replaying the pending WAL (§3.6)"
      env <- recoverDatabase cfg                     -- §3.6 replay
      loadCatalog env cache                          -- §6.3 catalog rebuild
      assemble env cache (cfNextTid ctl) lock
    else do
      -- §11.2's create signal is "no control file AND the directory is
      --   otherwise empty"; it warns that pointing the server at the WRONG
      --   directory must not silently create a database over stray files.  So
      --   anything that is not one of OUR four files (§11.4's names, incl. a
      --   crashed checkpoint's haskdb.control.tmp.N) is a hard refusal, and a
      --   bare data/WAL without a control file is §11.2's "incomplete
      --   database directory" (never guessed).  Only the advisory lock file
      --   left by a dead process tolerates bootstrap: it is never written to
      --   and carries no database state.
      entries <- listDirectory dir
      let ours n = n `elem` [ dataFileName, walFileName, controlFileName
                            , lockFileName ]
                 || (controlFileName ++ ".tmp.") `isPrefixOf` n
          strays = [ n | n <- entries, not (ours n) ]
      unless (null strays) $
        die "refusing to create a database over foreign files in this directory"
      when (dataFileName `elem` entries || walFileName `elem` entries) $
        die "incomplete database directory (a data or WAL file exists, but no control file)"
      env <- createDatabase cfg cache                -- §6.2 bootstrap
      ctl0 <- readTVarIO (envControl env)

      assemble env cache (cfNextTid ctl0) lock

assemble :: Env -> CatalogCache -> TxnId -> Fd -> IO Database
assemble env cache tid lock = do
  tm <- newTxnManager tid
  lm <- newLockManager
  startCheckpointTimer env tm
  startDeadlockDetector tm lm (cfgDeadlockMs (envConfig env))   -- §4.3 (D-12)
  pure Database { dbEnv = env, dbCatalog = cache, dbTxnMgr = tm
                , dbLockMgr = lm, dbLockFd = lock }

-- | The exclusive advisory flock (§11.2).  Deliberately non-blocking so a
--   second server fails fast: 'setLock' throws when the lock cannot be taken.
--   The lock file is never written to, only created empty on first use
--   ('System.Posix.IO' has no create-if-missing 'OpenMode').
acquireLock :: FilePath -> IO Fd
acquireLock dir = do
  let path = dir </> lockFileName
  exists <- doesFileExist path
  -- unix's openFd never creates a file (every OpenMode maps to an fopen flag
  -- without O_CREAT), so the §11.4 lock file is touched here first.
  when (not exists) (writeFile path "")
  fd <- openFd path ReadWrite defaultFileFlags
  got <- try (setLock fd wholeFile) :: IO (Either SomeException ())
  case got of
    Left _ -> die "another HaskDB process is using this directory"
    Right _ -> pure fd

-- ---------------------------------------------------------------------------
-- §11.6: the checkpoint timer thread
-- ---------------------------------------------------------------------------
startCheckpointTimer :: Env -> TxnManager -> IO ()
startCheckpointTimer env tm = void (forkIO foreverCheckpoint)
  where
    foreverCheckpoint = forever (checkpointRound env tm)
    -- 'checkpointRound' is re-entered as a fresh call each round: a shared
    -- local thunk would be a black hole when the round re-forces itself
    checkpointRound sx tmx = do
      threadDelay (secsMicro (cfgCheckpointSecs (envConfig sx)))
      r <- try (runCheckpointWith sx
                  (do act <- activeSnapshot tmx      -- §3.5 step 1: live
                      tid <- nextTidOf tmx           -- §3.5 step 5: manager-owned
                      pure (act, tid))) :: IO (Either SomeException ())
      case r of
        Left e  -> logServer ("checkpoint failed (continuing): " <> showText e)
        Right _ -> logServer "checkpoint completed"

-- ---------------------------------------------------------------------------
-- §11.3: the listener
-- ---------------------------------------------------------------------------
data ListenerState = ListenerState
  { lsActive   :: IORef Int             -- live session threads
  , lsSessions :: IORef [(Word32, Connection)]  -- LIVE connections keyed by the
      --   session id, so a finished session drops its entry: the plain list
      --   grew once per connection ever accepted (§11.3's loop is unbounded)
  , lsPid      :: IORef Word32          -- §9.2's session counter
  , lsStopped  :: IORef Bool }

runListener :: Database -> IO ()
runListener db = do
  let env = dbEnv db
      cache = dbCatalog db
      tm = dbTxnMgr db
      lm = dbLockMgr db
      port = cfgPort (envConfig env)             -- §11.7 startup banner
  logServer ("listening on port " <> pack (show port)
             <> ", data directory " <> pack (cfgDataDir (envConfig env)))
  sock <- listenOnPort port                        -- §11.3: bind, all interfaces
  a <- newIORef (0 :: Int)
  ss <- newIORef []
  pc <- newIORef (0 :: Word32)
  fl <- newIORef False
  let st = ListenerState { lsActive = a, lsSessions = ss, lsPid = pc, lsStopped = fl }
  _ <- installHandler sigINT (Catch (stopAccept st sock)) Nothing    -- §11.5 step 1
  _ <- installHandler sigTERM (Catch (stopAccept st sock)) Nothing    -- §11.5 step 1
  acceptLoop env cache tm lm sock st
    `finally` gracefulShutdown db st sock

-- | The accept loop must never die from a per-connection exception (§11.3);
--   sessions are independent and their threads are not tracked.
--
--   It POLLS rather than parking in a blocking accept(): GHC masks SIGINT/
--   SIGTERM for the whole extent of a 'safe' foreign call, so a thread sitting
--   in accept() would never run §11.5's signal handler and the server could
--   not be shut down.  Between polls the thread is in 'threadDelay', an
--   interruptible point, so SIGTERM/SIGINT start the shutdown as designed.
acceptLoop :: Env -> CatalogCache -> TxnManager -> LockManager -> Socket
           -> ListenerState -> IO ()
acceptLoop env cache tm lm sock st = do
  stopped <- readIORef (lsStopped st)
  if stopped
    then pure ()
    else do
      ready <- try (connPending sock) :: IO (Either SomeException Bool)
      case ready of
        Left e -> logServer ("listening socket stopped: " <> showText e)
        Right False -> threadDelay acceptPollMicro >> acceptLoop env cache tm lm sock st
        Right True -> do
          r <- try (acceptPeer sock) :: IO (Either SomeException Socket)
          case r of
            Left e -> logServer ("accept failed, ending the loop: " <> showText e)
            Right peer -> do
              forkSession env cache tm lm peer st
              acceptLoop env cache tm lm sock st

-- | One session per connection (§11.3); §10.3's finally already rolled back
--   any in-flight transaction, and a thread's exception closes only its own
--   connection.
forkSession :: Env -> CatalogCache -> TxnManager -> LockManager
            -> Socket -> ListenerState -> IO ()
forkSession env cache tm lm peer st = do
  -- the pid is the session key that lsSessions later prunes by, so it must be
  --   handed out ATOMICALLY: a modify-then-read pair lets two concurrent accepts
  --   read the same n, and the removal filter would then drop the wrong entry
  --   (a closed Connection kept alive until the next shutdown).
  n <- atomicModifyIORef' (lsPid st) (\k -> let n = k + 1 in (n, n))
  let conn = newConnection peer
  modifyIORef' (lsActive st) (+ 1)
  modifyIORef' (lsSessions st) ((n, conn) :)
  void (forkIO do
    r <- try (runSession env cache tm lm conn (fromIntegral n))
           :: IO (Either SomeException ())
    case r of
      Left e -> logServer ("session thread died: " <> showText e)
      Right _ -> pure ()
    -- the session is over: drop its connection from the tracked set, so a
    --   long-running server does not keep every peer it ever accepted alive
    modifyIORef' (lsSessions st) (filter ((/= n) . fst))
    modifyIORef' (lsActive st) (subtract 1))

-- ---------------------------------------------------------------------------
-- §11.5: graceful shutdown
-- ---------------------------------------------------------------------------
gracefulShutdown :: Database -> ListenerState -> Socket -> IO ()
gracefulShutdown db st sock = do
  let env = dbEnv db
  logServer "shutdown: closing the listening socket"
  stopAccept st sock                                 -- step 1: stop accepting
  conns <- readIORef (lsSessions st)
  _ <- mapM (try_ . connClose . snd) conns           -- step 2a: force closes
  drained <- waitForSessions st (0 :: Int)           -- step 2b: wait for them
  unless drained $
    logServer "shutdown: sessions still running after the wait cap (their rollback is asynchronous; the checkpoint below records them as active, so recovery undoes them)"
  r <- try (runCheckpointWith env
              (do act <- activeSnapshot (dbTxnMgr db)   -- §3.5 step 1: live txns
                  tid <- nextTidOf (dbTxnMgr db)        -- §3.5 step 5
                  pure (act, tid))) :: IO (Either SomeException ())
  case r of
    Left e  -> logServer ("shutdown checkpoint failed: " <> showText e)
    Right _ -> logServer "shutdown checkpoint completed"
  closeDataFile (envFileMgr env)                     -- step 4
  closeWalManager (envWalMgr env)
  closeFd (dbLockFd db)                              -- release the flock
  logServer "shutdown complete"
  exitSuccess

-- | §11.5 step 2: let live sessions finish their current statement (their
--   cleanup rolls back whatever is in flight).  Returns False when the cap was
--   hit with sessions still running — the final checkpoint below reads the LIVE
--   active-txn snapshot, so an unfinished transaction is still recorded as
--   active and recovery undoes it (design/02 §2.6 keeps the invariant); only
--   the shutdown's own durability response can lag.
waitForSessions :: ListenerState -> Int -> IO Bool
waitForSessions st k
  | k >= waitTicks = pure False
  | otherwise = do
      n <- readIORef (lsActive st)
      if n == 0
        then pure True
        else threadDelay tickMicro >> waitForSessions st (k + 1)

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
-- | How long the accept loop waits between two polls of the listening socket
--   (§11.3's "bind, listen, accept repeatedly").  Small enough that a client's
--   round trip does not notice it, large enough not to spin the CPU.
acceptPollMicro :: Int
acceptPollMicro = 5000

stopAccept :: ListenerState -> Socket -> IO ()
stopAccept st sock = do
  writeIORef (lsStopped st) True
  try_ (closeSocket sock)

try_ :: IO a -> IO ()
try_ act = try act >>= \(_ :: Either SomeException a) -> pure ()

secsMicro :: Int -> Int
secsMicro s = s * 1000000

showText :: SomeException -> Text
showText e = pack (show e)

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("haskdb-server: " ++ msg)
  exitFailure
