# 09. Wire Protocol (PostgreSQL-Compatible Subset)

## 9.1 Goal and subset

HaskDB speaks a subset of the PostgreSQL frontend/backend protocol
(version 3.0) over TCP, sufficient for `psql` and mainstream drivers to
connect, run statements in the SQL dialect of 05-sql-language.md, and
receive results and errors in the usual shapes.

The baseline implements the **simple query protocol** and the startup
phase. Support for the **extended query protocol**
(Parse/Bind/Describe/Execute) is decision item **D-05**: several
drivers work with the simple protocol only via fallbacks, but full
driver compatibility usually wants extended protocol. This document
specifies the simple protocol completely and marks the points where
extended protocol would attach.

## 9.2 Connection startup

```
Client                                Server
  |  SSLRequest (optional)              |
  | ----------------------------------> |  responds 'N' (no TLS in baseline; D-23)
  |  StartupMessage                     |
  |    user=<anything> database=<any>   |
  | ----------------------------------> |
  |              AuthenticationOk       |  (no authentication exists:
  |              ParameterStatus x N    |   all clients are the single user)
  |              BackendKeyData         |
  |              ReadyForQuery ('I')    |
```

- `user` and `database` parameters are accepted and ignored (single
  database, single user). Unknown startup parameters are ignored.
- `ParameterStatus` values sent: `server_version` = `16.0 (HaskDB)`
  *(supplementary specification — a plausible PostgreSQL version string
  maximises client compatibility)*, `client_encoding` = `UTF8`,
  `server_encoding` = `UTF8`, `DateStyle` = `ISO, MDY`,
  `integer_datetimes` = `on`, `standard_conforming_strings` = `on`.
- `BackendKeyData` carries the session's process id (internal counter)
  and a secret key (random per session); query cancellation via a
  separate connection (`CancelRequest`) is **not** supported in the
  baseline — a cancel request connection is accepted and closed
  *(supplementary specification; decision D-21 if cancellation is
  wanted)*.
- GSSENCRequest is answered 'N' like SSLRequest.

## 9.3 Messages implemented

Frontend → backend:

| Message | Use |
|---------|-----|
| StartupMessage / SSLRequest / GSSENCRequest | §9.2 |
| Query | simple query protocol (§9.4) |
| Terminate (X) | close session |
| Parse/Bind/Describe/Execute/Sync/Flush | only if D-05 decides extended protocol |

Backend → frontend:

| Message | Use |
|---------|-----|
| AuthenticationOk, ParameterStatus, BackendKeyData, ReadyForQuery | startup / per-query end |
| RowDescription, DataRow | SELECT results |
| CommandComplete | statement completion tags |
| EmptyQueryResponse | empty query string |
| ErrorResponse | all errors (§9.6) |
| NoticeResponse | warnings (rare; e.g. none in baseline) |

All multi-byte protocol fields are big-endian, per the PostgreSQL
protocol (note: this differs from the on-disk little-endian formats —
the two codecs are separate modules).

## 9.4 Simple query protocol flow

On receiving `Query(sql)`:

1. Split `sql` into statements on top-level semicolons (respecting
   string literals and `--` comments).
2. Execute statements in order, inside the session's transaction state
   (§9.5):
   - For SELECT: send `RowDescription`, then one `DataRow` per result
     row, then `CommandComplete("SELECT n")`.
   - For INSERT/UPDATE/DELETE: `CommandComplete("INSERT 0 n")` /
     `("UPDATE n")` / `("DELETE n")`.
   - For CREATE TABLE / CREATE INDEX: matching `CommandComplete`.
   - For BEGIN/COMMIT/ROLLBACK: §9.5.
3. On the first error: send `ErrorResponse`, skip the remaining
   statements of the string, roll back per §9.5, then send
   `ReadyForQuery` with the transaction status byte:
   `'I'` idle, `'T'` in transaction block, `'E'` in failed
   transaction block.
