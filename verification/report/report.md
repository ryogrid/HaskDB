# TLA+ Verification of HaskDB: External Operations and REPEATABLE READ

**Repository:** ryogrid/HaskDB, master at commit `26db41d4a9463138c6d22c91ec957399da76190d`
**Date:** 2026-11-17
**Tools:** TLA+ / TLC 1.7.4 (`tla2tools.jar`), Temurin OpenJDK 17.0.21
**Materials:** `verification/spec/` (models + configs), `verification/results/` (full TLC logs), `verification/run_all.sh` (re-runs every check)

---

## 1. Scope and questions

This study model-checks HaskDB's transaction machinery, as documented in
`design/` and as implemented in `src/HaskDB/`, against two questions:

1. **External operations.** Are the operations of HaskDB's external
   specification — `BEGIN` / `COMMIT` / `ROLLBACK`, `SELECT`, `INSERT`,
   `UPDATE`, `DELETE`, and transactional DDL — free of specification-level
   problems: non-atomic commit, partial rollback, lost updates, ambiguous
   or inconsistent semantics?
2. **Isolation level.** The design (design/03 §3.2) states that the
   concurrency-control baseline — strict two-phase locking (strict 2PL)
   with row locks — "provides the equivalent of REPEATABLE READ for row
   accesses … with phantoms possible". Does that claim hold, property by
   property, and under which definition of REPEATABLE READ?

Method in one paragraph: the design/implementation was abstracted into a
TLA+ model (`spec/HaskDB.tla`) in which transactions perform point reads,
full scans, inserts, updates, deletes, commits and aborts over a small
key space under exactly the locking rules the code implements. TLC then
explored the reachable state space exhaustively for a small
configuration (2 transactions × 2 keys — one initially present, one
absent so INSERT is representable — × 2 values), checking invariants
that encode each rule; two larger spaces were additionally explored in part before
being stopped for time (2 transactions × 3 keys: 22.3 M distinct
states; 3 transactions × 2 keys: 14.0 M distinct states), with no
violation in either. A weakened
READ COMMITTED variant (`spec/HaskDBRC.tla`) serves as a negative
control, and a scripted two-transaction module
(`spec/HaskDBDeadlock.tla`) isolates deadlock behaviour with and without
the implemented deadlock policy.

**What "verified" means here.** All positive results are statements
about the *model*, i.e. about the design as abstracted in §2. They are
evidence that the documented locking discipline, *if implemented as
modelled*, enforces the stated properties. They are not a proof that the
Haskell code is correct; §7 lists what the abstraction leaves out.

---

## 2. Sources and model mapping

### 2.1 Facts taken from the design documents

| # | Fact | Source |
|---|------|--------|
| D1 | Concurrency scheme is strict 2PL with row-level locks; all locks held until commit/rollback; reads take S, writes take X; S→X upgrade allowed when the transaction is the only holder. Stated as the *provisional baseline*, decision item D-02 still open (alternatives: MVCC, single-writer). | design/03 §3.2 |
| D2 | Lockable objects: table (IS/IX/S/X intention modes; DDL takes X, DML takes intention modes), row/RID (S/X). **Index key ranges are not locked.** "Phantom anomalies are therefore possible under the baseline: a repeated range scan can see rows inserted by a concurrently committed transaction." | design/03 §3.2, lock table |
| D3 | Isolation claim: "the equivalent of REPEATABLE READ for row accesses (no dirty reads, no non-repeatable row reads, no lost updates), with phantoms possible". Marked a *supplementary specification*; "the requirements do not name an isolation level". A READ COMMITTED style mode (read locks released after each statement) is an option in D-03, "not implemented by default". | design/03 §3.2 |
| D4 | Commit protocol: append COMMIT record, flush WAL (fsync) — after the flush returns the transaction is committed; locks are released only after the flush (strictness). Rollback: undo in memory in reverse order using before-images, append ABORT, release locks. | design/02 §2.4; design/03 §3.3 |
| D5 | Statements are atomic: a failed statement leaves no partial changes. Outside an explicit block every statement is its own implicit transaction (autocommit). A failed statement inside an explicit block puts the block into the failed state. Savepoints are not supported. | design/03 §3.1; design/02 §2.4 |
| D6 | Deadlock is reachable under row locking + upgrades and a mechanism is mandatory. The design leaves the policy open (D-12): (a) wait-for cycle detection aborting the youngest transaction in the cycle, SQLSTATE 40P01; or (b) lock-wait timeout, SQLSTATE 55P03. | design/03 §3.5 |
| D7 | DDL (CREATE TABLE / CREATE INDEX) is transactional, WAL-logged, and takes an X lock on the table, excluding concurrent DML for the statement's duration. | design/03 §3.6; design/05 §5.2 note |
| D8 | SQL surface: SELECT (WHERE/GROUP BY/ORDER BY, subqueries), INSERT … VALUES (no INSERT … SELECT), UPDATE (assignments are literals or column references — the grammar has **no arithmetic**), DELETE, CREATE TABLE, CREATE INDEX. No PRIMARY KEY / UNIQUE constraints exist in the grammar; rows are identified by RID. `BEGIN`/`COMMIT`/`ROLLBACK` are session commands (09 §9.5), not grammar statements; there is no SET TRANSACTION / isolation-level syntax. | design/05 §5.2 |

