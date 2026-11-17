#!/bin/bash
# Re-runs every TLC check cited in report/report.md and captures the
# full output into results/. Requires a JRE (JAVA env var) and
# tla2tools.jar (TLAJAR env var).
set -u
cd "$(dirname "$0")/spec"
JAVA="${JAVA:-java}"
JAR="${TLAJAR:-$HOME/workspace/tools/tla2tools.jar}"
R=../results
run() {
  local name="$1" module="$2" cfg="$3"
  echo "=== $name : $module -config $cfg ($(date -Is)) ===" | tee "$R/$name.log"
  timeout 3600 "$JAVA" -XX:+UseParallelGC -Xmx3G -jar "$JAR" "$module" \
      -config "$cfg" -workers auto -cleanup >> "$R/$name.log" 2>&1
  echo "--- exit: $? ---" >> "$R/$name.log"
  tail -4 "$R/$name.log"
}
run runD-deadlock-nodetector HaskDBDeadlock HaskDBDeadlock.cfg
run runE-deadlock-detector  HaskDBDeadlock HaskDBDeadlockDet.cfg
run runB-phantom            HaskDB         HaskDBPhantom.cfg
run runC-rc-weakened        HaskDBRC       HaskDBRC.cfg
run runA-core-2txn          HaskDB         HaskDB2K.cfg
# Optional, long-running (the cited evidence is a partial exploration
# of each, kept in results/ as *-partial.log): the 3-transaction
# configuration (HaskDB3S.cfg) and the 2-transaction x 3-key
# configuration (HaskDB.cfg) have state spaces of tens of millions of
# states and did not finish on the study machine. Uncomment to run:
# run runA3-core-3txn       HaskDB         HaskDB3S.cfg
# run runA-core-2txn-3key   HaskDB         HaskDB.cfg
