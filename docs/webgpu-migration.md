# SDL_GPU to WebGPU migration

Status: Phase 0 remains open for lifecycle, baseline, and performance evidence;
Phase 1 now includes a host-owned WebGPU presenter boundary exercised against
the shared compositor; Phase 2 has bounded solid-surface, text-sampling, icon,
image, material, custom-surface caching, and mixed compositor slices. SDL_GPU
remains the only complete application renderer and the visual reference.

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
| 0. Feasibility and baseline | Windows SDL_GPU reference captured; same Odin/WGPU code builds and runs native and browser; solid/clipped/blended/rounded/image/Runa text/waveform/settled-motion, partial texture and buffer uploads, uniform-buffer layout, padded async readback, and queue-completion callbacks demonstrated; binding/lifecycle limitations recorded | In progress: the pre-change Windows SDL_GPU reference and a supplemental D3D12 effects profile are recorded in `docs/validation/sdl-gpu-reference-windows-2026-11-15.md`; Windows D3D12 and hosted macOS arm64 Metal smoke/callback evidence pass; Linux x64 X11/lavapipe native smoke passes; `js_wasm32` builds and actual browser WebGPU offscreen/readback passes, but the browser adapter acceleration class is not surfaced. Physical Linux GPU/Wayland, genuine driver/OS loss and recovery, same-workload production comparison, and application-level stage/working-set measurements remain open |
| 1. Separation | renderer/host package boundary with unchanged runtime and app API | In progress: shared UI authoring and CPU preparation are SDL-independent; `renderer/webgpu/presenter.odin` now consumes a borrowed finalized display list and encodes into caller-owned WebGPU frame objects, with queue submission and async completion owned by the host. Its fixture parity passes on Windows D3D12 and the package builds for `js_wasm32`. Production SDL3/window and browser host integration, native `ui.run` target selection, and full downstream app import migration remain outstanding |
| 2. Core parity | solid, clipping, text, image, icon, materials and custom surfaces pass native/browser tests | In progress: local Windows Vulkan and D3D12 fixtures exercise per-resource custom-surface caching, budget pressure, in-flight protection, instance transforms, readback, and resize. One shared compositor preserves interleaved paint order; text, icon, image, and resource-local custom geometry reuse are asserted. Semantic gradients, relief, clipping, waveform samples, and cropped mixed-renderer readback pass Windows D3D12 and the current browser WebGPU readback. Shared CPU backdrop planning/meshes feed renderer-owned WebGPU prefix capture, filtering, and in-order composition for up to four markers within one aggregate 48 MiB tracked mesh+texture allocation budget. Two overlapping markers pass pixel readback on Windows D3D12/Vulkan and browser WebGPU; the later marker's capture includes the earlier marker's composed result. D3D12 also verifies unchanged-prefix reuse, changed-prefix invalidation, resized-target retirement behind the prior queue serial, and exact ordinary-paint parity when a valid effect exceeds budget. Six shared WGSL sources are compile-time loaded for native and `js_wasm32` builds. A Windows-only fixture slice verifies one per-corner rounded relief surface under increased contrast and reduced transparency on D3D12/Vulkan; its WASM build passes, but those new material pixels have not yet been replayed in a browser. Full theme/accessibility combinations, application host presentation, and broader cross-platform GPU validation remain open |
| 3. GPU lifecycle | bounded asynchronous retirement, capture/readback, device loss/recreation and window teardown validated | In progress: image, custom-geometry, and backdrop resources have bounded asynchronous retirement and completion-driven release tests; async readback is exercised. Same-device compositor teardown/rebuild now reproduces every RGBA pixel on Windows D3D12 and Vulkan from retained Runtime products. Genuine driver/OS device loss and device recovery, plus primary/secondary window teardown/recreation, remain unvalidated. Intentional `DeviceDestroy` callbacks are tracked separately and do not count as driver-loss evidence |
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
  device, queue, encoder/render pass, and target view. Native SDL3 hosting must
  support both Alicorn-created windows and externally managed surfaces. The
  presenter path preserves #162's borrowed paint-list, owner-thread synchronous
  consumption, and caller-owned target/encoder/submission; it must not silently
  take surface or queue ownership. Loop ownership follows #196 independently:
  callbacks and Runtime mutation stay on the owner thread. A renderer instance
  is bound to one Runtime and is destroyed before it; a host may share its
  device across independent window runtimes.
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

