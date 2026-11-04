-- | Crash recovery: three-phase analysis/redo/undo + final checkpoint
--   (design/02 §2.6, internal-design/03 §3.6-3.7) and checkpointing
--   (§3.5).  Deviations recorded in TODO.md:
--   * losers for undo = Running AND Aborted (docs Phase C says Running
--     only; with steal/no-force, an aborted txn's stolen-and-flushed
--     pages must be undone too — redo re-establishes them first, so
--     undoing both is safe and idempotent).
--   * CHECKPOINT payload is the docs' (txnId, oldest LSN); recovery
--     finds a checkpoint-only txn's most-recent LSN by forward-scanning
--     from its oldest LSN (valid because the WAL file is never truncated
--     or reused — only garbage tails are cut).
--   * redo/undo of INDEX_*, CREATE_* payloads are no-op stubs until the
--     catalog (Phase 4) and B-tree (Phase 5) layers exist.
--   * Phase D catalog/FSM rebuild is deferred (no catalog yet); the
--     FreeSpaceMap is fresh for now.
module HaskDB.Wal.Recovery where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Control.Monad (when, unless, forM_)
import Control.Monad.STM (atomically)
import System.Directory (doesFileExist, createDirectoryIfMissing)
import System.FilePath ((</>))
import Control.Concurrent.MVar (withMVar)
import GHC.Internal.Conc.Sync (writeTVar)
import HaskDB.Common.Types
import HaskDB.Common.Config
import HaskDB.Common.Error (throwSql)
import HaskDB.Server.Env
import HaskDB.Server.Control
import HaskDB.Storage.FileManager
import HaskDB.Storage.BufferPool
import HaskDB.Wal.Manager
import HaskDB.Wal.Format
import HaskDB.Wal.Apply (applyRedo, applyUndo, touchesPage)

-- Database file names (impl choice: the docs never name them).
dataFileName, walFileName, controlFileName :: String
dataFileName = "haskdb.data"
walFileName = "haskdb.wal"
controlFileName = "haskdb.control"

data TriStatus = TxnRunning | TxnCommitted | TxnAborted
  deriving (Eq, Show)

data TxnRecoveryInfo = TxnRecoveryInfo
  { triStatus   :: !TriStatus
  , triFirstLSN :: !LSN
  , triLastLSN  :: !LSN }
  deriving (Show)