### 2.2 Facts taken from the implementation

| # | Fact | Source |
|---|------|--------|
| I1 | Lock manager is STM-based. Modes IS/IX/S/X with the standard conflict matrix (X conflicts with everything). Grant requires compatibility with all granted modes **and** no earlier conflicting waiter (FIFO fairness against writer starvation). Waiting is an STM `retry` on a per-request flag, racing an abort channel; the abort channel wins over a grant. | `src/HaskDB/Txn/LockManager.hs` (`modeConflict`, `tryGrant`, `lock`) |
| I2 | Deadlock policy as implemented: D-12 was decided as **wait-for graph detection + abort youngest victim + 40P01**. A background thread scans every `cfgDeadlockMs`; on a cycle it signals the maximum tid (youngest = most recently begun) through the abort channel. Only transactions in `Active` status are signalled — a `Committing` transaction is past the commit point and exempt. | `src/HaskDB/Txn/Deadlock.hs`; `src/HaskDB/Txn/Manager.hs` (`signalAborted`) |
| I3 | `commitTxn`: status → Committing; append COMMIT; `flushWalUpTo` (the commit point); **then** `unlockAll`; staged catalog updates are applied after the commit point, in registration order. `abortTxn`: undo newest-first through the same `applyUndo` used by crash recovery; append ABORT; `unlockAll`; staged updates discarded. | `src/HaskDB/Txn/Manager.hs` |
| I4 | Statement rollback (`abortStatement`): undoes to the statement mark and **releases the locks the failed statement acquired**; the transaction stays active. | `src/HaskDB/Txn/Manager.hs` (`releaseStmtLocks`) |
| I5 | Read locking: sequential scan takes an S lock on each row as it is emitted (`queueNext`); index scan S-locks every hit (`heapFetch` at open, re-booked per row). Point fetch takes S on the RID *before* reading the page. A lookup that finds no row takes no lock. Pure SELECTs take **no table-level lock** (no IS) anywhere on the read path. | `src/HaskDB/Executor/Operators.hs` (header, `queueNext`, `indexHits`); `src/HaskDB/Heap/Heap.hs` (`heapFetch`) |
| I6 | Write locking: INSERT takes IX on the table and **X on the fresh RID before the tuple is written** (slot selection, then lock, then WAL, then page write). UPDATE/DELETE take IX on the table and X on each target RID before mutation; the candidate rows were S-locked by the feeding scan, so this is an S→X upgrade in the usual case. WAL record is appended before any page mutation. | `src/HaskDB/Heap/Heap.hs` (`heapInsert`/`insertOnPage`/`heapUpdate`/`heapDelete`, header invariants) |
| I7 | Index maintenance during DML takes a **transaction-duration X lock on the index relation** (plus a short MVar latch). Index *searches* (`btreeSearch`/`btreeRange`) take no transaction locks at all. | `src/HaskDB/Index/BTree.hs` (`btreeInsert`, `btreeDelete` vs `btreeSearch`) |
| I8 | DDL takes X on the (new/affected) table's relation id. | `src/HaskDB/Catalog/Bootstrap.hs` (`createTableDDL`, `createIndexDDL`) |
| I9 | Existing tests encode the same expectations: a 4-session parallel stress test and a deadlock-injection test (A holds one row and blocks on the other's; victim = younger txn wakes with 40P01; the survivor then proceeds). | `test/TxnSpec.hs` |

### 2.3 Model mapping

The model (`spec/HaskDB.tla`) represents one table. A *key* is a row
identity (RID); per D8 there are no user-visible unique keys to model.
One key starts absent so INSERT (row creation) is representable.

| Model element | Meaning | Backed by |
|---|---|---|
| `db[k]` | Committed value of row k, or `NoVal` if the row does not exist | — |
| `wbuf[t][k]` | Transaction t's not-yet-committed write to k (value, `NoVal` for delete, `None` for untouched) | Abstraction of in-place update + X lock + before-image undo; see below |
| `locksS[k]`, `locksX[k]` | Granted S holders / X holder of row k | I1, I5, I6 |
| `Read(t,k)` | Point read; requires S grantable; takes S if the row exists; takes **no** lock on a miss; returns `db[k]` (own writes are read from `wbuf` and are not separate actions) | I5 |
| `Scan(t)` | SELECT / range scan; requires S grantable on every existing row; S-locks every returned row; records the returned key set | I5, D2 |
| `Insert(t,k,v)` | Insert into an absent slot; requires X grantable on the fresh identity; buffered | I6 |
| `Write(t,k,v)` / `Delete(t,k)` | UPDATE / DELETE of an existing row; requires X grantable (upgrade rule: no other S holders) | I6, D1 |
| `Commit(t)` | Applies `wbuf[t]` to `db` in **one atomic step**, then releases all locks | D4, I3 (the step is the WAL-flush commit point) |
| `Abort(t)` | Discards `wbuf[t]`, releases all locks, `db` untouched | D4, I3 |
| Blocked request | The action is simply not enabled; the transaction may do other work, commit, or abort (detector / client can always end it) | I1, I2 |

Two abstraction choices deserve emphasis:

* **Buffered writes vs in-place updates.** The implementation writes
  into shared heap pages immediately, protected by the X lock taken
  *before* the page is touched (I6), with before-images in the WAL for
  undo. Because no other transaction can read or write a row whose X
  lock is held, and abort restores the before-image before releasing
  locks, the *observable* behaviour is identical to a private buffer
  applied atomically at commit. The model uses the buffer form.
* **Table intention locks and DDL are not modelled.** The properties
  under study are row-level; table X/IX interactions with DDL are
  discussed as findings in §5 (items F5, F6) instead.

---

## 3. Properties checked and how each is encoded

All properties are state invariants over the main model, checked by TLC
in **Run A** (2 transactions; `spec/HaskDB2K.cfg`), and a 3-transaction
exploration (**Run A3**, `spec/HaskDB3S.cfg`) covered the same
invariants over a further 14.0 M states without violation. History variables
(first-read records, first-scan records, commit snapshots) make the
history properties expressible as invariants; three Boolean flags
(`badNRR`, `badLU`, `phantom`) are set by the actions that would witness
a violation.

| # | Property (claim) | Encoding |
|---|---|---|
| P1 | **No dirty read** — a transaction never reads a value written by a transaction that has not committed; if the writer aborts, no reader saw its value | Reads consult only `db` (changed solely by `Commit`) and the reader's own buffer. Invariant `NoDirtyRead`: every externally read value is in `committedVals[k]`, the set of values ever committed for k (initial state counts as committed). |
| P2 | **Repeatable read (point)** — re-reading the same key in one transaction returns the same value, unless the transaction itself wrote it | First external read per (t,k) is recorded (`firstExtRead`); a later external read of an *existing* row with a different value sets `badNRR`. Invariant `NoNonRepeatableRead`. A row *appearing* at a previously absent identity is deliberately **not** counted here — it is phantom-class (P6). |
| P3 | **No lost update / WW safety** — two concurrent transactions cannot both commit writes to the same key where one overwrites a value the other had read and that has since changed | `Write`/`Delete` require X, grantable only when no *other* transaction holds S or X (upgrade rule). Flag `badLU` records a write to a key whose *existing* value the writer read earlier (`firstExtRead` ∉ {none, absent}) and which another commit has since overwritten (`lastWSeq[k] > readSeq[t][k]`). Invariant `NoLostUpdate`. The AtomicCommit invariant (P4) additionally forces all committed write sets to be applied serially, in commit order. |
| P4 | **Atomic commit** — for each transaction, either all of its writes become visible (commit) or none do (abort); never a partial application | Invariant `AtomicCommit`: at every state, `db[k]` equals the initial value folded through the *complete* recorded write sets (`cWrites`) of committed transactions in commit order (`cOrd`). Aborted/active transactions contribute nothing. This single invariant also encodes **rollback correctness (P5)**: since `Abort` never touches `db` and aborted transactions never enter `cWrites`, the committed state is always exactly as if aborted transactions had never written. |
| P6 | **Phantom freedom (strict reading)** — a repeated scan in one transaction returns the same key set | First scan's key set recorded (`firstScan`); a later scan whose set differs in a key the scanner never wrote sets `phantom`. Invariant `NoPhantom`, checked separately in **Run B** (`spec/HaskDBPhantom.cfg`) because the design *predicts* it fails (D2). |
| P7 | **Deadlock** — can the system reach a state where every remaining active transaction waits forever? | Separate scripted module (`spec/HaskDBDeadlock.tla`): d1 takes X(a) then X(b); d2 takes X(b) then X(a). **Run D** (no policy): TLC's deadlock check. **Run E** (`UseDetector = TRUE`): adds a `DetectorAbort` action enabled exactly on a wait-for cycle, aborting the youngest member (I2); checked for absence of deadlock plus `AtMostOneVictim` (the detector never aborts both) and `HolderActive`. |
| P8 | **Negative control** — the properties must fail when the discipline is weakened | `spec/HaskDBRC.tla` is the main model with one change: S locks are released immediately after each read/scan (the D-03 READ COMMITTED option, D3). **Run C** checks `NoNonRepeatableRead` there; a counterexample is *required* for the study to mean anything. |

`LockSafety` (an X holder excludes all other holders; locks are held
only by active transactions) and `TypeOK` are checked alongside in Run A.

---

## 4. Results

| Run | Configuration | Result | Scale |
|---|---|---|---|
| A — core properties | HaskDB.tla, 2 txns, 2 keys (1 present, 1 absent), 2 values; invariants P1–P5 + LockSafety | **No error found** — all invariants hold over the full reachable state space | 1,335,873 states generated, 361,761 distinct, depth 18, 25 s |
| A3 — core, 3 txns | HaskDB.tla, 3 txns, 2 keys (1 present, 1 absent), 2 values | **Partial exploration** — no violation in the states covered; stopped for time with the space still growing (not exhaustive) | 35,589,785 states generated, 14,018,230 distinct, up to depth 15, ~9 min (stopped) |
| B — phantom probe | HaskDB.tla, `NoPhantom` only | **Violated** — counterexample in 7 steps (below) | found after 27,019 generated / 10,376 distinct states |
| C — negative control | HaskDBRC.tla (read locks released), `NoNonRepeatableRead` | **Violated**, as required — counterexample in 7 steps (below) | found after 22,833 generated / 8,998 distinct states |
| D — deadlock, no policy | HaskDBDeadlock.tla, `UseDetector = FALSE` | **Deadlock reached** — after 2 lock acquisitions (below) | 13 distinct states |
| E — deadlock, with policy | HaskDBDeadlock.tla, `UseDetector = TRUE` | **No error found** — no deadlock, invariants hold | 16 distinct states |

Full TLC output for every completed run is in `results/`
(`runA-core-2txn.log`, `runB-phantom.log`, `runC-rc-weakened.log`,
`runD-deadlock-nodetector.log`, `runE-deadlock-detector.log`), and
`run_all.sh` reproduces them. Two further logs keep *partial*
explorations, stopped because their state spaces were still growing;
both are supplementary evidence only, not exhaustive results:
`results/runA-core-2txn-3key-partial.log` (2 transactions × 3 keys,
`spec/HaskDB.cfg`: 91,419,537 states generated / 22,327,276 distinct
states explored up to depth 15, no invariant violation, stopped after
16 minutes) and `results/runA3-core-3txn-partial.log` (3 transactions
× 2 keys, `spec/HaskDB3S.cfg`: 35,589,785 generated / 14,018,230
distinct up to depth 15, no invariant violation, stopped after
~9 minutes).

### 4.1 P1–P5 hold under strict 2PL (Run A)

Exhaustive exploration of the 2-transaction model found no dirty read,
no non-repeatable point read, no lost update, and no deviation from
atomic-commit/rollback semantics, over ~362 K distinct states. This is
the expected textbook result for strict 2PL, and it confirms that the
discipline *as the code implements it* — S before read, X before write,
upgrade only as sole holder, everything held to the commit point — is
sufficient for the design's row-level claims (D3). The 3-transaction
exploration (Run A3) covered a further 14.0 M distinct states, again
without violation, before being stopped with the space still growing —
breadth evidence, not an exhaustive result. The partial 3-key
exploration (§4, supplementary log) likewise found no violation in the
22.3 M distinct states it covered.

### 4.2 Phantom counterexample (Run B) — the design's prediction, confirmed

TLC's trace, in plain terms (full state dump in `results/runB-phantom.log`):

1. t1 begins.
2. **t1 scans** the table; it sees keys {k1, k2} (k3 does not exist) and
   S-locks k1, k2.
3. t2 begins.
4. **t2 inserts** the new row k3. The insert takes X on the *fresh*
   identity k3 — nothing t1 holds conflicts with it, because t1 could
   not lock a row that did not exist.
5. t2 commits. k3 now exists as a committed row.
6. **t1 scans again**; it now sees {k1, k2, k3}. The result set of the
   repeated predicate read changed inside one transaction: a phantom.

No rule of the row-level discipline is broken along the way; the trace
uses only documented behaviour (D2, I5, I6). The model therefore
*confirms the design document's own statement* that phantoms are
possible, with a minimal concrete schedule.

### 4.3 Negative control (Run C) — the properties have teeth

In the weakened variant (S locks released after each read — the D-03
option), TLC finds a non-repeatable read in 7 steps:

1. t1 begins; **t1 reads k1 → v0** (and, in this variant, keeps no lock).
2. t2 begins; t2 deletes k1; t2 commits.
3. **t1 reads k1 again → the row is gone** (`NoVal`), a different result
   from its first read of the same key.

The same check passes in the strict model (Run A), so the difference is
exactly the lock-retention rule — the invariant is not vacuous, and the
D-03 READ COMMITTED option would indeed give up repeatable reads, as
its name implies.

### 4.4 Deadlock (Runs D and E)

Without any policy, TLC reaches the deadlocked state after two lock
acquisitions (3-state trace): d2 takes X(b); d1 takes X(a); now d1
waits for b and d2 waits for a, and no
action is enabled. This is precisely the schedule design/03 §3.5 uses
to motivate a mandatory deadlock mechanism (D6), and the same shape as
the injection test in `test/TxnSpec.hs` (I9).

With the implemented policy modelled (cycle detection + abort the
youngest cycle member), the same module explores cleanly: no deadlock
state exists, the survivor always proceeds, and the detector never
aborts both transactions. Note the asymmetry this creates for clients:
the *younger* transaction is the one that receives 40P01 and must be
retried by the application; the design and code agree on this (D6, I2).

---

## 5. Findings on the external operations specification

These are specification-level findings: places where the documents are
silent, ambiguous, or in tension with the implementation, including
every decision the modeller had to take on the documents' behalf.
None of them is a counterexample to P1–P5; they are the places where
"the spec says so" could not be the justification.

**F1 — The isolation level is a baseline claim, not a requirements
claim, and it cannot be selected per transaction.**
The requirements never named an isolation level; design/03 §3.2
supplies "REPEATABLE READ for row accesses" as a supplementary
specification on top of a *provisional* baseline (D-02 could still
replace strict 2PL with MVCC or single-writer serialisation), and
design/05's grammar has no isolation-level syntax at all (D8). Anyone
building on HaskDB should therefore read the guarantee as "whatever
the current baseline provides", not as a contractual SQL isolation
level. *Modelling decision: the implemented baseline (strict 2PL) was
modelled; an MVCC decision under D-02 would invalidate the model, not
just its parameters.*

**F2 — "REPEATABLE READ" is claimed with phantoms explicitly allowed;
the documents do not say which definition they mean.**
design/03 §3.2 claims REPEATABLE READ equivalence *for row accesses*
and states phantoms are possible (D2, D3). Whether that is "really"
REPEATABLE READ depends on the definition (§6). The documents would be
clearer if they named the definition — e.g. "REPEATABLE READ in the
ANSI SQL sense (P3 phantoms permitted)". *Modelling decision: both
readings were checked separately (P2 vs P6) so the verdict does not
depend on the modeller's choice.*

**F3 — Deadlock policy was left open by the design (D-12) and is only
pinned down by the code.**
design/03 §3.5 offers two policies with *different client-visible
behaviour* (40P01 on detection vs 55P03 on timeout). The implementation
chose detection + abort-youngest (I2). A client written against the
design alone could not know which error to expect, nor that the
*youngest* transaction is always the victim (so long-running older
transactions are systematically favoured). The design document should
be updated to record the D-12 decision. *Modelling decision: the
implemented policy was modelled in Run E.*

**F4 — Statement-level rollback releases locks, which the design's
strictness statement does not mention.**
design/03 §3.2 says all locks are held until commit/rollback, but
`abortStatement` releases the locks a *failed statement* acquired while
the transaction continues (I4). This is safe for the checked properties
— the failed statement's reads were never delivered as a successful
result, and inside an explicit block the transaction enters the failed
state (D5), so nothing later in the transaction can depend on them —
but it is a real deviation from a literal reading of "strict", and a
streaming SELECT that fails mid-scan may already have delivered rows
to the client before its locks are released. Worth one sentence in
design/03. *Modelling decision: statement boundaries were not
modelled; the model checks transaction-level properties only.*

**F5 — Read paths take no table intention lock, so the design's
DDL/DML exclusion does not come from the lock manager for SELECTs.**
design/03 §3.2's lock table says DML takes intention modes "so DDL and
DML exclude each other correctly", and §3.6 says DDL's X lock excludes
concurrent DML. In the code, write DML does take IX (I6) and DDL takes
X (I8), but a pure SELECT takes no table lock at all (I5) — an X table
lock does not conflict with a lock the reader never requests. Whatever
protects a concurrent CREATE INDEX from SELECTs must therefore be the
catalog staging/publication mechanism, not the lock manager; the
documents do not analyse that interaction. This study did not model
DDL, so the point is flagged, not verified, either way.

**F6 — Index maintenance takes transaction locks although the design
says index structures are not transaction-locked.**
design/03 §3.2: "Index structures are protected only by short-term
page content locks … not by transaction locks." The implementation
additionally takes a transaction-duration X lock on the index relation
in `btreeInsert`/`btreeDelete` (I7). The effect is conservative —
concurrent transactions that maintain the same index serialise for
their whole duration (extra blocking, and extra deadlock surface in
principle, though the acquisition order table→index is consistent) —
and readers never take it, so it does not change any isolation
verdict. But the design text and the code describe different systems
here; one of them should be corrected.

**F7 — Minor: lock-upgrade fairness is stronger than the design's
rule.** The design allows upgrade "when the transaction is the only
holder" (D1); the implementation also makes an upgrader queue behind
earlier conflicting *waiters* (FIFO, I1). Two transactions that both
read a row and then both try to update it deadlock and are resolved
by the detector (the younger is aborted) rather than one being
granted the upgrade immediately — standard behaviour, but the
victim-selection consequence (F3) is worth knowing for retry logic.
*Modelling decision: FIFO waiter order was not modelled; it affects
which waiter proceeds first, not any checked safety property.*

---

## 6. The REPEATABLE READ verdict

**Claim under test** (design/03 §3.2): strict 2PL as implemented
provides "the equivalent of REPEATABLE READ for row accesses (no dirty
reads, no non-repeatable row reads, no lost updates), with phantoms
possible".

