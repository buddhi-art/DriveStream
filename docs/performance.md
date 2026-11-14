# Performance and native Finder continuity — 1.2.0

DriveStream aims for a familiar Finder entry point and fast cached reads/writes without pretending a cloud filesystem is a physical SSD. Performance is a primary requirement, but uncached content, metadata, uploads and recovery still depend on rclone, Google, the network and the selected filesystem backend.

This report covers **executed, scoped Swift cache-warming measurements on 6 November 2026** and the inspected 1.2 resource/continuity settings. It is not a final whole-application validation or a real-Google/NFS throughput claim. The maintainer records final acceptance results separately in [verification](<verification.md>).

## What changed, and why Swift was enough

The legacy pin reader read selected files sequentially using a new Foundation Data result for each 4 MiB chunk and forced a progress callback after every file. The new implementation uses:

- A fixed-size TaskGroup with 1–4 long-lived workers, not a task per enumerated file.
- Dedicated Dispatch I/O blocks so actual blocking reads/traversal do not occupy the MainActor or Swift cooperative executor.
- One reusable, aligned **4 MiB POSIX buffer per worker**: 8 MiB explicit file buffers with two readers, at most 16 MiB with four. This is not a bound on rclone/OS/whole-process memory.
- A streaming descriptor-relative, no-follow traversal cursor. Memory depends on selected roots and directory depth/path storage, not a whole-library enumerated-file array.
- Serialized progress at most five periodic snapshots/second plus start/finish, rather than one queued UI update per small file.
- Deduplicated overlapping selections, ordinary hidden-file inclusion, Apple-metadata exclusions, visible traversal/read failures and no new complete marker for a partially read requested root.
- Joined cancellation and owner-thread descriptor closing. A kernel read already blocked on a filesystem cannot safely/reliably be interrupted with cross-thread close; cancellation can wait for that response rather than orphan work.

See [PinEngine](<../Sources/Services/PinEngine.swift>), [PinFileIO](<../Sources/Services/PinFileIO.swift>) and [PinTraversal](<../Sources/Services/PinTraversal.swift>). The engine default argument is three readers, but the application supplies its resource policy: **two for Automatic on an 8 GB M1**, four for the larger-memory/responsive profile, or an explicit 1–4 override.

The measured buffer/allocation and progress improvements were achievable in Swift/POSIX. There is **no demonstrated unavoidable Swift limit requiring Rust for this change**. A future Rust component should be justified by a remaining reproducible bottleneck, not by a language-speed assumption; the compatible password-obscuration helper likewise uses an existing CommonCrypto primitive directly in Swift.

## Evidence and measurement contract

### Host and fixtures

| Item | Measured setup |
| --- | --- |
| Hardware | MacBookAir10,1, Apple M1, 8 CPU cores, 8 GiB physical RAM |
| OS | macOS 27.2, build 26B123 |
| Compiler | Apple Swift 6.4.2 |
| SDK/deployment | Real installed macOS 26.5 SDK; arm64 macOS 14 target |
| Flags | `-O -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors` |
| Storage | Local APFS Data volume, private temporary fixtures |
| Small | 2,000 × 4 KiB files; 8,192,000 bytes total |
| Medium | 32 × 8 MiB files; 256 MiB total |
| Large | One 256 MiB file |
| Contents | Physically written deterministic repeating nonzero bytes, not sparse/truncated fixtures |

The fixtures, installed cache, executable and temporary compilation products are **not checked into the repository**. The small checked-in evidence files contain only benchmark metrics/context, not real account or cached user data:

- [Raw JSONL: 102 rows](<benchmarks/pin-warm-apfs-raw.jsonl>): 15 unmeasured warmups, 75 actual measurements and 12 synthetic measurements.
- [Original median/min/max summary](<benchmarks/pin-warm-apfs-summary.json>).
- [Derived median/p95/min/max distributions](<benchmarks/pin-warm-apfs-distributions.json>) for elapsed, CPU, peak process RSS and callbacks.
- [Context and caveats](<benchmarks/pin-warm-apfs-context.json>).

### Bias control and metric scope

