# AGENT.md — working rules for this repository

## Rule R-RES: bounded resources — every HaskDB test run is cgroup-capped (20 % budget)

**Never run HaskDB tests (server, `psql`, `pgbench`, `cabal test`, smoke
scripts, benchmarks) straight onto the shell.** Run each one through this
repository's capped runner:

```
scripts/haskdb-test-run.sh <command> [args...]
```

It puts the command's whole process tree in a systemd **cgroup v2 scope**
(`systemd-run --user --scope`) under a shared **slice**, so caps are enforced:

* per-scope `MemoryHigh`/`MemoryMax`: crossing `MemoryMax` lets the **cgroup-local**
  OOM killer SIGKILL only that command's tree — the host-wide OOM killer never
  fires, so a runaway test kills itself instead of freezing the machine;
* `MemorySwapMax=0`: this box has 64 GiB of swap, so an unbounded run thrashes
  swap (and the whole box goes unresponsive for minutes) long before any OOM
  kill; denying the scope's swap turns that slow freeze into a prompt, clean kill;
* the shared slice caps the **SUM of all concurrently capped runs** — per-scope
  caps cannot see sibling scopes, so aggregate oversubscription dies inside the
  slice instead of tripping the host-wide killer;
* `CPUQuota=` on the slice: an **aggregate CPU cap** for the whole workload
  group. Verified on this host (kernel `6.18…-WSL2`, systemd 255): with
  `CPUQuota=300%` and 8 busy workers in 8 scopes, the slice accounted 18.3 s of
  CPU over ~6 s of wall time — held to ~3 cores. Percentage semantics: 100 % =
  one core, so **20 % of 16 cores = `CPUQuota=320%`**. The slice reports the
  quota back as `CPUQuotaPerSecUSec=3.200000s`, and the wrapper warns if that
  read-back ever says `infinity`.
  * Survey result (why only this name): the Ubuntu man pages here list no CPU
    property at all (`systemd.slice(5)` is trimmed to the overview, `man 7
    cgroups` documents mostly the cgroup v1 interface), so the survey was
    empirical: `systemctl --user set-property` ACCEPTS `CPUQuota=` and answers
    `Unknown assignment` for `CPUUtilization=`, `CPUQuotaSlice=`, `CGroupCPU=`,
    `CGroupSlice=`, `CPUQuotaPeriodUSec=`.  Under
    `/sys/fs/cgroup/user.slice/user-<uid>.slice/...` a cgroup exposes only
    `cpu.max`, `cpu.max.burst`, `cpu.stat`, `cpu.weight`, ...
    i.e. `cpu.max` is the utilization control that exists here, and there is
    no `cpu.utilization`-style file; those files are root-owned, so a regular
    user cannot write them directly: systemd must apply the quota.  `CPUQuota=`
    is therefore the only cgroup CPU cap available, and we apply it at the slice
    level so it bounds the SUM of all concurrent runs.
* CPU, second line of defence: a per-process `ulimit -t` guard
  (`HASKDB_CPU_LIMIT`) so a hang dies instead of spinning, plus `nice`
  (`HASKDB_NICE`) so a busy box is yielded to.
* accounting: the slice reports `CPUUsageNSec`/`MemoryPeak`, which is how the
  20 % budget of rule R-RES is **VERIFIED** rather than assumed.

The implementation mirrors the cgroup recipe documented in
`/home/ryo/work/goopg/goopg/scripts/goopg-test-run.sh` (read it for how the
scope/slice/delegation/OOM-containment knobs work); that tree is a **reference
only** — nothing there is executed or depended on. Our runner is self-contained
and uses `HASKDB_*` names.

### The budget: 20 % of this host, summed over ALL spawned processes

