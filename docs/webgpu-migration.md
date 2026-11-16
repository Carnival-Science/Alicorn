# SDL_GPU to WebGPU migration

Status: Phase 0 remains open for lifecycle, baseline, and performance evidence;
Phase 2 has bounded solid-surface, text-sampling, icon, image, material,
custom-surface caching, and mixed compositor slices. SDL_GPU remains the only
complete application renderer and the visual reference.

## Architecture inventory

The current path is `application -> ui -> runtime retained state and ordered paint
stream -> native/sdl_gpu -> SDL_GPU`. The architecture document explicitly keeps
runtime identity, reconciliation, layout, text shaping products, paint order,
interaction, focus, semantics, and motion independent of the native renderer.

| Area | Existing ownership | Migration treatment |
| --- | --- | --- |
| GPU-independent, retain unchanged | `runtime/`, `ui/`, app callbacks, invalidation, paint command ordering, semantic model, focus/input policy, text editing, shaping, motion, themes/material descriptions | Preserve public behavior. Runtime must not import SDL3, WGPU, or browser packages. |
| CPU rendering products to reuse/extract | Paint commands and text runs; image payloads; generic `runtime/gpu_surface` samples and geometry; Runa shaping/rasterization and glyph atlas packing in `third_party/Runa`; CPU mesh, text and asset presentation helpers in `renderer/cpu` | Keep mesh, atlas and image products backend-neutral and reconstructible after device loss. |
| SDL_GPU-specific replacement | `native/sdl_gpu/{gpu_frame,solid,text,surface,images,icons,retained_effects,effects_compositor,vertex_buffers,render_capture}.odin`; GPU resources, shaders, upload policy, render passes, readback and retirement | Replace incrementally with `renderer/webgpu/` and shared WGSL. Do not alter geometry/shaping as incidental migration work. |
| Native host responsibilities to retain | SDL3 window/event lifecycle, DPI, text input/IME, clipboard, dialogs, drag/drop, titlebars/menus, AccessKit, primary and secondary window scheduling | Keep in SDL3 host modules. Replace only surface/device/presentation integration. |
| Browser host to add | Canvas sizing/DPR, WebGPU surface/device, pointer/wheel/keyboard/touch, browser focus/composition/clipboard, visibility, bounded scheduling, DOM/ARIA projection and capability errors | Add `host/web/` using Odin `js_wasm32` interop and narrow JS integration. No Emscripten or WebGL renderer. |
| Public API/downstream impact | `ui.run` and authoring APIs are public goals; examples and applications currently import `alicorn:native/sdl_gpu` | Preserve `ui.run` and UI/runtime contracts. Provide a temporary narrow import shim only if needed. Coordinate compile/import updates for examples, AliKit, Scratchpad and Punks at migration gates. No raw WGPU handles in widget APIs. |

The exact paint-stream order is a correctness contract. The renderer must not
sort primitives into batches that change stacking. GPU surface declarations
and custom-geometry tessellation are backend-neutral; device resources and
uploads remain renderer-specific.

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
  consumes Alicorn's production paint stream. Preserve its borrowed-paint-list,
  synchronous owner-thread consumption, host-owned target/encoder/submission,
  and GPU-resource lifetime rules in the WebGPU presenter.
