# 11. Open Decisions (Decisions Required)

The requirements fixed the scope listed in 00-overview.md §0.3. The
items below were **not** specified. They are intentionally left
undecided here: each entry gives the question, the candidate options,
and their pros and cons, so the decision-maker can choose. Where the
design documents needed a working assumption to remain coherent, the
assumption is marked *provisional* and can be changed by deciding the
item; the "affects" line names the documents/phases that would change.

---

## D-01. Page size (`PAGE_SIZE`)

**Question**: What fixed page size does the data file use?

| Option | Pros | Cons |
|--------|------|------|
| 4 KiB | matches common OS/SSD block sizes; less wasted space for small tuples | fewer tuples per page; deeper B+-trees |
| 8 KiB | same as PostgreSQL's default → wire-protocol story and intuition carry over; good fan-out | slightly more I/O per random page touch than 4 KiB |
| 16 KiB | very high B+-tree fan-out; fewer pages to manage | more write amplification; large VARCHAR-heavy tuples still capped by page |

*Affects*: 01 (format constants), 10 Phase 1. The format stores the
value in the control file, so the choice is per-database, not global.
*Provisional assumption in the text*: none (written as `PAGE_SIZE`
throughout).

## D-02. Concurrency control scheme

**Question**: How are concurrent transactions isolated and kept
consistent?

| Option | Pros | Cons |
|--------|------|------|
| **Strict 2PL with row locks** | classical textbook scheme; no tuple versioning needed; recovery design (02) stays simple; strong guarantees | readers block writers and vice versa; deadlock handling required; phantoms possible without range locks |
| MVCC / snapshot isolation | readers never block writers; very PostgreSQL-like | needs tuple versioning (xmin/xmax), visibility checks everywhere, dead-tuple cleanup (vacuum-like machinery) — contradicts the current tuple format and adds the most complexity of any option |
| Single-writer serialisation (one write txn at a time, readers under a shared lock) | drastically simpler; no row locks, no deadlocks | write throughput = 1; long write transactions block all others; "concurrent transactions" supported only in a weak sense |

*Affects*: 01 §1.3 (tuple header), 03 (whole document), 10 Phase 3.
*Provisional assumption in the text*: strict 2PL (03 is written against
it; its §3.4 interface is the stable seam).

## D-03. Default isolation behaviour for reads

**Question** (only if D-02 = locking): do read locks survive to end of
transaction (REPEATABLE-READ-like, the 03 baseline) or are they
released at statement end (READ-COMMITTED-like)?

| Option | Pros | Cons |
|--------|------|------|
| Hold to end of transaction | stronger guarantees; simpler reasoning | more blocking, more deadlock surface |
| Release per statement | less blocking; closer to PostgreSQL's default feel | non-repeatable reads inside a transaction block |

*Affects*: 03 §3.2. No SQL syntax for choosing per-session is proposed
either way (adding `SET TRANSACTION` etc. would be a separate scope
decision).

## D-04. Index scope

**Question**: Is `CREATE INDEX` a single-column B+-tree only?

| Option | Pros | Cons |
|--------|------|------|
| Single-column B+-tree only (baseline) | smallest correct implementation; covers the planner's needs | no composite keys; no uniqueness enforcement |
| + composite (multi-column) keys | more realistic | key encoding/comparison and planner matching get more complex |
| + UNIQUE indexes | enforces a useful integrity rule | requires an error path in DML and a semantics decision for duplicates at build time; the requirements never mention constraints |

*Affects*: 04, 05 §5.10, 06 (catalog columns), 10 Phase 4.

## D-05. Extended query protocol

**Question**: Implement PostgreSQL's extended query protocol
(Parse/Bind/Describe/Execute/Sync) in addition to the simple protocol?

| Option | Pros | Cons |
|--------|------|------|
| Simple protocol only (baseline) | much less protocol machinery; `psql` works fully | drivers that default to prepared statements may fail or need workarounds; no parameter binding (`$1`) at all |
| Simple + extended | real driver compatibility (JDBC, psycopg, etc.); parameterised queries | roughly doubles the protocol surface; portal/statement lifecycle, Describe variants, binary formats negotiation |

*Affects*: 09, 10 Phase 7. Parameter placeholders in SQL text
(`$1`) exist only under the extended option.

## D-06. Socket implementation vs. the standard-library constraint

