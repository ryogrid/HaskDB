#!/usr/bin/env bash
#
# haskdb-test-run.sh — run a command inside a resource-capped cgroup v2 scope.
#
# Every HaskDB test run (server, psql/pgbench smokes, cabal test suites,
# benchmarks) goes through this wrapper, never straight onto the shell.  Why:
# an uncapped pgbench/psql storm plus a server holding a 1024-frame buffer pool
# is enough to drive this box into swap or onto the host-wide OOM killer, and
# on this host (32 GiB RAM, 64 GiB swap, 16 cores) that freezes the whole
# machine for minutes instead of just failing one test.
#
# What it does:
#   * systemd-run --user --scope: the command's whole process tree gets its own
#     transient scope unit, so caps apply to the tree, not to the shell running
#     the script.
#   * per-scope MemoryHigh/MemoryMax: crossing MemoryMax lets the cgroup-local
#     OOM killer SIGKILL ONLY this command's tree; the host-wide OOM killer
#     never fires.  "the test died" instead of "the box died".
#   * MemorySwapMax=0: with 64 GiB of swap an unbounded run thrashes swap
#     (whole box unresponsive for minutes) long before any OOM kill; denying
#     the scope's swap turns that slow freeze into a prompt, clean kill.
#   * a shared SLICE whose MemoryHigh/MemoryMax/CPUQuota bound the SUM of every
#     concurrently capped run: per-scope caps cannot see sibling scopes, so
#     aggregate oversubscription dies inside the slice (the kernel picks the
#     member with the highest badness, biased by OOMScoreAdjust) instead of
#     tripping the host-wide killer.
#   * CPUQuota on the slice: an AGGREGATE CPU cap for the whole workload group.
#     Verified on this host (kernel 6.18-WSL2, systemd 255): the slice reports
#     the quota and it is enforced — with CPUQuota=300% and 8 busy workers in
#     8 scopes the slice accounted 18.3 s of CPU over ~6 s of wall time, i.e.
#     it was held to ~3 cores.  This build rejects the newer names
#     (CPUUtilization=/CGroupCPU=/CGroupSlice= answer "Unknown assignment")
#     and the kernel exposes only cpu.max/cpu.weight under
#     /sys/fs/cgroup/user.slice/user-<uid>.slice (no cpu.utilization files).
#   * a per-process `ulimit -t` CPU-seconds guard and `nice`: a hang dies
#     instead of spinning, and a busy box is yielded to.
#   * accounting: the slice reports CPUUsageNSec/MemoryPeak, which is how the
#     20 % budget of AGENT.md rule R-RES is VERIFIED rather than assumed.
#
# Usage:
#   scripts/haskdb-test-run.sh <command> [args...]
#   scripts/haskdb-test-run.sh -c 900 -u haskdb-server -- ./bin/haskdb-server +RTS -N2 -RTS dir
#
# Examples:
#   scripts/haskdb-test-run.sh ./x/haskdb-server +RTS -N2 -RTS /tmp/db --port 5501
#   scripts/haskdb-test-run.sh cabal test all
#   scripts/haskdb-test-run.sh psql -h 127.0.0.1 -p 5501 -c 'select count(x) from t;'
#
# Tunables (environment variables; defaults implement AGENT.md rule R-RES, the
# 20 % budget on this 16-core / 32 GiB box):
#   HASKDB_MEM_HIGH        soft cap, reclaim+throttle starts     (default 1G)
#   HASKDB_MEM_MAX         hard cap, scope-local OOM kill        (default 1200M)
#   HASKDB_MEM_SWAP_MAX    swap allowed to the scope             (default 0)
#   HASKDB_CG_SLICE        slice = the AGGREGATE budget          (default haskdb-workloads)
#                          empty string disables the slice (per-scope caps only)
#   HASKDB_SLICE_MEM_HIGH  aggregate soft cap over the slice     (default 5G)
#   HASKDB_SLICE_MEM_MAX   aggregate hard cap, slice OOM kill    (default 6G)
#   HASKDB_SLICE_SWAP_MAX  aggregate swap cap                    (default 0)
#   HASKDB_CPU_QUOTA       aggregate CPU cap on the slice        (default 320%)
#                          percentage semantics: 100% = one core, so 320% ~
#                          20% of 16 cores; empty/none disables the quota
#   HASKDB_SCOPE_CPU_QUOTA optional per-scope CPU cap           (default empty)
#                          e.g. 200% for a -N2 server so one run alone cannot
#                          eat the whole aggregate budget
#   HASKDB_CG_UNIT         transient scope unit name (default: generated unique)
#                          MUST be unique per concurrently running command
#   HASKDB_OOM_SCORE_ADJ   OOMScoreAdjust, inherited by children (default 400)
#   HASKDB_CPU_LIMIT       per-process CPU seconds before SIGXCPU (default 600)
#                          empty/0 disables the guard
#   HASKDB_NICE            nice value for the command            (default 15)
#
# Stopping a backgrounded run by name:
#   systemctl --user stop "<unit>.scope"
#
# The cgroup mechanics follow the recipe documented in
#   /home/ryo/work/goopg/goopg/scripts/goopg-test-run.sh
# (reference only: this script is self-contained and uses HaskDB names, so
# nothing under the goopg tree is executed or depended on at build/run time).
#
set -euo pipefail

