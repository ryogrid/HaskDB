# 01. Page, Tuple, File Manager, and Free-Space Internals

Refines `design/01-storage-engine.md`.

## 1.1 In-memory page representation

Pages are manipulated as a mutable byte buffer inside the buffer
pool's frame (document 02). The `Page` module provides a *view* API:
all offsets are computed from the header fields on every call (no
cached copies that could desync).

```haskell
-- Storage.Page
newtype PageRef = PageRef (IORef ByteString)  -- owned by a buffer frame;
                                              -- exactly cfgPageSize bytes

data PageKind = PKHeap | PKIndexLeaf | PKIndexInternal | PKCatalog | PKFree
  deriving (Eq, Show)

data PageHeader = PageHeader
  { phLsn     :: !LSN
  , phKind    :: !PageKind
  , phLower   :: !Int    -- end of slot array
  , phUpper   :: !Int    -- start of tuple area
  , phSpecial :: !Int    -- special area offset (0 = none / PAGE_SIZE)
  , phNext    :: !PageId -- heap chain next; leaf chain next; else 0
  } deriving (Show)

headerSize :: Int
headerSize = 20          -- per design/01: 8+2+2+2+2+4

readHeader  :: PageRef -> IO PageHeader
writeHeader :: PageRef -> PageHeader -> IO ()
initPage    :: PageRef -> PageKind -> IO ()   -- zero page, empty header,
                                              -- phLower = headerSize,
                                              -- phUpper = phSpecial = PAGE_SIZE
pageFreeContiguous :: PageHeader -> Int       -- phUpper - phLower
```

On-disk header encoding (offsets in bytes, all little-endian):

```
0  u64  pd_lsn
8  u16  pd_flags   (bits 0-2: kind; bit 3: hasSpecial; rest 0)
10 u16  pd_lower
12 u16  pd_upper
14 u16  pd_special
16 u32  pd_next
```

Invariants checked by `checkPage :: PageRef -> IO ()` (called in debug
builds and by recovery before first use of a page):

```
headerSize <= phLower <= phUpper <= (phSpecial or PAGE_SIZE) <= PAGE_SIZE
for every live slot: phUpper <= lp_off and lp_off + lp_len <= specialStart
sum of live slot lengths <= phSpecialStart - phUpper + (fragment accounting)
```

## 1.2 Slot directory primitives

```haskell
itemSize :: Int
itemSize = 4             -- u16 off, u16 len (len 0 = unused slot)

slotCount   :: PageHeader -> Int            -- (phLower - headerSize) `div` itemSize
readSlot    :: PageRef -> SlotNum -> IO (Maybe (Int, Int))
              -- Nothing = unused slot; Just (off, len) = live
writeSlot   :: PageRef -> SlotNum -> Int -> Int -> IO ()
clearSlot   :: PageRef -> SlotNum -> IO ()  -- len := 0

-- Find an unused slot, or Nothing (caller must grow the array).
findUnusedSlot :: PageRef -> IO (Maybe SlotNum)
```

Slot array growth: appending a slot decreases free space by `itemSize`
and increases `phLower` by `itemSize`; only allowed when
`pageFreeContiguous >= itemSize + neededTupleBytes` for the pending
insert.

## 1.3 Slotted-page tuple operations

These are the only functions that move tuple bytes. Callers
(buffer-pool users) must hold the pin and the page content lock, and
must have appended the WAL record **before** calling the mutating
operations (the functions take the record's LSN as an argument and
stamp it into the header — making the correct order the only
expressible order).

```haskell
-- Insert bytes as a new tuple. Precondition: fits (checked by caller via
-- pageInsertFits). Returns the slot used.
pageInsertTuple :: PageRef -> LSN -> ByteString -> IO SlotNum
  -- 1. slot <- findUnusedSlot, else append slot at phLower
  -- 2. off  <- ph.phUpper - len(bytes); copy bytes to off
  -- 3. writeSlot slot off len; phUpper := off; phLsn := lsn

pageInsertFits :: PageHeader -> Int {- tuple bytes -} -> Bool
  -- free contiguous >= bytes + (itemSize if no unused slot exists)
  -- (slot existence is in the header-derived data: pass slotCount and
  --  unusedSlotKnown as computed by caller; see Heap flow doc 01 sect 1.5)

-- Read tuple bytes for a live slot.
pageReadTuple :: PageRef -> SlotNum -> IO ByteString

-- Replace tuple bytes in place. newLen <= oldLen + pageFreeContiguous.
-- If newLen < oldLen, bytes are rewritten at the same offset and the
-- tail becomes a fragment (accounted by compaction, sect 1.4).
-- Slot offset may move only if the caller first compacts; this function
-- never moves other tuples.
pageUpdateTuple :: PageRef -> LSN -> SlotNum -> ByteString -> IO ()

-- Delete: clear the slot; tuple bytes become a fragment.
pageDeleteTuple :: PageRef -> LSN -> SlotNum -> IO ()

-- Total bytes recoverable by compaction:
pageFragmentedFree :: PageRef -> IO Int
  -- (specialStart - phUpper) - sum(live slot lengths) + pageFreeContiguous
```

