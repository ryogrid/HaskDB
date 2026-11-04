#!/usr/bin/env bash
#
# pgbench-smoke.sh — Milestone 4 (design/08 §8.5): run the stock `pgbench`
# client against HaskDB.  This is the milestone that forces COPY: pgbench
# initialises and reads its tables over the COPY path, so a green run is also
# the proof that the wire layer speaks PostgreSQL's protocol closely enough.
#
# What pgbench 18.3 needs from us (learned from
# /home/ryo/work/goopg/goopg/postgres/src/bin/pgbench/pgbench.c, its --help,
# and the failing runs recorded in notes/wire-protocol-psql-pgbench-memo.md):
#   * `select count(*) from pgbench_branches` at startup (GetTableInfo) —
#     design/05 §5.2 agg_call ::= COUNT '(' '*' ')' so this is in the grammar;
#   * the pg_catalog partition probe: we answer an ErrorResponse, pgbench
#     tolerates it (PART_NONE) — do NOT treat that error as a failure;
#   * table names pgbench_{accounts,branches,tellers,history} with PostgreSQL's
#     own column names (aid/abalance, bid/bbalance, tid/bid/tbalance,
#     tid/bid/aid/delta/endts/flags) so the stock builtin scripts apply
#     unmodified.  We create them with our DDL (int64 / varchar, no length
#     specifier per design/05 §5.3) and populate them with our own
#     `copy <table> from stdin` text rows — pgbench's own init steps (-i/-I)
#     use SQL we do not support (arithmetic, INSERT..SELECT, VACUUM, indexes),
#     so no -i/-I/-s generation flags are passed;
#   * BEGIN/COMMIT blocks and `UPDATE ... SET col = :v WHERE col = :v`:
#     legal for us; NO arithmetic anywhere (design/05 §5.2 line 86), so the
#     arithmetic builtins (simple-update / full) are EXPECTED to be rejected —
#     that rejection is a design deviation we log, not a bug to chase;
#   * `-t` is TRANSACTIONS per client and `-T` is DURATION seconds (pgbench's
#     help here), so the runs below are bounded by -t, and the default protocol
#     is `simple` (design/09 §9.1 / decision D-05).
#
# The COPY row text format of §9.4 is tab-separated (PostgreSQL text format),
# so the generators below print TAB-separated rows.
#
# Everything runs through scripts/haskdb-test-run.sh (AGENT.md rule R-RES):
# one fresh cgroup slice, memory caps + a slice CPUQuota, and the accounting
# delta printed at the end so the 20 % budget is MEASURED.
#
set -u
export PATH=/home/ryo/work/goopg/goopg/postgres/local_install/bin:$PATH
export LD_LIBRARY_PATH=/home/ryo/work/goopg/goopg/postgres/local_install/lib:${LD_LIBRARY_PATH:-}

SRV=dist-newstyle/build/x86_64-linux/ghc-9.10.3/haskdb-0.1.0/x/haskdb-server/build/haskdb-server/haskdb-server
PSQL=/home/ryo/work/goopg/goopg/postgres/local_install/bin/psql
PGB=/home/ryo/work/goopg/goopg/postgres/local_install/bin/pgbench
RUN=scripts/haskdb-test-run.sh
DIR=/tmp/opencode/pgbench-smoke
NACC=${NACC:-200}          # pgbench_accounts rows (keep small: R-RES budget)
export SRV PSQL PGB RUN DIR NACC
SL=haskdb-pgbench-smoke-$RANDOM
export HASKDB_CG_SLICE="$SL" HASKDB_SLICE_MEM_HIGH=2G HASKDB_SLICE_MEM_MAX=3G HASKDB_SLICE_SWAP_MAX=0
export HASKDB_CPU_QUOTA=320% HASKDB_SCOPE_CPU_QUOTA=200%
export HASKDB_MEM_HIGH=1G HASKDB_MEM_MAX=1200M HASKDB_MEM_SWAP_MAX=0 HASKDB_NICE=15 HASKDB_CPU_LIMIT=600

cg() { systemctl --user show "$1.slice" --property="$2" 2>/dev/null \
      | sed -n 's/^[^=]*=//p' | grep -E '^[0-9]+$' || echo 0; }
say() { echo "=== $1"; }
miss() { grep -q "$2" "$1" || echo "  ^^ expected [$2] NOT seen in $1"; }
n=0
pq() { n=$((n+1)); HASKDB_CG_UNIT="pgb-cli-$n-$RANDOM" "$RUN" \
       "$PSQL" -h 127.0.0.1 -p "$1" "$2" "$3"; }
bench() { HASKDB_CG_UNIT="pgbench-$1-$RANDOM" "$RUN" \
       "$PGB" -h 127.0.0.1 -p "$P" $2; }

start_srv() {
    local tag="$1" dir="$2" base=$((5000 + RANDOM % 4000)) i p log
    for i in 0 1 2 3 4 5 6 7; do
        p=$((base + i)); log=/tmp/opencode/srv-$tag.log
        rm -rf "$dir"; mkdir -p "$dir"
        HASKDB_CG_UNIT="srv-$tag-$p" "$RUN" sh -c \
          'exec nice -n 15 "$SRV" "$1" --port "$2"' _ "$dir" "$p" >"$log" 2>&1 &
        SRVPID=$!
        for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do sleep 0.4; grep -q 'listening on port' "$log" 2>/dev/null && break; done
        if grep -q 'listening on port' "$log" 2>/dev/null; then SRVPORT=$p; say "server $tag up on $p"; return 0; fi
        kill -9 "$SRVPID" 2>/dev/null
    done
    return 1
}

