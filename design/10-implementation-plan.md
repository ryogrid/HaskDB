# 10. Implementation Plan

## 10.1 Principles

- **Dependency order first**: phases are ordered so that every phase
  only uses components finished in earlier phases. Within a phase,
  modules are listed in implementation order.
- Each phase ends with a **verifiable milestone**: a test suite or a
  runnable demo that proves the phase works before the next phase
  builds on it.
- **No phase implements features beyond the requirements.** Where a
  decision item (11-open-decisions.md) gates a phase, the phase notes
  the dependency; work that does not depend on the decision proceeds.
- Suggested build setup: a single Cabal package `haskdb` with library +
  `haskdb-server` executable + test suites. Cabal vs Stack is D-13.

Module map (Haskell):

```
src/
  HaskDB/
    Common/        -- Value, types, errors, byte codecs
    Storage/       -- Page, FileManager, BufferPool, FreeSpaceMap
    Wal/           -- WalFormat, WalManager, Recovery
    Txn/           -- TxnManager, LockManager
    Heap/          -- Heap (insert/update/delete/scan), TupleCodec
    Index/         -- BTree
    Catalog/       -- Catalog, CatalogCache
    Sql/           -- Lexer, Parser, Ast, Analyzer
    Planner/       -- Planner, CostModel
    Executor/      -- Operators, Eval, MemoryBudget
    Server/        -- WireProtocol, Session, Listener
app/
  Main.hs          -- server entry point
test/
  ...              -- per-phase suites (see 10.4)
```

## 10.2 Phases

### Phase 0 — Project skeleton and common utilities

- Cabal package, CI-less local build on Ubuntu/x86-64, GHC version
  pinned by D-13.
- `Common`: `Value` type, little-endian codecs, `SqlError` type, CRC32.
- **Milestone**: `cabal build` clean; codec round-trip tests pass.

### Phase 1 — Storage foundation (design 01, 02 §2.1)

- File manager (page read/write by `PageId`), page format
  encode/decode, slotted-page operations (insert tuple into page,
  delete, compact), tuple codec.
- Buffer pool with CLOCK replacement, pin/unpin, page content locks.
  WAL rule enforced structurally (flush callback injected; a stub that
  always reports "flushed" is used until Phase 2 — replaced, not
  bypassed, in Phase 2).
- Free-space map (rebuildable, in-memory).
- **Milestone**: property tests — random insert/delete/update sequences
  against an in-memory model of a page set; reopen-file persistence
  test.

### Phase 2 — WAL and recovery (design 02)

- WAL record codec, WAL manager (append/flush with `fdatasync`),
  commit flush protocol, checkpoint (timer/size triggers per D-11),
  control file (atomic replace).
- Recovery: analysis/redo/undo as in 02 §2.6; `prevTxnLSN` chaining.
- Buffer-pool stub from Phase 1 replaced by the real WAL flush.
- **Milestone**: crash tests — a harness that runs random transactional
  workloads, kills the process (`kill -9`) at random points, restarts,
  and verifies committed-prefix consistency and absence of uncommitted
  data.

*Depends on*: D-01 (page size — needed already in Phase 1 for the file
format; a provisional compile-time constant is acceptable until D-01 is
decided, since it is stored in the control file and checked, not baked
into record formats).

### Phase 3 — Transactions and locking (design 03)

- Transaction manager (begin/commit/abort, in-memory undo lists),
  lock manager (STM-based, IS/IX/S/X + row S/X, FIFO fairness),
  deadlock policy module (per D-12).
- Heap operations become transactional (WAL-logged, lock-taking).
- **Milestone**: concurrency stress test — N threads running random
  transfers between rows; final state equals a serial execution;
  deadlock-injection test terminates with a victim error, not a hang.

*Depends on*: D-02 (concurrency scheme) and D-12 (deadlock policy).
The lock-manager interface of 03 §3.4 is implemented first so executor
work can proceed against it even while D-02 is open; if D-02 chooses
MVCC, this phase is the one that changes most.

### Phase 4 — Catalog and DDL storage side (design 06)

- Bootstrap (page 0, catalog heaps), catalog cache with version-based
  invalidation, `CREATE TABLE` catalog writes (SQL parsing not yet
  needed: drive DDL from internal calls in tests).