## 1.4 In-page compaction

```haskell
pageCompact :: PageRef -> LSN -> IO ()
```

Flow:

1. Collect `(slot, bytes)` for all live slots, ordered by slot number.
2. Rewrite them contiguously from the end of the usable area
   (`specialStart`) backwards, updating each slot's offset.
3. Set `phUpper` to the start of the rewritten block, `phLsn := lsn`.
4. Slot numbers do not change → RIDs are stable.

The caller (Heap) logs a `PAGE_IMAGE` WAL record with the
post-compaction page image *before* running compaction in memory — see
the ordering note in document 03 §3.4 for why the image is captured
from a scratch copy: compaction is first applied to a copied buffer,
the copy's bytes are logged, then the copy replaces the frame content.
This "compute new image → log → install" pattern is used for all
multi-step page mutations:

```haskell
-- Storage.Page helper used by Heap and BTree:
withPageImage :: PageRef -> (ByteString -> ByteString) -> ByteString
-- pure transform of the page bytes; caller logs result, then installs
-- via installPageImage :: PageRef -> ByteString -> LSN -> IO ()
```

## 1.5 Tuple codec (`Heap.TupleCodec`)

```haskell
data ColumnDesc = ColumnDesc
  { colName :: !Text
  , colType :: !SqlType
  } deriving (Show)   -- full RelationDesc lives in Catalog.Types (doc 06)

encodeTuple :: [ColumnDesc] -> Tuple -> ByteString
decodeTuple :: [ColumnDesc] -> ByteString -> Either Text Tuple
tupleSize   :: [ColumnDesc] -> Tuple -> Int   -- = BS.length . encodeTuple,
                                              -- but computed without building
                                              -- the ByteString (sum of field sizes)
```

Encoding (design/01 §1.3), implemented with `Builder`:

```
header: u8 flags (bit 0 = DELETED-pending; others 0), u8 natts, u16 reserved=0
then per column, in order:
  TyInt64   -> i64le
  TyFloat64 -> u64le of IEEE bit pattern (doubleToWord64)
  TyBool    -> u8 (0|1)
  TyVarchar -> u16le byteLength, then raw UTF-8 bytes
```

`decodeTuple` must consume exactly the input length; leftover or
truncated input is `Left`. The DELETED flag in the header is set by
the two-phase delete path only during the window described in
`design/01` §1.5; normal reads treat flagged tuples as deleted
(defensive; the window is inside one page-lock hold, so concurrent
readers should never observe it).

Size limits enforced here:

```haskell
maxTupleBytes :: Int -> Int   -- pageSize - headerSize - itemSize - 4
checkInsertable :: Int -> [ColumnDesc] -> Tuple -> Either SqlError ()
  -- Left errTupleTooLarge if tupleSize > maxTupleBytes pageSize
  -- Left errStringTooLong if any VText longer than 1024 bytes
```

## 1.6 File manager (`Storage.FileManager`)

```haskell
data FileManager = FileManager
  { fmHandle   :: Handle
  , fmPageSize :: !Int
  , fmLock     :: MVar ()        -- serialises extend operations only
  }

openDataFile   :: FilePath -> Int -> IO FileManager  -- creates if absent
readPageBytes  :: FileManager -> PageId -> IO ByteString  -- positional read,
                       -- exactly pageSize bytes; short file = errInternal
writePageBytes :: FileManager -> PageId -> ByteString -> IO ()
                       -- positional write; caller must have satisfied the
                       -- WAL rule (enforced by BufferPool, doc 02)
filePageCount  :: FileManager -> IO PageId  -- file size / pageSize
extendFile     :: FileManager -> IO PageId  -- append one zero page, return
                                            -- its id; fsync file after extend
fsyncDataFile  :: FileManager -> IO ()
```