This box: 16 cores, `MemTotal` ≈ 31 GiB. Everything the agent spawns at once may
use at most **20 %** of the machine — i.e. ≤ **3.2 core-equivalents of CPU** and
≤ **6.2 GiB RSS in total**. Export this recipe before any test work (the
script's own defaults already implement it; never fall back to unbounded runs):

```sh
export HASKDB_CG_SLICE=haskdb-workloads        # the aggregate (sum) budget
export HASKDB_SLICE_MEM_HIGH=5G                # aggregate soft cap
export HASKDB_SLICE_MEM_MAX=6G                 # aggregate hard cap ≈ 20 % RAM
export HASKDB_SLICE_SWAP_MAX=0                 # no swap: a freeze is a bug
export HASKDB_CPU_QUOTA=320%                   # aggregate CPU cap = 20 % of 16 cores
export HASKDB_SCOPE_CPU_QUOTA=200%             # per-run cap (a -N2 server)
export HASKDB_MEM_HIGH=1G                      # per-process soft cap
export HASKDB_MEM_MAX=1200M                    # per-process hard cap
export HASKDB_MEM_SWAP_MAX=0
export HASKDB_OOM_SCORE_ADJ=400                # prefer our own runs as victim
export HASKDB_CPU_LIMIT=600                    # per-process CPU seconds, then SIGXCPU
export HASKDB_NICE=15                          # yield CPU when the box is busy
# one unique unit name PER concurrently running command (systemd refuses a
# second live scope with the same name):
export HASKDB_CG_UNIT="haskdb-srv-$$"           # and e.g. "haskdb-cli-$$-$i" in loops
```

`scripts/haskdb-test-run.sh` generates a unique unit name itself when
`HASKDB_CG_UNIT` is unset, and takes `-c` (CPU seconds), `-u` (unit name),
`-n` (nice) and `-q` (slice CPU quota) overrides.  Set
`HASKDB_CG_SLICE=<session>-<n>` to a FRESH name per test session so the slice
accounting below measures only that session.

### Per-scope caps: the GHC toolchain needs a wider scope than a HaskDB run

Measured on this box with the slice accounting above:

* **HaskDB runtime runs** (server + `psql`/`pgbench`) peak at a few tens of MiB,
  so the default `HASKDB_MEM_HIGH=1G HASKDB_MEM_MAX=1200M` is generous.
* **Toolchain-heavy runs** (`cabal build all`, `cabal test all` — GHC compiling
  8 test-suite executables) peak at **≈ 1.258 GiB**, i.e. the default per-scope
  cap SIGKILLS the compile.  For those runs use a wider scope **and** a slice that
  still leaves the sum inside the 20 % budget:
  `HASKDB_MEM_HIGH=2G HASKDB_MEM_MAX=3G` with
  `HASKDB_SLICE_MEM_HIGH=4G HASKDB_SLICE_MEM_MAX=5G`, `HASKDB_CPU_QUOTA=320%`,
  `HASKDB_CPU_LIMIT=900`.
* The rule is unchanged either way: judge the **slice total**, and the observed
  smoke sessions stayed at 0.2–1.5 % of the box's CPU and 0.02 GiB = 0.3 % of the
  20 % memory budget.  A wider per-scope cap raises the ceiling, it does not
  license a bigger run.

Hard rules, in order:

1. **Concurrency ≤ 1 heavy process at a time.** Do not parallelise test suites
   (`cabal test all` is already sequential). A server plus one client is the
   whole allowance — nothing else runs meanwhile.
2. **Bound the threads each process may use.** GHC RTS: `-N1` for test drivers,
   `-N2` for the server — `-N4` on 16 cores is already 25 %, over budget.
   Pass it explicitly: `"x/haskdb-server" +RTS -N2 -RTS <dir> --port <N>`.
3. **Give up CPU when busy:** the runner applies `nice` and `ulimit -t`
   (`HASKDB_CPU_LIMIT`) so a hang dies instead of spinning the box.
4. **Measure it, do not assume it.** Slice accounting reports the aggregate
   usage; use a FRESH slice name per test session (slice accounting accumulates
   over the slice's lifetime), snapshot before and after, and compare deltas:

   ```sh
    SL=haskdb-smoke-1                       # unique per session
    export HASKDB_CG_SLICE="$SL"
    # A fresh slice prints "[not set]" for these, so collapse non-digits to 0.
    cg() { systemctl --user show "$1.slice" --property="$2" 2>/dev/null \
           | sed -n 's/^[^=]*=//p' | grep -E '^[0-9]+$' || echo 0; }
    cores=$(grep -c '^processor *:' /proc/cpuinfo)
    before=$(cg "$SL" CPUUsageNSec); t0=$(date +%s.%N)
    ... the capped runs ...
    after=$(cg "$SL" CPUUsageNSec); t1=$(date +%s.%N)
    peak=$(cg "$SL" MemoryPeak)
    ```

    Then report, and both numbers must be within budget:

    ```sh
    python3 - "$before" "$after" "$t0" "$t1" "$peak" "$cores" \
            "$(awk '/MemTotal/{print $2}' /proc/meminfo)" <<'PY'
    import sys
    b,a,t0,t1,pk,cores,mem=[float(x) for x in sys.argv[1:8]]
    wall=max(t1-t0,1e-9); cpu=(a-b)/1e9
    print(f"CPU  {100*cpu/(wall*cores):.1f}% of the box (budget 20.0%)")
    print(f"MEM  peak {pk/2**30:.2f} GiB = {100*pk/(mem*1024*0.20):.1f}% of the 20% budget")
    PY
    ```

    * CPU: `HASKDB_CPU_QUOTA` (default `320%` = 3.2 of 16 cores) caps the
      aggregate inside the slice, and `nice` + `ulimit -t` back it up; the
      slice measurement above is the proof, so keep a whole session in ONE
      fresh slice.
    * Memory: peak must stay ≤ 20 % of `MemTotal` (≈ 6.2 GiB here); the slice's
      `MemoryMax` (6G) enforces it, and the slice-local OOM kill ends the run
      instead of swapping.
    Judge the **slice total**, never per-process numbers: the rule is about the
    sum across everything spawned. If a run is over budget, shrink it (smaller
    `pgbench -P`/`-s`, fewer table rows, fewer concurrent sessions, one suite at
    a time) and re-run — do not just raise the caps.

5. **Clean up.** The runner passes `--collect`, so a scope's name is free even
   after it fails; if one lingers, `systemctl --user stop "<unit>.scope"`
   (then `reset-failed` if needed). Also `rm -rf` the test scratch dirs
   (`session-test-dir/`, `exec-test-dir/`, `index-test-dir/`,
   `txn-test-dir/`, …) between `cabal test` runs, and never leave a HaskDB
   server running: it holds a flock on its data directory and a listening port.
