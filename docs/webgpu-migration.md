# SDL_GPU to WebGPU migration

Status: Phase 0 in progress. Production rendering remains SDL_GPU until the shared
native/browser feasibility fixture and parity gates pass.

## Architecture inventory

The current path is `application -> ui -> runtime retained state and ordered paint
stream -> native/sdl_gpu -> SDL_GPU`. The architecture document explicitly keeps
runtime identity, reconciliation, layout, text shaping products, paint order,
interaction, focus, semantics, and motion independent of the native renderer.

| Area | Existing ownership | Migration treatment |
| --- | --- | --- |
| GPU-independent, retain unchanged | `runtime/`, `ui/`, app callbacks, invalidation, paint command ordering, semantic model, focus/input policy, text editing, shaping, motion, themes/material descriptions | Preserve public behavior. Runtime must not import SDL3, WGPU, or browser packages. |
| CPU rendering products to reuse/extract | Paint commands and text runs; image payloads; generic `runtime/gpu_surface` samples; Runa shaping/rasterization and glyph atlas packing in `third_party/Runa`; CPU mesh, text and asset presentation helpers in `renderer/cpu` | Keep mesh, atlas and image products backend-neutral and reconstructible after device loss. |
| SDL_GPU-specific replacement | `native/sdl_gpu/{gpu_frame,solid,text,surface,images,icons,retained_effects,effects_compositor,vertex_buffers,render_capture}.odin`; GPU resources, shaders, upload policy, render passes, readback and retirement | Replace incrementally with `renderer/webgpu/` and shared WGSL. Do not alter geometry/shaping as incidental migration work. |
| Native host responsibilities to retain | SDL3 window/event lifecycle, DPI, text input/IME, clipboard, dialogs, drag/drop, titlebars/menus, AccessKit, primary and secondary window scheduling | Keep in SDL3 host modules. Replace only surface/device/presentation integration. |
| Browser host to add | Canvas sizing/DPR, WebGPU surface/device, pointer/wheel/keyboard/touch, browser focus/composition/clipboard, visibility, bounded scheduling, DOM/ARIA projection and capability errors | Add `host/web/` using Odin `js_wasm32` interop and narrow JS integration. No Emscripten or WebGL renderer. |
| Public API/downstream impact | `ui.run` and authoring APIs are public goals; examples and applications currently import `alicorn:native/sdl_gpu` | Preserve `ui.run` and UI/runtime contracts. Provide a temporary narrow import shim only if needed. Coordinate compile/import updates for examples, AliKit, Scratchpad and Punks at migration gates. No raw WGPU handles in widget APIs. |

The exact paint-stream order is a correctness contract. The renderer must not
sort primitives into batches that change stacking. GPU surface declarations are
backend-neutral; their current native payload renderer is not.

## Existing issue alignment (2026-11-15)

