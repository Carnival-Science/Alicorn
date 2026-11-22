# Material-stream fixture (issue #104 phase A)

One fixture answers where rounded and relief surface expansion actually costs
time. It contains exactly 500 visible card surfaces and 28 visible scrolling-row
commands; a treatment changes only shape (`rectangle` or rounded radius 8),
material (`flat` or `Analytic_Relief`), and physical height (`0` or `0.5`).
Bounds, clip, opacity, translation, stroke (absent), and painter order are
identical across treatments.

```powershell
.\tools\bench_material_stream.ps1 -Odin C:\odin\odin.exe -Runs 5 `
  -OutputDir out\issue-104-material-stream
```

Modes:

- `--mode=window` (default) describes the scene through `ui.run`
  (`--backend=sdl-gpu`) or `ui/webgpu.run` (`--backend=d3d12|vulkan`).
  `--treatment=<name>` and `--condition=cold|warm|resize|theme|hover|scroll|idle`
  select one cell; the app driver requests one description per planned pass
  (24 by default). `--scene=scratchpad --interaction=typing|scroll` swaps in
  the representative `benchmarks/scratchpad_scene` composition.
- `--mode=offscreen` renders the same resolved `Paint_Command` stream on the
  real GPU device at 1x, 1.25x, 1.5x, and 2x through the production
  `draw_display_list` path, then waits for the fence. The window runs cover
  conditions at the monitor's display scale; Windows exposes one display scale
  per monitor, so the scale dimension is measured offscreen instead of by
  pretending a window has another DPI.
- `--mode=dogfood` describes the representative Scratchpad workload headlessly
  and counts resolved surfaces by shape and material, plus a flat
  Acetate-shaped control scene.

The fixture prints `[alicorn-material-stream]` command/pass counts, the native
host prints its `SDL application PASS` build/encode/submit distribution and
solid-stream counters, and the hosted WebGPU host prints its retained-mesh
upload counters. `[alicorn-material-offscreen]` lines carry per-stage p50/p95/p99
plus draw calls, upload bytes, peak vertex capacity, growth events, and idle
stalls.

`tools/bench_material_stream.ps1` writes `window-runs.csv`,
`offscreen-runs.csv`, per-run logs, `dogfood.txt`, and
`material-stream-summary.md`.

Limits: all values are host CPU wall time or renderer counters. The offscreen
fence wait is a GPU completion round trip, not presented-frame latency, GPU
execution timing, scan-out, or a cross-machine promise. The window path does not
measure physical fractional DPI.