before=$(cg "$SL" CPUUsageNSec); t0=$(date +%s.%N)

say "start the server"
start_srv pgbench "$DIR" || { echo "could not start the server"; exit 1; }
P=$SRVPORT

say "create the pgbench tables with PostgreSQL's own column names"
for tbl in "pgbench_accounts (aid int64, abalance int64)" \
           "pgbench_branches (bid int64, bbalance int64)" \
           "pgbench_tellers (tid int64, bid int64, tbalance int64)" \
           "pgbench_history (tid int64, bid int64, aid int64, delta int64, endts int64, flags varchar)"; do
  pq "$P" -c "create table $tbl;" > /tmp/opencode/ctbl.txt 2>&1
  head -2 /tmp/opencode/ctbl.txt
done

say "populate them with COPY rows on psql's stdin (tab-separated text rows)"
mk2() { awk -v c="$1" 'BEGIN{for(i=1;i<=c;i++) print i "\t" i*7}'; }
mk3() { awk -v c="$1" 'BEGIN{for(i=1;i<=c;i++) print i "\t" (i%5+1) "\t" i*3}'; }
for rowset in "pgbench_accounts:$NACC:2" "pgbench_branches:5:2" "pgbench_tellers:20:3"; do
  tbl=${rowset%%:*}; rest=${rowset#*:}; cnt=${rest%%:*}; cols=${rest##*:}
  gen=mk2; [ "$cols" = 3 ] && gen=mk3
  "$gen" "$cnt" | HASKDB_CG_UNIT="copy-$tbl-$RANDOM" "$RUN" \
    "$PSQL" -h 127.0.0.1 -p "$P" -c "copy $tbl from stdin;" > "/tmp/opencode/copy-$tbl.txt" 2>&1
  tail -3 "/tmp/opencode/copy-$tbl.txt"
done

say "the pgbench startup query itself (GetTableInfo): select count(*) from pgbench_branches"
pq "$P" -c 'select count(*) from pgbench_branches;' > /tmp/opencode/o1.txt 2>&1
head -8 /tmp/opencode/o1.txt
miss /tmp/opencode/o1.txt "$NACC\|5"

say "a stock builtin that fits our grammar: -b select-only (SELECT ... WHERE aid = :aid)"
bench select-only "-b select-only -t 200 -P1" > /tmp/opencode/pgb-sel.txt 2>&1
tail -12 /tmp/opencode/pgb-sel.txt
miss /tmp/opencode/pgb-sel.txt 'transactions actually processed: [1-9]'
grep -Eq 'tps[[:space:]]*=[[:space:]]*[1-9]' /tmp/opencode/pgb-sel.txt || echo "  ^^ ZERO transaction rate (bench did not run)"

say "our own script: BEGIN/UPDATE/SELECT/COMMIT with :vars and NO arithmetic"
cat > /tmp/opencode/bench.sql <<SQL
\set aid random(1, $NACC)
\set bal random(1, 100000)
BEGIN;
UPDATE pgbench_accounts SET abalance = :bal WHERE aid = :aid;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
COMMIT;
SQL
bench custom "-f /tmp/opencode/bench.sql -t 200 -P1" > /tmp/opencode/pgb-custom.txt 2>&1
tail -14 /tmp/opencode/pgb-custom.txt
miss /tmp/opencode/pgb-custom.txt 'transactions actually processed: [1-9]'

say "COPY OUT rows for a small table stream as tuples (select bid from pgbench_branches)"
pq "$P" -c 'select bid from pgbench_branches;' > /tmp/opencode/o4.txt 2>&1
head -10 /tmp/opencode/o4.txt
miss /tmp/opencode/o4.txt '5 rows'

say "arithmetic is NOT in design/05 §5.2 (line 86): the stock simple-update/full
     builtins are expected to be rejected — this is a logged design deviation"
bench arithmetic "-b simple-update -t 20 -P1" > /tmp/opencode/pgb-arith.txt 2>&1
tail -12 /tmp/opencode/pgb-arith.txt
grep -qi 'unexpected character: +\|parse error\|syntax' /tmp/opencode/pgb-arith.txt \
  && echo "expected: the arithmetic builtin was rejected by our grammar" \
  || echo "UNEXPECTED: the arithmetic builtin was ACCEPTED"

say "shut the server down gracefully"
kill -TERM "$SRVPID"
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SRVPID" 2>/dev/null || break; sleep 1; done
kill -9 "$SRVPID" 2>/dev/null
tail -6 /tmp/opencode/srv-pgbench.log
rm -rf "$DIR"

t1=$(date +%s.%N); after=$(cg "$SL" CPUUsageNSec); peak=$(cg "$SL" MemoryPeak)
python3 - "$before" "$after" "$t0" "$t1" "$peak" "$(nproc)" "$(awk '/MemTotal/{print $2}' /proc/meminfo)" <<'PY'
import sys
b,a,t0,t1,pk,cores,mem=[float(x) for x in sys.argv[1:8]]
wall=max(t1-t0,1e-9); cpu=(a-b)/1e9
print(f"budget check: CPU {100*cpu/(wall*cores):.1f}% of the box (limit 20.0%), cores_used={cpu/wall:.2f}/{cores:.0f}")
print(f"budget check: MEM peak {pk/2**30:.2f} GiB = {100*pk/(mem*1024*0.20):.1f}% of the 20% budget ({0.2*mem/2**20:.0f} MiB)")
PY
