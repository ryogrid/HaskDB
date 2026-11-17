--------------------------- MODULE HaskDBDeadlock ---------------------------
(***************************************************************************)
(* Focused deadlock model for HaskDB's strict 2PL (design/03 SS3.5).     *)
(*                                                                       *)
(* Two transactions run FIXED scripts that take X locks in opposite      *)
(* order -- the classic reachable deadlock the design document itself    *)
(* calls out ("two transactions updating each other's next row"):        *)
(*   d1: X(a) -> X(b) -> COMMIT                                          *)
(*   d2: X(b) -> X(a) -> COMMIT                                          *)
(* Younger == larger transaction id: d2 began after d1.                  *)
(*                                                                       *)
(* The constant UseDetector selects the configuration:                   *)
(*  - FALSE: no deadlock policy. TLC's deadlock check must find the      *)
(*    state in which d1 holds a and waits for b while d2 holds b and     *)
(*    waits for a.                                                       *)
(*  - TRUE: the implemented policy (src/HaskDB/Txn/Deadlock.hs,         *)
(*    D-12 = wait-for cycle detection + abort youngest victim,           *)
(*    SQLSTATE 40P01). A DetectorAbort action is enabled exactly when    *)
(*    a wait-for cycle exists and aborts the youngest member (d2).       *)
(*    TLC must then find no deadlock, and the invariant says the         *)
(*    detector never aborts both transactions for one cycle.             *)
(***************************************************************************)
EXTENDS Naturals, TLC

CONSTANT UseDetector   \* BOOLEAN, set by the .cfg file

Txns == {"d1", "d2"}
KeysD == {"a", "b"}
Youngest == "d2"       \* max tid, the design's victim choice

FirstKey  == [d1 |-> "a", d2 |-> "b"]
SecondKey == [d1 |-> "b", d2 |-> "a"]

VARIABLES pc,       \* Txns -> 0..4 : 0 need 1st, 1 need 2nd, 2 commit,
                    \*              3 committed, 4 aborted
          xholder   \* KeysD -> Txns \cup {"none"}

vars == <<pc, xholder>>

Init ==
  /\ pc = [t \in Txns |-> 0]
  /\ xholder = [k \in KeysD |-> "none"]

AcquireFirst(t) ==
  /\ pc[t] = 0
  /\ xholder[FirstKey[t]] = "none"
  /\ xholder' = [xholder EXCEPT ![FirstKey[t]] = t]
  /\ pc' = [pc EXCEPT ![t] = 1]

AcquireSecond(t) ==
  /\ pc[t] = 1
  /\ xholder[SecondKey[t]] = "none"
  /\ xholder' = [xholder EXCEPT ![SecondKey[t]] = t]
  /\ pc' = [pc EXCEPT ![t] = 2]

CommitD(t) ==
  /\ pc[t] = 2
  /\ xholder' = [k \in KeysD |-> IF xholder[k] = t THEN "none" ELSE xholder[k]]
  /\ pc' = [pc EXCEPT ![t] = 3]

\* t waits for u iff t's next lock is currently X-held by u.
WaitsFor(t, u) ==
  \/ (pc[t] = 0 /\ xholder[FirstKey[t]] = u)
  \/ (pc[t] = 1 /\ xholder[SecondKey[t]] = u)

CycleExists == \E t, u \in Txns : t /= u /\ WaitsFor(t, u) /\ WaitsFor(u, t)

\* The deadlock policy of Txn/Deadlock.hs: on a wait-for cycle, signal
\* the youngest transaction in the cycle; its lock wait wakes with
\* 40P01 and the session rolls it back, releasing its locks.
DetectorAbort ==
  /\ UseDetector
  /\ CycleExists
  /\ pc[Youngest] \in {0, 1}
  /\ xholder' = [k \in KeysD |->
                   IF xholder[k] = Youngest THEN "none" ELSE xholder[k]]
  /\ pc' = [pc EXCEPT ![Youngest] = 4]

\* Explicit termination so finished states are not deadlocks.
DoneD ==
  /\ \A t \in Txns : pc[t] \in {3, 4}
  /\ UNCHANGED vars

Next ==
  \/ \E t \in Txns : AcquireFirst(t) \/ AcquireSecond(t) \/ CommitD(t)
  \/ DetectorAbort
  \/ DoneD

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ pc \in [Txns -> 0..4]
  /\ xholder \in [KeysD -> Txns \cup {"none"}]

\* One victim per cycle suffices: the detector never aborts both.
AtMostOneVictim == ~(pc["d1"] = 4 /\ pc["d2"] = 4)

\* Whoever holds a lock is still running (locks are released before
\* the committed/aborted state becomes visible).
HolderActive ==
  \A k \in KeysD :
    xholder[k] /= "none" => pc[xholder[k]] \in {1, 2}

=============================================================================
