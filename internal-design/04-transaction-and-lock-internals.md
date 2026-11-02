# 04. Transaction Manager and Lock Manager Internals

Refines `design/03-transactions-concurrency.md`. Written against the
provisional strict-2PL baseline (D-02); the interfaces in §4.1/§4.4
are the seam if D-02 changes.

## 4.1 Transaction context

Every executing statement carries a `TxnCtx`:

```haskell
-- Txn.Manager
data TxnCtx = TxnCtx
  { tcEnv     :: Env
  , tcTxnId   :: !TxnId
  , tcState   :: TVar TxnLocalState
  }

data TxnLocalState = TxnLocalState
  { tlsLastLSN  :: !LSN        -- last WAL LSN appended by this txn
                               -- (for wrPrevTxn chaining)
  , tlsUndo     :: [LSN]       -- this txn's change-record LSNs, newest first
  , tlsLocks    :: [LockObject]  -- acquired lock objects (for release)
  , tlsRowCount :: !Int64      -- rows changed by current statement
  }
```

Helper used by all storage-writing code:

```haskell
-- Append a record for this transaction, chaining wrPrevTxn and
-- recording the LSN for undo. All Heap/BTree mutation paths call this
-- instead of Wal.Manager.appendRecord directly.
txnAppend :: TxnCtx -> WalPayload -> IO LSN
```

This single choke point guarantees the `prevTxnLSN` chain and the
in-memory undo list can never desync from the WAL.

## 4.2 Transaction manager

```haskell
data TxnManager = TxnManager
  { tmNextTid :: TVar TxnId     -- initialised from control file at startup
  , tmActive  :: TVar (Map TxnId TxnStatus)
  }

data TxnStatus = TxnActive | TxnCommitting | TxnAborting
  deriving (Eq, Show)

beginTxn    :: Env -> IO TxnCtx
commitTxn   :: TxnCtx -> IO ()
abortTxn    :: TxnCtx -> IO ()
withTxn     :: Env -> (TxnCtx -> IO a) -> IO a
  -- bracket: begin; on exception -> abortTxn and rethrow; on success
  -- the *caller* decides commit (session layer), so withTxn exists in
  -- two forms: withTxnAuto (commit on success) for autocommit
  -- statements, and manual begin/commit for transaction blocks
  -- (document 10).
activeTxnsOldestLSN :: TxnManager -> IO [(TxnId, LSN)]
  -- for checkpoints: each active txn's oldest undo LSN
  -- (head of its reversed undo list = last element of tlsUndo);
  -- sessions register a summary (txnId, IORef LSN) in tmActive's
  -- companion map at beginTxn so the checkpoint does not reach into
  -- session state. Implementation: tmActive maps to
  -- (TxnStatus, IORef LSN) where the IORef is updated by txnAppend.
```

### commitTxn flow

```
1. tls <- read tcState; status := TxnCommitting (in tmActive)
2. lsn <- txnAppend-like append of PCommit (chained, but NOT added to
   the undo list)
3. flushWalUpTo envWal lsn          -- <<< commit point (design/00 0.7)
4. unlockAll lockMgr txnId
5. remove from tmActive
```

### abortTxn flow (live rollback)

```
1. status := TxnAborting
2. for lsn in tlsUndo (newest first):
     rec <- read WAL record at lsn (from WAL file via a read handle;
            records being undone are already appended; they may still
            be only in the WAL buffer — the manager therefore reads
            through WalManager.readRecordAt which consults buffer
            state under the MVar before falling back to the file)
     applyUndo env rec lsn           -- Wal.Recovery's function
3. append PAbort (not chained into undo)
4. unlockAll; remove from tmActive
```

Statement-level rollback (a statement fails inside a transaction
block) uses the same loop with a *statement mark*: `tlsUndo` entries
pushed since the statement began. `TxnLocalState` keeps
`tlsStmtMark :: Int` (length of `tlsUndo` at statement start);
`abortStatement ctx` undoes down to the mark without the `PAbort`
record and without releasing locks acquired before the statement
(locks acquired *by* the failed statement are released — they are
exactly the `tlsLocks` entries added since a parallel lock mark).

## 4.3 Deadlock policy seam

```haskell
-- Txn.LockManager exports the wait-for relation:
waitForEdges :: LockManager -> IO [(TxnId, TxnId)]  -- waiter -> holder

-- Txn.Manager runs (if D-12 = detection) a background thread:
--   every 1s: build graph from waitForEdges, find a cycle,
--   abortTxn the youngest txnId in the cycle with errDeadlock
--   delivered into its session via its TxnCtx exception channel
--   (an IORef (Maybe SqlError) checked by lock waits and statement
--   boundaries — a blocked lock waiter must wake: lock acquisition
--   races the channel with STM `orElse` on a TVar flag).
```

