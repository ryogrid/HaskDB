------------------------------ MODULE HaskDB ------------------------------
(***************************************************************************)
(* TLA+ model of HaskDB's transaction machinery at the level of its      *)
(* documented design (design/03-transactions-concurrency.md) and its     *)
(* implementation (src/HaskDB/Txn, src/HaskDB/Heap,                      *)
(* src/HaskDB/Executor).                                                 *)
(*                                                                       *)
(* Abstraction:                                                          *)
(*  - A "key" is a row identity (RID). HaskDB has no PRIMARY KEY /       *)
(*    UNIQUE constraints (design/05 grammar), so rows are identified     *)
(*    by RID, not by a user key. One key (AbsentKey) starts absent so    *)
(*    that INSERT (creation of a row) can be modelled.                   *)
(*  - The implementation updates heap pages in place under an X lock     *)
(*    with WAL before-images (steal/no-force). Because the X lock is     *)
(*    taken BEFORE the page is touched (Heap.hs header) and held to      *)
(*    end of transaction, no other transaction can observe or overwrite  *)
(*    the uncommitted value, and abort restores the before-image. The    *)
(*    observable behaviour is therefore identical to a private write     *)
(*    buffer applied atomically at the commit point (the WAL flush,     *)
(*    design/02 SS2.4). This model uses the buffer presentation: `db`     *)
(*    holds committed state only and changes only in the Commit action.  *)
(*  - Locking is strict 2PL exactly as specified: S on read, X on        *)
(*    write, S->X upgrade only when no other transaction holds a         *)
(*    conflicting lock, all locks held until commit/abort. A lock        *)
(*    request that cannot be granted disables the action (the            *)
(*    transaction waits); a waiting transaction may still commit what    *)
(*    it has or abort -- in the implementation the deadlock detector     *)
(*    (Txn/Deadlock.hs: wait-for cycle -> abort youngest, SQLSTATE       *)
(*    40P01) or the client can always end a waiting transaction.         *)
(*  - A scan (SELECT over the table / a range) S-locks every row it      *)
(*    returns (Executor queueNext / heapFetch). Rows that do not exist   *)
(*    (and key ranges / gaps) are NOT locked: design/03 SS3.2 states      *)
(*    index key ranges are not locked and phantoms are possible.         *)
(*    The scan is modelled as one atomic action; the implementation     *)
(*    locks row by row, which is discussed in the report.                *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Txns,        \* set of transaction ids (model values)
          Keys,        \* set of row identities
          Vals,        \* set of storable values
          AbsentKey,   \* the key that is absent in the initial state
          InitVal,     \* value of every initially present key
          NoVal,       \* "no row" marker (distinct from every value)
          None,        \* "no buffered write / never read" marker
          NoTxn        \* "no lock holder" marker

ASSUME AbsentKey \in Keys
ASSUME InitVal \in Vals
ASSUME NoVal \notin Vals
ASSUME None \notin Vals \cup {NoVal}
ASSUME NoTxn \notin Txns

VARIABLES db,            \* committed state: Keys -> Vals \cup {NoVal}
          status,        \* Txns -> {"idle","active","committed","aborted"}
          locksS,        \* Keys -> SUBSET Txns   (granted S holders)
          locksX,        \* Keys -> Txns \cup {NoTxn} (granted X holder)
          wbuf,          \* Txns -> Keys -> Vals \cup {NoVal, None}
          firstExtRead,  \* Txns -> Keys -> Vals \cup {NoVal, None} (history)
          readSeq,       \* Txns -> Keys -> Nat  (commit count at first read)
          scanSeen,      \* Txns -> BOOLEAN      (history)
          firstScan,     \* Txns -> SUBSET Keys  (history: first scan result)
          committedVals, \* Keys -> SUBSET (Vals \cup {NoVal}) (history)
          cWrites,       \* Txns -> Keys -> Vals \cup {NoVal, None} (at commit)
          cOrd,          \* Txns -> Nat (commit order, 0 = not committed)
          commitCnt,     \* Nat
          lastWSeq,      \* Keys -> Nat (commit count of last commit writing k)
          badNRR,        \* BOOLEAN flag: non-repeatable read observed
          badLU,         \* BOOLEAN flag: stale-read write (lost update) observed
          phantom        \* BOOLEAN flag: phantom observed

vars == <<db, status, locksS, locksX, wbuf, firstExtRead, readSeq,
          scanSeen, firstScan, committedVals, cWrites, cOrd, commitCnt,
          lastWSeq, badNRR, badLU, phantom>>

InitDb == [k \in Keys |-> IF k = AbsentKey THEN NoVal ELSE InitVal]

Init ==
  /\ db = InitDb
  /\ status = [t \in Txns |-> "idle"]
  /\ locksS = [k \in Keys |-> {}]
  /\ locksX = [k \in Keys |-> NoTxn]
  /\ wbuf = [t \in Txns |-> [k \in Keys |-> None]]
  /\ firstExtRead = [t \in Txns |-> [k \in Keys |-> None]]
  /\ readSeq = [t \in Txns |-> [k \in Keys |-> 0]]
  /\ scanSeen = [t \in Txns |-> FALSE]
  /\ firstScan = [t \in Txns |-> {}]
  /\ committedVals = [k \in Keys |-> {InitDb[k]}]
  /\ cWrites = [t \in Txns |-> [k \in Keys |-> None]]
  /\ cOrd = [t \in Txns |-> 0]
  /\ commitCnt = 0
  /\ lastWSeq = [k \in Keys |-> 0]
  /\ badNRR = FALSE
  /\ badLU = FALSE
  /\ phantom = FALSE

Active(t) == status[t] = "active"

\* S can be granted iff no OTHER transaction holds X (impl: heapFetch /
\* queueNext take LS and block behind a writer's LX).
CanS(t, k) == locksX[k] = NoTxn \/ locksX[k] = t

\* X can be granted iff no other transaction holds X, and no other
\* transaction holds S (impl: compatible + FIFO rule in LockManager;
\* an S holder upgrading must be the sole remaining holder, design/03 SS3.2).
CanX(t, k) == (locksX[k] = NoTxn \/ locksX[k] = t) /\ locksS[k] \subseteq {t}

\* The value of k as seen by t: own buffered write wins, else committed.
EffVal(t, k) == IF wbuf[t][k] /= None THEN wbuf[t][k] ELSE db[k]

ReleaseLocks(t) ==
  /\ locksS' = [k \in Keys |-> locksS[k] \ {t}]
  /\ locksX' = [k \in Keys |-> IF locksX[k] = t THEN NoTxn ELSE locksX[k]]

-----------------------------------------------------------------------------

Begin(t) ==
  /\ status[t] = "idle"
  /\ status' = [status EXCEPT ![t] = "active"]
  /\ UNCHANGED <<db, locksS, locksX, wbuf, firstExtRead, readSeq, scanSeen,
                 firstScan, committedVals, cWrites, cOrd, commitCnt,
                 lastWSeq, badNRR, badLU, phantom>>

\* Point read of a key the transaction has not written itself.
\* (Reads of own writes return the buffered value by construction and
\* cannot violate any isolation rule; they are not separate actions.)
\* A read of an existing row takes S on it (heapFetch). A read that
\* finds no row takes NO lock: there is no RID to lock, and the
\* implementation locks nothing for a miss. A row that appears at the
\* same identity afterwards is therefore a phantom-class event, not a
\* non-repeatable read; the two flags are kept separate.
Read(t, k) ==
  /\ Active(t)
  /\ wbuf[t][k] = None
  /\ CanS(t, k)
  /\ locksS' =
       IF db[k] /= NoVal
         THEN [locksS EXCEPT ![k] = @ \cup {t}]
         ELSE locksS
  /\ firstExtRead' =
       IF firstExtRead[t][k] = None
         THEN [firstExtRead EXCEPT ![t][k] = db[k]]
         ELSE firstExtRead
  /\ readSeq' =
       IF firstExtRead[t][k] = None
         THEN [readSeq EXCEPT ![t][k] = commitCnt]
         ELSE readSeq
  /\ badNRR' = IF firstExtRead[t][k] /= None /\ firstExtRead[t][k] /= NoVal
                    /\ db[k] /= firstExtRead[t][k]
                  THEN TRUE ELSE badNRR
  /\ phantom' = IF firstExtRead[t][k] = NoVal /\ db[k] /= NoVal
                  THEN TRUE ELSE phantom
  /\ UNCHANGED <<db, status, locksX, wbuf, scanSeen, firstScan,
                 committedVals, cWrites, cOrd, commitCnt, lastWSeq,
                 badLU>>

\* The set of keys a scan by t returns (own writes applied).
PresentSet(t) == {k \in Keys : EffVal(t, k) /= NoVal}

\* Does the current scan by t differ from t's first scan in a key t
\* itself never wrote? (Phantom test, see Scan.)
ScanDiffers(t) ==
  \E k \in Keys :
    /\ wbuf[t][k] = None
    /\ (k \in PresentSet(t)) /= (k \in firstScan[t])

\* Full scan (a SELECT / range scan over all keys). Locks S on every
\* row that exists in the committed state; absent keys are not locked.
\* Records the set of present keys; a later scan of the same transaction
\* whose present-set differs in a key the transaction itself never
\* wrote is a phantom.
Scan(t) ==
  /\ Active(t)
  /\ \A k \in Keys : db[k] /= NoVal => CanS(t, k)
  /\ locksS' = [k \in Keys |->
                  IF EffVal(t, k) /= NoVal /\ wbuf[t][k] = None
                    THEN locksS[k] \cup {t}
                    ELSE locksS[k]]
  /\ scanSeen' = [scanSeen EXCEPT ![t] = TRUE]
  /\ firstScan' =
       IF scanSeen[t] THEN firstScan
       ELSE [firstScan EXCEPT ![t] = PresentSet(t)]
  /\ phantom' = IF scanSeen[t] /\ ScanDiffers(t) THEN TRUE ELSE phantom
  /\ UNCHANGED <<db, status, locksX, wbuf, firstExtRead, readSeq,
                 committedVals, cWrites, cOrd, commitCnt, lastWSeq,
                 badNRR, badLU>>

\* INSERT of a new row into the absent slot k. The implementation takes
\* IX on the table and X on the fresh RID before writing it
\* (Heap.placeLocked), so a pending insert blocks other writers of the
\* same slot but never conflicts with scans of existing rows.
Insert(t, k, v) ==
  /\ Active(t)
  /\ db[k] = NoVal
  /\ wbuf[t][k] = None
  /\ CanX(t, k)
  /\ locksX' = [locksX EXCEPT ![k] = t]
  /\ wbuf' = [wbuf EXCEPT ![t][k] = v]
  /\ UNCHANGED <<db, status, locksS, firstExtRead, readSeq, scanSeen,
                 firstScan, committedVals, cWrites, cOrd, commitCnt,
                 lastWSeq, badNRR, badLU, phantom>>

\* UPDATE of an existing row: X lock (upgrade from S if the transaction
\* read the row first). The stale-write flag records a write by a
\* transaction whose earlier external read of the same key has since
\* been overtaken by another transaction's committed write -- the
\* lost-update pattern. Under strict 2PL this cannot happen: the
\* reader's S lock blocks the other writer until the reader ends.
Write(t, k, v) ==
  /\ Active(t)
  /\ EffVal(t, k) /= NoVal
  /\ CanX(t, k)
  /\ locksX' = [locksX EXCEPT ![k] = t]
  /\ wbuf' = [wbuf EXCEPT ![t][k] = v]
  /\ badLU' = IF firstExtRead[t][k] /= None /\ firstExtRead[t][k] /= NoVal
                    /\ lastWSeq[k] > readSeq[t][k]
                  THEN TRUE ELSE badLU
  /\ UNCHANGED <<db, status, locksS, firstExtRead, readSeq, scanSeen,
                 firstScan, committedVals, cWrites, cOrd, commitCnt,
                 lastWSeq, badNRR, phantom>>

\* DELETE of an existing row: X lock, buffered removal.
Delete(t, k) ==
  /\ Active(t)
  /\ EffVal(t, k) /= NoVal
  /\ CanX(t, k)
  /\ locksX' = [locksX EXCEPT ![k] = t]
  /\ wbuf' = [wbuf EXCEPT ![t][k] = NoVal]
  /\ badLU' = IF firstExtRead[t][k] /= None /\ firstExtRead[t][k] /= NoVal
                    /\ lastWSeq[k] > readSeq[t][k]
                  THEN TRUE ELSE badLU
  /\ UNCHANGED <<db, status, locksS, firstExtRead, readSeq, scanSeen,
                 firstScan, committedVals, cWrites, cOrd, commitCnt,
                 lastWSeq, badNRR, phantom>>

\* COMMIT: the write set is applied to the committed state in one
\* atomic step (the model's image of the WAL-flush commit point,
\* design/02 SS2.4 step 3 / Txn.Manager.commitTxn); locks are released
\* only after that point (strictness).
Commit(t) ==
  /\ Active(t)
  /\ db' = [k \in Keys |->
              IF wbuf[t][k] /= None THEN wbuf[t][k] ELSE db[k]]
  /\ status' = [status EXCEPT ![t] = "committed"]
  /\ ReleaseLocks(t)
  /\ commitCnt' = commitCnt + 1
  /\ cOrd' = [cOrd EXCEPT ![t] = commitCnt + 1]
  /\ cWrites' = [cWrites EXCEPT ![t] = wbuf[t]]
  /\ lastWSeq' = [k \in Keys |->
                    IF wbuf[t][k] /= None THEN commitCnt + 1 ELSE lastWSeq[k]]
  /\ committedVals' = [k \in Keys |->
                         IF wbuf[t][k] /= None
                           THEN committedVals[k] \cup {wbuf[t][k]}
                           ELSE committedVals[k]]
  /\ UNCHANGED <<wbuf, firstExtRead, readSeq, scanSeen, firstScan,
                 badNRR, badLU, phantom>>

