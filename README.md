# macOS Virtualization.framework Balloon Memory Reclamation Test

Standalone test proving that macOS `Virtualization.framework` does **not** return host memory when a guest VM frees it, even though the virtio-balloon device inflates correctly.

This affects all macOS developers using **Lima**, **Colima**, and any tool backed by `Virtualization.framework` (vz backend). On memory-constrained systems (32GB), the VM host process grows monotonically toward the VM memory limit and never releases, eventually forcing the host into swap/compression.

## Key Finding

| Metric | Value |
|--------|-------|
| VM idle RSS | 1709 MB |
| After 256MB guest alloc | 1731 MB (+22 MB) |
| Guest freed memory | 108% recovered (more free than before, after drop_caches) |
| Host RSS after 120s observation | 1748 MB (**+17 MB — grew, not shrank**) |
| Host reclamation | **0%** monotonically non-decreasing across 120 samples |

**The guest did its job. The host ignored it.**

- Guest `/proc/meminfo` confirms memory was freed: available went from 70 MB back to 316 MB
- Guest `shmem` (tmpfs backing) dropped from 273 MB to 17 MB
- Host `com.apple.Virtualization.VirtualMachine` RSS: never decreased once

## Test Design

```
1. Start Colima VM (1GB, vz/Virtualization.framework backend)
2. Record host VM process RSS at 1-second intervals
3. Allocate 256MB inside guest via dd to tmpfs (/dev/shm)
4. Record host RSS (should rise)
5. Free guest memory + drop_caches + compact_memory
6. Observe host RSS for 2 minutes
7. Report: did host RSS decrease? By how much?
```

Both host-side (VMS RSS via `ps`) and guest-side (`/proc/meminfo`) metrics are captured at phase boundaries, making the proof two-sided: the guest cooperated, the host did not reclaim.

## Safety

Designed for 32GB Apple Silicon with LM Studio as a neighbor process:

- **Preflight**: abort if LM Studio is loaded (>500MB RSS) or <8GB available
- **Phase check**: abort if swap >128MB or compressed >1.5GB
- **Killswitch**: force-kill VM if swap >256MB or compressed >2GB (2s poll)
- **Alloc guard**: cannot allocate more than 75% of VM memory

## Quick Start

```bash
# Default: 1 cycle, 256MB alloc, 120s observation, 1GB VM
./balloon_memory_test.sh

# More data points
./balloon_memory_test.sh --cycles 3

# Larger allocation (auto-checks it fits in VM)
./balloon_memory_test.sh --alloc-mb 512 --vm-memory 2
```

### Prerequisites

- macOS with Virtualization.framework (Apple Silicon)
- [Colima](https://github.com/abiosoft/colima) installed
- No other VMs running (for clean measurement)

### Output

```
.runtime_logs/balloon/
  balloon_<ts>.jsonl    — per-second host memory samples (machine-readable)
  balloon_<ts>.csv      — summary
  balloon_<ts>.txt      — human-readable report
```

## Test Data

The `data/` directory contains results from a confirmed run:

- **System**: MacBook Pro 14" 2021, Apple M1 Max, 32GB, macOS 26.0.1
- **Colima**: 0.10.1 (Virtualization.framework / vz backend)
- **167 JSONL samples** at 1-second resolution with full `vm_stat` breakdown
- **4 guest `/proc/meminfo` snapshots** at phase boundaries (idle, peak, freed, final)

## Related Issues

| Resource | Link |
|----------|------|
| Lima #2789 — Memory not freed on VZ | [lima-vm/lima#2789](https://github.com/lima-vm/lima/issues/2789) |
| Lima #4220 — Support memory ballooning | [lima-vm/lima#4220](https://github.com/lima-vm/lima/issues/4220) |
| Lima PR #4226 — Experimental memory command | [lima-vm/lima#4226](https://github.com/lima-vm/lima/pull/4226) |
| Lima PR #4828 — Adaptive balloon controller | [lima-vm/lima#4828](https://github.com/lima-vm/lima/pull/4828) |

## How to Contribute

If you can reproduce this on your hardware, please:

1. Run the test and share your `balloon_*.txt` report
2. File an Apple Feedback report (see below) — volume matters for Apple prioritization
3. Post your results on [lima-vm/lima#2789](https://github.com/lima-vm/lima/issues/2789)

### Filing Apple Feedback

1. Open [Feedback Assistant](https://feedbackassistant.apple.com/)
2. Category: **Developer Technologies & SDKs > Virtualization**
3. Title: `Virtualization.framework: VZVirtioTraditionalMemoryBalloonDevice inflates but host process never reclaims memory`
4. Attach your `balloon_*.txt` report and `balloon_*.jsonl` samples
5. Reference this repo for reproduction steps

## License

MIT