**Verdict, by phenomenon:**

| Phenomenon | Forbidden by ANSI REPEATABLE READ? | Model result |
|---|---|---|
| Dirty read (P1) | Yes | **Excluded** (Run A, exhaustive for the configuration) |
| Non-repeatable read (P2) | Yes | **Excluded** (Run A) |
| Lost update (P3) | Not an ANSI phenomenon per se; part of the design's claim | **Excluded** (Run A) |
| Phantom (ANSI phenomenon P3; property P6 here) | **No** — ANSI REPEATABLE READ permits phantoms; only SERIALIZABLE forbids them | **Possible** — concrete counterexample (Run B), exactly as the design states |

So under the **ANSI SQL phenomenon-based definition**, the design's
claim *holds in the model, including the phantom caveat*: ANSI
REPEATABLE READ is precisely "no dirty reads, no non-repeatable reads,
phantoms allowed", and that is exactly the combination the model
verifies (P1, P2 hold; P6 fails by design).

Under the **strict definition** of REPEATABLE READ used in much of the
concurrency literature (Berenson et al.'s critique of the ANSI
definition; locking-based definitions where REPEATABLE READ forbids
P3), HaskDB's baseline does **not** qualify, because phantoms occur
(Run B). It would sit at the level sometimes called "REPEATABLE READ
with phantoms" — stronger than READ COMMITTED (which the negative
control, Run C, shows failing P2), weaker than SERIALIZABLE.

