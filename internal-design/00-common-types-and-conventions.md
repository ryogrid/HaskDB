# 00. Common Types, Package Layout, and Conventions

## 0.1 Package layout

Single Cabal package `haskdb`:

```
haskdb.cabal
src/
  HaskDB/
    Common/
      Types.hs        -- identifiers, Value, Tuple, SqlType
      Error.hs        -- SqlError, throw helpers, SQLSTATE constants
      Codec.hs        -- little-endian ByteString codecs, CRC32
      Config.hs       -- Config record and defaults
    Storage/
      FileManager.hs  -- raw page I/O on the data file
      Page.hs         -- page structure, slotted-page primitives
      BufferPool.hs   -- document 02
      FreeSpace.hs    -- free-space map
    Wal/
      Format.hs       -- WAL record types and codecs
      Manager.hs      -- append/flush
      Recovery.hs     -- analysis/redo/undo
    Txn/
      Manager.hs      -- transaction lifecycle
      LockManager.hs  -- STM lock table
    Heap/
      TupleCodec.hs   -- Value <-> bytes per schema
      Heap.hs         -- insert/update/delete/scan a relation heap
    Index/
      BTree.hs        -- document 05
    Catalog/
      Types.hs        -- RelationDesc, ColumnDesc
      Bootstrap.hs    -- page 0, catalog creation
      Cache.hs        -- in-memory catalog cache
    Sql/
      Lexer.hs
      Parser.hs
      Ast.hs          -- raw (unresolved) AST
      Analyzer.hs     -- resolved AST + semantic checks
    Planner/
      CostModel.hs
      Planner.hs      -- resolved AST -> Plan
    Executor/
      Types.hs        -- Plan (physical), ExecCtx, operator state
      Eval.hs         -- predicate/expression evaluation
      Operators.hs    -- scans, filter, project
      Joins.hs
      Aggregate.hs
      Sort.hs
      Modify.hs       -- Insert/Update/Delete/DDL operators
    Server/
      Wire.hs         -- message codecs
      Session.hs      -- per-connection state machine
      Listener.hs     -- accept loop
app/
  Main.hs             -- entry point (document 11)
test/
  ...                 -- per design/10 test strategy
```

Import rule: a module may only import modules from its own layer or
lower layers (order: Common < Storage/Wal/Txn < Heap/Index/Catalog <
Sql < Planner < Executor < Server). `Main` wires everything together.

## 0.2 Core types (`HaskDB.Common.Types`)

```haskell
type PageId  = Word32          -- page number in the data file
type LSN     = Word64          -- byte offset of a WAL record in the WAL file
type TxnId   = Word64          -- 0 = invalid / none
type RelId   = Int64           -- catalog relation id
type SlotNum = Int             -- slot index within a page (0-based in code;
                               -- design documents count slots the same way)

data RID = RID { ridPage :: !PageId, ridSlot :: !SlotNum }
  deriving (Eq, Ord, Show)

data SqlType = TyInt64 | TyFloat64 | TyVarchar | TyBool
  deriving (Eq, Show)

-- PostgreSQL type OID for the wire protocol (design/09)
typeOid :: SqlType -> Word32
typeOid TyInt64   = 20     -- int8
typeOid TyFloat64 = 701    -- float8
typeOid TyVarchar = 1043   -- varchar
typeOid TyBool    = 16     -- bool

data Value
  = VInt   !Int64
  | VFloat !Double
  | VText  !ByteString     -- UTF-8 bytes, length <= 1024 (checked on write paths)
  | VBool  !Bool
  deriving (Eq, Show)

valueType :: Value -> SqlType

-- A decoded tuple: one Value per table column, in column order.
type Tuple = [Value]

-- Canonical byte encoding of a Value, used for hash keys (joins,
-- aggregation) and B+-tree key comparison. Must satisfy:
--   encodeValue a == encodeValue b  iff  compareSql a b == EQ
-- (For VFloat this uses the IEEE bit pattern after normalising -0.0 to
-- 0.0; NaN never occurs, see design/05 section 5.4.)
encodeValue :: Value -> ByteString

-- SQL comparison semantics (design/05 section 5.4).
compareSql :: Value -> Value -> Ordering   -- requires equal types;
                                           -- callers guarantee this
```

Notes:

- `Value` uses strict fields everywhere; tuples are short (one entry
  per column), so plain lists are fine and keep the code readable.
- `VText` stores raw UTF-8 `ByteString`, not `Text`, because the
  storage format, the 1024-**byte** limit, and byte-wise comparison
  are all byte-oriented. Conversion to `Text` happens only at
  boundaries that need it (none in the baseline).
