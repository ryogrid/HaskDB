# 04. Index: B+-Tree

## 4.1 Role and assumptions

`CREATE INDEX` creates a secondary index on one table column.
*(The requirements do not name an index type. The classical default —
and the only type this design specifies — is a B+-tree over a single
column. Composite-column indexes and other index types are recorded as
decision item **D-04** and are not in the baseline.)*

Properties:

- Single-column keys of any supported type (INT64, FLOAT64, VARCHAR,
  BOOLEAN).
- **Non-unique**: duplicate keys are allowed; entries are ordered by
  `(key, RID)` so every entry is unique as a pair.
- The index stores `(key, RID)` pairs; it is not a covering index
  (index-only scans would need visibility information the tuple format
  does not carry — see 01 §1.3).
- Indexes are maintained transactionally: index changes are WAL-logged
  in the same transaction as the heap change that caused them
  (02 §2.3), so heap/index consistency survives crashes.

## 4.2 Key ordering

Keys compare by the SQL comparison semantics of their type (05 §5.4):

- INT64: numeric order.
- FLOAT64: numeric order; NaN cannot occur (05 §5.4), so the order is
  total.
- VARCHAR: byte-wise lexicographic order over UTF-8 bytes
  *(supplementary specification — no collation support exists)*.
- BOOLEAN: false < true.

## 4.3 Page layout

Index pages reuse the slotted-page skeleton of 01 §1.2 with a different
header special area.

### Common

- `pd_flags` marks the page as index leaf / index internal / index root.
- The header field `pd_next` (01 §1.2) is, for leaf pages, the next
  leaf page of the leaf chain used by range scans (0 = none); for
  internal pages it is unused (0).
- The `pd_special` area of index pages holds:
  - `level :: Word16` (0 = leaf).

### Leaf entry

```
 +----------------------+-------------------+
 | key (type encoding)  | RID (6 bytes)     |
 | as in 01 §1.3        | PageId W32 + slot |
 +----------------------+-------------------+
```

Entries in a leaf are sorted by `(key, RID)`. A slot points at an entry;
entries are variable-length because VARCHAR keys are variable-length.

### Internal entry

```
 +----------------------+-------------------+
 | separator key        | child PageId      |
 | (type encoding)      | Word32            |
 +----------------------+-------------------+
```

Standard B+-tree convention: the first slot of an internal page is a
pointer with an implicit `-infinity` separator (stored as a flag bit in
the slot), each subsequent separator is the smallest key of the child it
points to.

## 4.4 Operations

All operations take the page content locks of 02 §2.1 in a
**top-down, hand-over-hand (crabbing)** fashion where possible; for
simplicity and readability, a split that propagates to the root
re-acquires locks from the root under a per-index latch. Given the
readability priority and expected scale, the baseline implementation
may serialise structural modifications per index with a single
per-index write latch, while searches still proceed concurrently on
stable pages. *(Implementation simplification, no semantic effect.)*

- **Search(key)** → descend to leaf, binary search within the page
  (entries are sorted), return all RIDs with that key.
- **Range scan** `key >= lo AND key < hi` → descend to `lo`'s leaf,
  follow `nextLeaf` chain.
- **Insert(key, rid)** → descend; insert into leaf keeping order; if
  the leaf overflows, split it: move the upper half to a new page,
  insert a separator into the parent, link the leaf chain. Splits may
  propagate; a root split creates a new root page and updates the
  catalog's `index_root` for the index (WAL-logged).
- **Delete(key, rid)** → descend; remove the entry. **No merge/rebalance
  on delete** *(supplementary specification)*: under-full pages are
  accepted (they only waste space; correctness is unaffected). This is
  the classical simplification used by many teaching implementations;
  rebalancing is listed as possible future work in 11-open-decisions.md
  (D-20), not in the baseline.
- **Bulk build** (for `CREATE INDEX`): scan the heap once, collect
  `(key, RID)` pairs, sort in memory, and build the tree bottom-up,
  page by page. Bottom-up build is simpler and produces a compact tree.
  (External sorting is not involved; if the collected pairs exceed
  memory, the build fails — consistent with the no-external-sort stance;
  the limit policy is the same decision as D-08.)

## 4.5 WAL logging of index changes

Following 02 §2.3:

- Entry insert/delete in a leaf: `INDEX_INSERT` / `INDEX_DELETE`
  records (logical within the page; redo/undo re-descend the tree to
  find the leaf, so a stale leaf hint is harmless).
- Splits, root changes, and bulk build: `PAGE_IMAGE` records for every
  created/modified page, plus the catalog record that publishes the new
  root. A partially logged split is never visible because the catalog
  root pointer changes only with the last record of the same
  transaction, and recovery undo restores before-images in reverse
  order.

## 4.6 Executor use

- `IndexScan` (08-executor.md) uses Search for equality predicates and
  Range scan for `<, <=, >, >=` predicates on the indexed column.
- `Index Nested Loop Join` probes the index with Search for each outer
  tuple.
- The planner's rules for choosing index access are in 07-planner.md.

## 4.7 Statistics kept

Per index, the catalog stores only its root page and owning table/column
(06-catalog.md). No key-distribution statistics are kept (consistent
with the fixed cost model, 07-planner.md).