**Question**: The requirements say "in principle, GHC boot libraries
only", but Haskell's `network` package is **not** a boot library.

| Option | Pros | Cons |
|--------|------|------|
| Use the `network` package | the normal, readable way to write socket code; small, stable API | technically breaks the "boot libraries only" rule |
| FFI to POSIX sockets via `base`/`unix` | keeps the dependency rule absolute | hand-rolled socket code is longer, more error-prone, and obscures the teaching goal |
| Relax the rule to "boot libraries + `network`" | honest middle ground | requires amending the stated constraint |

*Affects*: 09 §9.7, 10 Phase 7. Other boot libraries used
(`bytestring`, `containers`, `stm`, `mtl`, `binary`, `unix`,
`directory`, `filepath`) are unproblematic.

## D-07. Buffer pool size default

**Question**: Default number of buffer frames (and whether it is a
startup flag)?

| Option | Pros | Cons |
|--------|------|------|
| Fixed small default (e.g. 1024 frames) | predictable memory use on any machine | arbitrary; may be small for larger demos |
| Flag with a documented default | flexible | one more configuration surface to document/test |

*Affects*: 02 §2.1. No semantic impact either way.

## D-08. Statement memory budget (sort / materialisation / hash build)

**Question**: 05 §5.9 requires *some* limit (external sort is
forbidden, so unbounded in-memory materialisation cannot be the
answer), but its size and configurability are unspecified.

| Option | Pros | Cons |
|--------|------|------|
| Fixed compile-time limit (e.g. 256 MiB per statement) | zero configuration; uniform failure mode | inflexible for very small/large machines |
| Startup flag / per-database config value | adaptable | configuration plumbing through planner/executor |
| No explicit limit; rely on process memory | simplest code | a single big ORDER BY can OOM the whole server — violates the spirit of the requirement to define the overflow behaviour |

*Affects*: 05 §5.9, 07 §7.6, 08 §8.4/§8.5/§8.7, 10 Phase 6.
*Provisional assumption*: a limit exists and exceeding it is a `54000`
error; only the number/configuration is open.

## D-09. Aggregate edge semantics

**Question**: (a) `SUM`/`AVG`/`MIN`/`MAX` over an empty input (no
GROUP BY, zero rows); (b) `SUM` over INT64 overflow.

| Sub-question | Option A | Option B |
|--------------|----------|----------|
| (a) empty input | **Error** — only semantics consistent with "no NULL" (provisional in 05 §5.8) | `SUM`=0, error for AVG/MIN/MAX — asymmetric but convenient |
| (b) INT64 SUM overflow | **Error** (`22003`) — honest, no silent wraparound | Promote result to FLOAT64 — loses exactness, changes result type dynamically |

*Affects*: 05 §5.7/§5.8, 08 §8.6.

## D-11. Checkpoint policy

**Question**: When are checkpoints taken?

| Option | Pros | Cons |
|--------|------|------|
| Time-based (e.g. every 5 min) + on shutdown | bounded recovery time; simple | may checkpoint needlessly when idle |
| WAL-size-based (e.g. every 64 MiB of WAL) | work-proportional | idle-but-dirty states linger |
| Both | standard practice | two triggers to test |

*Affects*: 02 §2.5. (Numbering skips D-10 intentionally; ids are
stable references, not a sequence.)

## D-12. Deadlock handling

**Question**: Only relevant if D-02 = locking.

| Option | Pros | Cons |
|--------|------|------|
| Wait-for graph detection, abort youngest victim | no spurious aborts; classic algorithm, fits the teaching goal | needs the wait-for graph maintained and a periodic detector |
| Lock-wait timeout (e.g. 10 s) | trivially simple | slow to react; false aborts under legitimate long waits |
| Prevention (wait-die / wound-wait by txn age) | no detection pass; provably deadlock-free | unfair aborts of young/old transactions; restart logic pushed to clients |

*Affects*: 03 §3.5, error codes in 09 §9.6.

## D-13. Build tooling and test framework

**Question**: Cabal or Stack? GHC version? Are non-boot *test-only*
dependencies (e.g. QuickCheck, hspec, tasty) acceptable even if the
runtime rule (D-06) is strict?

