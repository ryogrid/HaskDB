# 06. System Catalog

## 6.1 Role

The catalog stores all metadata: tables, columns, indexes, and the
statistics the planner needs. The catalog itself is stored as ordinary
heap pages inside the same data file, in relations whose layout is
fixed by this document (bootstrap relations), so the heap/WAL/recovery
machinery covers metadata with no special cases.

Catalog changes are made only by DDL statements, inside transactions,
and are WAL-logged like user data (record types `CREATE_TABLE` /
`CREATE_INDEX`, plus ordinary tuple records for the catalog heaps
themselves — the design logs *both* the semantic record and lets the
catalog heap pages be covered by normal tuple records; recovery treats
catalog pages as normal pages).

## 6.2 Bootstrap

Page 0 of the data file is reserved: it holds the file header
(`PAGE_SIZE` echo, catalog root page ids, format version) so that the
catalog can be found before any catalog is read. The bootstrap catalog
relations start at fixed page ids recorded in page 0.

On first creation of a database directory, the server:

1. writes the control file,
2. initialises page 0,
3. creates the three catalog relations below as empty heaps,
4. writes a checkpoint.

## 6.3 Catalog relations

### `hask_class` — one row per table or index

| Column | Type | Meaning |
|--------|------|---------|
| `relid` | INT64 | unique, monotonically allocated relation id |
| `relname` | VARCHAR | table or index name (lower-cased) |
| `relkind` | VARCHAR | `'table'` or `'index'` |
| `relpages_head` | INT64 | first heap page (tables); unused for indexes |
| `relroot` | INT64 | B+-tree root page (indexes); 0 for tables |
| `reltuples` | INT64 | approximate row count (tables); entry count (indexes) |
| `relowner_table` | INT64 | for indexes: relid of the owning table; 0 for tables |
| `relindex_column` | INT64 | for indexes: ordinal of the indexed column; 0 for tables |

### `hask_attribute` — one row per column of a table

| Column | Type | Meaning |
|--------|------|---------|
| `attrelid` | INT64 | owning table's relid |
| `attnum` | INT64 | 1-based column ordinal |
| `attname` | VARCHAR | column name (lower-cased) |
| `atttypid` | INT64 | type code: 1=INT64, 2=FLOAT64, 3=VARCHAR, 4=BOOLEAN (mirrors the wire OIDs by mapping table in 09) |

### `hask_stat` — *(reserved, not populated in the baseline)*

The fixed cost model (07) needs only `reltuples`. No histograms or
distinct-value statistics are collected. This relation is not created;
it is mentioned only to record that adding statistics later would not
change the catalog's shape for existing relations. *(Placeholder note,
not a schema commitment.)*

## 6.4 Row counts (`reltuples`)

- Maintained by the executor: at the end of each INSERT/UPDATE/DELETE
  statement, the catalog cache's counter for the table is adjusted by
  the number of inserted/deleted rows, and the new value is written to
  `hask_class` inside the same transaction (so rollback restores it and
  a crash cannot leave a count that disagrees with committed data by
  more than the in-flight transactions at crash time; recovery leaves
  counts consistent with committed state because the update is itself
  transactional).
- The planner treats `reltuples` as exact enough for its fixed cost
  model; small drift under concurrency is acceptable for a teaching
  system and is corrected by `CREATE INDEX` builds and checkpoints
  only if it is free to do so — no `ANALYZE` command exists.

## 6.5 Catalog cache

Each process keeps an in-memory cache: relid/name → `RelationDesc`

```haskell
data RelationDesc = RelationDesc
  { rdId       :: RelId
  , rdName     :: String
  , rdKind     :: RelKind            -- Table | Index
  , rdColumns  :: [ColumnDesc]       -- for tables
  , rdPages    :: [PageId]           -- heap page list (tables)
  , rdRoot     :: PageId             -- index root (indexes)
  , rdTuples   :: Int64
  }
```

- The cache is populated lazily from the catalog heaps and invalidated
  by DDL: any session that commits a DDL change bumps a global catalog
  version counter (`TVar Word64`); sessions check the version at
  statement start and reload descriptors whose version is stale.
  *(Supplementary specification — a single-user teaching system does
  not need finer-grained invalidation.)*
- Name resolution in the analyzer reads only the cache (never the
  catalog heap directly).

## 6.6 Identifier limits *(supplementary specification)*

Table, index and column names are VARCHAR values in the catalog and
therefore inherit the 1024-byte cap; the practical limit is the page:
a `CREATE TABLE` whose catalog rows do not fit is impossible in
practice for reasonable schemas, and pathological cases fail with the
ordinary `tuple too large` error. No separate identifier-length rule
is imposed.