Two practical consequences:

* Any application logic that depends on the *stability of a predicate
  result set* inside a transaction — e.g. "scan, decide, then act on
  the scan's result" over rows that other transactions can insert —
  is **not** protected by HaskDB's isolation, and no lock the
  application can request changes that (there is no key-range locking
  to ask for). Existence checks followed by inserts are the canonical
  victim: the check can pass and the row can still appear.
* Row-level logic — read a row, later re-read or update *that row* —
  is fully protected, including against lost updates, with deadlock
  (and a 40P01 retry for the younger transaction) as the only
  interference.

---

## 7. Limitations of the abstraction

1. **Design-level, not code-level.** The model encodes the locking
   *rules* the code implements (I1–I8); it does not verify the Haskell
   code itself. A bug in, say, `tryGrant`'s FIFO logic or in undo
   would not be caught here. (The code's own tests, I9, cover two
   concrete schedules.)
2. **Small configurations.** The exhaustive result is for 2
   transactions × 2 keys × 2 values. Two partial explorations add
   breadth — 3 transactions × 2 keys (14.0 M states) and 2
   transactions × 3 keys (22.3 M states), both stopped with their
   spaces still growing, neither exhaustive. The phenomena checked
   are all pairwise, and the negative control shows the checks bite
   at this size; but absence of a counterexample at larger sizes is
   not proven.