### Shared backdrop-effect planning (Windows, 2026-11-15)

The bounded backdrop-blur request validation, physical-pixel capture bounds,
ancestor output clipping, Gaussian kernel generation, and bilinear tap pairing
now live in `renderer/cpu/effects.odin`. The SDL_GPU adapter calls this shared
policy and retains ownership of SDL texture formats, byte-budget accounting,
resource caching, GPU passes, and submission/fence lifetime. This is a CPU
planning extraction only: it does not implement or validate WebGPU effect
capture, filtering, or composition.

CPU regressions verify fractional-DPI halo rounding, clipping, Gaussian
normalization and tap reconstruction, tiny-sigma underflow, bounds, and forged
plan rejection. The complete Windows
`tools/test.ps1 -Odin C:\odin\odin.exe` run passed after the extraction,
including CPU renderer and SDL_GPU integration tests. Its existing large-stack-
local warnings in secondary-window tests remain. These tests validate the
temporary SDL_GPU reference path and shared policy; WebGPU effect parity remains
open.

### Shared backdrop-prefix policy (Windows and `js_wasm32`, 2026-11-15)

Prefix boundary discovery, content-generation hashing, and offscreen-local
paint-list construction now live in `renderer/cpu/effects_prefix.odin`. The
hash covers the captured paint prefix and resolved geometry payload revision;
paint after the effect marker does not invalidate the cached backdrop. Local
capture copies shift command bounds and clips without mutating the source paint
list or changing its translation semantics. The SDL_GPU compositor delegates
to these helpers; its capture, filter, cache resources and submission/fence
handling remain native.

CPU regressions cover first-marker selection, before/after cache invalidation,
and localization without source mutation. The full Windows
`tools/test.ps1 -Odin C:\odin\odin.exe` suite passed, the `js_wasm32` UI/renderer
package-boundary build passed, and the D3D12 effects validation repeated all
nine pixel cases with maximum error 1 RGBA8 level. Its retained custom-geometry
probe still refreshes on payload revision change, and 100 unchanged attempts
add zero passes, allocations or submissions. This enables shared future
WebGPU invalidation policy; GPU capture and filtering are not ported yet.

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

An opt-in explicit-destruction experiment (`FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true`) delivered
the `Destroyed` device-loss callback in browser WebGPU after the readback
passed. Its executable assertion now requires the exact `Destroyed` reason and
labels the result as an explicit-destroy callback pass. Destruction is deferred
until the host loop regains control, so it does not occur reentrantly inside
the map callback. On Windows wgpu-native/D3D12,
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
before claiming a performance benefit. Across Alicorn consumers, the contract
remains ordinary retained geometry declarations; any reuse or upload
optimization belongs in the renderer and must remain bounded, revision-aware,
and reconstructible after device loss.

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

## Phase 1 host-owned WebGPU presenter boundary (Windows, 2026-11-15)

`renderer/webgpu/presenter.odin` provides a host-facing frame boundary around
the shared WebGPU compositor. One presenter is bound to a borrowed Runtime,
device, and queue. It consumes a finalized `Paint_Display_List_View`
synchronously and encodes into a caller-owned command encoder and target view;
the host still owns surface acquisition, command submission, callback/event
processing, and frame scheduling. The renderer does not import SDL3 or browser
APIs. Submission tokens report display revision and serial, and asynchronous
queue-completion callbacks release retired renderer resources. Outstanding
frames are bounded (default three, maximum eight); encoding returns explicit
backpressure instead of waiting on the GPU. A failed encode requires the host
to discard its command encoder. The Runtime and WebGPU device must outlive the
presenter, and destruction refuses while frames are in flight.

