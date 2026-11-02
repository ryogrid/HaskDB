# 08. Planner Internals

Refines `design/07-planner.md`.

## 8.1 Plan type (`Executor.Types` — defined there, produced here)

The physical plan type lives in `Executor.Types` (document 09 §9.1)
because the executor pattern-matches on it; the planner is its only
producer. The planner works on `Analyzed` + a snapshot of catalog
descriptors:

```haskell
-- Planner.Planner
data PlanEnv = PlanEnv
  { peTables  :: Map RelId RelationDesc
  , peIndexes :: Map RelId [IndexDesc]     -- keyed by owning table relid
  }

planStatement :: CatalogCache -> Analyzed -> IO Plan
```

## 8.2 Predicate normalisation

The planner flattens the top level of the resolved predicate:

```haskell
conjuncts :: RPred -> [RPred]     -- split RPAnd recursively; leaves are
                                  -- non-AND predicates
classify  :: [FromSlot] -> RPred -> ClassifiedPred

data ClassifiedPred
  = CmpSingle  Int RPred          -- references exactly one FROM slot
  | CmpEquiJoin (Int, Int) (Int, Int) RPred
      -- (slotA, colA) (slotB, colB): an equality RPCmp between two
      -- columns of different slots; keeps the original RPred for
      -- residual evaluation
  | CmpOther   RPred              -- everything else (residual)
```

Classification inspects `RPCmp (ROCol a) OpEq (ROCol b)` (either
operand order) for equijoins; `RPCmp` with one side `ROCol` of a
single slot and the other side a literal or an already-materialisable
subquery operand for single-slot predicates; `RPIn`/`RPExists`/
`ROScalar` are *not* classified here — they are rewritten first (§8.5).

Comparison ops other than `=` between two slots' columns are
`CmpOther` (residual). OR/NOT subtrees are `CmpOther` as a whole
(they are leaves after flattening).

## 8.3 Scan planning per slot

```haskell
planSlotScan :: PlanEnv -> Int -> FromSlot -> [RPred] -> (Plan, [RPred])
  -- input: the slot and its CmpSingle predicates
  -- output: scan plan + predicates not consumed by the scan
```

Rules (design/07 §7.4):

1. Collect candidate index predicates: `CmpSingle` predicates of the
   form `col op value` or `value op col` where `col` is the indexed
   column of some index on the table, `op ∈ {=, <, <=, >, >=}`, and
   `value` is `ROLit` (subquery operands were rewritten to literals in
   §8.5 before this step).
2. If any equality candidate exists → `IndexScan` with the first (in
   WHERE order) equality predicate; all other predicates become a
   `Filter` above.
3. Else if a range candidate exists → `IndexScan` combining at most
   two bounds on the same index (one lower, one upper, first of each).
   Remaining predicates → `Filter`.
4. Else → `SeqScan` (+ `Filter` with all predicates).
5. Derived-table slots: the scan is `Materialize` of the subplan
   (§8.5); single-slot predicates become a `Filter` above it.

IndexScan plan node (document 09 §9.1):

```haskell
IndexScan RelId IndexDesc IndexBound
data IndexBound = IBEqual Value | IBRange (Maybe (Value, Bool)) (Maybe (Value, Bool))
-- (bound value, inclusive?)
```

## 8.4 Join tree construction

```
planJoins slots scans equijoins residuals:
  tree := scan of slot 0;  joinedSlots := {0}
  for slot i in 1..n-1 (FROM order):
     eq := first equijoin predicate connecting slot i to any slot in joinedSlots
     case eq of
       Just (outerCol, innerCol) ->
          if slot i is a base table with an index on innerCol:
              tree := IndexNestedLoop tree table_i index (outerCol -> key)
                      residual := other equijoins to i ++ residuals
          else if estRows(tree) * rows(slot i) > nljHashThreshold
                  && slot i is a base table or materialised subquery:
              tree := HashJoin (build = smaller side) tree scan_i eq
          else:
              tree := NestedLoop tree scan_i (Just eqPred)
       Nothing ->
          tree := NestedLoop tree scan_i Nothing   -- cross product
     joinedSlots += {i}
  if residuals non-empty: tree := Filter (andAll residuals) tree
```

