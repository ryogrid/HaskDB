# 07. Planner

## 7.1 Pipeline

```
SQL text
  -> Parser        : AST (unresolved names)
  -> Analyzer      : resolved AST (names -> relids/column ordinals,
                     types checked, correlation ban enforced)
  -> Planner       : physical plan tree (executor operators)
  -> Executor      : result rows / command tag
```

The analyzer and planner are separate passes so that name resolution
errors and planning decisions never mix. Subqueries are analyzed and
planned recursively, bottom-up: a subquery is planned as an independent
plan tree (valid because subqueries are uncorrelated).

## 7.2 Plan representation

A plan is a tree of the executor operators defined in 08-executor.md:

```haskell
data Plan
  = SeqScan      RelId
  | IndexScan    RelId IndexId ScanPredicate        -- equality or range on indexed col
  | Filter       Predicate Plan
  | Project      [ProjItem] Plan
  | NestedLoop   Plan Plan (Maybe Predicate)         -- residual predicate
  | IndexNestedLoop Plan RelId IndexId JoinKey       -- outer plan, inner index probe
  | HashJoin     Plan Plan JoinKey
  | HashAggregate [ColRef] [AggCall] Plan
  | Sort         [SortKey] Plan
  | MaterializeSubquery Plan                          -- executed once, rows cached
  | Insert       RelId Plan
  | Update       RelId [Assign] Plan
  | Delete       RelId Plan
  | CreateTable  ...
  | CreateIndex  ...
```

Predicates are kept in a normalised internal form: a conjunction of
`Comparison(operand, op, operand)` terms under an AND/OR/NOT tree.
The planner inspects the top-level conjunction of the WHERE clause to
extract join predicates and index predicates; everything else stays as
a residual `Filter`.

## 7.3 Predicate classification

For a query over relations `R1..Rn` with WHERE predicate `P`:

1. **Single-relation predicates**: all column references belong to one
   relation → candidates for pushing into that relation's scan
   (index predicate if it is a comparison on an indexed column with a
   literal or a value from an uncorrelated subquery/outer plan column —
   for scans, only literal/subquery values; outer-column values arise
   in joins, handled by IndexNestedLoop).
2. **Equijoin predicates**: `Ri.a = Rj.b` with `i /= j` → join
   conditions.
3. **Residual predicates**: everything else (non-equi cross-relation
   comparisons, OR-ed terms, NOT-ed terms, EXISTS/IN — IN and EXISTS
   are planned as their own subquery plans, evaluated per §7.6) →
   `Filter` above the join tree.

Decomposition rule *(supplementary specification)*: only top-level
conjuncts (AND-ed at the root of the predicate tree) are classified
into (1)/(2); anything under OR/NOT is residual as a whole. This keeps
predicate handling simple and predictable.

## 7.4 Join ordering and algorithm selection

### Inputs available to the planner (and only these)

- `reltuples` per relation (06 §6.4),
- the set of indexes per relation (columns indexed),
- the fixed cost constants of §7.5.

There is **no** selectivity estimation, no histograms, no distinct
counts. The planner must not pretend to have them.

### Algorithm choice per join (pairwise, in FROM order)

