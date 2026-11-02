# HaskDB Design Documents

This directory contains the detailed design and implementation plan for
**HaskDB**, a small, old-school relational database management system written
in Haskell for study and implementation purposes.

The documents are written in English. File names are in English.

## How to read these documents

| # | Document | Contents |
|---|----------|----------|
| 00 | [00-overview.md](00-overview.md) | Goals, scope, non-goals, system architecture, process/thread model, file layout |
| 01 | [01-storage-engine.md](01-storage-engine.md) | Data file format, slotted pages, tuple format, free-space management |
| 02 | [02-buffer-pool-wal-recovery.md](02-buffer-pool-wal-recovery.md) | Buffer pool, WAL format, checkpointing, crash recovery |
| 03 | [03-transactions-concurrency.md](03-transactions-concurrency.md) | Transaction manager, locking, isolation, deadlock handling |
| 04 | [04-index-btree.md](04-index-btree.md) | B+-tree index design, page format, operations |
| 05 | [05-sql-language.md](05-sql-language.md) | SQL grammar, type system, expression rules per clause, subquery semantics, aggregate semantics |
| 06 | [06-catalog.md](06-catalog.md) | System catalog schema and bootstrap |
| 07 | [07-planner.md](07-planner.md) | Logical/physical plans, join algorithm selection, fixed cost model |
| 08 | [08-executor.md](08-executor.md) | Iterator execution model, operators, sort, aggregation, DML execution |
| 09 | [09-wire-protocol.md](09-wire-protocol.md) | PostgreSQL-compatible wire protocol subset, message flows, error mapping |
| 10 | [10-implementation-plan.md](10-implementation-plan.md) | Phased implementation plan, dependency order, milestones, test strategy |
| 11 | [11-open-decisions.md](11-open-decisions.md) | **Decisions required** — items intentionally left undecided, with options and trade-offs |

## Conventions

- **Normative text** describes the design as specified. Where the original
  requirements were silent and a supplementary rule was needed to make the
  design implementable, the text is marked *(supplementary specification)*.
- Items whose priority or scope the requirements did **not** specify are
  **not** decided in these documents. They are collected in
  [11-open-decisions.md](11-open-decisions.md) with candidate options and
  their pros and cons. Where the main text needs a working assumption to stay
  coherent, it references the decision ID (e.g. "see D-02") and labels the
  assumption as *provisional*.
- "Page size" is written as `PAGE_SIZE` throughout. Its concrete value is a
  decision item (D-01); most of the design is independent of it.
- Type names in small caps (INT64, FLOAT64, VARCHAR, BOOLEAN) refer to HaskDB
  SQL types. Haskell types are written in `monospace`.
