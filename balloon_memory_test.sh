#!/usr/bin/env bash
# balloon_memory_test.sh — virtio-balloon host memory reclamation test
#
# Proves whether macOS Virtualization.framework actually returns
# memory to the host when the guest frees it and the balloon inflates.
#
# Test design:
#   1. Start Colima VM (1GB) — record host "Virtual Machine Service" RSS
#   2. Allocate ~256MB inside the guest via dd to tmpfs
#   3. Record host RSS (should rise ~256MB)
#   4. Free the guest memory
#   5. Wait for balloon + record host RSS over 2 minutes
#   6. Report: did host RSS decrease? By how much? How fast?
#
# Safety (designed for 32GB M1 Max with LM Studio as neighbor):
#   - Preflight: abort if LM Studio is loaded or <8GB available
#   - Phase check: abort if swap>128MB or compressed>1.5GB
#   - Killswitch: force-kill VM if swap>256MB or compressed>2GB (2s poll)
#   - Small VM (1GB) + small alloc (256MB) = minimal host pressure
#
# This test produces data suitable for:
#   - Apple Feedback (FB) bug report
#   - Lima issue #2789 / #4220 comments
#   - Validating Lima PR #4828 (adaptive balloon controller)
#
# Prerequisites:
#   - Colima installed (uses vz/Virtualization.framework backend)
#   - No other VMs running (for clean measurement)
#   - LM Studio models unloaded (preflight enforces this)
#
# Usage:
#   ./tests/balloon_memory_test.sh                    # default 1 cycle
#   ./tests/balloon_memory_test.sh --cycles 3         # more data points
#   ./tests/balloon_memory_test.sh --alloc-mb 512     # larger allocation
#   ./tests/balloon_memory_test.sh --wait-secs 300    # longer observation
#
# Output:
#   .runtime_logs/balloon/
#     balloon_<ts>.jsonl    — per-second host memory samples
#     balloon_<ts>.csv      — summary (for spreadsheets / Apple FB)
#     balloon_<ts>.txt      — human-readable report

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/.runtime_logs/balloon"
CYCLES=1
ALLOC_MB=256        # small alloc — enough to prove balloon behavior
WAIT_SECS=120       # observation window after guest free (2min is sufficient)
SETTLE_SECS=20      # settle after VM start before allocation
VM_MEMORY=1         # Colima VM memory in GB (1GB is minimum viable for test)
VM_CPU=2
VM_DISK=30
HOST_FREE_FLOOR_MB=4096   # abort if host FREE pages drop below this
HOST_PRE_START_MIN_MB=8192 # require 8GB truly free before starting VM
STRESS_TIMEOUT_SECS=30    # stress-ng hard timeout (prevents runaway holds)
KILLSWITCH_PID=""          # background safety watchdog PID
KILLSWITCH_FLOOR_MB=2048   # force-kill VM if free drops below this

while [ $# -gt 0 ]; do
    case "$1" in
        --cycles)      CYCLES="$2"; shift 2 ;;
        --alloc-mb)    ALLOC_MB="$2"; shift 2 ;;
        --wait-secs)   WAIT_SECS="$2"; shift 2 ;;
        --settle-secs) SETTLE_SECS="$2"; shift 2 ;;
        --vm-memory)   VM_MEMORY="$2"; shift 2 ;;
        --floor-mb)    HOST_FREE_FLOOR_MB="$2"; shift 2 ;;
        -h|--help)     sed -n '2,/^$/s/^# //p' "$0"; exit 0 ;;
        *)             echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Sanity: alloc must fit inside VM with room for the OS
VM_MEMORY_MB=$((VM_MEMORY * 1024))
MAX_ALLOC_MB=$((VM_MEMORY_MB * 3 / 4))
if [ "${ALLOC_MB}" -gt "${MAX_ALLOC_MB}" ]; then
    echo "ERROR: --alloc-mb ${ALLOC_MB} exceeds 75% of VM memory (${VM_MEMORY}GB = ${MAX_ALLOC_MB}MB max)"
    echo "  Either increase --vm-memory or decrease --alloc-mb"
    exit 2
fi

mkdir -p "${LOG_DIR}"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SAMPLE_LOG="${LOG_DIR}/balloon_${TIMESTAMP}.jsonl"
SUMMARY_CSV="${LOG_DIR}/balloon_${TIMESTAMP}.csv"
REPORT_FILE="${LOG_DIR}/balloon_${TIMESTAMP}.txt"

# ── helpers ──────────────────────────────────────────────────────

_iso_ts() {
    date +"%Y-%m-%dT%H:%M:%S%z"
}

