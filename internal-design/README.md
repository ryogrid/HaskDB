# HaskDB Internal Design Documents

These documents refine the documents in `design/` down to the level an
implementer needs to start writing code without making further design
decisions: concrete Haskell data structures, module boundaries, function
signatures, invariants, and step-by-step processing flows.

Reading order: implementers should read the relevant `design/` document
first (the *what* and *why*), then the matching internal document (the
*how*). If the two disagree, `design/` wins for semantics and this
directory wins for code structure; report the discrepancy instead of
silently choosing.

| # | Document | Code modules |
|---|----------|--------------|
| 00 | [00-common-types-and-conventions.md](00-common-types-and-conventions.md) | `HaskDB.Common.*`, package layout, config, error handling |
| 01 | [01-page-and-tuple-internals.md](01-page-and-tuple-internals.md) | `HaskDB.Storage.Page`, `HaskDB.Heap.TupleCodec`, `HaskDB.Storage.FileManager`, `HaskDB.Storage.FreeSpace` |
| 02 | [02-buffer-pool-internals.md](02-buffer-pool-internals.md) | `HaskDB.Storage.BufferPool` |
| 03 | [03-wal-and-recovery-internals.md](03-wal-and-recovery-internals.md) | `HaskDB.Wal.Format`, `HaskDB.Wal.Manager`, `HaskDB.Wal.Recovery` |
| 04 | [04-transaction-and-lock-internals.md](04-transaction-and-lock-internals.md) | `HaskDB.Txn.Manager`, `HaskDB.Txn.LockManager` |
| 05 | [05-btree-internals.md](05-btree-internals.md) | `HaskDB.Index.BTree` |
| 06 | [06-catalog-internals.md](06-catalog-internals.md) | `HaskDB.Catalog.Types`, `HaskDB.Catalog.Cache`, `HaskDB.Catalog.Bootstrap` |
| 07 | [07-sql-frontend-internals.md](07-sql-frontend-internals.md) | `HaskDB.Sql.Lexer`, `HaskDB.Sql.Parser`, `HaskDB.Sql.Ast`, `HaskDB.Sql.Analyzer` |
| 08 | [08-planner-internals.md](08-planner-internals.md) | `HaskDB.Planner.Planner`, `HaskDB.Planner.CostModel` |
| 09 | [09-executor-internals.md](09-executor-internals.md) | `HaskDB.Executor.*` |
| 10 | [10-wire-protocol-internals.md](10-wire-protocol-internals.md) | `HaskDB.Server.Wire`, `HaskDB.Server.Session` |
| 11 | [11-server-startup-and-config.md](11-server-startup-and-config.md) | `app/Main.hs`, `HaskDB.Server.Listener`, startup/shutdown flows |

## Global rules for implementers

1. **No lazy I/O anywhere in storage/WAL/server code.** All file and
   socket payloads are strict `ByteString`s.
2. **All page access goes through the buffer pool.** No module except
   `FileManager`, `Wal.Manager`, and startup/recovery code touches
   file handles for the data file.
3. **Every mutation of a page is preceded by its WAL record** being
   appended (the WAL manager's flush rules in document 03 enforce the
   rest). There is no legitimate call path that mutates a pinned page
   before appending the corresponding WAL record.
4. **Errors are `SqlError` exceptions** (document 00 §0.4). Storage
   layer functions throw; the session layer catches and maps to the
   wire protocol.
5. Provisional values inherited from `design/11-open-decisions.md`
   (page size, memory budget, buffer frames, …) live **only** in the
   `Config` record / control file (document 00 §0.3, document 11).
   Never hard-code them inside algorithms.
