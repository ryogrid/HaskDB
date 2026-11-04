# HaskDB

A small relational database (RDBMS) written in Haskell, built to the
specification in [`design/`](design/) (semantics authority) and
[`internal-design/`](internal-design/) (code structure authority).
It is a teaching-scale engine: page-based heap, buffer pool, write-ahead
logging, ARIES-style crash recovery, strict two-phase locking with deadlock
detection, a B+-tree index, a small SQL front end, and a PostgreSQL-compatible
wire protocol so that real `psql` and `pgbench` drive it.

Readability is the stated priority: classical algorithms over clever ones.

## Building

Toolchain: GHC 9.10.3 + Cabal, GHC boot libraries only (no `network`: D-24
replaced it with a libc socket shim, `c/hs-socket.c`, called through GHC's
FFI).  On this toolchain (Cabal 3.16.1.0) `cabal build all` compiles the
library and `exe:haskdb-server` only — the suite executables are compiled and
run by `cabal test`, so use `cabal test all` rather than building and invoking
them by hand.

```
cabal build all          # library + haskdb-server
cabal test all           # the 9 test suites
cabal test crash-tests   # one suite
```

`cabal test <name>` runs one suite; `cabal test all` runs all nine.

## Running the server

```
haskdb-server <dataDir> [--port N] [--create]
```

* `<dataDir>` is the database directory. If it has no `haskdb.control`, the
  database is **created** (page 0 + the catalog); otherwise it is **opened**
  (crash recovery first, then serve).
* `--port` overrides the configured port (default `54329`). `--create` is
  accepted and ignored — internal-design/11 §11.2 makes the missing control
  file the create signal.
