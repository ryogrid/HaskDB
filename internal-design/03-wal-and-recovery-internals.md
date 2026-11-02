# 03. WAL and Recovery Internals

Refines `design/02-buffer-pool-wal-recovery.md` §2.3–§2.6.

## 3.1 Record representation (`Wal.Format`)

```haskell
data WalRecord = WalRecord
  { wrType     :: !WalRecType
  , wrTxn      :: !TxnId        -- 0 for records not owned by a txn
                                -- (CHECKPOINT)
  , wrPrevTxn  :: !LSN          -- previous record LSN of the same txn,
                                -- 0 = first record of the txn
  , wrPayload  :: !WalPayload
  } deriving (Show)

data WalPayload
  = PInsertTuple  { pPage :: PageId, pTuple :: ByteString }
  | PDeleteTuple  { pPage :: PageId, pSlot :: SlotNum, pBefore :: ByteString }
  | PUpdateTuple  { pPage :: PageId, pSlot :: SlotNum,
                    pBefore :: ByteString, pAfter :: ByteString }
  | PIndexInsert  { pIndex :: RelId, pKey :: Value, pRid :: RID }
  | PIndexDelete  { pIndex :: RelId, pKey :: Value, pRid :: RID }
  | PPageImage    { pPage :: PageId, pImage :: ByteString }
  | PAllocPage    { pPage :: PageId, pRel :: RelId }
  | PCreateTable  { pRel :: RelId, pName :: Text, pCols :: [ColumnDesc] }
  | PCreateIndex  { pRel :: RelId, pName :: Text,
                    pTable :: RelId, pCol :: Int, pRoot :: PageId }
  | PCommit
  | PAbort
  | PCheckpoint   { pActive :: [(TxnId, LSN)] }  -- txn -> its oldest LSN
```

Notes:

- `PInsertTuple` carries no slot (document 01 §1.8: placement is
  deterministic given the page image, so redo reproduces the slot).
- `PIndexInsert`/`PIndexDelete` carry the index's relid; redo/undo
  re-descend the tree from its current root (looked up in the catalog
  state being recovered — during recovery the catalog pages are
  recovered like all others, and index operations during redo use the
  root page recorded by the most recent `PCreateIndex`/`PPageImage`
  state; to keep this simple, recovery applies index records by
  descending from the root page id stored in a recovery-side map
  seeded from `PCreateIndex` records and updated whenever a
  `PPageImage` touches a page flagged as an index root. This is the
  one place recovery needs care; the fallback for any doubt is that
  splits are logged as page images, so tree *structure* never depends
  on logical index records — only entry presence does.)

## 3.2 On-disk framing and codec

```
record := u32le totalLen        -- length of everything after this field
          u8    typeTag
          u64le txnId
          u64le prevTxnLSN
          payload (per typeTag)
          u32le crc32           -- over all preceding bytes of this record
                                -- including totalLen
```

- `encodeRecord :: WalRecord -> ByteString`
- `decodeRecord :: ByteString -> Int -> Either Text (WalRecord, Int)`
  (bytes, offset) → (record, next offset). Returns `Left` on: short
  buffer, `totalLen` < minimum or > remaining, CRC mismatch, unknown
  tag, payload decode failure. Recovery treats any `Left` as
  end-of-valid-WAL (design/02 §2.6).
- Type tags are a `Word8` enum in `Wal.Format`; adding a record type
  later means appending a new tag — old tags never change meaning.

Payload encodings reuse `Common.Codec`; `Value` is encoded with the
same canonical encoding as `encodeValue` plus a 1-byte type tag so
index keys are self-describing in the WAL.

## 3.3 WAL manager (`Wal.Manager`)

