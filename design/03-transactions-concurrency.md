# 03. Transactions and Concurrency

## 3.1 Model

- Transactions are executed by session threads inside one process.
- A transaction is a sequence of statements ended by commit or rollback.
- Statements are atomic: a failed statement leaves no partial changes
  (its changes are undone before the error is reported).
- Outside an explicit transaction block, every statement runs in its
  own implicit transaction (autocommit). Explicit blocks are described
  in 09-wire-protocol.md §9.5. *(The requirements speak of "commit" and
  concurrent transactions but do not enumerate `BEGIN`/`COMMIT`
  statements; supporting them as session-level commands is a
  supplementary specification, flagged as decision item **D-17** in the
  sense that their exact surface syntax follows PostgreSQL.)*

## 3.2 Concurrency control: locking baseline

The concurrency-control *scheme* is decision item **D-02** (options:
strict two-phase locking, MVCC/snapshot isolation, single-writer
serialisation). This document specifies the **provisional baseline**:
strict two-phase locking (S2PL) with row-level locks, because it is the
classical textbook scheme, matches the "no tuple versioning" storage
design (01 §1.3), and makes the recovery design in 02 sufficient without
version chains. If D-02 is decided otherwise, this document and parts of
01/02 must be revisited; the lock-manager *interface* in §3.4 is the
stable seam.

Under S2PL:

- All locks are held until commit/rollback (strictness gives
  cascadeless rollback with plain before-image undo).
- Reads take shared locks; writes take exclusive locks; lock upgrade
  (S → X) is allowed when the transaction is the only holder.

### Lockable objects and modes

| Object | Modes | Use |
|--------|-------|-----|
| Table (relation) | `IS`, `IX`, `S`, `X` (intention modes) | DDL takes `X` on the table; DML takes intention modes so DDL and DML exclude each other correctly |
| Row (RID) | `S`, `X` | tuple reads/writes |
| Index key range | — | **not locked** (see below) |

Index structures are protected only by short-term page content locks
(02 §2.1), not by transaction locks. **Phantom anomalies are therefore
possible under the baseline**: a repeated range scan can see rows
inserted by a concurrently committed transaction. Preventing phantoms
would require predicate/key-range locking or MVCC; whether any
isolation guarantee beyond the baseline is required is part of D-02/D-03
(the requirements do not name an isolation level).

### Isolation provided by the baseline *(supplementary specification)*

With strict 2PL and row locks held to end of transaction, the baseline
provides the equivalent of **REPEATABLE READ for row accesses** (no
dirty reads, no non-repeatable row reads, no lost updates), with
phantoms possible as described above. A weaker/faster mode (locks
released after each statement for reads, i.e. READ COMMITTED style) is
listed as an option in D-03, not implemented by default.

## 3.3 Transaction manager

```haskell
data TxnManager = TxnManager
  { tmNextTid  :: TVar Word64
  , tmActive   :: TVar (Map TxnId TxnState)
  }

data TxnState = TxnState
  { tsId        :: TxnId
  , tsStatus    :: TxnStatus          -- Active | Committing | Aborting
  , tsUndoLog   :: [WalLSN]           -- LSNs of this txn's change records, newest first (in memory)
  , tsLocks     :: [LockRef]          -- held locks, for release
  , tsSavepoints :: ...               -- not supported; see below
  }
```

- `beginTxn :: IO TxnId` — allocate id, register as active.
- `commitTxn` — WAL commit protocol (02 §2.4); locks are released only
  after the WAL flush completes (strictness).
- `abortTxn` — undo using before-images in reverse LSN order (the same
  code path as recovery undo, operating on buffer-pool pages), append
  `ABORT`, release locks.
- Savepoints are **not** supported (not in the requirements; the
  statement-atomicity rule of §3.1 replaces their main use).
- Transaction ids are `Word64`, persisted via the control file
  (`nextTid`) so ids never repeat across restarts (they appear in WAL
  records and must stay unique per WAL lifetime).

The in-memory undo list is possible because a transaction's own changes
are undone from the buffer pool while the server is alive; after a
crash, recovery re-derives undo information from the WAL itself
(02 §2.6, `prevTxnLSN` chaining).

## 3.4 Lock manager

```haskell
data LockManager = LockManager
  { lmTable :: TVar (Map LockObject LockEntry) }

data LockEntry = LockEntry
  { leGranted :: Map TxnId LockMode
  , leWaiters :: Queue (TxnId, LockMode, TMVar Bool)  -- STM-based wait
  }
```

- Locking/unlocking is implemented with STM: a request either grants
  immediately (compatible with all granted modes and no earlier
  incompatible waiter — FIFO fairness to avoid writer starvation) or
  blocks by `retry` on the entry's TVar state.
- Mode compatibility follows the standard IS/IX/S/X matrix.
- `lockRow txn rid mode`, `lockTable txn rel mode`,
  `unlockAll txn` are the only entry points; the executor calls them
  through the transaction context, never directly on the TVar map.

## 3.5 Deadlocks

Deadlock handling strategy is decision item **D-12** (options:
wait-for-graph detection with victim selection, lock wait timeout,
prevention schemes such as wait-die). Some mechanism is mandatory: with
row locking and lock upgrades, deadlock is reachable
(e.g. two transactions updating each other's next row).

The design keeps the lock manager independent of the policy:

- The lock manager records, for every waiting transaction, the set of
  transactions it waits for (derivable from granted holders).
- A policy module either (a) runs periodic cycle detection and aborts
  the youngest transaction in the cycle, or (b) aborts waiters after a
  timeout. The aborted transaction receives SQLSTATE `40P01`
  (deadlock) in case (a) or `55P03` (lock not available) in case (b).

## 3.6 Interaction with DDL

`CREATE TABLE` / `CREATE INDEX` run inside a transaction like DML
(catalog changes are WAL-logged, 02 §2.3). They take an `X` lock on the
(affected/new) table, which excludes concurrent DML on it for the
duration of the statement. Because DDL is rare and the system is
single-user, no attempt is made to allow concurrent DML during index
builds: `CREATE INDEX` scans the table under its table lock and builds
the index before committing.

## 3.7 What concurrency does *not* cover

- Two server processes on the same files: excluded by the startup file
  lock (00 §0.6).
- Two statements of one session running in parallel: a session is
  strictly sequential.
- Distributed transactions, two-phase commit: out of scope entirely.
