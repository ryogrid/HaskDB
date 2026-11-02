# 01. Storage Engine: Files, Pages, Tuples

## 1.1 Data file

The data file `haskdb.data` is an array of fixed-size pages numbered from
0 (`PageId = Word32`). Page `i` occupies bytes
`[i * PAGE_SIZE, (i+1) * PAGE_SIZE)`. New pages are appended at the end of
the file; pages are never removed from the middle (there is no
`DROP TABLE`, so page reclamation across relations is unnecessary;
see §1.7 for how emptied pages are reused within a relation).

The value of `PAGE_SIZE` is decision item **D-01**. It is fixed when a
database directory is created, stored in the control file, and checked on
every open.

## 1.2 Slotted page layout

Both heap pages and index pages use a *slotted page* structure. This
section describes the heap variant; the index variant is in
04-index-btree.md.

```
 offset 0
 +-------------------+----------------------------------------------+
 | PageHeader        | ItemId array (slot directory)                |
 +-------------------+----------------------------------------------+
 |                   |  free space                                  |
 |                   v                                              |
 +-------------------+----------------------------------------------+
 |                                     tuples grow from the end   |
 +----------------------------------------------------------------+
 offset PAGE_SIZE
```

### Page header (20 bytes)

| Field | Type | Meaning |
|-------|------|---------|
| `pd_lsn` | `Word64` | LSN of the last WAL record that changed this page |
| `pd_flags` | `Word16` | page kind (heap / index leaf / index internal / catalog / free), other flags |
| `pd_lower` | `Word16` | offset where the item-id array ends (start of free space) |
| `pd_upper` | `Word16` | offset where tuple data begins (end of free space) |
| `pd_special` | `Word16` | offset of the "special" area (used by index pages; 0 for heap) |
| `pd_next` | `Word32` | next page of the same relation (heap page chain, §1.4); for index pages, the B+-tree sibling/link use is defined in 04 |

Free space is the contiguous region `[pd_lower, pd_upper)`. The number of
slots is `(pd_lower - headerSize) / itemIdSize`.

### Item identifier (slot), 4 bytes

| Field | Type | Meaning |
|-------|------|---------|
| `lp_off` | `Word16` | offset of the tuple within the page |
| `lp_len` | `Word16` | length of the tuple in bytes; 0 marks a dead/unused slot |
| `lp_flags` | — | packed into the above: a slot with `lp_len = 0` is unused |

An RID `(PageId, SlotNumber)` is *stable*: a tuple never changes its RID
for its whole lifetime (see §1.5 on UPDATE). Slots of deleted tuples are
marked unused and may be reused by later inserts into the same page.

## 1.3 Tuple format

A tuple is stored entirely within one page. There is no overflow storage.

```
 +------------------+-----------+------------------------------+
 | TupleHeader      | fixed-    | variable-length              |
 | (4 bytes)        | length    | column values,               |
 |                  | values    | in column order              |
 +------------------+-----------+------------------------------+
```

### Tuple header (4 bytes)