```haskell
data WalManager = WalManager
  { wmHandle     :: Handle
  , wmState      :: MVar WalState
  , wmFileSize   :: TVar LSN        -- logical end of WAL = next LSN
  }

data WalState = WalState
  { wsBuffer     :: !ByteString     -- appended, not yet written out
  , wsWrittenLSN :: !LSN            -- written to the OS (not yet fsynced)
  , wsFlushedLSN :: !LSN            -- fsynced (durable)
  }

newWalManager  :: FilePath -> IO WalManager   -- opens/creates WAL file;
                       -- initial LSNs = existing file size (append mode)
appendRecord   :: WalManager -> WalRecord -> IO LSN
flushWalUpTo   :: WalManager -> LSN -> IO ()
flushedLSN     :: WalManager -> IO LSN
```

### appendRecord flow

```
1. bytes := encodeRecord rec
2. under wmState MVar:
     lsn := wsFlushedLSN-base offset = current logical end
            (tracked as wmFileSize TVar value)
     wsBuffer := wsBuffer <> bytes;  wmFileSize += length bytes
3. return lsn
```

Appends are serialised by the MVar, so LSN order = call order for
concurrent transactions. The record's own `wrPrevTxn` is filled in by
the *caller* (transaction manager, document 04) before appending.

### flushWalUpTo flow

```
flushWalUpTo wm target:
  if flushedLSN >= target: return
  under MVar:
    if wsBuffer non-empty: write it to wmHandle (hPut), wsWrittenLSN := end
    if wsWrittenLSN >= target: fdatasync wmHandle; wsFlushedLSN := wsWrittenLSN
  (Loop check in case another thread appended meanwhile — target is a
  fixed LSN, so at most one write+sync is needed; concurrent flushers
  serialise on the MVar and re-check the condition.)
```

`fdatasync` is via `System.Posix.IO` `fileSynchronizeDataOnly` on the
handle's fd (fallback: `fileSynchronize`). Group commit (D-15) would
be implemented inside this function only.

## 3.4 Ordering pattern for page mutations (used by Heap and BTree)

Every page mutation follows this exact shape (see also document 01
§1.4):

```
1. Compute the mutation as a pure function on the pinned page's bytes
   (or perform it under the page write lock — both are used; pure
   image computation for compaction/splits, in-place for simple ops).
2. Build the WalRecord with before/after images taken from the
   pre-mutation bytes.
3. lsn <- appendRecord wal rec
4. Apply the mutation to the page bytes; stamp phLsn := lsn.
5. Unpin dirty.
```

Undo (rollback/recovery) applies the inverse using the before-image
with the *same page operations* in reverse record order — there is a
single function per payload type:

```haskell
-- Wal.Recovery (also used by Txn.Manager for live rollback)
applyRedo :: Env -> WalRecord -> LSN -> IO ()
applyUndo :: Env -> WalRecord -> LSN -> IO ()
```

Both are no-ops when the page's current `phLsn` shows the change is
already present (redo) or already absent (undo), checked by comparing
`phLsn` and, for tuple records, the slot content against the expected
image (design/02 §2.6 safety net).

## 3.5 Checkpoint (`Wal.Manager` + `Server` timer)

```haskell
runCheckpoint :: Env -> IO ()
```

Flow (design/02 §2.5):

1. Snapshot active transactions from the transaction manager:
   `[(txnId, oldestLSN)]`.
2. `rec = CHECKPOINT` with that snapshot; `lsn <- appendRecord`;
   `flushWalUpTo lsn`.
3. `flushAll bufferPool` (each page flush re-checks the WAL rule).
4. `fsyncDataFile`.
5. Write control file (document 11 §11.2) with `checkpointLSN = lsn`,
   `nextTid` from the transaction manager, via write-temp + rename +
   directory fsync.

Checkpoint execution is serialised by an `MVar` in `Env` so the timer,
shutdown path, and any manual trigger cannot overlap.

## 3.6 Recovery (`Wal.Recovery`)

```haskell
recoverDatabase :: Config -> IO Env
  -- Called once at startup (document 11). Builds FileManager,
  -- WalManager, BufferPool in raw mode (no catalog yet), runs the
  -- three phases, then loads the catalog cache and FSM.
```

Internal state:

