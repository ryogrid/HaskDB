# 02. Buffer Pool, WAL, and Recovery

## 2.1 Buffer pool

The buffer pool caches data-file pages in memory.

### Structures

```haskell
data BufferPool = BufferPool
  { bpFrames     :: TVar (Vector Frame)      -- fixed-size array of frames
  , bpPageTable  :: TVar (Map PageId FrameId)
  , bpClockHand  :: TVar Int                 -- CLOCK sweep hand
  }

data Frame = Frame
  { frPageId  :: Maybe PageId
  , frData    :: IORef ByteString            -- exactly PAGE_SIZE bytes
  , frPin     :: TVar Int                    -- pin count
  , frDirty   :: TVar Bool
  , frRefBit  :: TVar Bool                   -- CLOCK reference bit
  }
```

- Pool size (number of frames) is a startup parameter; the default value
  is decision item **D-07**.
- Replacement policy: **CLOCK** (second-chance). It is the classical
  teaching policy, O(1) amortised, and avoids LRU list maintenance.
  *(This is an internal implementation choice; it has no user-visible
  semantics.)*

### Operations

- `pinPage pageId :: IO Frame` — if resident, increment pin count and
  set the reference bit; otherwise choose a victim frame (CLOCK sweep
  over unpinned frames), flush it first if dirty (§2.4), read the page
  from disk, install it.
- `unpinPage frame dirty` — decrement pin count; if `dirty`, mark the
  frame dirty.
- All executor/storage code must access page bytes only while holding a
  pin. A page may be modified only while pinned *and* while the caller
  holds the page content lock (§2.2).

### Page content locks *(supplementary specification)*

Each frame has an associated `MVar ()`-style content lock. Readers may
share it; writers take it exclusively. In practice the design uses one
`TMVar`-based read/write lock per frame, taken for the duration of a
single page operation (not for a whole transaction). Transaction-length
data locking lives in the lock manager (03); page content locks only
protect the physical page structure against concurrent threads.

## 2.2 Flush rules and the WAL rule

A dirty frame may be written to the data file only when

```
walFlushedLSN >= frame.pageLSN
```

(the WAL rule). The buffer pool asks the WAL manager to flush up to the
page's LSN before writing the page. The same rule applies to victim
eviction and to checkpoint flushes. There is no code path that writes a
data page without this check; this invariant is what makes the
durability definition in 00-overview §0.7 hold.

Policy: **steal / no-force**.

- *Steal*: uncommitted changes may reach disk (eviction can flush dirty
  pages of active transactions) → recovery must be able to **undo**.
- *No-force*: commit does not force data pages to disk → recovery must
  be able to **redo**; commit only forces the WAL (§2.5).

## 2.3 WAL format

The WAL file is an append-only sequence of records. LSNs are byte
offsets into the WAL file (`Word64`), so an LSN directly addresses a
record.

### Record framing

```
 +----------------+--------------------+------------------+--------+
 | total length   | record type +      | payload          | CRC32  |
 | Word32 LE      | transaction id     | (type-specific)  | Word32 |
 |                | Word8 + Word64     |                  |        |
 +----------------+--------------------+------------------+--------+
```

- The CRC covers everything before it. A torn/invalid tail record
  (short read, bad CRC, implausible length) marks the end of valid WAL
  during recovery.
- Records are **physiological**: they name a concrete page and describe
  a physical change within it, expressed logically enough to redo and
  undo deterministically.

### Record types

| Type | Payload | Purpose |
|------|---------|---------|
| `INSERT_TUPLE` | pageId, slot, tuple bytes | redo: place tuple; undo: remove it |
| `DELETE_TUPLE` | pageId, slot, full before-image | redo: remove; undo: restore image |
| `UPDATE_TUPLE` | pageId, slot, before-image, after-image | redo: write after; undo: write before |
| `INDEX_INSERT` | index root pageId, key, RID | redo/undo of index entry creation |
| `INDEX_DELETE` | index root pageId, key, RID, (leaf page hint) | redo/undo of index entry removal |
| `BTREE_SPLIT` | affected pages' full after-images + parent update info | page splits are logged as page images to keep recovery simple |
| `PAGE_IMAGE` | pageId, full page after-image | in-page compaction, page initialisation, other structural changes |
| `ALLOC_PAGE` | pageId, owning relation id | new page appended to a relation |
| `CREATE_TABLE` / `CREATE_INDEX` | catalog change description | DDL is transactional like DML |
| `COMMIT` | transaction id | commit marker; fsync of WAL up to this record defines commit completion |
| `ABORT` | transaction id | written after in-memory rollback finishes (informational for recovery) |
| `CHECKPOINT` | list of active transaction ids, oldest LSN per transaction | recovery starting point |
| `TXN_BEGIN` | — | *(not written; transaction begin is memory-only — recovery learns about transactions from their first change record)* |