The opt-in fixture feeds the exact same 15-command mixed paint list through the
direct compositor and the host-owned presenter into separate offscreen targets
in one host-created command encoder. Windows D3D12 and Vulkan readback each
compared every RGBA pixel at 63×64 and found exact parity. Both queue callbacks
completed serial 1 with zero frames in flight, after which presenter destruction
succeeded. Both local runs used Odin at `C:\odin\odin.exe` and an NVIDIA
GeForce RTX 2080 SUPER; requested and reported backends agreed in each run.
`examples/15_webgpu_feasibility/build.ps1` also built the
interactive, readback, compositor-recreation, resize, presenter-smoke, and
`js_wasm32` fixture targets. `odin check renderer/webgpu -no-entry-point` and
all three `odin test renderer/webgpu` tests passed.

Run the native boundary probe with:

~~~powershell
.\build.ps1 -Odin C:\odin\odin.exe
.\out\webgpu_feasibility_presenter_smoke.exe --backend=d3d12
~~~

This proves the host-owned frame contract around the feasibility compositor,
not a production SDL3 window presenter, externally managed native surface,
browser canvas presenter, or real device-loss recovery. No adapter, SDL, or
browser responsibilities have moved into the renderer. Phase 1 and Phase 6
remain open.

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
Punks instrumentation, and genuine driver/OS loss and recovery remain open.
Intentional `DeviceDestroy` and a driver-initiated lost device are separate
evidence categories.

## Phase 2 cache-pressure and fence-protection follow-up (Windows, 2026-11-15)

The bounded native feasibility smoke now fills the retained waveform payload
to its supported maximum and prepares two sets of 120 distinct tessellation
extents. Each set requests about 33.75 MiB of vertex buffers, so the combined
working set exceeds the renderer's 64 MiB custom-geometry cache budget. The
fixture clips each draw to one pixel to keep raster work small while still
encoding every cached mesh in paint order.

The first set is submitted at compositor serial 3. Before that work completes,
the fixture attempts to prepare the second set. Preparation fails with
`Resource_Failure` while remaining under budget; all 120 in-flight first-set
buffers remain present with last-use serial 3, and the eviction count does not
change. Once serial 3 completes, the second set prepares and submits at serial
4. Completion confirms all 120 second-set resources remain resident, total
active/resident geometry bytes stay below 64 MiB, no retired buffers remain,
and LRU evicts the oldest first-set entries while retaining its newest entry.

Validation on Windows with Odin `dev-2026-11-nightly:08539cd`, NVIDIA GeForce
RTX 2080 SUPER:

- D3D12 readback smoke passed. In-flight protection observed 120 submitted
  resources, 107 partial second-set resources, zero evictions, and
  66,957,312 resident bytes against a 67,108,864-byte budget. After completion,
  the second set completed at serial 4 with 120 resources, 66,948,096 resident
  bytes, 15 LRU evictions, the oldest first-set entry evicted, the newest
  retained, and zero retired buffers.
- D3D12 resize smoke passed the same pressure checks and presented at 800×450
  during motion and 720×405 after settlement.