```haskell
data RecoveryState = RecoveryState
  { rsTxnTable  :: Map TxnId TxnRecoveryInfo
  , rsDirtyPages :: Map PageId LSN       -- page -> first LSN dirtying it
  , rsIndexRoots :: Map RelId PageId     -- seeded/updated per sect 3.1 note
  }

data TxnRecoveryInfo = TxnRecoveryInfo
  { triStatus  :: TxnRunning | TxnCommitted | TxnAborted
  , triLastLSN :: LSN
  , triFirstLSN :: LSN
  }
```

### Phase A — analysis

```
start := controlFile.checkpointLSN (0 if none)
offset := start
loop:
  decode record at offset; on Left -> stop (walEnd := offset)
  update rsTxnTable:
    - change records: insert txn if absent (Running, firstLSN=offset),
      lastLSN := offset; record page in rsDirtyPages if absent
      (for payload types that touch a page; index logical records map
      to "unknown page" and are excluded from rsDirtyPages — their
      redo is entry-level, sect 3.7)
    - COMMIT: status := Committed
    - ABORT:  status := Aborted
    - CHECKPOINT: merge its active list (txns not seen since get
      Running entries with the recorded oldest LSN)
  offset += record length
```

### Phase B — redo

```
start := minimum of rsDirtyPages values (or walEnd if empty)
scan records from start to walEnd:
  for each record with a page payload:
    if page on disk has phLsn < recordLSN: applyRedo
  for each index logical record: applyRedo unconditionally
    (idempotent: inserting an existing (key,RID) is a no-op; deleting
    an absent one likewise — the B-tree redo entry points are written
    to guarantee this, document 05 sect 5.6)
```

### Phase C — undo

```
losers := txns in rsTxnTable with status Running (never committed)
for each loser, walk from triLastLSN following wrPrevTxn:
  applyUndo record
  until wrPrevTxn = 0
```

Undo writes no WAL records (recovery is restartable: if the server
crashes during undo, the next recovery redoes to the same state and
re-undoes; `applyUndo`'s image checks make re-application safe).

### Phase D — finish

1. Rebuild per-relation page lists and the FSM by walking catalog +
   page chains (catalog pages are ordinary pages by now).
2. Load catalog cache (document 06).
3. `runCheckpoint` once to establish a fresh checkpoint LSN.
4. Return `Env`; server starts accepting connections.

## 3.7 Redo/undo per payload type (summary table)

| Payload | applyRedo | applyUndo |
|---------|-----------|-----------|
| InsertTuple | place tuple if slot/content absent | remove tuple if present |
| DeleteTuple | clear slot if tuple == before | restore before-image into slot |
| UpdateTuple | write after-image if current == before | write before-image if current == after |
| IndexInsert | `btreeInsertIdempotent` | `btreeDeleteIdempotent` |
| IndexDelete | `btreeDeleteIdempotent` | `btreeInsertIdempotent` |
| PageImage | install image if `phLsn < lsn` | install *previous* image — not available; undo of a PageImage is handled because compaction/split page images are always paired with the logical records of the same operation in the same transaction, and undo walks records in reverse: the logical undos run first, then the page image redo-guard (`phLsn`) prevents stale reinstall. See note below. |
| AllocPage | ensure page exists (extend file), chain link is via separate PageImage on the predecessor | no-op (an allocated-but-unused page is harmless) |
| CreateTable/Index | insert catalog rows if absent | remove catalog rows if present |
| Commit/Abort/Checkpoint | no-op in redo; skipped in undo walk | — |

**Note on PageImage undo**: compaction does not change logical
content, so undoing it is unnecessary; splits *do* move entries
between pages, but every split also emits the logical index/heap
records for the moved entries in the same transaction, so reverse
order undo restores logical content before any page image could be
re-examined. To keep this airtight, the implementation rule is:
**structural operations log page images for redo, and logical records
for undo; undo never installs page images.** This is a deliberate,
documented simplification of full ARIES. If a future change introduces
a structural operation with no logical-record counterpart, it must
also log a before-image `PPageImageUndo` record type — flagged here so
the gap is visible rather than silent.
