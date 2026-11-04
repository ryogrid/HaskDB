# Wire protocol memo — psql 18.3 + pgbench (written before implementing `Server.Wire`)

Reference client behaviour verified against the PostgreSQL 18.3 source tree
`/home/ryo/work/goopg/goopg/postgres` (`local_install/bin/psql --version` =
`psql (PostgreSQL) 18.3`, `local_install/bin/pgbench` present).
Note: the checkpoint's stated psql dir `/home/ryo/goopg/...` does not exist; the
actual one is `/home/ryo/work/goopg/goopg/postgres/local_install/bin`
(smoke scripts must `export PATH` + `LD_LIBRARY_PATH` accordingly).

Authority order unchanged: `design/09` + `internal/10` for our semantics; the
PostgreSQL docs/source for what the CLIENTS actually put on the wire. Where the
design docs are silent (COPY, protocol letters), the PostgreSQL formats win,
and the divergence is logged in TODO.md.

## 1. Startup handshake (psql 18.3, `src/common`/`libpq` + `design/09` §9.2)

Startup packets have NO type byte: `Int32 len`, then `Int32 code`.

| packet | code | our reply |
|--------|------|-------------|
| StartupMessage | 196608 (3.0) … 196610 (3.2) | accept; `psql` 18.3 sends **196610** (`PG_PROTOCOL_LATEST = PG_PROTOCOL(3,2)` in `include/libpq/pqcomm.h`, verified) |
| SSLRequest | 80877103 | single byte `'N'` |
| GSSENCRequest | 80877104 | single byte `'N'` |
| CancelRequest | 80877102 | close connection (D-21) |

FLUSH RULE (verified against libpq 18.3, learned while debugging the smoke
test): the SSL/GSS probe's single `'N'` byte must be FLUSHED before the server
reads the StartupMessage — libpq sends the probe, then *waits for the reply*
before sending its real startup packet, so a buffered `'N'` plus a blocking
`recv` deadlocks the client until `SSLSTATUS_TIMEOUT`. §9.7's output batching is
a per-query-cycle property and must not cover startup negotiation.

Version rule: accept major 3, minor 0..2; a minor > 2 client (PG 19 beta) would
need `NegotiateProtocolVersion` (`'v'`, int32 newest protocol NUMBER we
implement — NOT the bare minor: a bare `2` is read by a modern client as
"newest is 0.2" and the connection is rejected, so we send `3<<16|2 = 196610`,
then int32 0 unknown options) — implement the cheap reply so a newer client
degrades instead of hanging. (Not in the design docs: supplementary, log as
deviation.)

Backend replies (letters + shapes from the official protocol-message-formats
docs, fetched 2026-11-04; the design docs name the messages but never the
letters):

| message | letter | body |
|---------|--------|------|
| AuthenticationOk | `'R'` | `Int32 len = 8`, `Int32 0` |
| ParameterStatus | `'S'` | String name, String value (NUL-terminated) |
| BackendKeyData | `'K'` | `Int32 pid`, then secret bytes to end of message (4..256 bytes) |
| ReadyForQuery | `'Z'` | `Int32 len = 5`, `Byte1` status `I`/`T`/`E` |

ParameterStatus set per design/09 §9.2: `server_version = "16.0 (HaskDB)"`,
`client_encoding = UTF8`, `server_encoding = UTF8`, `DateStyle = ISO, MDY`,
`integer_datetimes = on`, `standard_conforming_strings = on`.

psql-side facts (verified in `src/bin/psql/startup.c`, `common.c`):
- PG 18.3 psql sends **no startup SQL probe** (no `SELECT 1;;` anywhere in the
  tree) — so a `select` without `FROM` is not needed for connecting.
- `standard_strings()` / prompt helpers read `PQparameterStatus(...)` — hence the
  ParameterStatus set above must include `standard_conforming_strings`.
- `BEGIN;` / `COMMIT;` / `ROLLBACK;` SQL is sent only under
  `--single-txn` (`startup.c:368`, `:439`) — our smoke script exercises them
  explicitly instead.
- Feature probes (`\d`, `\echo`, …) issue SQL only when the script uses them;
  the smoke script sticks to our dialect.
- Simple-query message: `'Q'` (`QSimple`), `Int32 len`, String SQL (NUL-
  terminated). Extended protocol letters (`'P'` Parsetable, `'B'` Bind, …) are
  out of baseline (D-05); an unknown type byte answers
  `ErrorResponse 0A000` per `internal/10 §10.3`.