- Vulkan readback smoke passed the same pressure and cache-bound checks.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` rebuilt
  native interactive/readback/resize executables and the `js_wasm32` fixture.
  `odin check examples/15_webgpu_feasibility` passed.

This closes the direct cache-budget and in-flight LRU stress gap for the local
Windows D3D12/Vulkan fixture. It does not establish browser or macOS cache
pressure behavior, Punks application instrumentation, or driver-initiated
device-loss recovery. The compositor remains host-independent: the host owns
surface acquisition, encoding/submission, and completion delivery; the shared
renderer owns cache policy and retires resources by the host-reported queue
serial. Intentional device destruction remains distinct from genuine
driver/OS-initiated loss.

## Phase 2 shared backdrop effect mesh (Windows, 2026-11-15)

The bilinear-paired Gaussian filter quads and final backdrop composite quad now
come from `renderer/cpu/effects_mesh.odin`. The shared mesh preserves the
existing tap ordering and weights, horizontal and vertical UV offsets,
out-of-range sampling halo for clamp-to-edge samplers, and physically snapped
composite origin. SDL_GPU consumes this CPU product; WebGPU can use the same
vertices when effect capture and filtering are implemented. GPU textures,
samplers, passes, uploads, cache slots, and retirement remain backend-owned.

The fixed mesh capacity is derived from the maximum supported tap count. Tests
cover ordinary and maximum kernels, vertex ordering and attributes, the
composite location, and rejecting a forged plan before modifying output memory.
The SDL effect plan is explicitly adapted to the shared CPU plan, keeping its
backend-specific texture-byte charge separate from shared geometry policy. A
test helper also stopped attempting to free a temporary-allocator slice.

Validation on the Windows D3D12 candidate with Odin `dev-2026-11-nightly:08539cd`:

- `odin test renderer/cpu` passed all 18 CPU-renderer tests.
- `tools/check_web_ui_package.ps1 -Odin C:\odin\odin.exe` passed, compiling
  the backend-neutral CPU package for the `js_wasm32` consumer.
- `tools/test.ps1 -Odin C:\odin\odin.exe` passed the full regression suite,
  including 352 Runtime tests and 197 native SDL_GPU tests. Existing warnings
  about large stack locals in native secondary-window tests remain.
- `tools/validate_effects.ps1 -Odin C:\odin\odin.exe -Driver direct3d12`
  passed all nine Gaussian scale/sigma readbacks with maximum RGBA8 error 1,
  painter order intact, cache/fresh output equal, and payload-revision
  invalidation checks passing. One hundred unchanged attempts produced no new
  passes, allocations, or submissions; effect resources retired to zero live
  bytes.
- `git diff --check` passed.

This validates a shared CPU mesh and unchanged Windows reference pixels. It
does not implement WebGPU backdrop capture, filtering, or composition, and it
does not require a host-owned presentation target to be sampleable or
copyable. External targets remain borrowed render attachments; the future
effect path must capture the paint prefix into renderer-owned sampleable
textures. WebGPU effect parity, macOS/Linux GPU validation, host presentation
integration, and genuine driver/OS device-loss recovery remain open.
Intentional device destruction remains separate evidence.

## Phase 2 cropped capture viewport encoding (Windows D3D12, 2026-11-15)

`Compositor_Encode` can now draw a range of an already prepared full-display
paint list into a caller-supplied cropped render target. The meshes and command
coordinates remain in full-display physical pixels; an aligned dynamic view
uniform supplies the crop extent and origin, and the shared WGSL subtracts the
origin while mapping into the target. Solid, text, custom-surface scissors are
translated and clipped to the crop; icons and images use the target's local
viewport bounds. The prepared meshes and main viewport are not rebuilt or
overwritten. Up to 63 public capture slots are available per submitted
compositor frame; the final dynamic-uniform slot is private to backdrop halo
capture. A slot cannot be reused until the host commits that submission, so
later queue writes cannot change an earlier capture's origin.

The fixture renders its 63×64 mixed paint list as a full frame and as two 45×36
crops, at physical origins (18, 28) and (0, 0), in the same command encoder.
The capture texture is reused, with a copy between passes, and each crop uses a
different dynamic uniform slot. It compares every RGBA8 pixel against the
corresponding full-frame region. This covers the shared surface, text, icon,
image, semantic material, and custom-geometry pipelines, including clip
translation, paint ordering, and independent queued crop origins.

Validation on Windows with Odin `dev-2026-11-nightly:08539cd`, NVIDIA GeForce
RTX 2080 SUPER, D3D12:

- `odin check renderer/webgpu -no-entry-point` and
  `odin check examples/15_webgpu_feasibility` passed.
- `odin test renderer/cpu` passed 19 tests; `odin test renderer/webgpu` passed
  its capture-slot uniqueness test.
- `tools/test.ps1 -Odin C:\odin\odin.exe` passed the full regression suite,
  including 352 Runtime tests, 197 native SDL_GPU tests, AccessKit contract,
  UIA, and foundation checks. Existing large-stack warnings for
  `Native_Secondary_Window` test locals remain.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` built the
  native fixture and `js_wasm32` browser fixture.
