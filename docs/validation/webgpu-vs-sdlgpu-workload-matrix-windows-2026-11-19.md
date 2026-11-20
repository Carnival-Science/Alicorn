# WebGPU vs SDL_GPU matched-description workload matrix — Windows

Captured 2026-11-19 from the Phase 0 migration worktree based on `ab98ce5`
(`codex/webgpu-phase0-feasibility`) on Windows 10 22H2 build `10.0.19045`,
Odin `dev-2026-11-nightly:08539cd`, Odin-pinned wgpu-native `v29.0.1.1`, SDL3
`3.4.20`, and an NVIDIA GeForce RTX 2080 SUPER (Turing, 8192 MiB, driver
`595.97`). SDL_GPU selected Direct3D 12. WebGPU ran on both its D3D12 and
Vulkan backends. The desktop session was not idle-exclusive.

This record replaces the unmatched-motion comparison in
[`webgpu-vs-sdlgpu-perf-windows-2026-11-19.md`](webgpu-vs-sdlgpu-perf-windows-2026-11-19.md)
for the motion question: both backends now receive the same retained-motion
scene and neither re-runs the application description during motion. It does
not replace that record's cold-scene stage timings.

## What changed in this slice

The previous harness ran a cold retained-control scene and an unmatched
"motion" scene: the SDL_GPU loop was described as rebuilding the description
per motion frame while WebGPU presented retained frames. That claim does not
reproduce with a matched scene. This slice drives one shared scene through both
hosts and asserts the description sequence directly:

- **Description scenarios** use one worker waker request per planned frame. The
  driver waits for the previous description to finish, pauses 25 ms so the host
  can submit it, then posts one wake. The host answers with one invalidated
  description. This produces identical description and wake counts on SDL_GPU
  and WebGPU; the counts are assertions, not assumptions.
- **Motion scenarios** declare the same `ui.motion` reveal on the same retained
  marker and do not re-describe. Each host presents retained frames from its own
  scheduler.
- **Multi-window motion** opens one auxiliary window through each host's native
  window service and animates both windows with the same scene declaration.
- **Idle hold**: `--smoke-hold-ms=1200` makes a smoke run wait for 1.2 s after
  the last presented frame (or last primary submission on SDL_GPU) before exit,
  so the settled scenario observes a real idle window rather than exiting on
  the first present. The default smoke behavior is unchanged when the flag is
  absent.

One executable is built from `benchmarks/workload_matrix/main.odin` and both
host paths are compiled into it. The scene, window size (720x480 logical,
display scale 1.0), theme, description, motion declaration, and waker cadence
are identical; only the renderer/host differs.

## Harness

```powershell
.\tools\bench_webgpu_vs_sdlgpu.ps1 -Odin C:\odin\odin.exe -Matrix -MatrixRuns 5 `
  -Frames 32 -IdleHoldMs 1200 -OutputDir .\out\webgpu-phase0\matrix-2026-11-19