3. **Buffered-write abstraction.** In-place updates, the buffer pool,
   WAL replay and crash recovery are abstracted into atomic commit /
   no-op abort (§2.3). Crash-atomicity (e.g. recovery's undo of
   "loser" transactions) is therefore *assumed from the design*
   (design/02 §2.4–2.6), not model-checked.
4. **Scans are atomic actions.** The implementation locks rows one by
   one as a scan emits them and can block mid-scan. The atomic scan
   can miss interleavings *inside* one scan; each individual row read
   is still of committed data under an S lock, so no checked property
   is affected, but scan-internal snapshot behaviour (a scan seeing a
   mix of pre- and post-commit values of *different* rows) is real
   and is not a violation of any REPEATABLE READ clause.
5. **Blocked transactions may act.** In the model a transaction whose
   lock request is ungrantable can still perform other actions,
   commit, or abort; a real session is sequential and would be parked
   inside the blocked statement until the deadlock detector (or a
   disconnect) frees it. This over-approximates interleavings, which
   is conservative for the safety properties checked (more schedules,
   not fewer), but it means the model says nothing about *timeliness*
   — e.g. how long a waiter can be starved by a stream of short
   transactions is a fairness question the FIFO rule (I1) addresses
   in code and the model does not check.
6. **Not modelled:** table/DDL locking (see F5, F6), statement-level
   rollback and the failed-transaction state (F4), savepoints (not
   supported, D5), multiple tables and joins (locking is per-row and
   table-independent in the code, so the single-table results carry
   over per row), autocommit (a one-statement transaction in the
   model), the wire protocol, and types/values beyond a 2-value
   domain.