Each actual scenario/method received an **unmeasured prewarm**. Five measured repeats compared unchanged legacy versus new Swift with 1/2/3/4 readers, in deterministic shuffled order per repeat (seed 20261106). Each trial ran in a fresh process, but filesystem data was already warm; no global cache purge or system preference change was performed.

The legacy implementation was archived before editing and renamed only so both implementations could coexist in the optimized harness. No autoreleasepool or other legacy performance repair was added. The measured pin snapshot predates unrelated later 1.2 model/lifecycle additions; the numbers do not cover all subsequent application changes.

- **Elapsed:** monotonic time around the awaited pin call, including task/queue setup, traversal, reads and callbacks; excludes fixture creation/compilation and most process launch work.
- **CPU:** process CPU delta from `getrusage`, summed user+system time. Parallel workers can use more CPU even when elapsed improves.
- **Peak RSS:** process-wide `ru_maxrss` in bytes on macOS, reported below in binary MiB. Includes framework/runtime/allocator/autorelease behavior; it is not a buffer-only or rclone-memory measurement.
- **Callbacks:** a cheap serialized counter, **not a rendered Finder/SwiftUI latency measurement**. The actual controller schedules UI updates for snapshots, but rendering cost was not benchmarked here.
- **p95:** descriptive linear interpolation of sorted samples at `(n−1) × 0.95`. With only five actual or three synthetic samples, it is not a reliable population tail/latency-service estimate. Min/max are retained and outliers are not discarded.

The machine was **not isolated**: normal harness/compiler and other shared-machine activity can introduce noise, especially for tens-of-milliseconds cases. Shuffling/prewarm mitigate ordering bias, not all environmental interference.

## Actual warm-APFS results — five repeats per row

Times are milliseconds; RSS is median peak **process** MiB; callback counts are medians. These are actual warmed local reads, not NFS/FUSE/Google throughput.

### Small: 2,000 × 4 KiB

| Method/readers | Elapsed median ms | Descriptive p95 ms | Elapsed min–max ms | CPU median ms | Peak RSS median MiB | Callbacks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Legacy | 137.84 | 147.11 | 133.62–148.39 | 134.39 | 17.27 | 2002 |
| Swift 1 | 35.50 | 40.01 | 34.75–40.38 | 35.41 | 6.12 | 2 |
| Swift 2 | 38.88 | 39.86 | 38.54–40.08 | 45.14 | 6.19 | 2 |
| Swift 3 | 41.00 | 90.81 | 38.77–101.98 | 49.84 | 6.28 | 2 |
| Swift 4 | 40.48 | 68.07 | 37.91–74.05 | 50.72 | 6.33 | 2 |

One reader beat two on this local small-file fixture. The large Swift 3/4 ranges are visible rather than hidden by the median. Removing per-file callback pressure and Foundation allocation/path overhead matters here more than maximizing local parallelism.

### Medium: 32 × 8 MiB

| Method/readers | Elapsed median ms | Descriptive p95 ms | Elapsed min–max ms | CPU median ms | Peak RSS median MiB | Callbacks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Legacy | 51.60 | 52.63 | 48.59–52.68 | 49.32 | 264.14 | 34 |
| Swift 1 | 23.86 | 24.60 | 22.69–24.64 | 23.89 | 10.11 | 2 |
| Swift 2 | 22.22 | 22.64 | 20.83–22.68 | 43.02 | 14.14 | 2 |
| Swift 3 | 22.20 | 23.30 | 21.05–23.56 | 60.71 | 18.25 | 2 |
| Swift 4 | 21.73 | 23.29 | 21.54–23.66 | 72.96 | 22.31 | 2 |

The unchanged legacy process shows much larger RSS, consistent with its Foundation allocation/retention/autorelease effects in this harness. The reusable-buffer implementation avoids that observed growth. This does not prove identical memory use for remote VFS reads or every Foundation environment.

More workers offer only a modest additional warm-local elapsed improvement and increase aggregate CPU/RSS. The conservative two-reader policy is a trade-off, not a claim that two is fastest on every fixture.

### Large: one 256 MiB file