# Emit a sample to the JSONL log. Single python3 call gathers all
# host metrics, VMS RSS, and writes the sample in one shot.
# Prints the VMS RSS (MB) to stdout for the caller.
_sample() {
    local phase="$1"
    local cycle="$2"
    local seq="$3"
    python3 -c "
import subprocess, json, re, time

# VMS RSS — the number we're testing
# On macOS 26+, the Virtualization.framework host process is:
#   com.apple.Virtualization.VirtualMachine
# Older versions may use 'Virtual Machine Service'.
# We match both to be robust across macOS versions.
ps_out = subprocess.check_output(
    ['ps', 'axo', 'pid,rss,command'], text=True, stderr=subprocess.DEVNULL)
vms_rss_kb = 0
for line in ps_out.splitlines():
    ll = line.lower()
    if 'virtualization.virtualmachine' in ll or 'virtual machine service' in ll:
        parts = line.split()
        if len(parts) >= 2:
            try: vms_rss_kb += int(parts[1])
            except ValueError: pass
vms_rss_mb = vms_rss_kb // 1024

# Host memory via vm_stat
out = subprocess.check_output(['vm_stat'], text=True)
def v(name):
    for l in out.splitlines():
        if name in l:
            return int(l.split(':')[1].strip().rstrip('.'))
    return 0
ps = 16384
wired = v('wired') * ps
active = v('Pages active') * ps
compressed = v('occupied by compressor') * ps
inactive = v('Pages inactive') * ps
free = v('Pages free') * ps

sw = subprocess.check_output(
    ['sysctl', '-n', 'vm.swapusage'], text=True).strip()
m_used = re.search(r'used\s*=\s*([\d.]+)M', sw)
swap_mb = float(m_used.group(1)) if m_used else 0

sample = {
    'epoch_ms': int(time.time() * 1000),
    'phase': '${phase}',
    'cycle': ${cycle},
    'seq': ${seq},
    'vms_rss_mb': vms_rss_mb,
    'host': {
        'used_gb': round((wired + active + compressed) / (1024**3), 2),
        'free_gb': round((inactive + free) / (1024**3), 2),
        'wired_mb': round(wired / (1024**2)),
        'active_mb': round(active / (1024**2)),
        'compressed_mb': round(compressed / (1024**2)),
        'inactive_mb': round(inactive / (1024**2)),
        'free_mb': round(free / (1024**2)),
        'swap_used_mb': round(swap_mb),
    },
}

with open('${SAMPLE_LOG}', 'a') as f:
    f.write(json.dumps(sample, separators=(',', ':')) + '\n')
print(vms_rss_mb)
" 2>/dev/null || echo "0"
}

# Host memory safety gate — abort before we OOM the machine
# ONLY counts truly free pages. Inactive is NOT reliable under pressure.
_host_free_mb() {
    python3 -c "
import subprocess
out = subprocess.check_output(['vm_stat'], text=True)
def v(name):
    for l in out.splitlines():
        if name in l:
            return int(l.split(':')[1].strip().rstrip('.'))
    return 0
ps = 16384
free = v('Pages free') * ps
print(int(free / (1024**2)))
" 2>/dev/null || echo "0"
}

