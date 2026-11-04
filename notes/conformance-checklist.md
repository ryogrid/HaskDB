# Conformance checklist — design/00 §0.3 vs the test corpus (Phase 8, T41)

design/10 §10.2 Phase 8 asks for "a conformance checklist run against 00 §0.3:
every 'supported' item demonstrated by a test; every 'not supported' item
demonstrated to error cleanly".  This file is that checklist: one row per §0.3
bullet, and the test that shows it.  Item text is quoted from
`design/00-overview.md` §0.3 (the authority for the scope); the test names are
the check labels inside each suite, so a reviewer can grep them.

Running everything: `cabal test all` (9 suites) plus the three smoke scripts.
All of them run through `scripts/haskdb-test-run.sh` (AGENT.md rule R-RES).

## 1. "Supported"

| §0.3 item | Demonstrated by |
|-----------|---------------|
| "One single database that exists from the start (no CREATE DATABASE)" | `test/IndexSpec.hs` bootstrap (createDatabase → page-0 file header + self-describing catalog heaps, reopen via `recoverDatabase`); `test/CrashSpec.hs` E0 (`checkPage0` accepts a bootstrapped page 0). The *absence* of CREATE DATABASE is a rejection: `test/SqlSpec.hs` F1 "no CREATE DATABASE" → 42601 |
| "Multiple tables in that database" | `test/ExecSpec.hs` fixture keeps `person`/`city`/`bigt` live at once; `test/IndexSpec.hs` creates several relations + indexes through real transactions; `scripts/psql-smoke.sh` creates `t`, `pair_t`, `u` in one database |
| "DML: SELECT, INSERT, UPDATE, DELETE" | `test/ExecSpec.hs` (all four, incl. `update count`/`delete count` tags and the two-phase DML rule), `test/SessionSpec.hs` (`INSERT 0 1` over the wire), `test/TxnSpec.hs` (concurrent INSERT/UPDATE/DELETE/SELECT sessions), `scripts/psql-smoke.sh` |
| "DDL: CREATE TABLE, CREATE INDEX only" | `test/IndexSpec.hs` (CREATE TABLE/CREATE INDEX staged in the catalog cache, landed only at commit; CREATE INDEX bulk-builds the B+-tree), `test/SqlSpec.hs` P-grammar rows for both productions; every other DDL is rejected, see §2 row "ALTER TABLE / DROP TABLE / DROP INDEX" |
| "Aggregates: COUNT, SUM, AVG, MIN, MAX, with GROUP BY" | `test/ExecSpec.hs` checks `agg count`, `agg sum`, `agg avg`, `agg min/max`, `group by counts`, `group src order`; the D-09 empty-global-group rule is `agg count empty` (COUNT → 0) vs `agg sum empty is 21000` |
| "ORDER BY (in-memory sort only; no external sort, no LIMIT)" | `test/ExecSpec.hs` `order by asc stable`, `order by desc stable`; the in-memory-only limit is `memory budget sort` → 54000; `test/SqlSpec.hs` F1 "LIMIT"/"LIMIT after WHERE" reject `LIMIT` |
| "Joins: inner equijoins derived from WHERE predicates over multiple relations in FROM. Nested Loop Join, Index Nested Loop Join and Hash Join are implemented" | `test/ExecSpec.hs` plan rows `plan INLJ`, `plan NLJ`, `plan HashJoin` (the §8.4 planner picks each) plus the same join forced as three hand-built plans whose outputs must be identical (`forced plans agree`, `forced NLJ/HashJoin/IndexNestedLoop rows`); `hashjoin catalog-rows threshold` shows the §7.5 row-product threshold is a fixed cost constant, not statistics |
| "Subqueries: derived tables in FROM; uncorrelated subqueries in WHERE (EXISTS, IN, scalar). Correlated subqueries are not supported" | `test/ExecSpec.hs` `subquery IN`, `subquery NOT IN`, `subquery EXISTS`, `subquery NOT EXISTS`, `scalar subquery`, `scalar subquery >1 row` → 21000, `derived table`, `plan derived materialises`; the ban is `test/SqlSpec.hs` (correlated subquery → 0A000) |
| "Types: INT64, FLOAT64, VARCHAR (UTF-8, max 1024 bytes), BOOLEAN" | `test/SqlSpec.hs` P7 "type aliases" (`int64 bigint int8 float64 "double precision" varchar bool boolean` all map to the four §5.3 types), `L5 float forms`, the VARCHAR 1024-byte rule → 22001 in the analyzer and in `test/ExecSpec.hs` `varchar too long`; the text wire form round-trips rows in `scripts/psql-smoke.sh` + `scripts/pgbench-smoke.sh` |
| "Concurrent transactions from multiple client connections (threads) inside one process" | `test/TxnSpec.hs` four sessions in four forks doing INSERT/UPDATE/DELETE/SELECT at once, final multiset == the union of the committed sessions (no lost update despite steal + no-force); `test/SessionSpec.hs` drives several scripted sessions over the same Env; `scripts/psql-smoke.sh` runs two real `psql` sessions with conflicting blocks → one gets the 40P01 deadlock abort |
| "Durability: a committed transaction survives a process crash" | `scripts/crash-smoke.sh` C1 (SIGKILL after the commit response, the row + its index entry survive), C2 (SIGKILL with an OPEN BEGIN block → nothing survives), C3 (SIGKILL landing inside the reopen's WAL replay — the replay-start log marker, an observability line per internal/11 §11.7, is in its log while `listening` is not — and the half-recovered disk reopens to the SAME 5003-row state), C4 (SIGKILL after a CREATE response: the table MUST be back, and losing it is now a FAIL rather than an accepted outcome); `test/CrashSpec.hs` A/B/C/D; `test/WalSpec.hs` crash simulation; `test/TxnSpec.hs` `recovery: reopen sees same committed state` |

## 2. "Explicitly not supported" — each must error cleanly

| §0.3 item | Rejecting test → SQLSTATE |
|---------|--------------------------|
| NULL values / NULL literals / `IS NULL` / `IS NOT NULL` / three-valued logic | `test/SqlSpec.hs` F1 "IS NULL", F1 "bare NULL operand", P6 "VALUES rejects a NULL literal" → 0A000 |
| `ALTER TABLE`, `DROP TABLE`, `DROP INDEX`, all other DDL | F1 "ALTER", F1 "DROP", F1 "DROP INDEX" → 0A000 |
| `HAVING`, `LIMIT` | F1 "HAVING", F1 "LIMIT", F1 "LIMIT after WHERE" → 0A000 (also OFFSET, DISTINCT) |
| Explicit `JOIN ... ON`, outer joins, `CROSS JOIN` | F1 "JOIN", F1 "cross join", F1 "LEFT ... ON" → 0A000 |
| Arithmetic expressions in the SELECT list (and everywhere else: §5.3 says "no arithmetic anywhere in the grammar") | F1 "arithmetic in the select list" / "in WHERE" / "in UPDATE SET" / "in INSERT VALUES" / "in GROUP BY" / "in ORDER BY" → 42601 (added in this pass; arithmetic is simply not in the grammar, so the rejection is a syntax error, not a 0A000 feature error) |
| Overflow storage (TOAST-like); a tuple must fit in one page | `test/ExecSpec.hs` `update tuple too large` → 54000 and `heap unchanged after rollback` (a mid-UPDATE failure leaves the heap alone) |
| User management, authentication, privileges (all clients are one user) | `test/SessionSpec.hs` startup handshake: psql's real startup parameters are ignored, the SSL/SASL probes answer a bare `N` (D-23: no TLS), and no connection ever authenticates — one user for every socket |
| External sort | `test/ExecSpec.hs` `memory budget sort` → 54000 (the sort is in-memory and bounded; there is no spill-over path to try) |
| Selectivity-/statistics-based cost optimisation (row counts + index existence + a fixed cost model only) | `test/ExecSpec.hs` plan dumps (`plan INLJ`/`plan NLJ`/`plan HashJoin` chosen from `rdTuples` + index presence) and `hashjoin catalog-rows threshold` (the chosen plan flips at a fixed row-product constant) |
| Multiple databases; multiple processes opening the same files | `scripts/crash-smoke.sh` C9: a second `haskdb-server` on the same directory is refused — `another HaskDB process is using this directory` (design/00 §0.6's flock guard); one Config = one database directory, there is no second database to open |

## 3. Gaps found while writing this checklist (closed in this pass)

While mapping §0.3 row by row, four §0.3 bullets had **no test at all** and one
had only an indirect test.  They were closed before the checklist was written
down, so the table above has no "—" entries:

| Gap | Closure |
|-----|---------|
| `DROP INDEX` (the §0.3 bullet names it; only `drop table` was tested) | `test/SqlSpec.hs` F1 "DROP INDEX" |
| arithmetic rejected in each clause §5.4 lists as illegal (SELECT list, WHERE, UPDATE SET, INSERT VALUES, GROUP BY, ORDER BY) | six new SqlSpec F1 rows; observed codes: 42601 everywhere (the lexer stops at `+` before the parser can name the construct) — recorded as a deviation from the §7.3 "specific feature error" nicety, which the docs only promise for the blocklisted keywords `JOIN/HAVING/LIMIT/NULL/IS/ALTER/DROP` |
| "no CREATE DATABASE" | SqlSpec F1 "no CREATE DATABASE" → 42601 (`create` is reserved and must be followed by `table`/`index`) |
| "multiple processes on the same files" (only reasoned about, never run) | `scripts/crash-smoke.sh` C9 runs a real second server on the same directory and checks the §11.2 flock refusal |
| internal/11 §11.2's `incomplete database directory` refusal (a data/WAL without a control file must never be guessed) was asserted nowhere in the matrix — the C4 branch that used to accept a refused reopen was its only, and dead, mention | `scripts/crash-smoke.sh` C10 deletes the control file of a healthy database and asserts the refusal; C4 no longer treats that refusal as an acceptable outcome, because a bootstrap that printed `listening` had already written the control file |

## 3b. Engine bugs the crash matrix exposed

The durability row of §1 is not just a test — running C1–C3 against the real
server found engine bugs that no unit suite had covered (which is why §0.3's
durability bullet needs a server-level harness at all). Each is recorded with
the symptom, the first (rejected) fix and the fix that shipped:

| Bug | Symptom | Fix that shipped |
|-----|---------|------------------|
| `Heap.Heap.heapAllocPage` chained a new heap page from the caller's stale `rdPages` snapshot, so one statement allocating several pages (a COPY/INSERT past ~340 rows at pageSize 8192) rewrote a committed predecessor's `phNext` from an OLDER page and a whole page of committed tuples left design/01 §1.5's chain | live count 980/1000 (rows 341–680 gone, 681–1000 listed twice), reopened 660 | the predecessor is the **descriptor's** last page, and the tail is threaded to the caller: `Heap.heapInsertDesc` returns the grown descriptor (internal/06 §6.3's "heapInsert returns the updated descriptor to its caller" rule) and `Executor.Operators.targetOf`/`runInsert` keep it alive across the CopyData chunks of one COPY statement through the statement-scoped `ecTargets` cell |
| A first attempt made `Heap` walk the `phNext` chain itself (`lastHeapPage`) to find that predecessor | live/reopened counts agreed, but `IndexSpec`'s ground-truth check broke: the walk lets ONE statement extend the chain ahead of the relation's page LIST, which is frozen until COMMIT, so pages the chain gained never appear in any committed `relpages` list — the live view and the reopened view of the relation disagree, a design/00 §0.7 violation (and one walk pins a frame per relation page per allocation, reshuffling CLOCK eviction/flush order) | rejected: the walk was removed from `Heap`; only the threading shipped (recorded in TODO.md's Phase-8 deviations) |
| `Catalog.Cache.stageAllocPage` appended unconditionally while the catalog cache is frozen until COMMIT (internal/06 §6.3: `stageAppend` only RECORDS the closure), so each COPY chunk re-staged the same pages and `rdPages` gained duplicate entries | live counts 1660 / 6400 / 29600 for 1000 / 2000 / 5000 rows | `stageAllocPage` is idempotent (an `pg elem rdPages` guard inside the `atomically` block) — safe exactly because staged closures run only at COMMIT and aborts discard them |
| The catalog-heap (DDL) path inserted `hask_class` / `hask_attribute` rows through the non-threaded `heapInsert` with a frozen descriptor, so a DDL storm past one catalog heap page had the same chain-skipping and never booked the new catalog page in the reopened page list | latent: needs ~160 CREATE TABLE/INDEX calls to allocate a second class page, so no suite reached it | `Bootstrap.insertCatalogTuple`/`insertCatalogTuples` now follow the same contract (`heapInsertDesc` + `stageAllocPage` for the new catalog page) |

After these fixes the repro's live and reopened counts agree exactly
(1000 / 3000 / 8000 / 8003 rows), and C3 of `scripts/crash-smoke.sh` shows a
5003-row COPY-era state surviving a kill -9 that lands inside a reopen's WAL
replay and reaching the same count again.

## 4. Where §0.3 and the implementation notes disagree

Not scope items, so not rows above, but the same §0.3 reading touches them:

- §0.3 says "Concurrent transactions from multiple client connections"; the
  wire layer only implements the simple query protocol subset (D-05), so
  "multiple connections" is exercised over real sockets in
  `scripts/psql-smoke.sh` and over a scripted `Connection` in
  `test/SessionSpec.hs` (internal/11 §11.3 explicitly allows the latter).
- §0.3's durability bullet defers to §0.7 for the definition of "committed";
  the tests therefore key on the WAL commit record + fsync, which is what
  `scripts/crash-smoke.sh` C1–C3 and `test/CrashSpec.hs` A–D use.
- §0.2's "GHC boot libraries only (see D-06)" is amended by D-24: `network` is
  uninstallable in this toolchain, so the socket layer is a libc shim
  (`c/hs-socket.c` via GHC FFI) — still boot-libs-only Haskell.
