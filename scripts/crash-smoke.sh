#!/usr/bin/env bash
#
# crash-smoke.sh — Phase 8 T40 (design/10 §10.2 "full crash-test matrix (kill
# -9 during each phase's operations, including during checkpoint and during
# recovery itself)"; design/02 §2.6 + design/00 §0.7's durability rule;
# internal/11 §11.2's open/create + reopen guards).  The SERVER-level matrix:
# a real process is SIGKILLed at the chosen moment, then restarted, and the
# client tells us what survived.
#
# Every case ends by restarting the server and asking the client what survived,
# which is design/02 §2.6's observable contract:
#
#   committed    = the WAL commit record was written AND the WAL fsynced
#                  (design/00 §0.7 - the client's response only answers after
#                  that) - those changes MUST survive,
#   uncommitted  = any transaction not at that point - those changes must
#                  NEVER become visible,
#   and the reopen/compatibility guards (internal/11 §11.2/§11.4) must REFUSE
#                  rather than guess at a doctored disk state.
#
# What is covered HERE (process level) vs in the in-process crash-tests suite:
#   here  : kill -9 after a commit, with an open BEGIN block, DURING A REPLAY
#           (C3: the previous server itself died by kill -9, so the control
#           file's checkpointLSN is stale, the WAL holds thousands of pending
#           records put there by one COPY, and the reopened process is
#           killed inside that replay before it ever serves a request), during
#           bootstrap; the single-process guard (internal/11 §11.4's separate
#           `haskdb.lock`, which is how internal/11 realises design/00 §0.6's
#           rule - design/00 §0.6 names the CONTROL file, a docs-vs-docs
#           divergence recorded in TODO.md); the wrong-PAGE_SIZE /
#           bad-format-version / foreign-file / zeroed-page-0 / missing-control
#           file refusals.
#   there : the crash states that need the disk doctored at BYTE level (a
#           checkpoint cut between the CHECKPOINT record's append + flushAll +
#           data fsync and the writeControl, an ACTIVE txn listed in that
#           record, an aborted txn whose pages were stolen and flushed, a
#           replay interrupted mid-page) - a shell cannot hit those offsets
#           deterministically, and cfgCheckpointSecs = 300 (D-11) with no CLI
#           flag means a shell cannot even start a checkpoint on demand.  See
#           test/CrashSpec.hs.
#
# psql facts learned against this build (PostgreSQL 18.3, our own binary tree;
# see scripts/psql-smoke.sh for the full list):
#   * SQL is passed with -c; a bare positional argument is a FILE to read,
#   * -q SUPPRESSES the result-status lines (CREATE TABLE / INSERT 0 1), so the
#     greps below must not use it,
#   * `-f /dev/stdin` streams a multi-statement script, and a line starting
#     with backslash there is psql's own meta-command parser (backslash-! sleep
#     4 therefore keeps an open BEGIN block alive while we crash the server),
#   * a count query prints a ` ?column? ` header, one indented number, then
#     `(1 row)`; the number alone is what countOf matches,
#   * COPY rows are TAB-separated text on stdin, ended by EOF (COPY n).
#
# Host quirk (learned in scripts/psql-smoke.sh): a just-freed TCP port may still
# be held by the kernel, so every server starts on a fresh random port with
# retries.
#
# Everything runs through scripts/haskdb-test-run.sh (AGENT.md rule R-RES):
# one fresh cgroup slice for the whole session, capped per scope and per slice,
# and the accounting delta is printed at the end so the 20 % budget is MEASURED.
#
set -u
export PATH=/home/ryo/work/goopg/goopg/postgres/local_install/bin:$PATH
export LD_LIBRARY_PATH=/home/ryo/work/goopg/goopg/postgres/local_install/lib:${LD_LIBRARY_PATH:-}

SRV=dist-newstyle/build/x86_64-linux/ghc-9.10.3/haskdb-0.1.0/x/haskdb-server/build/haskdb-server/haskdb-server
PSQL=/home/ryo/work/goopg/goopg/postgres/local_install/bin/psql
RUN=scripts/haskdb-test-run.sh
ROOT=/tmp/opencode/crash-smoke
export SRV PSQL RUN DIR ROOT