- B+-tree index (design 04): search/insert/delete, splits, bulk build,
  leaf-chain range scans.
- **Milestone**: index property tests (random operations vs. `Data.Map`
  model, including after simulated crash/recovery); catalog restart
  test.

### Phase 5 — SQL front end (design 05)

- Lexer, recursive-descent parser for the §5.2 grammar (hand-written;
  no parser library beyond boot libraries), AST.
- Analyzer: name resolution against the catalog cache, type checking,
  per-clause expression rules (§5.5), correlation ban, aggregate rules.
- **Milestone**: parser/analyzer test corpus — every grammar production
  has positive tests; every "not supported" item of 00 §0.3 has a
  negative test asserting the specific error.

### Phase 6 — Planner and executor (design 07, 08)

- Planner: predicate classification, rule-based scan/join choice,
  fixed cost model, subquery materialisation planning.
- Executor operators: SeqScan, IndexScan, Filter, Project,
  NestedLoop/IndexNestedLoop/Hash joins, HashAggregate, Sort,
  Materialize, Insert/Update/Delete, DDL operators.
- Statement memory budget enforcement (D-08).
- **Milestone**: end-to-end SQL tests through an in-process session
  (no sockets): a scripted suite covering DML, joins (all three
  algorithms forced and verified via plan inspection hooks), GROUP BY,
  ORDER BY, subqueries (EXISTS/IN/scalar/derived), error cases from
  05 (tuple-too-large, VARCHAR-too-long, scalar subquery cardinality).

### Phase 7 — Wire protocol and server (design 09)

- Listener + session threads, startup handshake, simple query
  protocol, error mapping, transaction-block state machine.
- **Milestone**: `psql` smoke test script — connect, create table and
  index, insert/select/update/delete, explicit transaction with
  rollback, two concurrent `psql` sessions running conflicting updates
  (one must block or fail per D-12), restart server and verify data.

*Depends on*: D-05 (extended protocol in/out of this phase), D-06
(socket library), D-17 (transaction statement surface — assumed
PostgreSQL-like per 09 §9.5).

### Phase 8 — Hardening and conformance pass

- Full crash-test matrix (kill -9 during each phase's operations,
  including during checkpoint and during recovery itself).
- Reopen/compatibility checks: control-file version checks, wrong
  `PAGE_SIZE` rejection.
- A conformance checklist run against 00 §0.3: every "supported" item
  demonstrated by a test; every "not supported" item demonstrated to
  error cleanly.
- Documentation pass: README for running the server; comments in code
  aligned with these design documents.
- **Milestone**: all suites green on a clean Ubuntu x86-64 machine from
  a fresh clone with only GHC + boot libraries installed.

## 10.3 Dependency graph (summary)

```
Phase 0 -> Phase 1 -> Phase 2 -> Phase 3 -> Phase 4 -> Phase 5 -> Phase 6 -> Phase 7 -> Phase 8
                              \-> (D-02, D-12 gate Phase 3 details)
Phase 4 (index) can overlap Phase 3's later half.
D-01 gates the file format from Phase 1 (provisional constant allowed).
D-05/D-06/D-17 gate only Phase 7 scope details.
D-08 gates Phase 6 memory-budget constants only.
D-09 gates Phase 6 aggregate finalisation details only.
```

No phase requires a decision to *start*; the gates above mark where a
late decision would cause rework, so they should be resolved before
the gated phase begins.

## 10.4 Test strategy (cross-phase)

- **Unit/property tests** with boot-library-only tooling where
  feasible; if a test framework beyond boot libraries is wanted, that
  is part of D-13. Property tests use hand-rolled generators if no
  framework is adopted.
- **Model-based tests**: heap vs. list model; B+-tree vs. `Data.Map`;
  executor results vs. naive in-memory evaluation of the same queries
  on small random databases.
- **Crash tests**: external harness (shell + server binary), `kill -9`
  at randomised points, post-recovery assertions. These are
  first-class deliverables of Phases 2 and 8, not afterthoughts.
- **Protocol tests**: byte-level tests for the startup and simple-query
  flows, plus the `psql` smoke script of Phase 7.
- No performance benchmarks are deliverables (performance is a
  non-goal beyond the classical algorithms themselves); a simple
  "does it finish" sanity workload is enough.