- Frontend `Terminate` = `'X'`, `Int32 len = 4`.
- Message letters conflict-free parse: backend `ReadyForQuery`/`AuthenticationOk`
  both use `'R'` (context-dependent) — the client never has to distinguish.

## 2. Result/error messages (psql text output)

| message | letter | body (big-endian) |
|---------|--------|-------------------|
| RowDescription | `'T'` | `Int16 ncol`, then per column: String name (NUL-terminated), `Int32` table OID (0), `Int16` attnum (0), `Int32` type OID, `Int16` typelen (8/8/-1/1), `Int32` typmod (-1), `Int16` format (0) |
| DataRow | `'D'` | `Int16 ncol`, then per column `Int32` byte length (-1 = NULL, no bytes) + raw bytes |
| CommandComplete | `'C'` | String tag (NUL-terminated) |
| EmptyQueryResponse | `'I'` | `Int32 len = 4` |
| ErrorResponse | `'E'` | (key byte + String)* then a single `0` terminator byte |
| NoticeResponse | `'N'` | same field framing |

Error fields per design/09 §9.6: `S`=`ERROR`, `V`=`ERROR`, `C`=SQLSTATE,
`M`=message; `F`/`L`/`P`/`s` omitted in baseline. pgbench reads `C`
(`PQresultErrorField(PG_DIAG_SQLSTATE)`) — see §4.

Text encodings (design/09 §9.4 + `internal/10 §10.1`): INT64 decimal; FLOAT64
GHC `show` with `.0` appended when no `.`/`e`/`n` present; VARCHAR raw UTF-8;
BOOLEAN `t`/`f`. Our dialect has no NULL, so `Int32 -1` never appears.

