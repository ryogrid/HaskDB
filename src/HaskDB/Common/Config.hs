-- | Deployment/configuration values, centralised here (internal-design/00
--   §0.3): the provisional decision values D-01/D-07/D-08/D-11 live only
--   in this record and the control file — never hard-coded in algorithms.
module HaskDB.Common.Config where

data Config = Config
  { cfgDataDir        :: FilePath
  , cfgPort           :: Int        -- default 54329 (avoid clashing with psql)
  , cfgPageSize       :: Int        -- PROVISIONAL (D-01): 8192; authoritative
                                     -- value afterwards is the control file
  , cfgBufferFrames   :: Int        -- PROVISIONAL (D-07): 1024
  , cfgStmtMemBudget  :: Int        -- PROVISIONAL (D-08): 256 MiB per statement
  , cfgCheckpointSecs :: Int        -- PROVISIONAL (D-11): 300 (time-based)
  , cfgLockWaitSecs   :: Int        -- only if D-12 chose timeouts: 10
  } deriving (Show)

defaultConfig :: FilePath -> Config
defaultConfig dir = Config
  { cfgDataDir        = dir
  , cfgPort           = 54329
  , cfgPageSize       = 8192
  , cfgBufferFrames   = 1024
  , cfgStmtMemBudget  = 256 * 1024 * 1024
  , cfgCheckpointSecs = 300
  , cfgLockWaitSecs   = 10
  }