Index structural changes other than splits (e.g. root change) are also
logged via `PAGE_IMAGE` records for every touched page plus the catalog
update record. The rule of thumb: **when in doubt, log a page image** —
volume is a non-goal, correctness and simplicity are goals.

### WAL manager

```haskell
data WalManager = WalManager
  { wmBuffer     :: TVar ByteString   -- not-yet-flushed WAL bytes
  , wmFlushedLSN :: TVar LSN          -- durable up to this LSN
  , wmHandle     :: Handle
  }
```

- `appendWal record :: IO LSN` — serialise the record, append to the
  in-memory buffer, return its LSN. Appending is serialised by an
  `MVar` so LSN order equals buffer order.
- `flushWal uptoLSN :: IO ()` — write buffered bytes and `fdatasync`
  until `wmFlushedLSN >= uptoLSN`. Callers: commit (§2.5), the buffer
  pool before page writes (§2.2), checkpoint.
- Group commit (batching concurrent committers into one fsync) is
  decision item **D-15**; the flush interface above supports it without
  changes.

## 2.4 Commit protocol

1. The transaction finishes its work; all its changes are WAL-logged.
2. Append a `COMMIT` record → LSN `c`.
3. `flushWal c` (fsync). **After this call returns, the transaction is
   committed** and the client may be told so.
4. Release locks, remove the transaction from the active set
   (03-transactions-concurrency.md).

Rollback (explicit or on error): undo the transaction's changes in
memory (reverse order, using before-images), append `ABORT`, release
locks. Statement-level errors roll back to the start of the statement;
if the session is inside an explicit transaction block, the block enters
the failed state (see 09-wire-protocol.md §9.5).

## 2.5 Checkpointing

A checkpoint:

1. Appends a `CHECKPOINT` record listing active transactions and their
   oldest unflushed-relevant LSN, then flushes the WAL.
2. Flushes all currently dirty buffer-pool frames (respecting §2.2).
3. Updates the control file: `checkpointLSN`, `nextTid`.

Checkpoint triggers (periodic timer / WAL size threshold / shutdown)
and their defaults are decision item **D-11**. A checkpoint on clean
shutdown is always performed.

## 2.6 Crash recovery

Recovery follows the classical three-phase pattern (ARIES-lite:
page images and before/after-images make redo/undo idempotent, so no
compensation log records are needed beyond re-logging nothing —
recovery itself writes no WAL except a final `CHECKPOINT`).

1. **Load control file.** Take `checkpointLSN` as the starting point
   (or the beginning of the WAL if none).
2. **Analysis.** Scan forward from `checkpointLSN`. Rebuild:
   - the set of transactions that were active at the crash and whether
     each has a `COMMIT` record ("winners" vs "losers"),
   - the dirty-page table: first LSN that dirtied each page since the
     checkpoint.
   Stop at the first invalid/torn record; that is the WAL end.
3. **Redo.** Scan from the minimum "first dirty LSN" over all pages.
   For each change record, if the page's on-disk `pd_lsn` is smaller
   than the record's LSN, re-apply the change and set `pd_lsn` to the
   record LSN. Redo is applied for *all* transactions (winners and
   losers), restoring the exact pre-crash physical state.
4. **Undo.** For each loser transaction, walk its records backwards
   (via LSN chaining: each change record of a transaction stores the
   previous LSN of the same transaction — `prevTxnLSN` field in the
   record header payload) and apply the inverse operation. Undo stops
   at the transaction's first record.
5. **Finish.** Rebuild the free-space map from page headers, reload
   catalog caches, write a `CHECKPOINT` record, reopen for clients.

Idempotence: because every change record carries full before/after
images (or a full page image) and redo is guarded by `pd_lsn`, running
recovery twice, or crashing during recovery and restarting it, yields
the same result. Undo operations are physical inverses guarded by
checking the current page content matches the expected after-image
before overwriting *(supplementary specification — cheap safety net)*.

This satisfies the non-functional requirements:

- committed transactions survive (their changes are either on disk or
  redoable from fsynced WAL),
- uncommitted changes never survive recovery (undo phase),
- heap and index stay consistent (index changes are logged in the same
  WAL, in the same transaction, as heap changes),
- the WAL rule is never violated (§2.2).

## 2.7 Haskell implementation notes

- File I/O uses `System.IO` with explicit `hSeek`/binary handles, or
  `unix` package `fdPread`/`fdPwrite` style calls via `System.Posix.IO`.
  All multi-byte integers go through `Data.Binary` / hand-rolled
  little-endian codecs from boot libraries (`bytestring`, `binary` is a
  boot library).
- The WAL append path must not use lazy I/O. Buffers are strict
  `ByteString`s.