| Field | Type | Meaning |
|-------|------|---------|
| `t_flags` | `Word8` | `DELETED` flag (set by DELETE before WAL-driven cleanup, see §1.6); other bits reserved |
| `t_natts` | `Word8` | number of columns stored (must equal the table's column count; kept for sanity checks) |
| reserved | 2 bytes | |

No NULL bitmap is needed (NULL is not supported). No per-tuple
xmin/xmax fields are stored: visibility and rollback are handled by the
lock manager and WAL undo (see 03-transactions-concurrency.md), not by
tuple versioning. This is a deliberate simplification consistent with
the locking-based concurrency design.

### Column value encoding

Values are stored in table-column order, with **no alignment padding**
(readability over hardware convenience; all reads/writes go through
explicit little-endian encode/decode functions).

| SQL type | Encoding |
|----------|----------|
| INT64 | 8 bytes, little-endian two's complement |
| FLOAT64 | 8 bytes, IEEE 754 binary64 bit pattern, little-endian |
| BOOLEAN | 1 byte: `0` = false, `1` = true |
| VARCHAR | 2-byte little-endian length `n` (bytes, `0 <= n <= 1024`) followed by `n` bytes of UTF-8 |

Because every VARCHAR carries its own length and all other types are
fixed-size, a tuple can be decoded given only the table schema. The tuple
length is the slot's `lp_len`; decoding must consume exactly `lp_len`
bytes, otherwise the page is corrupt.

### Maximum tuple size

The largest storable tuple is
`PAGE_SIZE - pageHeaderSize - itemIdSize - tupleHeaderSize`.
`CREATE TABLE` must reject schemas whose *minimum possible* tuple already
exceeds the page (not possible with the given types, since VARCHAR can be
empty), and `INSERT`/`UPDATE` enforce the per-tuple limit (§1.5).

## 1.4 Heap organisation

- Each table's heap is a **linked list of pages**: the head page id is
  stored in the catalog (`relpages_head`, see 06-catalog.md) and each
  page header's `pd_next` points to the next page of the same relation
  (0 = end of chain). Allocating a page appends it to the chain and is
  WAL-logged (`ALLOC_PAGE`, 02 §2.3). The in-memory page list used by
  scans and the free-space map is built by walking the chain from the
  catalog head at startup/first access.
  Rationale: with no DROP TABLE, a relation's page set only grows, so
  the chain is append-only and never needs restructuring.
- A sequential scan visits pages in list order and slots in slot order,
  skipping unused slots and tuples flagged `DELETED`-pending-cleanup.

## 1.5 INSERT / UPDATE / DELETE mechanics at the storage layer

### INSERT

1. Find a page of the relation with enough contiguous free space
   (§1.7). If none exists, allocate a new page at the end of the file.
2. If the encoded tuple does not fit into an *empty* page, the statement
   fails with an error (`tuple too large for page`, SQLSTATE `54000`;
   see 09-wire-protocol.md §9.6). This is a specified behaviour, not an
   implementation accident.
3. Write a WAL record, then place the tuple, allocate a slot (reusing an
   unused slot if present), update `pd_lower`/`pd_upper`, set `pd_lsn`.

### UPDATE

Specified semantics:

- The updated tuple keeps the **same RID**. Tuples never migrate to
  another page.
- If the new tuple image is **smaller than or equal to** the old image,
  it is written in place; the freed tail bytes become an in-page free
  fragment (reclaimed by in-page compaction, §1.6).
- If the new image is **larger** than the old image but still fits in
  the page's current free space plus the old image's space, it is
  written in place as well *(supplementary specification: the
  requirements only mandate an error when the tuple no longer fits the
  page; using existing free space of the same page is the natural
  reading of "does not fit in the current page → error")*.
- If the new image does not fit in the current page, the statement fails
  with `tuple too large for page` and the whole statement is rolled
  back. There is no fallback to another page.

Index entries: an UPDATE that changes an indexed column deletes the old
index entry and inserts a new one pointing to the same RID. An UPDATE
that does not touch indexed columns leaves the index untouched.

### DELETE

1. Write a WAL record containing the full before-image.
2. Mark the slot unused (`lp_len = 0`) and set the page LSN.
   The tuple bytes remain as free fragment until in-page compaction.
3. Delete all index entries pointing to the RID.

## 1.6 In-page compaction

When a page's free space is fragmented (checked on insert: contiguous
free space too small but total free space sufficient), the page is
compacted: live tuples are rewritten contiguously from the end of the
page, slot offsets are updated (RIDs unchanged — only offsets move),
fragments disappear. Compaction is itself WAL-logged as a page-image
record (see 02, WAL record type `PAGE_IMAGE`) so recovery stays simple.

## 1.7 Free-space management

Options considered:

- **Full scan of the relation's pages on every insert** — simplest, but
  O(pages) per insert.
- **In-memory free-space map (FSM)** — per relation, a map
  `PageId -> freeBytes`, rebuilt at startup by scanning page headers,
  updated by the buffer-pool write path. Not persisted; page headers on
  disk are the source of truth after a crash.

**Design**: the in-memory FSM. It is small, classical, and its loss on
crash is harmless because it is rebuilt from page headers during
startup/recovery. Persisting an FSM is decision item **D-14** (not
recommended; recorded for completeness).

Page allocation: new pages are appended to the data file. Because there
is no DROP, a page, once allocated to a relation, stays with that
relation forever; fully emptied pages simply report all their space in
the FSM and are reused by later inserts into the same relation.

## 1.8 Reading and writing pages

All page access goes through the buffer pool (02). The storage layer
never calls `pread`/`pwrite` on the data file directly. The only direct
file users are:

- the WAL manager (WAL file, appends + `fdatasync`),
- the control-file writer (atomic replace: write temp file, fsync,
  rename, fsync directory),
- startup/recovery code before the buffer pool is initialised.

## 1.9 Corruption behaviour *(supplementary specification)*

Header sanity checks (magic-free but cheap): `pd_lower <= pd_upper <=
pd_special or PAGE_SIZE`, slot offsets within `[pd_upper, PAGE_SIZE)`,
tuple decode consuming exactly `lp_len`. A failed check raises an
internal error (`XX000`) and aborts the current transaction; the server
does not attempt repair.