Positional I/O uses `System.Posix.IO` (`fdReadBuf`/`fdWriteBuf` via
the handle's fd) or `hSeek`+read/write under a per-call pattern; the
buffer pool serialises reads/writes per frame anyway, so a simple
seek-based implementation is acceptable and more readable. The file
manager itself performs **no caching**.

The control file is *not* managed here; see document 11 §11.2.

## 1.7 Free-space map (`Storage.FreeSpace`)

```haskell
data FreeSpaceMap = FreeSpaceMap
  { fsmMap :: TVar (Map RelId (Map PageId Int))  -- rel -> page -> free bytes
  }

fsmRebuild     :: Env -> RelId -> [PageId] -> IO ()
  -- walk pages (via buffer pool), read headers, record
  -- pageFreeContiguous + fragmented free (post-compaction estimate =
  -- contiguous only; fragmented space is discovered on demand, sect 1.8)
fsmNoteFree    :: FreeSpaceMap -> RelId -> PageId -> Int -> IO ()
fsmFindPage    :: FreeSpaceMap -> RelId -> Int -> IO (Maybe PageId)
  -- first page (lowest PageId) whose recorded free bytes >= needed
fsmForget      :: FreeSpaceMap -> RelId -> IO ()  -- not used in baseline
                                                    -- (no DROP TABLE)
```

The FSM is advisory: Heap always rechecks the real header after
pinning the candidate page. A stale FSM entry causes at most one
wasted pin.

## 1.8 Heap operations (`Heap.Heap`) — processing flows

All functions take the transaction context (document 04) — shown as
`ctx` — which carries the WAL and lock operations.

```haskell
heapInsert :: Env -> TxnCtx -> RelationDesc -> Tuple -> IO RID
heapFetch  :: Env -> TxnCtx -> RelationDesc -> RID -> IO (Maybe Tuple)
heapUpdate :: Env -> TxnCtx -> RelationDesc -> RID -> Tuple -> IO ()
heapDelete :: Env -> TxnCtx -> RelationDesc -> RID -> IO ()
heapScan   :: Env -> TxnCtx -> RelationDesc -> IO [ (RID, Tuple) ]
  -- NOTE: scans are cursor-based in the executor (document 09);
  -- this list form is the storage-level primitive used by DDL and
  -- tests. The executor uses heapScanCursor with the same internals.
```

### heapInsert flow

1. `checkInsertable` (codec) → may throw `54000` / `22001`.
2. `bytes = encodeTuple schema tuple`.
3. Candidate page: `fsmFindPage rel (length bytes + itemSize)`, else
   allocate: `extendFile` → `pageId`; WAL `ALLOC_PAGE` (before first
   use); `initPage` under pin; append to relation page chain
   (set previous last page's `pd_next`, WAL `PAGE_IMAGE` for it, and
   update the in-memory `RelationDesc` page list).
4. Pin candidate, take page write lock.
5. Recompute fit from the real header. If it does not fit but
   `pageFragmentedFree` suffices → compact (log `PAGE_IMAGE` via the
   scratch-copy pattern, §1.4). If it still does not fit → unpin, go
   to 3 for a fresh page.
6. Append WAL `INSERT_TUPLE(rel, pageId, bytes)` → `lsn`.
   (Slot is *not* in the record: redo computes the same slot by
   replaying the same deterministic placement on the same page image —
   placement is a pure function of page content, so redo is exact.)
7. `slot <- pageInsertTuple page lsn bytes`; stamp header LSN.
8. Take exclusive row lock on the new RID (lock manager, document 04).
9. `fsmNoteFree`; unpin dirty. Return `RID pageId slot`.

### heapUpdate flow (same-RID, same-page rule of design/01 §1.5)

1. Pin page of `rid`, page write lock; read old bytes (must be live).
2. `newBytes = encodeTuple schema newTuple`; `checkInsertable` for the
   page-local rule:
   `length newBytes <= length oldBytes + pageFreeContiguous header`
   else throw `errTupleTooLarge` (statement rollback follows).
3. WAL `UPDATE_TUPLE(pageId, slot, oldBytes, newBytes)` → `lsn`.
4. If `length newBytes > length oldBytes` and the extra bytes do not
   fit contiguously at the tuple's offset (they never can in place —
   tuples are packed), perform the move-within-page variant:
   treat as delete-bytes + insert-bytes on the same page preserving
   the slot: write new bytes at `phUpper - newLen` region after a
   compaction that excludes the old tuple, then point the slot at the
   new offset. All of this is one page mutation under the same `lsn`,
   computed via the scratch-copy pattern (§1.4). RID unchanged.
5. Index maintenance is the *caller's* job (executor Modify operator),
   using the old/new tuples it already has.
6. Stamp LSN, unpin dirty, `fsmNoteFree`.

### heapDelete flow

1. Pin page, write lock; read old bytes.
2. WAL `DELETE_TUPLE(pageId, slot, oldBytes)` → `lsn`.
3. `pageDeleteTuple page lsn slot`; stamp, unpin dirty, `fsmNoteFree`.

### heapFetch / scan flow

Pin page, read lock, decode the slot's bytes with `decodeTuple`
(failure → `errInternal "corrupt tuple"`); scans iterate the
relation's page list in order and slots in ascending slot order,
skipping unused slots.