* An open/create failure prints `haskdb-server: <cause>` on stderr and exits
  1 (§11.2's `die <message>`).

Connect with PostgreSQL clients:

```
psql -h 127.0.0.1 -p 54329 -c 'create table acct (k int64, v int64);'
psql -h 127.0.0.1 -p 54329 -c 'insert into acct values (1, 10);'
psql -h 127.0.0.1 -p 54329 -c 'select count(k) from acct;'
pgbench -h 127.0.0.1 -p 54329 -f bench.sql   # see scripts/pgbench-smoke.sh for
                                            # the working invocation: pgbench's
                                            # own `-i` init SQL is outside the
                                            # design/05 grammar, so the table is
                                            # created and populated by HaskDB
```

## Files on disk (internal-design/11 §11.2/§11.4)

One database = one directory, exactly four files:

| File | Purpose |
|------|---------|
| `haskdb.data` | the page file: page 0 (file header + relid counter), catalog heaps, relation heaps, B+-tree pages |
| `haskdb.wal` | write-ahead log; LSNs **are byte offsets** in this file |
| `haskdb.control` | human-readable text: `format=1`, `pageSize`, `checkpointLSN`, `nextTid` — written atomically (tmp + fsync + rename) by bootstrap and checkpoints |
| `haskdb.lock` | the flock holder: a second `haskdb-server` on the same directory is refused (design/00 §0.6) |

Reopen guards refuse rather than guess: a `pageSize` that disagrees between the
control file and the configuration, a control `format` other than `1`, page 0
without the `HDB1` magic or with a disagreeing page-size echo, a directory with
data/WAL but no control file (internal/11 §11.2's "incomplete database
directory" — never guessed), and a directory containing foreign files.

## Configuration

All deployment values live in `HaskDB.Common.Config.Config` (internal-design/00
§0.3), never in the algorithms; the server exposes no flags for them:

| Knob | Value (decision) |
|------|------------------|
| `cfgPageSize` | 8192 (D-01; the control file is authoritative afterwards) |
| `cfgBufferFrames` | 1024 (D-07) |
| `cfgStmtMemBudget` | 256 MiB per statement (D-08) |
| `cfgCheckpointSecs` | 300, time-based (D-11) |
| `cfgDeadlockMs` | 1000 ms detector scan (D-12 = detection, abort youngest, `40P01`) |

## Wire-protocol subset (design/09, internal-design/10)

Simple query protocol only (D-05): `Q`/`S` startup handshake, `Z`+`T`+`D`
parameter/BackendKeyData/`EmptyQueryResponse` flow, `Query` messages, `Row`
`Row`+`Terminate` (CancelRequest is accepted and the connection closed, D-21),
`COPY` in both directions (`CopyIn`/`CopyOut`, text format, D-16), transaction
blocks `BEGIN`/`COMMIT`/`ROLLBACK` (PostgreSQL-like, `ReadyForQuery` flag `T`
inside a block), one `ReadyForQuery` per frontend-message cycle, error
messages carrying SQLSTATEs, no TLS (D-23: the SSL probe answers a bare `N`).

## Tests

Nine suites (`haskdb.cabal`), each a `test-suite` stanza run with `cabal test`:

| Suite | Covers |
|-------|--------|
| `codec-tests` | codecs, CRC-32 vectors, value comparison |
| `storage-tests` | slotted pages vs an in-memory model, persistence, CLOCK buffer pool, free-space map |
| `wal-tests` | WAL framing/CRC/torn tail, buffered appends + fsync, control file, crash simulation, recovery idempotence |
| `index-tests` | bootstrap, catalog DDL through transactions, B+-tree split storms, duplicate keys, DELETE, aborted DDL |
| `txn-tests` | S2PL concurrency, live rollback, deadlock injection, recovery over real transaction records |
| `sql-tests` | lexer, parser (one positive per grammar production), every §0.3 "not supported" construct rejected, analyzer |
| `session-tests` | the wire layer over a scripted `Connection` (internal/11 §11.3 allows this), incl. COPY split mid-message, failed blocks, startup params |
| `exec-tests` | end-to-end SQL: planner plan dumps, three join algorithms, aggregates/ORDER BY/subqueries, error corpus + rollback |
| `crash-tests` | Phase-8 crash matrix on doctored disk states (checkpoint with an active txn, checkpoint-boundary equivalence, aborted-then-stolen undo, idempotent replay, reopen guards) |

Smoke scripts, which drive a real server process and real PostgreSQL clients:

| Script | What |
|--------|------|
| `scripts/psql-smoke.sh` | real `psql` sessions: handshake, CREATE/INSERT/SELECT, COPY in/out, blocks, the deadlock conflict, §11.5 shutdown, restart |
| `scripts/pgbench-smoke.sh` | real `pgbench` against the server (COPY-driven) |
| `scripts/crash-smoke.sh` | the server-level crash matrix C1–C10: SIGKILL after a commit, with an open `BEGIN` block, inside a 5000-row `COPY`'s WAL replay, after a `CREATE` response, plus the reopen/create guards — disagreeing `pageSize`, unsupported `format`, zeroed page-0 magic, foreign files, the `haskdb.lock` single-process rule, and internal/11 §11.2's `incomplete database directory` (no control file) refusal |

## Every test run is resource-capped (AGENT.md rule R-RES)

Nothing is executed straight onto the shell: `scripts/haskdb-test-run.sh` puts
each run in its own systemd scope inside one shared slice, so total CPU+memory
of every spawned process stays ≤ 20 % of the host (the caps are enforced by the
wrapper — `systemd-run` replaces it, so the wrapper itself prints only the
cap settings it applied). The budget is then **measured** by the harnesses that
read the slice's accounting back before and after the run and print the delta:
`scripts/psql-smoke.sh`, `scripts/pgbench-smoke.sh` and `scripts/crash-smoke.sh`
each end with two `budget check:` lines.

```
scripts/haskdb-test-run.sh cabal test all
HASKDB_CG_SLICE=my-run-1 scripts/haskdb-test-run.sh cabal test crash-tests
```

## Documentation map

| Path | Content |
|------|---------|
| `design/` | what the system must do (semantics authority) |
| `internal-design/` | how the code is structured (structure authority) |
| `TODO.md` | phase plan, the decision log `D-01…D-24`, plus per-phase **Deviations** (docs↔code and docs↔docs disagreements) and **Learned** notes |
| `notes/` | implementation memos: `wire-protocol-psql-pgbench-memo.md`, `conformance-checklist.md` |