- [#196](https://github.com/samanshaiza004/alicorn/issues/196) establishes a
  separate host-loop contract. Standalone and externally driven hosts share
  Runtime and renderer state across nonblocking steps; callbacks and Runtime
  mutation stay on the owner thread. Do not conflate loop ownership with #162's
  renderer/frame boundary.
- Open [#204](https://github.com/samanshaiza004/alicorn/issues/204) describes
  failure recovery after acquiring an SDL_GPU swapchain texture. It remains a
  risk for the temporary reference path while SDL_GPU is retained; it does not
  dictate the WebGPU frame transaction. Keep its host/renderer recovery
  requirements visible when comparing the reference implementation.

## Phase tracker

| Phase | Exit evidence | Status |
| --- | --- | --- |
| 0. Feasibility and baseline | Windows SDL_GPU reference captured; same Odin/WGPU code builds and runs native and browser; solid/clipped/blended/rounded/image/Runa text/waveform/settled-motion, partial texture and buffer uploads, uniform-buffer layout, padded async readback, and queue-completion callbacks demonstrated; binding/lifecycle limitations recorded | In progress: Windows D3D12 and hosted macOS arm64 Metal smoke/callback evidence pass; Linux x64 X11/lavapipe native smoke passes; `js_wasm32` builds and actual browser WebGPU offscreen/readback passes on an NVIDIA Turing adapter; physical Linux GPU/Wayland, genuine driver/OS loss and recovery, comparative baselines, and production parity remain open |
| 1. Separation | renderer/host package boundary with unchanged runtime and app API | In progress: shared UI authoring, CPU solid/custom-surface mesh assembly, and text/image/icon preparation are SDL-independent and compile for `js_wasm32`; native `ui.run` remains target-gated. GPU renderer/host extraction and browser `ui.run` remain outstanding |
| 2. Core parity | solid, clipping, text, image, icon, materials and custom surfaces pass native/browser tests | In progress: local Windows Vulkan and explicitly selected D3D12 fixtures exercise per-resource custom-surface caching, instance transforms, readback, and resize; prior browser WebGPU fixture passes custom-surface pixels and the current WASM build compiles, but this cache follow-up has not had a live browser replay. One shared compositor preserves interleaved paint order. Text, icon, image, and resource-local custom geometry reuse are asserted. Semantic gradients, relief, rectangles, segments, circles, masked markers, clipping, and waveform samples pass representative native pixel probes. Rounded/accessibility material parity, effects, and application host presentation remain outstanding |
| 3. GPU lifecycle | bounded asynchronous retirement, capture/readback, device loss/recreation and window teardown validated | Not started |
| 4. Desktop acceptance | full regression suite, pixel comparisons, performance and Scratchpad/Punks/AliKit dogfood | Not started |
| 5. SDL_GPU removal | delete production backend, legacy shader artifacts, switches and obsolete docs | Not started |
| 6. Browser host | interaction, accessibility, text/IME, lifecycle and demand-driven scheduling complete | Not started |
| 7. Release readiness | docs, reproducible setup, CI and substantive shared-renderer web example | Not started |

The Phase 0 evidence authorizes bounded, testable renderer slices; it does not
authorize a wholesale renderer replacement. SDL_GPU remains the complete
application renderer and the parity reference while individual WebGPU paths
are brought up.

## Protected renderer invariants

- **Retained products:** unchanged text/surface content must not reconstruct
  CPU geometry, upload glyph atlas data, or allocate GPU resources. Atlas dirty
  generations are acknowledged only after queue submission. Motion-only text
  translation must not rebuild its glyph mesh.
- **Host independence:** renderer packages accept a host-provided WebGPU
  device, queue, encoder/render pass, and target view. They do not create SDL
  windows, acquire browser canvases, or own platform event loops. A renderer
  instance is bound to one Runtime and is destroyed before it; a host may share
  its device across independent window runtimes.
- **Shared implementation:** native SDL3 and browser hosts use the same
  `renderer/cpu` products, `renderer/webgpu` policies, batching, clipping,
  caches, and WGSL. Platform code is limited to device/surface setup,
  callbacks, scheduling, and input/accessibility integration.
- **Renderer-local retained geometry:** do not add an application-facing raw
  GPU canvas callback for the waveform workload. Keep the existing retained
  geometry API and cache local meshes inside the backend renderer by Runtime,
  handle generation, payload revision, and tessellation extents. Keep placement,
  DPI scale, and opacity in per-instance data; apply clip through each paint
  command's scissor. Let static peaks and dynamic overlays invalidate
  independently; batch only compatible adjacent paint work without changing
  retained order. Bound active and retiring bytes together, retire replaced
  resources after their last-use submission completes, and rebuild GPU state
  from retained CPU geometry after device/compositor recreation.
- **Loss evidence:** a test that calls `DeviceDestroy` and receives
  `reason=Destroyed` verifies intentional-destruction callback delivery. It is
  not driver/OS-initiated device loss, and neither result proves resource
  recreation. Track those separately until real loss/recovery is tested.

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

### Shared text-quad assembly (Windows, 2026-11-15)

`renderer/cpu/text_mesh.odin` now converts an already-resolved Runa atlas slot
and Alicorn's shaped glyph/paint command into a backend-neutral six-vertex
quad. The helper owns physical-pixel snapping, exact clip rejection, UV
placement, bitmap bearings, monochrome tint, and color-glyph alpha policy. The
SDL_GPU text renderer now consumes this shared mesh product; glyph rasterization,
atlas residency, and GPU upload remain host/backend responsibilities. Focused
tests cover snapping carry, bearings, UVs, opacity, color glyphs, and translated
clipped text. This is preparation reuse, not yet a WebGPU text pass.

The full Windows `tools/test.ps1 -Odin C:\odin\odin.exe` suite passed after the
extraction, including runtime, SDL_GPU, CPU renderer, AccessKit ABI/UIA,
restoration, and native text-input/navigation/paint-span/ownership checks. The
Web UI package-boundary build also passed. Existing large-stack-local warnings
for native secondary-window tests remain unchanged.

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

## Phase 2 first solid-surface slice (Windows, 2026-11-15)

`renderer/webgpu/solid.odin` now consumes Alicorn's borrowed finalized
`Paint_Display_List_View`, resolves the existing shared CPU surface meshes,
preserves command order, and applies their resolved clips as device-pixel
scissors. It creates a WGSL solid pipeline, viewport uniform, and vertex buffer.
The caller owns the command encoder, target view, clear policy, queue submission,
and renderer lifetime; this module has no SDL dependency and the runtime remains
GPU-independent. Mixed display lists containing text, images, icons, geometry,
or effects are rejected before the pass is encoded.

The feasibility fixture builds a three-surface retained tree: an opaque root,
a translucent clipped parent, and an overlapping translucent child larger than
that parent. The GPU readback checks source-over output at the overlap and the
root color outside the clip on both axes. It encodes the unchanged display list
twice and asserts one CPU mesh rebuild plus one vertex and viewport upload
overall; the second encoding must reuse the retained mesh. The readback now
contains 16 checks total: the original 13 capability probes and these three
real-runtime-paint samples.

Local Windows validation for these changes, based on `9394537`:

- `C:\odin\odin.exe check renderer/webgpu -no-entry-point` and
  `C:\odin\odin.exe check examples/15_webgpu_feasibility -no-entry-point`:
  passed.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe`: passed;
  built both native smoke executables and the `js_wasm32` browser fixture.
- Native readback and resize smokes: passed on the NVIDIA GeForce RTX 2080
  SUPER with the installed Vulkan backend. All 16 probes passed; surface
  reconfiguration submitted at 800×450 during animation and 720×405 after
  settlement.
- A local browser WebGPU run passed the 16 readback probes before the final
  cache-reuse assertion was added. The final cache-enabled browser artifact
  rebuilt successfully; its live run has not yet been repeated.
- Runtime (352), CPU renderer (2), UI (39), TestUI (13), theme (37), native
  SDL_GPU (197), and scroll-capture (6) tests passed when run individually. The
  foundation executable also reported PASS.
- `tools/test.ps1 -Odin C:\odin\odin.exe` stops in the bundled AccessKit UIA
  check with `Accessible Button missing`, before reaching Alicorn's suite. The
  underlying SDL smoke passes and the affected check is outside this renderer
  change; the separately run Alicorn suites above passed.
- `tools/check_web_ui_package.ps1 -Odin C:\odin\odin.exe` passed after the
  WebGPU package was added to the `js_wasm32` import graph. Two runtime test
  files are now excluded from JS builds because Odin compiles test sources in
  imported packages and those tests use native-only facilities.

### Hosted validation for the solid-surface slice (`b6cb7e0`, 2026-11-15)

The exact implementation commit passed the [Windows foundation workflow](https://github.com/samanshaiza004/alicorn/actions/runs/43765193655),
[macOS foundation workflow](https://github.com/samanshaiza004/alicorn/actions/runs/43765193635),
[Linux WebGPU feasibility workflow](https://github.com/samanshaiza004/alicorn/actions/runs/43765193679),
[native packaging workflow](https://github.com/samanshaiza004/alicorn/actions/runs/43765193645),
and [icon asset reproducibility workflow](https://github.com/samanshaiza004/alicorn/actions/runs/43765193674).
The hosted macOS job also passed Metal readback and resize smoke, device-destroy
callback checks, retained-effects readback, example runner smoke, secondary-window
waker teardown under ThreadSanitizer, retained-work benchmarking, and bounded
material/relief geometry checks. Hosted Linux remains X11/lavapipe software
Vulkan evidence; the macOS run uses hosted Metal infrastructure and does not
replace local physical-device validation. CI built the browser target but did
not execute browser WebGPU after the final cache-reuse assertion was added.

This slice validates retained solid-surface rendering, blend order, clipping,
and reuse on Windows. It does not route application windows through WebGPU and
does not provide text, image, icon, material/effect, capture, resource-retirement,
device-recovery, secondary-window, or performance parity. The SDL_GPU
presenter remains the only full application path.

## Phase 2 shared text sampling slice (Windows and browser, 2026-11-15)

`renderer/webgpu/text.odin` consumes real retained `Text_Paint` commands from
one borrowed Runtime, resolves glyphs through Alicorn's Runa-backed text engine,
and reuses `renderer/cpu/text_mesh.odin` for physical glyph geometry. One WGSL
pipeline samples monochrome `R8Unorm` and color `RGBA8Unorm` atlas pages. The
host supplies the WebGPU device/queue and its render pass; `Text_Draw_Command`
can be called at each original command position so a future compositor can
preserve interleaved paint order. This is shared renderer code with no SDL or
browser imports.

The text renderer caches its glyph mesh by text paint, shaping/font generation,
clip, scale, and target size; command translation is kept in a separate GPU
buffer. Atlas pages are created lazily and upload only dirty regions after
initialization. `Text_Commit_Submission` acknowledges the exact Runa dirty
generation only after host submission. A renderer binds to one Runtime and
must be destroyed before that Runtime; separate window runtimes can share the
host device while keeping renderer caches independent.

The feasibility fixture now renders actual Alicorn-shaped text to a third
offscreen target. Windows native WebGPU smoke on an NVIDIA GeForce RTX 2080
SUPER / Vulkan adapter and the in-app browser WebGPU session on an NVIDIA
Turing adapter both passed the text pixel-presence check and existing
solid/blend/clip/readback probes. Browser shaping first exposed a vendored Runa
portability bug: process-lifetime Unicode tables hard-coded Odin's native heap
allocator, which traps on `js_wasm32`. Those tables now use Odin's
platform-default allocator, which is the WASM allocator on that target and the
same heap allocator on native builds.

On native, first prepare created one atlas page and uploaded its initial 1 MiB
page; an unchanged prepare added zero mesh rebuilds, vertex/atlas uploads,
atlas-page creates, or prepare-time buffer creates. Translation-only motion
added one translation-buffer upload and zero glyph mesh/atlas/resource work.
The same retained text cache checks and updated four-target pixel readback passed
in the browser. The later mixed surface/text composition is recorded below.
This proves browser runtime execution for the fixture, not images, icons,
effects, host presentation, full renderer parity, or device-loss recovery.

Validation on this Windows host:

- `C:\odin\odin.exe check renderer/webgpu -no-entry-point`: passed.
- `C:\odin\odin.exe test third_party/Runa`: 7 tests passed.
- `C:\odin\odin.exe test runtime`: 352 tests passed.
- `C:\odin\odin.exe test renderer/cpu`: 4 tests passed.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe`:
  native interactive, native smoke, native resize smoke, and `js_wasm32`
  artifacts built.
- Native offscreen/readback smoke passed on the RTX 2080 SUPER through Vulkan.
- A browser WebGPU run completed callback setup, retained solid/text cache
  assertions, async queue completion, and all RGBA8 readback assertions,
  including visible runtime text and the mixed surface/text compositor checks.

## Phase 2 shared surface/text compositor slice (Windows and browser, 2026-11-15)

`renderer/webgpu/compositor.odin` now owns one shared WebGPU composition path
for retained surface and shaped-text commands. It prepares the surface mesh
and Runa-backed text products before the pass, opens one caller-targeted render
pass, and dispatches every supported command in its original display-list
order. It does not acquire a native or browser surface, create the command
encoder, submit the queue, or import SDL/browser APIs. The host still owns
those operations and acknowledges atlas dirtiness only after submission.

`Solid_Prepare` and `Solid_Draw_Command` separate geometry upload from
pass-specific drawing. Surface draws retain their source command index, clip
scissor, and existing cached mesh. The text renderer draws at each exact
command index requested. The compositor rejects unsupported command families
before preparing anything, preventing a partial renderer path from appearing
to accept a complete display list.

At this stage, the feasibility fixture sent an interleaved four-command list
through this compositor in native and browser runs: an underlay, retained text,
an opaque surface over that text, then a second copy of the text offset below.
The asynchronous pixel readback verifies that the upper region is uniformly
the opaque surface color (so text was not reordered above it) and that the
later text copy remains visible. It also requires one surface mesh build and
upload and one text mesh build and upload, a glyph-atlas upload on first use,
and no additional surface/text mesh or atlas uploads on unchanged preparation.

Validation on this Windows host:

- `C:\odin\odin.exe check renderer/webgpu -no-entry-point` and
  `C:\odin\odin.exe check examples/15_webgpu_feasibility -no-entry-point`:
  passed.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe`:
  native interactive, bounded native smoke, resize smoke, and `js_wasm32`
  artifacts built.
- Native bounded readback passed on the NVIDIA GeForce RTX 2080 SUPER through
  Vulkan, including mixed surface/text paint ordering and cache reuse.
- The rebuilt browser fixture passed live WebGPU readback in the in-app browser
  on an NVIDIA Turing adapter, including the same mixed-command assertions.
- `C:\odin\odin.exe test runtime`: 352 passed;
  `C:\odin\odin.exe test renderer/cpu`: 4 passed.
- `git diff --check`: passed.

This was shared renderer integration evidence, not full parity. At this point
the compositor accepted only surface and text commands. The icon slice below
extends it; images, geometry, backdrop effects, application-window
presentation, lifecycle recovery, and performance parity remain open. This
local surface/text slice was not run on macOS or Linux.

## Phase 2 shared icon composition slice (Windows and browser, 2026-11-15)

`renderer/webgpu/icons.odin` now consumes Alicorn's existing CPU-generated
icon quads and compiled monochrome atlas. It uses a shared WGSL coverage-mask
shader, source-over blending, and lazily created `R8Unorm` atlas textures.
Each compositor retains icon vertices by the CPU helper's content fingerprint;
atlas pages upload only on first use. Clipping remains in the shared CPU quad
builder, so icon bounds, crop, and UV mapping are the same on native and
browser targets. Icons are dispatched at their original paint-command index
alongside surfaces and text. The renderer accepts the host's device and queue,
and borrows the target render pass; it does not acquire or submit platform
surfaces.

The shared feasibility compositor now renders seven ordered commands: surface
underlay, text, opaque surface overlay, vertically offset text, a one-pixel
scissor sentinel, and clipped Folder/Search icons at two atlas sizes. Its
asynchronous pixel checks require both tints to be visible, ensure no blue
Search icon pixels appear beyond the clip, and verify that the icon draw
restores the full-target scissor after a preceding renderer leaves a narrow
scissor active. The larger icon selects atlas page zero and the Search icon
selects page one, exercising bind-group switching within one render pass.
First preparation builds/uploads the icon mesh once and lazily uploads both
immutable atlas pages (1.5 MiB total); unchanged preparation reuses the mesh
without another vertex or atlas upload.

Validation on this Windows host:

- `odin check renderer/webgpu -no-entry-point` and
  `odin check examples/15_webgpu_feasibility -no-entry-point`: passed.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe`: built
  native interactive, bounded smoke, resize smoke, and `js_wasm32` artifacts.
- Native bounded readback passed on NVIDIA GeForce RTX 2080 SUPER through
  Vulkan. All sixteen checks passed, including both atlas pages, tint, clipping,
  and scissor restoration;
  `QueueOnSubmittedWorkDone` reported `Success`.
- The native resize smoke passed while changing the host window to 800×450
  during motion and 720×405 after settling. Both surface submissions and the
  shared icon/text readback checks passed.
- The rebuilt `js_wasm32` page passed the same sixteen checks in a live browser
  WebGPU session. It settled with no animation-frame requests during the
  fixture's 500 ms idle observation.
- `odin test runtime`: 352 passed; `odin test renderer/cpu`: 4 passed;
  `git diff --check`: passed.
- `tools/test.ps1 -Odin C:\odin\odin.exe`: the complete Windows regression,
  API-boundary, and host-contract script passed. Odin still reports the
  existing large-stack-local warnings for some `Native_Secondary_Window`
  test values.

This is the first actual WebGPU icon rendering evidence, but it is not a
complete icon parity or production-host claim. The local slice has not yet
been run on macOS or Linux, and images, material/effect parity, application
presentation, native/browser lifecycle recovery, and comparative performance
remain open. Device destruction callbacks remain distinct from genuine
driver/OS-initiated device loss and recovery.

## Renderer cache direction from Alicorn #164 (2026-11-15)

Alicorn [#164](https://github.com/samanshaiza004/alicorn/issues/164) closed
with a useful renderer finding: the existing retained geometry surface already
expresses the two-waveform Punks-style workload, preserves ordinary slider
input/accessibility, clips and retained blur, and keeps GPU ownership in the
host. No new public GPU canvas API is needed. The
[report at `6410ba3`](https://github.com/samanshaiza004/alicorn/blob/6410ba38cc51e8dfd929a36524838db185d679ab/docs/research/issue-164-gpu-canvas.md)
records exact output at 100%, 125%, 150%, and 200% scale, after resize and with
retained blur; hidden idle requested no frames or persistent allocations, and
in-flight resources were released after their fences completed.

On one Windows D3D12 fixture, the host-private cached-peak prototype reduced
CPU geometry encoding p95/p99 from 58.8/75.8 µs to 22.9/31.9 µs, per-frame
vertex uploads from 227,232 B to 5,184 B (about 44× less), and geometry passes
from four to two. It added 222,048 B of persistent GPU peak buffers.
Submit-to-fence samples were noisy across runs and report queue/driver wall
time, not GPU execution timestamps. The fixture reproduced Punks' composition;
it did not instrument the Punks application.

Carry this as a measured optimization direction, not a parity prerequisite.
The WebGPU renderer now has an initial per-resource cache slice, described
below, to validate independent invalidation and safe retirement. It has not yet
been benchmarked against the aggregate path or a Punks application workload;
the prototype's single-machine performance result does not predict WebGPU
latency. Preserve the same output, scale, idle, ordering, and memory checks
before claiming a performance benefit.

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

## Phase 2 image renderer slice (2026-11-15)

`renderer/webgpu/images.odin` now renders Runtime-owned images through the same
WGSL pipeline and `renderer/cpu.Image_Quad` geometry on native and browser
targets. It samples straight RGBA8 pixels, preserves source-over blending and
the retained command order, and clips image UVs with their geometry. The GPU
cache is keyed by `(Runtime identity, Image_Handle)` and bounded to 128 MiB;
the Runtime keeps authoritative CPU pixels so a new device can rebuild texture
resources. The renderer reports submission serials and holds evicted/released
textures until the host acknowledges completion of their last-use serial.

The shared mixed-paint fixture now interleaves surface, shaped text, two atlas
icons, and two Runtime images. It verifies opaque red pixels, blue alpha over
red, blue over the root surface, and that clipped image pixels do not escape
their clip. Repeating unchanged preparation causes no image mesh or texture
upload. Moving an image updates its retained vertex mesh without re-uploading
its pixels. Releasing the blue image after submission leaves 128 bytes resident
and one texture retired until queue completion serial 1; after completion the
retirement list is empty, resident bytes fall to 64, and one resource is
released.

Validation on the final slice:

- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` passed,
  building the native interactive/smoke/resize executables and `js_wasm32`.
- Native bounded readback passed on the local Vulkan backend with an NVIDIA
  GeForce RTX 2080 SUPER. All prior probes and the four image-specific pixel
  probes passed. Queue completion reported `Success`; the resource retirement
  assertion observed serial 1 and 64 bytes remaining.
- Native resize smoke passed on Vulkan while resizing during animation to
  800×450 and after settlement to 720×405; both new surface sizes were
  presented, image readback passed, and queue retirement completed.
- The rebuilt WASM ran in the browser's WebGPU implementation. Its live status
  reported the same four image pixel checks and resource-retirement assertion
  passing, with queue completion `Success`.
- `git diff --check` passed.

This is fixture-level native/browser renderer evidence. It is not yet Windows
D3D12 or macOS Metal image parity, a production SDL/browser presenter, or a
device-loss/recreation test. The production hosts do not yet call
`Compositor_Complete_Submission` from their queue-work-done callbacks. Until
that host bridge exists, the cache's in-flight retirement mechanism is proven
only by the feasibility fixture; Phase 2 and Phase 3 remain open.

## Phase 2 shared material geometry checks (2026-11-15)

The feasibility runtime now emits three semantic surfaces into the same mixed
paint list as text, icons, and images: a horizontal theme-resolved gradient,
an elevated analytic-relief rectangle, and its recessed counterpart. The
WebGPU solid path uses `renderer/cpu`'s existing material tessellator and
vertex-color shader; the migration adds no material-specific GPU API or
duplicate geometry implementation.

The local Windows Vulkan readback and rebuilt browser WebGPU fixture both
passed the six material pixel probes: two gradient endpoints, raised and
recessed face colors, and their top bevel colors.

Those expected colors distinguish the gradient direction and confirm the
relief sign changes the edge tint while leaving the face color unchanged. These
checks validate representative rectangular materials and semantic gradient
resolution. Rounded material parity, full theme/accessibility combinations,
reference pixel comparison against SDL_GPU and retained material mesh
invalidation remain to be measured before claiming material parity.

## Phase 2 shared custom-surface rendering (2026-11-15)

`renderer/cpu/gpu_surface.odin` owns the shared tessellation for Alicorn's
existing `Geometry_Paint` payloads and waveform samples. The native path bakes
physical scale into vertices; WebGPU keeps those vertices local and applies
placement and scale through instances. Both
`native/sdl_gpu/surface.odin` and `renderer/webgpu/surfaces.odin` consume that
same builder. Rectangles, thick segments, 16-triangle circles, and six-vertex
masked point markers preserve payload ordering, clipping bounds, command
translation, scale, opacity, and the established cyan waveform treatment. The
WebGPU compositor dispatches those commands at their original paint-list
indices, alongside solid surfaces, text, icons, and images. No public drawing
API was added.

The initial WebGPU slice cached its prepared custom-surface mesh against the
display revision, scale/size, command placement, and resource revisions. That
aggregate cache has now been replaced by resource-local GPU geometry buffers
and a separate instance stream; the follow-up evidence is recorded below.

The feasibility mixed-compositor readback now checks explicit rectangle,
segment, circle, point-marker, marker clipping, and waveform pixels. The native
SDL_GPU reference path and browser WebGPU path use the same
`renderer/cpu` geometry; WebGPU executes it through the new WGSL renderer. The
fixture uses synthetic command placement for deterministic readback and does
not replace downstream Punks app validation.

Validation on this slice:

- `C:\odin\odin.exe test renderer/cpu` passed all 7 tests, including the new
  shared geometry, waveform, and marker-mask regressions.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` passed,
  building the native interactive/readback/resize programs and `js_wasm32`.
- The native readback smoke passed on Windows Vulkan / NVIDIA GeForce RTX 2080
  SUPER. All six custom-surface pixel checks, existing renderer probes, image
  retirement, and queue completion passed.
- The native resize smoke passed the same checks and presented at 800×450
  during motion and 720×405 after settlement.
- The rebuilt fixture ran in the browser WebGPU implementation. Its live
  accessibility status reported all custom-surface checks, existing material
  probes, image retirement, and queue completion passing.
- `git diff --check` passed after the implementation and documentation updates.

This initial shared-geometry slice established fixture parity on local Windows
Vulkan and the tested browser adapter; it did not validate custom-surface
rendering on D3D12 or macOS Metal. The per-resource cache follow-up below adds
Windows D3D12 evidence. Neither slice provides an SDL_GPU pixel-differential
comparison, Punks app instrumentation, production host presentation,
cache-performance benchmark, or genuine driver/OS device-loss and recovery
evidence. Intentional device destruction remains a separate probe and must not
be counted as genuine device loss.

## Phase 2 renderer-local custom geometry cache (2026-11-15)

The WebGPU custom-surface renderer now stores a GPU vertex buffer per Runtime,
`Geometry_Handle` generation, and tessellation extent. Payload revision updates
that retained local mesh. Translation, origin, DPI scale, and opacity travel in
a separate instanced vertex stream; clip remains a per-command scissor. This
keeps geometry reuse independent from presentation changes while retaining the
existing CPU tessellator and the original paint-command order. No new public
canvas API or platform-specific rendering path was introduced.

The cache accounts for active geometry, the instance buffer, and fence-retired
buffers against a 64 MiB logical GPU-buffer budget. It evicts least-recently
used resources only when they are absent from the prepared frame and their last
submission has completed. Buffer growth retains the old allocation until its
shared compositor queue serial completes. Recreating the compositor starts
with an empty GPU cache and rebuilds meshes from Runtime-owned CPU payloads.
This establishes reconstructibility by design; driver-loss recovery is not
validated by this fixture.

The feasibility fixture now verifies that repeated preparation reuses two
independent geometry resources; changing translation and opacity uploads only
instance data and changes readback pixels at the moved location; and growing a
waveform payload rebuilds/uploads only that resource while preserving the
static mesh. Its old buffer remains resident until serial 2 completes, and an
invalid future completion serial releases nothing. Existing rectangle,
segment, circle, masked-marker, waveform, clipping, material, text, icon, image,
and paint-order pixels continue to pass.

Validation on the local Windows candidate:

- `C:\odin\odin.exe check renderer/webgpu -no-entry-point` and the same check
  for `examples/15_webgpu_feasibility` passed.
- `C:\odin\odin.exe test renderer/cpu` passed all 8 tests. The full
  `tools/test.ps1 -Odin C:\odin\odin.exe` regression, host, and recovery suite
  also passed (352 Runtime tests; existing large-stack-local warnings remain).
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` built
  native interactive/readback/resize executables and `js_wasm32`.
- Native readback and resize smokes passed on Windows Vulkan / NVIDIA GeForce
  RTX 2080 SUPER. The motion readback measured the moved half-opacity pixel as
  `[137,28,30,255]`; both resize presentations passed.
- After adding explicit backend selection to the fixture, readback and resize
  smokes also passed with `--backend=d3d12`; the adapter reported D3D12 on the
  NVIDIA GeForce RTX 2080 SUPER. Both runs verified the per-resource cache,
  moved geometry pixels, queue-serial retirement, and surface presentations.
- The live browser window capture helper timed out twice after refreshing its
  window selection. The current WASM candidate builds, but this cache slice has
  no live browser replay result recorded.
- `git diff --check` passed.

This is cache-correctness and native pixel evidence, not a WebGPU performance
claim. macOS Metal cache readback/resize, live browser replay for this candidate,
cache-pressure stress, Punks instrumentation, and genuine driver/OS loss and
recovery remain open. Intentional `DeviceDestroy` and a driver-initiated lost
device are separate evidence categories.
