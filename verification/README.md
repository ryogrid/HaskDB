# HaskDB Formal Verification (TLA+)

This directory holds a TLA+ model-checking study of HaskDB, created on
2026-11-17. It covers two questions:

1. **External operations** — are the operations defined by HaskDB's external
   specification (the SQL surface: `BEGIN` / `COMMIT` / `ROLLBACK`, `SELECT`,
   `INSERT`, `UPDATE`, `DELETE`, DDL) free of specification-level problems
   (ambiguous or inconsistent behaviour, lost updates at the stated isolation
   level, non-atomic commit, and similar)?
2. **Isolation level** — does the transaction machinery, specified as
   REPEATABLE READ and implemented with strict two-phase locking, actually
   exclude the phenomena that REPEATABLE READ forbids (dirty read,
   non-repeatable read, and — depending on the definition used — phantom)?

## Layout

- `spec/` — TLA+ modules and TLC configuration files.
- `report/` — the verification report (English Markdown).
- `results/` — raw TLC output logs for every run cited in the report.

## Method (summary)

The TLA+ model abstracts the implementation at the level of its documented
design: strict 2PL with S/X locks held to commit (design/03), an STM-based
lock table, WAL-backed atomic commit/abort with undo. TLC then exhaustively
explores small configurations (a few transactions, a few keys) checking
invariants that encode the REPEATABLE READ rules and the atomicity /
consistency expectations of the external operations. Any counterexample
trace is reproduced in the report and mapped back to the design/implementation
concept it corresponds to.

Full details, scope limits, and findings: see `report/`.
