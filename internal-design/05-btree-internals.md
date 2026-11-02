# 05. B+-Tree Index Internals

Refines `design/04-index-btree.md`.

## 5.1 Entry representation in pages

Index pages use the slotted layout of document 01 with these entry
formats (all integers little-endian):

```
Leaf entry payload:
  keyBytes   := encodeValue key          (self-delimiting per type)
  rid        := u32le pageId ++ u16le slotNum

Internal entry payload:
  sepKey     := encodeValue key          (absent for the -infinity slot,
                                          flagged by slot flag bit)
  child      := u32le pageId
```

Slot flags: the generic slot has no flag field in document 01's
4-byte item id; the internal node's `-infinity` entry is therefore
identified structurally: **slot 0 of an internal page is always the
-infinity entry** *(internal-design decision, recorded here: internal
pages keep at least one entry; lookup treats slot 0's key as
-infinity and never compares it)*. Its payload is just `child`.

Entry decode needs the index's key `SqlType` (from the catalog) to
know the key's byte length; `encodeValue` for `VText` is
length-prefixed internally, so keys are self-delimiting given the
type tag stored in the first byte of `encodeValue` output (document
00 §0.2: the canonical encoding begins with a type tag byte).

```haskell
-- Index.BTree internal entry types
data LeafEntry = LeafEntry { leKey :: !Value, leRid :: !RID }
data InternalEntry = InternalEntry { ieSep :: !(Maybe Value)  -- Nothing = -inf
                                   , ieChild :: !PageId }
```

Page-level primitives (built on document 01's slot functions):

```haskell
leafEntries     :: SqlType -> PageRef -> IO [LeafEntry]     -- slot order = key order
internalEntries :: SqlType -> PageRef -> IO [InternalEntry]
leafInsertEntry :: PageRef -> LSN -> Int -> LeafEntry -> IO ()  -- at position
leafDeleteEntry :: PageRef -> LSN -> Int -> IO ()
```

Entries within a page are kept in ascending `(key, RID)` (leaf) or
ascending separator order (internal). Positions are found by binary
search over the decoded entry list — pages hold at most a few hundred
entries, and decoding the list per operation is simpler and fast
enough; no in-page binary search over raw bytes is implemented
(readability first).

## 5.2 The per-index latch and pin budget

```haskell
data IndexHandle = IndexHandle
  { ihDesc  :: !IndexDesc        -- from catalog: relid, table, column, key type
  , ihLatch :: MVar ()           -- serialises structural changes (splits,
                                 -- root changes) for this index
  }
```

- Searches/inserts/deletes of entries take page content locks
  hand-over-hand (document 02 §2.5) and at most **3 pins at a time**
  (parent, child, one sibling during split).
- Structural changes additionally hold `ihLatch` for the duration of
  the split/root-change portion only.
- Bulk build does not need the latch (table X lock held by DDL).

## 5.3 Search flow

```haskell
btreeSearch :: Env -> IndexHandle -> Value -> IO [RID]
```

1. `root <- catalog root page of index` (from `IndexDesc`, refreshed
   from the catalog cache at statement start).
2. Descend: pin page (read lock); if internal, choose child = the
   entry with the largest separator `<= key` (slot 0 if none);
   unpin parent after pinning child (hand-over-hand: pin child first,
   then release parent).
3. At leaf: binary search the entry list for the first `(key, _)`;
   collect all consecutive entries with that key, following `pd_next`
   leaf links if the run reaches the page end (duplicates can span
   leaves).
4. Return RIDs in `(key, RID)` order.

Range search `btreeRange :: Env -> IndexHandle -> Maybe Value -> Maybe Value -> IO [RID]`
(lower/upper bounds, inclusive flags) descends to the lower bound and
walks the leaf chain until the upper bound is passed.

## 5.4 Insert flow (with splits)

```haskell
btreeInsert :: Env -> TxnCtx -> IndexHandle -> Value -> RID -> IO ()
```

1. Append WAL `PIndexInsert` first? — **No**: the WAL record for a
   logical index op cannot be finalised until the target leaf is
   known to have room (a split logs page images instead). The correct
   order used here:
   a. Descend with write locks, remembering the path (page ids +
      chosen slot positions). Pin budget: path pages are unpinned
      except the leaf and its parent, unless a split must propagate —
      splits re-descend under `ihLatch` (step c).
   b. If the leaf has room: WAL `PIndexInsert` → lsn; insert entry;
      stamp; done.
   c. If the leaf is full: take `ihLatch`, re-descend (root may have
      changed), then split:
      - allocate new page (extendFile + WAL `ALLOC_PAGE`),
      - compute both pages' new images on scratch copies,
      - WAL `PPageImage` for the original leaf, the new leaf, and
        (recursively) any internal page that gains a separator —
        root split also logs the new root page image and the catalog
        root update is part of the same transaction's catalog write,
      - install images, update leaf chain `pd_next` links (part of the
        images), stamp LSNs.
      Splits propagate up while the parent is full; the path is
      re-walked per level (trees are shallow; clarity over speed).
2. Idempotency variant for recovery: `btreeInsertIdempotent` skips the
   insert if `(key, RID)` is already present (checked at the leaf).

Note the deliberate asymmetry with heap inserts (document 01): index
inserts log *after locating* the leaf because their WAL payload is
logical. The WAL rule is still honoured — the record is appended
before the page bytes change, and page flush waits for the LSN.

## 5.5 Delete flow

```haskell
btreeDelete :: Env -> TxnCtx -> IndexHandle -> Value -> RID -> IO ()
```

Descend to leaf (write lock), find exact `(key, RID)`; if absent →
`errInternal "index entry missing"` during normal operation (heap and
index disagree = corruption), but a no-op in the idempotent recovery
variant. WAL `PIndexDelete` → lsn → remove entry → stamp. No merging,
no separator fix-ups (an internal separator that no longer equals the
smallest key of its child remains valid as a lower bound — standard
B+-tree deletion laziness; lookup logic in §5.3 relies only on
separators being *a* valid partitioning, specifically: separator `s`
for child `c` satisfies `all keys in c >= s` and `all keys in the
previous sibling < s`... the second property is preserved by insertion
order — implementers must keep the invariant "separator = smallest key
of the child at split time; later deletions only ever make the true
minimum larger, never smaller", which keeps both properties sound).

## 5.6 Bulk build flow (CREATE INDEX)

```haskell
btreeBuild :: Env -> TxnCtx -> IndexDesc -> [(Value, RID)] -> IO PageId
```

1. Caller (executor DDL) supplies all `(key, RID)` pairs collected
   from a heap scan (the statement memory budget of document 09 §9.1
   applies).
2. Sort by `(key, RID)` (`Data.List.sortBy` with `compareSql` on keys
   then RID order).
3. Fill leaves left to right at 100% occupancy except the last; link
   `pd_next`. Write each leaf via `pinNewPage` + direct byte assembly
   (this is initialisation, WAL via one `PPageImage` per page after
   assembly, following the scratch-copy pattern).
4. Build internal levels bottom-up from the leaves' first keys until
   one root remains.
5. Return the root page id; the caller stores it in the catalog and
   logs `PCreateIndex` with it.
6. Empty table: the index is a single empty leaf as root.

## 5.7 Concurrency summary

Readers and entry-level writers proceed concurrently on disjoint
pages; structural changes are serialised per index by `ihLatch`;
table-level DDL exclusion comes from the lock manager (document 04).
Deadlock between page content locks is prevented by the global rule
(document 02 §2.5) plus `ihLatch` being acquired **before** any page
lock of the split path and released after all of them.