- `-0.0` normalisation: `encodeValue (VFloat x)` encodes
  `if x == 0 then 0 else x` so that `-0.0 = 0.0` holds under `EQ`
  comparisons and hash equality, matching numeric comparison.

## 0.3 Configuration (`HaskDB.Common.Config`)

All provisional / deployment values are centralised here. They are
read once at startup (document 11) and threaded through the system in
an `Env` record (see §0.5).

```haskell
data Config = Config
  { cfgDataDir        :: FilePath
  , cfgPort           :: Int        -- default 54329 (avoid clashing with a real PostgreSQL)
  , cfgPageSize       :: Int        -- PROVISIONAL (D-01): 8192. Only used when
                                    -- creating a new database; afterwards the
                                    -- control file's value is authoritative.
  , cfgBufferFrames   :: Int        -- PROVISIONAL (D-07): 1024
  , cfgStmtMemBudget  :: Int        -- PROVISIONAL (D-08): 256 * 1024 * 1024 bytes
                                    -- per statement (sort/materialise/hash build)
  , cfgCheckpointSecs :: Int        -- PROVISIONAL (D-11): 300
  , cfgLockWaitSecs   :: Int        -- used only if D-12 chooses timeouts: 10
  } deriving (Show)
```

`defaultConfig :: FilePath -> Config` fills the defaults above.

## 0.4 Errors (`HaskDB.Common.Error`)

```haskell
data SqlError = SqlError
  { seState   :: !Text        -- SQLSTATE, e.g. "42601"
  , seMessage :: !Text
  } deriving (Show)
instance Exception SqlError

throwSql :: MonadIO m => Text -> Text -> m a   -- state -> message -> throw

-- Frequently used constructors:
errSyntax        :: Text -> SqlError   -- 42601
errUndefinedTable  :: Text -> SqlError -- 42P01
errUndefinedColumn :: Text -> SqlError -- 42703
errFeatureNotSupported :: Text -> SqlError -- 0A000
errTupleTooLarge   :: SqlError         -- 54000
errMemoryLimit     :: SqlError         -- 54000
errStringTooLong   :: SqlError         -- 22001
errDeadlock        :: SqlError         -- 40P01
errInternal        :: Text -> SqlError -- XX000
```

Rules:

- Library code throws `SqlError` (via `throwIO`) for all user-visible
  failures. Programming-invariant violations use `errInternal` with a
  message naming the invariant — never bare `error`/`undefined` in
  non-test code.
- Only `Server.Session` catches `SqlError` (to emit `ErrorResponse`);
  everywhere else it propagates and triggers transaction rollback by
  the transaction context's bracket (document 04 §4.2).

## 0.5 The runtime environment (`Env`)

One immutable record created at startup and passed (via function
arguments or a `ReaderT`-free explicit parameter — explicit arguments
are preferred for readability) to all layers:

```haskell
data Env = Env
  { envConfig     :: Config
  , envFiles      :: FileManager
  , envBufferPool :: BufferPool
  , envWal        :: WalManager
  , envTxnMgr     :: TxnManager
  , envLockMgr    :: LockManager
  , envCatalog    :: CatalogCache
  }
```

Managers hold their own mutable state in `TVar`/`MVar` fields
(documented per manager). `Env` itself is never mutated after startup.

## 0.6 Byte codecs (`HaskDB.Common.Codec`)

Little-endian helpers over strict `ByteString`, implemented with
`Data.ByteString.Builder` for writing and a small hand-rolled reader
monad for reading (boot libraries only):

```haskell
newtype Reader a = Reader { runReader :: ByteString -> Int -> Either Text (a, Int) }
-- primitives: getW8, getW16le, getW32le, getW64le, getI64le,
--             getBytes n, getRemaining
putW8, putW16le, ... :: Builder

crc32 :: ByteString -> Word32   -- CRC-32 (IEEE), table-driven
```

Disk formats use little-endian; the wire protocol (document 10) uses
its own big-endian helpers inside `Server.Wire`. The two never mix.

## 0.7 Coding conventions

- GHC2021 language edition; `-Wall` clean.
- No partial functions on data read from disk or the network: all
  decoders return `Either Text a` and callers convert failures with
  `errInternal` (disk) or a protocol error (network).
- Every exported function that can fail in a user-visible way documents
  its error SQLSTATEs in a Haddock comment.
- Names: functions that pin pages end in the pattern
  `withPage ... :: ... -> (Page -> IO a) -> IO a` style brackets
  wherever possible, so pin/unpin pairing is structural, not manual
  (document 02 §2.3).
