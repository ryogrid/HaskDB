# 00. Overview

## 0.1 Purpose

HaskDB is a small relational database management system (RDBMS) implemented
in Haskell. Its goal is to cover the *fundamentals* of an RDBMS in a
classical, easy-to-read form:

- a page-based heap storage engine with a buffer pool,
- write-ahead logging (WAL) and crash recovery,
- transactions with concurrent execution inside one process,
- a B+-tree index,
- a SQL front end (parser, planner, executor),
- a PostgreSQL-compatible wire protocol so that existing PostgreSQL
  clients (e.g. `psql`) can connect over TCP.

Design priorities, in order:

1. **Readability and ease of understanding** over performance.
2. Classical, well-known algorithms (slotted pages, CLOCK/LRU buffer
   replacement, ARIES-style recovery, volcano-style execution) over
   clever or hardware-specific optimisations.
3. General CS/RDBMS optimisation algorithms that are considered
   fundamental (join algorithms, indexing, sorting in memory) are in
   scope; micro-optimisations are not.

## 0.2 Platform and language

| Item | Specification |
|------|---------------|
| Implementation language | Haskell (GHC) |
| Libraries | In principle, GHC boot libraries only (see D-06 for the socket library question) |
| OS / architecture | Ubuntu Linux, x86-64 only |
| Concurrency unit | Multiple threads inside a single database process |
| Multi-process access to the same database files | **Not supported** (see §0.6) |

## 0.3 Scope summary

### Supported

- One single database that exists from the start (no `CREATE DATABASE`).
- Multiple tables in that database.
- DML: `SELECT`, `INSERT`, `UPDATE`, `DELETE`.
- DDL: `CREATE TABLE`, `CREATE INDEX` only.
- Aggregates: `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`, with `GROUP BY`.
- `ORDER BY` (in-memory sort only; no external sort, no `LIMIT`).
- Joins: inner equijoins derived from `WHERE` predicates over multiple
  relations in `FROM`. Nested Loop Join, Index Nested Loop Join and
  Hash Join are implemented.
- Subqueries: derived tables in `FROM`; uncorrelated subqueries in
  `WHERE` (`EXISTS`, `IN`, scalar). Correlated subqueries are **not**
  supported.
- Types: INT64, FLOAT64, VARCHAR (UTF-8, max 1024 bytes), BOOLEAN.
- Concurrent transactions from multiple client connections (threads)
  inside one process.
- Durability: a committed transaction survives a process crash
  (see §0.7 for the exact definition of "committed").

### Explicitly not supported

- NULL values, NULL literals, `IS NULL` / `IS NOT NULL`, three-valued
  logic. All predicate logic is two-valued.
- `ALTER TABLE`, `DROP TABLE`, `DROP INDEX`, and all other DDL.
- `HAVING`, `LIMIT`.
- Explicit `JOIN ... ON` syntax, outer joins, `CROSS JOIN`.
- Arithmetic expressions in the `SELECT` list
  (e.g. `SELECT col + 1 FROM t` is rejected).
- Overflow storage (TOAST-like mechanisms). A tuple must fit in one page.
- User management, authentication management, privileges. All clients
  are treated as one single user.
- External sort.
- Selectivity-based / statistics-based cost optimisation. The planner
  uses relation row counts, index existence and a fixed cost model only.
- Multiple databases, multiple processes opening the same files.

## 0.4 Architecture

```
                TCP clients (psql, drivers)
                          |
                    TCP listener
                          |
        +-----------------+------------------+
        |  Session / wire protocol layer     |   (09-wire-protocol.md)
        |  one thread per connection         |
        +-----------------+------------------+
                          |  SQL text
        +-----------------+------------------+
        |  Parser        (SQL -> AST)        |
        |  Analyzer      (name resolution,   |   (05-sql-language.md)
        |                 type checking,     |   (06-catalog.md)
        |                 subquery checks)   |
        |  Planner       (AST -> plan tree)  |   (07-planner.md)
        +-----------------+------------------+
                          |  plan tree
        +-----------------+------------------+
        |  Executor (iterator model)         |   (08-executor.md)
        |  SeqScan / IndexScan / Join /      |
        |  Aggregate / Sort / Insert / ...   |
        +-----------------+------------------+
                          |  tuple reads/writes by RID
        +-----------------+------------------+        +----------------+
        |  Heap + B+-tree index            |        | Catalog cache  |
        |                                  |        | (06-catalog)   |
        +-----------------+------------------+        +----------------+
                          |
        +-----------------+------------------+
        |  Transaction manager / lock mgr  |   (03-transactions)
        +-----------------+------------------+
                          |
        +-----------------+------------------+
        |  Buffer pool                     |   (01, 02)
        |  WAL manager                     |
        +-----------------+------------------+
                          |
              data file   +   WAL file  (+ control file)
```

Module boundaries in Haskell follow the same layering. Lower layers never
import upper layers. The storage/WAL/transaction layers know nothing about
SQL; the executor knows nothing about sockets.

## 0.5 Process and thread model

- One OS process per database directory.
- One listener thread accepts TCP connections; each connection is served
  by its own Haskell thread (lightweight thread via `forkIO`).
- All connection threads share one buffer pool, one WAL manager, one
  lock manager and one catalog cache. Shared mutable state is held in
  `MVar`/`TVar` structures owned by the respective manager modules; no
  module reaches into another module's state.
- A session executes one statement at a time (no intra-query parallelism).

## 0.6 Single-process enforcement *(supplementary specification)*

Multiple processes opening the same database files are not supported. To
turn silent corruption into a clear error, the server takes an exclusive
advisory file lock (`flock`) on the control file at startup and refuses to
start if the lock is held. This is a safety guard, not a multi-process
feature.

## 0.7 Durability definition

A transaction is **committed** when the WAL record that marks its commit
has been written to the WAL file and `fsync` (or `fdatasync`) of the WAL
file has completed. Only after that may the server send the commit
completion response to the client.

Consequences implemented by the design:

- **WAL rule**: a data page may be written to the data file only after
  all WAL records describing changes to that page, up to the page's LSN,
  have been flushed to the WAL file (see 02-buffer-pool-wal-recovery.md).
- After a crash, recovery redoes all logged changes and undoes the
  changes of transactions that did not commit, so committed data is
  never lost and uncommitted data never becomes visible
  (see 02-buffer-pool-wal-recovery.md, §2.6).

## 0.8 Files on disk

*(supplementary specification — the requirements mention "the database
file" and the WAL; the concrete split below is the design's choice)*

A database is a directory containing:

| File | Contents |
|------|----------|
| `haskdb.control` | Small control file: format version, `PAGE_SIZE`, checkpoint LSN, next transaction id counter, lock file target |
| `haskdb.data` | The single data file: catalog pages and all table/index pages, addressed by page number |
| `haskdb.wal` | The WAL file (append-only sequence of WAL records) |

Reopening an existing directory must work: all state needed to reopen is
in these files; nothing is kept only in memory across restarts except
caches that are rebuilt during recovery/startup.

WAL segmenting/rotation and data-file-per-table layouts are *not* part of
this design (single files keep the implementation small and readable).

## 0.9 Terminology

- **RID**: record identifier, `(PageId, SlotNumber)`, the physical
  address of a tuple in the heap.
- **LSN**: log sequence number, a monotonically increasing `Word64`
  identifying a WAL record by its byte offset in the WAL file.
- **Page**: fixed-size block of `PAGE_SIZE` bytes in the data file.
- **Tuple**: one row, stored entirely inside one page.