Joins are built **left-deep, in the order relations appear in FROM**
*(supplementary specification: join-order optimisation by cardinality
is deliberately not attempted, since without selectivity estimates it
would be guesswork; FROM order is the user's explicit hint)*. For each
new relation `R` joined to the accumulated tree `T` with equijoin
predicate `T.a = R.b` (if any):

1. If an equijoin predicate exists **and** `R` has an index on `R.b`
   → **Index Nested Loop Join** (probe `R`'s index per outer row).
   Exception: if `T`'s estimated rows are 0 (a relation with
   `reltuples = 0`), the choice is still INLJ — cost is 0 probes.
2. Else if an equijoin predicate exists **and**
   `rows(T) * rows(R)` exceeds the NLJ threshold constant (§7.5)
   → **Hash Join** (build side = the smaller of `T`, `R` by
   `reltuples`).
3. Else if an equijoin predicate exists → **Nested Loop Join** with
   the equijoin predicate evaluated per pair.
4. If no equijoin predicate connects `R` → **Nested Loop Join**
   (cross product filtered by residual predicates). This is legal SQL
   in this dialect (comma-separated FROM) and must not be an error.

If several equijoin predicates connect `R`, the first (in WHERE text
order) drives the algorithm choice; the rest become residual
predicates of the join node.

### Scan choice per relation

- If the relation has a single-relation predicate that is an equality
  or range comparison on an indexed column → `IndexScan` for that
  predicate, with the remaining single-relation predicates as a
  `Filter` above it.
- Otherwise → `SeqScan` (+ `Filter` if predicates exist).

## 7.5 Fixed cost model

The planner computes a scalar cost per candidate plan only where a
choice exists (scan choice above is rule-based; the NLJ-vs-Hash
threshold is the one numeric comparison). Constants (unitless,
PostgreSQL-flavoured but fixed at compile time — not user-tunable in
the baseline):

| Constant | Value | Meaning |
|----------|-------|---------|
| `SEQ_PAGE_COST` | 1.0 | reading one page sequentially |
| `RANDOM_PAGE_COST` | 4.0 | one random page access (index descent step) |
| `CPU_TUPLE_COST` | 0.01 | processing one tuple |
| `CPU_OPERATOR_COST` | 0.0025 | one predicate/hash evaluation |
| `NLJ_HASH_THRESHOLD` | 10,000 (rows product) | above this, prefer Hash Join when no index applies |

Formulas used:

- `cost(SeqScan R) = pages(R) * SEQ_PAGE_COST + rows(R) * CPU_TUPLE_COST`
  where `pages(R)` is the catalog page-list length.
- `cost(IndexScan) = depth(index) * RANDOM_PAGE_COST + matchedRows * (RANDOM_PAGE_COST + CPU_TUPLE_COST)`,
  with `matchedRows` estimated as `rows(R) / 10` for equality and
  `rows(R) / 3` for range scans — **fixed fractions**, not statistics
  *(supplementary specification: some constant is needed for logging
  and EXPLAIN-like debugging; these fractions never change rule order,
  because scan choice is rule-based per §7.4)*.
- `cost(NLJ) = cost(T) + rows(T) * costPerProbe(R)`;
  `cost(HashJoin) = cost(T) + cost(R) + (rows(T)+rows(R)) * CPU_OPERATOR_COST`.

Costs are used for plan *annotation* (debugging) and for the single
threshold decision. Whether to expose an `EXPLAIN` command is decision
item **D-19** (not in the baseline SQL grammar).

## 7.6 Subquery planning

- **Scalar / IN subqueries in WHERE**: planned as `MaterializeSubquery`
  nodes evaluated **once per statement** (they are uncorrelated, so
  re-evaluation per row would be pure waste) and replaced in the
  predicate by the resulting literal (scalar) or literal set (IN).
  If the same subquery text appears twice, it is planned twice —
  no common-subexpression elimination *(simplification)*.
- **EXISTS**: evaluated once per statement to a boolean literal, for
  the same reason.
- **Derived tables**: planned as a sub-plan whose output feeds the
  outer scan; the executor materialises derived-table results once
  (08 §8.4) since the volcano model would otherwise re-run the
  sub-plan per outer row in joins.

Wait — derived tables joined against other relations: materialisation
is required for Hash Join build sides anyway; for NLJ outer/inner use,
materialising once and scanning the materialised rows is always at
least as good. **All derived tables are materialised once per
statement.**

## 7.7 Aggregate and sort planning

- Aggregate query: plan the input (scans/joins/filters), then
  `HashAggregate` grouped by the GROUP BY columns (or a single global
  group). Hash aggregation is the only aggregation strategy in the
  baseline (sort-based aggregation is decision D-20's neighbour —
  recorded under D-20 as future work, not baseline).
- ORDER BY: append a `Sort` node on top of the (projected) result.
  Sort keys resolve to output columns per 05 §5.5. No attempt is made
  to exploit index order to avoid sorting (indexes do not provide
  ordering guarantees in this planner — deliberate simplification).
- Projection is planned as a `Project` node directly above the node
  that produces the needed columns; for aggregate queries the
  projection is folded into the aggregate node's output.

## 7.8 DML planning

- `INSERT`: the VALUES rows become a constant plan; `Insert` operator
  performs per-row storage work and index maintenance.
- `UPDATE`/`DELETE`: plan the target relation's scan with the WHERE
  predicate pushed as for SELECT (index scans allowed), then the
  `Update`/`Delete` operator consumes RIDs + (for UPDATE) the old
  tuple images. Two-phase within the operator (collect target RIDs
  first, then modify) so that updating rows cannot make the scan
  revisit or skip rows *(supplementary specification)*.
