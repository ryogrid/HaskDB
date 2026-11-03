-- | The 'Env' database environment record (internal-design/11 §11.2/11.3
--   use an Env but never name its module — implementation choice, recorded
--   in TODO.md).  Grown in place as phases land: catalog cache, FSM and
--   txn/lock managers are appended in Phases 3-6; Phase 2 carries the
--   raw managers plus the checkpoint serialiser and the tid counter
--   (until Txn.Manager exists, §3.5 reads nextTid from here).
module HaskDB.Server.Env where

import Control.Concurrent.MVar (MVar, newMVar)
import GHC.Internal.Conc.Sync (TVar, newTVarIO)
import HaskDB.Common.Types (TxnId, LSN)
import HaskDB.Common.Config (Config)
import HaskDB.Storage.FileManager (FileManager)
import HaskDB.Storage.BufferPool (BufferPool)
import HaskDB.Storage.FreeSpace (FreeSpaceMap, newFreeSpaceMap)
import HaskDB.Wal.Manager (WalManager)
import HaskDB.Server.Control (ControlFile(cfNextTid))

data Env = Env
  { envConfig      :: !Config
  , envFileMgr     :: FileManager
  , envWalMgr      :: WalManager
  , envBufferPool  :: BufferPool
  , envFreeSpace   :: FreeSpaceMap
  , envCtlPath     :: FilePath
  , envControl     :: TVar ControlFile  -- in-memory view; persisted at checkpoints
  , envNextTid     :: TVar TxnId        -- §3.5 checkpoint reads this
  , envCkptLock    :: MVar ()           -- checkpoints serialised (§3.5)
  }

newEnv :: Config -> FilePath -> ControlFile -> FileManager -> WalManager
       -> BufferPool -> IO Env
newEnv cfg ctlPath ctl fm wal bp = do
  fs <- newFreeSpaceMap
  ctv <- newTVarIO ctl
  tidv <- newTVarIO (cfNextTid ctl)
  ck <- newMVar ()
  pure Env { envConfig = cfg
           , envFileMgr = fm
           , envWalMgr = wal
           , envBufferPool = bp
           , envFreeSpace = fs
           , envCtlPath = ctlPath
           , envControl = ctv
           , envNextTid = tidv
           , envCkptLock = ck }