- `estRows(plan)`: the planner annotates every plan node with an
  estimated row count as it builds: scans use `rdTuples` (or the
  subquery's estimate), filters multiply by the fixed fractions of
  design/07 §7.5 (equality 1/10, range 1/3, other 1/3 — annotations
  only, except the single NLJ/Hash threshold comparison), joins
  multiply operand estimates for cross products and use
  `max(rowsA, rowsB)` for equijoins *(fixed rule, supplementary)*.
- The build/probe choice for HashJoin: build = the side with the
  smaller estimate; if the build side is the accumulated tree, it is
  wrapped in `Materialize` (hash build consumes it fully anyway, so
  this costs nothing extra).
- An `IndexNestedLoop`'s inner side is not a plan subtree but the
  triple `(RelId, IndexDesc, keySource :: RColRef)` where keySource
  refers to a column of the accumulated outer tuple (whose layout is
  the concatenation of slots `0..i-1` outputs — offsets computed by
  the planner and stored in the node).

Tuple layout convention (used by planner and executor alike): the
output tuple of a join tree over slots `0..k` is the concatenation of
the slots' output tuples, in slot order. `RColRef (slot, col)` maps
to the flat index `sum of widths of slots < slot + col`. The planner
precomputes these flat indexes into the plan (`FlatRef = Int`), so
the executor never does scope arithmetic.

## 8.5 Subquery rewriting (before classification)

```
rewritePred :: RPred -> Planner (RPred, [Plan])
  -- Returns a predicate where every RPExists/RPIn/ROScalar has been
  -- replaced, plus the list of materialisation plans to execute first.
```

- `RPExists sub` → plan `sub`; at execution, evaluate to a boolean;
  replace with `RPCmp (ROLit (VBool True)) OpEq (ROLit result)` — or,
  cleaner: the executor's statement preamble (§9.2 of document 09)
  evaluates materialised subqueries into a `SubqueryResults` map keyed
  by a `SubqueryId` assigned here in the planner; the predicate node
  becomes `RPExistsRef SubqueryId`. To keep `RPred` shared between
  analyzer and planner, the planner produces a *separate* physical
  predicate type:

```haskell
-- Executor.Types
data PPred
  = PPAnd PPred PPred | PPOr PPred PPred | PPNot PPred
  | PPCmp POperand CmpOp POperand
  deriving (Show)
data POperand = POCol FlatRef | POLit Value | POScalar SubqueryId
              | POInList SubqueryId   -- used by a dedicated node below
data SubqueryId = SubqueryId Int
```

`IN` becomes a dedicated physical predicate:

```haskell
  | PPIn FlatRef Bool SubqueryId    -- col [NOT] IN (materialised set)
```

This keeps evaluation pure and fast: all subqueries run exactly once
in the preamble, before the main plan opens.

- Derived tables (`FromSlot.fsSubplan`): planned recursively to a
  `Plan`, wrapped in `Materialize`, and treated as a scan whose
  "relid" is a synthetic slot id.

## 8.6 Aggregate, projection, sort planning

- If `rsIsAgg`: plan input (joins+filters), then
  `HashAggregate groupFlatRefs [AggSpec] inputPlan` where
  `data AggSpec = AggSpec { asFn :: AggFn, asArg :: Maybe FlatRef,
  asOutType :: SqlType }`. The aggregate's output layout = group
  columns (in GROUP BY order) ++ aggregate results (in select order).
  The final select-list order is produced by a `Project` above the
  aggregate that picks/reorders — always present for aggregate
  queries (even if identity) to keep one code path.
- Non-aggregate queries: `Project` directly above the join tree with
  items `(FlatRef | Literal)`.
- `SelStar`: expanded by the *analyzer* into explicit column items
  (in FROM slot order), so the planner never sees it.
- ORDER BY (already resolved to output indexes by the analyzer):
  append `Sort [(outIndex, asc)]` above the projection.

## 8.7 DML planning

- INSERT: `InsertPlan relid descriptors rows` — no child plan.
- UPDATE: child = planSlotScan + filters for the target table with
  the WHERE conjuncts (single-slot classification only);
  `UpdatePlan relid childPlan [(colOrdinal, PAssignRhs)]` where
  `PAssignRhs = PALit Value | PACol FlatRef`.
- DELETE: `DeletePlan relid childPlan`.
- CREATE TABLE/INDEX: direct plan nodes carrying the analyzed
  statement; execution in document 09 §9.7.

## 8.8 Cost annotations

Every plan node carries `planCost :: Double` and `planRows :: Int64`
in a wrapper:

```haskell
data Plan = Plan { planNode :: PlanNode, planCost :: Double,
                   planRows :: Int64 }
```

Costs are computed bottom-up with the constants and formulas of
design/07 §7.5 (`Planner.CostModel` is a pure module of the five
constants and three formulas). They influence only the NLJ/Hash
threshold; they exist in the tree for debuggability.
