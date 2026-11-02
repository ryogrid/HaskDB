# 09. Executor Internals

Refines `design/08-executor.md`.

## 9.1 Plan type and operator state (`Executor.Types`)

```haskell
data Plan = Plan { planNode :: PlanNode, planCost :: Double,
                   planRows :: Int64 }

data PlanNode
  = PSeqScan    RelId
  | PIndexScan  RelId IndexDesc IndexBound
  | PFilter     PPred Plan
  | PProject    [ProjItem] Plan
  | PNestedLoop Plan Plan (Maybe PPred)
  | PIndexNestedLoop Plan RelId IndexDesc FlatRef  -- outer, inner table,
                                                   -- index, key position
  | PHashJoin   Plan Plan JoinSides
  | PHashAggregate [FlatRef] [AggSpec] Plan
  | PSort       [(Int, Bool)] Plan
  | PMaterialize Plan
  | PInsert     RelId [[Value]]
  | PUpdate     RelId [(Int, PAssignRhs)] Plan
  | PDelete     RelId Plan
  | PCreateTable CreateTableStmt
  | PCreateIndex CreateIndexStmt

data ProjItem = PJCol FlatRef | PJLit Value
data JoinSides = JoinSides { jsBuild :: WhichSide, jsBuildKey :: FlatRef,
                             jsProbeKey :: FlatRef, jsResidual :: Maybe PPred }
data WhichSide = BuildLeft | BuildRight
```

Operator execution uses an explicit state value per open plan:

```haskell
data ExecState = ExecState
  { esNode   :: PlanNode
  , esChild  :: [ExecState]        -- 0, 1 or 2 children, opened lazily
  , esData   :: ExecData           -- per-operator scratch state
  }

data ExecData
  = DNone
  | DScan    ScanCursor
  | DFilter
  | DProject
  | DNL      { nlOuter :: Maybe [Value], nlInnerOpen :: Bool }
  | DINL     { inlOuter :: Maybe [Value], inlHits :: [(RID, [Value])] }
  | DHash    { hjTable :: Maybe (HashMap ByteString [[Value]]),
               hjProbe :: ... }
  | DAgg     { aggGroups :: HashMap ByteString AggAccums }
  | DSort    { sortRows :: Maybe [[Value]] , sortIx :: Int }
  | DMat     { matRows :: [[Value]], matIx :: Int }
  | DModify  { modCount :: Int64 }

openPlan  :: ExecCtx -> Plan -> IO ExecState
nextRow   :: ExecCtx -> ExecState -> IO (Maybe [Value])
closePlan :: ExecCtx -> ExecState -> IO ()
```

`ExecCtx` bundles `Env`, `TxnCtx`, the statement's `SubqueryResults`,
and the **memory budget tracker**:

```haskell
data ExecCtx = ExecCtx
  { ecEnv :: Env, ecTxn :: TxnCtx
  , ecSubq :: Map SubqueryId SubqueryResult
  , ecMem  :: MemBudget
  }

data SubqueryResult
  = SQScalar (Maybe Value)        -- Nothing = zero rows (error at use site)
  | SQSet    [Value]              -- for IN: the single column's values
  | SQExists Bool

data MemBudget = MemBudget { mbLimit :: Int, mbUsed :: IORef Int }
chargeMem   :: ExecCtx -> Int -> IO ()   -- throws errMemoryLimit past limit
releaseMem  :: ExecCtx -> Int -> IO ()
-- charged units: estimated bytes = sum over rows of (tupleByteSize)
-- where tupleByteSize uses encoded sizes: 8/8/1/len+2 per column.
```

Rows flowing between operators are `[Value]` in the flat layout of
document 08 §8.4. Scans additionally produce the RID; operators that
need it (joins for locking, Modify) receive it through a side channel:
scan states remember the *current* row's RID, and `nextRow` returns
`(Maybe RID, [Value])` internally — the public SELECT path discards
RIDs at `PProject`. (Concretely: `nextRow` returns
`Maybe (Maybe RID, [Value])`; the RID is `Just` only for rows coming
directly from a base-table scan under a Modify operator. Join outputs
carry `Nothing`.)

## 9.2 Statement execution preamble

```
executeStatement :: ExecCtx -> Plan -> IO StmtResult

data StmtResult
  = RowsResult [[Value]]-streamed   -- see below
  | CountResult Text Int64          -- tag name, affected rows
```

Flow:

1. Collect all `SubqueryId`s referenced by the plan (planner stored
   them in a list on the root `Plan` wrapper — add field
   `planSubqueries :: [(SubqueryId, Plan, SQKind)]`).
2. Execute each subquery plan fully (recursively via this same
   function, sharing the `TxnCtx` and memory budget), store results:
   scalar → also enforce ≤ 1 row here (`21000` if more; 0 rows →
   `SQScalar Nothing`, error raised at evaluation time per
   design/05 §5.6 — raised when the enclosing predicate is first
   evaluated; if the predicate is never evaluated because the input
   is empty, no error occurs. *This lazy-error choice is recorded
   here: PostgreSQL raises it when the scalar subquery is evaluated,
   which for a top-level WHERE on an empty table also never happens
   if the filter short-circuits per-row — matches.*)
3. Open the main plan, stream rows to the caller (session layer) via
   a callback `([Value] -> IO ())`, close the plan.
4. For Modify/DDL plans, run to completion and return counts.

## 9.3 Operator implementations (key flows)

### SeqScan cursor

