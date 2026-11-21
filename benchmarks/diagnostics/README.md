# Construction diagnostics

This standalone headless probe separates flat container, short text, and
wrapped text construction. `short-reserve` pre-reserves exactly 10,001 pending
items for the synthetic short-text fixture. It is a diagnostic experiment;
runtime applications should not reserve this capacity unconditionally.

From the repository root, build and run one fresh process per workload:

```powershell
odin build benchmarks\diagnostics\perf_construction_probe.odin -file -out:out\perf_construction_probe.exe
out\perf_construction_probe.exe containers
out\perf_construction_probe.exe short
out\perf_construction_probe.exe short-reserve
out\perf_construction_probe.exe wrapped
```

The `memory_requested` values are the probe allocator's requested-live-byte
high-water mark, not process RSS, allocator overhead, or GPU residency. Work
counters accompany wall times to show which stages ran. The workload is a
synthetic flat root with 10,000 children and does not represent application
startup on its own.

## Typed sizing research

`issue109_sizing_probe.odin` prints two current sizing gaps: stale percentage
width inside a reused region and a typed fixed height conflicting with a
panel's implicit default. It is an observational reproduction, not a passing
acceptance test. See the [completion proposal](../../docs/research/issue-109-completion-plan.md).

On Windows, stage SDL3.dll in `out` using the normal native build tools, then:

```powershell
. .\tools\common.ps1
$ProbeAccessKit = Get-AlicornAccessKit
odin build benchmarks\diagnostics\issue109_sizing_probe.odin -file -collection:alicorn=. @($ProbeAccessKit.CompilerArguments) -out:out\issue109_sizing_probe.exe
.\out\issue109_sizing_probe.exe
```

`issue109_percent_sidecar_benchmark.odin` compares the optional retained
percentage-width sidecar with the same retained tree using fixed child widths.
It measures unchanged cached-region reuse and alternating parent-width changes
at 1, 8, 32, 128, and 256 relationships, including p95, requested persistent
bytes, allocator calls, and layout updates. Build with `-o:speed`; collect five
fresh processes and retain each raw capture. The synthetic resize trace includes
the layout work caused by changing child widths, so it is a cost profile rather
than an isolated map-iteration microbenchmark.

```powershell
. .\tools\common.ps1
$ProbeAccessKit = Get-AlicornAccessKit
$Odin = Resolve-AlicornOdin
& $Odin build benchmarks\diagnostics\issue109_percent_sidecar_benchmark.odin `
    -file -o:speed -collection:alicorn=. `
    "-extra-linker-flags:$($ProbeAccessKit.LinkerFlags)" `
    -out:out\issue109_percent_sidecar_benchmark.exe
1..5 | ForEach-Object { .\out\issue109_percent_sidecar_benchmark.exe }
```

The Windows capture from 2026-10-30 is in
[`raw/issue109-percent-sidecar-windows-2026-10-30.txt`](raw/issue109-percent-sidecar-windows-2026-10-30.txt).

## Percentage-width production validation

`issue158_percent_width_benchmark.odin` drives a font-picker-shaped modal
(overlay padding, a 100%-width panel capped at 900, header/footer text, and
twelve retained rows) through two behavior-equivalent authoring variants:
`width=percent(1)` and `width=min(viewport.w-48, 900)`. It asserts identical
panel and row geometry at 800 and 1200 units, then reports complete headless
frame, application-description, and retained-layout p95 values together with
allocator calls, requested bytes, layout updates, and measurement cache
counters. The `resize_cap_release` trace alternates 800/1200; `same_width`
redescribes at a constant width; `idle` polls a settled tree.

```powershell
. .\tools\common.ps1
$Odin = Resolve-AlicornOdin
$AccessKit = Get-AlicornAccessKit
& $Odin build benchmarks\diagnostics\issue158_percent_width_benchmark.odin `
    -file -o:speed -collection:alicorn=. @($AccessKit.CompilerArguments) `
    -out:out\issue158_percent_width_benchmark.exe
1..5 | ForEach-Object { .\out\issue158_percent_width_benchmark.exe }
```

Collect five fresh processes and keep each raw capture. The 2026-11-21
Windows capture and its interpretation are in
[`docs/validation/issue-158-percentage-width-windows-2026-11-21.md`](../../docs/validation/issue-158-percentage-width-windows-2026-11-21.md).
This is a consumer-shaped fixture, not the Scratchpad executable, and it does
not measure GPU submission, present latency, or native input.