```

The script builds the matrix fixture with `-define:WGPU_SHARED=true`, the
repository-pinned AccessKit arguments, and `-o:speed`; stages `SDL3.dll` and
`wgpu_native.dll`; and runs five times per scenario and renderer:

| Scenario | Workload arguments | Planned frames | Expected retained behavior |
| --- | --- | ---: | --- |
| `identical` | `--workload=identical` | 32 | Re-describing identical content rebuilds no mesh and uploads no vertex data |
| `transform` | `--workload=transform` | 1 description | Translation-only motion updates transforms without geometry rebuilds or re-description |
| `color` | `--workload=color` | 32 | Only the changed solid content updates; text/icon/image/surface geometry is retained |
| `layout` | `--workload=layout` | 32 | A fixed-size row changes one box width; unaffected text/icon/image/surface geometry is retained |
| `scroll-1000` | `--workload=scroll --items=1000` | 32 | Work scales with visible rows, not the 1,000 logical items |
| `scroll-10000` | `--workload=scroll --items=10000` | 32 | Same counters as the 1,000-item list |
| `multiwindow` | `--workload=multiwindow` | 1 description/window | Independent invalidation/scheduling; no cross-window description storm |
| `settled` | `--workload=settled` | 1 | Zero additional frame requests and zero application wakes over the idle window |

`--backend=sdl-gpu`, `--backend=d3d12`, and `--backend=vulkan` select the
renderer. Every run also passes `--smoke --smoke-hold-ms=1200`.

The run produced 131 machine-checked expectations (129 PASS, 2 FAIL). The full
machine-readable result is `matrix-expectations.csv`; the full per-run data is
`matrix-runs.csv`. The human-readable summary emitted by the harness is
committed as
[`raw/webgpu-vs-sdlgpu-workload-matrix-2026-11-19.txt`](raw/webgpu-vs-sdlgpu-workload-matrix-2026-11-19.txt).

## Metric availability

Every value is recorded only where the renderer emits it. No value is inferred
from another metric.

| Metric | SDL_GPU (D3D12) | WebGPU (D3D12/Vulkan) |
| --- | --- | --- |
| Description count, application wakes, presented frames | Yes (app + host) | Yes (app + host) |
| CPU description pass p50/p95/p99 | Yes: `application_build_*` over bounded passes (new in this slice) | Yes: `runtime_step_*` over hosted steps |
| CPU encode p50/p95/p99 | Yes per primary submission (includes hidden HUD/inspector draw attempts) | Yes: app display-list encode |
| CPU submit p50/p95/p99 | Yes; includes `SDL_SubmitGPUCommandBufferAndAcquireFence` and fence acquisition | Yes; `wgpu.QueueSubmit` only |
| GPU execution time | **n/a**: no timestamp query in this app loop | **n/a**: fixture/runtime do not expose timestamp-query; no device feature added |
| Draw calls | **n/a**: no cumulative draw-call counter; `display_commands_finalized` is reported instead | **n/a**: same |
| Solid mesh rebuilds | **n/a**: no solid fingerprint/rebuild counter | Yes |
| Solid vertex uploads and bytes | Yes (byte counter added in this slice) | Yes |
| Solid transform uploads and bytes | **n/a**: no transform buffer/path; translation is baked into rebuilt vertices | Yes |
| Text mesh rebuilds, cache hits, vertex uploads/bytes, atlas uploads/bytes | Yes (vertex byte counter added) | Yes; WebGPU does not expose a text mesh *cache-hit* counter |
| Text transform uploads | **n/a** counter: per-command transform is applied through the vertex model after the retained mesh | Yes |
| Icon mesh rebuilds/cache hits, vertex uploads/bytes, atlas uploads/bytes | Yes | Yes |
| Image mesh rebuilds/vertex uploads/texture uploads | Vertex uploads/bytes yes; mesh rebuild and texture upload counters **n/a** | Yes |
| Custom-surface mesh rebuilds/instance uploads | Encodes and vertex uploads/bytes yes; instance counter **n/a** | Yes |
| Allocations | Yes: runtime persistent/scratch allocator stats | Yes: same runtime allocator |
| Retained runtime work (nodes created, layout/paint visits, display commands, text shapes) | Yes | Yes |

The SDL_GPU solid renderer has no fingerprint cache or transform buffer;
`native_solid_build` clears and rebuilds the complete solid vertex list on every
submitted frame and `native_vertex_buffer_upload` uploads it. Text, icon, image,
and custom-surface renderers do fingerprint their retained meshes. This
asymmetry is the source of the two expectation failures below and is a property
of the reference path, not of the shared runtime.

## CPU wall-time matrix

Cells are the median of five runs; each run's p50/p95/p99 is computed from that
run's per-pass or per-submission samples, then the five percentiles are
medianed. `Submits`, `Describe`, and `Wake` are medians of the run counts.
`Idle` is the host-reported interval after the last presented frame (WebGPU) or
last primary submission (SDL_GPU), with the 1.2 s hold. All times are
microseconds unless noted.

| Scenario | Renderer | Submits | Describe | Wake | Build p50/p95/p99 | Encode p50/p95/p99 | Submit p50 | Idle ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| identical | SDL_GPU D3D12 | 32 | 32 | 31 | 25.0 / 47.4 / 51.5 | 37.8 / 78.0 / 945.3 | 148.1 | 2,209 |
| identical | WebGPU D3D12 | 32 | 32 | 31 | 25.5 / 49.9 / 52.5 | 61.7 / 139.3 / 146.6 | 55.3 | 1,200 |
| identical | WebGPU Vulkan | 32 | 32 | 31 | 27.4 / 47.6 / 50.5 | 51.0 / 97.6 / 103.2 | 42.1 | 1,200 |
| transform | SDL_GPU D3D12 | 36 | 1 | 0 | 4,043.0 (n=1) | 38.6 / 63.1 / 903.9 | 147.4 | 2,383 |
| transform | WebGPU D3D12 | 47 | 1 | 0 | 6.5 / 12.7 / 17.5 | 102.5 / 176.7 / 507.8 | 72.6 | 1,200 |
| transform | WebGPU Vulkan | 43 | 1 | 0 | 6.8 / 11.4 / 17.8 | 56.1 / 138.8 / 215.2 | 51.2 | 1,200 |
| color | SDL_GPU D3D12 | 32 | 32 | 31 | 28.8 / 50.5 / 51.0 | 39.8 / 76.8 / 1,016.9 | 157.2 | 2,207 |
| color | WebGPU D3D12 | 32 | 32 | 31 | 27.9 / 57.4 / 59.9 | 97.6 / 188.1 / 241.9 | 61.9 | 1,200 |
| color | WebGPU Vulkan | 32 | 32 | 31 | 26.8 / 52.2 / 56.5 | 52.0 / 130.4 / 241.0 | 40.5 | 1,200 |
| layout | SDL_GPU D3D12 | 32 | 32 | 31 | 34.7 / 60.7 / 67.1 | 33.9 / 64.8 / 884.5 | 137.9 | 2,207 |
| layout | WebGPU D3D12 | 32 | 32 | 31 | 40.8 / 68.9 / 71.9 | 97.3 / 181.0 / 190.9 | 60.0 | 1,200 |
| layout | WebGPU Vulkan | 32 | 32 | 31 | 40.6 / 75.9 / 92.8 | 54.5 / 142.7 / 184.7 | 40.9 | 1,200 |
| scroll-1000 | SDL_GPU D3D12 | 32 | 33 | 31 | 93.5 / 168.8 / 179.0 | 106.6 / 815.4 / 2,223.2 | 156.1 | 2,208 |
| scroll-1000 | WebGPU D3D12 | 33 | 33 | 31 | 77.3 / 138.0 / 192.7 | 151.0 / 273.6 / 304.3 | 50.0 | 1,200 |
| scroll-1000 | WebGPU Vulkan | 33 | 33 | 31 | 86.9 / 144.2 / 199.4 | 113.3 / 242.7 / 274.3 | 38.5 | 1,200 |
| scroll-10000 | SDL_GPU D3D12 | 32 | 33 | 31 | 86.8 / 188.2 / 215.6 | 106.1 / 746.0 / 1,946.9 | 148.7 | 2,208 |
| scroll-10000 | WebGPU D3D12 | 33 | 33 | 31 | 86.0 / 143.5 / 152.1 | 150.6 / 260.7 / 290.1 | 62.0 | 1,200 |
| scroll-10000 | WebGPU Vulkan | 33 | 33 | 31 | 85.6 / 154.8 / 174.4 | 114.4 / 222.1 / 242.9 | 41.5 | 1,200 |
| multiwindow | SDL_GPU D3D12 | 29 | 2 | 1 | 44.1 (n=2) | 30.9 / 49.6 / 965.5 | 139.9 | 2,383 |
| multiwindow | WebGPU D3D12 | 94 | 1 | 1 | 4.6 / 8.4 / 13.9 | 103.0 / 139.8 / 178.6 | 62.8 | 1,200 |
| multiwindow | WebGPU Vulkan | 67 | 1 | 1 | 4.1 / 10.1 / 28.4 | 41.9 / 118.6 / 244.5 | 44.5 | 1,200 |
| settled | SDL_GPU D3D12 | 1 | 1 | 0 | 3,948.8 (n=1) | 1,831.7 (n=1) | 571.3 | 2,989 |
| settled | WebGPU D3D12 | 1 | 1 | 0 | 4,003.7 (n=1) | 1,125.4 (n=1) | 1,654.1 | 1,200 |
| settled | WebGPU Vulkan | 1 | 1 | 0 | 4,113.3 (n=1) | 1,184.9 (n=1) | 117.2 | 1,200 |

Notes:

- With 32 samples, p99 is the maximum of the run. The SDL_GPU encode p99
  (~0.9-2.2 ms) is a single cold outlier in each run, consistent with first-frame
  pipeline/registration work; p50/p95 show the steady path.
- SDL_GPU encode includes hidden DevTools/inspector draw attempts; WebGPU encode
  is the application display list only. SDL_GPU submit includes fence
  acquisition; WebGPU submit is the `wgpu.QueueSubmit` call. These boundaries
  are not identical.
- Motion submissions are host-scheduled, not waker-paced, so the presented-frame
  count differs by renderer (36 / 47 / 43). Per-frame work and counters are
  compared; total times scale with frame count.
- The `settled` row is a single cold frame. Its values identify first-frame cost
  and are not steady-state timing. The idle column is the evidence for the
  scenario.
- The description scenarios pause 25 ms between waker requests, so `Build` is
  the retained description pass only; it excludes the deliberate pacing.
- `Describe` is one higher than `Submits` for scroll: the first virtual-list
  description requests one bounded visible-range correction. SDL_GPU stabilizes
  within the same host frame (8 descriptions, 1 submission at 8 frames); WebGPU
  performs the correction in the next host step, which presents one additional
  frame at this scale. Both settle to waker-paced frames afterward.

## Retained-work matrix

These are medians of the cumulative renderer/runtime counters at exit. Each run
covers the scenario's full frame sequence, so counts are compared by scenario,
not across different frame counts.

| Scenario | Renderer | Solid rebuilds | Solid vertex uploads / bytes | Solid transform uploads / bytes | Text rebuilds / cache hits | Text vertex uploads / bytes | Icon rebuilds / hits | Surface uploads / encodes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| identical | SDL_GPU | n/a (no counter) | 32 / 34,560 | n/a | 1 / 31 | 1 / 31,320 | 1 / 31 | 0 / 0 |
| identical | WebGPU D3D12 | 1 | 1 / 1,080 | 1 / 40 | 1 / n/a | 1 / 38,280 | 1 / 31 | 0 / n/a |
| identical | WebGPU Vulkan | 1 | 1 / 1,080 | 1 / 40 | 1 / n/a | 1 / 38,280 | 1 / 31 | 0 / n/a |
| transform | SDL_GPU | n/a | 36 / 38,880 | n/a | 1 / 35 | 1 / 31,320 | 1 / 35 | 0 / 0 |
| transform | WebGPU D3D12 | 1 | 1 / 1,080 | 47 / 1,880 | 1 / n/a | 1 / 38,280 | 1 / 46 | 0 / n/a |
| transform | WebGPU Vulkan | 1 | 1 / 1,080 | 43 / 1,720 | 1 / n/a | 1 / 38,280 | 1 / 42 | 0 / n/a |
| color | SDL_GPU | n/a | 32 / 34,560 | n/a | 1 / 31 | 1 / 31,320 | 1 / 31 | 0 / 0 |
| color | WebGPU D3D12 | 32 | 32 / 34,560 | 1 / 40 | 1 / n/a | 1 / 38,280 | 1 / 31 | 0 / n/a |
| color | WebGPU Vulkan | 32 | 32 / 34,560 | 1 / 40 | 1 / n/a | 1 / 38,280 | 1 / 31 | 0 / n/a |
| layout | SDL_GPU | n/a | 32 / 41,472 | n/a | 1 / 31 | 1 / 31,320 | 1 / 31 | 0 / 0 |
| layout | WebGPU D3D12 | 32 | 32 / 41,472 | 1 / 48 | 1 / n/a | 1 / 38,280 | 1 / 31 | 0 / n/a |
| layout | WebGPU Vulkan | 32 | 32 / 41,472 | 1 / 48 | 1 / n/a | 1 / 38,280 | 1 / 31 | 0 / n/a |
| scroll-1000 | SDL_GPU | n/a | 32 / 48,384 | n/a | 32 / 0 | 32 / 2,294,784 | 1 / 31 | 0 / 0 |
| scroll-1000 | WebGPU D3D12 | 5 | 5 / 7,560 | 1 / 56 | 32 / n/a | 32 / 2,804,736 | 1 / 32 | 0 / n/a |
| scroll-10000 | SDL_GPU | n/a | 32 / 48,384 | n/a | 32 / 0 | 32 / 2,294,784 | 1 / 31 | 0 / 0 |
| scroll-10000 | WebGPU D3D12 | 2 | 2 / 3,024 | 1 / 56 | 32 / n/a | 32 / 2,804,736 | 1 / 32 | 0 / n/a |
| multiwindow | SDL_GPU | n/a | 29 / 31,320 | n/a | 1 / 28 | 1 / 31,320 | 1 / 28 | 0 / 0 |
| multiwindow | WebGPU D3D12 | 1 | 1 / 1,080 | 94 / 3,760 | 1 / n/a | 1 / 38,280 | 1 / 93 | 0 / n/a |
| multiwindow | WebGPU Vulkan | 1 | 1 / 1,080 | 67 / 2,680 | 1 / n/a | 1 / 38,280 | 1 / 66 | 0 / n/a |
| settled | SDL_GPU | n/a | 1 / 1,080 | n/a | 1 / 0 | 1 / 31,320 | 1 / 0 | 0 / 0 |
| settled | WebGPU D3D12 | 1 | 1 / 1,080 | 1 / 40 | 1 / n/a | 1 / 38,280 | 1 / 0 | 0 / n/a |
| settled | WebGPU Vulkan | 1 | 1 / 1,080 | 1 / 40 | 1 / n/a | 1 / 38,280 | 1 / 0 | 0 / n/a |

`n/a` means the renderer does not expose that counter. The WebGPU icon and image
renderers increment their mesh-rebuild counter once when their empty first mesh
is prepared; it stays at 1 for scenes without icons or images. No icon, image,
or custom-surface upload occurred in any scenario, so those passes show retained
zero work.

Runtime-side work is shared code and matches across backends by construction;
the equality is still an assertion (every scenario reports the same
`nodes_created`, `layout_nodes_visited`, `paint_nodes_visited`,
`display_commands_finalized`, and `text_shape_requests` on both renderers):

| Scenario | Nodes created | Layout visits | Display commands | Text shapes | Persistent alloc calls | Scratch alloc calls |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| identical | 11 | 21 | 8 | 3 | 323 | 13,882 |
| transform | 11 | 21 | 288 (36 frames) | 3 | 277 | 13,510 |
| color | 11 | 21 | 39 | 3 | 417 | 13,882 |
| layout | 13 | 552 | 40 | 3 | 627 | 14,260 |
| scroll-1000 | 37 | 1,145 | 627 | 27 | 1,772 | 15,574 |
| scroll-10000 | 37 | 1,145 | 627 | 27 | 1,772 | 15,574 |
| multiwindow (primary) | 11 | 21 | 232 (SDL) / 752 (D3D12) / 536 (Vulkan) | 3 | 260 / 451 / 370 | 13,522 / 13,510 / 13,510 |
| settled | 11 | 21 | 8 | 3 | 167 | 13,510 |

The multiwindow display-command total counts retained presentation frames for
the primary runtime on each host; frame counts differ because scheduling
differs. It is not a description storm: both windows describe once (SDL's
primary adds one startup resize pass).

### Scroll scaling

The 1,000- and 10,000-item lists produce identical retained work on every
renderer:

| Renderer | Items | Nodes created | Layout visits | Display commands | Text shapes | Solid vertex bytes | Text vertex bytes | Text atlas uploads / bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| SDL_GPU | 1,000 | 37 | 1,145 | 627 | 27 | 48,384 | 2,294,784 | 8 / 33,554,432 |
| SDL_GPU | 10,000 | 37 | 1,145 | 627 | 27 | 48,384 | 2,294,784 | 8 / 33,554,432 |
| WebGPU D3D12 | 1,000 | 37 | 1,145 | 627 | 27 | 7,560 | 2,804,736 | 95 / 1,406,104 |
| WebGPU D3D12 | 10,000 | 37 | 1,145 | 627 | 27 | 3,024 | 2,804,736 | 95 / 1,406,104 |

The virtual list realizes the same visible range at both sizes. WebGPU's solid
mesh rebuild count differs (5 vs 2) but remains bounded and independent of item
count. SDL_GPU's text-atlas byte total is full-page uploads; WebGPU's total
reflects smaller dirty-region uploads. The byte totals are therefore not
directly comparable, while the upload *counts* and runtime work are.

## Expectations

All 131 expectations are recorded in the harness CSV. Summary by scenario:

| Scenario | Expectations | PASS | FAIL | Result |
| --- | ---: | ---: | ---: | --- |
| identical descriptions | 20 | 19 | 1 | FAIL: SDL_GPU re-uploads solid geometry on every submitted frame |
| transform-only animation | 13 | 12 | 1 | FAIL: SDL_GPU rebuilds/re-uploads solid geometry for every motion frame |
| color animation | 16 | 16 | 0 | PASS: only solid content updates; text/icon/image/surface retained |
| localized layout change | 22 | 22 | 0 | PASS: text/icon/image/surface geometry retained; layout visits bounded |
| scrolling 1k and 10k | 25 | 25 | 0 | PASS: identical bounded work at both sizes |
| simultaneous multi-window motion | 19 | 19 | 0 | PASS: one description per window, one scheduled close wake, no storm |
| settled interface | 16 | 16 | 0 | PASS: one frame, zero wakes, >= 1 s idle |
| **Total** | **131** | **129** | **2** | |

The two failures are real reference-path findings, not harness errors:

1. **Identical descriptions: SDL_GPU uploads solid geometry every frame.**
   With 32 identical descriptions, SDL_GPU made 32 solid vertex uploads
   (34,560 bytes) while WebGPU made 1 upload (1,080 bytes) and 1 mesh rebuild.
   Text, icon, image, and custom-surface geometry were retained on both sides
   (SDL_GPU text: 1 rebuild, 31 cache hits, 1 upload). SDL_GPU's solid renderer
   has no fingerprint cache or per-command geometry; `native_solid_build` clears
   and rebuilds the full solid vertex list for each submitted frame.
2. **Transform-only animation: SDL_GPU rebuilds solid geometry for every
   retained frame.** Both backends described once (expected), and SDL_GPU
   presented 36 retained frames with 0 application wakes. Text was retained
   (1 mesh rebuild, 35 cache hits, 1 upload), but the moving marker is a solid
   surface: SDL_GPU performed 36 solid uploads (38,880 bytes). WebGPU performed
   0 solid mesh rebuilds, 0 solid vertex uploads, and 47 transform updates
   (1,880 bytes, one `[2]f32` per solid draw per frame). WebGPU text also
   updated only its transform buffer (47 uploads) without rebuilding glyph
   geometry.

This is the strongest single migration argument in the matrix: the WebGPU
renderer's retained solid/transform path avoids geometry re-uploads that the
SDL_GPU reference path performs on exactly the workloads a retained UI is meant
to optimize. It is also a bounded, testable gap if the reference renderer is
ever brought to parity.

### Other expectation findings

- **The earlier motion confounder is superseded.** With the same scene and
  motion declaration, SDL_GPU described **once** and presented 36 retained
  frames; WebGPU described once and presented 47 (D3D12) or 43 (Vulkan) retained
  frames. The earlier record's statement that SDL_GPU rebuilt the description
  per motion frame does not reproduce. The remaining per-frame difference is
  scheduler pacing and renderer work, not a different application workload.
- **Layout invalidation is coarser than geometry retention.** A one-box width
  change on a fixed-height row caused 552 layout-node visits over 32 frames
  (about 17 per frame) versus 21 for identical frames, while text/icon/image/
  surface geometry stayed retained and no nodes churned (13 created, all
  initial). The renderer-level retention expectation passes, but the runtime
  layout stage re-visits far more than the changed row. This is a retained
  runtime locality opportunity, not a WebGPU/SDL_GPU difference.
- **Color and localized layout updates are targeted at the paint-type level.**
  They rebuild only solid geometry on both renderers; text, icon, image, and
  surface meshes do not change. WebGPU still rebuilds the complete solid mesh
  when a color/size fingerprint changes; per-command solid mesh caching remains
  a future refinement for both renderers.
- **Multi-window invalidation is independent.** Both windows described once and
  received no application wakes during motion; the only wake is the scheduled
  auxiliary-close request. SDL_GPU's primary added one pre-motion description
  from a startup pixel-resize event (describe_calls=2, last description at
  ~145 ms), while WebGPU described once at startup. The description **content**
  sequence is the same; the count differs by one host startup event, which is
  recorded rather than hidden.
- **Idle behavior is demand-driven.** The settled scenario submitted one frame,
  delivered zero application wakes, and then stayed idle for the observation
  window (2.99 s SDL_GPU, 1.2 s WebGPU). No periodic frame request appeared in
  either host. The WebGPU host's own loop still evaluates its timeout while the
  hold is pending; that internal step count is reported in the raw logs but is
  not an application frame request or wake.

## Cross-check against the feasibility fixture

The Windows D3D12 and Vulkan readback fixture
(`examples/15_webgpu_feasibility`, built with its committed `build.ps1`) was run
on the same machine and adapter. Its retained-work assertions are consistent
with the matrix's WebGPU counters:

```text
[webgpu-feasibility] retained solid cache PASS mesh_rebuilds=1 vertex_uploads=1
  vertex_bytes=648 transform_uploads=1 transform_bytes=24 viewport_uploads=1
  unchanged_repeat=true