- `webgpu_feasibility_smoke.exe --backend=d3d12` passed all existing readbacks
  and reported `crop_capture_a=true crop_capture_b=true`, comparing every
  pixel exactly.
- The later live browser fixture replay reported both crop comparisons true.
  Earlier attempts using the Windows browser-capture helper timed out; that
  limitation has since been superseded by this browser runtime evidence.

This crop path is now also used internally by the backdrop effect renderer.
The caller still owns the presentation target, encoder, submission, and
completion flow; the renderer neither inspects nor samples a host presentation
surface. The following section records the first WebGPU effect slice.

## Phase 2 shared WebGPU backdrop effect slice (Windows D3D12, 2026-11-15)

The shared compositor now accepts one backdrop-effect marker and interprets it
as a paint boundary. It encodes the preceding retained paint commands into a
bounded, renderer-owned sampleable crop, runs horizontal and vertical Gaussian
filter passes using the shared `renderer/cpu` mesh and bilinear-paired taps,
then composites through the same prepared mesh at the marker's original paint
position. The host continues to own its target view, encoder, queue submission,
and completion callback. The renderer does not require a sampleable host
surface. If the effect is unsupported or its bounded texture budget is
exceeded, the marker is skipped and ordinary paint remains available.

Effect GPU objects and pipeline creation are lazy: a compositor with no active
effect marker does not initialize the backdrop renderer. The initial slice
supported one effect output per compositor; the multi-marker follow-up below
extends the cache to four bounded entries under one aggregate 48 MiB tracked
mesh+texture allocation budget. Each entry keys cached pixels from its shared
paint-prefix identity and effect plan, skips capture/filter work on an unchanged prefix, and retires
resized texture sets only after the host-reported completion serial.
This follows Alicorn #164: applications continue to express retained geometry
through existing APIs; optimization stays renderer-local rather than adding a
public GPU canvas API.

Validation on Windows D3D12 with an NVIDIA GeForce RTX 2080 SUPER and Odin
`dev-2026-09-nightly:a2fb372`; a separate browser runtime/readback replay used
the `js_wasm32` artifact:

- `odin check renderer/webgpu -no-entry-point` and
  `odin check examples/15_webgpu_feasibility` passed after lazy initialization.
- `examples/15_webgpu_feasibility/build.ps1` rebuilt native interactive,
  readback, and resize fixtures plus the `js_wasm32` WASM fixture.
- `webgpu_feasibility_smoke.exe --backend=d3d12` passed. Across three ordered
  effect submissions it reported three captures, three horizontal and three
  vertical filter passes, four composites, one unchanged-prefix cache hit, and
  two shared mesh builds. The 40×40 active set plus its retained mesh used
  74,120 bytes; total residency was 100,040 bytes while the retired set was
  still in flight, both below the 50,331,648-byte budget. Pixel checks passed for the
  initial red/blue and changed red/green blur, the resized effect, and pixels
  beyond the effect clip.
- While the 36×36 set remained in flight at serial 3, resize prepared a 40×40
  set and kept the old 25,920-byte texture set retired. Completion at serial 6
  released it, leaving exactly 74,120 active bytes and no retired sets.
- A valid 1,612×1,612 effect plan requested 52,013,000 bytes including the
  retained mesh, above budget. The renderer skipped its effect marker without
  changing residency; every RGBA pixel matched the same paint list with that
  marker removed.
- Existing text, image, icon, material, custom geometry, crop, retained cache,
  cache-pressure, and queue-retirement checks in the same smoke also passed.
- The local browser replay reached the idle-settled state and reported the
  offscreen readback PASS, including both crop comparisons and backdrop
  mixed-color, clip, cache-hit, prefix-invalidation, resize pixel, and exact
  over-budget fallback parity probes. Its exposed
  status did not identify whether the adapter was hardware or software-backed;
  this is correctness evidence, not GPU-performance evidence.

This is the first GPU effect execution slice, not complete effect parity. The
SDR output-format constraints, genuine device-loss/recreation,
application-host integration, and broader macOS/Linux GPU validation remain
open.
Explicit device destruction is still distinct from genuine driver/OS-initiated
device loss and recovery.