\* ROLLBACK / abort (explicit rollback, statement error at transaction
\* level, deadlock victim): buffered writes are discarded, the
\* committed state is untouched, locks are released. In the
\* implementation this is before-image undo (Txn.Manager.abortTxn);
\* because uncommitted values were never visible to others, discarding
\* the buffer is observationally the same.
Abort(t) ==
  /\ Active(t)
  /\ status' = [status EXCEPT ![t] = "aborted"]
  /\ ReleaseLocks(t)
  /\ UNCHANGED <<db, wbuf, firstExtRead, readSeq, scanSeen, firstScan,
                 committedVals, cWrites, cOrd, commitCnt, lastWSeq,
                 badNRR, badLU, phantom>>

\* Explicit termination action so that states in which every
\* transaction has finished are not reported as deadlocks.
Done ==
  /\ \A t \in Txns : status[t] \in {"committed", "aborted"}
  /\ UNCHANGED vars

Next ==
  \/ \E t \in Txns :
       \/ Begin(t)
       \/ Commit(t)
       \/ Abort(t)
       \/ Scan(t)
       \/ \E k \in Keys :
            \/ Read(t, k)
            \/ Delete(t, k)
            \/ \E v \in Vals : \/ Write(t, k, v)
                               \/ Insert(t, k, v)
  \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