4. A whitespace/comment-only query yields `EmptyQueryResponse` +
   `ReadyForQuery`.

### Row encoding (text format)

Only the **text** result format is supported in the baseline (format
code 0; requesting binary format for a column is an error `0A000` —
binary format support is part of D-05/D-16).

| Type | Text encoding |
|------|---------------|
| INT64 | decimal, `-` for negatives |
| FLOAT64 | shortest round-trip decimal (Haskell `show (x :: Double)`, post-processed: `Infinity`/`NaN` cannot occur, see 05 §5.4; ensure a decimal point or exponent is present to match PostgreSQL float output conventions) |
| VARCHAR | the raw UTF-8 bytes |
| BOOLEAN | `t` / `f` |

`RowDescription` reports the PostgreSQL type OIDs of 05 §5.3, type
lengths (8/8/-1/1), and format code 0.

## 9.5 Transaction control at the session layer

*(Supplementary specification — see D-17. PostgreSQL clients expect
these commands; the requirements' commit definition in 00 §0.7 is
implemented exactly for COMMIT below.)*

- `BEGIN` starts an explicit transaction block
  (`CommandComplete("BEGIN")`, status `'T'`). `BEGIN` inside a block
  is a no-op with a warning notice.
- `COMMIT`: runs the commit protocol of 02 §2.4 — WAL commit record +
  fsync first; only then `CommandComplete("COMMIT")` and status `'I'`.
  Committing an implicit transaction is the same path per statement.
- `ROLLBACK`: undoes the transaction (02 §2.4 / 03 §3.3),
  `CommandComplete("ROLLBACK")`, status `'I'`.
- An error inside an explicit block puts the session in failed state
  `'E'`; further statements other than COMMIT/ROLLBACK are rejected
  with `25P02` until the block ends. `COMMIT` of a failed block
  performs a rollback and returns `CommandComplete("ROLLBACK")`
  (PostgreSQL behaviour).
- Outside a block, each statement is an implicit transaction:
  BEGIN before, COMMIT (with fsync) on success, ROLLBACK on error.

## 9.6 Error mapping

Internal `SqlError`s carry a SQLSTATE; ErrorResponse fields: `S`
(severity `ERROR`), `V`, `C` (SQLSTATE), `M` (message), plus `F`/`L`/`R`
omitted in the baseline.

| Condition | SQLSTATE |
|-----------|----------|
| Syntax error / unsupported syntax | `42601` / `0A000` |
| Unsupported feature (e.g. correlated subquery, binary format) | `0A000` |
| Undefined table / column | `42P01` / `42703` |
| Duplicate table/index name | `42P07` |
| Duplicate column name in CREATE TABLE | `42701` |
| Grouping error (non-grouped column selected) | `42803` |
| Type mismatch in comparison/assignment | `42804` |
| Invalid text representation (bad literal) | `22P02` |
| VARCHAR value over 1024 bytes | `22001` |
| Scalar subquery returned != 1 row | `21000` |
| Tuple too large for page; sort/materialisation memory limit | `54000` |
| Deadlock victim | `40P01` |
| Lock wait timeout (if D-12 chooses timeouts) | `55P03` |
| Statement in failed transaction block | `25P02` |
| Internal error (page corruption, invariant violation) | `XX000` |

## 9.7 Session and listener implementation

- Listener: one thread, `accept` loop; each accepted socket becomes a
  session thread with its own read buffer and message parser
  (incremental, length-prefixed framing; partial messages handled).
- Message size sanity cap: 1 GiB (PostgreSQL's own cap) — larger length
  fields close the connection as a protocol error.
- A session thread that dies by exception must roll back its active
  transaction before exiting (exception handler around the session
  loop); a client disconnect mid-transaction likewise rolls back.
- Writes are flushed per query cycle (after ReadyForQuery), not per
  row. *(Buffering detail, implementation-level.)*
- The socket API question (boot-library-only constraint) is D-06.