### Phase 2 bounded multiple backdrop markers (Windows and browser, 2026-11-15)

The shared compositor now keeps up to four effect entries per Runtime and
composes each marker in retained paint order. When a later marker needs a new
prefix capture, the recursive prefix pass composes all earlier ready markers
into that capture before filtering it. A single aggregate 48 MiB tracked
mesh+texture allocation budget includes every entry's vertex and texture
allocations. Markers that do not fit remain a direct-paint fallback; the compositor does not discard
ordinary paint or grow the cache without bound. Earlier effect parameters are
included in later prefix hashes, so changing an earlier blur invalidates later
cached output.

The feasibility fixture renders two overlapping effects and compares the
second effect's clipped pixels against the same paint list with the first
marker removed. A difference inside the later clip proves that the second
capture observed the first effect's composition, rather than independently
capturing the original source prefix. A CPU regression verifies that changing
an earlier marker's sigma invalidates a later marker's prefix generation.

Validation on Windows x64 with Odin
`dev-2026-09-nightly:a2fb372`, NVIDIA GeForce RTX 2080 SUPER:

- `odin check renderer/webgpu -no-entry-point` and the feasibility native and
  `js_wasm32` builds passed.
- The complete Windows `tools/test.ps1` run passed, including 352 Runtime
  tests, 197 SDL_GPU integration tests, AccessKit ABI/UIA, foundation,
  restoration, and native host-contract checks. The focused CPU renderer suite
  passed all 20 tests.
- The full async readback smoke passed with both Windows D3D12 and Vulkan
  backends. The later marker produced 288 pixels different inside its clip
  when the earlier marker was present. Budget fallback still matched ordinary
  paint at every RGBA pixel.
- A live browser WebGPU replay passed the same two-marker pixel assertion and
  reached settled idle with no additional animation-frame requests for
  500 ms. Its adapter acceleration class was not surfaced, so this is
  correctness evidence only.

The new path is still fixture-level renderer coverage, not production
application presentation. It does not establish SDR parity for all output
formats, genuine device loss/recreation, secondary-window lifecycle, or
production performance. Intentional `DeviceDestroy` callbacks remain separate
from driver/OS-initiated loss evidence.

### Phase 2 rounded accessibility-material fixture (Windows, 2026-11-15)

The shared feasibility scene now includes a per-corner rounded raised surface
whose registered material starts with a narrow, low-strength bevel and a
translucent outer shadow. Its style environment enables increased contrast and
reduced transparency. The fixture asserts that material resolution widens and
strengthens the bevel and removes the outer shadow, then checks actual GPU
readback for the face, bevel band, rounded corner, and unsullied underlay where
the shadow would have appeared. The existing paint-order probe excludes the
single row occupied by the rounded fill's documented 0.75-pixel antialias
fringe; it still checks uniform overlay across the fully covered rows.

Validation with Odin `dev-2026-09-nightly:a2fb372` on Windows x64 and an NVIDIA
GeForce RTX 2080 SUPER:

- `odin check renderer/webgpu -no-entry-point` passed, and
  `odin test renderer/cpu` passed all 20 tests.
- `examples/15_webgpu_feasibility/build.ps1` built the native interactive,
  readback, and resize programs and the `js_wasm32` artifact.
- The complete asynchronous fixture readback passed on Windows D3D12 and
  Vulkan, including the new material variant, bevel, corner, and reduced-
  transparency checks plus all existing readback and resource-lifecycle
  assertions.
- A live browser capture was attempted, but the Windows UI capture helper
  timed out twice. The WASM compilation passed; the new material pixel checks
  therefore still need a browser replay.

This is a focused geometry/accessibility fixture, not full material parity.
It does not cover the theme/accessibility matrix, production host presentation,
other GPU vendors, or cross-platform pixel variance.

### Phase 2 compile-time WGSL inventory (Windows, 2026-11-15)