if [ ! -x "$SRV" ]; then echo "server binary missing — build it first"; exit 1; fi

SL=haskdb-crash-smoke-$RANDOM
export HASKDB_CG_SLICE="$SL" HASKDB_SLICE_MEM_HIGH=2G HASKDB_SLICE_MEM_MAX=3G HASKDB_SLICE_SWAP_MAX=0
export HASKDB_CPU_QUOTA=320% HASKDB_SCOPE_CPU_QUOTA=200%
export HASKDB_MEM_HIGH=1G HASKDB_MEM_MAX=1200M HASKDB_MEM_SWAP_MAX=0 HASKDB_NICE=15 HASKDB_CPU_LIMIT=600

cg() { systemctl --user show "$1.slice" --property="$2" 2>/dev/null \
      | sed -n 's/^[^=]*=//p' | grep -E '^[0-9]+$' || echo 0; }
say() { echo "=== $1"; }
FAILS=0
fail() { FAILS=$((FAILS+1)); }
hit() { grep -q "$2" "$1" && echo "ok [$2]" || { echo "  ^^ expected [$2] NOT seen in $1"; fail; }; }
nohit() { grep -q "$2" "$1" && { echo "  ^^ must NOT contain [$2] in $1"; fail; } \
          || echo "ok [$2] absent"; }
countOf() { grep -oE '^[[:space:]]*[0-9]+[[:space:]]*$' "$1" | tr -d ' ' | head -1; }
# expect <got> <want> : a comparison that can actually FAIL - a failed psql call
# prints an EMPTY count, and "" = "" would have passed the first version of this
# harness vacuously.
expect() { if [ -n "$1" ] && [ "$1" = "$2" ]; then echo "ok: got [$1] = [$2]"; \
           else echo "  ^^ FAIL: got [$1], expected [$2]"; fail; fi; }
# refused <tag> <dir> <needle> : a reopen/create GUARD case.  start_srv's exit
#   code is the outcome (0 = listening, 1 = all eight fresh ports were still
#   held, 2 = the server exited without listening), so a guard case that
#   ignored it would grep whatever SRVFAILLOG the PREVIOUS case left behind.
refused() { local tag="$1" dir="$2" needle="$3" rc
    # start_srv overwrites SRVPORT/SRVPID/SRVLOG on SUCCESS, so a guard case
    #   must not orphan the caller's live holder (C9's `shut` would then shut
    #   the wrong pid and leave a flock for the rest of the matrix, TODO.md's
    #   lesson).  Save and restore them around the call.
    local hold_pid=${SRVPID:-} hold_port=${SRVPORT:-} hold_log=${SRVLOG:-}
    SRVFAILLOG=""
    start_srv "$tag" "$dir"; rc=$?
    # the pid start_srv started, if any, BEFORE restoring the caller's vars
    local new_pid=${SRVPID:-}
    SRVPID=$hold_pid; SRVPORT=$hold_port; SRVLOG=$hold_log
    if [ "$rc" = 2 ]; then
        sed -n '1,8p' "$SRVFAILLOG"
        hit "$SRVFAILLOG" "$needle"
        nohit "$SRVFAILLOG" 'listening on port'
    else
        echo "  ^^ guard case NOT exercised: opening $dir did not refuse (rc=$rc)"
        fail
        # an unexpected LIVE server must not keep holding the flock
        [ "$rc" = 0 ] && [ -n "$new_pid" ] && kill -9 "$new_pid" 2>/dev/null
    fi
}

n=0
pq() { n=$((n+1)); HASKDB_CG_UNIT="psql-cli-$n-$RANDOM" "$RUN" \
       "$PSQL" -h 127.0.0.1 -p "$1" -c "$2"; }
pqs() { n=$((n+1)); HASKDB_CG_UNIT="psql-scr-$n-$RANDOM" "$RUN" \
       "$PSQL" -h 127.0.0.1 -p "$1" -f /dev/stdin; }
# copyin <port> <rows> : one COPY transaction loading <rows> TAB-separated rows
#   (EOF ends it) - the cheap way to get a WAL with tens of thousands of
#   pending records, which is what makes a replay slow enough to be killed in.
copyin() {
    local p="$1" cnt="$2" log="$3"
    n=$((n+1))
    awk -v c="$cnt" 'BEGIN { for (i = 1; i <= c; i++) printf "%d\t%d\n", i + 1000, i * 2 }' \
      | HASKDB_CG_UNIT="copyin-$n-$RANDOM" "$RUN" \
        "$PSQL" -h 127.0.0.1 -p "$p" -c 'copy acct from stdin;' >"$log" 2>&1
}