usage() {
    echo "usage: $0 [-c CPU_SECONDS] [-u UNIT] [-n NICE] [-q CPU_QUOTA] [--] <command> [args...]" >&2
    exit 2
}

CPU_LIMIT="${HASKDB_CPU_LIMIT-600}"
CG_UNIT="${HASKDB_CG_UNIT-}"
NICE="${HASKDB_NICE-15}"
QUOTA="${HASKDB_CPU_QUOTA-320%}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        -c) CPU_LIMIT="${2:-}"; shift 2 ;;
        -u) CG_UNIT="${2:-}"; shift 2 ;;
        -n) NICE="${2:-15}"; shift 2 ;;
        -q) QUOTA="${2:-}"; shift 2 ;;
        -h) usage ;;
        --) shift; break ;;
        *)  break ;;
    esac
done

if [ "$#" -eq 0 ]; then
    usage
fi

MEM_HIGH="${HASKDB_MEM_HIGH:-1G}"
MEM_MAX="${HASKDB_MEM_MAX:-1200M}"
MEM_SWAP_MAX="${HASKDB_MEM_SWAP_MAX-0}"
CG_SLICE="${HASKDB_CG_SLICE-haskdb-workloads}"
SLICE_HIGH="${HASKDB_SLICE_MEM_HIGH:-5G}"
SLICE_MAX="${HASKDB_SLICE_MEM_MAX:-6G}"
SLICE_SWAP_MAX="${HASKDB_SLICE_SWAP_MAX-0}"
SLICE_QUOTA="$QUOTA"
SCOPE_QUOTA="${HASKDB_SCOPE_CPU_QUOTA-}"
OOM_ADJ="${HASKDB_OOM_SCORE_ADJ-400}"

# A unit name must not collide with a live scope.  Generate one when the caller
# did not supply it: $$ (shell pid) plus $RANDOM keeps concurrent runs apart.
if [ -z "$CG_UNIT" ]; then
    CG_UNIT="haskdb-run-${$$}-${RANDOM:-0}"
fi

# Only digits may reach a [ -lt ] comparison, so a unit-suffixed cap token can
# never be evaluated as arithmetic by bash.
pure_num() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# to_bytes: systemd resource dialects (bare bytes, K/M/G/T base-1024,
# infinity) plus the GHC-ish MiB/GiB spellings, so caps can be compared.
to_bytes() {
    local v unit mult
    v="${1^^}"
    case "$v" in
        INFINITY) echo "infinity"; return 0 ;;
    esac
    local num
    num="${v%%[A-Z]*}"
    unit="${v#"$num"}"
    mult=0
    case "$unit" in
        "") mult=1 ;;
        "B") mult=1 ;;
        "K"|"KIB") mult=1024 ;;
        "M"|"MIB") mult=$((1024 * 1024)) ;;
        "G"|"GIB") mult=$((1024 * 1024 * 1024)) ;;
        "T"|"TIB") mult=$((1024 * 1024 * 1024 * 1024)) ;;
    esac
    case "$num" in
        '' | *[!0-9]*) return 1 ;;
    esac
    if [ "$mult" -eq 0 ]; then
        return 1
    fi
    echo $((num * mult))
}