The six renderer shaders now live as readable `.wgsl` files in
`renderer/webgpu/shaders/`. Odin `#load(..., string)` embeds them at compile
time, leaving the same shader bytes in native and `js_wasm32` builds without
runtime file access. The inventory documents each pipeline's vertex/resource
contract. Extraction was checked against the previous Odin raw strings; all
six WGSL bodies were byte-for-byte identical.

Validation on Windows x64 with Odin `dev-2026-09-nightly:a2fb372` and an NVIDIA
GeForce RTX 2080 SUPER:

- `examples/15_webgpu_feasibility/build.ps1` rebuilt the native interactive,
  readback, and resize programs and the `js_wasm32` artifact with compile-time
  shader loading.
- The complete readback smoke passed on D3D12 and Vulkan, including solid,
  text, icons, images, custom surfaces, backdrop effects, and the accessibility
  material checks. This verifies native shader module creation and unchanged
  raster output for the extracted shader bodies.
- The browser artifact compiled, but a live browser replay was not repeated in
  this slice; the new material pixels still need browser runtime evidence.

The old SDL_GPU shader artifacts remain until Phase 5. This extraction changes
source organization only; it does not alter rendering policy or create a
second shader implementation.

### Explicit-destruction probe labeling follow-up (Windows, 2026-11-15)

The feasibility probe and its build flags are named for the operation they
perform: `FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY`. The result now asserts
exactly one callback with `reason=Destroyed`, and the success message states
that this does not count as driver/OS-loss evidence. This keeps callback
delivery under intentional teardown separate from genuine loss and recovery in
the validation matrix.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) passed the
native and `js_wasm32` checks for the explicit-destroy configuration, plus the
shared renderer package check. The fixture built for native interactive use,
Windows asynchronous smoke, and `js_wasm32`; the D3D12 smoke passed on an
NVIDIA GeForce RTX 2080 SUPER, including pixel readback, geometry cache,
backdrop, image, surface, and queue-completion retirement assertions. The
source-patched explicit-destroy callback matrix was not rerun in this slice;
the earlier Windows and hosted macOS results remain the recorded callback
evidence. Genuine driver/OS loss and device recreation remain unvalidated.

The full `tools/test.ps1 -Odin C:\odin\odin.exe` suite also passed on this
candidate: 352 Runtime tests, 197 SDL_GPU integration tests, AccessKit ABI/UIA,
foundation, restoration, and native host-contract checks. Existing large-stack
warnings for `Native_Secondary_Window` test locals remain. This verifies the
temporary SDL_GPU reference and preserved host/runtime contracts; it is not
production WebGPU integration evidence.

### Phase 3 same-device compositor reconstruction probe (Windows, 2026-11-15)

The bounded native fixture checks the distinction between retained CPU
products and device-owned renderer resources. After the existing readback and
cache-pressure mutations complete, it submits a fresh baseline render from the
current retained display list and maps the RGBA8 target. It then waits for both
mapping and queue completion, destroys the quiescent compositor, creates a
new compositor on the same device and queue, prepares the same Runtime-owned
display products, and compares every pixel from the second render with the
baseline. It also requires fresh solid, text, icon, image, and custom-geometry
GPU products to be built.

Validation with Odin `dev-2026-11-nightly:08539cd` on an NVIDIA GeForce RTX
2080 SUPER:

- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` passed;
  it built native interactive, regular smoke, compositor-recreation smoke,
  resize smoke, and `js_wasm32` outputs.
- `out/webgpu_feasibility_recreate_smoke.exe --backend=d3d12` passed the full
  fixture readback/cache/retirement checks and compositor reconstruction
  (`queue_completed=true`, `pixel_identical=true`,
  `cpu_products_rebuilt=true`).
- The same bounded smoke passed with `--backend=vulkan` on the NVIDIA adapter.
- `git diff --check` passed.

This is exact pixel evidence for rebuilding renderer-owned cache state after
intentional compositor teardown while the WebGPU device remains alive. It does
not simulate spontaneous driver/OS device loss, recreate a WebGPU device, or
validate production window teardown. Those remain separate Phase 3 gates.
