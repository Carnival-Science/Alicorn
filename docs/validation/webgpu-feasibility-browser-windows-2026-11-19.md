# WebGPU feasibility fixture: live browser execution — Windows

Date: 2026-11-19  
Platform: Windows x64  
Compiler: Odin `dev-2026-11-nightly:08539cd` (`C:\odin\odin.exe`)  
Browser: Helium (connected as "Chrome on this computer"), Chromium/Chrome 143  
Node: v24.18.0  
Repository head: `ecc8f19208acdd3292514df21f7a2c49afe40be7` on
`codex/webgpu-phase0-feasibility`  
Last code-changing commit: `40afdff` (later commits change documentation only)

## Scope

This run executes the staged `js_wasm32` build of
`examples/15_webgpu_feasibility` in the user's real browser through WebGPU. It
records browser adapter/device initialization, the fixture's asynchronous
readback matrix, renderer cache and retirement counters, demand-driven
scheduling, console output, and a full-page screenshot.

The goal was the browser GPU gap left by the 2026-11-17 solid-transform slice:
that change compiled for `js_wasm32`, but its live browser run had not been
performed. This run covers the transform and cropped-capture path in a real
browser in addition to the earlier fixture readbacks.

The staged web directory is:

```text
examples/15_webgpu_feasibility/web/
  feasibility.wasm              5,458,441 bytes
    sha256 3a3ff70667de15811c16a44389e746dd57416c7d2f04934cb4b57a3680d225e8
  index.html                    9,775 bytes
  wgpu.js                     115,982 bytes
  odin.js                      75,074 bytes
  alicorn_demand_scheduler.js   4,414 bytes
  alicorn_accessibility_dom.js 13,892 bytes
```

Those artifacts were staged from the code at `40afdff`; the only later commit
on this branch is documentation. They were not rebuilt for this run. The
recorded evidence applies to the wasm hash above.

## Commands

From the repository root, serve the staged directory with a static server that
sends `application/wasm` and `Cache-Control: no-store`:

```powershell
node C:\Users\saman\AppData\Local\Temp\opencode\alicorn-static-server.js `
  C:\Users\saman\.codex\worktrees\alicorn-webgpu-migration\alicorn\examples\15_webgpu_feasibility\web `
  8766
```

Open `http://127.0.0.1:8766/`. The page starts WebGPU initialization on load;
no click is required. Console capture was started on a blank tab before
navigation, so adapter, device, and page errors were captured from the first
script execution.

The fixture's **Resize surface** button was clicked twice after the readback
matrix settled. The second click moved the canvas from 1662x934 to 1305x734
CSS/device pixels at DPR 1, and the footer returned to the settled idle state.

## Results

### Browser WebGPU initialization

- The page requested backend `Undefined`, as expected for a browser rather than
  an explicitly selected native backend.
- Adapter callback status `Success`, adapter present. The page's adapter
  classification was
  `fallback=false vendor=nvidia architecture=turing device=(redacted)
  description=(redacted)`.
- Adapter info through the fixture reported `backend=WebGPU type=Unknown
  vendor=nvidia architecture=turing`.
- Surface capabilities query succeeded with `formats=1 alpha_modes=2`.
- Device request succeeded; the device callback reported `Success`,
  device present, empty message. The page logged that the browser device promise
  resolved.
- The shared Hosted_Runtime, browser input bridge, and canvas presenter
  connected.

The browser does not expose Dawn's internal backend choice (D3D12 versus
Vulkan) to page JavaScript. `backend=WebGPU` and `type=Unknown` are the WebGPU
API's values, not wgpu-native's D3D12/Vulkan selector. This run therefore does
not claim which operating-system graphics API Dawn used.

### Readback matrix

All of the fixture's readback groups reported PASS in the browser:

```text
async RGBA8 readback core PASS texture=63x64 row_pitch=256 padding_per_row=4
  bytes=262144 clear=true solid=true checker=true partial_texture=true
  partial_buffer=true uniform=true blend=true glyph=true clip=true
  outside_clip=true rounded=true rounded_corner=true last_row=true
async RGBA8 readback compositor PASS display_blend=true clip_x=true clip_y=true
  text=true overlay_order=true offset_text=true icon=true icon_clip=true
  atlas_switch=true image_red=true image_alpha=true image_blue=true
  image_clip=true solid_motion=true crop_a=true crop_b=true
async RGBA8 readback effects PASS backdrop=true backdrop_clip=true
  prefix_reuse=true prefix_invalidation=true resized=true fallback=true
  geometry_rect=true segment=true circle=true marker=true geometry_clip=true
  waveform=true gradient=true raised=true raised_bevel=true recessed=true
  recessed_bevel=true
rounded accessibility-material readback PASS variant=true face=true bevel=true
  corner=true reduced_transparency_shadow=true
custom geometry translation/opacity pixel PASS
  moved_pixel=[137, 28, 30, 255] original_pixel=[20, 31, 46, 255]
```