_check_host_memory() {
    local phase="$1"
    local result
    result=$(python3 -c "
import subprocess, re
sw = subprocess.check_output(['sysctl', '-n', 'vm.swapusage'], text=True)
m = re.search(r'used\s*=\s*([\d.]+)M', sw)
swap_mb = int(float(m.group(1))) if m else 0
out = subprocess.check_output(['vm_stat'], text=True)
def v(name):
    for l in out.splitlines():
        if name in l:
            return int(l.split(':')[1].strip().rstrip('.'))
    return 0
compressed_mb = v('occupied by compressor') * 16384 // (1024**2)
if swap_mb > 128 or compressed_mb > 1536:
    print(f'DANGER swap={swap_mb}MB compressed={compressed_mb}MB')
else:
    print('OK')
" 2>/dev/null || echo "OK")
    if [[ "${result}" == DANGER* ]]; then
        echo ""
        echo "  *** SAFETY ABORT ***"
        echo "  Host memory pressure: ${result}"
        echo "  Phase: ${phase}"
        echo "  Killing guest workloads and stopping VM to protect host..."
        _guest_free
        _stop_colima
        echo "  Test halted. Review partial results in ${LOG_DIR}/"
        exit 3
    fi
}

# ── killswitch watchdog ──────────────────────────────────────────
# Self-contained safety net: polls free pages every 2s, force-kills
# the VM if free memory drops dangerously low. This test is designed
# to be standalone (shareable for Apple FB / Lima issues) so it
# cannot depend on external daemons.

_killswitch_loop() {
    local parent_pid="$$"
    while true; do
        sleep 2
        # Real pressure = swap growing + compression. Free pages alone
        # is meaningless on macOS (it aggressively converts free→inactive).
        local result
        result=$(python3 -c "
import subprocess, re
out = subprocess.check_output(['vm_stat'], text=True)
def v(name):
    for l in out.splitlines():
        if name in l:
            return int(l.split(':')[1].strip().rstrip('.'))
    return 0
ps = 16384
compressed_mb = v('occupied by compressor') * ps // (1024**2)
sw = subprocess.check_output(['sysctl', '-n', 'vm.swapusage'], text=True)
m = re.search(r'used\s*=\s*([\d.]+)M', sw)
swap_mb = int(float(m.group(1))) if m else 0
# Danger: swap > 256MB OR compressed > 2GB
if swap_mb > 256 or compressed_mb > 2048:
    print(f'KILL swap={swap_mb}MB compressed={compressed_mb}MB')
else:
    print(f'OK swap={swap_mb}MB compressed={compressed_mb}MB')
" 2>/dev/null || echo "OK")
        if [[ "${result}" == KILL* ]]; then
            echo ""
            echo "  *** KILLSWITCH: ${result} ***"
            echo "  Force-stopping Colima to protect host..."
            colima stop --force 2>/dev/null || true
            pkill -f stress-ng 2>/dev/null || true
            colima delete --force 2>/dev/null || true
            echo "  Killswitch fired. Partial data in ${LOG_DIR}/"
            kill -USR1 "${parent_pid}" 2>/dev/null || true
            exit 0
        fi
    done
}

_start_killswitch() {
    _killswitch_loop &
    KILLSWITCH_PID=$!
    echo "  Killswitch watchdog started (PID ${KILLSWITCH_PID}, floor ${KILLSWITCH_FLOOR_MB}MB free)"
}

_stop_killswitch() {
    if [ -n "${KILLSWITCH_PID}" ] && kill -0 "${KILLSWITCH_PID}" 2>/dev/null; then
        kill "${KILLSWITCH_PID}" 2>/dev/null || true
        wait "${KILLSWITCH_PID}" 2>/dev/null || true
        KILLSWITCH_PID=""
    fi
}

trap '_stop_killswitch; echo "  Killswitch triggered — exiting."; exit 3' USR1
trap '_stop_killswitch' EXIT

# ── pre-start memory gate ───────────────────────────────────────

_host_available_mb() {
    # free + inactive — valid at rest when no pressure exists yet
    python3 -c "
import subprocess
out = subprocess.check_output(['vm_stat'], text=True)
def v(name):
    for l in out.splitlines():
        if name in l:
            return int(l.split(':')[1].strip().rstrip('.'))
    return 0
ps = 16384
free = v('Pages free') * ps
inactive = v('Pages inactive') * ps
print(int((free + inactive) / (1024**2)))
" 2>/dev/null || echo "0"
}

_preflight_memory_check() {
    # Warn if LM Studio is running — it holds GB of RAM
    local lms_rss_mb
    lms_rss_mb=$(ps axo rss,comm 2>/dev/null \
        | grep -i "LM Studio" | grep -v grep \
        | awk '{sum += $1} END {printf "%d", sum/1024}')
    if [ "${lms_rss_mb:-0}" -gt 500 ]; then
        echo ""
        echo "  *** PREFLIGHT ABORT ***"
        echo "  LM Studio is using ~${lms_rss_mb}MB of RAM."
        echo "  On a 32GB machine this leaves too little headroom."
        echo "  Unload models (lms unload --all) or quit LM Studio, then retry."
        echo ""
        exit 3
    fi

    local avail_mb
    avail_mb=$(_host_available_mb)
    local used_gb
    used_gb=$(python3 -c "
import subprocess
out = subprocess.check_output(['vm_stat'], text=True)
def v(name):
    for l in out.splitlines():
        if name in l:
            return int(l.split(':')[1].strip().rstrip('.'))
    return 0
ps = 16384
w = v('wired') * ps; a = v('Pages active') * ps; c = v('occupied by compressor') * ps
print(f'{(w+a+c)/(1024**3):.1f}')
" 2>/dev/null || echo "?")
    echo "  Pre-flight: ${used_gb}GB used, ${avail_mb}MB available (free+inactive)"
    if [ "${avail_mb}" -lt "${HOST_PRE_START_MIN_MB}" ]; then
        echo ""
        echo "  *** PREFLIGHT ABORT ***"
        echo "  Not enough available memory to safely run this test."
        echo "  Available: ${avail_mb}MB, Required: ${HOST_PRE_START_MIN_MB}MB"
        echo "  Close memory-heavy apps (LM Studio, browsers) and retry."
        echo ""
        exit 3
    fi
}

# ── colima management ────────────────────────────────────────────

_colima_is_up() {
    colima status &>/dev/null
}

_stop_colima() {
    if _colima_is_up; then
        echo "  Stopping Colima..."
        colima stop 2>/dev/null || colima stop --force 2>/dev/null || true
        sleep 3
    fi
    # Clear stale disk locks — Colima can report "stopped" while Lima
    # still holds the disk attachment, causing the next start to fail
    # with: "failed to run attach disk, in use by instance"
    if colima list 2>/dev/null | grep -q "Stopped"; then
        echo "  Cleaning stale Colima instance..."
        colima delete --force 2>/dev/null || true
        sleep 2
    fi
}

_start_colima() {
    echo "  Starting Colima (${VM_CPU} CPU, ${VM_MEMORY}GB RAM, ${VM_DISK}GB disk)..."
    colima start --cpu "${VM_CPU}" --memory "${VM_MEMORY}" --disk "${VM_DISK}" 2>&1 | tail -3
    # Wait for SSH
    local w=0
    while [ "${w}" -lt 30 ]; do
        if colima ssh -- true 2>/dev/null; then
            echo "  Colima SSH ready (${w}s)"
            return 0
        fi
        sleep 1
        w=$((w + 1))
    done
    echo "  WARN: Colima SSH not ready after 30s"
    return 1
}

# Allocate memory inside the guest via dd to tmpfs (/dev/shm).
# tmpfs is backed by guest RAM — allocation stays until we delete
# the file. This is more reliable than stress-ng for controlled
# alloc/free because there's no timeout race.
_guest_alloc() {
    local mb="$1"
    echo "  Allocating ${mb}MB inside guest (dd → /dev/shm)..."
    colima ssh -- dd if=/dev/urandom of=/dev/shm/balloon_test bs=1M count="${mb}" 2>/dev/null
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        echo "  WARN: dd failed (rc=${rc}), trying stress-ng fallback..."
        if colima ssh -- which stress-ng &>/dev/null; then
            colima ssh -- sh -c 'nohup stress-ng --vm 1 --vm-bytes '"${mb}"'M --vm-hang 0 --timeout '"${STRESS_TIMEOUT_SECS}"'s &' 2>/dev/null
        else
            echo "  FATAL: neither dd nor stress-ng available in guest"
            return 1
        fi
    fi
}

# Snapshot guest memory via /proc/meminfo. Returns JSON with key
# fields. Called at phase boundaries only (not per-second) because
# each call requires an SSH round-trip.
_guest_mem_json() {
    colima ssh -- cat /proc/meminfo 2>/dev/null | python3 -c "
import sys, json
fields = {}
for line in sys.stdin:
    parts = line.split()
    if len(parts) >= 2:
        key = parts[0].rstrip(':')
        try: fields[key] = int(parts[1])
        except ValueError: pass
# All values in kB from /proc/meminfo, convert to MB
total = fields.get('MemTotal', 0) // 1024
free = fields.get('MemFree', 0) // 1024
avail = fields.get('MemAvailable', 0) // 1024
cached = fields.get('Cached', 0) // 1024
shmem = fields.get('Shmem', 0) // 1024
print(json.dumps({
    'total_mb': total,
    'free_mb': free,
    'available_mb': avail,
    'cached_mb': cached,
    'shmem_mb': shmem,
}))
" 2>/dev/null || echo '{"error":"guest_meminfo_failed"}'
}

# Log a guest memory snapshot to JSONL at a phase boundary
_guest_sample() {
    local phase="$1"
    local cycle="$2"
    local guest_mem
    guest_mem=$(_guest_mem_json)
    python3 -c "
import json, time
sample = {
    'epoch_ms': int(time.time() * 1000),
    'type': 'guest_mem',
    'phase': '${phase}',
    'cycle': ${cycle},
    'guest': ${guest_mem},
}
with open('${SAMPLE_LOG}', 'a') as f:
    f.write(json.dumps(sample, separators=(',', ':')) + '\n')
print(json.dumps(${guest_mem}))
" 2>/dev/null || echo '{}'
}

_guest_free() {
    echo "  Freeing guest memory..."
    # Kill stress-ng — SIGTERM then SIGKILL to ensure it dies
    colima ssh -- pkill -f stress-ng 2>/dev/null || true
    sleep 1
    colima ssh -- pkill -9 -f stress-ng 2>/dev/null || true
    # Remove tmpfs file
    colima ssh -- rm -f /dev/shm/balloon_test 2>/dev/null || true
    # Drop caches inside guest to help balloon
    colima ssh -- sh -c 'echo 3 | sudo tee /proc/sys/vm/drop_caches' 2>/dev/null || true
    # Compact memory
    colima ssh -- sh -c 'echo 1 | sudo tee /proc/sys/vm/compact_memory' 2>/dev/null || true
}

# ── system info ──────────────────────────────────────────────────

_system_info() {
    python3 -c "
import subprocess, platform, json
chip = subprocess.check_output(
    ['sysctl', '-n', 'machdep.cpu.brand_string'],
    text=True).strip()
mem_bytes = int(subprocess.check_output(
    ['sysctl', '-n', 'hw.memsize'], text=True).strip())
os_ver = platform.mac_ver()[0]
colima_ver = subprocess.check_output(
    ['colima', 'version'], text=True).strip().split('\n')[0]
print(json.dumps({
    'chip': chip,
    'memory_gb': mem_bytes // (1024**3),
    'macos_version': os_ver,
    'colima_version': colima_ver,
    'kernel': platform.release(),
}))
" 2>/dev/null || echo '{"error":"sysinfo_failed"}'
}

# ── main ─────────────────────────────────────────────────────────

echo "=========================================="
echo "Virtio-Balloon Memory Reclamation Test"
echo "=========================================="
echo "  cycles:      ${CYCLES}"
echo "  alloc:       ${ALLOC_MB}MB per cycle"
echo "  observation: ${WAIT_SECS}s after guest free"
echo "  VM config:   ${VM_CPU} CPU, ${VM_MEMORY}GB RAM"
echo "  safety:      swap>128MB or compressed>1.5GB → abort phase"
echo "  preflight:   ${HOST_PRE_START_MIN_MB}MB available (free+inactive) to start"
echo "  killswitch:  swap>256MB or compressed>2GB → force-kill VM (2s poll)"
echo "  output:      ${LOG_DIR}/"
echo "  started:     $(_iso_ts)"
echo "=========================================="
echo ""

SYS_INFO=$(_system_info)
echo "System: $(echo "${SYS_INFO}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f"{d.get(\"chip\",\"?\")}, {d.get(\"memory_gb\",\"?\")}GB, macOS {d.get(\"macos_version\",\"?\")}, {d.get(\"colima_version\",\"?\")}")
' 2>/dev/null)"
echo ""

# Write system info as first line
python3 -c "
import json
info = ${SYS_INFO}
info['type'] = 'system_info'
info['alloc_mb'] = ${ALLOC_MB}
info['wait_secs'] = ${WAIT_SECS}
info['vm_memory_gb'] = ${VM_MEMORY}
info['cycles'] = ${CYCLES}
print(json.dumps(info, separators=(',', ':')))
" >> "${SAMPLE_LOG}"

# CSV header
echo "cycle,phase,vms_rss_mb,host_used_gb,host_free_gb,swap_mb,elapsed_s,epoch_ms" \
    > "${SUMMARY_CSV}"

# Preflight: enough free memory before we even start?
_preflight_memory_check

# Start background killswitch watchdog
_start_killswitch

# Clean start
_stop_colima

for cycle in $(seq 1 "${CYCLES}"); do
    _check_host_memory "pre-cycle ${cycle}"
    echo ""
    echo "── Cycle ${cycle}/${CYCLES} ──────────────────────────────"

    # Phase 1: baseline (before VM start)
    echo "[phase:baseline] Recording pre-VM host memory..."
    baseline_rss=$(_sample "baseline" "${cycle}" 0)
    echo "  VMS RSS: ${baseline_rss}MB (should be 0 — no VM running)"

    # Phase 2: start VM
    echo "[phase:vm_start] Starting Colima VM..."
    if ! _start_colima; then
        echo "  FATAL: Colima failed to start — skipping cycle ${cycle}"
        _sample "vm_start_failed" "${cycle}" 0 > /dev/null
        _stop_colima
        continue
    fi

    # Verify vz backend — the balloon bug is Virtualization.framework specific
    if [ "${cycle}" -eq 1 ]; then
        vm_type=$(colima status --json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    driver = data.get('driver', '').lower()
    if 'virtualization' in driver or 'vz' in driver:
        print('vz')
    elif 'qemu' in driver:
        print('qemu')
    else:
        print(data.get('driver', 'unknown'))
except: print('unknown')
" 2>/dev/null || echo "unknown")
        echo "  VM backend: ${vm_type}"
        if [ "${vm_type}" != "vz" ] && [ "${vm_type}" != "unknown" ]; then
            echo ""
            echo "  *** ABORT: Colima is using '${vm_type}' backend, not 'vz'. ***"
            echo "  This test targets Virtualization.framework (vz) balloon behavior."
            echo "  Restart Colima with: colima start --vm-type vz ..."
            _stop_colima
            exit 2
        fi
    fi

    echo "  Settling ${SETTLE_SECS}s..."
    for s in $(seq 1 "${SETTLE_SECS}"); do
        _sample "vm_idle" "${cycle}" "${s}" > /dev/null
        sleep 1
    done
    idle_rss=$(_sample "vm_idle_end" "${cycle}" 0)
    echo "  VMS RSS after settle: ${idle_rss}MB"

    # Guest memory snapshot: pre-allocation baseline
    guest_idle=$(_guest_sample "guest_idle" "${cycle}")
    echo "  Guest memory (idle): ${guest_idle}"

    # Phase 3: allocate inside guest
    _check_host_memory "pre-alloc cycle ${cycle}"
    echo "[phase:alloc] Allocating ${ALLOC_MB}MB inside guest..."
    _guest_alloc "${ALLOC_MB}"
    echo "  Waiting 15s for host RSS to reflect guest allocation..."
    for s in $(seq 1 15); do
        _sample "alloc" "${cycle}" "${s}" > /dev/null
        sleep 1
    done
    peak_rss=$(_sample "alloc_peak" "${cycle}" 0)
    echo "  VMS RSS at peak: ${peak_rss}MB (growth: $((peak_rss - idle_rss))MB)"

    # Guest memory snapshot: after allocation (should show consumed)
    guest_peak=$(_guest_sample "guest_peak" "${cycle}")
    echo "  Guest memory (alloc): ${guest_peak}"

    # Phase 4: free guest memory
    echo "[phase:free] Freeing guest memory + dropping caches..."
    _guest_free
    sleep 5
    post_free_rss=$(_sample "post_free" "${cycle}" 0)
    echo "  VMS RSS immediately after free: ${post_free_rss}MB"

    # Guest memory snapshot: after free (should show memory returned)
    guest_freed=$(_guest_sample "guest_freed" "${cycle}")
    echo "  Guest memory (freed): ${guest_freed}"

    # Phase 5: observation window — sample every second
    echo "[phase:observe] Observing host reclamation for ${WAIT_SECS}s..."
    min_rss="${post_free_rss}"
    for s in $(seq 1 "${WAIT_SECS}"); do
        rss=$(_sample "observe" "${cycle}" "${s}")
        if [ "${rss}" -lt "${min_rss}" ]; then
            min_rss="${rss}"
        fi
        # Progress every 30s
        if [ $((s % 30)) -eq 0 ]; then
            echo "  ${s}/${WAIT_SECS}s: VMS RSS=${rss}MB (min so far: ${min_rss}MB)"
            _check_host_memory "observe cycle ${cycle} @ ${s}s"
        fi
        sleep 1
    done
    final_rss=$(_sample "observe_end" "${cycle}" 0)

    # Guest memory snapshot: end of observation
    guest_final=$(_guest_sample "guest_final" "${cycle}")
    echo "  Guest memory (final): ${guest_final}"

    # Phase 6: stop VM
    echo "[phase:stop] Stopping Colima..."
    _stop_colima
    stopped_rss=$(_sample "vm_stopped" "${cycle}" 0)

    # Cycle summary
    growth=$((peak_rss - idle_rss))
    reclaimed=$((peak_rss - final_rss))
    retained=$((final_rss - idle_rss))
    reclaim_pct=0
    if [ "${growth}" -gt 0 ]; then
        reclaim_pct=$(( reclaimed * 100 / growth ))
    fi

    echo ""
    echo "  ┌─ Cycle ${cycle} Summary ─────────────────────┐"
    echo "  │ Baseline (no VM):     ${baseline_rss}MB       │"
    echo "  │ VM idle:              ${idle_rss}MB            │"
    echo "  │ After ${ALLOC_MB}MB alloc:   ${peak_rss}MB    │"
    echo "  │ Growth from alloc:    ${growth}MB              │"
    echo "  │ After free + ${WAIT_SECS}s:  ${final_rss}MB   │"
    echo "  │ Reclaimed:            ${reclaimed}MB (${reclaim_pct}%)  │"
    echo "  │ Retained (leak):      ${retained}MB            │"
    echo "  │ After VM stop:        ${stopped_rss}MB         │"
    echo "  └──────────────────────────────────────────┘"

    # Append to CSV
    echo "${cycle},idle,${idle_rss},,,," >> "${SUMMARY_CSV}"
    echo "${cycle},peak,${peak_rss},,,," >> "${SUMMARY_CSV}"
    echo "${cycle},final,${final_rss},,,," >> "${SUMMARY_CSV}"
    echo "${cycle},reclaimed_mb,${reclaimed},,,," >> "${SUMMARY_CSV}"
    echo "${cycle},reclaimed_pct,${reclaim_pct},,,," >> "${SUMMARY_CSV}"
done

# ── final report ─────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "Test complete: $(_iso_ts)"
echo "=========================================="

# Generate human-readable report
python3 - "${SAMPLE_LOG}" "${REPORT_FILE}" "${ALLOC_MB}" "${WAIT_SECS}" "${VM_MEMORY}" <<'REPORT_EOF'
import json, sys

sample_log = sys.argv[1]
report_file = sys.argv[2]
alloc_mb = int(sys.argv[3])
wait_secs = int(sys.argv[4])
vm_memory = int(sys.argv[5])

samples = []
guest_samples = []
sys_info = {}
with open(sample_log) as f:
    for line in f:
        d = json.loads(line.strip())
        if d.get("type") == "system_info":
            sys_info = d
        elif d.get("type") == "guest_mem":
            guest_samples.append(d)
        else:
            samples.append(d)

# Group by cycle
cycles = {}
for s in samples:
    c = s.get("cycle", 0)
    if c not in cycles:
        cycles[c] = []
    cycles[c].append(s)

# Group guest samples by cycle
guest_by_cycle = {}
for g in guest_samples:
    c = g.get("cycle", 0)
    if c not in guest_by_cycle:
        guest_by_cycle[c] = {}
    guest_by_cycle[c][g["phase"]] = g.get("guest", {})

lines = []
lines.append("=" * 60)
lines.append("VIRTIO-BALLOON HOST MEMORY RECLAMATION TEST REPORT")
lines.append("=" * 60)
lines.append("")
lines.append("PURPOSE: Determine whether macOS Virtualization.framework")
lines.append("returns host memory when a guest VM frees memory and the")
lines.append("virtio-balloon device inflates.")
lines.append("")
lines.append("SYSTEM:")
lines.append(f"  Hardware:     {sys_info.get('chip', 'unknown')}")
lines.append(f"  Memory:       {sys_info.get('memory_gb', '?')}GB unified")
lines.append(f"  macOS:        {sys_info.get('macos_version', '?')}")
lines.append(f"  Kernel:       {sys_info.get('kernel', '?')}")
lines.append(f"  Colima:       {sys_info.get('colima_version', '?')}")
lines.append("")
lines.append("TEST PARAMETERS:")
lines.append(f"  VM config:    {vm_memory}GB RAM (Virtualization.framework / vz)")
lines.append(f"  Allocation:   {alloc_mb}MB per cycle (dd to tmpfs)")
lines.append(f"  Observation:  {wait_secs}s after guest memory free")
lines.append(f"  Cycles:       {len(cycles)}")
lines.append("")
lines.append("-" * 60)

total_growth = 0
total_reclaimed = 0

for c in sorted(cycles.keys()):
    if c == 0:
        continue
    samps = cycles[c]
    idle = [s for s in samps if s["phase"] in ("vm_idle_end",)]
    peak = [s for s in samps if s["phase"] == "alloc_peak"]
    final = [s for s in samps if s["phase"] == "observe_end"]

    idle_rss = idle[0]["vms_rss_mb"] if idle else 0
    peak_rss = peak[0]["vms_rss_mb"] if peak else 0
    final_rss = final[0]["vms_rss_mb"] if final else 0
    growth = peak_rss - idle_rss
    reclaimed = peak_rss - final_rss
    retained = final_rss - idle_rss
    pct = (reclaimed * 100 // growth) if growth > 0 else 0

    total_growth += growth
    total_reclaimed += reclaimed

    lines.append(f"")
    lines.append(f"CYCLE {c}:")
    lines.append(f"  VM idle RSS:           {idle_rss} MB")
    lines.append(f"  After {alloc_mb}MB alloc:  {peak_rss} MB (+{growth} MB)")
    lines.append(f"  After free + {wait_secs}s:    {final_rss} MB")
    lines.append(f"  Reclaimed:             {reclaimed} MB ({pct}%)")
    lines.append(f"  Retained (not freed):  {retained} MB")

    # Guest-side evidence: did the guest actually free its memory?
    gc = guest_by_cycle.get(c, {})
    g_idle = gc.get("guest_idle", {})
    g_peak = gc.get("guest_peak", {})
    g_freed = gc.get("guest_freed", {})
    g_final = gc.get("guest_final", {})
    if g_idle and g_freed:
        lines.append(f"  Guest /proc/meminfo:")
        lines.append(f"    Idle:    {g_idle.get('available_mb','?')} MB available"
                     f"  (shmem: {g_idle.get('shmem_mb','?')} MB)")
        lines.append(f"    Alloc:   {g_peak.get('available_mb','?')} MB available"
                     f"  (shmem: {g_peak.get('shmem_mb','?')} MB)")
        lines.append(f"    Freed:   {g_freed.get('available_mb','?')} MB available"
                     f"  (shmem: {g_freed.get('shmem_mb','?')} MB)")
        lines.append(f"    Final:   {g_final.get('available_mb','?')} MB available"
                     f"  (shmem: {g_final.get('shmem_mb','?')} MB)")
        # Did the guest recover its memory?
        idle_avail = g_idle.get('available_mb', 0)
        freed_avail = g_freed.get('available_mb', 0)
        if idle_avail > 0 and freed_avail > 0:
            recovery_pct = freed_avail * 100 // idle_avail
            lines.append(f"    Guest recovery: {recovery_pct}% of idle available")
            if recovery_pct > 80:
                lines.append(f"    → Guest DID free its memory. Host did NOT reclaim.")

    # Find observation trend
    obs = [s for s in samps if s["phase"] == "observe"]
    if obs:
        rss_values = [s["vms_rss_mb"] for s in obs]
        min_rss = min(rss_values)
        max_rss = max(rss_values)
        lines.append(f"  Observation range:     {min_rss} - {max_rss} MB")
        # Check if monotonically non-decreasing (never reclaims)
        decreases = sum(
            1 for i in range(1, len(rss_values))
            if rss_values[i] < rss_values[i-1]
        )
        if decreases == 0:
            lines.append(f"  Trend:                 MONOTONIC (never decreased)")
        else:
            lines.append(f"  Trend:                 {decreases} decreases observed")

lines.append("")
lines.append("-" * 60)
lines.append("CONCLUSION:")
avg_reclaim_pct = (
    (total_reclaimed * 100 // total_growth)
    if total_growth > 0 else 0
)
if avg_reclaim_pct < 5:
    lines.append(f"  Host memory reclamation: BROKEN")
    lines.append(f"  Average reclaimed: {avg_reclaim_pct}% across all cycles")
    lines.append(f"  The Virtualization.framework host process retains")
    lines.append(f"  allocated memory even after the guest frees it and")
    lines.append(f"  the balloon inflates. This confirms the behavior")
    lines.append(f"  reported in lima-vm/lima#2789.")
elif avg_reclaim_pct < 50:
    lines.append(f"  Host memory reclamation: PARTIAL")
    lines.append(f"  Average reclaimed: {avg_reclaim_pct}% across all cycles")
    lines.append(f"  Some memory is returned but the majority is retained.")
elif avg_reclaim_pct < 90:
    lines.append(f"  Host memory reclamation: MOSTLY WORKING")
    lines.append(f"  Average reclaimed: {avg_reclaim_pct}% across all cycles")
else:
    lines.append(f"  Host memory reclamation: WORKING")
    lines.append(f"  Average reclaimed: {avg_reclaim_pct}% across all cycles")

lines.append("")
lines.append("IMPACT:")
lines.append(f"  On a {sys_info.get('memory_gb', 32)}GB system, this means "
             f"the VM process grows")
lines.append(f"  monotonically toward the VM memory limit ({vm_memory}GB) and")
lines.append(f"  never releases it, even when the guest is idle.")
lines.append(f"  Under sustained workloads, this forces the host into")
lines.append(f"  swap/compression, degrading all host processes.")
lines.append("")
lines.append("=" * 60)

report = "\n".join(lines)
print(report)
with open(report_file, "w") as f:
    f.write(report + "\n")
REPORT_EOF

echo ""
echo "Output files:"
echo "  Samples:  ${SAMPLE_LOG}"
echo "  CSV:      ${SUMMARY_CSV}"
echo "  Report:   ${REPORT_FILE}"
echo ""
echo "Next steps:"
echo "  1. Review the report: cat ${REPORT_FILE}"
echo "  2. Attach report + JSONL to Apple Feedback (FB)"
echo "  3. Post findings on lima-vm/lima#2789"
echo "  4. Share data with @jwehrlich on lima-vm/lima#4828"
