# Runtime construction comparison — Windows

Captured 2026-11-16 on the Windows machine used for the SDL_GPU reference.
This is a supplemental Runtime-only comparison; it does not measure GPU work,
presented-frame latency, a full interactive application, or renderer parity.

## Environment and revisions

- Windows 10 Home 22H2, build 19045.6466.
- AMD Ryzen 5 7600X, 12 logical processors.
- NVIDIA GeForce RTX 2080 SUPER, driver 595.97.
- Odin `dev-2026-11-nightly:08539cd` (`C:\odin\odin.exe`).
- Optimized builds (`-o:speed`).
- Reference: `d0c273fc00769412018ef871e407a1d45882ffbf`.
- Compared migration checkout: `574c06247df3fbafb9b5f5644a78c58f69157b0a`.

The reference and migration snapshots were built from Git archives by
`tools/bench_construction.py`. This comparison spans all source changes between
those commits, so it cannot attribute a difference specifically to WebGPU work.

## Timing and working-set method

The identical `benchmarks/diagnostics/construction_cpu_probe.odin` fixture
builds a Runtime, describes one frame, finalizes it, and destroys it. Workloads
were 10,000 containers, 10,000 short text nodes, 10,000 wrapped text nodes, and
100 panels. Each variant ran in five fresh processes; process order alternated
between rounds. Timing is wall-clock duration for `description`, `end_frame`,
and their sum. The process working set uses Windows
`GetProcessMemoryInfo(PROCESS_MEMORY_COUNTERS_EX)`; the helper samples every
millisecond and reports the OS-maintained peak working-set counter. Values below
are five-run medians; working-set ranges show observed min–max across processes.

Command:

```powershell
python tools/bench_construction.py `
  --odin C:\odin\odin.exe `
  --ref baseline=d0c273fc00769412018ef871e407a1d45882ffbf `
  --ref migration=574c06247df3fbafb9b5f5644a78c58f69157b0a `
  --runs 5 --speed --windows-process-metrics `
  --output out\webgpu-phase0\runtime-comparison-574c062
```

| Workload | Description p50 ms (base → current) | End-frame p50 ms (base → current) | Total p50 ms (base → current) | Peak working set MiB (base → current) |
| --- | ---: | ---: | ---: | ---: |
| Containers, 10,000 | 11.179 → 10.711 | 26.256 → 25.183 | 37.435 → 36.352 | 54.21 (54.17–54.39) → 52.37 (52.33–52.53) |
| Short text, 10,000 | 10.761 → 10.732 | 36.173 → 38.029 | 46.406 → 48.761 | 69.30 (69.27–69.32) → 67.23 (67.22–67.34) |
| Wrapped text, 10,000 | 13.094 → 11.986 | 39.767 → 42.040 | 53.095 → 53.995 | 70.92 (70.88–70.96) → 68.91 (68.87–69.00) |
| Panels, 100 | 0.682 → 0.670 | 2.385 → 2.584 | 3.055 → 3.263 | 7.92 (7.91–7.92) → 7.94 (7.90–7.96) |

Timing runs varied enough that these five-sample medians do not support a
performance-regression claim. The short-text and wrapped-text end-frame medians
were 5.1% and 5.7% higher in the compared checkout, respectively; other
workloads moved in the other direction. Peak working set was about 2 MiB lower
for the two 10,000-text workloads and effectively unchanged for the small panel
workload. These measurements are Runtime construction evidence, not evidence
about GPU rendering or the live application.

## Runtime phase attribution

A separate five-run capture instrumented coarse Runtime phases. Instrumented
timings are not mixed with the ordinary timing results above. The table shows
median wall durations for the 10,000 wrapped-text workload. These phases are
inclusive and overlap; do not sum them. On Windows the fixture has no process
CPU clock, so these are elapsed-time measurements.

| Phase | Reference ms | Compared checkout ms |
| --- | ---: | ---: |
| Reconcile | 39.530 | 38.394 |
| Tree order | 0.704 | 0.636 |
| Layout | 8.971 | 9.088 |
| Adaptive semantics | 0.772 | 0.731 |
| Paint | 8.472 | 8.222 |
| Display build | 2.804 | 2.567 |
| Display finalize | 0.872 | 0.853 |

Command:

```powershell
python tools/bench_construction.py `
  --odin C:\odin\odin.exe `
  --ref baseline=d0c273fc00769412018ef871e407a1d45882ffbf `
  --ref migration=574c06247df3fbafb9b5f5644a78c58f69157b0a `
  --runs 5 --speed --phases `
  --output out\webgpu-phase0\runtime-phases-574c062
```

## Allocator-requested high-water

An independent capture enabled the fixture's custom allocator tracker. These
are allocator-requested live-byte high-water values for Runtime construction,
not process working set or GPU allocation totals.

| Workload | Reference bytes | Compared checkout bytes |
| --- | ---: | ---: |
| Containers, 10,000 | 58,542,118 | 57,093,502 |
| Short text, 10,000 | 72,361,928 | 70,913,312 |
| Wrapped text, 10,000 | 73,871,928 | 72,423,312 |
| Panels, 100 | 4,652,644 | 4,563,068 |

The compared checkout's `Node` record is 2,008 bytes versus 2,048 bytes in the
reference; `Pending_Item` is 1,320 versus 1,384 bytes and `Description` is 704
versus 768 bytes. This is consistent with the lower allocator high-water, but
the comparison spans multiple changes and does not assign causality to this
migration.

Command:

```powershell
python tools/bench_construction.py `
  --odin C:\odin\odin.exe `
  --ref baseline=d0c273fc00769412018ef871e407a1d45882ffbf `
  --ref migration=574c06247df3fbafb9b5f5644a78c58f69157b0a `
  --runs 5 --speed --allocations `
  --output out\webgpu-phase0\runtime-allocations-574c062
```

## Interpretation and remaining baseline gaps

The benchmark helper now reads and writes generated Odin source explicitly as
UTF-8, making phase instrumentation independent of Windows' active code page.
Ordinary timing, phase attribution, and allocator attribution were run
separately. Raw JSON and logs are under ignored `out/webgpu-phase0/` and are not
committed.

This closes only a Runtime construction and process-working-set slice of the
baseline. Full application description-to-visible latency, renderer preparation
and GPU costs on the same Scratchpad/Punks workloads, idle behavior, resizing,
scrolling, secondary windows, and cross-platform comparison remain open. It
does not replace the original 10,000-node `tools/bench.ps1` baseline or provide
SDL_GPU-versus-WebGPU production parity evidence.