| Method/readers | Elapsed median ms | Descriptive p95 ms | Elapsed min–max ms | CPU median ms | Peak RSS median MiB | Callbacks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Legacy | 48.25 | 57.38 | 46.38–57.52 | 47.71 | 263.91 | 3 |
| Swift 1 | 22.16 | 23.01 | 20.55–23.07 | 22.21 | 10.08 | 2 |
| Swift 2 | 22.22 | 23.98 | 20.94–23.99 | 22.40 | 10.11 | 2 |
| Swift 3 | 22.47 | 23.85 | 21.04–24.08 | 22.77 | 10.19 | 2 |
| Swift 4 | 22.88 | 23.63 | 21.48–23.76 | 23.17 | 10.25 | 2 |

A single file cannot benefit from parallel **file** readers; the buffer/allocation improvement is the relevant result. Unused workers allocate address space but do not fill all their buffers, so observed RSS can be below the maximum explicit-buffer allocation.

## Synthetic delayed-reader results — separate, three repeats

This uses **only the new implementation**, with one reader as the matched baseline. The hook requests `usleep(10000)` before each POSIX read, including the EOF read, on the medium fixture. Utility-QoS timer coalescing and scheduling mean the actual delay is **not exactly 10 ms** and must not be interpreted as a measured network round-trip time.

Times below are **seconds**, except CPU milliseconds. This experiment demonstrates bounded concurrency mechanics; it is not the legacy comparison and not a real NFS/Google speed measurement.

| Readers | Elapsed median s | Descriptive p95 s | Elapsed min–max s | CPU median ms | Peak RSS median MiB | Callbacks |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Swift 1 | 5.035 | 5.596 | 4.945–5.659 | 44.21 | 10.11 | 24 |
| Swift 2 | 2.517 | 2.963 | 2.402–3.013 | 47.02 | 14.17 | 13 |
| Swift 3 | 1.617 | 2.138 | 1.595–2.196 | 51.64 | 18.23 | 9 |
| Swift 4 | 1.232 | 1.419 | 1.181–1.440 | 55.78 | 22.30 | 7 |

No synthetic ratio should be advertised as a Google Drive or Finder performance multiplier. Actual backend concurrency, connection reuse, cache hits, rate limits, upload competition and application semantics need their own measurements.

## Effective resource settings

[PerformancePolicy](<../Sources/Models/PerformancePolicy.swift>) resolves the following values; [MountArgumentsBuilder](<../Sources/Services/MountArgumentsBuilder.swift>) emits the corresponding mount flags.

| Selection | Automatic pin readers | Transfers | Drive upload chunk | rclone buffer |
| --- | ---: | ---: | ---: | ---: |
| Automatic, less than 16 GiB RAM (including 8 GB M1) | 2 | 4 | 16M | 16M |
| Automatic, at least 16 GiB RAM | 4 | 8 | 64M | 32M |
| Lower memory use, any RAM | 2 | 4 | 16M | 16M |
| Maximum responsiveness, any RAM | 4 | 8 | 64M | 32M |

A manual 1–4 reader override affects pin concurrency, not all rclone transfers or allocations. These flags are configured budgets, not an enforced whole-process memory ceiling: per-open-file buffers, read-ahead, dirty/staged data, metadata trees, general transfer/backend applicability and the OS page cache also matter. Memory-profile superiority under a real remote workload was not established by the pin-only benchmark.

Upload and download limits are independent integer **binary MiB/s**, 0–10000, with `0` meaning unlimited. Both zero omit `--bwlimit`; upload 10/download 0 yields `--bwlimit 10M:off`. Bandwidth-only changes use the idempotent RC control without a remount; resource/profile changes still require a safe restart. Neither is a bandwidth schedule or a guaranteed exact kernel rate.

## Sticky Finder feel without fake filesystem guarantees