# start_srv <tag> <dataDir> : capped server on a fresh port; on SUCCESS sets
# SRVPORT/SRVPID/SRVLOG, on REFUSAL sets SRVFAILLOG; on a SUCCESS it DOES
#   overwrite them, so the `refused` helper above saves-and-restores them
#   around the call, and a broken guard cannot leave a flock holder for the
#   rest of the matrix.
start_srv() {
    local tag="$1" dir="$2" base=$((5000 + RANDOM % 4000)) i p log rc pid
    for i in 0 1 2 3 4 5 6 7; do
        p=$((base + i))
        log=/tmp/opencode/srv-$tag-$p.log
        HASKDB_CG_UNIT="srv-$tag-$p" "$RUN" sh -c \
          'exec nice -n 15 "$SRV" "$1" --port "$2"' _ "$dir" "$p" >"$log" 2>&1 &
        pid=$!
        rc=1
        for k in $(seq 1 15); do
            sleep 0.4
            if grep -q 'listening on port' "$log" 2>/dev/null; then rc=0; break; fi
            if ! kill -0 "$pid" 2>/dev/null; then rc=2; break; fi
        done
        if [ "$rc" = 0 ]; then
            ALLPIDS="$ALLPIDS $pid"
            SRVPORT=$p; SRVPID=$pid; SRVLOG=$log
            say "server $tag up on port $p (log $log, pid $pid)"
            return 0
        fi
        if [ "$rc" = 2 ]; then
            if grep -qi 'Address already in use' "$log" 2>/dev/null; then
                say "port $p still held, retrying"
                kill -9 "$pid" 2>/dev/null
                continue
            fi
            SRVFAILLOG=$log
            say "server $tag exited without listening (log $log)"
            return 2
        fi
        say "port $p still held, retrying"
        kill -9 "$pid" 2>/dev/null
    done
    return 1
}

# boot_and_kill <tag> <dataDir> <secs> : launch a capped server and SIGKILL it
#   <secs> later, with NO client ever contacting it.  The caller must have left
#   a STALE checkpoint behind (its server died by kill -9: a SIGTERM shutdown
#   writes a final checkpoint per internal/11 §11.5 and would leave an EMPTY
#   replay), so the only work that process does is §3.6's redo/undo of the
#   pending WAL - which is what makes the kill land "during recovery".  Sets
#   SRVDEADLOG.  Retries a port the kernel still holds.
boot_and_kill() {
    local tag="$1" dir="$2" secs="$3" base=$((5000 + RANDOM % 4000)) i p log pid
    for i in 0 1 2 3 4 5 6 7; do
        p=$((base + i))
        log=/tmp/opencode/srv-$tag-$p.log
        HASKDB_CG_UNIT="srv-$tag-$p" "$RUN" sh -c \
          'exec nice -n 15 "$SRV" "$1" --port "$2"' _ "$dir" "$p" >"$log" 2>&1 &
        pid=$!
        sleep "$secs"
        kill -9 "$pid" 2>/dev/null
        sleep 0.6
        if grep -qi 'Address already in use' "$log" 2>/dev/null; then
            say "port $p was still held, retrying"
            kill -9 "$pid" 2>/dev/null
            continue
        fi
        ALLPIDS="$ALLPIDS $pid"
        SRVDEADLOG=$log
        say "server $tag died $secs s after launch (log $log)"
        return 0
    done
    return 1
}

# setup <tag> <dataDir> : a fresh database, a table, an index over k and three
# committed rows; leaves the server LIVE (SRVPORT/SRVPID) for the case to crash.
setup() {
    local tag="$1" dir="$2" r
    rm -rf "$dir"; mkdir -p "$dir"
    start_srv "$tag" "$dir" || return 1
    pq "$SRVPORT" 'create table acct (k int64, v int64);' >/dev/null 2>&1
    pq "$SRVPORT" 'create index ixk on acct (k);'         >/dev/null 2>&1
    for r in 11 12 13; do
        pq "$SRVPORT" "insert into acct values ($r, $((r*10)));" >/dev/null 2>&1
    done
    return 0
}