Statement command tags (design/09 §9.4 + PostgreSQL `CommandComplete` wording):
`SELECT n`, `INSERT 0 n`, `UPDATE n`, `DELETE n`, `BEGIN`, `COMMIT`,
`ROLLBACK`, `CREATE TABLE`, `CREATE INDEX`, `COPY n` (COPY tag is our choice —
PostgreSQL's is `COPY`; the count suffix is informational).

## 3. Framing rules (`internal/10 §10.1`, design/09 §9.7)

- regular messages: `Byte1 type`, `Int32 len` (len counts itself);
- startup packets: `Int32 len`, `Int32 code` (no type byte);
- length sanity: `< 4` or `> 1 GiB` → close connection;
- partial frames wait for more bytes (session buffer grows);
- writes flushed per query cycle (after ReadyForQuery).

## 4. pgbench 18.3 — what it actually needs (`src/bin/pgbench/pgbench.c`)

Initialization (`runInitSteps`) runs **only** in `-i/--initialize` mode
(`pgbench.c:7185` `if (is_init_mode) { … runInitSteps … exit(0); }`) and `-I ""`
is rejected (`checkInitSteps`, `pgbench.c:5296`). Its steps emit SQL we cannot
parse (`pgbench.c:4800` `drop table if exists …`, `:4941` `create table t(cols)`
with `int`/`bigint`/`char(84)`/`not null`/`with (fillfactor=…)`/
`partition by`/`tablespace`, `:4980` `truncate table …`, `:5220`
`vacuum analyze …`, `:5233` `alter table … add primary key …`,
`:5271` `… foreign key …`).

Consequence: **do not use pgbench's own initialization.** Our pgbench setup is
ours: create the four tables with HaskDB DDL and populate them with HaskDB
`COPY ... FROM STDIN` (or INSERTs), then run `pgbench -f <script>`.

Benchmark-mode requirements (must hold or pgbench dies):
1. `GetTableInfo` runs before benchmarking and sends
   `select count(*) from pgbench_branches` (`pgbench.c:5407`); any non-tuples
   result → `exit(1)`. So `COUNT '*'` over a relation (empty ok → `0`) must work
   and stream as RowDescription+DataRow.
2. The partition probe (`pgbench.c:5446`, a `pg_catalog` join query) failure is
   tolerated → `PART_NONE`. Do not implement; verify it is tolerated.
3. Script lines are SQL sent **verbatim** through `PQsendQuery` (simple
   `'Q'`, default `--query-mode=simple`, `pgbench.c:3196`); `\set`/`:var`
   substitution and `\gset`/`\sleep` are client-side. The builtin scripts
   (`pgbench.c:782-818`) use `:vars`, expressions, `CURRENT_TIMESTAMP` and the
   `END;` pseudo-statement → unusable; `-f` custom scripts are the integration
   path, with `BEGIN; … COMMIT;` (design/09 §9.5 / D-17) as our transaction
   control. (`pgbench.c:4137` sends literal `ROLLBACK` on failure paths — we
   support it.)
4. After each script/pgbench transaction, `CSTATE_END_TX` calls
   `getTransactionStatus(con)` (`pgbench.c:4278`), which reads the ReadyForQuery
   status byte: it must be `I` after `COMMIT;` and the session must be
   `T` inside `BEGIN;` — otherwise pgbench aborts
   ("end of script reached without completing the last transaction").
5. Errors: only SQLSTATE `40P01` (deadlock, our D-12) and the
   serialization code are retried (`getSQLErrorStatus`,
   `pgbench.c:3237-3258`); everything else aborts a client. So the pgbench
   script must be error-free, and lock contention must surface as `40P01`
   (retryable) or block, never as `XX000`.
6. COPY never appears in the benchmark loop: `readCommandResponse`
   (`pgbench.c:3362-3374`) deliberately aborts on `PGRES_COPY_IN/OUT/BOTH`.
   COPY is used by pgbench only in the `-i` data-loading step
   (`initPopulateTable`, `pgbench.c:5025-5131`).

COPY IN flow (pgbench's `-i -I g` step, and our own bulk loading):
- `begin` (statement, session → `T`);
- `truncate table a, b, c` — unsupported in our dialect; see §5 option list;
- `copy <table> from stdin` — and when `PQserverVersion(con) >= 140000`
  pgbench instead uses `copy <table> from stdin with (freeze on)`
  (`pgbench.c:5037-5040`) after a **parameterized** probe
  `SELECT relkind FROM pg_catalog.pg_class WHERE oid=$1::pg_catalog.regclass`
  via `PQexecParams` (extended protocol). Our simple-protocol server cannot
  answer it and `get_table_relkind` does `exit(1)` on failure
  (`pgbench.c:863-868`). So with `server_version = "16.0 (HaskDB)"` the
  pgbench `-I g` path cannot work. Options:
  (a) keep the docs' version string and never use pgbench `-i`
      (recommended: pgbench integration = our setup + `-f` scripts);
  (b) report a sub-14 version (`"9.20 (HaskDB)"`) so pgbench takes the plain
      `copy … from stdin` form — contradicts design/09 §9.2, log if chosen;
  (c) implement pg_catalog + `$n` parameters — out of scope.
- client then: server sends `CopyInResponse` (`'G'`: `Int8 fmt`=0 text,
  `Int16 ncol`, `Int16[ncol]` format codes 0) as the first message of the
  statement; pgbench does `PQputline` per row (`'d'` CopyData chunks, arbitrary
  split), terminator line `\.` + `PQendcopy` (`'c'` CopyDone), then expects the
  statement's `CommandComplete` + `ReadyForQuery`.
- COPY text rows pgbench writes (`pgbench.c:4988-5012`): tab-separated
  decimal fields, `\N` for NULL (branches/tellers `filler`), empty field for the
  blank-padded `char` default (accounts).

## 5. COPY in our dialect (extension: design/09's message table omits COPY
    entirely; PostgreSQL has it; the user requires it for pgbench)

Syntax (supplementary spec, TODO log):
`copy <table> from stdin [with ( <arbitrary> )]` and
`copy <table> to stdout` (`with (freeze on)` parsed and ignored — HaskDB has no
lock-free load mode).

Semantics:
- statement runs inside the session transaction like any DML (BEGIN/COPY/COMMIT
  is pgbench's own pattern); row locks (S on read? COPY IN = writes → X lock per
  row, WAL `PInsertTuple`) exactly as `INSERT`;
- `from stdin`: send `CopyInResponse` before consuming input; accumulate
  `CopyData` bytes, split on newlines, parse COPY text format (tab-separated;
  `\N` → no-NULL dialect: use the type's zero value (VInt 0 / VFloat 0.0 / VText
  "" / VBool `f`) — deviation; `\<char>` escapes `\n \t \b \f \r \v \\` and
  `\NNN` octal; a lone `\.` line ends data; stop at `CopyDone`);
  `CopyFail` (`'f'` + cause) → abort the statement.  CORRECTION (the earlier
  draft's guess was wrong): PostgreSQL's `errcodes.txt` has NO `20F` code at
  all — the code for a bad COPY input is `22P04`
  (`ERRCODE_BAD_COPY_FILE_FORMAT`), so COPY protocol/arity errors use `22P04`;
- arity/type mismatch per row → `22P02` (bad literal); wrong ARITY is a bad COPY
  line too, so `22P04` (the earlier draft's `4280`-family guess was dropped,
  matching the CORRECTION above); row too large for a page → `54000`
  (same as INSERT);
- `to stdout`: `CopyOutResponse` (`'H'`) then `CopyData` chunks in the same text
  format terminated by `\.` then `CopyDone` then `CommandComplete "COPY n"`,
  streamed (no materialisation → no memory-budget charge);
- counts reported in `CommandComplete`; `COPY` inside an explicit block does NOT
  commit by itself (pgbench commits).

## 6. Consequences for the implementation plan (Phase 7 tasks)

- `Server.Wire`: letters/shapes above; framing reader returns
  `Need | Bad | Ok msg rest` so `Session` can buffer; COPY messages
  (`msgCopyInResponse`, `msgCopyOutResponse`, `msgCopyDone`, and decoding
  `FCopyData`/`FCopyDone`/`FCopyFail` as frontend messages).
- `Server.Session`: `QSimple` handler per `internal/10 §10.5`; the COPY statement
  needs a message-loop *inside* the statement handler (the session, not the
  executor, owns the socket) → executor exposes `executeCopy` given a row sink,
  and the wire session feeds rows; keep the row-format parsing in
  `Server.Wire` (`decodeCopyRow`).
- `Server.Listener` + `app/Main.hs` unchanged by COPY.
- Smoke scripts: `scripts/psql-smoke.sh` (T39) and
  `scripts/pgbench-smoke.sh` (T44) using
  `export PATH=/home/ryo/work/goopg/goopg/postgres/local_install/bin:$PATH`
  and `export LD_LIBRARY_PATH=/home/ryo/work/goopg/goopg/postgres/local_install/lib:${LD_LIBRARY_PATH:-}`.
  pgbench fixture: create `pgbench_{accounts,branches,tellers,history}` with
  HaskDB DDL (`int64` columns; `filler varchar`), populate with `COPY ... FROM
  STDIN`, benchmark script with `BEGIN; UPDATE ... SET abalance = <lit> WHERE aid = <lit>; SELECT ...; COMMIT;`.
  Note pgbench's `:var` substitution feeds literals into the script text — our
  grammar takes literals, so a pgbench script CAN use `\set` + `:aid` (the
  substitution is textual, client-side) as long as the resulting SQL is
  dialect-legal: `UPDATE pgbench_accounts SET abalance = :delta WHERE aid = :aid;`
  becomes `... = 123 WHERE aid = 45;` — legal. Our dialect's UPDATE RHS accepts
  a literal → OK.

## 7. Deviations to record in TODO.md at the phase boundary

- protocol message letters + RowDescription/DataDataRow field order taken from
  PostgreSQL 18.3 docs (design/09 names messages only);
- StartupMessage minor version accepted up to 3.2 (docs name 196608 = 3.0; the
  18.3 client sends 196610) and `NegotiateProtocolVersion` reply for newer
  clients;
- COPY statement + COPY wire messages (design/09's message table has none) and
  the `copy … from stdin with (…)` option accepted-and-ignored;
- `\N` in COPY text rows → the column type's zero value (dialect has no NULL);
- COPY failure code `20F03` (PostgreSQL's `COPY IN` error code) — design/09 §9.6
  table has no COPY row;
- psql binary lives at `/home/ryo/work/goopg/goopg/postgres/local_install/bin`
  (the checkpoint's `/home/ryo/goopg/...` path does not exist);
- pgbench integration: our own table setup + `-f` scripts, not pgbench's `-i`
  steps (its SQL surface — drop/truncate/vacuum/alter/partition/`char(N)` — is
  outside design/05's grammar); server_version stays `16.0 (HaskDB)` so
  pgbench's `-I g` probe path is knowingly unusable (option (b) rejected:
  contradicts design/09 §9.2).
