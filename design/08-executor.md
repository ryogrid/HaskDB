# 08. Executor

## 8.1 Execution model

The executor implements the classical **iterator (volcano) model**.
Every operator exposes:

```haskell
data ExecState = ...  -- per-operator state, created by `open`

open  :: Plan -> TxnCtx -> IO ExecState
next  :: ExecState -> IO (Maybe Tuple)   -- Nothing = exhausted
close :: ExecState -> IO ()
```

- `Tuple` at executor level is a list of decoded `Value`s plus, where
  needed, the source RID (scans produce `(RID, Tuple)` internally;
  `Project` drops RIDs).
- `Value = VInt Int64 | VFloat Double | VText ByteString | VBool Bool`.
- Execution runs inside the statement's transaction context (`TxnCtx`
  carries the transaction id, the lock manager handle, buffer pool and
  WAL handles, and the statement's error/abort plumbing).
- Errors are exceptions carrying an `SqlError` (code + message); the
  session layer converts them to wire-protocol errors (09 §9.6) after
  statement rollback.

Demand-driven `next` keeps memory bounded for plain scans/filters/
joins (except where materialisation is mandated: Sort, Hash Join build
side, Hash Aggregate, derived tables, subqueries).

## 8.2 Scan operators

### SeqScan

- Iterates the relation's page list in order; for each page: pin, take
  page content read lock, iterate slots, decode live tuples.
- Acquires a shared row lock on each returned tuple's RID before
  returning it (03 §3.2). *(Locking per returned tuple — not per
  examined tuple — is the baseline; examined-but-filtered tuples are
  locked by the Filter's input scan only if the Filter sits above the
  scan and the scan returns them, which it does: filtering happens
  above the scan, so all scanned tuples are locked. This is the simple,
  correct-under-S2PL behaviour; lock-count optimisation is a
  non-goal.)*

### IndexScan

- Equality: B+-tree Search → RIDs → fetch each heap tuple by RID
  (pin page, decode), taking shared row locks.
- Range: descend to the lower-bound leaf, follow the leaf chain,
  applying the bound checks per entry.
- Heap fetches are random page accesses; no prefetching (non-goal).

## 8.3 Filter and Project

- `Filter` evaluates the predicate tree per tuple. Predicate evaluation
  is pure: `evalPred :: Predicate -> Tuple -> Bool` (two-valued logic;
  every comparison on type-mismatched operands was already rejected by
  the analyzer, so evaluation never fails on types).
- `Project` maps a tuple to the select-list shape (column picks and
  literals).

## 8.4 Materialisation

`Materialize` stores all rows of its child in an in-memory list and
replays them. Used for: derived tables, subquery results, the inner
side of joins when the child is a subquery plan, and as the input
stage of `Sort`. Materialised rows count against the same memory
limit discipline as sort (D-08) *(supplementary specification: one
shared per-statement memory budget for materialisation+sort+hash
tables keeps the failure mode uniform — exceeding it is a `54000`
error; the budget's default is D-08)*.

## 8.5 Join operators

### NestedLoopJoin

For each outer tuple, scan the whole inner plan; emit pairs passing
the join/residual predicate. Inner plan is re-`open`ed per outer tuple
unless it is a materialised node (derived tables are, §7.6).

### IndexNestedLoopJoin

For each outer tuple, extract the join key value, probe the inner
relation's index (Search), fetch matching heap tuples, take locks,
emit pairs passing residual predicates.

### HashJoin

1. Build: consume the smaller side fully into a hash table keyed by the
   join column value (key equality per 05 §5.4; the hash function is
   over the canonical byte encoding of the value).
2. Probe: stream the larger side; for each tuple, look up matches;
   emit pairs passing residual predicates.
3. No spilling: if the build side exceeds the statement memory budget,
   the statement fails with `54000` (consistent with the
   no-external-anything stance).

## 8.6 Aggregation

`HashAggregate`:

- Consume all input rows. Maintain a hash map from group key (the
  GROUP BY column values, encoded canonically) to a vector of
  accumulator states, one per aggregate call.
- Accumulators: `COUNT` → running `Int64`; `SUM` → `Int64` or `Double`
  per input type (overflow per D-09); `AVG` → `(sum :: Double, count)`
  finalised as `sum / count`; `MIN`/`MAX` → current extreme `Value`.
- With no GROUP BY, there is exactly one group (key = unit), created
  even for empty input so `COUNT` can return 0; the SUM/AVG/MIN/MAX
  empty-group behaviour follows D-09.
- Output: one tuple per group: grouping columns + aggregate results,
  then the folded projection. Group output order is unspecified
  (hash order); ORDER BY on top imposes order when requested.

## 8.7 Sort

- Materialise the full input, then a **stable** sort by the sort keys
  (`Data.List.sortBy` on the materialised list satisfies stability).
- Key comparison uses 05 §5.4 semantics per key type and direction.
- Memory discipline: the materialised input is charged to the
  statement memory budget (D-08). Exceeding it aborts the statement
  with `54000 sort memory limit exceeded`. There is deliberately **no**
  external sort fallback — this is a specified limitation
  (05 §5.9), not an error in the implementation.

## 8.8 DML operators

### Insert

For each VALUES row: type-check/convert literals against the target
schema (analyzer did static checks; VARCHAR byte-length and INT64
range are re-checked on values), encode the tuple, storage INSERT
(01 §1.5: FSM page choice, WAL, placement), then insert `(key, RID)`
into every index on the table. Exclusive row lock on the new RID.
Returns affected-row count for the command tag.

### Update

1. Run the child scan (with pushed-down WHERE) collecting
   `(RID, oldTuple)` pairs into a list — the scan and the modification
   are separate phases (07 §7.8).
2. For each pair: take exclusive row lock (upgrade), compute the new
   tuple from the SET assignments, encode, check the in-page fit rule
   (01 §1.5): if it does not fit → error, statement rollback undoes
   earlier pairs of this same statement via WAL undo.
3. WAL-log `UPDATE_TUPLE` with before/after images; write in place;
   maintain indexes for changed indexed columns (delete old entry,
   insert new entry, same RID).

### Delete

Same two-phase shape: collect RIDs via the child scan, then per RID:
exclusive lock, WAL `DELETE_TUPLE` with before-image, mark slot
unused, delete all index entries for the RID.

## 8.9 DDL operators

- `CreateTable`: take X lock on the (new) catalog namespace entry,
  allocate relid, insert catalog rows, initialise the heap (no pages
  until first insert), WAL-log `CREATE_TABLE`.
- `CreateIndex`: X lock on the table, bulk-build the B+-tree
  (04 §4.4), insert catalog rows, WAL-log `CREATE_INDEX`.

## 8.10 Result delivery

SELECT results stream to the wire layer row by row (`next` → DataRow)
except when a `Sort` or other materialising operator already holds
them in memory. Command tags (`INSERT 0 n`, `UPDATE n`, `DELETE n`,
`SELECT n`, `CREATE TABLE`, `CREATE INDEX`) are produced by the
session layer from operator-reported counts (09 §9.4).