```haskell
data ScanCursor = ScanCursor
  { scPages :: [PageId], scPageIx :: Int, scSlot :: Int,
    scCurrentPage :: Maybe PinnedPage }
```

`next`: advance slot; on page end, unpin and move on. For each live
tuple: decode, take **shared row lock** (via `Txn.LockManager`,
document 04) — scanning for a Modify child takes shared locks too;
the Modify operator upgrades. Return `(Just rid, values)`.

### IndexScan cursor

Equality: on open, `btreeSearch` → RID list (materialised; bounded by
matches, charged to memory budget only if > 10,000 entries — simpler:
not charged; match lists are proportional to result size which the
client consumes anyway. *Recorded simplification.*); then fetch heap
tuples one by one (`heapFetch`, lock S).
Range: on open, descend once and keep the current leaf pinned while
walking entries + leaf chain; fetch heap tuples as above. Pin budget:
1 leaf + 1 heap page.

### Filter / Project

Stateless per row: `evalPred` (§9.4) / map `ProjItem`s.

### NestedLoop

State: current outer row + inner state. On outer advance, close and
re-open the inner state — **except** when the inner node is
`PMaterialize` (its state replays from its row list without
re-executing). The planner guarantees derived tables are materialised,
so re-open cost only hits base scans (cheap: cursor reset).

### IndexNestedLoop

On each outer row: key = outerRow !! keyFlatRef; `btreeSearch`;
fetch each hit's heap tuple (lock S); concatenate outer ++ inner;
apply residual predicate.

### HashJoin

Open: fully consume the build side into
`HashMap ByteString [[Value]]` keyed by `encodeValue` of the build
key (charged to the memory budget per row). Probe: stream the other
side; for each row, look up matches, emit concatenations passing the
residual. Output layout is always **left-plan columns ++ right-plan
columns** regardless of which side built the table (concatenation
order is normalised at emit time).

### HashAggregate

Open consumes the entire input: group key = concatenation of
`encodeValue` over group refs; accumulators:

```haskell
data AggAccum
  = AccCount !Int64
  | AccSumInt !Int64            -- overflow-checked: use
                                -- addWithOverflow-style checked add;
                                -- on overflow throw 22003 (D-09 option A
                                -- provisional)
  | AccSumFloat !Double
  | AccAvg !Double !Int64       -- running sum as Double, count
  | AccMinMax !Value            -- current extreme (compareSql)
```

Emission order: hash map iteration order (unspecified), one row per
group = group key values (decoded from the first row seen per group —
the state keeps one representative row's group columns) ++ finalised
accumulators (`AVG` = sum/count as `VFloat`; empty global group per
design/05 §5.8 provisional → SUM/AVG/MIN/MAX over zero rows throw
`errInternal`-free `SqlError "22003"`? — no: use SQLSTATE `21000`
with message "aggregate over empty input" *(provisional, tied to
D-09)*; COUNT returns 0).

### Sort

Open consumes input fully into a list (charged to budget), sorts with
`Data.List.sortBy` comparing the projected output rows by the sort
key indexes with per-column `compareSql` and direction. Stability
comes free from `sortBy`.

### Materialize

Open consumes the child fully (charged), then replays. Re-openable
(reset index) for nested-loop use.

## 9.4 Predicate evaluation (`Executor.Eval`)

```haskell
evalPred :: ExecCtx -> PPred -> [Value] -> Bool
evalOperand :: ExecCtx -> POperand -> [Value] -> Value
```

- `POCol i` = row !! i (bounds are planner-guaranteed).
- `POScalar id`: look up `SQScalar`; `Nothing` → throw the scalar
  subquery error (`21000`); `Just v` → v.
- `PPIn ref negated id`: membership test of `row !! ref` in the
  `SQSet` list using `compareSql == EQ` (list scan; sets are
  statement-materialised and expected small — a HashSet optimisation
  is possible later but not in the baseline).
- Comparisons use `compareSql`; type equality was analyzer-checked.

## 9.5 Modify operators

### Insert

For each VALUES row: `heapInsert` (document 01 flow) → for each index
on the table: `btreeInsert key rid`. Stage `reltuples` delta +1 per
row in the `TxnCtx` (catalog staging, document 06 §6.3). Count rows.

### Update

1. Open child scan; collect `(RID, oldValues)` for **all** matching
   rows first (list charged to budget), close scan.
2. For each: lock X (upgrade) on RID; compute new values from
   assignments (`PALit` / `PACol` = old value at flat ref);
   `heapUpdate` (may throw tuple-too-large → statement rollback via
   document 04 §4.2 handles the partial work); for each index whose
   column changed: `btreeDelete oldKey rid`, `btreeInsert newKey rid`.
3. Count = number of updated rows.

### Delete

Collect RIDs via child scan (phase 1), then per RID: lock X,
`heapDelete`, `btreeDelete` for every index. Stage reltuples delta.

### DDL operators

- CreateTable: `allocRelId`; build `RelationDesc` (no pages);
  `insertClassRow`/`insertAttrRows` via heap primitives on catalog
  relations (inside the same txn); stage cache insert.
- CreateIndex: lock X on table (lock manager call in the operator's
  open); heap scan collecting `(key, RID)` (charged to budget);
  `btreeBuild`; catalog rows; stage cache insert. Tag `CREATE INDEX`.

## 9.6 Result streaming and counts

The session layer (document 10) drives SELECT plans with the row
callback; Modify/DDL plans ignore the callback and return
`CountResult`. Command tag strings are assembled in the session layer
from `StmtResult` (design/09 §9.4).
