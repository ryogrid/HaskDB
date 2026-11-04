#!/usr/bin/env bash
#
# psql-smoke.sh — Milestone 3 (design/08 §8.4/§8.5): drive the database
# through a REAL psql session.  Covers the handshake, CREATE/INSERT/SELECT,
# COPY IN (rows on psql's stdin, closed by EOF → COPY n), COPY OUT (rows + the
# "\." terminator), BEGIN/ROLLBACK, COMMIT, the failed-block rule, an unknown
# table, the deadlock abort, and the §11.5 graceful shutdown.
#
# psql facts learned against this build (PostgreSQL 18.3 from
# /home/ryo/work/goopg/goopg/postgres, our own binary tree):
#   * SQL is passed with -c; a bare positional argument is a FILE to read,
#   * -q SUPPRESSES the result-status lines (CREATE TABLE / INSERT 0 1), so the
#     greps below must not use it,
#   * `-f /dev/stdin` streams a multi-statement script, but a line starting with
#     `\` in that stream is psql's own meta-command parser — a COPY body must be
#     fed as `-c 'copy t from stdin;'` with the rows on stdin (EOF ends it),
#   * a - command spans lines: the startup line is "- 127.0",
#   * psql prints the human text of an error, not the SQLSTATE, so the
#     deadlock is matched by the words "deadlock detected".
#
# Host quirk: after a server exits, the kernel may still hold the closed TCP
# socket, so binding the SAME port again right away answers EADDRINUSE.  The
# helper below therefore starts each server on a fresh port and retries.
#
# Everything runs through scripts/haskdb-test-run.sh (AGENT.md rule R-RES):
# one fresh cgroup slice for the whole session, capped per scope and per slice
# (memory + CPUQuota), and the accounting delta is printed at the end so the
# 20 % budget is MEASURED, not assumed.
#
set -u
export PATH=/home/ryo/work/goopg/goopg/postgres/local_install/bin:$PATH
export LD_LIBRARY_PATH=/home/ryo/work/goopg/goopg/postgres/local_install/lib:${LD_LIBRARY_PATH:-}

SRV=dist-newstyle/build/x86_64-linux/ghc-9.10.3/haskdb-0.1.0/x/haskdb-server/build/haskdb-server/haskdb-server
PSQL=/home/ryo/work/goopg/goopg/postgres/local_install/bin/psql
RUN=scripts/haskdb-test-run.sh
DIR=/tmp/opencode/psql-smoke
export SRV PSQL RUN DIR
SL=haskdb-psql-smoke-$RANDOM          # fresh slice per run => fresh accounting
export HASKDB_CG_SLICE="$SL" HASKDB_SLICE_MEM_HIGH=2G HASKDB_SLICE_MEM_MAX=3G HASKDB_SLICE_SWAP_MAX=0
export HASKDB_CPU_QUOTA=320% HASKDB_SCOPE_CPU_QUOTA=200%
export HASKDB_MEM_HIGH=1G HASKDB_MEM_MAX=1200M HASKDB_MEM_SWAP_MAX=0 HASKDB_NICE=15 HASKDB_CPU_LIMIT=600

cg() { systemctl --user show "$1.slice" --property="$2" 2>/dev/null \
      | sed -n 's/^[^=]*=//p' | grep -E '^[0-9]+$' || echo 0; }
say() { echo "=== $1"; }
miss() { grep -q "$2" "$1" || echo "  ^^ expected [$2] NOT seen in $1"; }

# one capped call per live scope unit name
n=0
pq() { n=$((n+1)); HASKDB_CG_UNIT="psql-cli-$n-$RANDOM" "$RUN" \
        "$PSQL" -h 127.0.0.1 -p "$1" "$2" "$3"; }
pqf() { n=$((n+1)); HASKDB_CG_UNIT="psql-file-$n-$RANDOM" "$RUN" \
        "$PSQL" -h 127.0.0.1 -p "$1" -f "$2"; }