[webgpu-feasibility] solid translation cache PASS mesh_rebuilds=0
  vertex_uploads=0 transform_uploads=1 transform_bytes=24
[webgpu-feasibility] retained text cache PASS mesh_rebuilds=1 vertex_uploads=1
  atlas_uploads=1 ... unchanged_repeat=true
[webgpu-feasibility] text motion cache PASS translated_command_only=true
  glyph_mesh_uploads=0 atlas_uploads=0 atlas_page_creates=0
[webgpu-feasibility] custom geometry instance cache PASS
  translation_and_opacity_changes=1 mesh_rebuilds=0 vertex_uploads=0
```

Both D3D12 and Vulkan produced these PASS lines. The matrix's `identical`
scenario (1 rebuild/1 upload and no repeat work), `transform` scenario (0 mesh
rebuilds, 0 vertex uploads, transform-only updates), and `layout`/`color` text
retention agree with the fixture's direct readback-counter assertions. Raw
lines are in
[`raw/webgpu-feasibility-workload-crosscheck-2026-11-19.txt`](raw/webgpu-feasibility-workload-crosscheck-2026-11-19.txt).

## Confounders and limits

- SDL_GPU runs through SDL's D3D12 backend; WebGPU runs through wgpu-native's
  D3D12 or Vulkan backend. Queue construction, submission flushing, fence
  ownership, and present-call boundaries differ.
- The WebGPU D3D12 submit call was consistently slower than Vulkan in these
  runs. This record does not attribute the difference.
- SDL_GPU's encode total includes hidden DevTools/inspector draw attempts;
  WebGPU's is the app display list only. SDL_GPU's submit includes fence
  acquisition.
- Description scenarios are paced at 25 ms per waker request. Motion and
  multi-window frames are paced by each host's scheduler, so presented-frame
  counts differ (36/47/43). Per-frame retained work is compared; totals are
  not.
- The SDL_GPU idle hold starts after the last primary submission and is
  combined with the existing 3 s smoke window (observed ~2.2-3.0 s idle).
  WebGPU waits 1.2 s after the last presented frame. Both satisfy the ">= 1 s"
  idle assertion, but the windows are not the same length.
- A startup pixel-resize event can add one SDL_GPU description before motion in
  the multi-window scenario. It is visible in the description span and count.
- The scroll scenario's first description may request one bounded visible-range
  correction. SDL_GPU stabilizes it in-frame; WebGPU presents one extra frame at
  this scale. Both then settle to waker-paced frames.
- Five runs on an interactive, non-idle-exclusive desktop cannot characterize
  variance. The p99 column over 32 samples is the run maximum and includes
  first-frame warm-up.
- No GPU timestamps, queue-completion intervals, display-level pacing, or
  visible latency were measured. The fixture is deliberately small (11-37
  retained nodes) and is not a production Scratchpad/Punks workload.
- No CI perf numbers were used; CI software/paravirtual adapters are excluded
  by design.

## Artifacts

- `docs/validation/raw/webgpu-vs-sdlgpu-workload-matrix-2026-11-19.txt`: the
  harness summary (medians, all 131 expectations, failures) and counter
  medians.
- `docs/validation/raw/webgpu-feasibility-workload-crosscheck-2026-11-19.txt`:
  the retained-work lines from the D3D12 and Vulkan feasibility readback runs.
- Machine-local, ignored: `matrix-runs.csv`, `matrix-expectations.csv`,
  `matrix-summary.md`, and one log per run under
  `out/webgpu-phase0/matrix-2026-11-19/matrix/`.

## Limits

This fills the matched-description, retained-work, motion, multi-window, scroll,
and idle parts of the Phase 0 application-level comparison for one fixture. It
does not establish performance parity or a WebGPU win in stage timings, does not
measure GPU execution or visible latency, and does not cover a production
application. It does establish that the matched workload does not re-describe
during motion on either backend, that WebGPU retains solid/transform work where
the SDL_GPU reference re-uploads it, and that both runtimes keep identical
retained-work counters for the shared scene.