- Open [#163](https://github.com/samanshaiza004/alicorn/issues/163) contains an
  earlier bounded-browser research plan whose boundary explicitly says not to
  replace SDL_GPU. This owner-directed migration supersedes that restriction.
  Its browser input, accessibility, text/IME and capability-limit questions
  remain relevant; this migration tracker is authoritative for renderer scope
  and phase gates.
- [#162](https://github.com/samanshaiza004/alicorn/issues/162) is closed with
  the host-owned SDL_GPU presenter boundary now on `master`. That validates the
  current external-frame seam, but does not prove that a WebGPU renderer
  consumes Alicorn's production paint stream.
- Open [#204](https://github.com/samanshaiza004/alicorn/issues/204) describes
  failure recovery after acquiring an SDL_GPU swapchain texture. It remains a
  risk for the temporary reference path while SDL_GPU is retained; it does not
  dictate the WebGPU frame transaction. Keep its host/renderer recovery
  requirements visible when comparing the reference implementation.

## Phase tracker

| Phase | Exit evidence | Status |
| --- | --- | --- |
| 0. Feasibility and baseline | Windows SDL_GPU reference captured; same Odin/WGPU code builds and runs native and browser; solid/clipped/blended/rounded/image/Runa text/waveform/settled-motion, partial texture and buffer uploads, uniform-buffer layout, padded async readback, and queue-completion callbacks demonstrated; binding/lifecycle limitations recorded | In progress: Windows D3D12 and hosted macOS arm64 Metal smoke/callback evidence pass; Linux x64 X11/lavapipe native smoke and `js_wasm32` build pass; physical Linux GPU/Wayland, driver/OS loss, recovery, and production parity evidence remain open |
| 1. Separation | renderer/host package boundary with unchanged runtime and app API | In progress: shared UI authoring and CPU surface mesh assembly plus text/image/icon preparation are SDL-independent and compile for `js_wasm32`; native `ui.run` remains target-gated. GPU renderer/host extraction and browser `ui.run` remain outstanding |
| 2. Core parity | solid, clipping, text, image, icon, materials and custom surfaces pass native/browser tests | Not started |
| 3. GPU lifecycle | bounded asynchronous retirement, capture/readback, device loss/recreation and window teardown validated | Not started |
| 4. Desktop acceptance | full regression suite, pixel comparisons, performance and Scratchpad/Punks/AliKit dogfood | Not started |
| 5. SDL_GPU removal | delete production backend, legacy shader artifacts, switches and obsolete docs | Not started |
| 6. Browser host | interaction, accessibility, text/IME, lifecycle and demand-driven scheduling complete | Not started |
| 7. Release readiness | docs, reproducible setup, CI and substantive shared-renderer web example | Not started |

Phase 0 does not authorize a production renderer rewrite. SDL_GPU remains the
reference implementation until parity evidence is available.

## Phase 1 boundary slice (Windows, 2026-11-15)

The first separation step removes the direct native-host dependency from the
shared UI authoring package. `ui/ui.odin` now owns its small backend-neutral
`Application_Waker` value and shared runtime interaction helpers. The native
`ui.run` implementation lives in `ui/run_native.odin`, behind Odin's `!js`
build constraint; it adapts the shared waker to the existing SDL host callback.
Native callers retain `ui.run` and the same callback behavior.

Odin compiles test source files as part of imported packages, so the runtime and
UI test files are excluded from `js` builds. They still compile and run on
native targets. The shared runtime and UI implementation itself remains
unchanged by target; this is a package-boundary change, not a renderer change.

`tools/check_web_ui_package.ps1 -Odin C:\odin\odin.exe` builds a real
`js_wasm32` consumer that imports `alicorn:ui` and calls its declarative text
API. The check passed on Windows. `odin test ui` passed all 39 UI tests,
`odin test runtime` passed all 343 runtime tests, and the native
`examples/01_hello` `ui.run` consumer built successfully. An initial broad
`tools/test.ps1` attempt stopped in the AccessKit UI Automation smoke with
`Accessible Button missing`; a later full rerun passed all stages, as recorded
in the refreshed Windows validation below.

This is only the UI/runtime package boundary. `ui.run` is currently unavailable
on `js_wasm32` until the browser host is implemented; most SDL_GPU production
code and SDL host responsibilities are still co-located under `native/sdl_gpu`.
The next Phase 1 work should establish the renderer/host boundary without
rewriting production rendering before the parity gates.

### CPU renderer preparation boundaries (Windows, 2026-11-15)

The shape/material CPU mesher, image/icon quad generation and mesh fingerprints,
text paint-span color resolution, text quad clipping, physical-pixel glyph
snapping, logical-to-device-pixel rounding, cache hashing, and their 36-byte
position/color/UV vertex product now live in `renderer/cpu`, with no SDL or GPU
imports. The SDL_GPU renderers call those shared routines; text atlas lookup,
glyph rasterization/residency, image and icon GPU texture ownership, buffers,
and uploads remain in the native backend. Paint ordering, geometry generation
and shaders are unchanged. Existing material, connected-tab, image readback,
icon clipping, text clipping/span-color/snapping and pixel-finalization
regressions exercise the shared implementation through native tests.

The WASM package-boundary fixture imports `alicorn:renderer/cpu` and generates
a quad and calls its glyph-snap and pixel-edge helpers, so Odin type-checks the
extracted CPU mesh, text-preparation and pixel-geometry package for `js_wasm32`
without pulling SDL_GPU into the target. On Windows, `odin check renderer/cpu
-no-entry-point` passed, all 194 `native/sdl_gpu` tests passed, and
`tools/check_web_ui_package.ps1 -Odin C:\odin\odin.exe` passed. The full
`tools/test.ps1` suite was not rerun for this slice. This is CPU-side
preparation reuse, not a shared production WebGPU renderer; SDL_GPU remains
the only production backend. In particular, shaped runs still resolve glyph
slots through the mutable Runa atlas on the native side; extracting a
reconstructible CPU atlas/raster product is a separate renderer slice.

### Shared solid-surface assembly (Windows, 2026-11-15)

Surface material resolution, culling bounds, scale-aware clipping, shape
expansion, and ordered per-paint draw metadata now live in
`renderer/cpu/solid.odin`. The SDL_GPU package supplies the retained runtime and
display list; the native backend keeps its GPU pipeline/resource lifecycle,
buffer growth, SDL scissor conversion, uploads, and submission around that CPU
mesh product. The mesh builder keeps one draw slot per display-list command and
preserves the original paint order.
Existing relief, rounded-surface, outside-stroke, fractional-DPI, and mixed
paint-order regressions now exercise the shared surface mesh through the native
adapter. The HUD's transient quads also use the shared vertex helper.

On Windows, `odin check renderer/cpu -no-entry-point` passed, all 194
`native/sdl_gpu` tests passed, the native application executable built, and
`tools/check_web_ui_package.ps1 -Odin C:\odin\odin.exe` passed. This move does
not create a WebGPU production backend or alter geometry and shader policy;
native rendering still uses SDL_GPU. GPU validation and performance comparison
for the production WebGPU compositor remain Phase 0/2 gates.

The two new `renderer/cpu` solid-mesh unit tests passed and are now included in
both `tools/test.ps1` and `tools/test.sh`. The Windows
`tools/validate_blending.ps1 -Odin C:\odin\odin.exe` D3D12 readback also
passed: 348 of 348 expected cases across surfaces, per-corner surfaces,
geometry, icons, images, text and mixed paint; gradient orientation, stops,
rounded clipping and source-over checks passed. Its recorded p50/p95 timings
include offscreen submission/fence/readback and are not a before/after renderer
performance comparison.

The material geometry benchmark now imports `renderer/cpu` directly instead of
reaching through the SDL_GPU host package. The Windows run of
`tools/bench_material.ps1` with `-Odin C:\odin\odin.exe` passed, including
direct/material output equivalence and the geometry budget assertions. Its
local timing output is not added as migration performance evidence: this changes
the measured call path, and this run did not capture complete machine metadata.

## Phase 0 feasibility results (Windows, 2026-11-15)

`examples/15_webgpu_feasibility` builds from the same Odin renderer source for
Windows SDL3/wgpu-native and browser `js_wasm32`. Both targets rendered the
fixture and passed thirteen checks from an asynchronous 63×64 RGBA8 readback,
copied using a 256-byte row pitch with four padding bytes per row:
clear color, solid color, sampled checker texture, partial texture upload,
nonzero-offset partial vertex-buffer upload, a uniform-buffer layout and
binding probe, source-over blend, Runa glyph-atlas coverage, inside/outside
scissor clipping, rounded-rectangle fill, rounded-corner exclusion, and a last-
row check. This exercises more than the on-screen scene: each pixel result is
asserted identically by the shared Odin callback on both targets. The scene also
exercises partial vertex-buffer uploads, aligned vertex fields, resize, waveform
bars, and demand-driven animation that stops after settling. The original
Windows native run used D3D12 on an RTX 2080 SUPER. A
later fresh run is recorded below with the backend it actually selected. The
browser fixture was executed in a real WebGPU browser session; its adapter
fallback flag was captured in the later metadata probe below. The readback
result is exposed in the page's live accessible validation status. The last-row
and partial-buffer samples exercise the padded row pitch and nonzero upload offset.
Both targets also reported successful `QueueOnSubmittedWorkDone` callbacks;
the bounded native smoke waits for both queue completion and async readback
before exit.

An opt-in destruction experiment (`FEASIBILITY_TEST_DEVICE_LOSS=true`) delivered
the `Destroyed` device-loss callback in browser WebGPU after the readback
passed. Destruction is deferred until the host loop regains control, so it does
not occur reentrantly inside the map callback. On Windows wgpu-native/D3D12,
both the full readback test and a minimal early-destroy test (before GPU
resources or submissions) fail to deliver the callback. The early probe was
repeated with both `AllowProcessEvents` and `AllowSpontaneous` callback modes.
The existing `wgpu.DevicePoll` wrapper plus `InstanceProcessEvents` were run;
the blocking poll reported `queue_empty=true`, and the normal release/teardown
path also completed without a callback. This rules out callback reentrancy,
callback mode, and outstanding queue work as sufficient explanations. The
native result still does not establish device-loss notification or recovery.

Upstream wgpu issue [#9278](https://github.com/gfx-rs/wgpu/issues/9278)
describes the requirement to poll after destroy, while
[#9579](https://github.com/gfx-rs/wgpu/issues/9579) tracks destroy/callback
behavior around queue draining. Source inspection of the pinned
wgpu-native `v29.0.1.1` C API shows a more specific integration gap: its
`wgpuAdapterRequestDevice` extracts `deviceLostCallbackInfo` into
`ErrorSinkRaw`, but does not register the callback with wgpu-core's
`device_set_device_lost_closure` path. `wgpuDeviceDestroy` only marks the core
device destroyed; the later poll invokes a lost callback only when that core
closure is installed. This matches the native probe and the browser/native
difference. See the pinned [wgpu-native C API](https://github.com/gfx-rs/wgpu-native/blob/v29.0.1.1/src/lib.rs#L767-L827)
and [device destroy path](https://github.com/gfx-rs/wgpu-native/blob/v29.0.1.1/src/lib.rs#L2399-L2406),
alongside wgpu-core's [device-lost closure registration](https://github.com/gfx-rs/wgpu/blob/v29.0.1/wgpu-core/src/device/global.rs#L1847-L1879)
and [poll-time callback dispatch](https://github.com/gfx-rs/wgpu/blob/v29.0.1/wgpu-core/src/device/resource.rs#L900-L920).
The same missing registration was still present in the upstream wgpu-native
`trunk` source inspected on 2026-11-15, so simply advancing the binary pin is
not yet a validated remedy.

### Targeted native callback patch validation

The minimal fix is now captured as
[`dependencies/patches/wgpu-native-v29.0.1.1-device-lost-callback.patch`](../dependencies/patches/wgpu-native-v29.0.1.1-device-lost-callback.patch).
It registers wgpu-core's one-shot device-lost closure at native device creation,
maps the core reason to the C API reason, takes the user callback out of the
error-sink mutex before invoking it, and safely supplies a null device handle
if the C wrapper has already been released. The patch is deliberately limited
to the pinned dependency source; Alicorn's production renderer remains
untouched.

On 2026-11-15, the patched release library compiled with Odin's pinned
`29.0.1.1` bindings and passed four Windows x64 / D3D12 fixture runs: early
destroy with `AllowProcessEvents`, early destroy with `AllowSpontaneous`, final
wrapper release before polling, and destroy after a successful full GPU
readback. Every run printed exactly one `reason=Destroyed` notification and
exited through normal fixture teardown; releasing the wrapper first reported
`device_handle_present=false` as required by the nullable callback handle.
This resolves the explicit-destroy callback discrepancy for the tested native
configuration. The installed, unmodified Odin library still shows the
original failure. Exact patch/build instructions and outputs are in the
[Windows validation record](validation/webgpu-device-loss-callback-patch-windows-2026-11-15.md).

The smallest reproducer is the fixture's zero-resource/zero-submission native
probe with an explicitly supplied `deviceLostCallbackInfo`: destroy, call
`DevicePoll(wait=true)`, then `InstanceProcessEvents`; it reports an empty
queue but no callback with the unmodified library. This is no longer an
unlocalized Odin-binding suspicion. The checked-in source patch registers the
core lost closure and dispatches the C callback/userdata outside the error-sink
lock while respecting the C callback lifetime rules. No upstream report has
been filed from this work.

Phase 0's shared-rendering feasibility and the patched explicit-destroy
callback path are demonstrated on Windows D3D12 and hosted macOS arm64 Metal.
Hosted Linux x64 X11/lavapipe smoke and `js_wasm32` compilation now also pass;
this is software Vulkan evidence, not physical-GPU or Wayland validation.
Phase 0 remains open because the fixture does not establish driver/OS-initiated
loss, device recreation, general in-flight shutdown safety, resource retirement,
secondary windows, or production performance parity.

## Hosted Linux x64 validation (2026-11-15)

The [Linux feasibility workflow for `d1d3c1f`](https://github.com/samanshaiza004/alicorn/actions/runs/43759132474)
passed on Ubuntu 26.04. It downloaded and SHA-256-verified the pinned Odin
`dev-2026-11` x86-64 SDK and wgpu-native `v29.0.1.1`, built all three native
fixtures and the browser `js_wasm32` fixture, and ran the native smoke under
Xvfb against Mesa llvmpipe (lavapipe software Vulkan).

The shared 63×64 RGBA8 asynchronous readback passed all thirteen pixel probes
with a padded 256-byte row pitch. The native surface-resize smoke submitted
present work at both 800×450 and 720×405. This validates Linux x64 linking,
X11 surface use in the virtual display, Vulkan software rendering, readback, and
resize submission. The browser artifact was built but not executed by this
Linux job; browser runtime evidence is recorded separately. This result does
not measure physical GPU performance and does not validate Wayland.

After integrating the latest `master` changes, the corrected Linux workflow on
[`abc645a`](https://github.com/samanshaiza004/alicorn/actions/runs/43761187143)
also passed. It verifies the selected adapter from the fixture's own startup
log (`backend=Vulkan`, `vendor=llvmpipe`) instead of invoking `vulkaninfo` under
Xvfb; the latter's optional XCB diagnostic had failed to connect in one runner
attempt. The same run passed all thirteen asynchronous readback probes and
submitted the resized surfaces at 800×450 and 720×405. The WASM target was
built in CI; this run does not claim browser execution, physical Linux GPU
coverage, or Wayland validation.

## Refreshed Windows validation (2026-11-15)

- `tools/test.ps1 -Odin C:\odin\odin.exe`: passed (343 runtime foundation
  tests, 194 native SDL_GPU frontend tests, 2 shared CPU renderer tests, 6
  scroll-capture tests, and the script's ABI, AccessKit, UIA,
  text-input/navigation, and host-ownership checks). Odin emitted the existing
  large-stack-local warnings for `Native_Secondary_Window`.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe`: passed;
  rebuilt the interactive and bounded-smoke native executables plus the
  standard `js_wasm32` artifact.
- The bounded native smoke exited successfully after asynchronous 63×64 RGBA8
  readback with padded 256-byte rows; all thirteen named pixel probes passed. A
  fresh local run selected Vulkan and reported a discrete NVIDIA GeForce RTX
  2080 SUPER adapter with description `595.97`, while the earlier Windows run
  selected D3D12. Both backend results are retained as separate observations
  rather than treating backend selection as fixed. The new
  `QueueOnSubmittedWorkDone` callback also reported `Success`; the smoke waits
  for both callbacks before teardown.
- The rebuilt browser WASM was loaded in the local WebGPU browser session. Its
  accessible live status reported all thirteen pixel probes passed and its
  queue callback reported `Success`. The fixture-local adapter-info override
  reported `fallback=false`, vendor `nvidia`, and architecture `turing`; device
  and description were redacted. Odin's `AdapterGetInfo` returned backend
  `WebGPU`, type `Unknown`, and those same available identifiers. This is
  browser runtime and adapter-metadata evidence; `fallback=false` is not a
  standalone proof of physical-GPU acceleration.
- Browser initialization now schedules one frame to observe startup, then
  sleeps without RAF polling until Odin's adapter/device callbacks wake the
  host. In the refreshed Windows browser session it used two initialization
  wake frames, completed the shared readback, and settled after 300 total RAF
  requests. It produced no additional requests for 500 ms; the resize action
  scheduled exactly one additional frame (301 total), followed by another
  successful 500 ms idle check. The shared `step()` now preserves dirty state
  across a surface reconfigure so an Outdated/Lost surface can request a bounded
  retry on browser as well as native.
- Hosted CI for Alicorn commit `2e30693` passed the
  [Windows foundation run](https://github.com/samanshaiza004/alicorn/actions/runs/43753628624),
  [macOS foundation run](https://github.com/samanshaiza004/alicorn/actions/runs/43753628648),
  [Windows/macOS native packaging run](https://github.com/samanshaiza004/alicorn/actions/runs/43753628606),
  and [icon asset reproducibility run](https://github.com/samanshaiza004/alicorn/actions/runs/43753628521).
  Windows foundation executed the shared fixture on D3D12 and the backend-neutral
  material benchmark. macOS arm64 verified the pinned wgpu-native archive,
  built the same fixture for native Metal and `js_wasm32`, and passed native
  Metal readback plus surface-resize smoke. This is hosted runner evidence, not
  a maintainer-run macOS session.
- A local static wgpu-native `v29.0.1.1` library built from the pinned source
  and checked-in callback patch passed early-destroy tests in both native
  callback modes, as well as a final-handle-release-before-poll test. The
  patched full fixture passed RGBA8 readback, delivered one `Destroyed`
  notification, and exited through teardown. See the
  [patch validation record](validation/webgpu-device-loss-callback-patch-windows-2026-11-15.md).
- The native callback probe now requires exactly one callback before teardown,
  rejects duplicates during cleanup, and exits nonzero after its 15-second
  deadline. On the patched Windows D3D12 library, process-events, spontaneous,
  release-before-poll, and post-readback variants passed. The unmodified Odin
  package (which selected Vulkan on this host) was a negative control and
  correctly failed with zero callbacks.
  The reproducible patched Metal build-and-run step passed in the
  [macOS foundation run for `cde2f08`](https://github.com/samanshaiza004/alicorn/actions/runs/43756274305).
  It compiled the pinned wgpu-native patch for Metal and passed the same four
  strict callback variants. This is hosted macOS arm64 runner evidence, not a
  maintainer-local Mac session.
- Odin's installed browser-side `AdapterGetInfo` bridge omits the
  `GPUAdapterInfo` argument when calling `genericGetAdapterInfo`. The fixture
  now works around this only in its page imports and captures the browser's
  fallback flag without modifying the installed SDK. The pinned/upstream JS
  binding defect remains. See the [toolchain audit](../dependencies/webgpu-toolchain.md#browser-adapter-metadata-bridge-2026-11-15).
- `git diff --check`: passed.

The bounded native fixture now has a 15-second end-to-end deadline for its
adapter/device/readback/queue-completion path. If an async callback is lost, it
prints the completion flags and exits nonzero instead of waiting indefinitely.
The rebuilt Windows readback smoke passed on Vulkan/NVIDIA RTX 2080 SUPER with
all thirteen pixel probes and `QueueOnSubmittedWorkDone` reporting `Success`.
The new resize smoke programmatically changed the SDL window to 800×450 during
the 1.8-second motion and 720×405 after it settled; both surface reconfigures
were observed, and `SurfacePresent` was submitted at both new sizes before
exit. It also passed readback and queue completion. This verifies WGPU surface
submission, not physical display scanout.

Phase 0 therefore has credible shared-renderer feasibility evidence, but its
cross-platform device-loss/lifecycle acceptance remains open. The patched
explicit-destroy callback is verified on Windows D3D12 and hosted macOS arm64
Metal. Do not treat those limited probes as evidence of driver/OS-initiated
device-loss recovery or a completed lifecycle gate for production renderer work.