TypeOK ==
  /\ db \in [Keys -> Vals \cup {NoVal}]
  /\ status \in [Txns -> {"idle", "active", "committed", "aborted"}]
  /\ locksS \in [Keys -> SUBSET Txns]
  /\ locksX \in [Keys -> Txns \cup {NoTxn}]
  /\ commitCnt \in Nat

\* Lock-table consistency: an X holder excludes other holders, and
\* locks are only ever held by active transactions (released at
\* commit/abort before the status changes become visible).
LockSafety ==
  /\ \A k \in Keys :
       locksX[k] /= NoTxn => locksS[k] \subseteq {locksX[k]}
  /\ \A k \in Keys :
       locksX[k] /= NoTxn => status[locksX[k]] = "active"
  /\ \A k \in Keys, t \in Txns :
       t \in locksS[k] => status[t] = "active"

\* No dirty read: every value a transaction has read from outside its
\* own write set is a value that was committed (initial state counts
\* as committed) at the time it could have been read.
NoDirtyRead ==
  \A t \in Txns, k \in Keys :
    firstExtRead[t][k] /= None => firstExtRead[t][k] \in committedVals[k]

\* Repeatable read (point): no transaction ever re-read a key and saw
\* a different value than its first read (own writes excluded).
NoNonRepeatableRead == ~badNRR