The compositor line includes `solid_motion=true`, `crop_a=true`, and
`crop_b=true`. Those are the checks added by the solid-transform slice: the
translated/clipped surface readback and both full-display-to-cropped-target
comparisons. The browser therefore executed the path that the 2026-11-17
report could only build.

### Renderer counters

The browser printed the same retained-cache counters as the native runs:

```text
retained solid cache PASS mesh_rebuilds=1 vertex_uploads=1 vertex_bytes=648
  transform_uploads=1 transform_bytes=24 viewport_uploads=1
  unchanged_repeat=true
mixed paint-order compositor PASS commands=15 solid_meshes=1 text_meshes=1
  icon_meshes=1 icon_vertex_uploads=1 icon_atlas_pages=2
  icon_atlas_bytes=1572864 image_meshes=1 image_vertex_uploads=1
  image_texture_uploads=2 image_texture_bytes=128 custom_surface_meshes=2
  custom_surface_vertex_uploads=2 custom_surface_vertices=72
  instance_uploads=1
solid target resize cache PASS mesh_rebuilds=0 vertex_uploads=0
  transform_uploads=0 viewport_uploads=2
solid translation cache PASS mesh_rebuilds=0 vertex_uploads=0
  transform_uploads=1 transform_bytes=24
solid instance transform submitted PASS translation=5,5 clip=5,5,20,20
  readback_slot=15
```

Moving and clipping one surface caused zero mesh rebuilds and zero vertex
uploads, and one 24-byte transform upload. Resizing the target and restoring it
caused two viewport updates and no mesh, vertex, or transform upload. The
retained text, text-motion, image, custom-geometry, and per-resource geometry
cache checks also passed.

### Backdrop effects and retirement

```text
backdrop WebGPU prefix cache PASS capture=3 filters=3/3 composite=6
  cache_hits=2 mesh_rebuilds=2 texture_bytes=100040 cache_budget=50331648
  resize_retired=1 budget_fallback_bytes=52013000
backdrop resized texture retirement PASS submitted=5 completed=8 retired=0
  resident=74120 active=74120
image resource retirement PASS submitted_serial=2 completed_serial=2 retired=0
  resident_bytes=64 releases=1
custom geometry buffer retirement PASS submitted_serial=2
  completed_serial=2 retired=0 active_bytes=10752 resident_bytes=10752
  retirements=1 releases=1
multiple backdrop prefix pixels PASS differing_inside_later_clip=288
backdrop over-budget fallback PASS every RGBA pixel matches plain paint
queue work done status=Success message=
```

The two-marker comparison produced 288 differing pixels inside the later
marker's clip, showing that the later effect sampled the earlier effect's
composed output. The over-budget effect plan fell back to ordinary paint and
matched every RGBA pixel. Completion callbacks released in-flight resources and
returned residency to the tracked active bytes.

### Scheduling and interaction

The footer's initial settled state was:

```text
Settled: demand-driven idle (3 frame requests; 1 initialization wake frames).
```

After the resize clicks it reached the same settled state with 9 frame requests.
The page did not keep an animation-frame loop running while idle. The rendered
canvas, hosted controls, and footer diagnostics are visible in
[`assets/webgpu-feasibility-browser-2026-11-19.png`](assets/webgpu-feasibility-browser-2026-11-19.png).

### Console

The full capture is in
[`raw/webgpu-feasibility-browser-2026-11-19.txt`](raw/webgpu-feasibility-browser-2026-11-19.txt).
There were two non-fixture entries:

- `GET /favicon.ico` returned 404 because the fixture does not ship a favicon.
  The page itself and every module and wasm request returned 200.
- Chromium warned that `powerPreference` is ignored by `requestAdapter()` on
  Windows (`crbug.com/369219127`). This is a browser-platform warning, not a
  fixture failure.

There were no WebGPU uncaptured errors, no unhandled promise rejections, no
`window` error events, and no `[browser console.error]` entries from the page.

## Limits

- Only one browser, OS, and GPU were exercised: Helium/Chrome 143 on Windows
  x64 with an NVIDIA Turing adapter. The page reports `fallback=false` and
  vendor/architecture metadata, but those privacy-limited values do not by
  themselves prove physical-GPU acceleration. The exact adapter model and
  Dawn's internal OS backend were redacted or unavailable to page JavaScript.
- The run is correctness and lifecycle evidence, not a performance measurement.
  The fixture prints counters, not GPU timestamps or frame timings.
- The browser fixture does not trigger device loss or demonstrate wasm
  loss-recovery. Its page reports device loss as a terminal state; the separate
  browser recovery state machine is still not physically exercised here.
- Clicking the hosted controls through the accessibility projection was blocked
  in this harness by the page overlay hit test ("body is on top"). No browser
  input evidence is claimed from this run.
- The staged wasm was built from the last code-changing commit rather than
  rebuilt at the documentation head. The hash above identifies the exact
  artifact; a rebuild should invalidate this record until rerun.
- macOS and Linux browser GPU execution, and the production application
  presenter, remain untested.