high_b="$(to_bytes "$MEM_HIGH" || true)"
max_b="$(to_bytes "$MEM_MAX" || true)"
slice_high_b="$(to_bytes "$SLICE_HIGH" || true)"
slice_max_b="$(to_bytes "$SLICE_MAX" || true)"
if pure_num "$high_b" && pure_num "$max_b" && [ "$max_b" -lt "$high_b" ]; then
    echo "haskdb-test-run: WARNING — HASKDB_MEM_MAX (${MEM_MAX}) is below HASKDB_MEM_HIGH (${MEM_HIGH}): the hard cap fires before the soft one" >&2
fi
if pure_num "$slice_high_b" && pure_num "$slice_max_b" && [ "$slice_max_b" -lt "$slice_high_b" ]; then
    echo "haskdb-test-run: WARNING — HASKDB_SLICE_MEM_MAX (${SLICE_MAX}) is below HASKDB_SLICE_MEM_HIGH (${SLICE_HIGH})" >&2
fi

uid="$(id -u)"
controllers="/sys/fs/cgroup/user.slice/user-${uid}.slice/user@${uid}.service/cgroup.controllers"

if command -v systemd-run >/dev/null 2>&1 \
   && [ -r "$controllers" ] \
   && grep -qw memory "$controllers"; then

    slice_args=()
    if [ -n "$CG_SLICE" ]; then
        # The AGGREGATE budget: every capped scope lands in this slice, whose
        # caps bound their SUM.  --runtime keeps it in a transient drop-in
        # (survives concurrent launches, idempotent, re-applied every run so a
        # daemon-reload cannot silently drop it).
        props=(MemoryHigh="$SLICE_HIGH" MemoryMax="$SLICE_MAX" MemorySwapMax="$SLICE_SWAP_MAX")
        case "$SLICE_QUOTA" in
            "" | none | off) SLICE_QUOTA="" ;;
            *[!0-9%]*)
                echo "haskdb-test-run: WARNING — ignoring unparsable HASKDB_CPU_QUOTA='${SLICE_QUOTA}' (want e.g. 320%): slice CPU quota NOT applied" >&2
                SLICE_QUOTA=""
                ;;
            *) props+=(CPUQuota="$SLICE_QUOTA") ;;
        esac
        if systemctl --user set-property --runtime "${CG_SLICE}.slice" "${props[@]}" 2>/dev/null; then
            slice_args+=(--slice="${CG_SLICE}.slice")
            echo "haskdb-test-run: slice=${CG_SLICE} MemoryHigh=${SLICE_HIGH} MemoryMax=${SLICE_MAX} MemorySwapMax=${SLICE_SWAP_MAX} CPUQuota=${SLICE_QUOTA:-none} (aggregate budget)" >&2
            # Read the quota back: if systemd could not apply it (older unit,
            # kernel without the control), warn instead of silently running
            # uncapped, which is exactly the failure mode R-RES guards against.
            case "$SLICE_QUOTA" in
                "" | none | off) : ;;
                *)
                    got="$(systemctl --user show "${CG_SLICE}.slice" --property=CPUQuotaPerSecUSec 2>/dev/null \
                          | sed -n 's/^CPUQuotaPerSecUSec=//p')"
                    case "$got" in
                        infinity*) echo "haskdb-test-run: WARNING — CPUQuota=${SLICE_QUOTA} did NOT apply to ${CG_SLICE}.slice (reports ${got:-unknown}): aggregate CPU is NOT capped" >&2 ;;
                    esac
                    ;;
            esac
        else
            echo "haskdb-test-run: WARNING — could not configure ${CG_SLICE}.slice; per-scope caps only (no aggregate budget)" >&2
        fi
    fi

    # OOM victim preference.  Scope units reject -p OOMScoreAdjust= (a scope
    # spawns no process of its own), so set this process's oom_score_adj, which
    # fork+exec hands down to the whole workload tree.
    case "$OOM_ADJ" in
        "" | 0 | +0) : ;;
        *[!0-9+-]*) echo "haskdb-test-run: WARNING — ignoring unparsable HASKDB_OOM_SCORE_ADJ='${OOM_ADJ}'" >&2 ;;
        *) echo "${OOM_ADJ#+}" > /proc/self/oom_score_adj 2>/dev/null \
             || echo "haskdb-test-run: WARNING — could not set oom_score_adj=${OOM_ADJ}" >&2 ;;
    esac

    # CPU: cgroup CPUQuota (above) bounds the aggregate; per process we also add
    # a ulimit -t CPU-seconds guard so a hang dies instead of spinning.  Both
    # are best effort: a failing guard only warns.
    cpu_note=""
    if [ -n "$CPU_LIMIT" ] && [ "$CPU_LIMIT" != "0" ]; then
        case "$CPU_LIMIT" in
            *[!0-9]*) echo "haskdb-test-run: WARNING — ignoring unparsable HASKDB_CPU_LIMIT='${CPU_LIMIT}'" >&2 ;;
            *) cpu_note="ulimit -t ${CPU_LIMIT};" ;;
        esac
    fi

    scope_props=(-p MemoryHigh="$MEM_HIGH" -p MemoryMax="$MEM_MAX" -p MemorySwapMax="$MEM_SWAP_MAX")
    case "$SCOPE_QUOTA" in
        "" | none | off) : ;;
        *[!0-9%]*)
            echo "haskdb-test-run: WARNING — ignoring unparsable HASKDB_SCOPE_CPU_QUOTA='${SCOPE_QUOTA}': per-scope CPU quota NOT applied" >&2
            ;;
        *) scope_props+=(-p CPUQuota="$SCOPE_QUOTA") ;;
    esac

    echo "haskdb-test-run: scope=${CG_UNIT} MemoryHigh=${MEM_HIGH} MemoryMax=${MEM_MAX} MemorySwapMax=${MEM_SWAP_MAX} oom_score_adj=${OOM_ADJ} cpu_limit=${CPU_LIMIT:-none} nice=${NICE}" >&2

    # --collect: unload the scope unit even on failure/OOM, so its name is free
    #            for the next run without a manual reset-failed.
    # --expand-environment=no: argv passes through verbatim (the caller's shell
    #            already expanded it).
    # The inner sh carries the CPU guard + nice; "$0"/"$@" keeps the payload's
    # own quoting (RTS flags included).
    if [ -n "$cpu_note" ]; then
        exec systemd-run --user --scope --quiet --collect \
            --expand-environment=no \
            --unit="$CG_UNIT" \
            "${slice_args[@]}" \
            "${scope_props[@]}" \
            -- sh -c "$cpu_note exec nice -n $NICE \"\$@\"" _ "$@"
    fi
    exec systemd-run --user --scope --quiet --collect \
        --expand-environment=no \
        --unit="$CG_UNIT" \
        "${slice_args[@]}" \
        "${scope_props[@]}" \
        -- nice -n "$NICE" -- "$@"
fi

echo "haskdb-test-run: WARNING — no systemd cgroup memory delegation here: running UNCAPPED (memory/CPU cgroup caps are off; only the caller's own limits apply)" >&2
if [ -n "$CPU_LIMIT" ] && [ "$CPU_LIMIT" != "0" ]; then
    exec sh -c "ulimit -t $CPU_LIMIT; exec nice -n $NICE \"\$@\"" _ "$@"
fi
exec nice -n "$NICE" -- "$@"