- **Launch at login** is a separate user choice through `SMAppService`; initialization reads status and does not silently register it.
- **Mount automatically** attempts mounting when the application launches.
- **Keep in Finder** provides supported one-time user drag-to-Favorites guidance. Finder controls Locations for attached volumes; a detached Favorites folder is an empty mount directory, not cached cloud content or a pretend local disk. No private Finder sidebar API/database edit is used.
- Sleep/network loss preserves a healthy local attachment and cache rather than deliberately tearing down Finder identity. Sleep stops telemetry; wake checks the authenticated helper PID and can recover a previously stopped session when configured/safe.
- A satisfied network path, resumed telemetry, visible sidebar entry or successful pin marker does not prove cloud availability or upload durability.
- Ordinary exit uses fresh queue/stat evidence plus read-only dirty-cache observation; unknown/incomplete evidence does not approve a normal exit. Close writers and verify important remote files. Quit Anyway accepts interruption and retains cache, not guaranteed recovery.

The inspected official rclone v1.75.2 NFS route uses NFSv3 and remains experimental. This report's timing tables are **APFS fixture reads**, not acceptance measurements for that local NFS server or a filesystem driver. See [README workflows](<../README.md>) and [security boundaries](<../SECURITY.md>).

## Executed correctness checks and remaining validation

The final pin-only CLI run completed with exit code 0 and **15 reported PASS groups**, including explicit cap variants 1/2/3/4. It used real frozen Models, Swift 6.4.2, SDK 26.5, macOS 14 target, complete strict concurrency and warnings-as-errors; no State shim or unchecked application box was used. Elapsed **34.70 seconds**, CPU user 25.28/system 2.17 seconds, includes a fresh compiler/module cache build.

Coverage includes empty directories; ordinary hidden files/Apple metadata; overlaps; symlink roots/intermediates/descendants; containment/marker validation; real and injected read/directory errors; partially failed roots; changed/truncated files; pre-start/read/enumeration cancellation; joined descriptor cleanup/no late callbacks; progress/concurrency/resource caps; and multi-chunk reads with a short final chunk.

From the repository root, run:

```bash
make pin
# or
bash Scripts/run-pin-tests.sh
```

The [pin runner](<../Scripts/run-pin-tests.sh>) snapshots its real model inputs before compiling and uses only private fixtures. It does not sign into Google, write the user's Keychain, install a driver, modify Finder preferences or mount a real volume. The [hostless native XCTest target](<../project.yml>) is additionally configured in CI; full Xcode/native-target/CI execution is not claimed here.

Still needed for broader performance/support claims:

- Cold-local reads and real Google/NFS/FUSE behavior, including rate limits and uncached metadata.
- Larger directory trees, multi-terabyte working sets, sustained memory pressure and competing Finder/editor/upload activity.
- Installed-build sleep/wake, held-writer flush/close, interrupted-exit/recovery and cache-format compatibility acceptance.
- Intel/macOS 14 runtime coverage, real Google OAuth/crypt acceptance and the final complete 1.2 test/build/artifact record.

A pin marker is a completed eligible read snapshot, not a protected rclone cache lease. LRU/age/size cleanup can subsequently evict bytes. For indispensable offline work, keep and verify a separate normal local copy.

## Recompute the checked-in descriptive statistics

The raw dataset supports portable re-analysis without private paths, a mount or network access. For example, from the repository root:

```bash
python3 - <<'PY'
import json, math, statistics
from collections import defaultdict
from pathlib import Path

groups = defaultdict(list)
for line in Path('docs/benchmarks/pin-warm-apfs-raw.jsonl').read_text().splitlines():
    row = json.loads(line)
    if row['measured']:
        groups[(row['type'], row['scenario'], row['mode'], row['concurrency'])].append(row)

for key, rows in sorted(groups.items()):
    values = sorted(row['elapsed_seconds'] for row in rows)
    index = (len(values) - 1) * 0.95
    lo, hi = math.floor(index), math.ceil(index)
    p95 = values[lo] + (values[hi] - values[lo]) * (index - lo)
    print(key, 'n=', len(values), 'median=', statistics.median(values),
          'p95=', p95, 'min=', values[0], 'max=', values[-1])
PY
```

This reproduces the published distribution calculation, **not a fresh legacy/new filesystem trial**. The original archived legacy harness and private fixtures were retained during implementation, not committed as production code. For a fresh benchmark, recreate the deterministic physical fixtures and unchanged baseline, compile both readers with the recorded flags, prewarm each method, shuffle measured order, and retain every raw trial and environment detail. Do not replace a fresh measurement with a calculated multiplier or silently omit failures/outliers.