7. **Deadlock module scope.** Runs D/E use fixed scripts (the
   canonical opposite-order pair). They show deadlock is reachable
   and that the modelled policy removes it *for that pattern*; they
   are not a general deadlock-freedom proof for arbitrary workloads.
   The general guarantee comes from the policy itself (any wait-for
   cycle is eventually detected and broken), which is a liveness
   argument about the detector thread, outside TLC's safety checks
   here.

---

## 8. Conclusion

* The external operations are in good shape at the specification
  level: commit is atomic at a single, well-defined point (the WAL
  flush), rollback is total, statements are atomic, and the model
  found no schedule in which the documented operations produce a
  dirty read, a non-repeatable row read, a lost update, or a partial
  commit. (Run A, exhaustive; corroborated by the partial explorations
  of §4.)
* The REPEATABLE READ claim is **accurate under the ANSI definition
  and inaccurate under the strict definition**, and the design
  document itself supplies the reason: key ranges are not locked, so
  phantoms occur (Run B gives a 7-step witness). The documents should
  name the definition they mean (F2).
* Deadlock is genuinely reachable (Run D), and the *implemented*
  policy — wait-for cycle detection aborting the youngest transaction
  with 40P01 — removes it in the model (Run E). The design document
  still presents this as an open decision (F3) and should be updated.
