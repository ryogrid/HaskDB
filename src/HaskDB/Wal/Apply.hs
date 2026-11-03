-- | Redo/undo of a single WAL record against the buffer pool
--   (design/02 §2.6 applyRedo/applyUndo; internal-design/03 §3.7 rules).
--   Shared by crash recovery (Wal.Recovery) AND live rollback
--   (Txn.Manager.abortTxn) — the "same code path" guarantee of design/02
--   §2.4.  Split out of Wal.Recovery so the transaction layer can reuse
--   it without a module cycle (structure refinement, TODO.md log).
module HaskDB.Wal.Apply where

import Control.Monad (when)
import HaskDB.Common.Types
import HaskDB.Common.Config (cfgPageSize)
import HaskDB.Server.Env (Env, envBufferPool, envFileMgr, envConfig)
import HaskDB.Storage.BufferPool (withPageDirty)
import HaskDB.Storage.FileManager (filePageCount, extendFile)
import HaskDB.Storage.Page
import HaskDB.Wal.Format

-- | Payloads whose redo/undo is page-level; index-logical and catalog
--   payloads map to "no page" (internal/03 §3.6 Phase A note).
touchesPage :: WalPayload -> Maybe PageId
touchesPage p = case p of
  PInsertTuple pg _ _   -> Just pg
  PDeleteTuple pg _ _   -> Just pg
  PUpdateTuple pg _ _ _ -> Just pg
  PPageImage pg _       -> Just pg
  PPageUndo pg _        -> Just pg
  PAllocPage pg _       -> Just pg
  PIndexInsert{}  -> Nothing
  PIndexDelete{}  -> Nothing
  PCreateTable{}  -> Nothing
  PCreateIndex{}  -> Nothing
  PCommit         -> Nothing
  PAbort          -> Nothing
  PCheckpoint{}   -> Nothing

-- | Redo a physiological change, guarded by the on-page phLsn and the
--   record's content (internal/03 §3.4 + §3.7 table: replay is
--   idempotent because guards check current state).
applyRedo :: Env -> WalRecord -> LSN -> IO ()
applyRedo env rec lsn = case wrPayload rec of
  PInsertTuple pg n tb -> withPageDirty bp pg $ \pr -> do
    hdr <- readHeader pr
    when (phLsn hdr < lsn) $ pageSetTuple pr lsn n tb
  PDeleteTuple pg n bf -> withPageDirty bp pg $ \pr -> do
    hdr <- readHeader pr
    when (phLsn hdr < lsn) $ do
      ms <- readSlot pr n
      case ms of
        Just (off, len) -> do
          cur <- pageSlice pr off len
          when (cur == bf) $ pageDeleteTuple pr lsn n
        Nothing -> pure ()
  PUpdateTuple pg n bf af -> withPageDirty bp pg $ \pr -> do
    hdr <- readHeader pr
    when (phLsn hdr < lsn) $ do
      ms <- readSlot pr n
      sz <- pageFrameLen pr
      case ms of
        Just (off, len) -> do
          cur <- pageSlice pr off len
          when (cur == bf) $ pageUpdateTuple pr lsn sz n af
        Nothing -> pure ()
  PPageImage pg img -> withPageDirty bp pg $ \pr -> do
    hdr <- readHeader pr
    when (phLsn hdr < lsn) $ installPageImage pr img lsn
  PAllocPage pg _ -> do
    pc <- filePageCount fm
    when (pc <= pg) (extendUntil fm pg)
    -- redo must MATERIALIZE the fresh-page image: after a crash with
    -- no checkpoint and no eviction, the pinNewPage init never reached
    -- the file (extendFile left zeros = undecodable header), and later
    -- replayed records on the page would readHeader-fail.  A replayed
    -- ALLOC_PAGE (LSN >= redoStart) implies the page had no content at
    -- redoStart, so (re)initialising is safe and idempotent.
    withPageDirty bp pg $ \pr -> do
      bs <- pageSlice pr 0 headerSize
      case decodeHeader bs of
        Left _  -> initPage pr PKHeap (cfgPageSize (envConfig env))
        Right _ -> pure ()
  PIndexInsert{} -> pure ()   -- logical index records are replayed
  PIndexDelete{} -> pure ()   -- PHYSIOLOGICALLY: every index page
                               -- mutation also logs PPageImage (after) +
                               -- PPageUndo (before), and redo/undo of the
                               -- images is the authoritative replay.  The
                               -- INDEX_* records stay in the WAL stream as
                               -- the semantic markers of design/04 §4.5.
                               -- (deviation: docs' logical redo/undo
                               -- re-descend; ours is image-based, TODO log)
  PPageUndo{}    -> pure ()   -- undo-only images: redo never applies
  PCreateTable{} -> pure ()   -- Phase 4: catalog rows (stub now)
  PCreateIndex{} -> pure ()
  PCommit        -> pure ()
  PAbort         -> pure ()
  PCheckpoint{}  -> pure ()
  where
    bp = envBufferPool env
    fm = envFileMgr env
    extendUntil fm' pg = do
      pc <- filePageCount fm'
      if pc > pg then pure ()
        else extendFile fm' >> extendUntil fm' pg

-- | Undo: inverse guarded against the current content (§3.7 table);
--   undo NEVER installs page images (internal/03 §3.7 rule — logical
--   redo/undo of index/catalog records is Phase 4/5 territory).
applyUndo :: Env -> WalRecord -> LSN -> IO ()
applyUndo env rec lsn = case wrPayload rec of
  PInsertTuple pg n tb -> withPageDirty bp pg $ \pr -> do
    ms <- readSlot pr n
    case ms of
      Just (off, len) -> do
        cur <- pageSlice pr off len
        when (cur == tb) $ pageDeleteTuple pr lsn n
      Nothing -> pure ()
  PDeleteTuple pg n bf -> withPageDirty bp pg $ \pr ->
    pageSetTuple pr lsn n bf
  PUpdateTuple pg n bf af -> withPageDirty bp pg $ \pr -> do
    ms <- readSlot pr n
    case ms of
      Just (off, len) -> do
        cur <- pageSlice pr off len
        when (cur == af) $ pageSetTuple pr lsn n bf
      Nothing -> pure ()
  PPageImage{}   -> pure ()   -- undo never installs after-images (§3.7)
  PPageUndo pg img -> withPageDirty bp pg $ \pr -> installPageImage pr img lsn
  PAllocPage{}   -> pure ()   -- allocated pages are never reclaimed
  PIndexInsert{} -> pure ()
  PIndexDelete{} -> pure ()   -- see applyRedo note: image-based replay
  PCreateTable{} -> pure ()
  PCreateIndex{} -> pure ()
  PCommit        -> pure ()
  PAbort         -> pure ()
  PCheckpoint{}  -> pure ()
  where
    bp = envBufferPool env
