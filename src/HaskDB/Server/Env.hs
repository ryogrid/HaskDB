-- | The 'Env' database environment record (internal-design/11 §11.2/11.3
--   use an Env but never name its module — implementation choice, recorded
--   in TODO.md).  Grown in place as phases land: catalog cache is appended
--   in Phase 4/6; the txn/lock managers deliberately do NOT live in Env
--   (deviation from internal/11 §11.2: they travel inside TxnCtx so the
--   module graph stays acyclic — see HaskDB.Txn.Manager header).
--   Phase 3: the Phase-2 envNextTid TVar is removed — TxnManager.tmNextTid
--   owns the counter (§3.3 "persisted via the control file").
module HaskDB.Server.Env where

import Control.Concurrent.MVar (MVar, newMVar)
import GHC.Internal.Conc.Sync (TVar, newTVarIO)
import HaskDB.Common.Config (Config)
import HaskDB.Storage.FileManager (FileManager)
import HaskDB.Storage.BufferPool (BufferPool)
import HaskDB.Storage.FreeSpace (FreeSpaceMap, newFreeSpaceMap)
import HaskDB.Wal.Manager (WalManager)
import HaskDB.Server.Control (ControlFile)

data Env = Env
  { envConfig      :: !Config
  , envFileMgr     :: FileManager
  , envWalMgr      :: WalManager
  , envBufferPool  :: BufferPool
  , envFreeSpace   :: FreeSpaceMap
  , envCtlPath     :: FilePath
  , envControl     :: TVar ControlFile  -- in-memory view; persisted at checkpoints
  , envCkptLock    :: MVar ()           -- checkpoints serialised (§3.5)
  }

newEnv :: Config -> FilePath -> ControlFile -> FileManager -> WalManager
       -> BufferPool -> IO Env
newEnv cfg ctlPath ctl fm wal bp = do
  fs <- newFreeSpaceMap
  ctv <- newTVarIO ctl
  ck <- newMVar ()
  pure Env { envConfig = cfg
           , envFileMgr = fm
           , envWalMgr = wal
           , envBufferPool = bp
           , envFreeSpace = fs
           , envCtlPath = ctlPath
           , envControl = ctv
           , envCkptLock = ck }