| Option | Pros | Cons |
|--------|------|------|
| Cabal + boot-only tests (hand-rolled properties) | zero extra dependencies anywhere | property testing is weaker without QuickCheck |
| Cabal + test-only frameworks allowed | strong property tests for heap/index/recovery | two dependency policies to explain |
| Stack (pinned Stackage snapshot) | reproducible snapshots | heavier; snapshot curation |

*Affects*: 10 Phase 0 and §10.4.

## D-14. Persisted free-space map

**Question**: Persist the FSM, or rebuild at startup (baseline)?

| Option | Pros | Cons |
|--------|------|------|
| Rebuild at startup (baseline) | no extra on-disk format; cannot disagree with page headers after crashes | startup cost linear in page count (header reads only) |
| Persist + rebuild-on-doubt | faster startup for huge files | extra format, extra crash-consistency surface |

*Affects*: 01 §1.7. Baseline recommended; listed for completeness.

## D-15. Group commit

**Question**: Batch concurrent commit fsyncs?

| Option | Pros | Cons |
|--------|------|------|
| No group commit (baseline) | simple, obviously correct | fsync per commit serialises committers |
| Group commit with a short coalescing window | much better concurrent-commit throughput | added latency bookkeeping; subtle flush-order bugs possible |

*Affects*: 02 §2.3/§2.4 (the flush interface already supports it).

## D-16. Binary result format

**Question**: Support binary format codes in RowDescription/DataRow?

Baseline: text only. Binary support mostly matters together with
D-05 (extended protocol). Decide together with D-05.

*Affects*: 09 §9.4.

## D-17. Transaction statement surface

**Question**: The requirements define commit semantics but never list
`BEGIN`/`COMMIT`/`ROLLBACK` as SQL. 09 §9.5 assumes PostgreSQL-like
transaction statements exist (clients need them to form multi-statement
transactions, and "concurrent transactions" implies multi-statement
transactions exist). Alternatives:

| Option | Pros | Cons |
|--------|------|------|
| PostgreSQL-like BEGIN/COMMIT/ROLLBACK (baseline assumption) | clients work as expected; matches the commit definition | adds statements the requirements did not enumerate |
| Autocommit only (every statement its own transaction) | smallest surface | "concurrent transaction" support becomes nearly meaningless; `psql` workflows break |

*Affects*: 05 §5.11, 09 §9.5.

## D-18. Small SQL surface additions

**Question**: Add either of these common conveniences?

| Item | Pros | Cons |
|------|------|------|
| `IN (literal, list, ...)` in WHERE | very common idiom | grammar/semantics growth (still small) |
| `INSERT INTO ... SELECT ...` | common; reuses planner machinery | interacts with locking/statement atomicity design |

Both are **out of the baseline grammar** (05 §5.2) until decided.

## D-19. EXPLAIN command

**Question**: Expose plan trees (`EXPLAIN SELECT ...`)?

| Option | Pros | Cons |
|--------|------|------|
| Not supported (baseline) | zero surface growth | planner behaviour is hard to observe when learning/debugging |
| Text-only EXPLAIN | makes the fixed cost model and join choices visible — valuable for a teaching RDBMS | new statement type + output format decisions |

*Affects*: 05, 07.

## D-20. B+-tree delete rebalancing / sort-based aggregation

**Question**: Two "classical completeness" items the baseline omits —
(a) merge/rebalance of under-full B+-tree pages on delete (04 §4.4),
(b) sort-based GROUP BY as an alternative to hash aggregation (07 §7.7).

| Option | Pros | Cons |
|--------|------|------|
| Omit both (baseline) | smaller, still correct | indexes can waste space under delete-heavy loads; one aggregation strategy only |
| Add later as extensions | keeps baseline small; revisits with experience | requires the extension to be scheduled explicitly |

*Affects*: 04, 07, 10 (would be a Phase 8 extension).

## D-21. Query cancellation

**Question**: Support PostgreSQL's CancelRequest (separate connection
with BackendKeyData) to abort a running query?

Baseline: not supported (09 §9.2). Adding it needs per-session query
thread handles and abort plumbing through the executor.

*Affects*: 08, 09.

## D-23. TLS for client connections

**Question**: Answer SSLRequest with 'N' forever (baseline), or
support TLS?

TLS requires a TLS library (definitely not a boot library), so this is
coupled to D-06. Baseline: no TLS; the server is a teaching system for
trusted local networks.

*Affects*: 09 §9.2.