-- | Decode consecutively from an offset up to the first invalid record.
scanRecords :: BS.ByteString -> Int -> [(Int, WalRecord)]
scanRecords bs off = case decodeRecord bs off of
  Left _ -> []
  Right (rec, off') -> (off, rec) : scanRecords bs off'

scanEnd :: BS.ByteString -> Int -> Int
scanEnd bs off = case decodeRecord bs off of
  Left _ -> off
  Right (_, off') -> scanEnd bs off'

-- | Phase A: transaction table + first-dirty-page map from checkpoint.
analyze :: BS.ByteString -> LSN
        -> (Map.Map TxnId TxnRecoveryInfo, Map.Map PageId LSN)
analyze bs cp = foldl step (Map.empty, Map.empty) (scanRecords bs (fromIntegral cp))
  where
    step (tbl, dirty) (off, rec) =
      let lsn = fromIntegral off :: LSN
          t = wrTxn rec
          pl = wrPayload rec
      in  case pl of
        PCommit -> (setStatus TxnCommitted lsn t tbl, dirty)
        PAbort  -> (setStatus TxnAborted lsn t tbl, dirty)
        PCheckpoint act -> (foldl merge tbl act, dirty)
        _ -> case touchesPage pl of
          Just pg ->
            ( Map.insertWith touch t (TxnRecoveryInfo TxnRunning lsn lsn) tbl
            , Map.insertWith (\_newVal oldVal -> oldVal) pg lsn dirty )
          Nothing -> (tbl, dirty)
    touch new old = old { triLastLSN = triLastLSN new }
    merge tbl (t, oldest) =
      Map.insertWith (\_newVal oldVal -> oldVal) t (TxnRecoveryInfo TxnRunning oldest oldest) tbl
    setStatus st lsn t tbl = Map.alter ins t tbl
      where
        ins Nothing = Just (TxnRecoveryInfo st lsn lsn)
        ins (Just x) = Just x { triStatus = st }

-- | Undo of dirty pages needs the *last* record LSN per txn; for txns
--   known only from a CHECKPOINT entry (oldest LSN) forward-scan from
--   that LSN.  (docs deviation, see header.)
fixLast :: BS.ByteString -> LSN -> TxnId -> TxnRecoveryInfo -> TxnRecoveryInfo
fixLast wb _cp t info
  | triStatus info == TxnRunning =
      info { triLastLSN =
               maximum (triLastLSN info
                        : [ fromIntegral o
                          | (o, r) <- scanRecords wb (fromIntegral (triFirstLSN info))
                          , wrTxn r == t ]) }
  | otherwise = info

-- | §3.5 checkpoint core.  The ACTIVE-TXN SNAPSHOT and nextTid come from an
--   action that is RUN INSIDE the checkpoint's lock, not captured by the caller
--   before it: capturing early leaves a window where a transaction registers
--   and appends its first record BELOW the new redo boundary while absent from
--   the checkpoint table, and a later flushAll would then let an uncommitted
--   transaction's pages survive recovery (design/02 §2.6 + internal/03 §3.5's
--   crash-equivalence rule).  Paired with beginTxn, which takes the SAME lock
--   for its registration step, no transaction can slip into that window.
--   (deviation: §3.5's core takes only Env and reads the managers itself; the
--   layering rule internal/00 §0.6 puts Storage/Wal below Txn, so the caller
--   supplies the READER instead of the value.)
runCheckpointWith :: Env -> IO ([(TxnId, LSN)], TxnId) -> IO ()
runCheckpointWith env snap = withMVar (envCkptLock env) $ \_ -> do
  (act, tid) <- snap
  let wal = envWalMgr env
  lsn <- appendRecord wal WalRecord
    { wrType = WTCheckpoint, wrTxn = 0, wrPrevTxn = 0
    , wrPayload = PCheckpoint act }
  flushWalUpTo wal lsn
  flushAll (envBufferPool env)
  fsyncDataFile (envFileMgr env)
  let ctlNew = ControlFile
        { cfPageSize = cfgPageSize (envConfig env)
        , cfCheckpointLSN = lsn, cfNextTid = tid }
  writeControl (envCtlPath env) ctlNew
  atomically (writeTVar (envControl env) ctlNew)

-- | §3.6 recovery entry: build raw managers, run the three phases,
--   write a fresh checkpoint, return the assembled Env.  (Catalog cache
--   and FSM loading steps of Phase D are deferred — no catalog yet.)
recoverDatabase :: Config -> IO Env
recoverDatabase cfg = do
  let dir = cfgDataDir cfg
      ps = cfgPageSize cfg
  createDirectoryIfMissing True dir
  let dataPath = dir </> dataFileName
      walPath = dir </> walFileName
      ctlPath = dir </> controlFileName
  fm <- openDataFile dataPath ps
  wal <- newWalManager walPath
  ctlExists <- doesFileExist ctlPath
  ctl0 <- if ctlExists
    then do
      c <- readControl ctlPath
      when (cfPageSize c /= ps) $
        throwSql "XX000" "control page size differs from config"
      pure c
    else pure ControlFile { cfPageSize = ps, cfCheckpointLSN = 0, cfNextTid = 1 }
  unless ctlExists $ writeControl ctlPath ctl0
  bp <- newBufferPool ps (cfgBufferFrames cfg) fm (\l -> flushWalUpTo wal l)
  env <- newEnv cfg ctlPath ctl0 fm wal bp
  performRecovery env ctl0
  pure env

performRecovery :: Env -> ControlFile -> IO ()
performRecovery env ctl = do
  walBytes <- readWalAll (envWalMgr env)
  let sz = fromIntegral (BS.length walBytes) :: LSN
      cp = cfCheckpointLSN ctl
      walEnd = scanEnd walBytes (fromIntegral cp)
  let (tbl0, dirty) = analyze walBytes cp
      tbl = Map.mapWithKey (fixLast walBytes cp) tbl0
      redoStart = if Map.null dirty then walEnd
                    else fromIntegral (minimum (Map.elems dirty) :: LSN)
  when (walEnd < (fromIntegral sz :: Int)) $
    truncateWal (envWalMgr env) (fromIntegral walEnd)
  flushWalUpTo (envWalMgr env) (fromIntegral walEnd)
  forM_ (scanRecords walBytes (fromIntegral redoStart)) $ \(off, rec) ->
    applyRedo env rec (fromIntegral off)
  mapM_ (undoLoser env walBytes) (Map.toList tbl)
  -- nextTid must not reuse ids seen in the WAL (aborted txns consumed
  -- ids past the checkpoint): bump past the max txn id analyzed.
  let tidNew = max (cfNextTid ctl) (1 + maximum (0 : Map.keys tbl))
  runCheckpointWith env (pure ([], tidNew))

undoLoser :: Env -> BS.ByteString -> (TxnId, TxnRecoveryInfo) -> IO ()
undoLoser env wb (_, info)
  | triStatus info `notElem` [TxnRunning, TxnAborted] = pure ()
  | otherwise = walk (triLastLSN info)
  where
    walk l
      | l == 0 = pure ()
      | otherwise = case decodeRecord wb (fromIntegral l) of
          Left e -> throwSql "XX000" ("recovery: undo chain broken: " <> e)
          Right (rec, _) -> do
            applyUndo env rec l
            walk (wrPrevTxn rec)