Timeout policy (if D-12 = timeout) needs no graph: lock waits use
`System.Timeout`-equivalent STM deadline and throw `55P03`.

## 4.4 Lock manager (`Txn.LockManager`)

```haskell
data LockObject
  = LTable !RelId
  | LRow   !RelId !RID
  deriving (Eq, Ord, Show)

data LockMode = LIs | LIx | LS | LX   -- intention-shared, intention-excl,
                                      -- shared, exclusive
  deriving (Eq, Show)

modeConflict :: LockMode -> LockMode -> Bool
-- standard matrix:
--        req:  IS   IX   S    X
-- granted IS    .    .    .    X
--         IX    .    .    X    X
--         S     .    X    .    X
--         X     X    X    X    X

data LockManager = LockManager
  { lmTable :: TVar (Map LockObject LockEntry) }

data LockEntry = LockEntry
  { leGranted :: !(Map TxnId LockMode)     -- strongest mode per txn
  , leWaiters :: [(TxnId, LockMode, TVar Bool)]  -- FIFO; the TVar is
                               -- flipped True when granted. Waiters block
                               -- in STM on their own TVar + entry changes.
  }

lock    :: LockManager -> TxnCtx -> LockObject -> LockMode -> IO ()
unlockAll :: LockManager -> TxnId -> IO ()
```

### lock flow (STM)

```
lock lm ctx obj mode:
  -- fast path & queueing are one STM transaction:
  atomically:
    entry := lmTable[obj] (default empty)
    myGranted := entry.granted[txn]
    if myGranted covers mode (same or stronger in the lattice
       IS < {S, IX} < X with S and IX incomparable — coverage means:
       granted == requested, or granted == X, or (granted == IX and
       requested == IS), or (granted == S and requested == IS)):
         return ()   -- already held
    if no conflicting granted mode (excluding my own) AND
       no earlier waiter conflicts with mode:
         grant: entry.granted[txn] := combine(myGranted, mode)
         record obj in ctx.tlsLocks if newly granted
         return ()
    else:
         enqueue (txn, mode, myFlag) if not already queued
         check myFlag; if False -> retry    -- blocks until a release
                                            -- or grant flips state
  -- abort channel race (sect 4.3): the STM transaction also reads the
  -- txn's abort TVar; if set, it throws outside atomically via a
  -- captured IORef check loop around the wait. Implementation detail:
  -- lockWait wraps atomically in a loop with the abort flag as an
  -- STM-read TVar so `retry` wakes on either event.
```

`unlockAll` removes the txn from every granted map and waiter queue
(objects listed in `tlsLocks` plus a scan for waiter entries — the
waiter scan is over `tlsLocks`-adjacent bookkeeping kept in the lock
manager as `lmWaitIndex :: TVar (Map TxnId [LockObject])` to avoid
scanning the whole table), then for each touched entry grants newly
unblocked waiters in FIFO order (skipping a waiter whose mode still
conflicts, but not granting later waiters that conflict with an
earlier still-blocked waiter — fairness rule of design/03 §3.4).

### Standard lock call sites

| Operation | Table lock | Row locks |
|-----------|-----------|-----------|
| SELECT (scan) | `IS` on each FROM table | `S` per returned tuple |
| INSERT | `IX` | `X` on new RID |
| UPDATE/DELETE | `IX` | `S` while scanning, upgrade to `X` on targets |
| CREATE INDEX | `X` on the table | — |
| CREATE TABLE | `X` on the new table's own (fresh) relid (trivially uncontended) | — |

Lock upgrade S→X within `lock` is handled by the coverage check plus
conflict check excluding other holders: if another txn also holds S,
the upgrade queues — the classic upgrade-deadlock case, resolved by
the D-12 policy.

## 4.5 What the transaction layer guarantees to upper layers

- After `commitTxn` returns, the transaction's changes are durable
  (WAL fsynced) and its locks are released.
- After `abortTxn`/`abortStatement`, none of the (statement's) changes
  are visible in any page, and recovery would reach the same state.
- `txnAppend` is the only way WAL records for a transaction are
  created; ad-hoc `appendRecord` calls exist only for CHECKPOINT
  (txn 0) and recovery-time checkpoint.