* The specification findings worth acting on are documentary, not
  algorithmic: record the D-12 decision (F3), note the
  statement-rollback lock release (F4), reconcile the DDL-exclusion
  story with the fact that SELECTs take no table lock (F5), and
  reconcile the "indexes are not transaction-locked" statement with
  the index-relation X lock the code actually takes (F6).
* The negative control (Run C) confirms the checks are meaningful:
  the moment read locks are released early — the design's own D-03
  option — repeatable read fails immediately.

Nothing in this study contradicts the implementation's own test
expectations (I9); the model and the tests agree on the deadlock
shape, the victim choice, and the isolation behaviour.

---

## Appendix: how to reproduce

```sh
# needs a JRE on PATH (or JAVA=...) and tla2tools.jar (or TLAJAR=...)
cd verification
./run_all.sh        # writes results/*.log
```

| Log | Module / config | Expected outcome |
|---|---|---|
| `results/runA-core-2txn.log` | HaskDB / HaskDB2K.cfg | "No error has been found" |
| `results/runA3-core-3txn-partial.log` | HaskDB / HaskDB3S.cfg | Partial exploration (stopped; no completion line) — supplementary only, not produced by `run_all.sh` |
| `results/runA-core-2txn-3key-partial.log` | HaskDB / HaskDB.cfg | Partial exploration (stopped; no completion line) — supplementary only, not produced by `run_all.sh` |
| `results/runB-phantom.log` | HaskDB / HaskDBPhantom.cfg | Invariant NoPhantom violated (7-state trace) |
| `results/runC-rc-weakened.log` | HaskDBRC / HaskDBRC.cfg | Invariant NoNonRepeatableRead violated (7-state trace) |
| `results/runD-deadlock-nodetector.log` | HaskDBDeadlock / HaskDBDeadlock.cfg | "Deadlock reached" (3-state trace) |
| `results/runE-deadlock-detector.log` | HaskDBDeadlock / HaskDBDeadlockDet.cfg | "No error has been found" |