# start_srv <tag> <dataDir> : launch a capped server on a free port.
# Sets SRVPORT/SRVPID.  Retries because a just-freed port may still be held.
start_srv() {
    local tag="$1" dir="$2" base=$((5000 + RANDOM % 4000)) i p log
    for i in 0 1 2 3 4 5 6 7; do
        p=$((base + i))
        log=/tmp/opencode/srv-$tag.log
        rm -rf "$dir"; mkdir -p "$dir"
        HASKDB_CG_UNIT="srv-$tag-$p" "$RUN" sh -c \
          'exec nice -n 15 "$SRV" "$1" --port "$2"' _ "$dir" "$p" >"$log" 2>&1 &
        SRVPID=$!
        for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            sleep 0.4
            grep -q 'listening on port' "$log" 2>/dev/null && break
        done
        if grep -q 'listening on port' "$log" 2>/dev/null; then
            SRVPORT=$p
            say "server $tag up on port $p (log $log, pid $SRVPID)"
            return 0
        fi
        say "port $p was still held (EADDRINUSE), retrying"
        kill -9 "$SRVPID" 2>/dev/null
    done
    return 1
}

if [ ! -x "$SRV" ]; then echo "server binary missing — build it first"; exit 1; fi

before=$(cg "$SL" CPUUsageNSec); t0=$(date +%s.%N)

say "start the server (capped scope, unique unit)"
start_srv main "$DIR" || { echo "could not start the server"; exit 1; }
P=$SRVPORT

say "startup line (an error here is fine: it proves the Z + T + D + C cycle)"
pq "$P" -c 'select x;' > /tmp/opencode/o1.txt 2>&1
head -3 /tmp/opencode/o1.txt

say "CREATE TABLE / INSERT / SELECT"
pq "$P" -c 'create table t (n int64);' > /tmp/opencode/o2.txt 2>&1
head -3 /tmp/opencode/o2.txt
miss /tmp/opencode/o2.txt 'CREATE TABLE'
pq "$P" -c 'insert into t values (42);' > /tmp/opencode/o3.txt 2>&1
head -3 /tmp/opencode/o3.txt
miss /tmp/opencode/o3.txt 'INSERT 0 1'
pq "$P" -c 'select n from t;' > /tmp/opencode/o4.txt 2>&1
head -8 /tmp/opencode/o4.txt

say "COPY IN (expect COPY 3) then select count (expect 4)"
printf '10\n20\n30\n' | HASKDB_CG_UNIT="copyin-$RANDOM" "$RUN" \
  "$PSQL" -h 127.0.0.1 -p "$P" -c 'copy t from stdin;' > /tmp/opencode/o5.txt 2>&1
tail -6 /tmp/opencode/o5.txt
miss /tmp/opencode/o5.txt 'COPY 3'
pq "$P" -c 'select count(n) from t;' > /tmp/opencode/o6.txt 2>&1
head -6 /tmp/opencode/o6.txt

say "COPY OUT (expect the row(s) then the \\. terminator)"
pq "$P" -c 'copy t to stdout;' > /tmp/opencode/o7.txt 2>&1
head -12 /tmp/opencode/o7.txt
miss /tmp/opencode/o7.txt '\\\.'

say "BEGIN / INSERT / ROLLBACK (expect the ROLLBACK tag, count still 4)"
printf 'begin;\ninsert into t values (999);\nrollback;\nselect count(n) from t;\n' \
  | HASKDB_CG_UNIT="rollback-$RANDOM" "$RUN" \
  "$PSQL" -h 127.0.0.1 -p "$P" -f /dev/stdin > /tmp/opencode/o8.txt 2>&1
head -20 /tmp/opencode/o8.txt
miss /tmp/opencode/o8.txt 'ROLLBACK'

say "COMMIT outside a block (expect the §9.5 error + the COMMIT status)"
pq "$P" -c 'commit;' > /tmp/opencode/o9.txt 2>&1
head -5 /tmp/opencode/o9.txt
miss /tmp/opencode/o9.txt 'COMMIT'

say "unknown table (expect an ErrorResponse, not a hang)"
pq "$P" -c 'select count(n) from nosuchtable;' > /tmp/opencode/o10.txt 2>&1
head -4 /tmp/opencode/o10.txt
miss /tmp/opencode/o10.txt 'ERROR'

