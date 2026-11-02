# 06. Catalog Internals

Refines `design/06-catalog.md`.

## 6.1 Types (`Catalog.Types`)

```haskell
data RelKind = RelTable | RelIndex deriving (Eq, Show)

data ColumnDesc = ColumnDesc
  { colName :: !Text
  , colType :: !SqlType
  } deriving (Show)

data RelationDesc = RelationDesc
  { rdId       :: !RelId
  , rdName     :: !Text
  , rdKind     :: !RelKind
  , rdColumns  :: [ColumnDesc]     -- tables only; [] for indexes
  , rdPages    :: [PageId]         -- tables: heap page chain, in order
  , rdRoot     :: !PageId          -- indexes only; 0 for tables
  , rdTuples   :: !Int64
  , rdOwner    :: !RelId           -- indexes: owning table; tables: 0
  , rdIdxCol   :: !Int             -- indexes: 0-based column ordinal; -1 tables
  } deriving (Show)

data IndexDesc = IndexDesc         -- convenience projection of RelationDesc
  { ixRelId :: !RelId, ixName :: !Text, ixTable :: !RelId
  , ixColumn :: !Int, ixKeyType :: !SqlType, ixRoot :: !PageId }
```

`RelationDesc` values are treated as immutable snapshots. DDL and page
allocation produce *new* descriptors and swap them into the cache
(§6.3); executor operators capture the descriptor at statement start
and never observe a mid-statement change (DDL takes the table X lock,
so no concurrent change is possible anyway).

## 6.2 Bootstrap (`Catalog.Bootstrap`)

Fixed layout:

- Page 0: file header page (kind `PKCatalog`, special format):
  ```
  0  u32  magic "HDB1"
  4  u32  formatVersion = 1
  8  u32  pageSize (echo; cross-checked with control file)
  12 u32  classFirstPage   -- hask_class heap head
  16 u32  attrFirstPage    -- hask_attribute heap head
  20 u64  nextRelId        -- next relid to allocate (mirrors control data)
  ```
  (Remainder zero-filled.)
- The two catalog relations have fixed relids: `hask_class = 1`,
  `hask_attribute = 2`, and describe themselves with rows in
  `hask_class`/`hask_attribute` (self-describing bootstrap, like
  PostgreSQL's):
  - `hask_class` columns (design/06 §6.3): relid, relname, relkind,
    relpages_head, relroot, reltuples, relowner_table,
    relindex_column — types INT64/VARCHAR/VARCHAR/INT64×5.
  - `hask_attribute` columns: attrelid, attnum, attname, atttypid.

Bootstrap flow (new database): init page 0 → create both catalog
heaps (one page each) → insert their self-describing rows directly
via heap primitives (no transactions yet — the database is empty and
not yet open) → initial checkpoint → write control file
(document 11 §11.2).

Open flow (existing database): recovery (document 03) runs first;
then the cache loads by scanning `hask_class` and `hask_attribute`
using their self-descriptions.

Type codes in `atttypid`: 1=INT64, 2=FLOAT64, 3=VARCHAR, 4=BOOLEAN,
with `sqlTypeToCode`/`codeToSqlType` in `Catalog.Types`.

## 6.3 Cache (`Catalog.Cache`)

```haskell
data CatalogCache = CatalogCache
  { ccState   :: TVar CacheState
  , ccVersion :: TVar Word64        -- bumped by every committed DDL
  }

data CacheState = CacheState
  { csById   :: !(Map RelId RelationDesc)
  , csByName :: !(Map Text RelId)
  }

newCatalogCache :: IO CatalogCache
loadCatalog     :: Env -> IO ()            -- full (re)load from heaps
lookupTable     :: CatalogCache -> Text -> IO (Maybe RelationDesc)
lookupById      :: CatalogCache -> RelId -> IO (Maybe RelationDesc)
indexesOf       :: CatalogCache -> RelId -> IO [IndexDesc]  -- for a table
catalogVersion  :: CatalogCache -> IO Word64

-- DDL-side updates (called inside the DDL transaction; applied to the
-- cache at commit time by the session/transaction hook — see below):
stageCreateTable :: TxnCtx -> RelationDesc -> IO ()
stageCreateIndex :: TxnCtx -> IndexDesc -> IO ()
stageAllocPage   :: TxnCtx -> RelId -> PageId -> IO ()  -- extend rdPages
stageTupleDelta  :: TxnCtx -> RelId -> Int64 -> IO ()   -- reltuples adjust
```

Staging model: DML/DDL never mutate `ccState` directly. Changes are
accumulated in the `TxnCtx` (a list of cache-update closures) and
applied atomically by `commitTxn` (document 04) after the WAL flush;
on abort they are discarded. This keeps the cache consistent with
committed state at all times, and the "catalog version check at
statement start" of design/06 §6.5 becomes: a session records the
version its descriptors came from; `CREATE` statements bump the
version when their staged updates apply. (Full reload via
`loadCatalog` is used only at startup; run-time invalidation is purely
the staged-update mechanism, because there is exactly one process.)

Special case — page allocation during INSERT (document 01 §1.8)
stages `stageAllocPage`, but the *executing* statement also needs the
new page in its own snapshot of `rdPages`. Rule: `heapInsert` returns
the updated descriptor to its caller, and executor operators thread
the newest descriptor for the target table through the statement
(simple: the Modify operator keeps a local `IORef RelationDesc` for
its target table).

## 6.4 Catalog writes (DDL execution support)

```haskell
-- Catalog.Bootstrap / Catalog.Cache helpers used by executor DDL ops:
insertClassRow :: Env -> TxnCtx -> RelationDesc -> IO ()
insertAttrRows :: Env -> TxnCtx -> RelId -> [ColumnDesc] -> IO ()
allocRelId     :: Env -> TxnCtx -> IO RelId
  -- reads page 0's nextRelId under the catalog page's pin, increments,
  -- logs via PPageImage of page 0 + PCreateTable carries the relid so
  -- recovery of the counter is: max(seen relid)+1 recomputed in
  -- analysis if page 0's value is stale — page 0 is a normal page for
  -- WAL purposes (its updates are PAGE_IMAGE records), so no special
  -- case is needed in recovery.
```

`reltuples` persistence: `stageTupleDelta` also schedules a catalog
heap update of the `hask_class` row inside the same transaction
(UPDATE_TUPLE WAL record on the catalog page) — executed at statement
end for DML statements by the Modify operators (design/06 §6.4).
