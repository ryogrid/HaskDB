# 02. Buffer Pool Internals

Refines `design/02-buffer-pool-wal-recovery.md` §2.1–§2.2.

## 2.1 Data structures

```haskell
-- Storage.BufferPool
data BufferPool = BufferPool
  { bpConfig  :: !Config
  , bpFiles   :: FileManager
  , bpWal     :: WalManager            -- for the WAL rule (sect 2.4)
  , bpState   :: MVar PoolState        -- one lock for table+hand updates;
                                       -- frame contents have their own locks
  }

data PoolState = PoolState
  { psFrames :: !(Vector Frame)
  , psTable  :: !(Map PageId FrameId)
  , psHand   :: !Int                   -- CLOCK hand position
  }

type FrameId = Int

data Frame = Frame
  { frPageId   :: TVar (Maybe PageId)
  , frBytes    :: IORef ByteString     -- accessed only under frContentLock
                                       -- or while pin count is held by caller
  , frPinCount :: TVar Int
  , frDirty    :: TVar Bool
  , frRefBit   :: TVar Bool
  , frLock     :: RwLock               -- page content lock (sect 2.5)
  }
```

`RwLock` is a small STM-based read/write lock implemented in this
module (about 40 lines: a `TVar (Int, Bool)` counting readers and a
writer flag, with `retry`-based acquisition). It is per frame, follows
the frame when the frame is reused for another page, and is only ever
held for the duration of one page operation.

Frame byte access discipline:

- The thread that pins a page for modification holds `frLock`
  exclusively for the whole read-modify-write of that page.
- `frBytes` is replaced wholesale (`writeIORef`) or mutated through a
  `PageRef` wrapping the same `IORef` (document 01). Because every
  access happens under `frLock` or under a pin held by a thread that
  previously validated the page identity, no additional synchronisation
  is needed. (Haskell `IORef` accesses are not atomic across threads in
  general; the lock/pin discipline is what makes this sound, and it is
  stated here so future maintainers do not "optimise" it away.)

## 2.2 Public API

```haskell
newBufferPool   :: Config -> FileManager -> WalManager -> IO BufferPool

-- Pin a page, loading it if needed. Returns a handle pairing the frame
-- with its PageRef view.
data PinnedPage = PinnedPage { ppFrameId :: FrameId, ppPage :: PageRef,
                               ppId :: PageId }

pinPage    :: BufferPool -> PageId -> IO PinnedPage
unpinPage  :: BufferPool -> PinnedPage -> Bool {- dirty -} -> IO ()

-- Bracket form (preferred):
withPage      :: BufferPool -> PageId -> (PageRef -> IO a) -> IO a
                  -- read use; unpins clean
withPageDirty :: BufferPool -> PageId -> (PageRef -> IO a) -> IO a
                  -- write use; unpins dirty

-- Force-write one page (checkpoint) and all pages:
flushPage  :: BufferPool -> PageId -> IO ()
flushAll   :: BufferPool -> IO ()

-- Allocate-and-pin a brand-new page (file already extended by caller):
pinNewPage :: BufferPool -> PageId -> PageKind -> IO PinnedPage
  -- installs a zeroed page image without reading from disk
```

## 2.3 pinPage flow

```
pinPage bp pid:
  1. atomically (MVar PoolState):
       if pid in psTable -> frame := frames[table[pid]]
                             increment frPinCount; set frRefBit
                             return frame
       else -> victim := clockSweep(ps)   -- may update psHand
               mark victim "loading" by setting frPageId = Just pid
               and frPinCount = 1 *before* releasing the MVar,
               so no other thread can pick the same victim
  2. If the page was resident: return PinnedPage.
  3. If a victim was chosen:
       a. if victim had a page and frDirty: flushFrame victim (sect 2.4)
       b. bytes <- readPageBytes fm pid   (outside the MVar)
       c. writeIORef frBytes bytes; frDirty := False; frRefBit := True
       d. atomically: psTable := insert pid victimId (delete old mapping)
  4. Return PinnedPage.
```

Failure handling: if step 3b throws (I/O error), the frame is returned
to the free pool (frPageId := Nothing, pin count 0) and the exception
propagates. No other thread can have observed the half-loaded frame
because its page-table entry is only installed in step 3d.

## 2.4 clockSweep and flushing (the WAL rule)

```
clockSweep: starting at psHand, loop over frames:
  - skip frames with pinCount > 0
  - if frRefBit set: clear it, advance
  - else: choose this frame as victim, advance hand past it, stop
  (Frames with frPageId = Nothing are chosen immediately.)
  Termination: at most 2 full revolutions; if every frame is pinned,
  throw errInternal "buffer pool exhausted: all frames pinned".
  (Callers pin at most a bounded number of pages at once — joins and
  B-tree operations are written to respect a small constant; see the
  per-operator pin budgets in documents 05 and 09.)

flushFrame f:
  1. bytes <- readIORef frBytes; lsn <- page LSN from bytes' header
  2. flushWalUpTo bpWal lsn        -- THE WAL RULE: no page write before
                                   -- its WAL is durable (design/02 2.2)
  3. writePageBytes fm (frPageId f) bytes
  4. frDirty := False
```

`flushAll` (checkpoint): snapshot the list of dirty frames under the
MVar, then `flushFrame` each (frames pinned by active transactions are
flushed too — flushing does not require a pin by the flusher, but it
does require the frame's content lock in write mode briefly, to copy a
consistent byte image; if the lock is contended, copy under the lock,
release, then do steps 2–3 with the copy).

## 2.5 Content-lock helpers

```haskell
withPageReadLock  :: PinnedPage -> IO a -> IO a
withPageWriteLock :: PinnedPage -> IO a -> IO a
```

Implemented over the frame's `RwLock`. Lock ordering rule (global, to
prevent lock-ordering deadlocks at the page level): **page content
locks are acquired in ascending PageId order whenever more than one is
held at once**, and B-tree crabbing acquires parent-then-child (also
ascending in practice, not guaranteed — the B-tree's per-index latch
in document 05 covers the exception). Transaction (row) locks are a
separate domain (document 04); the global order is: row locks first
(logical), page content locks inside individual page operations only.

## 2.6 Invariants

- A `PageId` is in `psTable` iff exactly one frame has
  `frPageId = Just pid`.
- `frPinCount >= 0`; a frame with pinCount > 0 is never a victim.
- A frame is written to disk only via `flushFrame` (single choke
  point for the WAL rule).
- After `pinNewPage`, the frame's bytes are a valid initialised page
  (header written by `initPage`) before the pin is released to any
  other thread.