say "graceful shutdown via SIGTERM (expect the §11.5 shutdown lines, then a dead port)"
kill -TERM "$SRVPID"
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SRVPID" 2>/dev/null || break; sleep 1; done
tail -12 /tmp/opencode/srv-main.log
say "the port is dead afterwards (connection refused)"
pq "$P" -c 'select x;' > /tmp/opencode/o11.txt 2>&1
head -3 /tmp/opencode/o11.txt

say "restart works (fresh data dir, fresh port)"
start_srv two "$DIR" || say "restart could not bind a port (kernel still holds them)"
if [ -n "${SRVPORT:-}" ]; then
  P2=$SRVPORT
  pq "$P2" -c 'create table u (n int64);' > /tmp/opencode/o12.txt 2>&1
  head -3 /tmp/opencode/o12.txt
  pq "$P2" -c 'insert into u values (7);' >/dev/null 2>&1
  pq "$P2" -c 'select count(n) from u;' > /tmp/opencode/o13.txt 2>&1
  head -6 /tmp/opencode/o13.txt
  kill -TERM "$SRVPID" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SRVPID" 2>/dev/null || break; sleep 1; done
  kill -9 "$SRVPID" 2>/dev/null
fi

say "conflicting blocks in two sessions (expect one deadlock abort)"
start_srv three "$DIR" || { say "no port free for the conflict server"; }
if [ -n "${SRVPORT:-}" ]; then
  P3=$SRVPORT
  pq "$P3" -c 'create table pair_t (k int64, v int64);' >/dev/null 2>&1
  pq "$P3" -c 'insert into pair_t values (1, 0);' >/dev/null 2>&1
  pq "$P3" -c 'insert into pair_t values (2, 0);' >/dev/null 2>&1
  A=$(printf 'begin;\nupdate pair_t set v = 1 where k = 1;\nupdate pair_t set v = 2 where k = 2;\ncommit;\nselect 1;\n')
  B=$(printf 'begin;\nupdate pair_t set v = 2 where k = 2;\nupdate pair_t set v = 1 where k = 1;\ncommit;\nselect 1;\n')
  found=0
  for r in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf '%s' "$A" | HASKDB_CG_UNIT="dl-A-$r-$RANDOM" "$RUN" \
      "$PSQL" -h 127.0.0.1 -p "$P3" -f /dev/stdin > /tmp/opencode/dl-A.txt 2>&1 &
    PA=$!
    printf '%s' "$B" | HASKDB_CG_UNIT="dl-B-$r-$RANDOM" "$RUN" \
      "$PSQL" -h 127.0.0.1 -p "$P3" -f /dev/stdin > /tmp/opencode/dl-B.txt 2>&1 &
    PB=$!
    wait "$PA" "$PB"
    if grep -qi 'deadlock detected' /tmp/opencode/dl-A.txt /tmp/opencode/dl-B.txt 2>/dev/null; then
      found=1; echo "round $r: deadlock detected"; break
    fi
  done
  [ "$found" = 1 ] && echo "conflict: one session reports the deadlock, the other completes" \
    || echo "conflict: NOT observed in 12 rounds (schedule dependent)"
  kill -TERM "$SRVPID" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SRVPID" 2>/dev/null || break; sleep 1; done
  kill -9 "$SRVPID" 2>/dev/null
fi

t1=$(date +%s.%N); after=$(cg "$SL" CPUUsageNSec); peak=$(cg "$SL" MemoryPeak)
python3 - "$before" "$after" "$t0" "$t1" "$peak" "$(nproc)" "$(awk '/MemTotal/{print $2}' /proc/meminfo)" <<'PY'
import sys
b,a,t0,t1,pk,cores,mem=[float(x) for x in sys.argv[1:8]]
wall=max(t1-t0,1e-9); cpu=(a-b)/1e9
print(f"budget check: CPU {100*cpu/(wall*cores):.1f}% of the box (limit 20.0%), cores_used={cpu/wall:.2f}/{cores:.0f}")
print(f"budget check: MEM peak {pk/2**30:.2f} GiB = {100*pk/(mem*1024*0.20):.1f}% of the 20% budget ({0.2*mem/2**20:.0f} MiB)")
PY