\* No lost update: no transaction ever wrote a key whose existing
\* value it had read and which another transaction's commit had
\* since changed. (Reading the ABSENCE of a row and later writing a
\* row that another transaction inserted in between is the phantom
\* pattern, not a lost update: the writer re-fetches the row at
\* write time. The badLU flag is therefore only about keys whose
\* existing value was read.)
NoLostUpdate == ~badLU

\* Phantom freedom (strict reading of REPEATABLE READ): no repeated
\* scan ever changed its result set in a key the scanning transaction
\* itself did not write. Expected to be VIOLATED in this design:
\* design/03 SS3.2 states key ranges are not locked.
NoPhantom == ~phantom

\* Atomic commit + rollback correctness: the committed state is at
\* all times exactly the result of applying, in commit order, the
\* complete write sets of committed transactions to the initial
\* state. Aborted and active transactions contribute nothing; a
\* committed transaction contributes all of its writes or (if a later
\* commit overwrote the key) is shadowed only by later commits.
AtomicCommit ==
  \A k \in Keys :
    LET writers == {t \in Txns : cOrd[t] > 0 /\ cWrites[t][k] /= None}
    IN  db[k] =
          IF writers = {}
            THEN InitDb[k]
            ELSE cWrites[CHOOSE t \in writers :
                           \A u \in writers : cOrd[u] <= cOrd[t]][k]

\* Symmetry for TLC state reduction.
TxnPerms == Permutations(Txns)

=============================================================================