shut()  { kill -TERM "$1" 2>/dev/null; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$1" 2>/dev/null || break; sleep 1; done; kill -9 "$1" 2>/dev/null; }
kill9() { kill -9 "$1" 2>/dev/null; sleep 0.5; kill -9 "$1" 2>/dev/null; }

rm -rf "$ROOT"; mkdir -p "$ROOT"
ALLPIDS=""
# with `set -u`, a case that reads the refusal log after an rc=1 (all eight
#   fresh ports held) must not die of an unbound variable before its FAIL
#   counter runs.
SRVFAILLOG=""
# an early `exit 1` must not leave a server holding a flock (AGENT.md)
trap 'for p in $ALLPIDS; do kill -9 "$p" 2>/dev/null; done' EXIT

before=$(cg "$SL" CPUUsageNSec); t0=$(date +%s.%N)

# ---------------------------------------------------------------------------
# C1 kill -9 AFTER a commit - design/00 §0.7: the WAL commit record is durable
#   before the client's "INSERT 0 1" arrives, so the row MUST survive.  The
#   page itself was NOT forced (no-force, design/02 §2.4), so on reopen the row
#   can only come back through §3.6's redo of the WAL.
# ---------------------------------------------------------------------------
say "C1 kill -9 AFTER a commit (the committed row + its index entry MUST survive)"
setup c1 "$ROOT/c1" || { echo "setup failed for C1"; exit 1; }
pq "$SRVPORT" 'insert into acct values (77, 770);' >/tmp/opencode/k1.txt 2>&1
hit /tmp/opencode/k1.txt 'INSERT 0 1'
say "  the commit response already arrived, so the WAL commit record is durable"
kill9 "$SRVPID"
start_srv c1r "$ROOT/c1" || { echo "restart after C1 failed"; exit 1; }
pq "$SRVPORT" 'select count(k) from acct;' > /tmp/opencode/k2.txt 2>&1
sed -n '1,6p' /tmp/opencode/k2.txt
expect "$(countOf /tmp/opencode/k2.txt)" 4
pq "$SRVPORT" 'select v from acct where k = 77;' > /tmp/opencode/k3.txt 2>&1
sed -n '1,6p' /tmp/opencode/k3.txt
hit /tmp/opencode/k3.txt '770'
say "  the row is reached through ixk, so the INDEX survived too"
shut "$SRVPID"

# ---------------------------------------------------------------------------
# C2 kill -9 with an OPEN BEGIN block - the block's rows must NEVER show up.
#   psql's backslash-! meta-command shells out, which keeps the session (inside
#   the block with one row inserted, uncommitted) alive while we crash the
#   server.  The BEGIN tag, the in-block INSERT's status line and the lost
#   connection are all asserted, so the case cannot pass with no open block.
# ---------------------------------------------------------------------------
say "C2 kill -9 with an OPEN BEGIN block (the uncommitted row must NEVER appear)"
setup c2 "$ROOT/c2" || { echo "setup failed for C2"; exit 1; }
printf 'begin;\ninsert into acct values (91, 910);\n\\! sleep 4\ncommit;\n' \
  | pqs "$SRVPORT" > /tmp/opencode/k4.txt 2>&1 &
BLKPID=$!
sleep 1.5
say "  the block is open (BEGIN + one INSERT, no COMMIT yet)"
hit /tmp/opencode/k4.txt 'BEGIN'
hit /tmp/opencode/k4.txt 'INSERT 0 1'
say "  the server is SIGKILLed while the block is open (nothing committed)"
kill9 "$SRVPID"
wait "$BLKPID" 2>/dev/null
sed -n '1,12p' /tmp/opencode/k4.txt
hit /tmp/opencode/k4.txt 'connection to server was lost'
say "  the block never reached COMMIT, so nothing of it may be on disk"
start_srv c2r "$ROOT/c2" || { echo "restart after C2 failed"; exit 1; }
pq "$SRVPORT" 'select count(k) from acct;' > /tmp/opencode/k5.txt 2>&1
sed -n '1,6p' /tmp/opencode/k5.txt
expect "$(countOf /tmp/opencode/k5.txt)" 3
nohit /tmp/opencode/k5.txt '910'
shut "$SRVPID"

# ---------------------------------------------------------------------------
# C3 kill -9 DURING RECOVERY ITSELF.  Build the crash state so that the pending
#   replay is BIG and real: one COPY commits thousands of records, then the
#   server is killed by kill -9 (NOT SIGTERM: internal/11 §11.5's shutdown
#   would run a final checkpoint and leave NOTHING to replay), so the control
#   file's checkpointLSN still sits before those records.  A fresh process is
#   then launched and killed inside that replay - the harness asserts the §3.6
#   "replaying the pending WAL" observability marker IS present in its log while
#   "listening on port" is absent, which pins the kill inside the replay rather
#   than in the open guards - and the disk it leaves half-recovered must reopen
#   to the SAME committed state.  (That marker line is an observability
#   addition printed right before `recoverDatabase`; internal/11 §11.7 lists
#   the log content - startup banner, checkpoint completions, XX000 session
#   errors, shutdown - and does not name it, a docs-vs-code deviation recorded
#   in TODO.md; §11.7's "client-visible behaviour never depends on logs" is
#   what makes adding it safe.)  (5000 rows: 30000 hit the scope's `ulimit -t
#   600` CPU guard and the 1.2G memory cap mid-COPY, so the crash state was
#   never even built - see the Phase-8 Learned notes in TODO.md.)
# ---------------------------------------------------------------------------
say "C3 kill -9 DURING RECOVERY (a big pending replay, then resumed)"
setup c3 "$ROOT/c3" || { echo "setup failed for C3"; exit 1; }
copyin "$SRVPORT" 5000 /tmp/opencode/copyin-c3.txt
hit /tmp/opencode/copyin-c3.txt 'COPY 5000'
pq "$SRVPORT" 'select count(k) from acct;' > /tmp/opencode/k6.txt 2>&1
sed -n '1,6p' /tmp/opencode/k6.txt
expect "$(countOf /tmp/opencode/k6.txt)" 5003
say "  the server dies by kill -9, so NO final checkpoint: cp stays below 5000 records"
kill9 "$SRVPID"
boot_and_kill c3k "$ROOT/c3" 0.05 || { echo "C3 doomed reopen failed"; exit 1; }
hit "$SRVDEADLOG" 'replaying the pending WAL'
nohit "$SRVDEADLOG" 'listening on port'
say "  (the open guards passed and the §3.6 replay STARTED, but the process"
say "   died before serving: the kill therefore landed inside the replay)"
start_srv c3r "$ROOT/c3" || { echo "restart after C3 failed"; exit 1; }
pq "$SRVPORT" 'select count(k) from acct;' > /tmp/opencode/k7.txt 2>&1
sed -n '1,6p' /tmp/opencode/k7.txt
expect "$(countOf /tmp/opencode/k7.txt)" 5003
say "  and the index still reaches a COPY-era row"
pq "$SRVPORT" 'select v from acct where k = 2001;' > /tmp/opencode/kidx.txt 2>&1
sed -n '1,6p' /tmp/opencode/kidx.txt
hit /tmp/opencode/kidx.txt '2002'
shut "$SRVPID"

# ---------------------------------------------------------------------------
# C4 kill -9 DURING bootstrap - a fresh directory killed mid-create.  The CREATE
#   is asserted to have been issued, so the only accepted outcomes are the two
#   self-consistent ones: either internal/11 §11.2 refuses (bootstrap left
#   data/WAL but no control file: never guessed) or the open works and the
#   CREATE's commit either did or did not reach the WAL.  A mix is a design/00
#   §0.7 bug.
# ---------------------------------------------------------------------------
say "C4 kill -9 DURING bootstrap (a fresh directory, killed mid-create)"
rm -rf "$ROOT/bootmid"; mkdir -p "$ROOT/bootmid"
start_srv c4 "$ROOT/bootmid" || { echo "C4 boot refused"; exit 1; }
pq "$SRVPORT" 'create table mid (n int64);' >/tmp/opencode/kcreate.txt 2>&1
hit /tmp/opencode/kcreate.txt 'CREATE TABLE'
say "  the CREATE response arrived, so per design/00 §0.7 its commit record"
say "  reached the WAL and the WAL was fsynced BEFORE that response: the table"
say "  MUST be back after the crash (bootstrap had already written the control"
say "  file when it printed 'listening', so this directory is COMPLETE and"
say "  §11.2's refuse-on-incomplete rule does not apply to it)"
kill9 "$SRVPID"
say "  reopen and look for the table"
if start_srv c4r "$ROOT/bootmid"; then
  pq "$SRVPORT" 'select count(n) from mid;' > /tmp/opencode/k8.txt 2>&1
  sed -n '1,6p' /tmp/opencode/k8.txt
  if grep -qi 'table not found' /tmp/opencode/k8.txt; then
    echo "  ^^ C4 FAIL: the CREATE had committed, so the reopened view lost it"
    echo "     - a design/00 §0.7 violation, not a legal outcome"
    fail
  else
    expect "$(countOf /tmp/opencode/k8.txt)" 0
    say "  the committed table is back and empty"
  fi
  shut "$SRVPID"
else
  echo "  ^^ C4 FAIL: a directory whose bootstrap reached 'listening' is complete"
  echo "     and must reopen; refusing here loses a §0.7-committed CREATE"
  sed -n '1,8p' "${SRVFAILLOG:-/dev/null}"
  fail
fi

# ---------------------------------------------------------------------------
# C5 reopen guard: a control file whose pageSize disagrees with the
#   configuration MUST be refused (design/00 §0.3's compatibility check;
#   internal/11 §11.4).  The data file is left untouched, so restoring the
#   control file must reopen the SAME state.
# ---------------------------------------------------------------------------
say "C5 reopen guard: a doctored control pageSize must be REFUSED, data intact"
setup c5 "$ROOT/c5" || { echo "setup failed for C5"; exit 1; }
pq "$SRVPORT" 'insert into acct values (5, 50);' >/dev/null 2>&1
shut "$SRVPID"
cp "$ROOT/c5/haskdb.control" /tmp/opencode/ctl-good
sed -i 's/^pageSize=.*/pageSize=4096/' "$ROOT/c5/haskdb.control"
say "  opening with the doctored control file"
refused c5bad "$ROOT/c5" 'pageSize'
say "  now restore the control file and open again (the data must be intact)"
cp /tmp/opencode/ctl-good "$ROOT/c5/haskdb.control"
start_srv c5ok "$ROOT/c5" || { echo "C5 reopen refused (bad)"; exit 1; }
pq "$SRVPORT" 'select count(k) from acct;' > /tmp/opencode/k9.txt 2>&1
sed -n '1,6p' /tmp/opencode/k9.txt
expect "$(countOf /tmp/opencode/k9.txt)" 4
shut "$SRVPID"

# ---------------------------------------------------------------------------
# C6 reopen guard: an unsupported control-file format version is refused
#   (internal/11 §11.4's version field; design/00 §0.3's compatibility checks).
# ---------------------------------------------------------------------------
say "C6 reopen guard: an unsupported control-file format version must be refused"
sed -i 's/^format=.*/format=2/' "$ROOT/c5/haskdb.control"
refused c6bad "$ROOT/c5" 'format version'
cp /tmp/opencode/ctl-good "$ROOT/c5/haskdb.control"

# ---------------------------------------------------------------------------
# C7 reopen guard: page 0 without the HaskDB magic is refused (a corrupt data
#   file must not be reinterpreted).  Copy of a real database, first bytes
#   zeroed with conv=notrunc so the file keeps its size; the sanity check below
#   proves the zeroing happened by reading the magic AT ITS REAL OFFSET
#   (page0PayloadOff = 20 - `HDB1` starts at byte 20 of page 0, after the 20-byte
#   page header, so reading bytes 0..3 could never have detected it).
# ---------------------------------------------------------------------------
say "C7 reopen guard: a zeroed page 0 (no HaskDB magic) must be refused"
COPYDB="$ROOT/corrupt"
rm -rf "$COPYDB"; mkdir -p "$COPYDB"
cp "$ROOT/c5/haskdb.data" "$COPYDB/haskdb.data"
cp "$ROOT/c5/haskdb.wal"  "$COPYDB/haskdb.wal"
cp "$ROOT/c5/haskdb.control" "$COPYDB/haskdb.control"
dd if=/dev/zero of="$COPYDB/haskdb.data" bs=64 count=1 seek=0 conv=notrunc 2>/dev/null
if dd if="$COPYDB/haskdb.data" bs=1 skip=20 count=4 2>/dev/null | grep -q 'HDB1'; then
  echo "  ^^ dd did NOT zero page 0 - the case would be vacuous"; fail
fi
refused c7bad "$COPYDB" 'page 0'

# ---------------------------------------------------------------------------
# C8 create guard: a directory with FOREIGN files must refuse to create
#   (internal/11 §11.2: never overwrite someone else's tree).
# ---------------------------------------------------------------------------
say "C8 create guard: a directory with foreign files must refuse to create"
STRAY="$ROOT/stray"
rm -rf "$STRAY"; mkdir -p "$STRAY"
echo "someone else's file" > "$STRAY/notes.txt"
refused c8bad "$STRAY" 'refusing to create a database over foreign files'

# ---------------------------------------------------------------------------
# C9 guard: a second server on the same directory must be refused.  internal/11
#   §11.2/§11.4 keep the exclusive flock in a separate `haskdb.lock` that is
#   never written to; design/00 §0.6 states the same single-process rule but
#   names the CONTROL file, so the FILE choice is a docs-vs-docs divergence
#   recorded in TODO.md (internal-design wins structure, design keeps semantics).
# ---------------------------------------------------------------------------
say "C9 guard: a second server on the same directory must be refused (flock)"
setup c9 "$ROOT/c9" || { echo "setup failed for C9"; exit 1; }
refused c9b "$ROOT/c9" 'another HaskDB process'
shut "$SRVPID"

# ---------------------------------------------------------------------------
# C10 open guard: a directory holding data + WAL but NO control file is
#   INCOMPLETE and must be REFUSED, never guessed (internal/11 §11.2's no-guess
#   rule, design/00 §0.3's compatibility checks).  Produced deterministically by
#   deleting the control file of an otherwise healthy database: the doctored-
#   disk pattern of C5/C6/C7, which a process-level kill -9 cannot hit because
#   §11.5 writes the control file during a graceful shutdown, not mid-crash.
# ---------------------------------------------------------------------------
say "C10 open guard: data + WAL but no control file must be REFUSED (§11.2)"
setup c10 "$ROOT/c10" || { echo "setup failed for C10"; exit 1; }
shut "$SRVPID"
rm -f "$ROOT/c10/haskdb.control"
refused c10bad "$ROOT/c10" 'incomplete database directory'

# ---------------------------------------------------------------------------
say "all crash servers are gone (no flock holders, no ports held)"
for p in $ALLPIDS; do kill -9 "$p" 2>/dev/null; done
sleep 0.5
# zombies still named haskdb-server are already dead (unreaped by this bash), so
# only count LIVE (non-Z) ones: what matters is that no flock holder survives.
alive=$(ps -eo pid=,stat=,comm= --no-headers | awk '$3=="haskdb-server" && $2 !~ "^Z" {c++} END{print c+0}')
expect "$alive" 0

t1=$(date +%s.%N); after=$(cg "$SL" CPUUsageNSec); peak=$(cg "$SL" MemoryPeak)
python3 - "$before" "$after" "$t0" "$t1" "$peak" "$(nproc)" "$(awk '/MemTotal/{print $2}' /proc/meminfo)" <<'PY'
import sys
b,a,t0,t1,pk,cores,mem=[float(x) for x in sys.argv[1:8]]
wall=max(t1-t0,1e-9); cpu=(a-b)/1e9
print(f"budget check: CPU {100*cpu/(wall*cores):.1f}% of the box (limit 20.0%), cores_used={cpu/wall:.2f}/{cores:.0f}")
print(f"budget check: MEM peak {pk/2**30:.2f} GiB = {100*pk/(mem*1024*0.20):.1f}% of the 20% budget ({0.2*mem/2**20:.0f} MiB)")
PY

if [ "$FAILS" -gt 0 ]; then
  echo "crash-smoke: $FAILS check(s) FAILED"
  exit 1
fi
echo "crash-smoke: the whole matrix held (0 failures)"
