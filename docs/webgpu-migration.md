# SDL_GPU to WebGPU migration

Status: Phase 0 remains open for lifecycle, baseline, and performance evidence;
Phase 1 now includes shared Hosted_Runtime WebGPU surface coordinators for the
browser and SDL3 native fixture, exercised against the shared compositor;
Phase 2 has bounded solid-surface, text-sampling, icon, image, material,
custom-surface caching, and mixed compositor slices. SDL_GPU remains the only
complete application renderer and the visual reference.

Stage A of hosted-runtime parity is complete on native SDL3: menus, integrated
chrome, dialogs, close deferral, and one secondary window with its own chrome
and services are covered by the shared hosted API and by the reference host.
Browser menus/dialog/close services and physical macOS/Linux validation remain
open; see [Stage A slice 4](#stage-a-slice-4-secondary-window-chrome-parity-and-physical-interaction-windows-2026-11-19).

The 2026-11-19 merge of `origin/master` into this branch, every shared-surface
change with its blast-radius verdict, and the integration regressions found and
fixed are recorded in
[the integration review](validation/webgpu-integration-review-2026-11-19.md).

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

- Open [#163](https://github.com/Carnival-Science/Alicorn/issues/163) contains an
  earlier bounded-browser research plan whose boundary explicitly says not to
  replace SDL_GPU. This owner-directed migration supersedes that restriction.
  Its browser input, accessibility, text/IME and capability-limit questions
  remain relevant; this migration tracker is authoritative for renderer scope
  and phase gates.
- [#162](https://github.com/Carnival-Science/Alicorn/issues/162) is closed with
  the host-owned SDL_GPU presenter boundary now on `master`. That validates the
  current external-frame seam, but does not prove that a WebGPU renderer
  consumes Alicorn's production paint stream. Preserve its borrowed-paint-list,
  synchronous owner-thread consumption, host-owned target/encoder/submission,
  and GPU-resource lifetime rules in the WebGPU presenter.
- [#196](https://github.com/Carnival-Science/Alicorn/issues/196) establishes a
  separate host-loop contract. Standalone and externally driven hosts share
  Runtime and renderer state across nonblocking steps; callbacks and Runtime
  mutation stay on the owner thread. Do not conflate loop ownership with #162's
  renderer/frame boundary.
- Open [#204](https://github.com/Carnival-Science/Alicorn/issues/204) describes
  failure recovery after acquiring an SDL_GPU swapchain texture. It remains a
  risk for the temporary reference path while SDL_GPU is retained; it does not
  dictate the WebGPU frame transaction. Keep its host/renderer recovery
  requirements visible when comparing the reference implementation.

## Phase tracker

| Phase | Exit evidence | Status |
| --- | --- | --- |
| 0. Feasibility and baseline | Windows SDL_GPU reference captured; same Odin/WGPU code builds and runs native and browser; solid/clipped/blended/rounded/image/Runa text/waveform/settled-motion, partial texture and buffer uploads, uniform-buffer layout, padded async readback, and queue-completion callbacks demonstrated; binding/lifecycle limitations recorded | In progress: the pre-change Windows SDL_GPU reference and D3D12 effects profile are recorded in `docs/validation/sdl-gpu-reference-windows-2026-11-15.md`; a Runtime-only Windows construction, phase, allocator high-water, and sampled process-working-set comparison is recorded in `docs/validation/runtime-construction-windows-2026-11-16.md`. Windows D3D12 and hosted macOS arm64 Metal smoke/callback evidence pass; Linux x64 X11/lavapipe native smoke passes; `js_wasm32` builds and actual browser WebGPU offscreen/readback passes. Windows browser canvas resize now verifies retained-only redraw with a fresh output revision and no UI re-description. A 2026-11-19 live browser run on the committed fixture code passed the full core/compositor/effects/material readback matrix, including solid translation and both cropped captures, on an NVIDIA Turing adapter with `fallback=false`; it is recorded in `docs/validation/webgpu-feasibility-browser-windows-2026-11-19.md`. The Odin browser binding's eight rejected-Promise callback chains are corrected in generated build copies and covered by an exactly-once regression; this does not simulate device loss. A bounded browser loss-recovery/rebind state machine is implemented and compiled, but real driver/OS loss and recovery have not been triggered. Browser fallback/vendor metadata is exposed, but does not establish hardware acceleration. The shared presenter has opt-in bounded CPU stage timings; a Windows D3D12 retained-motion smoke produced 48 WebGPU frame samples and 37 SDL_GPU submissions from the same callback on an RTX 2080 SUPER. This validates multi-frame native execution, but timing boundaries differ and it is not a performance-parity result. The later matched-description matrix in `docs/validation/webgpu-vs-sdlgpu-workload-matrix-windows-2026-11-19.md` supersedes the earlier unmatched-motion caveat: both hosts receive the same retained-motion scene, describe once, and present retained frames. Physical Linux GPU/Wayland, genuine loss recovery, production-application comparison, GPU-execution timings, and visible-latency measurements remain open. A five-run same-workload Windows fixture comparison now records CPU build, encode, and submit stages for SDL_GPU D3D12 and WebGPU D3D12/Vulkan in `docs/validation/webgpu-vs-sdlgpu-perf-windows-2026-11-19.md`; it is not a production workload or a GPU-execution measurement. The matched matrix records 131 assertions (129 PASS, 2 FAIL) across identical, transform, color, localized layout, 1k/10k scroll, simultaneous multi-window, and settled idle workloads. Its two failures are retained-work findings on the SDL_GPU reference path: solid geometry is re-uploaded on every submitted frame, so identical descriptions and transform-only motion do not retain solid geometry, while WebGPU uploads once and then uses transform-only updates. Text, icon, image, and surface geometry are retained on both. Cross-platform CI now also builds and runs the fixture's full readback matrix on hosted macOS arm64/Metal (`Apple Paravirtual device`) and Linux x64/llvmpipe under Xvfb, plus headless Chromium/SwiftShader; those runs record adapter identity and counter parity, but use software or virtualized adapters and are not physical-GPU or performance evidence (see `docs/validation/webgpu-feasibility-ci-crossplatform-2026-11-19.md`). Physical-session runbooks are ready for maintainers: `docs/validation/hardware-validation-macos.md`, `docs/validation/hardware-validation-linux.md`, and `docs/validation/hardware-validation-windows-highdpi.md`; they define adapter-identity checks, Wayland/X11 and Retina/mixed-scale steps, and evidence templates, but no physical macOS or Linux run is recorded yet |
| 1. Separation | renderer/host package boundary with unchanged runtime and app API | In progress: shared UI authoring and CPU preparation are SDL-independent; `renderer/webgpu/presenter.odin` consumes a borrowed finalized display list and encodes into caller-owned WebGPU frame objects, with queue submission and async completion owned by the host. `host/presentation/surface_presenter.odin` supplies a shared Hosted_Runtime-to-WebGPU-surface boundary. `host/web/application.odin` and `host/web/webgpu_run.odin` provide browser input/textarea, canvas sizing/DPR, visibility, async adapter/device bootstrap, bounded retry deadlines, and nonblocking teardown. Unexpected browser device loss now drains completion callbacks, discards the old presenter/device, and rebinds a new presenter to the existing Hosted_Runtime/input/accessibility objects. The feasibility fixture consumes the application coordinator. `host/sdl3/application.odin` composes the same Hosted_Runtime presenter with an SDL window identity, wake event, resize/DPI and visibility handling, focus changes, pointer/wheel, keyboard, text/IME routing, bounded retry deadlines, native AccessKit adapters on Windows/macOS, and nonblocking teardown. Native WebGPU `run` recovery preserves the Hosted_Runtime and now detaches old renderer handles and recreates primary and secondary SDL WebGPU surfaces before reattachment; the synthetic callback recovery smoke passes on Windows D3D12 and Vulkan, while genuine driver loss remains unverified. SDL3 pointer, modifier, wheel, focused-control, context-menu, application-shortcut, and text-editing key mapping plus native text/IME, clipboard, and AccessKit backend code lives in `host/sdl3` and its `host/sdl3/input` and WebGPU-agnostic `host/sdl3/clipboard` subpackages, with temporary SDL_GPU compatibility names retained. The browser fixture exercises resize, visibility, input, recovery, and async retirement; Windows SDL3 smoke exercises native retained presentation, pointer activation, synthetic key/text/IME routing, resize, and queue completion. A 2026-11-19 interactive pass on Windows D3D12 and Vulkan drove the native window with real `SendKeys`/`SendInput` and UIA: physical ASCII and Unicode text, Tab/Shift+Tab order, UIA Invoke on retained controls and the wake callback, and an auxiliary-window open/resize/close that preserved primary state; see `docs/validation/native-webgpu-ui-interactive-windows-2026-11-19.md`. IME composition, clipboard shortcuts, menus/titlebars, and screen-reader speech remain unvalidated. `paint_display_list_for_output` routes commands by disjoint retained root, preserves paint order and shared owner-zero overlays, and tags views with output identity and revision. Native D3D12/Vulkan fixture parity passes and the packages build for `js_wasm32`. SDL3 consumes posted `Hosted_Waker` notifications from its registered event; the browser records a posted wake and delivers it during the scheduled owner-thread step. Neither host polls wake state per frame. Native AccessKit domain actions are delivered through the application wake callback after the platform queue is drained. An opt-in native `alicorn:ui/webgpu` `run` and a browser-target `ui.run` path bootstrap WebGPU hosts while native `ui.run` remains on SDL_GPU pending acceptance. The renderer-neutral `UI_Host_Services` callback now delivers asynchronous-capable clipboard services through native `ui.run`, native WebGPU `run`, and browser `ui.run`; the browser adapter uses the permission-gated Clipboard API and bounded promise requests. Default native backend selection, physical IME composition and browser clipboard permission verification, and downstream application import migration remain outstanding; native titlebar chrome now has a hosted SDL3 port (slice 3: Windows integrated band tested locally, macOS full-size-content compile-checked); native menus now share `runtime/menus.odin` and the `host/menus` service/adapter between the SDL_GPU and SDL3/WebGPU hosts (Windows Win32 menu bar tested locally, macOS NSMenu compile-checked, browser menus still TODO); a one-child native WebGPU secondary-window service is implemented, with strict Windows Vulkan and D3D12 primary-plus-child presentation smoke passing and physical open/resize/close interaction now covered by the 2026-11-19 pass. The Windows native AccessKit code and tests now live under `host/sdl3/accessibility`; see the 2026-11-17 validation below. UIA tree and pattern behavior is now exercised programmatically; Narrator/NVDA speech remains unverified |
| 2. Core parity | solid, clipping, text, image, icon, materials and custom surfaces pass native/browser tests | In progress: local Windows Vulkan and D3D12 fixtures exercise per-resource custom-surface caching, budget pressure, in-flight protection, instance transforms, readback, and resize. One shared compositor preserves interleaved paint order; text, icon, image, and resource-local custom geometry reuse are asserted. Semantic gradients, relief, clipping, waveform samples, and cropped mixed-renderer readback pass Windows D3D12 and browser WebGPU. Shared CPU backdrop planning/meshes feed renderer-owned WebGPU prefix capture, filtering, and in-order composition for up to four markers within one aggregate 48 MiB tracked mesh+texture allocation budget. Two overlapping markers pass pixel readback on Windows D3D12/Vulkan and browser WebGPU; the later marker's capture includes the earlier marker's composed result. D3D12 also verifies unchanged-prefix reuse, changed-prefix invalidation, resized-target retirement behind the prior queue serial, and exact ordinary-paint parity when a valid effect exceeds budget. Six shared WGSL sources are compile-time loaded for native and `js_wasm32` builds. The rounded raised relief surface under increased contrast/reduced transparency now passes browser pixel readback as well as Windows D3D12/Vulkan; browser run also verified live canvas resize, output acknowledgement, and return to demand-driven idle. Full theme/accessibility combinations, application host presentation, and broader cross-platform GPU validation remain open |
| 3. GPU lifecycle | bounded asynchronous retirement, capture/readback, device loss/recreation and window teardown validated | In progress: image, custom-geometry, and backdrop resources have bounded asynchronous retirement and completion-driven release tests; async readback is exercised. Same-device compositor teardown/rebuild reproduces every RGBA pixel on Windows D3D12 and Vulkan from retained Runtime products. Browser recovery drains queue callbacks, recreates adapter/device/presenter with one immediate attempt plus three bounded retries, and requests retained repaint without UI re-description. Native SDL3 recovery now drains callbacks, preserves Hosted_Runtime/input state, abandons old device-bound renderer handles, recreates primary and secondary SDL surfaces, reacquires adapter/device, and reattaches both presenters. The synthetic `.Unknown` callback recovery smoke passes for primary and primary-plus-child windows on Windows D3D12 and Vulkan; see `docs/validation/webgpu-native-synthetic-recovery-windows-2026-11-17.md`. This exposed and fixed stale surface texture reuse and a lost-device resource-release panic. Renderer/WebGPU (6), presentation-host (6), and SDL3 host (11) tests pass; a shared reason policy routes `.Destroyed` and `.CallbackCancelled` away from automatic recovery while unexpected reasons use bounded retries. The full Windows `tools/check.ps1` also passes after fixing its SDL3 test invocation to use the pinned AccessKit compiler arguments. The fixture strict child smoke continues to pass on Windows Vulkan and D3D12. This is callback-path evidence only: it does not trigger actual driver/OS loss or validate real callback ordering. Physical keyboard/Unicode input, UIA activation, and auxiliary-window resize/close are now exercised on Windows D3D12 and Vulkan; see `docs/validation/native-webgpu-ui-interactive-windows-2026-11-19.md`. IME composition, clipboard shortcuts, menus/titlebars, genuine loss recovery, and device-loss resource behavior remain open. Browser callback-ordering research and the generated Odin JS correction are recorded in `dependencies/webgpu-toolchain.md`. Intentional `DeviceDestroy` callbacks remain separate and do not count as driver-loss evidence. The induced-backend-removal rung is now covered on Windows D3D12: a test-only wgpu-native export calls `ID3D12Device5::RemoveDevice()` on the live device, wgpu's DeviceLost callback fires with `.Unknown`, and the same recovery path recreates adapter/device/surfaces and presents a replacement frame in 122–164 ms; see `docs/validation/webgpu-native-backend-removal-windows-2026-11-19.md`. This is harness-induced, single-backend evidence, still not OS/driver-initiated; Windows TDR and physical macOS/Linux loss remain open |
| 4. Desktop acceptance | full regression suite, pixel comparisons, performance, Scratchpad/Punks/AliKit dogfood, and packaging/launch evidence from an actual WebGPU application | Not started: the physical-session runbooks are in place — `docs/validation/hardware-validation-macos.md` (physical Apple Silicon, Metal, Retina), `docs/validation/hardware-validation-linux.md` (physical GPU, Wayland and X11, fractional scaling), and `docs/validation/hardware-validation-windows-highdpi.md` (per-monitor DPI and mixed-scale drags). Each requires a maintainer-run dated record; none has been recorded yet. The Windows induced-removal result in `docs/validation/webgpu-native-backend-removal-windows-2026-11-19.md` covers rung 3 of the loss ladder but is not desktop acceptance. The macOS `tools/build_native_release.sh` static-wgpu check packages 01_hello, an SDL_GPU consumer that does not import wgpu; it only proves the existing packaging contract (static SDL3, no leaked rpath) has not regressed. Desktop acceptance must additionally package and launch an actual WebGPU application with static wgpu-native plus AccessKit, and record that evidence |
| 5. SDL_GPU removal | delete production backend, legacy shader artifacts, switches and obsolete docs | Not started |
| 6. Browser host | interaction, accessibility, text/IME, lifecycle and demand-driven scheduling complete | In progress: reusable demand-driven scheduling, host-side key mapping, DOM input routing, optional textarea-backed UTF-8/IME input, Hosted_Runtime surface presentation, and the reusable `Browser_Application` coordinator live in `host/web/`. Example 17's `ui.run` consumer builds for `js_wasm32`; its renderer-neutral host services now include an asynchronous Clipboard API adapter with explicit unsupported/permission/error results, an eight-request bound, a 1 MiB transfer bound, and shutdown cancellation. JS tests cover Unicode transfer, permission denial, unsupported APIs, size limits, and late promise settlement. A posted `Hosted_Waker` notification schedules one demand-driven frame and is delivered to `on_wake` on that frame's owner thread; no per-frame wake polling is used. Queued browser accessibility actions invoke `on_wake` on the owner thread, and Example 17 applies textbox `Set_Value` to its app-owned buffer; fresh browser validation confirms the semantic value updates. The clipboard adapter has not yet been exercised in a physical browser. `host/web/webgpu_run.odin` owns async browser adapter/device/surface setup and bounded recovery after unexpected loss; JS tests cover callback-driven retries without polling. Actual device loss/recovery is not physically validated. Headless tests cover the bounded DOM/ARIA model, Unicode selection, focus recovery, and secure-context/WebGPU capability errors. Physical IME and assistive-technology validation, browser clipboard permission interaction, actual device-loss recovery, and broader application dogfooding remain outstanding. A headless Chromium/SwiftShader CI job now executes the fixture's browser readback matrix from the `js_wasm32` artifact; Firefox and Safari remain untested, so multi-browser coverage is still open (see `docs/validation/webgpu-feasibility-ci-crossplatform-2026-11-19.md`) |
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
  consumption, and caller-owned target/encoder/submission; output-scoped views
  are obtained through `paint_display_list_for_output` and retain that output's
  own revision while excluding unrelated retained roots. Runtime-wide transient
  overlays remain shared and above each output's subtree. The presenter must not
  silently take surface or queue ownership. Loop ownership follows #196 independently:
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

## Phase 2 retained solid mesh invalidation (Windows, 2026-11-17)

The solid renderer previously keyed its retained mesh to the full display-list
revision. Since that revision also changes for unrelated text updates, a
text-only edit could rebuild and upload unchanged solid geometry. The cache now
fingerprints only surface commands, their display-list indices, target size,
and scale; Runtime identity remains a separate cache-key check. Including each
surface command index keeps ordered paint dispatch correct when the command
list's structure changes.

The CPU regression verifies that changing text bounds and color leaves the
solid fingerprint unchanged, while changing a surface fill or a surface's
display-list index invalidates it. The GPU fixture then changes only a text
command's translation and display revision. It verifies that solid mesh rebuild
and vertex-upload counts stay fixed, glyph geometry and atlas uploads stay
fixed, and the text translation buffer receives the update.

Validation on Windows:

- `C:\odin\odin.exe test renderer/cpu -collection:alicorn=.`: all 21 tests
  passed.
- `C:\odin\odin.exe check renderer/webgpu -no-entry-point`: passed.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe`: built the
  native fixtures and `js_wasm32` browser fixture.
- `out/webgpu_feasibility_smoke.exe --backend=d3d12`: passed on an NVIDIA
  GeForce RTX 2080 SUPER. The text-only revision regression and all existing
  readback, cache, resource-retirement, and cache-pressure probes passed.
- The browser artifact builds, but its live readback for this specific cache
  regression was not re-run in this pass; the Windows browser window capture
  timed out twice. Do not count this as browser runtime evidence.

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

Alicorn [#164](https://github.com/Carnival-Science/Alicorn/issues/164) closed
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
APIs. A host can reuse one presenter across targets on the same Runtime. For a
multi-output frame it passes the selected `Presentation_Output_ID` and a routed
display view stamped with that output snapshot's revision; successful
submission acknowledges only that target. Omitting the ID preserves the
whole-Runtime compatibility path. Submission tokens report display revision
and serial, and asynchronous
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
interactive, readback, compositor-recreation, resize, offscreen presenter,
SDL surface presenter, and `js_wasm32` fixture targets. `odin check renderer/webgpu -no-entry-point` and
`odin check renderer/webgpu -target:js_wasm32 -no-entry-point` passed. All five
WebGPU package tests passed, including a two-output acknowledgement regression;
all 352 Runtime tests passed after merging current `master`.

Run the native boundary probe with:

~~~powershell
.\build.ps1 -Odin C:\odin\odin.exe
.\out\webgpu_feasibility_presenter_smoke.exe --backend=d3d12
~~~

That earlier offscreen boundary smoke proves the host-owned frame contract
around the feasibility compositor, but by itself does not prove native-surface
or browser-canvas presentation, or real device-loss recovery. The surface
presentation evidence is recorded in the following sections. No adapter, SDL,
or browser responsibilities have moved into the renderer. Phase 1 and Phase 6
remain open.

### Phase 1 shared `ui.run` description slice (Windows and `js_wasm32`, 2026-11-16)

Moved the generic runner state and root/overlay description callback into
`ui/run_common.odin`, which is compiled for both native and browser targets.
The native adapter remains in `ui/run_native.odin` and still constructs
`native/sdl_gpu.Application`; the public key callback now uses Runtime's
backend-neutral `Application_Key` type. This establishes one shared application
description path for future host adapters without claiming that a browser
`ui.run` or production WebGPU host exists yet.

Validation: the standard Windows `tools/test.ps1 -Odin C:\odin\odin.exe`
completed successfully, and the focused UI tests passed all 39 tests. The
browser-target package check also passed:

~~~powershell
odin check ui -target:js_wasm32 -collection:alicorn=. -no-entry-point
~~~

Browser host selection, event delivery, accessibility, and WebGPU presentation
through `ui.run` remain open Phase 1/6 work.

### Shared `ui.run` adapter for host-driven Runtime (Windows and `js_wasm32`, 2026-11-16)

`ui/run_common.odin` now adapts the same generic `Run_State` callbacks to
`Hosted_Runtime_Config`: root content and overlays, initialization, lifecycle,
application wake, application key, text-change, and pointer callbacks. The
adapter borrows its state through `hosted_runtime_destroy`, and translates the
hosted waker back to the existing `Application_Waker` contract. The native
`ui.run` path continues to use the SDL host; its application-key callback now
uses the same shared dispatch helper.

The new UI regression initializes a real `Hosted_Runtime` through this adapter,
checks root/overlay description, waker delivery, explicit invalidation, key and
pointer callbacks, and stop ordering. All 40 UI tests passed on Windows; the
`js_wasm32` UI package check passed. This is a usable host boundary, not yet a
browser event loop or WebGPU surface host. Browser key-to-`Application_Key`
translation, DOM text/IME and accessibility routing, one-shot animation-frame
scheduling, and WGPU surface/device/presenter ownership remain open Phase 1/6
work.

### Phase 6 demand-driven scheduling foundation (Windows, 2026-11-16)

`host/web/demand_scheduler.js` now owns the browser scheduling policy used by
the WebGPU feasibility page. It coalesces input and asynchronous completion
wakes into one animation frame, requests another frame only when the prior
runtime step reports more work, and uses a single bounded timer for the next
absolute monotonic deadline. Early timer delivery rechecks the deadline;
hidden pages cancel pending frame/timer callbacks and resume with one current
frame rather than replaying missed frames. The module owns no renderer,
application state, paint decisions, or browser interaction policy.

Seven deterministic Node regressions cover wake coalescing and idle quiescence,
active-work frame chaining, deadline scheduling and early delivery, visibility
suspension/resume, a wake arriving during a runtime step, long-deadline clamping,
and initially hidden startup. All seven passed on Windows with Node 24.18.0.
The same `js_wasm32` WebGPU feasibility fixture
also rebuilt successfully against the updated page, and its build scripts copy
the shared host scheduler alongside the Odin and WGPU browser support files.
The Linux WebGPU workflow runs the scheduler regressions.

This is browser-host scheduling infrastructure exercised by the feasibility
fixture, not yet a production `ui.run` browser host. No browser GPU execution
was performed for this slice. Browser event/IME/clipboard integration, DOM/ARIA
projection, host-owned canvas lifecycle, and app-level validation remain open.

### Phase 6 browser key vocabulary (Windows and `js_wasm32`, 2026-11-16)

`host/web/key_mapping.odin` translates normalized browser `KeyboardEvent.code`
and modifier state into Alicorn's existing `Application_Key` and
`Application_Text_Key_Event` vocabularies. It follows the native shortcut
policy for application commands, Ctrl on Windows/Linux and Meta on macOS,
platform word
deletion/navigation, line boundaries, and document boundaries. Composition
arbitration and focused text ownership remain host responsibilities; this
helper deliberately does not dispatch events or depend on DOM APIs.

Two Odin regressions cover application shortcuts, menu suppression, focused
composition preemption policy, Windows/macOS text-navigation modifiers, and
unsupported keys. Both passed on Windows; `host/web` passed a `js_wasm32`
compile, and the browser package fixture now imports the mapping package. The
standard Windows/macOS test scripts and Linux WebGPU workflow run these host
policy tests. This is key translation policy, not browser event delivery or
text/IME integration.

## SDL-created native surface presenter smoke (Windows, 2026-11-16)

The new opt-in `FEASIBILITY_TEST_SURFACE_PRESENTER` target draws a separate
retained Alicorn Runtime through `WebGPU_Presenter_Encode` into the actual
swapchain texture acquired by the SDL3 host. SDL remains responsible for the
window, surface, acquisition, queue submission, `SurfacePresent`, event
processing, and teardown. The presenter receives the exact registered output
ID and revision; after `QueueSubmit`, the fixture verifies only that output's
revision was acknowledged, then waits for its queue-completion token before
destroying the presenter and unregistering the output.

`examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` passed and
built this target plus all existing native fixtures and the browser
`js_wasm32` artifact. The bounded surface smoke passed on Windows D3D12 and
Vulkan using an NVIDIA GeForce RTX 2080 SUPER; both requested/reported backend
pairs agreed. Each run presented one frame at 960×540, acknowledged output
revision 1, completed submission serial 1 with zero frames in flight, and
unregistered the output before Runtime teardown. The surface target does not
read back swapchain pixels or claim scanout. This is evidence for an
SDL-created native surface; externally managed native surfaces remain an open
host integration. Browser canvas evidence follows separately.

## Browser canvas shared-renderer smoke (Windows browser, 2026-11-16)

The `js_wasm32` build now selects `FEASIBILITY_TEST_WEB_CANVAS_PRESENTER`. It
creates the same retained Runtime composition used by the native SDL surface
smoke and calls the same `WebGPU_Presenter_Encode` implementation into the
browser canvas surface. JavaScript remains a surface, input-trigger, and
completion-callback host; it does not compose paint commands.

The local WebGPU fixture opened in the Windows browser created a WebGPU adapter
and device, passed its existing mixed-paint offscreen readback, presented
Runtime display revision 1 to an 870×489 canvas at scale 0.906, and completed
queue serial 1 with zero frames in flight. Pressing Resize produced a second
presenter submission and successful queue completion. After that, the page
reported no new animation-frame requests for 500 ms (six total, including two
initialization wake frames). The browser run does not identify whether the
adapter was hardware- or software-backed, so it is API/runtime correctness
evidence, not acceleration or performance evidence.

The canvas smoke presents a small retained surface-and-text composition. The
mixed paint list's solid, shaped text, icons, images, materials, custom
geometry, and waveform are separately covered by the shared compositor's
offscreen pixel readback. This does not yet validate a real application or
browser input/accessibility projection.

## Shared Runtime motion on the native surface and browser canvas (Windows, 2026-11-16)

The opt-in presenter scene now builds one retained Runtime tree containing
Runa-shaped text, an adopted checker image, a rounded clipped card, a
translucent surface, and a waveform payload held by Alicorn's existing custom
geometry API. The same `WebGPU_Presenter_Encode` and WGSL render this composition
to the SDL-created surface and the browser canvas. The waveform remains a
retained renderer resource while the card receives a translation-only reveal.
No application-facing GPU canvas API was added; waveform mesh caching remains
renderer-local as directed by Alicorn #164.

The reveal exercises the Runtime presentation-output contract. A sampled motion
change marks only the outputs containing its retained owner. The host then
opens a presentation-only frame, flushes composition, and publishes the new
display revision without rerunning UI descriptions. Native presentation waits
for each queue-completion callback before submitting the next frame, and the
SDL host polls wgpu-native while that callback is pending. Once motion settles
and the final submission completes, the host returns to its event wait.

Validation on this Windows host:

- `C:\odin\odin.exe test runtime`: 353 tests passed, including a regression
  that verifies sampled motion marks the owning output pending without dirtying
  a separate output.
- `tools/test.ps1 -Odin C:\odin\odin.exe`: the full Windows regression script
  passed, including the 353 Runtime tests, 197 SDL_GPU integration tests,
  AccessKit ABI/UIA, restoration, and native text-input/ownership host checks.
- Native build with `FEASIBILITY_TEST_QUIT_AFTER_READBACK` and
  `FEASIBILITY_TEST_SURFACE_PRESENTER`: passed. The bounded run selected Vulkan
  on an NVIDIA GeForce RTX 2080 SUPER (driver 595.97), completed the existing
  asynchronous pixel readback and cache-retirement probes, and presented
  retained revisions 2 through 25. Each presenter completion and output
  acknowledgement passed; the final settled revision completed before exit.
- `js_wasm32` browser build: passed. The live localhost browser canvas rendered
  the shared composition; status reported the reveal settled, queue serial 51
  completed successfully, and no frame requests during the following 500 ms
  (56 requests total, including two initialization wake frames).
- `git diff --check`: passed after this documentation update.

The browser run did not record whether its adapter was hardware- or
software-backed, and its request count is not a performance measurement. These
fixtures do not establish cross-platform pixel parity for the visible surface,
production application integration, externally managed browser/native
surfaces, or primary/secondary application windows. This motion smoke also
does not simulate driver/OS-initiated device loss. Intentional `DeviceDestroy`
callback delivery remains a separate test result; genuine loss and recovery
remain open Phase 0/3 gates.

## Output-scoped display routing on native and browser surfaces (Windows, 2026-11-16)

`paint_display_list_for_output` now produces a borrowed command view for one
registered retained root. It filters out unrelated output subtrees while
preserving paint order, carries the output identity and its published revision,
and retains Runtime-wide owner-zero transient overlays. The WebGPU presenter
rejects a tagged view paired with a different output ID, including when both
outputs happen to share the same revision. The view is allocated from Runtime
scratch storage and must be consumed synchronously on the Runtime owner thread.

The native SDL surface fixture and browser canvas fixture both use this query
and the same `WebGPU_Presenter_Encode` compositor. The native host still owns
surface acquisition, command submission, completion polling, and presentation;
the browser host still owns canvas sizing, callbacks, and event scheduling.

Validation on Windows x64 with `C:\odin\odin.exe` and the NVIDIA RTX 2080 SUPER:

- `odin test runtime`: 354 tests passed, including output-subtree filtering,
  shared overlay routing, output identity/revision tags, and an older but still
  current untouched-output revision.
- `odin test renderer/webgpu`: 6 presenter tests passed, including rejection
  of a view tagged for a sibling output.
- `tools/test.ps1 -Odin C:\odin\odin.exe`: passed the full Windows regression
  script, including 354 Runtime tests, 197 SDL_GPU tests, AccessKit ABI/UIA,
  restoration, and native host contracts.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe`: built
  the native fixtures and `js_wasm32` browser target.
- The native SDL surface smoke completed output-scoped submissions through
  queue serial 17 with zero work in flight and exited successfully on Vulkan.
- The live browser canvas reported output `1` acknowledged at revision `20`,
  queue serial `10` completed, and no animation-frame requests during the next
  500 ms (22 requests total, including two initialization wake frames).
- `git diff --check` passed.

The browser run exposed fallback/vendor metadata, but that does not establish
whether rendering used a physical GPU; the automation screenshot capture timed
out. The browser's live accessibility status exposed the successful output
acknowledgement and completion instead.
This is fixture-level native/browser host evidence, not a production `ui.run`
integration or a pixel capture. Externally managed third-party native surfaces,
physical browser acceleration classification, and device-loss recovery remain
open. Intentional `DeviceDestroy` callback evidence is still tracked separately
from driver/OS-initiated loss.

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

The merged Windows candidate was rechecked with
`tools/native_sdl_gpu.ps1 -GpuCanvasValidation -Speed -Odin C:\odin\odin.exe`
on 2026-11-16. D3D12 readback remained pixel-identical at 100%, 125%, 150%,
and 200% scale, including resized retained blur; slider semantics and input
remained intact; 128 rapid updates rebuilt neither Runtime description; hidden
idle requested no frame or persistent allocation; and static GPU buffers were
released after their fences. In this run, cached peaks reduced CPU encode p95
from 68.7 µs to 21.9 µs, uploads from 227,232 B/frame to 5,184 B/frame, and
geometry passes from four to two, while adding 222,048 B of persistent peak
buffers. Submit-to-fence p95 was 150.2 µs versus 118.5 µs; as the report notes,
this host timing is noisy and is not a GPU execution timestamp. The fixture is
still a composition-level comparison, not instrumentation of the Punks app.

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
  500 ms. The page exposed `fallback=false` and available vendor metadata, but
  that is not proof of physical-GPU acceleration; this is correctness evidence
  only.

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

### Phase 2 browser replay of rounded accessibility material (Windows, 2026-11-16)

Replayed the `js_wasm32` feasibility build in a live browser using the same
per-corner raised relief surface, increased-contrast, and reduced-transparency
fixture described above. The asynchronous RGBA8 readback and focused material
result both passed: variant resolution, face, bevel, rounded corner, and
suppressed shadow. The same source rebuilt all native and browser targets;
`webgpu_feasibility_smoke.exe --backend=d3d12` and
`webgpu_feasibility_smoke.exe --backend=vulkan` both passed on Windows x64 with
an NVIDIA GeForce RTX 2080 SUPER. Both reported the core, compositor, effects,
and focused material readbacks as passing, along with cache-pressure,
retirement, and queue-completion checks. Splitting the readback diagnostics
into bounded groups also prevents the browser console bridge from truncating
the trailing material results. The browser also classified its selected
adapter as non-fallback with NVIDIA/Turing metadata; adapter metadata does not
establish physical acceleration. Clicking **Resize surface** produced a new retained
output revision at 870×489, acknowledged presentation and queue completion,
and returned to idle with no recurring animation-frame requests. This closes
the prior browser-replay gap for this one fixture only; it is not full material
theme/accessibility parity or production host presentation evidence.

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

## Browser canvas resize recovery regression (Windows browser, 2026-11-16)

The feasibility page's **Resize surface** control changes the canvas backing
size, which clears its presented contents. The Web host now requests a
presentation-only Runtime frame and flushes the retained display list after
surface configuration. It checks that a fresh output revision is published;
the application description and layout are not rerun. The page fetches the
WASM artifact without HTTP cache reuse so a browser reload cannot silently test
an older build.

Validation on the local Windows browser with the rebuilt `js_wasm32` artifact:

- After an uncached page reload, resizing in both directions kept the retained
  scene visible. The output revision advanced `76 -> 77` at `870x489`, then
  `77 -> 78` at `1208x679`.
- Each resize logged `surface resize retained redraw PASS`; the browser
  presenter acknowledged and completed the new output. The page returned to
  its settled state without a continuous animation-frame loop.
- `odin test runtime` passed all 354 Runtime tests. The feasibility build
  completed for native fixtures and `js_wasm32`.

This is live browser surface-reconfiguration correctness evidence. It does not
identify whether the browser adapter is hardware accelerated, measure visible
frame latency, or establish native resize behavior for this exact retained-only
redraw path. Those platform and performance checks remain open.

### Phase 6 browser DOM input routing (Windows compile and headless tests, 2026-11-16)

`host/web/browser_input.odin` now owns removable Odin WASM event listeners for
canvas pointer-down and wheel, window pointer-move/up/cancel and blur, canvas
keyboard/focus/blur, and document visibility. Window pointer listeners preserve
an active drag when the pointer leaves the canvas; canvas-relative coordinates
are derived from the live client rectangle. Wheel pixel, line, and page deltas
are normalized into Alicorn's existing scroll event. Handled events wake a
host-supplied demand scheduler, and visibility updates both Hosted_Runtime and
the host scheduler.

Hosted text-key delivery is now a Runtime API, so browser text-field caret
navigation and deletion use the same selection, composition guard, and text
change dispatch as other hosts. The DOM keypress path commits ordinary text
strings, including multi-byte UTF-8 characters.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`):

- `odin test host/web -collection:alicorn=.` passed all 5 browser policy tests,
  including wheel-mode signs/scaling, context-menu shortcuts, and text-key
  filtering.
- `odin test runtime -collection:alicorn=.` passed all 356 Runtime tests,
  including hosted text-key selection, edit callback delivery, composition
  protection, and handled delivery of the application scroll fallback.
- The `tests/fixtures/web_ui_package` target built for `js_wasm32`, compiling
  the DOM event host, shared UI, CPU renderer, and WebGPU presenter boundary.

This is an input adapter foundation, not a production browser host or live DOM
interaction result. Odin's current event projection does not provide browser
composition payloads, precise fractional pointer coordinates, or wheel-event
pointer coordinates/modifiers. The current keypress path therefore does not
complete IME behavior; those gaps must be resolved before browser text-input
acceptance. `ui.run`, canvas sizing/WebGPU frame scheduling integration,
accessibility projection, and browser application dogfooding also remain open.

### Phase 6 browser text-input proxy (Windows `js_wasm32` and headless tests, 2026-11-16)

`Browser_Input` now accepts an optional host-provided textarea ID. When present,
the adapter moves DOM focus between the canvas and that textarea as Alicorn's
focused retained control changes. The textarea is only a browser input surface;
all committed edits and composition state still flow through
`hosted_runtime_text_input`. Regular text, paste, and IME commits use a UTF-8
safe value read rather than the JS event projection's UTF-16-sized key buffer.
Composition input events call Hosted_Runtime Preedit, composition end commits
once (with a short duplicate-input guard), and Escape marks the active
composition for cancellation. DOM UTF-16 selection offsets are converted to
Unicode-scalar indexes, and the textarea is placed at the Runtime's retained
text-input caret geometry for candidate-window positioning.

The browser feasibility page now provides this textarea and wires the helper
after each Hosted_Runtime step. The bridge remains opt-in so a host without a
DOM text control retains the existing keyboard fallback. This does not provide
the browser accessibility projection or production `ui.run` host.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`):

- `odin test host/web -collection:alicorn=.` passed all 6 host-policy tests,
  including UTF-16 offsets around accented, CJK, and astral Unicode scalars.
- `odin test runtime -collection:alicorn=.` passed all 356 Runtime tests.
- The hosted feasibility example built for `js_wasm32` with the shared canvas
  presenter enabled.

No physical IME session was available for this validation. Windows and macOS
IME candidate behavior, composition cancellation in supported browsers, and
screen-reader behavior remain hands-on acceptance work; compilation and the
pure offset tests do not establish those platform results.

### Phase 1/6 Hosted browser surface coordinator (Windows `js_wasm32`, 2026-11-16)

`host/web/surface_presenter.odin` now binds a host-created WebGPU surface and
device to one Alicorn `Hosted_Runtime`. A bounded host step advances at most one
Runtime description and submits only when presentation is pending. The helper
consumes the finalized display list synchronously, uses the shared WebGPU
presenter, acknowledges through its submission token, and retires renderer
resources only from the asynchronous queue-completion callback. Surface
timeout/backpressure are nonblocking results; lost/outdated surfaces are
reconfigured and rescheduled. Resize and page visibility jointly suspend or
restore retained scheduling, including zero-sized drawable surfaces.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`):

- The `tests/fixtures/web_ui_package` package built for `js_wasm32`, compiling
  the new WebGPU surface coordinator together with shared UI, CPU rendering,
  and the WebGPU renderer package.
- `odin test host/web -collection:alicorn=.` passed all 5 browser-policy tests.
- `odin test runtime -collection:alicorn=.` passed all 356 Runtime tests.
- `git diff --check` passed.

This is a reusable host API boundary. The feasibility example integration and
its build checks are recorded below; it is not yet the production browser
entrypoint. Production `ui.run`, browser text composition, accessibility
projection, and a live DOM run through this newest integration remain open.

### Hosted browser feasibility example integration (Windows builds, 2026-11-16)

The browser variant of `examples/15_webgpu_feasibility` now creates a
`Hosted_Runtime` after its existing WebGPU adapter/device setup, initializes
`Browser_Surface_Presenter` with the canvas surface, and routes pointer,
keyboard, wheel, focus, and visibility events through `Browser_Input`. The
sample UI has a retained button and controlled text field, so it can exercise
actual Runtime input when run in a browser. The scheduler supplies a monotonic
nanosecond timestamp to `Hosted_Runtime`, follows its next-wake deadline, and
is woken by asynchronous WebGPU completion. Resizing updates both canvas pixel
dimensions and the hosted logical/drawable metrics. The old standalone
`Runtime` surface fixture remains the native reference path.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`):

- The browser fixture built for `js_wasm32` with the new `alicorn:` collection
  configured explicitly from its example directory.
- The native interactive feasibility executable still built successfully.
- `odin test host/web -collection:alicorn=.` passed all 5 browser-policy tests.
- Node parsed the embedded browser bootstrap script successfully.
- `git diff --check` passed.
- A live browser interaction was attempted, but Windows window capture timed
  out twice. No live UI, resize, keyboard, or pointer pass is claimed for this
  new integration.

On page teardown, the fixture detaches DOM listeners and destroys the hosted
presenter/runtime only when no WebGPU work is in flight. If work remains, it
keeps those callback-referenced objects alive until the WASM page instance is
reclaimed. This fixture behavior is not evidence of general browser device-loss
or application-shutdown recovery.

### Shared Hosted_Runtime WebGPU surface lifecycle (Windows, 2026-11-16)

The surface coordinator has moved from the browser-only package into
`host/presentation/surface_presenter.odin`. It owns the common bridge from a
`Hosted_Runtime` to a host-created WebGPU surface and shared renderer: retained
resize/visibility state, one bounded step per wake, output acquisition and
presentation, completion-driven resource retirement, and nonblocking teardown.
The browser module now contains compatibility aliases and forwards to this
shared implementation. SDL3/native hosts can use the same coordinator without
importing browser interop.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`):

- `odin test host/presentation -collection:alicorn=.` passed (1 guard test).
- `odin test host/web -collection:alicorn=.` passed (5 tests).
- `examples/15_webgpu_feasibility` compiled for `js_wasm32` with the hosted
  canvas presenter enabled.
- The native feasibility executable built successfully; the common presenter
  also compiled in the native host test target.
- `git diff --check` passed.

This is a reusable presentation boundary. The browser feasibility example and
a native SDL3 feasibility smoke now exercise the shared coordinator. This is
not production-host integration: SDL3 window/surface/device creation, complete
native event and IME routing, visibility/minimize scheduling, and `ui.run`
target selection still need to be wired before native applications can use
WebGPU by default.

### SDL3 native Hosted_Runtime presenter smoke (Windows, 2026-11-16)

The native feasibility host now runs a retained Alicorn UI through
`host/presentation/surface_presenter.odin` on an SDL3-created WebGPU surface.
This is the same coordinator used by the browser wrapper. The bounded smoke
queries the retained button bounds, injects a primary pointer down/up through
`hosted_runtime_pointer`, requests an SDL window resize to 800×450, verifies a
new surface presentation after the resize, waits for asynchronous queue
completion, and destroys the presenter before the Hosted_Runtime and surface.
The window/event loop and resize are real; the pointer input is synthesized
from Runtime geometry, not a physical mouse event.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) on Windows
with an NVIDIA GeForce RTX 2080 SUPER:

- The native hosted feasibility build succeeded with
  `FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER` and
  `FEASIBILITY_TEST_NATIVE_HOSTED_SMOKE` enabled.
- `native_hosted_feasibility.exe --backend=d3d12` exited 0; device selection
  reported D3D12 and the hosted render, pointer activation, 800×450 resize,
  post-resize presentation, queue retirement, and shutdown checks passed.
- `native_hosted_feasibility.exe --backend=vulkan` exited 0 with the same
  hosted interaction and resize checks.
- Browser `js_wasm32` feasibility build succeeded; `odin test host/presentation`
  passed 1 test and `odin test host/web` passed 5 tests.
- `git diff --check` passed.

This establishes a native SDL3/WebGPU hosted-surface proof, not production
`ui.run` integration. Native key mapping, text input and IME, focus policy,
clipboard, drag/drop, minimize/restore behavior, secondary windows, and
application dogfooding remain unvalidated on this path. It does not close
Phase 0's Linux hardware/Wayland and genuine device-loss gaps.

### Browser hosted-surface resize recovery (Windows, 2026-11-16)

The live resize failure was caused by an Odin `vendor:wgpu` binding mismatch:
the generated binding declares `SurfacePresent` as returning `wgpu.Status`,
but `vendor/wgpu/wgpu.js` implements browser presentation as a void no-op
because WebGPU presents the canvas on queue submission. WASM therefore observed
an invalid zero status. The shared presenter latched that as a permanent
presentation failure; the next resize could no longer submit a replacement
frame, leaving the canvas black and eventually reporting `RuntimeError:
unreachable executed`.

The shared presentation package now selects a platform-specific status adapter:
native targets still require `.Success`, while `js` treats the browser's
no-op as success and relies on the existing asynchronous queue completion for
submission errors. Surface acquisition failures are also reported distinctly
from presenter failures. Temporary resize diagnostics were removed.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) on Windows:

- The full feasibility build completed, including native binaries and the
  `js_wasm32` browser fixture.
- `odin test host/presentation` passed (1 test); `odin test host/web` passed
  (5 tests).
- The live browser fixture reported WebGPU hardware acceleration
  (`fallback=false`, NVIDIA Turing) and all core, compositor, effects, and
  material readbacks passed.
- Clicking the retained button updated its visible state; typed text appeared
  in the retained text field. Both interactions returned to demand-driven idle.
- Repeatedly toggling **Resize surface** resized the canvas in both directions;
  retained UI and the edited field value remained visible, no browser runtime
  error appeared, and the host returned to demand-driven idle after each change.
- Native Hosted_Runtime presenter smoke passed on both D3D12 and Vulkan,
  including pointer activation and an 800×450 resize.
- The full Windows `tools/test.ps1 -Odin C:\odin\odin.exe` suite passed.
- `git diff --check` passed.

This validates the hosted feasibility path and the browser/native presenter
boundary. It does not validate production `ui.run`, browser device-loss
recovery, or the remaining Phase 0 platform gaps.

### SDL3 native input mapping extraction (Windows, 2026-11-16)

SDL3 pointer, button, modifier, focus-reset, and wheel conversion now live in
`host/sdl3/input/input_mapping.odin`, separate from the SDL_GPU package. The current
frontend delegates to this shared SDL3 host module through thin wrappers, so a
future SDL3/WebGPU native host can preserve the same Alicorn event semantics.
The mapping tests cover logical pointer coordinates, modifier snapshots,
Control-primary mapping policy (including macOS control-click), click counts,
stable down/up button mapping, focus-loss cleanup, wheel direction/metadata,
focused-control/context-menu key actions, platform-specific text editing
navigation including word, line, and document movement/deletion, and event-to-
window ownership for window, keyboard, pointer, text/IME, drop, and process-level
events.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) on Windows:

- `odin test host/sdl3 -collection:alicorn=...` passed all 6 tests.
- The full `tools/test.ps1 -Odin C:\odin\odin.exe` suite passed, including
  the new SDL3 host tests, 356 Runtime tests, 40 UI tests, 197 native SDL_GPU
  tests, and the existing AccessKit, restoration, and native text-input checks.
- Linux `webgpu-linux.yml` now runs the SDL3 mapping tests; the macOS shared
  test script also includes them. Hosted CI has not run for this local change.
- `git diff --check` passed and the changed PowerShell files parsed cleanly.
  Git Bash could not start inside the Windows sandbox (signal-pipe creation
  returned Win32 access denied), so shell syntax validation is left to hosted
  Linux/macOS CI.

This is a host-code extraction only. It does not move SDL3 window lifecycle,
key/text/IME routing, clipboard, drag/drop, AccessKit, or scheduling out of
`native/sdl_gpu` yet, and it is not evidence of native WebGPU application
input acceptance.

### Browser application coordinator extraction (Windows and `js_wasm32`, 2026-11-16)

`host/web/application.odin` now composes one `Hosted_Runtime`,
`Browser_Input`, and the shared WebGPU surface presenter. It derives logical
and physical canvas dimensions from CSS bounds and device pixel ratio, updates
the drawing-buffer size, coordinates visibility and retained presentation,
returns bounded retry deadlines to the browser scheduler, refreshes the hidden
text-input proxy after Runtime steps, and makes teardown nonblocking while GPU
work remains in flight. WebGPU instance/adapter/device creation and the outer
JavaScript module loader remain owned by the embedding application at this
stage.

The feasibility browser host now uses this coordinator instead of maintaining
its own parallel lifecycle wiring. Its Runtime callbacks and retained content
are unchanged. This is a reusable browser host boundary; it does not yet
provide production `ui.run` or solve the lifetime contract for application
state when a browser entrypoint returns asynchronously.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) on Windows:

- `odin test host/web -collection:alicorn=.` passed all 6 tests.
- `odin test runtime -collection:alicorn=.` passed all 356 tests.
- `odin test ui` with the repository's pinned AccessKit compiler arguments
  passed all 40 tests.
- `tools/check_web_ui_package.ps1 -Odin C:\odin\odin.exe` passed for
  `js_wasm32`.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` built all
  native feasibility executables and the browser WASM fixture.
- `git diff --check` passed.

The full `tools/test.ps1` run stopped in the external AccessKit Windows UI
Automation smoke with `Accessible Button missing`, before reaching its unit
test stages. The focused Runtime, UI, and browser-host suites were run
separately and passed. After reloading the Windows fixture at localhost:8091,
the owner confirmed that clicking the retained button updates the visible state
to `Button input reached the Hosted_Runtime.` and no browser runtime error
appears. This is live pointer-and-rerender smoke evidence for the refreshed
fixture and its Browser_Application path. The screenshot does not identify the
served commit SHA; it does not establish resize, IME, hardware acceleration,
or performance behavior for that exact artifact.

### Native SDL3/WebGPU Hosted_Runtime coordinator (Windows, 2026-11-16)

`host/sdl3/application.odin` now provides the native counterpart to the
browser application coordinator around the existing shared presentation
boundary. It owns one Hosted_Runtime, SDL window identity, registered SDL wake
event, and WebGPU surface presenter. It routes resize and DPI changes,
zero-sized suspension, show/hide, focus changes, pointer events, and wheel
input; the host retains adapter/device/surface creation and the outer event
loop. Presentation retries use one bounded deadline, and teardown remains
nonblocking while queue work is in flight. The feasibility native fixture now
uses this coordinator instead of duplicating Hosted_Runtime and presenter
lifecycle wiring.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) on Windows:

- `odin check host/sdl3 -collection:alicorn=. -no-entry-point` passed.
- `odin test host/sdl3 -collection:alicorn=.` passed all 6 input-mapping tests
  with the Odin SDL3 and wgpu-native DLL directories on `PATH`.
- The native hosted feasibility target built through the new coordinator.
- The full bounded D3D12 fixture smoke passed on an NVIDIA GeForce RTX 2080
  SUPER: shared compositor readbacks, synthetic retained-button activation,
  real SDL resize to 800×450, post-resize presentation, queue completion, and
  teardown all succeeded.
- The same feasibility source built for `js_wasm32`, confirming the native
  SDL3 host remains excluded from the browser target.

This is a native Hosted_Runtime/presentation boundary, not production `ui.run`
or full native input acceptance. At this revision the coordinator routes
pointer/wheel input only; keyboard shortcuts, text fields, IME, clipboard,
drag/drop, menus, dialogs, AccessKit, and secondary windows are outstanding.
The synthetic pointer smoke validates the coordinator's pointer entry point,
not physical mouse input. Zero-size suspension is handled by the coordinator,
but was not part of this smoke.

### SDL3/WebGPU keyboard, text, and IME routing (Windows, 2026-11-16)

The native coordinator now routes SDL key events through the shared host
mapping into `Hosted_Runtime`: application shortcuts respect focused text
owners and IME composition, interaction scopes receive preempting keys, text
fields get navigation/deletion/selection and submit behavior, Tab traverses
focus, and Select/context-menu overlays retain first refusal. SDL committed
UTF-8 text and composition preedit/cancel events use the hosted text-input API;
character selection offsets are normalized at the runtime boundary. SDL text
input starts and stops as retained focus changes, and the candidate-window
anchor follows current text-field geometry. Focus loss and application teardown
cancel composition and release the SDL text session.

The native feasibility fixture now sends synthetic SDL mouse, text, preedit,
key, focus, and Escape events through the real `SDL3_WebGPU_Application` event
router. It checks Left navigation, Control+A selection, committed text,
UTF-8 preedit, Escape and window-focus cancellation, text-session stop/restart,
resize presentation, and queue retirement before destruction. This validates
SDL event mapping and Hosted_Runtime delivery; it does not represent physical
keyboard input or a real operating-system IME session.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) on Windows:

- `odin check host/sdl3 -collection:alicorn=. -no-entry-point` passed.
- `odin test host/sdl3 -collection:alicorn=.` passed all 7 tests.
- `odin test runtime -collection:alicorn=.` passed all 357 tests.
- `odin test ui` with the repository's pinned AccessKit compiler arguments
  passed all 40 tests.
- The native Hosted_Runtime D3D12 smoke passed on an NVIDIA GeForce RTX 2080
  SUPER, including synthetic text navigation/selection/commit, UTF-8 IME
  preedit, Escape and focus-loss cancellation, 800×450 resize, asynchronous
  completion, and teardown.
- The same native Hosted_Runtime smoke passed on the Vulkan backend using the
  NVIDIA GeForce RTX 2080 SUPER.
- The complete feasibility build produced the native variants and the
  `js_wasm32` browser fixture; the production browser coordinator remains
  independent of the `!js` SDL3 host.
- `git diff --check` passed.

At this revision, this is not yet production `ui.run` on SDL3/WebGPU. Clipboard,
application-owned text-key callbacks in the run adapter, drag/drop,
menus/dialogs, AccessKit, secondary windows, physical input/IME, and native
macOS/Linux validation remain open. A refreshed localhost:8091 browser fixture
was separately confirmed by the owner to accept clicks without the earlier
runtime error; that screenshot does not identify its served commit or establish
those outstanding gates.

### Application-owned editor text-key routing (Windows, 2026-11-16)

The generic editor-key callback now crosses `Hosted_Runtime`, the shared
`ui.run` adapter, SDL3/WebGPU input, and browser keyboard routing. Focused
`text_input_target` nodes receive normalized navigation and deletion intents;
built-in `Text_Field` controls retain Alicorn's existing caret policy. Active
IME composition keeps these keys, and handled events invalidate the shared
description. The native `ui.run` callback receives the focused owner and keeps
editor caret/selection policy in application state.

The bounded native fixture now injects Left into an application-owned editor
target and asserts its callback is reached, alongside the existing Text_Field
text/IME and resize checks. The common hosted-adapter test and native
`run_application` forwarding test cover both callback adapters. The refreshed
localhost:8091 page was also reloaded by the owner and clicked without the prior
runtime error; its screenshot does not establish the exact served SHA, browser
keyboard routing, physical GPU acceleration, or browser IME behavior.

The browser fixture now includes an application-owned editor-key probe that
reports the last normalized key and event count. Its `js_wasm32` build passes,
but live interaction with this new probe remains unverified: the Windows
computer-use capture timed out twice while inspecting the browser window.

Validation with `C:\odin\odin.exe` on Windows:

- Runtime tests passed (357), SDL3 host tests passed (7), browser-host tests
  passed (6), and UI tests passed (41), including generic editor-key and
  composition-gating cases.
- The native Hosted_Runtime fixture passes on D3D12 and Vulkan, including the
  application-owned Left-key callback, text/IME routing, resize, and teardown.
- The full feasibility build produced all Windows native fixtures; after the
  browser probe was added, its `js_wasm32` fixture rebuilt successfully.

This closes the optional text-key callback adapter gap for native and hosted
`ui.run` composition. The bounded DOM/ARIA projection is now present in
`host/web`; live browser focus/action and assistive-technology validation,
physical IME and keyboard checks, production `ui.run` host selection for
WebGPU, clipboard, drag/drop, menus/dialogs, secondary windows, and native
macOS/Linux validation remain outstanding.

### Bounded browser semantic DOM projection (Windows `js_wasm32` build and headless tests, 2026-11-16)

`host/web/accessibility.odin` converts a complete Runtime semantic snapshot to
a bounded JSON view with stable IDs derived from the semantic namespace and
identity. It maps Runtime roles, labels, descriptions, values, states, numeric
properties, collection positions, live-region metadata, focus, and available
actions. `Text_Run` children are retained as internal selection-mapping data
rather than exposed as duplicate controls.

`host/web/accessibility_dom.js` maintains stable browser elements and applies
incremental attribute/value/order changes without replacing the tree on each
semantic revision. Native browser controls cover buttons, textboxes, checkboxes,
sliders, tabs, and generic ARIA roles. Click, focus, input, composition-end, and
text-selection events route through the existing Hosted_Runtime semantic
action APIs. DOM UTF-16 selection offsets convert to Alicorn selectable text-run
units; offsets inside astral Unicode scalars snap to a grapheme boundary. The
root is visually hidden and the canvas is marked `aria-hidden` while this
projection is enabled. Keyboard modality now drives a separate system-color
focus outline positioned from the focused semantic node's bounds; it remains
hidden during pointer modality. The marker is excluded from the accessibility
tree and recomputes its CSS geometry when the canvas or page moves/resizes.

The projection bounds snapshots to 4,096 candidate nodes, output to 2,048 DOM
controls, semantic text to 1 MiB, and serialized JSON to 8 MiB. Oversized or
unrepresentable trees replace any prior projection with a live status message,
preventing stale controls from remaining actionable. Snapshot text is checked
before cloning so oversized values do not cause unbounded temporary copies.
The example opts in with `accessibility_root_id="alicorn-accessibility"` and
loads the DOM helper from its feasibility web directory.

Validation with `C:\odin\odin.exe` on Windows:

- `odin test runtime -collection:alicorn=.` passed 360 Runtime tests,
  including bounded ordering and pre-clone text-budget cases.
- `odin test host/web -collection:alicorn=.` passed 13 tests, including
  projection caps, strict JSON, stable identity, and UTF-16-to-grapheme
  boundary mapping for accented and astral text.
- The feasibility fixture built for `js_wasm32`; `node --check` passed for the
  JavaScript DOM helper; `git diff --check` passed.
- The owner confirmed the refreshed `localhost:8091` page no longer reproduces
  the earlier runtime trap. That is not evidence that this uncommitted worktree
  was served, and does not validate the new accessibility DOM at runtime.

This is an opt-in accessibility host foundation, not browser acceptance.
Live screen-reader behavior, keyboard-only focus/action routing, text
editing/selection in a real browser, physical IME, and virtualized collection
navigation still need browser validation.

### Browser keyboard focus mirror (Windows `js_wasm32`, headless DOM regression, 2026-11-16)

The browser accessibility payload now carries focused-control bounds and the
Runtime viewport size. `Browser_Application` forwards the input adapter's
keyboard-modality state, so pointer use hides the visual ring and keyboard
navigation shows it without requiring another Runtime semantic revision. A
single `aria-hidden`, pointer-transparent overlay uses system `Highlight` and
`Canvas` colors, clips to the canvas, scales logical bounds to its CSS rectangle,
and follows canvas resize or document scroll. Destroy removes the overlay and
its listeners and restores the canvas ARIA attributes.

Validation with `C:\odin\odin.exe` on Windows:

- `odin test host/web -collection:alicorn=.` passed all 15 tests; the existing
  payload test now asserts bounds, viewport, and focus-modality serialization.
- `odin check host/web -target:js_wasm32 -collection:alicorn=. -no-entry-point`
  passed.
- `node tools/test_accessibility_dom.js` passed geometry scaling, same-revision
  modality and viewport changes, resize repositioning, missing-bounds behavior,
  and teardown.
- `node --check host/web/accessibility_dom.js` passed. The Linux WebGPU workflow
  now runs the DOM focus regression as well.

This is deterministic DOM-geometry evidence, not a live browser screenshot or
assistive-technology result. Focus appearance under browser zoom, high-contrast
settings, and real screen readers remains to be checked.

### Opt-in native WebGPU `ui.run` consumer (Windows, 2026-11-16)

`host/sdl3/run.odin` now owns an ordinary SDL3 window and the native WebGPU
adapter/device bootstrap for UI applications. It uses asynchronous WebGPU
callbacks, processes them from the SDL owner thread, configures the surface
from adapter capabilities, and delegates retained presentation, SDL input,
IME routing, resize/DPI, visibility, wake events, and frame retirement to the
existing `SDL3_WebGPU_Application` and shared `Hosted_Surface_Presenter`.
WGPU polling is bounded to adapter/device setup or outstanding submissions;
the settled event loop blocks in SDL. Queue synchronization is used only while
draining the final submission during shutdown.

`alicorn:ui/webgpu`'s `run` (originally named `ui.run_webgpu`) adapts the same
app-owned render and lifecycle callbacks used by
`ui.run` into `Hosted_Runtime`, initializes the bundled default fonts, and
offers an opt-in native consumer without switching the default backend. It
lives in a separate package specifically so SDL_GPU consumers of `alicorn:ui`
do not compile the WebGPU host or need wgpu-native. The
new `examples/16_native_webgpu_ui` demonstrates text, a button, a controlled
text field, and app-owned state. `--backend=vulkan` and `--backend=d3d12` select
the native adapter for local validation; the default leaves backend selection
to wgpu-native. This is not yet a replacement for `ui.run`.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) on Windows:

- `odin check host/sdl3 -collection:alicorn=. -no-entry-point` passed.
- The complete `tools/test.ps1 -Odin C:\odin\odin.exe` suite passed before the
  backend-selector addition; it included the UI, Runtime, SDL3, browser host,
  and existing SDL_GPU suites. The repository's existing large-stack-local
  warnings remain.
- `examples/16_native_webgpu_ui` built as `out/alicorn_webgpu_ui.exe`.
- `out/alicorn_webgpu_ui.exe --smoke --backend=d3d12` presented a frame and
  retired its queue submission on an NVIDIA GeForce RTX 2080 SUPER.
- `out/alicorn_webgpu_ui.exe --smoke --backend=vulkan` did the same on the
  NVIDIA GeForce RTX 2080 SUPER.
- Smoke mode exits only after one successful surface presentation and its
  in-flight submission have completed. It does not validate physical input,
  typing, resize, IME, accessibility, or long-running behavior in this new
  app-level wrapper.

At this initial validation point, the new path still lacked the SDL_GPU host's
integrated titlebar, native menus, AccessKit adapter, secondary-window manager,
optional system-font fallbacks, clipboard, and drag/drop. Later sections record
the subsequent clipboard, secondary-window, and AccessKit work. Physical
keyboard/IME checks, genuine device-loss validation, and broader macOS/Linux
acceptance remain open. `ui.run` continues to select SDL_GPU, and this opt-in
consumer is still a first production-shaped native host slice.

### Phase 1/6 browser `ui.run` host bootstrap (Windows `js_wasm32`, 2026-11-16)

`host/web/webgpu_run.odin` now owns creation and lifetime of the browser WebGPU
instance, canvas surface, adapter, device, and queue before composing the
existing `Browser_Application`. It chooses a supported surface format,
present mode, and alpha mode from capabilities; asynchronous setup and device
loss wake the host scheduler; destroy remains nonblocking while callbacks or
submissions are outstanding. The browser-target `ui.run` adapter now routes
the shared UI callback model through this host. Its exported frame, resize,
status, and shutdown functions are driven by `host/web/webgpu_ui_host.js`, the
bounded DOM helper in `host/web/accessibility_dom.js`, and the reusable demand
scheduler.

`examples/17_browser_webgpu_ui` is a small `ui.run` consumer with retained
button state and textarea-backed text input. Its build script copies the
matching Odin and WebGPU JavaScript bindings plus the shared scheduler.
Because browser startup is asynchronous, `ui.run` returns after requesting the
adapter and device; the application state pointer must remain valid while the
host is active. This browser build supports one `ui.run` instance per WASM
module. The native SDL_GPU `ui.run` behavior remains unchanged pending desktop
acceptance.

Validation with Odin `dev-2026-11-nightly:08539cd` on Windows:

- Runtime (360), browser-host (13), SDL3-host (7), and UI (41) test suites
  passed when run directly into `out/` with the required AccessKit compiler
  arguments. `tools/check_web_ui_package.ps1` also passed.
- `odin check host/web -target:js_wasm32 -collection:alicorn=. -no-entry-point`
  passed, and the same host package checked for `windows_amd64`.
- `odin check ui -target:js_wasm32 -collection:alicorn=. -no-entry-point`
  passed.
- `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe` produced
  `examples/17_browser_webgpu_ui/out/web/app.wasm`; the static page returned HTTP
  200 from localhost.
- `node --check host/web/webgpu_ui_host.js` passed, and
  `node tools/test_webgpu_ui_host.js` passed the browser-host lifecycle cases.
  A page entering the back/forward cache now suspends scheduling without
  destroying its WASM/WebGPU state; `pageshow` resumes it. Ordinary page exit
  still requests nonblocking teardown, retaining the scheduler if GPU work is
  outstanding. The same cases run in the Linux WebGPU workflow.
- The POSIX build script was added for macOS/Linux but was not run here; the
  installed Git Bash process could not start because Windows denied its signal
  pipe.
- The full `tools/test.ps1` entry point stopped in the external
  `odin-accesskit` Windows UIA contract check with `Accessible Button missing`,
  before running Alicorn suites. The direct suites listed above passed.
- A live browser run was attempted, but computer-use navigation to the local
  example timed out; no browser rendering, click, typing, resize, IME, or
  shutdown behavior is claimed for this new consumer.

This is a browser-host integration slice, not browser acceptance. Device loss
recovery, visible DOM focus behavior, and assistive-technology behavior remain
open.

### Browser `ui.run` consumer bootstrap (Windows browser, 2026-11-16)

The `examples/17_browser_webgpu_ui` consumer was rebuilt with
`.\build.ps1 -Odin C:\odin\odin.exe`, served from `out/web` on port 8092,
and opened at `http://127.0.0.1:8092/` in the Windows browser. The browser
accessibility tree exposed the application canvas and textarea input proxy, and
the status changed from `Starting WebGPU…` to
`WebGPU UI ready. Resize, click, or type to exercise the retained host.`. In
`host/web/webgpu_ui_host.js`, that ready status is only set after the browser
WebGPU run state becomes ready; the host then requests the retained application
frame. This advances the evidence from build-only to live host initialization.

The screenshot-backed Windows window capture timed out during two recovery
attempts. Therefore this check does not claim that pixels were visibly
presented, or that button activation, typing, resize, IME, focus, and shutdown
work in this consumer. The owner's separate `localhost:8091` validation is the
feasibility example 15 and remains evidence for that example, not for this
consumer. The 8092 server was left running for direct manual inspection.

### Browser WebGPU device-loss recovery path (Windows `js_wasm32`, 2026-11-16)

The browser `ui.run` host now distinguishes intentional `.Destroyed` and
`.CallbackCancelled` notifications from unexpected device loss. Unexpected loss
stops regular frames, marks the presenter unusable, drains every outstanding
queue callback, releases the lost device without calling `DeviceDestroy`, and
re-requests an adapter and device for the existing canvas surface. A fresh
presenter is attached to the same `Hosted_Runtime`, input bridge, and
accessibility projection. Reattaching requests retained paint without
rebuilding the application description. Adapter/device request failures use
an immediate initial request followed by at most three retries with 250 ms,
1 s, and 2 s delays; a presenter rebind failure is terminal. Shutdown also
waits for the device-lost callback caused by intentional `DeviceDestroy`,
keeping callback context alive. Callbacks and timers wake the demand scheduler
without a continuous frame loop.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) on Windows:

- `odin test runtime -collection:alicorn=.` passed all 361 tests, including a
  regression that verifies host-requested repaint does not rebuild the UI
  description.
- `odin test host/presentation -collection:alicorn=.` passed the presenter
  contract test; `odin test host/web -collection:alicorn=.` passed all 13
  browser-host tests; and `odin test renderer/webgpu -collection:alicorn=.`
  passed all 6 renderer tests.
- `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe` produced
  the browser `ui.run` WASM consumer, and the `examples/15_webgpu_feasibility`
  browser target compiled successfully.
- `node tools/test_webgpu_ui_host.js` passed 4 host scheduling/lifecycle cases;
  `node tools/test_web_scheduler.js` passed 7 demand-scheduler cases; JavaScript
  syntax checks and `git diff --check` passed.

This validates compile-time integration and the JavaScript scheduler contract,
not a spontaneous browser/driver device-loss event. The recovery state machine
has not yet been exercised against actual loss, and native SDL3/WebGPU device
recovery remains unimplemented. The earlier `DeviceDestroy` probes remain
intentional-destruction evidence only.

### Recovery retry and callback-order coverage (Windows, 2026-11-17)

The backoff policy is now isolated in the platform-neutral
`host/web/recovery_policy.odin` so native tests can verify its deadlines without
constructing fake WebGPU handles. It permits an immediate initial request and
three retries at 250 ms, 1 s, and 2 s, then becomes terminal. Adapter or device
callbacks that report loss while a device request is still pending are allowed
to settle before the host retires the adapter or starts another request.

Validation with `C:\odin\odin.exe` on Windows:

- `odin test host/web -collection:alicorn=.` passed all 15 tests, including
  retry timing, duplicate-request prevention, exhaustion, and recovery-budget
  reset after success.
- `odin check host/web -target:js_wasm32 -collection:alicorn=. -no-entry-point`
  passed.
- `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe` rebuilt the
  browser `ui.run` consumer and patched the eight Odin WebGPU one-shot callback
  chains in its generated JavaScript bindings.
- `node tools/test_webgpu_ui_host.js` passed all 4 scheduling/lifecycle cases.

This improves deterministic policy and callback-order coverage, but it still
does not simulate browser GPU loss. A physical browser/driver loss and recovery,
as well as native SDL3/WebGPU recovery, remain outstanding.

### Native SDL3/WebGPU active-session recovery (Windows, 2026-11-16)

The native WebGPU host entry (now `alicorn:ui/webgpu`'s `run`, previously
`ui.run_webgpu`) now uses the shared recovery policy from
`host/presentation/webgpu_recovery.odin`. Unexpected device loss marks the
presenter unusable, waits for in-flight frame callbacks, destroys the
device-bound presenter while preserving its `Hosted_Runtime` and SDL input
state, then requests a replacement adapter/device and reattaches the presenter
to the existing application. Recovery makes one immediate attempt and at most
three retries at 250 ms, 1 s, and 2 s. Intentional `.Destroyed` and
`.CallbackCancelled` notifications remain terminal and are not treated as
driver-loss evidence. Native WGPU completion polling stays submission-driven;
while a device-loss callback is pending, an idle host performs bounded event
maintenance no more often than every 250 ms.

Validation with `C:\odin\odin.exe` on Windows:

- `odin check host/sdl3 -collection:alicorn=. -no-entry-point` passed.
- `odin test host/sdl3` passed all 7 tests when built with the repository's
  pinned AccessKit compiler arguments; `host/presentation` passed 3 tests,
  `host/web` passed 13, `runtime` passed 361, and `ui` passed 41.
- `odin check host/web -target:js_wasm32 -collection:alicorn=. -no-entry-point`
  passed, and the existing browser-host tests still passed after moving the
  retry policy into the shared presentation package.
- `examples/16_native_webgpu_ui` built and its `--backend=vulkan --smoke` run
  exited successfully after presenting a frame and draining normal teardown.
  The selected adapter was an NVIDIA GeForce RTX 2080 SUPER on Vulkan.
- Initial default-mode D3D12 native WebGPU attempts stalled before adapter
  details, but a rebuild of the exact `d04f72f` source with `-o:speed` passed
  the D3D12 UI smoke twice, and the freshly rebuilt D3D12 Hosted_Runtime
  interaction/resize smoke also passed. The earlier stall remains unexplained;
  see the [follow-up validation](validation/native-webgpu-ui-windows-2026-11-16.md).

This verifies native application bootstrap, ordinary D3D12 presentation,
teardown, and compile-time integration. It does not trigger or validate a
genuine driver/OS device-loss event, replacement-device recovery, macOS/Linux
native recovery, or secondary-window recovery. Those remain Phase 3 acceptance
work. The earlier browser recovery note above records its historical status;
the shared retry policy and native host have since advanced as described here.

### Induced D3D12 backend device removal (Windows, 2026-11-19)

The third device-loss rung removes the live D3D12 device from underneath wgpu.
`dependencies/patches/wgpu-native-v29.0.1.1-test-remove-d3d12-device.patch`
adds a test-only `wgpuDeviceRemoveD3D12ForTesting` export that reaches the
D3D12 device through `wgpu-core`'s `device_as_hal::<Dx12>`, `wgpu-hal`'s
`raw_device()`, and `ID3D12Device5::RemoveDevice()`. The symbol is not in the
WebGPU C header; the validation host resolves it with `core:dynlib` behind the
`ALICORN_WEBGPU_TEST_D3D12_REMOVE_DEVICE` build define.

On the RTX 2080 SUPER, the DeviceLost callback fired with `.Unknown` 0.08–0.50
ms after removal, the existing recovery policy recreated the adapter, device,
surfaces, and presenters in 117–157 ms, and a post-recovery frame presented at
120–162 ms. Four primary-window runs plus a primary-plus-child run passed, as
did the ordinary smoke and the synthetic callback case. Two host robustness
fixes came out of the run: a resize racing the removal no longer configures a
swapchain on the lost device, and presentation failures observed in the same
step as the loss no longer abort the host loop.

This remains harness-induced backend removal on one D3D12 GPU. It does not
exercise driver/OS-initiated loss ordering, Windows TDR, Vulkan device loss, or
physical macOS/Linux hardware. See
[`validation/webgpu-native-backend-removal-windows-2026-11-19.md`](validation/webgpu-native-backend-removal-windows-2026-11-19.md)
and run `tools/validate_wgpu_native_backend_removal.ps1`.

### Exact-source D3D12 native UI retest (Windows, 2026-11-16)

The first default-mode `examples/16_native_webgpu_ui` D3D12 attempts did not
produce adapter output before being stopped. After isolating the native UI host
from the D3D12 feasibility fixture, the exact `d04f72f` source was rebuilt in
optimized mode and passed twice. A freshly rebuilt D3D12 Hosted_Runtime
feasibility smoke also passed pointer routing, synthetic text-key and IME
preedit/cancel/commit routing, resize, queue completion, and teardown. The
default-mode stall's cause is still unknown; do not treat this retest as
evidence for debug-mode startup or genuine device-loss recovery.

See [`native-webgpu-ui-windows-2026-11-16.md`](validation/native-webgpu-ui-windows-2026-11-16.md)
for exact commands, outputs, and validation limits.

### Browser accessibility focus recovery (Windows, 2026-11-17)

When a semantic DOM node that currently owns browser focus disappears during a
new snapshot (for example, after a virtualized or structural update), the
projection now restores focus to the newly reported semantic target when one
exists, or to Alicorn's hidden accessibility root when it does not. Focus
restoration uses `preventScroll` so the recovery does not move the page. A
headless DOM regression covers removal and subsequent focus transfer.

Validation with Node on Windows: `node tools/test_accessibility_dom.js` passed;
`git diff --check` passed. This validates projection logic only; browser-native
focus behavior and assistive-technology announcements still need physical
browser validation.

### Browser WebGPU capability errors (Windows, 2026-11-17)

Browser startup now reports an insecure-context requirement separately from
missing WebGPU support, and rejects before downloading the WASM module. This
makes the secure-context restriction actionable for users who opened the app
from an unsupported origin, while retaining the explicit unsupported-browser
message. Once WASM starts, the Odin host reports distinct failure codes for
instance creation, adapter unavailable/request failure, canvas
surface/capability failure, device request, queue creation, and Alicorn
presenter initialization. Synchronous instance/surface allocation failures
use this status path instead of trapping the WASM runtime. The page maps the
codes to actionable status text. An adapter-unavailable message points users
to browser GPU support, drivers, and permissions; it does not claim the browser
has hardware acceleration.

Validation with Odin `dev-2026-11-nightly:08539cd` and Node on Windows:

- `node tools/test_webgpu_ui_host.js` passed all six startup/lifecycle tests,
  covering insecure context, missing WebGPU, and all eight initialization
  failure messages.
- `node --check host/web/webgpu_ui_host.js` passed.
- `odin check host/web -target:js_wasm32 -collection:alicorn=. -no-entry-point`
  and the matching `odin check ui` passed.
- `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe` rebuilt
  the browser `ui.run` consumer and patched the generated WebGPU bindings.
- `git diff --check` passed.

### SDL3 clipboard host extraction (Windows, 2026-11-17)

The synchronous UTF-8 clipboard service contract and SDL get/set implementation
now live in `host/sdl3`, separate from renderer code. The former
`native/sdl_gpu` names forward to the host implementation for source
compatibility during the migration. The existing large UTF-8, empty-versus
failure, and embedded-NUL tests moved with the service into the host package.
The 2026-11-19 build-time opt-in correction moved the implementation itself to
the WebGPU-agnostic `host/sdl3/clipboard` package so SDL_GPU consumers do not
import the WebGPU host.

Validation with Odin `dev-2026-11-nightly:08539cd` on Windows:

- `odin test host/sdl3 -collection:alicorn=.` with the repository's pinned
  AccessKit compiler args passed all 10 host tests.
- `odin check native/sdl_gpu` with the Alicorn, AccessKit, and AccessKit C
  collections passed; it emitted only the existing large-stack warnings from
  secondary-window tests.
- `odin test native/sdl_gpu` with the repository's pinned AccessKit compiler
  args passed all 194 tests, confirming the existing frontend still compiles
  and exercises the compatibility surface. Its diagnostics negative-case log
  was expected; the suite finished successfully.

### `ui.run` clipboard service injection (Windows, 2026-11-17)

`UI_Host_Services` now exposes a renderer-neutral, asynchronous-capable
clipboard request contract to applications. The native SDL_GPU `ui.run` path
adapts its existing `Application_Services.clipboard`; native WebGPU `ui.run`
uses the SDL3 host implementation directly. Both deliver the capability from
`on_services` before `on_start`. Native callbacks may complete synchronously;
the shared request contract also permits later completion on the owning host
thread.

At this point in the migration, browser `ui.run` exposed the same
`on_services` hook but delivered an empty clipboard capability. Browser
text-input paste continued through the host textarea; application-level
clipboard requests still needed the Web Clipboard API adapter described below.

Validation with Odin `dev-2026-11-nightly:08539cd` on Windows:

- `odin test ui` passed all 42 tests, including service-before-start ordering
  and a fake SDL3 clipboard read/write round trip through native `ui.run`.
- `odin test host/sdl3` passed all 10 host tests.
- `odin check ui -target:js_wasm32 -no-entry-point` passed.
- The browser `ui.run` consumer built with
  `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe`.
- `examples/16_native_webgpu_ui` built optimized and its Vulkan smoke exited
  successfully after presentation on an NVIDIA GeForce RTX 2080 SUPER.
- `git diff --check` passed.

### Permission-aware browser clipboard service (Windows, 2026-11-17)

Browser `ui.run` now supplies the same renderer-neutral clipboard service as
the native hosts. Reads and writes use `navigator.clipboard` and begin the
permission-gated operation synchronously in the originating JavaScript event
stack to preserve transient user activation. Completion returns asynchronously
on the browser main thread and wakes the demand scheduler after application
state has been updated. Missing APIs, permission denial, unavailable
operations, over-limit content, cancellation, and generic failures have
distinct `Clipboard_Result` values. UTF-8 transfers are limited to 1 MiB and
there can be at most eight outstanding operations. Reads allocate WASM memory
only after a bounded UTF-8 length is known. Host shutdown closes the service,
completes pending requests as cancelled, and ignores later promise results by
token.

Validation with Odin `dev-2026-11-nightly:08539cd` on Windows:

- `node tools/test_webgpu_ui_host.js` passed all nine host tests, including
  Unicode clipboard read/write, permission denial, unsupported API, bounded
  reads, and late settlement after shutdown.
- `odin check ui -target:js_wasm32 -collection:alicorn=. -no-entry-point`
  and `odin check host/web` passed for `js_wasm32`.
- `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe` rebuilt
  the browser `ui.run` consumer and patched the generated WGPU callbacks.
- The resulting WASM exports both clipboard bridge callbacks.
- Example 17 now has Read clipboard and Copy sample text controls so the
  permission-dependent path can be exercised from a real pointer gesture.
- Physical browser permission prompts and user-gesture clipboard behavior have
  not been manually validated. The Windows computer-use helper timed out
  during browser discovery; hosted tests exercise the JS bridge contract but do
  not substitute for that physical browser check.
- `odin test ui` passed all 42 tests with the pinned AccessKit compiler args.

### Native shared-device multi-surface lifecycle fixture (Windows, 2026-11-17)

The SDL3/WebGPU feasibility fixture can now open two native windows with
independent `Hosted_Runtime` and presenter state while sharing one adapter,
device, and queue. It checks the second surface's format, alpha, and present
capabilities before configuring it; sends synthetic focus and pointer events to
the second window and confirms the primary host rejects those window-targeted
events; resizes and presents the secondary surface again; and destroys the
secondary presenter only after its queue work completes. The fixture then shuts
down the primary application and both WGPU surfaces before destroying the
windows.

Validated on Windows x64, Odin `dev-2026-11-nightly:08539cd`, NVIDIA GeForce
RTX 2080 SUPER, D3D12 and Vulkan. The optimized fixture exited 0 on both
backends and reported successful adapter/device callbacks, initial presentation
on both surfaces, isolated secondary focus/pointer routing, a 720×450 secondary
resize presentation, primary pointer/text/IME/resize checks, queue-complete
secondary teardown, and the final two-surface lifecycle PASS.

Reproduce from the repository root:

```powershell
C:\odin\odin.exe build examples/15_webgpu_feasibility `
  -collection:alicorn=. -o:speed `
  -define:FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER=true `
  -define:FEASIBILITY_TEST_NATIVE_HOSTED_SMOKE=true `
  -define:FEASIBILITY_TEST_NATIVE_MULTI_SURFACE=true `
  -out:examples/15_webgpu_feasibility/out/native_multi_surface_speed.exe
Copy-Item C:\odin\vendor\sdl3\SDL3.dll examples/15_webgpu_feasibility/out/ -Force
Copy-Item C:\odin\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll `
  examples/15_webgpu_feasibility/out/ -Force
& examples/15_webgpu_feasibility/out/native_multi_surface_speed.exe --backend=d3d12
```

This is host-lifecycle evidence, not a production application window service,
physical input validation, secondary-window recovery after genuine device loss,
macOS/Linux coverage, or a GPU performance comparison. Those remain open
acceptance work.

### Native WebGPU secondary-window service (Windows, 2026-11-17)

Hosted_Window_Service is now exposed to the native WebGPU entry through
UI_Host_Services.windows. The SDL3/WebGPU host accepts one deferred child
window at a time, gives it an independent Hosted_Runtime, input state, and
surface presenter, and shares the primary adapter/device/queue. Open, close,
title, and always-on-top requests are host-thread operations; creation and
teardown occur at event-loop safe points. Device-loss recovery now drains and
reattaches both presenters. Browser hosts leave this service unavailable.

The native UI example includes an auxiliary-window action and a --child-smoke
startup path. Validation on Windows x64 with Odin dev-2026-11-nightly:08539cd:

- `odin check host/sdl3 -collection:alicorn=. -no-entry-point` passed.
- `odin test runtime` passed all 363 tests, including the new host-service
  ordering and window-service forwarding tests.
- `examples/16_native_webgpu_ui` built with the repository pinned AccessKit
  compiler arguments.
- Ordinary Vulkan --smoke exited 0 and reported the NVIDIA GeForce RTX 2080
  SUPER adapter, validating primary native bootstrap/presentation/teardown.
- D3D12 child and primary smoke attempts exceeded 20 seconds; Vulkan
  --child-smoke remained live beyond 60 seconds and was stopped. That suggests
  the production child lifecycle still needs debugging; it did not pass.
- The Windows Computer Use helper timed out on app enumeration, so I could not
  inspect the native window or capture the point where the child path stalls.

### Native secondary-window smoke acceptance recheck (Windows, 2026-11-17)

The `--child-smoke` success condition now requires the primary surface to
present and drain, and, when a child exists, also requires a successful child
presentation and no child submission in flight. This prevents the smoke from
passing merely because the primary window rendered while the auxiliary window
was initialized and immediately torn down.

- `odin check host/sdl3 -collection:alicorn=. -no-entry-point` passed with the
  stricter smoke condition.
- The optimized `examples/16_native_webgpu_ui` build passed with the pinned
  AccessKit compiler/linker arguments.
- A bounded rerun of the existing
  `examples/15_webgpu_feasibility/out/native_multi_surface_speed.exe
  --backend=vulkan` selected the NVIDIA GeForce RTX 2080 SUPER and successfully
  queried surface capabilities, but produced no device callback within 60
  seconds after submitting its device request. The process was stopped. This
  shared bootstrap failure occurs before the new window service runs, so it
  does not establish a secondary-window presentation or teardown failure.
- The strengthened `--child-smoke` did not complete in this environment. Child
  presentation, native interactive input/resize/close, and recovery therefore
  remain unvalidated; do not treat the earlier primary-only smoke as child
  acceptance.

The production service is compiled but still needs a real Windows interactive
run that opens, types/scrolls, resizes, and closes the child, followed by
macOS/Linux host validation and secondary-surface device-loss evidence.

### Native WebGPU bootstrap diagnostics and child-smoke recheck (Windows, 2026-11-17)

The native SDL3 WebGPU host now logs the beginning and return of its device
request, the returned future ID, callback status/message, surface-capability
failures, and one notice if device creation remains pending after five seconds.
The diagnostic does not change callback mode or event-loop behavior. This makes
interactive console output sufficient to distinguish a call blocked inside
`AdapterRequestDevice` from a pending request whose callback has not completed.

Validation with `C:\odin\odin.exe` (`dev-2026-11-nightly:08539cd`) on Windows:

- `odin test runtime -collection:alicorn=.` passed all 363 tests.
- `odin check host/sdl3 -collection:alicorn=. -no-entry-point` passed.
- `examples/16_native_webgpu_ui` built optimized with the pinned AccessKit
  compiler arguments.
- The one-frame `--smoke --backend=vulkan` exited 0 and logged a successful
  device callback on the NVIDIA GeForce RTX 2080 SUPER.
- The strict `--child-smoke` exited 0 on both Vulkan and D3D12. This smoke only
  succeeds after primary and child presentations complete and both queue
  submissions drain, then follows normal teardown.
- An initial non-interactive pipe capture withheld output and was stopped;
  rerunning in an interactive PTY showed device initialization completing and
  the smoke exiting successfully. The earlier pipe capture is inconclusive; its lack of output did not
  reproduce as a native device-request failure.

This establishes a basic Windows secondary-surface presentation and normal
teardown path. It does not establish physical child-window interaction, resize
or close behavior, genuine driver-initiated device loss, or macOS/Linux
secondary-window support. A direct `odin test host/sdl3` invocation could not
start its test process in this environment (Windows loader exit
`0xC0000135`); the package check and optimized native example build passed.

### Native AccessKit extraction and WebGPU host integration (Windows, 2026-11-17)

The native semantic projection and AccessKit adapter now live in
`host/sdl3/accessibility`, outside the SDL_GPU renderer package. A narrow
`native/sdl_gpu/accessibility_compat.odin` shim keeps existing SDL_GPU call
sites stable. The native WebGPU application initializes AccessKit for each
primary or secondary SDL window, synchronizes the retained semantic snapshot,
routes actions and focus, and shuts the adapter down before destroying its
Hosted_Runtime. Platform preparation happens before the first native window is
created. If adapter setup fails, the visual app remains available without
native accessibility.

Validation with Odin `dev-2026-11-nightly:08539cd` on Windows:

- `odin test host/sdl3/accessibility` passed all 22 tests with the pinned
  AccessKit collections and linker flags.
- `odin check host/sdl3` and `odin check native/sdl_gpu` passed; the latter
  emitted only the existing large-stack-local warnings from secondary-window
  tests.
- `odin test native/sdl_gpu` passed all 172 tests in 4m19s using one test
  thread, random seed 1, and `-o:speed`. Together with the 22 tests in
  `host/sdl3/accessibility`, that validates the moved package and the retained
  SDL_GPU compatibility surface across all 194 tests. The first default
  12-thread attempt had been stopped before its summary; the deterministic
  rerun completed successfully.
- The optimized `examples/16_native_webgpu_ui` build passed with
  `-define:WGPU_SHARED=true`. Static wgpu-native and AccessKit each bring a
  Rust runtime defining `rust_eh_personality`; the shared Odin wgpu-native
  import library avoids that duplicate symbol on Windows.
- The Vulkan primary smoke and D3D12 primary-plus-child smoke exited 0 with
  normal queue-drained teardown. The shipped example output needs both
  `SDL3.dll` and Odin's `wgpu_native.dll`; `tools/build_examples.ps1` now copies
  those dependencies for this example.
- The legacy SDL_GPU native probe also built successfully with the same pinned
  AccessKit configuration.

This is build and startup evidence, not physical UI Automation or screen-reader
validation. Windows accessibility actions through assistive technology, macOS
build and VoiceOver validation, and the rest of the native physical-input
acceptance matrix remain open. The Windows shared-library workaround is not yet
validated on macOS or other architectures.

### Exact-head Windows and browser recheck (`ef6c05b`, 2026-11-17)

On Windows x64 with Odin `dev-2026-11-nightly:08539cd`, the following exact-head
checks passed:

- `tools/check.ps1 -Odin C:\odin\odin.exe` completed successfully. It still
  reports the existing large-stack-local warning for SDL_GPU secondary-window
  test values.
- `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe` built the
  `js_wasm32` `ui.run` consumer; `node tools/test_webgpu_ui_host.js` passed all
  9 browser-host lifecycle and clipboard tests.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` rebuilt
  the native fixtures and browser renderer fixture. The D3D12 and Vulkan
  readback/cache-pressure smokes passed on the NVIDIA GeForce RTX 2080 SUPER.
- The D3D12 resize-during/after-motion smoke passed. Compositor destruction and
  reconstruction produced pixel-identical output from retained CPU products.
- The D3D12 two-surface Hosted_Runtime smoke passed independent input/focus,
  synthetic text/IME, resize, presentation, and queue-drained teardown checks.

At the time of this recheck, the `ef6c05b` Windows foundation and Linux WebGPU
CI jobs had passed; the macOS foundation and macOS packaging jobs were still
queued ([foundation](https://github.com/samanshaiza004/alicorn/actions/runs/44127379589),
[packaging](https://github.com/samanshaiza004/alicorn/actions/runs/44127379537)).
This is exact-source automated and physical Windows GPU evidence; it does not
trigger genuine driver/OS device loss, establish physical Linux/Wayland or
macOS behavior, compare production Scratchpad/Punks workloads, or measure
input-to-photon latency. Those acceptance items remain open. The feasibility
build also exposed a missing ignore entry for its generated accessibility DOM
copy; `examples/15_webgpu_feasibility/.gitignore` now covers that build output.

### Browser accessibility allocator and focus fixes (Windows, 2026-11-17)

A fresh load of Example 17 initially failed on its first scheduled browser
frame with `RuntimeError: unreachable` in the WASM allocator. The accessibility
DOM projection serialized its bounded JSON using `context.temp_allocator`, but
released the resulting byte slice through the default allocator. The same
allocator mismatch existed in its unavailable-projection fallback and in the
oversized-JSON cleanup path. All three now release the slice through the
allocator that created it; the host accessibility tests explicitly exercise
temporary-allocator payload and JSON ownership.

Live browser interaction also exposed an Odin formatting issue in the DOM focus
handoff: literal braces in the JavaScript `focus({preventScroll:true})` call
were parsed as format directives. The format string now escapes those braces.

Validation on Windows x64 with Odin `dev-2026-11-nightly:08539cd`:

- `tools/check.ps1 -Odin C:\odin\odin.exe` passed, including the WASM
  package-boundary build and host checks. Existing large-stack-local warnings
  in SDL_GPU secondary-window tests remain.
- `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe` built the
  browser consumer; `node tools/test_webgpu_ui_host.js` passed all 9 tests.
- `odin test host/web -collection:alicorn=.` passed all 14 tests. A new pure
  helper regression checks the exact focus scripts for both the canvas and
  hidden textarea, including the literal `preventScroll` options object.
- In a fresh browser load, WebGPU UI initialization, clicking into the text
  input, DOM focus transfer, ASCII input, and Unicode input (`é🌍`) all worked;
  the retained accessibility value updated and no new runtime error appeared.

This closes the reported first-frame allocator crash and exercises the browser
text-input focus path on this Windows browser/device. It does not establish
physical macOS/Linux browser behavior, real assistive-technology behavior, or
the remaining native device-loss and migration acceptance gates.

### Browser semantic text-value delivery (Windows, 2026-11-17)

The accessibility DOM correctly converted textbox input into a semantic
`Set_Value` request, but the hosted browser path only scheduled a frame; it did
not invoke the application callback that drains queued domain actions. The
request therefore remained queued and the controlled application buffer stayed
unchanged. `hosted_runtime_accessibility_action` now calls `on_wake` on the
owner thread when an action is queued for application handling. Runtime-owned
Press/Focus actions still use their direct interaction path and do not call
the application callback. Example 17 drains and destroys semantic request
events, applying `Set_Value` to its app-owned text buffer.

Validation on Windows x64 with Odin `dev-2026-11-nightly:08539cd`:

- `odin test runtime -collection:alicorn=.` passed all 363 tests, including a
  regression proving queued values reach `on_wake` while realized Press stays
  runtime-owned.
- `odin test host/web -collection:alicorn=.` passed all 14 tests.
- `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe` succeeded;
  `node tools/test_webgpu_ui_host.js` passed all 9 tests.
- Full `tools/check.ps1 -Odin C:\odin\odin.exe` passed. It emits the existing
  large-stack-local warnings for SDL_GPU secondary-window test values.
- After reloading the local Example 17 browser page, setting the accessible
  textbox to `WebGPU semantic input` updated its semantic value and the focused
  textbox state.

This verifies the DOM action-to-application-state path in the local browser,
not physical screen-reader interoperability. Physical assistive-technology
validation and the other Phase 6/overall migration gates remain open.

### Hosted application wake delivery to WebGPU hosts (Windows, 2026-11-17)

The Hosted_Runtime had a tested `hosted_runtime_deliver_wake` API, but neither
production WebGPU host consumed its posted wake notification. As a result,
worker completions could schedule a frame without invoking application
`on_wake`. The SDL3 host now delivers queued notifications when its registered
event is consumed. The browser host records the posted wake and delivers it
from the next scheduled owner-thread step. Wake state is not polled in the
shared presenter or on idle frames. The SDL3 AccessKit event path also delivers
application-owned semantic requests after moving the platform action queue
into Runtime. Browser semantic actions continue to use the same request-drain
callback.

Validation on Windows x64 with Odin `dev-2026-11-nightly:08539cd`:

- Runtime tests verify owner-thread wake delivery and application-owned
  semantic request delivery; presentation-host tests pass.
- The SDL3 WebGPU host and AccessKit paths compile and run through the full
  Windows `tools/check.ps1` suite. The native application example exposes an
  app-owned wake callback probe, and an SDL event-queue regression uses the
  production registered-event callback and event handler to verify that a
  queued notification invokes `on_wake` once on the owner thread (11 SDL3 host
  tests passed).
- The browser `Set_Value` smoke, browser host tests, and `js_wasm32` Example 17
  build pass after the host-specific wake routing change.

This is callback-path and host-scheduling evidence, not a physical worker
thread stress test, native screen-reader validation, or a macOS/browser parity
claim. Those checks remain open.

### Shared device-loss reason policy (Windows and `js_wasm32`, 2026-11-17)

The native and browser WebGPU host callbacks now share the recovery policy's
reason classifier. `.Destroyed` (explicit `DeviceDestroy`) and
`.CallbackCancelled` do not enter automatic recovery; `.Unknown`, `.Undefined`,
and `.FailedCreation` follow the bounded recovery path. This keeps intentional
teardown and callback cancellation distinct from recovery policy decisions;
those decisions do not prove that a loss originated with the OS or driver.

Validation on Windows x64 with Odin `dev-2026-11-nightly:08539cd`:

- The presentation-host suite passed all 6 tests, including the explicit
  reason-classification cases.
- The SDL3 host suite passed all 11 tests; `odin check host/sdl3` passed with
  the pinned AccessKit and AccessKit C collections.
- `odin check host/web -target:js_wasm32 -no-entry-point` passed after wiring
  the browser callback to the shared classifier.

This tests policy routing, not a physical GPU reset, driver callback ordering,
or successful OS-initiated loss recovery. Synthetic callback evidence and
intentional-destroy evidence remain separately labeled in the native recovery
report.

### Solid surface translation and clip retention (Windows, 2026-11-17)

The WebGPU solid renderer now keeps surface geometry in local physical-pixel
coordinates and supplies translation through a compact per-draw instance
buffer. Clip rectangles are applied as draw scissors, including when a prepared
full-display mesh is rendered into a cropped capture. The mesh fingerprint no
longer includes translation, clip, or target dimensions; surface content,
ordering, and display scale still invalidate the retained mesh. This keeps
surface motion, clip changes, and target resizing out of solid vertex rebuilds
while preserving the existing paint order and runtime-owned source data.

Validation on Windows x64 with Odin `dev-2026-11-nightly:08539cd`:

- `odin test renderer/cpu` passed all 22 tests, including local unbounded
  geometry and fingerprint stability for translation, clip, and target-size
  changes.
- `odin check renderer/webgpu -no-entry-point` passed.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` built the
  native fixtures and shared `js_wasm32` renderer fixture.
- The full feasibility readback smoke passed on the NVIDIA GeForce RTX 2080
  SUPER with both D3D12 and Vulkan. It verifies that translated and clipped
  surfaces produce the expected pixels, target resizing uploads viewport data
  without rebuilding vertices, and both cropped captures remain pixel-equal
  to their corresponding regions of the full render.
- The retained solid cache reports one initial vertex upload (648 bytes) and
  one 24-byte transform upload; a later translation-plus-clip update performs
  zero mesh rebuilds and zero vertex uploads and re-uploads only the 24-byte
  transform buffer. The renderer's translation channel is independently
  checked for no upload on an unchanged repeat.
- `tools/test.ps1`, `tools/check.ps1`, and the Node WebGPU host, scheduler,
  patch, and accessibility-DOM tests passed. These counters come from a fresh
  rebuild and rerun on the committed fixture head rather than the earlier
  diagnostic pass.
- `git diff --check` passed.

The browser target compiled, but a live browser run was not performed in this
environment because no Chrome or Edge executable was available on `PATH` or in
the standard Windows install locations. Browser GPU execution of the new
transform and crop path, macOS/Linux native validation, and performance timing
remain outstanding. This is a retained-renderer optimization and test slice;
it does not complete the SDL_GPU removal or any later migration phase gate.

The browser gap in that paragraph was closed on 2026-11-19. The staged
`js_wasm32` fixture ran in the user's browser WebGPU session and passed
`solid_motion=true`, `crop_a=true`, and `crop_b=true`; see
[Live browser feasibility execution](#live-browser-feasibility-execution-windows-browser-2026-11-19)
below.

### Live browser feasibility execution (Windows browser, 2026-11-19)

The 2026-11-17 transform/crop change compiled for `js_wasm32` but had no live
browser run. The staged fixture was served over localhost and opened in
Helium/Chrome 143 on Windows x64. The full evidence is in
`docs/validation/webgpu-feasibility-browser-windows-2026-11-19.md`, with the
console capture in `docs/validation/raw/webgpu-feasibility-browser-2026-11-19.txt`
and a screenshot in
`docs/validation/assets/webgpu-feasibility-browser-2026-11-19.png`.

The browser session initialized a WebGPU adapter and device, then reported
`fallback=false vendor=nvidia architecture=turing` with adapter info
`backend=WebGPU type=Unknown`. Dawn's internal D3D12/Vulkan choice is not exposed
to page JavaScript, so no OS-backend claim is made. The fixture's asynchronous
readback matrix passed in full: core, compositor (`solid_motion=true`,
`crop_a=true`, `crop_b=true`), effects, rounded accessibility material, and
custom-geometry translation/opacity. Solid counters matched the native
slice: one 648-byte vertex upload and one 24-byte transform upload initially,
zero mesh rebuilds and zero vertex uploads after translation/clip, one 24-byte
transform upload, and two viewport updates with no geometry uploads on target
resize. Backdrop capture/filter/composite, two-marker prefix composition,
over-budget fallback parity, and completion-driven retirement also passed.

The page settled to demand-driven idle after 3 frame requests (1 initialization
wake), and returned to idle after two canvas resize clicks, reaching 9 frame
requests without a continuous animation loop. The only console issues were an
absent `favicon.ico` (404) and Chromium's Windows `powerPreference` warning; no
WebGPU uncaptured error, unhandled rejection, or page runtime error was logged.

This is correctness and lifecycle evidence on one browser/OS/GPU. It does not
classify physical acceleration, measure performance, exercise browser device
loss or wasm loss recovery, or test macOS/Linux browsers. The staged wasm was
built from the last code-changing commit (`40afdff`); HEAD differed only in
documentation, and the recorded artifact hash identifies the exact bytes.

### Interactive native WebGPU `run` input and accessibility (Windows, 2026-11-19)

`examples/16_native_webgpu_ui` was built optimized with the shared wgpu-native and
pinned shared AccessKit configuration, then driven on the interactive desktop on
D3D12 and Vulkan by `tools/validate_native_webgpu_ui.ps1`. Real `SendKeys` and
`SendInput` events cleared and typed into the text field, delivered a U+00E9
codepoint, cycled Tab/Shift+Tab focus, activated the auxiliary-window button
with Space, resized the auxiliary window, closed it, and verified the primary
text state survived. UIA exposed the full window tree with `Invoke`, `Value`,
and `Text` patterns, and incremental status updates after UIA activation were
read back live. Windows closed with `WM_CLOSE` and both processes exited 0.

Evidence is in
`docs/validation/native-webgpu-ui-interactive-windows-2026-11-19.md`, with raw
logs and UIA trees under `docs/validation/raw/` and `PrintWindow` captures under
`docs/validation/assets/`. UIA reports the buttons as not keyboard-focusable
even though Tab focuses them, which is recorded for the accessibility follow-up.
IME composition, clipboard shortcuts, menus/titlebars, and Narrator/NVDA speech
were not tested; the fixture has no clipboard or menu control.

### Same-workload native CPU comparison (Windows, 2026-11-19)

`tools/bench_webgpu_vs_sdlgpu.ps1` now builds one fixture executable containing
both paths and runs the same retained-control scene and retained-motion scene
five times each through SDL_GPU/D3D12, WebGPU/D3D12, and WebGPU/Vulkan. The
recorded metrics are the existing host CPU wall-time stages: application
build/runtime step, renderer encode, submit call, present call where available,
and submission counts. The original slice did not expose WebGPU's app-level
text/vertex upload counters through the shared presenter and lacked SDL_GPU
vertex byte counters, so those metrics were recorded only where available. The
matched matrix below adds a read-only presenter stats accessor and SDL_GPU byte
counters without changing renderer behavior.

The full table and boundary notes are in
`docs/validation/webgpu-vs-sdlgpu-perf-windows-2026-11-19.md`. The retained-motion
configurations did not perform identical per-frame application work: WebGPU
presented retained frames without re-describing on each motion frame while
SDL_GPU rebuilt the description, so that row is explicitly non-equivalent. No
GPU timestamps, queue-completion latency, display pacing, or visible latency
were measured, and this does not establish performance parity or a WebGPU win.

### Matched-description workload matrix (Windows, 2026-11-19)

`benchmarks/workload_matrix` drives one scene through SDL_GPU/D3D12,
WebGPU/D3D12, and WebGPU/Vulkan with asserted description counts. The harness
(`tools/bench_webgpu_vs_sdlgpu.ps1 -Matrix`) covers seven scenarios: identical
descriptions, transform-only motion, color animation, localized layout change,
scroll at 1k/10k items, simultaneous multi-window retained motion, and settled
idle. It produced 131 expectations (129 PASS, 2 FAIL) over five runs per
scenario and renderer.

The matched motion result supersedes the earlier unmatched-motion caveat: both
backends described once and presented retained frames (36 SDL_GPU, 47 WebGPU
D3D12, 43 WebGPU Vulkan). The two failures are retained-work findings on the
SDL_GPU reference path. Identical descriptions re-uploaded solid geometry on
every submitted frame (32 uploads / 34,560 bytes) while WebGPU uploaded once
(1 / 1,080 bytes). Transform-only motion re-uploaded solid geometry for every
retained frame (36 uploads / 38,880 bytes) while WebGPU made zero solid mesh
rebuilds, zero solid vertex uploads, and 47 small transform-buffer updates
(1,880 bytes). Text, icon, image, and custom-surface geometry were retained on
both paths. Scroll at 10,000 items produced exactly the same retained runtime
work and renderer upload counts as 1,000 items. A localized layout change
retained unaffected text geometry but re-visited about 17 layout nodes per
frame, recording a runtime-layout locality opportunity rather than a backend
difference. The settled interface presented one frame, delivered zero
application wakes, and idled for the observation window on both hosts.

The full matrix, metric availability, p50/p95/p99 tables, PASS/FAIL evidence,
machine specification, and confounders are in
`docs/validation/webgpu-vs-sdlgpu-workload-matrix-windows-2026-11-19.md`. Raw
harness output and the feasibility readback cross-check are under
`docs/validation/raw/`. This remains an app-level CPU and retained-work
comparison: no GPU timestamps or visible latency were measured.

### Cross-platform CI feasibility matrix (macOS, Linux, headless browser, 2026-11-19)

`b0adab5455fe696ad61f3d243394381dd330a7f8` adds two GitHub Actions workflows
and extends the existing Linux one; all three build and execute the committed
feasibility fixture:

- `WebGPU feasibility (macOS arm64)` (`webgpu-macos.yml`, run 44550779287)
  builds the native fixture with the pinned Odin/wgpu-native/SDL3 inputs and
  passes the Metal readback, transform/crop, retention, and resize checks on
  `Apple Paravirtual device` (`backend=Metal type=IntegratedGPU`).
- `WebGPU feasibility (Linux)` (`webgpu-linux.yml`, run 44550779384) passes the
  same matrix and cache-pressure probes under Xvfb/X11 with Mesa 26.0.8
  lavapipe (`backend=Vulkan type=CPU vendor=llvmpipe`).
- `WebGPU feasibility (browser)` (`webgpu-browser.yml`, run 44550779291) builds
  `js_wasm32`, serves the staged page, and passes the full browser readback
  matrix in headless Chromium with `fallback=true vendor=google
  architecture=swiftshader`. Chromium's system-Vulkan lavapipe and bundled
  SwiftShader-Vulkan launch profiles reached the page but reported a lost
  device; the ANGLE/SwiftShader profile is the recorded passing path.

Renderer cache counters match the Windows NVIDIA browser run exactly (mesh,
vertex, transform, atlas, image, custom-surface, backdrop, and cache-pressure
counters). Surface format counts differ by backend (1 Chromium, 2 Linux
Vulkan, 4 Metal), and the custom-geometry `moved_pixel` differs by one LSB
across adapters; the probe's boolean comparison passes everywhere.

The macOS job needs `-define:WGPU_SHARED=true` because AccessKit and static
wgpu-native duplicate `rust_eh_personality` under ld64. `tools/common.sh` now
selects the shared Odin dylib and embeds its rpath for macOS native builds;
`tools/build_native_release.sh` opts packaged apps back into the static
contract so bundles do not embed developer-machine rpaths.

Limits: every CI adapter is software or paravirtualized. There is still no
hosted hardware-GPU, physical-driver, Wayland, genuine device-loss, Firefox,
Safari, or performance evidence. The first macOS arm64 scheduling attempt never
acquired a runner; the rerun passed. Details and raw logs are in
`docs/validation/webgpu-feasibility-ci-crossplatform-2026-11-19.md`.

### Regression protection for the migration branch (2026-11-19)

Four small guards keep the validated configurations from silently diverging
while the branch is unmerged:

- **Device-loss probe link contract.** `tools/validate_wgpu_native_device_loss_macos.sh`
  previously invoked `odin build` directly and omitted the standalone AccessKit
  collections, so the macOS foundation job failed with
  `Unknown library collection: 'accesskit'`. It now builds through
  `alicorn_odin_with_linker_flags`, patches both the pinned
  `libwgpu_native.a` and `libwgpu_native.dylib`, and links the shared dylib
  (the same contract the fixture uses, since AccessKit + static wgpu-native
  duplicate `rust_eh_personality`). It refuses the static packaging opt-out
  with an explicit message. The `webgpu-macos.yml` job runs the script with
  `--build-only` (five probe configurations compile; no Rust rebuild and no
  probe execution), while `foundation-macos.yml` continues to run the full
  patched probe. CI therefore exercises the build path on every relevant push
  and the patched callback path in the foundation job.
- **Static/shared wgpu pairing.** The macOS WebGPU job now builds the native
  fixture with shared wgpu-native and a packaged app through
  `tools/build_native_release.sh` (static wgpu-native) in the same job.
  `build_native_release.sh` additionally fails fast if the built package
  executable carries an `LC_RPATH` other than `@executable_path`,
  `@loader_path`, or a system path, catching a leaked developer-machine rpath
  before `package_macos.py` bundles it. The Windows fixture build script now
  documents the same split (static default, `WGPU_SHARED=true` plus
  `wgpu_native.dll` for AccessKit consumers).
- **Weekly gate.** `webgpu-macos.yml`, `webgpu-linux.yml`, and
  `webgpu-browser.yml` also run on a Monday 04:17 UTC cron in addition to
  branch pushes and `workflow_dispatch`. The matrix costs roughly six runner
  minutes. These become master gates when `codex/webgpu-phase0-feasibility`
  lands; they are deliberately not enabled for master yet.
- **UIA focus action.** See the next section.

### UIA `IsKeyboardFocusable` for native buttons (Windows, 2026-11-19)

The interactive validation recorded UIA reporting `IsKeyboardFocusable=false`
for buttons that Tab and Shift+Tab genuinely focus and Space activates. The
mapping chain was alicorn semantics → odin-accesskit → AccessKit's UIA adapter:

- AccessKit's UIA adapter maps `UIA_IsKeyboardFocusablePropertyId` to
  `NodeRef::is_focusable()`, which is
  `supports_action(Action::Focus) || is_focused_in_tree()`.
- The pinned example in `odin-accesskit` adds both `Action::Focus` and
  `Action::Click` to its button precisely so this property is true.
- Alicorn's `semantic_description_defaults` emitted only `.Press` for buttons
  (and `.Select` for tabs); only text fields emitted `.Focus`. The adapter was
  correct; alicorn under-described the control.

`runtime/semantics.odin` now adds `.Focus` for every enabled `d.focusable`
control before the built-in kind switch. Disabled controls stay Focus-free,
matching their retained `node.focusable == false`. The regression test
`test_focusable_controls_advertise_the_focus_action` checks both the action set
and that the advertised Focus action routes through `semantic_action_request`.
`tools/validate_native_webgpu_ui.ps1` now records a
`buttons report IsKeyboardFocusable` PASS/FAIL row instead of only dumping the
tree.

The consumer-side finding is tracked in
[Carnival-Science/Alicorn#208](https://github.com/Carnival-Science/Alicorn/issues/208)
and closes with this branch. The separate intermittent `verify-uia.ps1`
window-selection failure is documented upstream in
[samanshaiza004/odin-accesskit#1](https://github.com/samanshaiza004/odin-accesskit/issues/1).
That issue records the `EnumWindows` sequence (application, console, and
default IME windows) proving the property failure was the dependency's example
check selecting the wrong window, not an Alicorn regression.

Validation on Windows x64 with Odin `dev-2026-11-nightly:08539cd`, the NVIDIA
GeForce RTX 2080 SUPER, and shared wgpu-native/AccessKit:

- `odin test runtime -collection:alicorn=.` passed all 364 tests (including the
  new focus-action regression); `host/sdl3/accessibility` passed all 22 tests.
- The rebuilt `examples/16_native_webgpu_ui` passed the full UIA harness on
  D3D12 and Vulkan with the new row:
  `buttons=[Increment,Queue application wake,Open auxiliary window] notFocusable=[]`.
  `Invoke`, `Value`, and `Text` patterns were unchanged.
- Post-fix initial trees are recorded in
  `docs/validation/raw/native-webgpu-ui-uia-focus-d3d12-2026-11-19.txt` and
  `...-vulkan-...txt`; logs in the matching `...-run-...` files.

The shared `host/sdl3/accessibility` projection is used by both the SDL_GPU and
WebGPU hosts, so the fix is renderer-independent; no SDL_GPU-specific UIA run
was needed to change the value. The project still lacks Narrator/NVDA speech
validation.

### Build-time opt-in and final pre-merge corrections (2026-11-19)

Renderer selection is now opt-in at build time as well as at runtime:

- The native WebGPU entry moved from package `ui` to
  `alicorn:ui/webgpu` (`webgpu.run`, formerly `ui.run_webgpu`). Every native
  `alicorn:ui` consumer no longer compiles the WebGPU host.
- The SDL3 clipboard implementation, its `UI_Host_Services` adapter, and the
  SDL event/pointer/text mapping helpers moved into the WebGPU-agnostic
  `host/sdl3/clipboard` and `host/sdl3/input` packages. `native/sdl_gpu`
  imports those directly; `host/sdl3` remains the WebGPU host.
- `tools/test_sdl_gpu_without_wgpu_native.ps1` proves the isolation by hiding
  Odin's pinned `vendor/wgpu/lib`, failing a WebGPU negative control, then
  building and smoking SDL_GPU consumers before restoring the library. The
  foundation Windows workflow now runs it. `docs/getting-started.md` records
  wgpu-native as a WebGPU-only prerequisite.
- The hosted key contract is opaque again. `hosted_runtime_key` only forwards
  the host event; the new typed
  `hosted_runtime_application_key(host, key, event)` owns text-field and
  interaction-scope preemption. `docs/hosted-runtime.md` documents both.
- The three WebGPU workflows share one comprehensive path filter, so changes
  to `renderer/**`, `runtime/**`, `ui/**`, `host/**`, and `native/**` no
  longer bypass them until the weekly run.
- The macOS static-wgpu packaging job builds `01_hello` (no wgpu) and is now
  labelled as proof that the existing packaging contract has not regressed,
  not as WebGPU application packaging evidence. Phase 4 requires packaging and
  launching an actual WebGPU application.

The full procedure, import-graph audit, command output, and verification
matrix are in
[the corrective-pass record](validation/webgpu-opt-in-corrective-pass-2026-11-19.md).

### Stage A slice 1: hosted close deferral and file dialogs (Windows, 2026-11-19)

Scratchpad's WebGPU dogfood exposed three plumbing gaps between
`native/sdl_gpu` and the hosted stack. This slice closes them without changing
default behavior:

- `Hosted_Runtime_Config` now carries `on_menu_command`,
  `on_close_requested`, and `on_dialog` alongside the existing drag, scroll,
  text-input, and scheduled-wake callbacks. `Hosted_Run_State` and
  `run_hosted_config` forward all of them, and `ui/webgpu.run` (plus `ui.run` for
  parity) accepts the same optional named parameters. Callback shapes match the
  native `Application` so Scratchpad handlers can move 1:1.
- `hosted_runtime_request_close` applies `.Allow`/`.Defer` semantics.
  `Hosted_Host_Services.quit` is the hosted equivalent of
  `Application_Services.quit`; `hosted_quit_request` completes a deferred close.
  The SDL3/WebGPU event host returns the new `Close_Deferred` result instead of
  `Close_Requested` and keeps the window alive. A missing callback still closes
  immediately.
- File dialogs are a `Hosted_Host_Services.dialogs` service.
  `hosted_dialog_show_file` copies a `File_Dialog_Request`; the host delivers a
  `File_Dialog_Result` through `hosted_runtime_dialog` and `on_dialog`. The
  request/result vocabulary (`Dialog_ID`, `File_Dialog_Kind`, `Dialog_Filter`,
  `Dialog_Status`) lives in `runtime/dialogs.odin`, and the headless fake
  backend moved there too.
- The SDL3 dialog bridge moved from `native/sdl_gpu/dialogs.odin` to the
  renderer-agnostic `host/sdl3/dialogs` package. The native host keeps thin
  aliases plus its breadcrumb adapter; `host/sdl3` constructs the same bridge per
  window (primary and secondary). There is one `SDL_ShowFileDialogWithProperties`
  implementation, not two. The browser host leaves `dialogs` and `quit` empty in
  this slice; the TODO is recorded in `ui/run_webgpu_browser.odin`.
- `examples/16_native_webgpu_ui` now exposes an "Open file dialog" button and
  reports `Hosted dialogs: available`; `--defer-close` exercises the deferred
  close handshake without changing the UIA validator's default close path.

Validation on Windows x64 (NVIDIA RTX 2080 SUPER, D3D12):

- `odin test runtime` passed all 388 tests (new close/menu/dialog/scroll-capture
  and fake-dialog coverage); `ui` passed 50, `host/sdl3` 2,
  `host/sdl3/dialogs` 5, `host/web` 14, `host/presentation` 6, `testui` 13,
  `native/sdl_gpu` 169, and `native/scroll_capture_tests` 6.
- `examples/15_host_owned_sdl_gpu` and `examples/16_native_webgpu_ui` built;
  `16_native_webgpu_ui --backend=d3d12 --smoke` exited 0. The `js_wasm32`
  package-boundary build passed.
- The native dialog fake fixture built and printed PASS; the SDL_GPU
  text-input contract and restoration suite passed.

Slices 2 (native menus) and 3 (titlebar chrome) can now use
`Hosted_Runtime_Config.on_menu_command` and `hosted_runtime_menu_command` for
command routing, and `Hosted_Host_Services.quit` for close completion. The
remaining menu/chrome gap is host-side: menu descriptions, accelerators, and
native chrome metrics/layout are still not part of `Hosted_Host_Services`.

### Stage A slice 2: shared native menus (Windows, 2026-11-19)

Native menus now use one renderer-agnostic implementation for both SDL3 hosts:

- The menu model moved to `runtime/menus.odin`: `Menu`, `Menu_Item`,
  `Menu_Item_Kind`, `Menu_Shortcut`, `Menu_Modifier(s)`, and
  `Menu_Presentation`, plus the shared accelerator matcher, enabled gate, and
  shortcut-label formatter. `native/sdl_gpu`'s `Application_Menu*` vocabulary
  is now a set of aliases, and its matching/dispatch/label code delegates to
  the runtime instead of keeping a second copy.
- `host/menus` owns the per-surface `Menu_Service` and the SDL3 platform
  adapters. Windows builds an HMENU tree and attaches it to the SDL window with
  `SetMenu` (system decorations), refreshing borrowed enabled/checked state on
  `WM_INITMENUPOPUP` and queueing `WM_COMMAND` selections for safe-point
  dispatch. macOS builds an NSMenu main menu and queues selected tags. Linux
  keeps descriptions as semantic accelerator metadata. There is one adapter
  implementation, not one per host.
- `Hosted_Runtime_Config` gained `menus` and `menu_presentation`; the runtime
  copies the borrowed slice and `hosted_runtime_menu_command` now applies the
  shared enabled gate before its `.Native_Command` cause. `Hosted_Run_State`,
  `ui.run`, `ui/webgpu.run`, and the browser `ui.run` expose matching
  parameters. `SDL3_WebGPU_Application` matches accelerators after overlay-key
  handling and before application key/text routing and skips matching during
  IME composition, in the same order as the native host.
- Accelerator semantics are preserved exactly: a printable key compared
  case-insensitively, an exact modifier set, Primary = Ctrl/Command and
  Super = Win/Control, disabled commands never match, repeat transitions are
  consumed without a second dispatch, and nested submenu items match
  depth-first.
- `examples/16_native_webgpu_ui` now supplies a Scratchpad-shaped menu tree
  (File/Edit/View/Help, a nested recent submenu, separators, checked and
  disabled commands, and one direct top-level command) and a `--menu-smoke`
  mode. It synthesizes Ctrl+X, Ctrl+V (disabled), Ctrl+S (disabled),
  Ctrl+Shift+P, and Ctrl+Y key events and verifies the dispatched sequence. The
  same smoke passes on the SDL_GPU reference path.

Validation on Windows x64 (NVIDIA RTX 2080 SUPER, D3D12):

- `odin test runtime` passed all 389 tests (including hosted borrowed-state
  menu gating); `ui` 50, `host/sdl3` 2, `host/sdl3/input` 8,
  `host/sdl3/clipboard` 3, `host/sdl3/dialogs` 5, new `host/menus` 6,
  `host/web` 14, `host/presentation` 6, `testui` 13, `theme` 37,
  `native/sdl_gpu` 169, and `renderer/cpu` 22.
- `examples/15_host_owned_sdl_gpu` and `examples/16_native_webgpu_ui` built.
  `16_native_webgpu_ui --smoke --backend=d3d12` exited 0, and
  `--menu-smoke --smoke --smoke-hold-ms=1200 --backend=d3d12` printed
  `menu_smoke PASS commands 3`. The same menu smoke printed PASS through
  `--backend=sdl-gpu`, proving identical command routing on both hosts.
- The `js_wasm32` package-boundary build passed. `host/menus` also type-checks
  for `darwin_arm64` and `linux_amd64`; macOS NSMenu behavior is compile-check
  only (no local Mac), and Windows adapter behavior is covered by a local test
  that attaches an HMENU to a hidden SDL window and verifies borrowed-state
  refresh and selection queueing.
- The existing `tools/validate_native_webgpu_ui.ps1` D3D12 interactive pass
  still reports `failures=0` with the native menu bar attached, including the
  auxiliary-window lifecycle and UIA activation checks.

Slice 3 (titlebar chrome) still needs: hosted window-decoration policy
(`Integrated_Title_Bar`/`Content_Title_Bar`) and chrome metrics/layout in
`Hosted_Runtime_Config`; Windows menu-label painting and hit testing in the
app-authored titlebar band (the current hosted adapter is a system menu bar and
treats `Hidden` as a no-op, matching native system decorations); macOS
full-size-content titlebar coordination; and a shared decision for which host
owns the menu label rectangles inside the chrome.

### Stage A slice 3: integrated titlebar chrome (Windows, 2026-11-20)

The hosted SDL3/WebGPU host now presents the same integrated titlebar contract
as the SDL_GPU reference:

- `Window_Decoration_Mode`, `Window_Chrome_Metrics`,
  `Window_Chrome_Region(_Kind)`, `WINDOW_CHROME_REGION_CAPACITY`,
  `Window_Chrome_Layout`, and `Window_Chrome_Appearance` moved to
  `runtime/hosted_chrome.odin`. `native/sdl_gpu`'s `Application_*` names are
  aliases, so an application maps its chrome callbacks without adaptation.
  `Hosted_Runtime_Config`/`Hosted_Run_State` and all three `ui.run`
  implementations expose `window_decorations`, `window_chrome_height`,
  `window_chrome_metrics`, `window_chrome_layout`, and
  `window_chrome_appearance`. The browser records policy only.
- `Hosted_Runtime` owns `content_inset_top`. Application descriptions receive
  the inset-reduced viewport; logical presentation scale still uses full window
  logical height; pointer and wheel coordinates subtract the inset once and
  input over host-owned chrome is withheld (a captured interaction stays
  clamped until cancellation); the presenter translates app paint below the
  band and appends host chrome paint in native draw order. Host-shaped text
  runs use `Text_Run_Source.Host` and resolve through
  `runtime_host_text_run_set/resolve/release`.
- `host/menus` converges the Win32 HMENU builder and the integrated chrome into
  one adapter/state/subclass. The integrated adapter paints the title, menu
  labels, hover/open/pressed feedback, and caption glyph masks; extends the DWM
  frame; handles `WM_NCCALCSIZE`, `WM_NCHITTEST`, `WM_NCACTIVATE`,
  `WM_DPICHANGED`, `WM_SIZE`, and theme messages; maps finalized app regions
  (splitter hit bounds included) to `HTCLIENT`/`HTCAPTION`; publishes measured
  metrics and inset into the hosted Runtime; and routes app declarations back
  to the Runtime so interactive regions still receive ordinary client input.
  `Window_Chrome_Appearance` resolves to derived band colors and a best-effort
  DWM dark-frame attribute; the native SDL_GPU host itself only paints colors.
- macOS `Content_Title_Bar` gains a compile-checked full-size-content port
  (style-mask coordination, traffic-light metrics, region hit testing, SDL
  hit-test callback). It has not been run on a physical Mac in this slice.
- `examples/16_native_webgpu_ui --titlebar-smoke` declares a connected tab bar
  plus an explicit window-drag region in the authored header. The same mode
  passes on `--backend=d3d12` and `--backend=sdl-gpu`, reporting delivered
  metrics, declared layouts, usable `content_start_x..content_end_x`, and
  pointer delivery. `host/menus` adds a hidden-window regression that sends
  real `WM_NCHITTEST` messages: an Interactive app region returns `HTCLIENT`, a
  Window_Drag region returns `HTCAPTION`, body pixels stay `HTCLIENT`, the
  app-owned header removes the content inset, host-owned chrome reserves it,
  and chrome paint includes shaped label text.

Residual slice-4 work: secondary-window chrome parity (the Windows adapter is
prepared per window, but the fixture and metrics coverage are primary-only),
physical Windows drag/maximize/Snap/high-contrast interaction, physical macOS
validation, and Scratchpad's consumption of the hosted chrome API.

Validation on Windows x64 (NVIDIA RTX 2080 SUPER, D3D12, 2026-11-20):

- `tools/test.ps1 -Odin C:\odin\odin.exe` passed: AccessKit 8, runtime 392,
  host/sdl3 2, host/sdl3/input 8, host/sdl3/clipboard 3, host/sdl3/dialogs 5,
  host/menus 8, host/web 14, ui 50, testui 13, theme 37, renderer/cpu 22,
  native/sdl_gpu 169, native/scroll_capture_tests 6, plus the foundation,
  text-input contract, restoration, and theme CLI checks. The `js_wasm32`
  package-boundary build passed.
- `examples/15_host_owned_sdl_gpu` and `examples/16_native_webgpu_ui` built.
  `16_native_webgpu_ui` ran `--smoke`, `--child-smoke`, `--menu-smoke`, and the
  new `--titlebar-smoke` to exit 0 on both `--backend=d3d12` and
  `--backend=sdl-gpu`. The titlebar smoke reported one delivered metrics
  snapshot, declared layouts, `header_h=32`, usable span `269..575` with visible
  menu labels, and a PASS on both hosts.
- `tools/validate_native_webgpu_ui.ps1 -Backend d3d12` reported
  `failures=0`, including the UIA tree, text field patterns, physical text
  input, Tab order, UIA Invoke, wake delivery, auxiliary open/resize/close, and
  primary-state preservation. Artifacts are under `out/uia-chrome-slice3/`.
- `host/menus` type-checks for `darwin_arm64` and `linux_amd64`, and
  `native/sdl_gpu` type-checks for `darwin_arm64`. The full `host/sdl3` WebGPU
  package could not be type-checked for macOS locally because this Odin install
  does not include the macOS wgpu-native archive. The macOS full-size-content
  path is therefore compile-only: no physical Mac ran this slice, so
  traffic-light placement, drag regions, and fullscreen transitions remain
  unverified.

### Stage A slice 4: secondary-window chrome parity and physical interaction (Windows, 2026-11-19)

Stage A is complete on native SDL3. The hosted stack now covers native menus,
integrated chrome, dialogs, close deferral, and one secondary window with its
own chrome and services; what remains is browser-side and physical-platform
validation.

- `ui/run_native` now bridges `Hosted_Window_Description` onto the reference
  `Application_Window_Description`. Before this slice, `ui.run` never published
  `UI_Host_Services.windows` on the SDL_GPU path, so a hosted child request
  returned `false` silently and the old `--child-smoke` could pass without a
  child. The bridge preserves menus, chrome callbacks (routed with
  `Hosted_Runtime_Config.state`), dialogs, close deferral, and the window
  service. It cannot manufacture a `Hosted_Waker`, so a child `on_start` gets an
  empty waker on the reference path; `ui/webgpu.run` supplies the real one.
- A hosted child owns its own `Hosted_Runtime`, content inset, chrome
  metrics/layout/regions/paint, menu service and accelerator gate, dialog
  bridge, close result, quit service, input/text/focus state, and scheduled
  wake. The SDL3/WebGPU loop steps the child, dispatches its dialogs/menus, and
  arms the earliest primary/child deadline.
- The reference secondary-window loop now re-syncs `chrome_layout` whenever the
  child has a pending frame. Previously an app-authored child header never
  produced drag/interactive regions after its first description.
- A caption double-click that changes zoom can omit `WM_NCLBUTTONUP`. Both the
  hosted and reference Win32 adapters now clear a latched `.Window` gesture when
  the maximized state changes; without this, every later `WM_NCHITTEST`
  returned `HTCAPTION`.
- macOS keeps the reference host's secondary-window policy: AppKit's main menu
  is process-global, so a hosted child leaves menus to the primary window. The
  hosted macOS titlebar now ports the reference pointer-sample pairing
  (hit-test point + button snapshot, press/release matching, consumed-event
  drain, last-point fallback). It is compile-only for `darwin_arm64`.
- `examples/16_native_webgpu_ui --child-chrome-smoke` opens a 760×460 child with
  an integrated titlebar, menu, accelerator, chrome metrics/layout, dialog
  service, and close deferral; it pushes a child-targeted accelerator and close
  request, completes the deferred close through the child quit service, and
  asserts the hosted callbacks. It passes on `--backend=d3d12` and
  `--backend=sdl-gpu`.
- `tools/validate_native_webgpu_chrome.ps1` drives the integrated titlebar with
  real `SendInput`/cursor input: the Window_Drag band returns `HTCAPTION` and
  moves the window, double-click maximizes/restores, the right edge returns
  `HTRIGHT` and resizes, and the three caption buttons minimize/maximize/restore
  and close cleanly. Theme/settings message survival is scripted; Snap Layouts,
  mixed-DPI moves, trackpad inertia, and visual contrast switches are recorded
  as hands-on. It reports `failures=0 pass=15 hands_on=4` on both D3D12 and
  SDL_GPU. See
  [`validation/webgpu-chrome-interactive-windows-2026-11-19.md`](validation/webgpu-chrome-interactive-windows-2026-11-19.md).

Validation on Windows x64 (NVIDIA RTX 2080 SUPER, `fe1dc7f`):

- `tools/test.ps1 -Odin C:\odin\odin.exe` passed: AccessKit 8, runtime 392,
  host/sdl3 2, host/sdl3/input 8, host/sdl3/clipboard 3, host/sdl3/dialogs 5,
  host/menus 8, host/web 14, ui 50, testui 13, theme 37, renderer/cpu 22,
  native/sdl_gpu 169, native/scroll_capture_tests 6, plus the foundation,
  text-input contract, restoration, and theme CLI checks. `host/menus` also adds
  three darwin-only pointer-sample tests (compile-checked, not run on Windows).
- `examples/15_host_owned_sdl_gpu` and `examples/16_native_webgpu_ui` built. The
  example 16 `--smoke`, `--child-smoke`, `--child-chrome-smoke`, `--menu-smoke`,
  and `--titlebar-smoke` modes exited 0 on both `--backend=d3d12` and
  `--backend=sdl-gpu`. Child chrome reported metrics/layouts/menu/deferral on
  both (`layouts=7` hosted, `layouts=2` reference).
- `tools/validate_native_webgpu_ui.ps1` reported `failures=0` on D3D12 and
  Vulkan. Its focus step now attaches to the foreground thread; a terminal
  window holding activation had produced a one-off spurious failure.
- `js_wasm32` package-boundary build passed. `host/menus` type-checks for
  `darwin_arm64`; `native/sdl_gpu` type-checks for `darwin_arm64`. The full
  `host/sdl3` WebGPU package still cannot be type-checked locally because this
  Odin install has no macOS wgpu-native archive.

Stage B entry state: Scratchpad should consume the branch tip after this slice
(`fe1dc7f` plus the docs commit) through `ui/webgpu.run` and
`Hosted_Window_Description`. Its native `Application_Window_Description`
fields map directly: `application.state/title/width/height`, `menus`,
`menu_presentation`, `window_decorations`, `window_chrome_height`,
`window_chrome_metrics/layout/appearance`, and every `on_*` callback become the
description's `title/width/height/always_on_top` plus `config`. That entry state
has since been superseded by Stage B slice 1 below.

### Stage B slice 1: hosted scheduler, synchronous clipboard, file drop, tick, and interaction policy (Windows, 2026-11-20)

Stage B closes the remaining service-shape gaps that blocked a 1:1 mapping from
Scratchpad's native `Application_Services`. The scheduler vocabulary now lives
in `runtime/scheduler.odin`; `native/sdl_gpu` re-exports it with unchanged
`Application_*` names.

```text
Hosted_Host_Services      windows dialogs quit clipboard scheduler
Hosted_Runtime_Config     ... on_scheduled_wake(state, rt, class)
                              on_file_drop(state, rt, path)
                              on_tick(state, rt)
                              interaction_update_policy
                              monotonic_now / monotonic_now_data
UI_Host_Services          clipboard (async) clipboard_text (sync)
                              scheduler windows dialogs quit
```

- `Scheduled_Wake_Class` is `{Frequent, Opportunistic}`. The hosted scheduler
  mirrors the native service one-for-one: one replaceable deadline per class,
  replaceable scheduling, cancel, `Application_Scheduler_Stats`, and a 150 ms
  input-quiet deferral for opportunistic work. The hosted input entry points
  timestamp pointer, key, text, and scroll interaction automatically;
  `hosted_runtime_note_interaction` is available for hosts with additional
  event sources. `hosted_runtime_set_deadline` remains as a legacy
  Frequent-class absolute deadline. Each `Hosted_Runtime` publishes its own
  service, so primary and child surfaces schedule independently, exactly like
  the reference host's per-window `Application_Scheduler`.
- The canonical clipboard service moved to `runtime/clipboard.odin` and
  `host/sdl3/clipboard` now forwards to it. The hosted service is the native
  synchronous shape (`ClipboardGetText`/`ClipboardSetText`); SDL3 hosts install
  the SDL3 implementation for primary and child surfaces. Browser hosts keep
  the asynchronous Web Clipboard service and leave the sync shape empty.
  Scratchpad's existing synchronous call sites work unchanged on native
  WebGPU; browser consumption still needs the async API (Stage C).
- `on_file_drop` mirrors `Application_File_Drop_Proc`. The SDL3 host routes
  `SDL_EVENT_DROP_FILE` through `hosted_runtime_file_drop`, which invokes the
  callback under the `.Host_Event` cause and invalidates the description. The
  browser host has no drop event and records the policy only.
- `on_tick` mirrors `Application_Tick_Proc` at the same 16.67 ms minimum
  cadence. The hosted implementation arms one one-shot deadline instead of the
  reference host's 1 ms delay pump: the callback timing is equivalent, and the
  idle runtime still has no recurring wake. Ticks and scheduled wakes keep
  running while the surface is hidden, as the reference loop does.
- `interaction_update_policy` now reaches hosted descriptions. The hosted
  description loop runs the same bounded four-pass stabilization as
  `native_application_build_until_stable`; `.Correct_After_Interaction`
  requests one corrective pass after a consumed widget interaction. Both
  `ui.run` entry points default to `.Correct_After_Interaction`.
- `ui.run`, `ui/webgpu.run`, and the browser `ui.run` now accept
  `on_scheduled_wake(..., class)`, `on_file_drop`, `on_tick`, and
  `interaction_update_policy`. `UI_Host_Services` adds `scheduler` and the
  synchronous `clipboard_text`, while its existing `clipboard` remains the
  asynchronous UI contract.

Tests cover scheduler arm/cancel/coalescing/class/lateness/deferral, legacy
deadline behavior, tick cadence, file-drop routing (including the SDL3 event
bridge), the clipboard roundtrip through published services, and corrective
versus explicit description policy. `examples/16_native_webgpu_ui
--services-smoke` exercises scheduler, clipboard, file drop, and tick through
`ui.run` on D3D12 and SDL_GPU.

Stage B entry state for the Scratchpad consumption slice: the native
`Application_Services` fields `scheduler`, `clipboard`, `windows`, `dialogs`,
and `quit` map 1:1, and `Application.on_file_drop`, `Application.on_tick`,
`Application.on_scheduled_wake`, and `interaction_update_policy` map 1:1 to the
hosted config/UI run surface. Remaining gaps are browser-only: asynchronous
clipboard consumption, browser file drops, browser menus/dialogs, and browser
close policy.

Validation on Windows x64 (NVIDIA RTX 2080 SUPER, `af28167`):

- `tools/test.ps1 -Odin C:\odin\odin.exe` passed: AccessKit 8, runtime 399,
  host/sdl3 3, host/sdl3/input 8, host/sdl3/clipboard 3, host/sdl3/dialogs 5,
  host/menus 8, host/web 14, ui 50, testui 13, theme 37, renderer/cpu 22,
  native/sdl_gpu 169, native/scroll_capture_tests 6, plus the foundation,
  text-input/navigation, restoration, theme CLI, and `js_wasm32`
  package-boundary checks. The AccessKit native UIA contract passed; its first
  invocation in this session missed the fixture window and was rerun
  successfully.
- `examples/15_webgpu_feasibility/build.ps1` built all native and browser
  fixtures. `examples/16_native_webgpu_ui` built (AccessKit + shared
  wgpu-native) and `--smoke`, `--menu-smoke`, `--titlebar-smoke`,
  `--child-smoke`, `--child-chrome-smoke`, and `--services-smoke` exited 0 on
  both `--backend=d3d12` and `--backend=sdl-gpu`. Services smoke reported
  `frequent=1 opportunistic=1` with both classes, clipboard roundtrip, one
  file drop, and six ticks on both renderers.
- `tools/validate_native_webgpu_ui.ps1 -Executable out\example16.exe -Backend
  d3d12` reported `failures=0` with real UIA and SendInput, including the
  auxiliary window lifecycle.
- `odin check ui -target:js_wasm32` and `odin check host/web -target:js_wasm32`
  passed; `git diff --check` passed.

### Stage B2: hosted workbench first-present fix (Windows, 2026-11-20)

Scratchpad's hosted WebGPU smoke presented its start screen and settings
scene but failed the first frame of every open-document workbench scene:
`Presenter_Failure` with `frames_presented=0`. The same session presented on
SDL_GPU. The Vulkan hosted path initialized its adapter and device but never
completed a first present.

The failure was an encode rejection, not a surface or blend problem. The
workbench paper is a rectangular analytic-relief surface whose connected tab
opens the top optical edge with a gap beginning at the surface's left
coordinate. The shared CPU preflight `Solid_Surface_Vertex_Count` reserves two
quads for that split edge, while `Append_Material_Surface` correctly omits the
zero-width left piece. The WebGPU solid path treated the preflight as an exact
vertex contract (`len != required` -> `Resource_Failure`) and returned
`Render_Failure` before submitting the first frame. SDL_GPU only used the count
to reserve a dynamic array, so it was unaffected. The same encode rejection
explains the Vulkan no-present observation; both backends now pass.

Changes:

- `renderer/webgpu/solid.odin` treats the CPU count as an allocation
  reservation. A smaller emitted mesh is accepted; a larger one grows the
  vertex buffer before upload. The equality assertion is removed.
- `host/presentation/surface_presenter.odin` logs the encode result, command
  count, and display revision when frame encoding is rejected. `host/sdl3/run.odin`
  logs the presentation result, step count, and frames presented. These paths
  previously discarded the stage, leaving only `Presenter_Failure`.
- `examples/16_native_webgpu_ui --workbench-smoke` reproduces the workbench
  paint: connected tabs, a rectangular negative-height analytic-relief paper
  with a left-edge top gap, editor-like text rows, a selected row, and a rounded
  relief sidebar. Before the fix the fixture failed at
  `frame encode failed result Resource_Failure commands 20 revision 2`; after
  the fix it exits 0 on D3D12, Vulkan, and SDL_GPU.
- `renderer/cpu/solid_test.odin` records that the material preflight is an
  upper bound (66 reserved, 54 emitted) for a left-edge gap, so a renderer must
  not require exact equality.

Validation is recorded below after the full suite and Scratchpad end-to-end run.

Validation on Windows x64 (NVIDIA RTX 2080 SUPER, this branch):

- Alicorn suites: runtime 399, host/sdl3 3, host/sdl3/input 8,
  host/sdl3/clipboard 3, host/sdl3/dialogs 5, host/menus 8, host/web 14,
  host/presentation 6, renderer/webgpu 6, ui 50, testui 13, theme 37,
  renderer/cpu 23 (including the new preflight test), native/sdl_gpu 169, and
  native/scroll_capture_tests 6. All passed. `tools/test.ps1` itself stopped at
  its AccessKit native UIA stage (`Accessible Button missing`); the same UIA
  check passed standalone with `UIA PASS` immediately afterward, and the
  Alicorn suites above were run individually with the same arguments.
- `examples/16_native_webgpu_ui` built and its `--smoke`,
  `--workbench-smoke`, `--titlebar-smoke`, `--child-chrome-smoke`,
  `--menu-smoke`, and `--services-smoke` modes passed on both
  `--backend=d3d12` and `--backend=vulkan`; `--workbench-smoke` also passed on
  `--backend=sdl-gpu`. Both hosted backends reported `frames_presented=1` for
  the workbench fixture.
- Scratchpad's dual-renderer frontend (`codex/issue-211-webgpu-frontend` at
  `bfb2aed`, candidate root this branch) passed `smoke --renderer=webgpu` on
  both `--backend=d3d12` and `--backend=vulkan`, including the restored
  two-document workbench session: `publication_rendered`, `wake_observed`,
  `ordered_shutdown`, and `session_restore` were all true for the clean and
  recovery launches. No Scratchpad source or lock file was changed.

## Stage B slice 3: backend-neutral diagnostics parity (2026-11-20)

Stage B was reopened after real-world Scratchpad testing showed that the hosted
WebGPU path had no developer diagnostics: an encode failure produced only
`Presenter_Failure` plus a console line, with no retained state, counters, or
image to investigate. The reference `native/sdl_gpu` host already had all of
it, implemented directly inside its event loop.

### What the reference host actually provides

- `F10` toggles a performance HUD. It is consumed after menu accelerators and
  before app key routing. The HUD classifies the latest wake as `IDLE`, `HOST`,
  `PRESENT`, `APP`, or `SURFACE`, shows one-second build/present/submit/wake
  counters, the last cause and retained-stage work, build/encode/input latency,
  semantic/accessibility activity, the invalidation reason, and a bounded
  activity strip. It is transient solid geometry; it adds no nodes and does not
  change application `Frame_Stats`.
- `F11` toggles retained-bounds inspection: one amber outline per visible paint
  command, appended after application paint. It is non-consuming.
- `F12` requests one capture (repeatable in a run), non-consuming.
- Capture writes `diagnostics.json` (timing percentiles, GPU/renderer counters,
  runtime state), `inspector.txt` (the human-readable retained tree),
  `timeline.json` (the versioned 256-sample flight recorder), `screenshot.ppm`,
  and `windows.json`, plus an opt-in `events.jsonl` breadcrumb recorder.
- Flags: `--diagnostics`, `--capture-after=SECONDS`, `--capture-dir=PATH`,
  `--debug-bounds`, `--diagnostic-events`.
- `Capture` was gated on a presented frame and rendered the screenshot through
  an offscreen SDL_GPU target.

### What moved where

`host/diagnostics` is now the single implementation: recorder/pointer samples,
activity classification, HUD model and 5x7 glyph quad layout, bounds geometry,
timing and text-event telemetry, options/path/bundle handling, JSON/window
writers, timeline export, and breadcrumbs. It imports only
`alicorn:runtime`. `native/sdl_gpu` keeps `Native_*` type aliases and thin
proc shims, its metric capture (SDL_GPU structures), its offscreen PPM capture,
and a quad sink that appends HUD/bounds geometry to its solid mesh. The shared
HUD text now emits one quad per contiguous glyph-row run instead of per pixel,
so the hosted renderer sees ~3x fewer commands for identical pixels.

`Hosted_Runtime_Config` gained `diagnostics_paint` / `diagnostics_paint_data`.
`hosted_runtime_presentation_list` appends those commands after application
paint and host chrome, so diagnostics are part of every `ui/webgpu.run` surface
without application code.

### Hosted wiring

- `host/sdl3/diagnostics.odin` owns options, the recorder, timing aggregation,
  the HUD/bounds paint provider, capture, and backend identity. It is created
  after application init and destroyed after teardown.
- `sdl3_webgpu_application_key_down` calls the diagnostics handler after menu
  keydown/accelerator handling and before Control+Tab/application keys. F10 is
  consumed; F11/F12 are not. This matches `native/sdl_gpu`'s order.
- Overlay frames are host-only re-composites: a presenter overlay-redraw flag
  renders the current retained display without mutating the Runtime, and an
  application display revision is acknowledged once. A visible HUD therefore
  cannot feed a redraw loop or count as application work. Overlay commands are
  staged in one reused host-owned buffer.
- Backend identity is captured from `wgpu.AdapterGetInfo`:
  `"gpu_driver": "webgpu/<backend>"`, a `backend` object (adapter type, vendor,
  device, description), and `backend_counters` groups for solid, text, icons,
  images, and surfaces with the shared compositor's mesh rebuild/cache-hit,
  upload, upload-byte, transform, viewport, atlas, and texture counters.
- Capture-on-failure: encoder/present failures call capture before returning
  `Presenter_Failure`. The bundle does not depend on presentation, and the
  screenshot is encoded from the retained display into an offscreen texture and
  copied to a mapped buffer, so an acquire/present failure still yields an image.
  A failure capture is written even without the diagnostic flags.

### Validation (Windows x64, RTX 2080 SUPER)

- Alicorn suites: `alicorn_tests`, runtime 401, host/sdl3 7, host/sdl3/input 8,
  host/sdl3/clipboard 3, host/sdl3/dialogs 5, host/menus 8, host/web 14,
  host/diagnostics 9, host/presentation 6, renderer/webgpu 6, ui 50, testui 13,
  theme 37, renderer/cpu 23, native/sdl_gpu 169, native/scroll_capture_tests 6,
  text-input contract, restoration, web-UI package build, and theme CLI checks
  all passed. `tools/test.ps1` itself stopped at its AccessKit native UIA stage
  (`Accessible Button missing`), the same environmental failure recorded for the
  previous slice; every Alicorn suite was then run individually with the same
  arguments and passed.
- `examples/16_native_webgpu_ui` built and `--smoke` and `--workbench-smoke`
  passed on `--backend=d3d12` and `--backend=vulkan`.
- `--test-diagnostics-sequence` on both backends produced two five-artifact
  bundles. The overlay capture had the HUD panel and bounds outlines in
  `screenshot.ppm`; the plain capture did not. HUD activity cost four frames,
  text mesh rebuilds stayed at one, and no per-frame persistent allocations
  appeared in the timeline.
- `--test-diagnostics-present-failure` (no `--diagnostics`) forced one encode
  failure after the first frame and still wrote `diagnostics.json`,
  `inspector.txt`, `timeline.json`, `screenshot.ppm`, `windows.json`, and
  `events.jsonl`, with `failure_reason` = `primary presentation failed:
  Render_Failure`.
- The reference SDL_GPU host captured the same artifact set (`diagnostics.json`,
  `inspector.txt`, `timeline.json`, `screenshot.ppm`, `windows.json`,
  `events.jsonl`) from `--inspector-fixture --diagnostics --capture-after=0
  --debug-bounds`.
- Scratchpad (`codex/issue-211-webgpu-frontend` at `bfb2aed`, read-only
  worktree, candidate root this branch) built with `--allow-alicorn-revision`
  and passed `smoke --renderer=webgpu --backend=d3d12` and
  `--backend=vulkan`, including the restored two-document session:
  `publication_rendered`, `wake_observed`, `ordered_shutdown`, and
  `session_restore` were true for clean and recovery launches. No Scratchpad
  source or lock file was changed.

Known limits: the hosted HUD still rebuilds the compositor's solid mesh when its
activity strip or counters change (bounded, opt-in developer overlay); it does
not rebuild text or allocate per frame. The browser host has no F10/F11/F12
keyboard capture surface; the shared core is ready for one, but browser
diagnostics remain future work.

## Stage B slice 4: hosted root ownership and after-frame ordering (2026-11-20)

Real Scratchpad dogfooding exposed two hosted-runtime contract defects that
Scratchpad had been compensating for in its adapter:

- `Hosted_Runtime` always opened its own `ui-root` `.Column` around the
  application description. Scratchpad describes its workbench `.Root` directly
  and then describes Quick Open, modals, context menus, and floating-window
  scenes as top-level layers. Under the host wrapper those layers became
  children of a column and laid out relative to the wrong ancestor; the
  founder's screenshot showed Quick Open underneath a compressed workbench.
- The hosted runtime had no post-frame hook. Scratchpad's `after_frame` work
  (focus restoration, scroll restoration, deferred geometry) was deferred to
  the next description, so it never ran when no later frame was requested.
  Its smoke had moved publication assertions into the description phase to hide
  that gap.

The reference `native/sdl_gpu` host does not wrap: `Application.build` owns the
root, runs `end_frame`, then runs the application's after-frame code before the
host presents. The hosted runtime now matches that ordering and root contract.

### Contract changes

- `Hosted_Runtime` calls `begin_frame`/`end_frame` but does not add a host root.
  `Hosted_Runtime_Config.render` must open and close the application's own
  `.Root`, exactly like `Application.build`. The application root's bounds are
  the content viewport; host-owned chrome continues through
  `content_inset_top` (the application viewport is reduced and paint is
  translated below the band), not through a wrapper. `render_overlays` runs at
  top level after the application root closes.
- `Hosted_Step_Result.root` is the application root described in the settled
  pass (the top-level `.Root` node, with a top-level fallback for malformed
  descriptions).
- `Hosted_Runtime_Config.on_after_frame` and `Hosted_After_Frame_Proc` were
  added. Ordering is `prepare -> begin_frame -> describe -> end_frame ->
  after_frame -> present/commit acknowledgement`. The hook runs after
  `end_frame` of the same pass, after layout, on every described frame
  including the last one before idle, and does not wait for another
  description. A hook that changes retained state calls `invalidate_root`; the
  bounded stabilization loop then rebuilds in the same step.
- `Hosted_Run_State` gained `on_after_frame` and an internal
  `root_ownership` selector. `ui.run` and the browser `run` keep the
  host-owned-root `ui.run` callback contract. `ui/webgpu.run` selects
  `Hosted_Root_Ownership.Application`, so its `render` owns the root and
  overlays are top-level, matching `native/sdl_gpu`. Native `ui.run` accepts
  `on_after_frame` and runs it after `end_frame` in its build callback.
- Alicorn-side hosted consumers that relied on the implicit wrapper now own
  their root: example 15's native/browser feasibility render, example 16's
  default and auxiliary render, the workload matrix hosted renderers, and the
  runtime hosted fixtures. Example 16's smoke renderers already owned roots.

Regression coverage lives in `runtime/hosted_contract_test.odin`: the
application root is a top-level node with exact window content bounds, a modal
overlay is a top-level sibling with viewport bounds, content inset reduces the
root/viewport instead of adding a wrapper, after-frame runs after `end_frame`
with finalized geometry on every described frame, a second step with no
description does not defer it, and an after-frame invalidation rebuilds in the
same step. The existing hosted, chrome, diagnostics, multisurface, services,
menus, SDL3, and UI tests were updated where their fixtures relied on the
wrapper.

The earlier B2 smoke workaround (publication evidence asserted during the
description phase) was Scratchpad-side. Once Scratchpad adopts
`on_after_frame`, its adapter should move that work back to the after-frame
position; Stage B wrap-up owns that Scratchpad change.

### Validation (Windows x64, RTX 2080 SUPER)

- Alicorn suites run individually with the pinned AccessKit arguments:
  runtime 405 (including the four new hosted contract tests), host/sdl3 7,
  host/sdl3/input 8, host/sdl3/clipboard 3, host/sdl3/dialogs 5, host/menus 8,
  host/web 14, host/diagnostics 9, host/presentation 6, renderer/webgpu 6,
  ui 50, testui 13, theme 37, renderer/cpu 23, native/sdl_gpu 169, and
  native/scroll_capture_tests 6. All passed. `odin build tests` plus
  `out/alicorn_tests.exe`, `tools/test_restoration.ps1`, and the SDL_GPU
  `--text-input-contract-test` also passed. `tools/test.ps1` itself stopped in
  the AccessKit binding check because its test runner writes INFO records to
  stderr under Windows PowerShell 5.1 with `$ErrorActionPreference = 'Stop'`;
  every stage was then run individually with the same arguments.
- All examples built with `tools/build_examples.ps1`'s arguments (including
  `-define:WGPU_SHARED=true` for example 16).
- `examples/16_native_webgpu_ui` `--smoke`, `--workbench-smoke`,
  `--titlebar-smoke`, `--child-chrome-smoke`, `--menu-smoke`, and
  `--services-smoke` passed on `--backend=d3d12`, `--backend=vulkan`, and the
  reference `--backend=sdl-gpu` path. `--test-diagnostics-sequence` on D3D12
  still produced HUD, bounds, and plain capture bundles with the screenshot.
- Scratchpad (`codex/issue-211-webgpu-frontend` at `bfb2aed`, read-only
  worktree, candidate root this branch) built against this worktree and passed
  the full native session smoke on `--renderer=webgpu --backend=d3d12` and
  `--backend=vulkan`, including both clean and unsaved-recovery launches:
  `publication_rendered`, `wake_observed`, `ordered_shutdown`, and
  `session_restore` were true. No Scratchpad source or lock file was changed.
  The Quick Open/modal visual regression remains for the founder's hands-on
  check; the hosted contract test now proves the overlay ancestry directly.

## Stage B slice 5: application parity for paint spans and pointer drag (2026-11-20)

Real Scratchpad testing on the hosted WebGPU path reported two P1
application-parity gaps: the Go editor looked like plain text (no syntax
highlighting) and click-drag text selection did not work, while the SDL_GPU
reference did both. This slice traced both flows end to end and fixed the
hosted-side causes.

### What the span flow actually showed

The span data itself was never lost. In the same restored Scratchpad scene
(`language/detection.go`, `builtin:cool-light`, settled frame) the hosted
`inspector.txt` and the SDL_GPU `inspector.txt` contain the same 25 span-bearing
text nodes with identical byte ranges and colors, for example

```text
text run: valid=true bytes=27 paint-spans=5 style-spans=0
  [4,8)fg=(0.040,0.058,0.085,1.000) [15,17)fg=(0.018,0.107,0.141,1.000) ...
```

The retained runtime node, the composed display command, the WebGPU
`Text_Prepare` glyph-color resolution, and the WGSL vertex path all consume those
spans (`renderer/webgpu/text.odin` already fingerprints
`cpu_renderer.Hash_Text_Spans`, so a span-only change invalidates the retained
glyph mesh). The remaining hosted-only difference was *color*: the hosted frame
was the sRGB encoding of the reference frame, channel for channel.

```text
editor text band          background      text          token          token
hosted before             250,251,254     56,68,82      36,92,105      96,74,136
SDL_GPU reference         244,246,253     10,15,22       4,27,36       30,17,63
hosted after fix          244,246,253     10,15,22       4,27,36       30,17,63
full-frame diff before    2,694,611 / 2,914,752 channels differ (92.45%), max 82
full-frame diff after                         0 / 2,914,752 channels differ
```

Root cause: `docs/themes.md` defines `Theme_Color`/`Color` channels as
linear-sRGB values uploaded unchanged and leaves output transfer to the
swapchain. `SDL_GetGPUSwapchainTextureFormat` is a non-sRGB (`*_UNORM`) target on
the reference host, but the hosted WebGPU hosts preferred `BGRA8UnormSrgb`.
That applied a second transfer function to every hosted color. On a light theme
this lightens text and compresses the contrast between base text and the
low-chroma syntax token colors, so highlighting reads as plain text even though
the spans are present. The more saturated the theme, the smaller the visible
difference.

Changes:

- `host/presentation/surface_format.odin` selects the hosted presentation
  format: non-sRGB BGRA/RGBA first, the sRGB variant only when it is the sole
  capability. `host/sdl3/run.odin` (primary surface),
  `host/sdl3/window_service.odin` (secondary surface), and
  `host/web/webgpu_run.odin` (browser) all use it. Image textures already derive
  their format from the target format (`renderer/webgpu/images.odin`), so the
  whole hosted stack stays consistent with the reference.
- `runtime/inspector.odin` records `text run: valid=... bytes=... paint-spans=N
  style-spans=N [start,end)fg=(...)` per Text/Text_Field node, so a capture
  bundle proves span provenance and per-span colors without a screenshot.
- `docs/themes.md` documents the rule explicitly: do not switch one host to
  sRGB output without the other; true color-managed output is a deliberate
  contract change that must land on both hosts (and their image texture formats)
  together.

### Pointer drag selection

The hosted runtime delivered `process_pointer` and then called the application
pointer callback directly. `native/sdl_gpu` and `testui` instead dispatch through
`application_dispatch_pointer`, which offers the event to interaction scopes
first, and they suppress the application callback while a live drag or an open
context menu consumes pointer input (a captured split handle keeps its callback
so app-owned measurement can refresh). The hosted route skipped scope routing
and both suppressions, so an application whose selection or drag gesture lives in
a scope - or which relies on the reference host's drag ownership - diverged.

`hosted_runtime_pointer` now mirrors the reference arbitration exactly: hit test,
pending drag-event dispatch, `application_dispatch_pointer` (scope dispatch then
`on_pointer`), context-menu and drag gates, and the captured-split exception.
The callback's Down/Up invalidation now comes from
`application_dispatch_pointer` instead of a duplicate hosted branch.

### Fixtures

- `runtime/hosted_parity_test.odin`
  - `test_hosted_presentation_preserves_text_paint_spans` describes an
    application-owned Root, a scroll region, a Text row with three ordered
    color spans (Scratchpad's syntax shape), and a Text_Field; it asserts the
    presentation list carries every span (ranges and colors) with
    `content_inset_top` 0 and 24, that the inset translates geometry only, and
    that retained nodes keep their spans.
  - `test_hosted_pointer_drag_selection_matches_reference` presses at byte 1 of
    a shaped Text_Field, moves to byte 8, and releases through
    `hosted_runtime_pointer`; it asserts anchor/caret, capture release, and
    callback order, then repeats the identical description through
    `process_pointer` + `application_dispatch_pointer` and asserts the same
    selection. Both hosts therefore produce the same drag range for the same
    description and pointer stream.
- `renderer/webgpu/text_span_test.odin` asserts per-glyph span colors for
  keyword/function/string/unspanned clusters and proves a span-only color change
  invalidates the retained text mesh fingerprint.
- `host/presentation/surface_format_test.odin` pins the non-sRGB preference,
  sRGB-only fallback, unknown-format fallback, and empty-capability rejection.

### Validation (Windows x64, RTX 2080 SUPER, `28afb82` + this slice)

- Alicorn suites run individually with the pinned AccessKit arguments: runtime
  407 (including the two hosted parity fixtures), host/sdl3 7, host/sdl3/input 8,
  host/sdl3/clipboard 3, host/sdl3/dialogs 5, host/menus 8, host/web 14,
  host/diagnostics 9, host/presentation 7 (new format test), renderer/webgpu 8
  (two new span tests), ui 50, testui 13, theme 37, renderer/cpu 23,
  native/sdl_gpu 169, native/scroll_capture_tests 6, plus `odin build tests` and
  `out/alicorn_tests.exe`, the accessibility contract fixture, restoration, and
  the SDL_GPU text-input contract. All passed. `tools/test.ps1` itself still
  stops in the AccessKit binding stage on this machine, so the same stages were
  run individually as in the previous slices.
- All examples built with `tools/build_examples.ps1` (including
  `-define:WGPU_SHARED=true` for example 16). `16_native_webgpu_ui` passed
  `--smoke`, `--workbench-smoke`, `--titlebar-smoke`, `--child-chrome-smoke`,
  `--menu-smoke`, and `--services-smoke` on `--backend=d3d12`,
  `--backend=vulkan`, and `--backend=sdl-gpu` (18/18 exits 0).
  `--test-diagnostics-sequence --diagnostics` on D3D12 wrote three five-artifact
  bundles, and each inspector now carries the text-run span lines.
- Scratchpad (`codex/issue-211-webgpu-frontend` at `bfb2aed`, read-only worktree,
  candidate root this branch) built with `--allow-alicorn-revision` and passed
  `smoke --renderer=webgpu --backend=d3d12` and `--backend=vulkan` for the clean
  and unsaved-recovery launches (`publication_rendered`, `wake_observed`,
  `ordered_shutdown`, `session_restore` all true). No Scratchpad source or lock
  file was changed. The settled Go-editor capture is byte-identical to the
  SDL_GPU reference capture (0 of 2,914,752 channels differ) after this slice,
  and the dark `charcoal-ink` theme agrees as well.
- Full evidence, histograms, raw diffs, and the span inspector excerpts are in
  [`validation/webgpu-scratchpad-span-selection-parity-windows-2026-11-20.md`](validation/webgpu-scratchpad-span-selection-parity-windows-2026-11-20.md).

### Residual work and Scratchpad-side follow-ups for the wrap-up slice

- `hosted_render` in Scratchpad's adapter still runs `after_frame` at the start
  of the next description; `ui/webgpu.run` now provides `on_after_frame`, so the
  adapter should pass it and run `scratchpad_build_after_frame` after
  `end_frame`. This also makes the editor row trace sample the same phase on
  both hosts; today hosted style/paint row fingerprints differ from the
  reference even though text, geometry, and rendered pixels agree.
- Scratchpad's `hosted_render` comment still describes a host-owned root wrapper
  that no longer exists; the description already opens `.Root`, so only the
  comment (and the deferred after-frame note) needs updating.
- A scripted OS-level mouse drag could not be delivered in this automation
  session (the window receives no synthetic pointer motion, while F10/F11/F12
  host shortcuts work), so drag selection is verified at the hosted-runtime API
  seam against the native/testui route. The founder's hands-on click-drag is the
  confirming check.
- True sRGB output (both hosts encoding linear theme values into an sRGB target)
  is a separate, deliberate contract change; it must land on SDL_GPU, hosted
  WebGPU, and both image-texture paths together.

## Stage C slice 1: live resize and window movement parity (2026-11-20)

Real Scratchpad testing on the hosted WebGPU build reported the P0 parity gap for
this stage: resizing the window only landed when the mouse was released, and
during the drag the window showed the pre-drag frame stretched into the live
size. The SDL_GPU reference resized live and continuously.

### What the reference host actually did

`native/sdl_gpu` never waited for a queued resize event during an interactive
drag. The platform owns a modal move/size loop between the pointer grab and
release, so the host's `SDL_WaitEventTimeout` does not return. The reference host
had two entry points that run inside that loop:

- `native_live_resize_event_watch` on `WINDOW_EXPOSED` with `data1 == 1`. SDL
  documents that this one event may be redrawn from the watcher callback and
  delivers it on the main thread.
- `native_live_resize_windows_message_hook` + `SetTimer(17 ms)` on the moving
  HWND. The hook tracks `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` (and counts
  `WM_MOVING`/`WM_WINDOWPOSCHANGED`); the timer gives every renderable slot a
  display-like presentation opportunity. `WM_EXITSIZEMOVE` can be consumed by
  the modal loop before SDL's hook sees it, so the first ordinary host-loop turn
  after the pointer is up reconciles any leftover move state.

Both paths are re-entrant with respect to the host frame path, because a present
can pump messages: a nested exposure sets a pending flag that the outer call
services in one bounded second pass, and a timer callback re-entered from inside
a present is dropped and counted. The Windows timer is only installed while a
slot has renderable work, so a static window does not spin during a move.

Per-window scheduling was already slot-shaped: the primary window and the single
secondary window each had their own motion scheduler, timing, and move state; the
timer serviced whichever slot the modal loop was moving.

### What moved and what stayed

The scheduling/windowing mechanism moved into `host/sdl3/live_resize`
(package `sdl3_live_resize`) so both renderers use one implementation:

- SDL event watch registration and the `WINDOW_EXPOSED` filter and dispatch;
- the Windows message hook, per-HWND timer, move-state machine, release
  reconciliation, and HWND lookup;
- per-slot identity (`Primary`, `Secondary`) with move/timer state;
- the re-entrancy guards and the counters every host publishes as telemetry.

Renderers supply `live_resize.Ops`: `window`, `renderable`, `has_work`, and
`render(slot, now_ns, cause)`. `render` is the only place frame policy lives, so
the reference renderer keeps its "timer ticks only sample when the retained
motion scheduler is due" rule while the hosted renderer keeps its
"rebuild description + present" rule.

`native/sdl_gpu/window_move_windows.odin` is now a thin adapter over that core:
it supplies the slot window/renderability/work probes, routes the render callback
into `native_live_resize_present_if_due`, republishes slots when a secondary
window opens or closes, and publishes the shared counters under the historical
telemetry names. The native event watch, message hook, timer, guards, and
`move_*` per-window fields were deleted rather than kept as a second copy. The
169 native tests and its smokes are the regression guard for that switch.

### Hosted wiring

`host/sdl3/live_resize_host.odin` installs the core for the primary application
and the optional secondary window. Its render callback:

1. polls the presenter (`hosted_surface_presenter_poll`) so queue completions
   retire while the modal loop owns the thread;
2. adopts the live geometry (`sdl3_webgpu_application_resize`) - this is the step
   whose absence produced the stretched last frame, because a rebuilt description
   was being presented into the previous swapchain size;
3. runs `sdl3_webgpu_application_live_step`, which calls the new
   `hosted_runtime_live_step`.

`hosted_runtime_live_step` is one presentation opportunity inside a modal loop:
it advances retained motion, rebuilds an invalidated description (application-
owned root contract), runs `on_after_frame` for that pass, and reports pending
presentation. It does not dispatch `on_tick` or application-scheduled wakes -
those are ordinary host-loop turns. `sdl3_webgpu_application_step` gained a
`step_in_progress` guard so a tick that lands while a step is running can never
start a second description, and `hosted_surface_presenter_step_with_hook` gained
a `live` parameter that selects the live runtime step.

`host/sdl3/run.odin` installs the core after the presenter exists, republishes
slot identity every loop turn (a secondary window may be created, destroyed, or
replumbed by device recovery), reconciles leftover modal state, and releases the
core before the application is destroyed. The install path's `defer`s are
deliberately outside the `if` block that tests installation: defers are
block-scoped, and the first version released the core at the end of the
installation `if`.

### Fixtures and scripted evidence

- `examples/16_native_webgpu_ui --live-resize-smoke` keeps an animated retained
  motion probe on the titlebar fixture and accounts every description the host
  builds: frame count, width transitions, and the distinct logical widths seen.
  A host that only re-lays out after release reports 1-2 width transitions; a
  host that tracks the drag reports the intermediate sizes. It exits with
  `live_resize_smoke PASS/FAIL` and a non-zero status on failure.
- `tools/validate_native_webgpu_resize.ps1` performs real `SendInput` caption and
  edge drags and counts `live_resize_frame` trace lines from a dedicated reader
  thread (PowerShell event handlers cannot be used here: they are marshalled onto
  the runspace that is busy inside the drag, so counting would be deferred past
  the release). It asserts mid-drag frames, that the drawable tracked the live
  client size, and that drawable and live client aspects agree. `-Mode
  application` runs the same drags against a real consumer build (Scratchpad).
- The hosted host prints `webgpu_live_resize frames ... expose_events ...
  move_timer_wakes ...` at shutdown behind the `--test-live-resize-trace` test
  seam, mirroring the reference host's telemetry line.

### Validation (Windows x64, RTX 2080 SUPER, `9b31260` + this slice)

- Hosted fixture, D3D12: 79 frames during the resize drag with pixel widths
  stepping 1105 -> 1240, 24 frames during the caption move drag, drawable and
  live client both 1240x700 (0.00 % aspect delta). Vulkan is equivalent (78
  frames). The pre-fix build reports 0 mid-drag frames and 3 distinct widths.
- Reference `--backend=sdl-gpu` with the same fixture: 120 exposures and 26
  modal-loop redraws, 26 distinct widths from the shared fixture accounting.
- Scratchpad (`b458d6e`, candidate root this branch): 24 mid-drag frames on both
  hosted backends (D3D12 and Vulkan) with 0.00 % aspect delta and 24 frames
  during the caption drag; `smoke --renderer=webgpu --backend=d3d12`,
  `--backend=vulkan`, and `--renderer=sdl-gpu` pass both legs
  (`publication_rendered`, `wake_observed`, `ordered_shutdown`,
  `session_restore`).
- Suites: runtime, host/sdl3 (plus the new host/sdl3/live_resize 9 tests),
  host/sdl3/input, clipboard, dialogs, host/menus, host/web, host/diagnostics,
  host/presentation, renderer/webgpu, renderer/cpu, ui, testui, theme,
  native/sdl_gpu (169), native/scroll_capture_tests, `odin build tests` and
  `out/alicorn_tests.exe`, and the accessibility contract fixture all pass. All
  examples build, example 16 passes its six smokes on D3D12, Vulkan, and
  SDL_GPU (18/18), and `--test-diagnostics-sequence --diagnostics` still writes
  three five-artifact bundles.
- Full numbers, trace excerpts, and the before/after comparison are in
  [`validation/webgpu-live-resize-windows-2026-11-20.md`](validation/webgpu-live-resize-windows-2026-11-20.md).

### Residual work

- Interactive DPI transitions (`WM_DPICHANGED` mid-drag) re-read logical and
  pixel metrics together on every live frame, but no scripted mixed-DPI monitor
  arrangement exists in this environment; the founder's cross-monitor drag is the
  confirming check.
- The shared core owns windowing/scheduling for both SDL3 renderers now. The
  remaining consolidation is outside this slice: the reference host still owns
  its own frame encoder and end-of-frame bookkeeping around the core, and the
  browser host has no modal move/resize loop to hook.
- Live frames do not run `on_tick` or scheduled wakes by design; applications
  that animate from `on_tick` rather than retained motion will hold their last
  pose during a modal drag, exactly as on the reference host.

## Stage C slice 2: tab drag reorder preview fidelity (2026-11-20)

Founder testing on the hosted WebGPU build reported the last P1 in Scratchpad's
tab drag: during a reorder the dragged tab became a dark, empty ~96x28
rectangle instead of the tab that was lifted. The SDL_GPU reference app shows
the real tab (contour, label, state) following the pointer with the source slot
empty and the insertion marker in the strip.

### What actually engaged the fallback

The fallback is `drag_preview_begin`'s last resort in `runtime/drag_drop.odin`:
when no preview could be built it paints a 96x28 dark card. Two things combined
to reach it, and neither was hosted-specific:

1. `Drag_Preview_Mode.Label` was the enum's zero value and therefore the
   default for every `Tab_Bar_Options` that did not set `drag_preview_mode`.
   Scratchpad's hosted frontend enabled `drag_type` and
   `animate_drag_reorder` but not the preview mode, so both hosts went down the
   label path. The reference Scratchpad branch happens to set
   `.Source_Subtree` explicitly, which is why it looked right there.
2. A tab is a composed button whose visible name is a child text node. The tab
   root's own `label`/`text` are empty, so the label path had nothing to shape
   and left `drag_preview.ready == false`; the card kept its 96x28 default.

A probe through the hosted runtime settled the host question: with
`.Source_Subtree` requested, `hosted_runtime_pointer` and the reference
`process_pointer` + presentation-frame route captured the identical three
commands (150x32 tab surface, its text run, its zero-height indicator), with
`drag_preview.mode == .Source_Subtree` and the same geometry. The hosted
capture hook, text-resource lifetime and transient translation updates were all
functioning. The defect was the preview *choice* and the label fallback's
inability to name a composed control.

### Changes

- `runtime/runtime.odin`: `Drag_Preview_Mode` gained `Auto = 0` before `Label`
  and `Source_Subtree`. `Auto` means "the declaring widget's default".
- `runtime/tab_bar.odin`: a tab bar resolves `Auto` to `.Source_Subtree`, so
  `DEFAULT_TAB_BAR_OPTIONS` and plain `Tab_Bar_Options{...}` literals both lift
  the real tab. Applications that want the compact card set `.Label`.
- `runtime/drag_drop.odin`: `drag_preview_begin` now resolves its label through
  `drag_preview_source_label`, which falls back to the first painted descendant
  text run (value, size, font, weight, style spans) when the source node has no
  label or text. The shaped preview is an owned copy, so the borrowed run may
  retire with its node. `drag_source`'s default mode is `Auto`, which behaves as
  the label card for non-tab sources.
- `runtime/inspector.odin`: capture bundles now record the drag session and up
  to 16 preview paint commands (`drag: phase=... preview=(mode=... commands=...)`
  plus `preview[i] index= kind= bounds= clip= translation= opacity= text=`), so
  a drag frame can be compared between hosts command for command.

Nothing changed in the paint pipeline, stacking, clipping, or retained
translation path: the lifted copy is still appended at the display tail, clipped
by the window viewport, updated by `drag_preview_pointer_moved` without a
display rebuild, and the source slot is still hidden by `drag_source_opacity`.
Neighbor motion remains application-owned through
`Tab_Bar_Result.item_nodes` + `ui.motion` (Scratchpad already does this), and
the insertion marker remains the drop target's own paint below the copy.

### Fixtures

- `runtime/tab_bar_test.odin`:
  - `test_tab_bar_default_drag_preview_lifts_the_real_tab` builds a tab bar that
    leaves the preview mode at `Auto`, drags across a sibling, and asserts the
    lifted mode/size, the tab's own contour and label text in the display tail,
    viewport clipping, inert owner 0, source hidden/neighbor visible, the
    insertion marker below the copy, and that a pointer move updates only the
    bounded preview translations (no display full pass).
  - `test_tab_bar_label_drag_preview_names_the_tab` forces `.Label` and asserts
    the shaped preview is the tab's label rather than the 96x28 empty card, on
    both the retained session and the composed display.
- `runtime/hosted_parity_test.odin`:
  `test_hosted_tab_drag_preview_matches_the_reference_route` describes
  Scratchpad's tab shape (default options, magnetic tracking,
  `animate_drag_reorder`, three semantic tabs), drags through
  `hosted_runtime_pointer` and through `process_pointer`, and compares a
  host-independent signature of the preview commands: mode, size, content kind,
  bounds, clip, translation, opacity and resolved label. The two hosts must
  describe the same visual.
- `examples/16_native_webgpu_ui --tab-drag-smoke` drives a scripted drag from
  `on_after_frame` (header tab 1 onto tab 2, magnetic track) and prints the
  preview evidence: mode, commands, tab size, label text, insertion marker,
  source/neighbor visibility, topmost stacking, owner 0, viewport clip and the
  retained translation, plus the semantic drop target/position. The titlebar
  tabs now carry stable semantic ids (the fixture's existing `titlebar_drag`
  handler already reordered by that value), and the fixture enables the same
  magnetic tracking as Scratchpad's connected titlebar tabs.
  `--tab-drag-hold-ms=N` keeps the lift alive and nudges the pointer one pixel
  per frame for an external capture.
- `tools/validate_native_webgpu_tab_drag.ps1` launches that fixture with
  `--diagnostics --capture-after=1 --capture-dir=...`, focuses the window and
  presses F12, finds the bundle whose `inspector.txt` contains
  `drag: phase=Dragging`, and writes the drag/preview lines to
  `<backend>-drag-preview.txt` for cross-backend comparison.

### Validation (Windows x64, RTX 2080 SUPER, `3df0f69` + this slice)

- Root-cause probe: hosted and reference routes captured the same three preview
  commands; the default-mode drag reported `mode=Label ready=false 96x28`, which
  is the founder's rectangle.
- `tab_drag_smoke` PASS with identical evidence on D3D12, Vulkan and SDL_GPU:
  `mode=Source_Subtree commands=3 size=150.0x32.0 tab=150.0x32.0 text_found=true
  marker=true source_hidden=true neighbor_visible=true topmost=true
  owner_zero=true viewport_clip=true translation=150.0,0.0 drop_target=2
  drop_position=After`.
- Mid-drag capture, `inspector.txt` preview lines (D3D12 vs Vulkan byte-equal;
  SDL_GPU differs only in node ids and the absolute display index):
  `preview[0] surface bounds=(269.0,0.0 150.0x32.0) clip=(0.0,0.0 736.0x519.0)
  translation=(150.0,0.0)`, `preview[1] text bounds=(289.0,6.0 110.0x20.0)
  text="Alicorn Overvi."`, `preview[2] surface bounds=(269.0,31.0 150.0x0.0)`.
- The captured mid-drag frames are pixel-identical between hosted D3D12 and the
  SDL_GPU reference: 0 of 381,984 pixels differ over the full 736x519 frame, and
  0 of 4,800 in the lifted-tab rectangle.
- Suites run individually: runtime (410, including the three new fixtures),
  host/sdl3, host/sdl3/live_resize, host/sdl3/input, host/sdl3/clipboard,
  host/sdl3/dialogs, host/menus, host/web, host/diagnostics,
  host/presentation, renderer/webgpu, renderer/cpu, ui, testui, theme,
  native/sdl_gpu (169), native/scroll_capture_tests, `odin build tests` and
  `out/alicorn_tests.exe`, and the accessibility contract fixture all pass.
  All examples build; example 16 passes all seven smokes (`--smoke`,
  `--workbench-smoke`, `--titlebar-smoke`, `--child-chrome-smoke`,
  `--menu-smoke`, `--services-smoke`, `--tab-drag-smoke`) on D3D12, Vulkan and
  SDL_GPU (21/21).
- Scratchpad (`codex/issue-211-webgpu-frontend` at `b458d6e`, candidate root
  this branch, no Scratchpad source or lock change) builds with
  `--allow-alicorn-revision` and passes both smoke legs on
  `--renderer=webgpu --backend=d3d12`, `--backend=vulkan`, and
  `--renderer=sdl-gpu` (`publication_rendered`, `wake_observed`,
  `ordered_shutdown`, `session_restore` all true).

### Residual work and hands-on items

- This automation session cannot deliver synthetic OS pointer input to the
  Scratchpad window (the same limitation recorded in Stage B slice 5: host keys
  such as F10-F12 arrive, pointer motion does not). The Scratchpad tab drag is
  therefore verified at the hosted-runtime seam plus the instrumented example 16
  fixture, not by a pixel capture of the real app. The founder's real tab drag
  is the confirming check; the hosted frontend picks up the new default without
  any Scratchpad change.
- Neighbor "make room" motion is application policy. Scratchpad retargets
  `ui.motion` on `Tab_Bar_Result.item_nodes`; the example 16 fixture does not,
  so its strip shows an empty source slot rather than animated neighbors. The
  runtime evidence asserted here is the marker, the lift, the hidden source and
  the retained translation.
- A drag that starts when the source subtree has already painted nothing (for
  example a virtualized row that retired in the same frame) still falls back to
  the label card; with the descendant-label resolution it now shows that row's
  text instead of an empty rectangle.

## Stage C slice 3: hosted font-initialization parity and the Pinned U+22EF control (2026-11-20)

Real Scratchpad testing found the Pinned card's "more actions" button drawn as a
missing-glyph box on the hosted WebGPU build. The control is a text button
labelled U+22EF HORIZONTAL MIDLINE ELLIPSIS
(`frontends/alicorn/pinned_surface.odin:998-1004`).

What each backend actually resolved on the same restored pinned scene:

| Build | Stack | U+22EF |
| --- | --- | --- |
| hosted before | bundled Atkinson only, 0 fallback faces | `.notdef`, primary face 1, glyph 0 |
| SDL_GPU before | bundled + 5 DirectWrite faces + NotoSansJP-VF | face 10, glyph 17470 |
| both after | the same shared desktop stack | face 10, glyph 17470 |

The five DirectWrite startup faces do not cover U+22EF; the reference's success
came from the optional `C:/Windows/Fonts/NotoSansJP-VF.ttf` fallback.
`segoeui.ttf` does not cover it either, so a Windows machine without Noto Sans JP
boxes the glyph on the reference too. This was an initialization-parity gap with
an incidental reference-side cover, not a Runa coverage bug.

Changes:

- The native font seeding moved from `native/sdl_gpu/fonts*.odin` into a shared
  `alicorn:host/fonts` package. `load_default_fonts` installs bundled defaults,
  the bounded Windows DirectWrite startup mappings, and the optional UI and
  monospace fallbacks. The SDL_GPU reference, `ui.run`'s native path, and the
  hosted SDL3/WebGPU `ui/webgpu.run` all call it. `native/sdl_gpu/fonts.odin`
  keeps aliases for the existing validation fixtures. The browser path remains
  bundled-only (`#+build !js`) and is documented as such.
- `runtime/inspector.odin` records `faces=[...] unresolved=...` on every text
  run, including button labels, plus a bounded
  `text fallback glyphs: [start,end)face=N gid=N` line. This made the actual
  face/glyph visible in both F12 bundles and is the regression surface for
  future fallback work.
- Alicorn now provides the semantic alternative for the control: a 15th
  built-in `More_Horizontal` icon (Reicon `ui/more-h`, pinned revision,
  regenerated atlas). `icon_button(ui, "More actions", .More_Horizontal, ...)`
  paints a tinted coverage mask with no text run and keeps the explicit
  accessible name. The Pinned control should adopt it rather than depend on a
  system face; the exact Scratchpad-side change is listed in the validation
  record.

Validation: the post-fix hosted frame is byte-identical to the SDL_GPU
reference for the same pinned scene (0 of 2,914,752 channels differ). The
pre-fix hosted frame differed in exactly the two `pinned-more` rectangles (642
channels, 214 pixels, bbox `(1176,96)-(1193,304)`). Runtime, host/fonts, ui,
native, and host suites pass; example 16's seven smokes exit 0 on D3D12, Vulkan,
and SDL_GPU; Scratchpad's webgpu D3D12, webgpu Vulkan, and sdl-gpu smokes all
report `publication_rendered`, `wake_observed`, `ordered_shutdown`, and
`session_restore` true.

Full evidence, coverage probes, the exact Scratchpad change list, and harness
limits are in
[`validation/issue-211-hosted-font-parity-ellipsis-windows-2026-11-20.md`](validation/issue-211-hosted-font-parity-ellipsis-windows-2026-11-20.md).

## Stage C slice 4: theme color fidelity across the presentation matrix (2026-11-20)

Founder finding on the hosted WebGPU build: syntax highlighting "seems to work,
the colors are just super subtle". The only pixel evidence so far was one Go
editor scene with one theme. This slice runs a matched real-application matrix
before changing anything: parity everywhere means theme design, a mismatch means
a renderer regression.

### Matrix

One Scratchpad build (Alicorn `3596387` + this slice, Scratchpad `b458d6e`,
candidate root, `--allow-alicorn-revision`, no Scratchpad source or lock change)
served every leg; `SCRATCHPAD_RENDERER` selected the host and `--backend=` the
hosted GPU. Every leg used the founder's restored session bytes, the same
theme preference, 1216x799 at 100% DPI, and two F12 captures that had to be
byte-identical before the frame was accepted.

Scenes: Go editor (`language/detection.go`), markdown (`README.md`), JSON
(`caliber.config.json`), the Pinned fixture, and the workbench start screen.
Themes: warm (default), cool-light, charcoal-ink, all with the
`workbench-relief` treatment.

Result over 5 scenes x 3 themes x 2 hosted backends (D3D12, Vulkan), against the
SDL_GPU reference: **27 of 30 comparisons are byte-identical**
(0 / 2,914,752 channels). All syntax-token colours, selection paints, chrome,
the pinned editor and the start screen agree pixel for pixel, which confirms the
Stage B5 surface-format fix holds across the app's presentation.

### The one mismatch is an application status label

The three `json-document` scenes differ in exactly one status-strip rectangle,
`(415,774)-(494,783)`: the hosted legs draw the app's conditional "Editor
focused" cue, the reference does not. Both hosted backends agree with each
other byte for byte (1113-1116 channels, max 308-550), and the editor, tabs,
sidebar and chrome are identical. A build-time trace showed both hosts run the
identical startup/focus sequence; the reference performs **one more describe
turn** after it, which lets the app's status strip read a valid current-pass
caret anchor. The hosted host presents the previous turn's stale label. That is
a host turn/scheduling parity gap, not a paint, material or colour difference:
the app's own state is what differs. It is recorded for a follow-up host slice;
no runtime change is made here.

### Why the highlighting is subtle (measured)

Both hosts follow the documented contract: generated theme channels are
linear-sRGB after the compiler's sRGB decode, and they are written unchanged
into a non-sRGB swapchain, so the displayed value is the linear channel read as
an sRGB code. The authored palette never appears on either host. In the
captured Go editor, cool-light's authored background `#fafbfe`, body text
`#121a26` and keyword `#604a88` are displayed as `#f4f6fd`, `#020305` and
`#1e113f`.

WCAG contrast from the compiled styles: on the light themes every token is
13.5-17.8:1 against its background (readable) but only **1.04-1.19:1 against
plain text** (the `syntax.variable` baseline), so only hue (dE 8-31) separates
highlighting from code. Warm is flattest; its comment colour is dE 8.9 from
plain text. On charcoal-ink the compression goes the other way: keyword
(2.91:1), number (2.82:1) and comment (2.22:1) fall **below the 3:1
body-text threshold** against their own background, while the authored palette
has 4.42-5.15:1.

Options for the founder are in the validation record: (A) true sRGB output on
both hosts together, restoring authored colours everywhere; (B) pre-compensate
the syntax palette (exact replacement components are tabulated) so the current
contract displays the authored colours, measured to move light-theme tokens from
1.04-1.19:1 to 2.3-3.2:1 against plain text and to fix charcoal-ink's sub-3:1
readability; (C) retune the palette itself for >=3:1 against plain text; (D)
typographic separation instead. No theme or renderer change is applied without
approval.

### Evidence equipment

`tools/compare_backends.ps1` is now the standard one-command matched comparison:
it runs each renderer/backend with the same state, environment, arguments and
window, drives F12 twice to prove the frame settled, diffs each candidate against
the reference, and writes a full-frame plus per-region `report.md`/`report.json`.
`tools/ppm_diff.py` is the dependency-free differ, `tools/theme_contrast.py`
reports authored-versus-displayed contrast for generated themes, and
`tools/test_compare_tools.py` covers the parser, region statistics and contrast
math (10/10). Usage is documented in `docs/development.md`.

Full matrix, region tables, the status-cue trace, the contrast tables, the
pre-compensation values and the retuned example are in
[`validation/issue-211-theme-fidelity-windows-2026-11-20.md`](validation/issue-211-theme-fidelity-windows-2026-11-20.md).

### Validation

All runtime, host, renderer, ui, testui, theme, native and accessibility suites
pass unchanged (this slice changes no runtime or host code): runtime 412/412,
host/fonts 5/5, host/sdl3 7/7, live_resize 9/9, input 8/8, clipboard 3/3,
dialogs 5/5, host/menus 8/8, host/web 14/14, host/diagnostics 9/9,
host/presentation 7/7, renderer/webgpu 8/8, renderer/cpu 23/23, ui 50/50,
testui 13/13, theme 37/37, native/sdl_gpu 166/166, scroll_capture 6/6,
`odin build tests` and `out/alicorn_tests.exe`, the accessibility contract
fixture, restoration, the text-input contract, and the theme CLI checks all
pass. `python tools/test_compare_tools.py` passes 10/10. Scratchpad smokes on
`--renderer=webgpu --backend=d3d12`, `--backend=vulkan` and `--renderer=sdl-gpu`
report `publication_rendered`, `wake_observed`, `ordered_shutdown` and
`session_restore` true.

### Residual work

- Hosted host turn parity: present the same final describe turn after the
  restore/focus sequence as the reference, or make the app's status read the
  current pass's anchor. The trace and the exact rectangle are in the record.
- The founder's hands-on judgement of whether the measured separation is
  acceptable decides between options A-D.

## Stage C slice 5: retained motion scheduling parity (2026-11-20)

The founder acceptance for this slice is "no frozen animations or unnecessary
idle rendering" on the hosted WebGPU path. The investigation compared how the
reference `native/sdl_gpu` host schedules retained motion with what
`runtime/hosted.odin` did, then measured both halves of the acceptance on real
windows and in the runtime suite.

### How the reference host schedules motion

`native/sdl_gpu` owns one `Native_Motion_Scheduler_State` per window. Each host
loop turn calls `native_motion_scheduler_advance`, which:

1. reads `motion_activity` (active owners/properties, unestablished deadlines);
2. calls `native_motion_scheduler_prepare`, which **consumes a due demand
   exactly once**: the first active turn arms `now + 16.67 ms`, later turns only
   sample when `now >= next_deadline`; a hidden/minimized/occluded window drops
   its deadline and records a suspension, and restoring asks for one immediate
   current-time sample;
3. when due, calls `motion_tick(at)` once and then re-arms the deadline
   (`native_motion_scheduler_finish_sample`), applying the bounded 5 s
   uncertified snap;
4. publishes the earliest deadline to the event wait (`Primary_Motion`,
   `Child_Motion` per window).

Crucially, an ordinary turn that is *not* due still updates the injected motion
clock (`native_motion_clock_set_current_time`, before every description) but
does not sample or request a frame. Retained-paint flushes that start a hover
transition re-arm the first deadline with a second `prepare` pass after the
frame. `native_application_build_until_stable` also injects the clock before
every description.

### What the hosted runtime did

`hosted_runtime_advance_presentation` called `motion_tick(now)` on **every**
step. That is correct for "the animation never freezes when the description does
not change" - a 40-frame settle run reproduced on the hosted step - but it made
the animation's sampling rate equal to the host's loop rate instead of the
display cadence. A 1 ms pointer/completion-wake storm presented 200 frames in
400 ms where the reference host presents ~24. Every one of those frames costs a
surface acquire, encode, submit and present, which is exactly the "unnecessary
rendering" half of the acceptance.

The second half was a pre-existing hosted loop defect that the gating would have
made much worse. `host/sdl3/run.odin` computed its wait with
`ceil((next_wake-now)/1 ms)` and called `SDL_WaitEventTimeout` directly. SDL3's
Windows backend truncates the *remaining* nanosecond timeout to milliseconds, so
a remainder below 1 ms becomes a zero-millisecond OS wait and the host re-enters
its loop. Before this slice the published deadline slid forward on every step,
which hid the effect; with a fixed deadline the last fraction of every sampling
interval spun. `native/sdl_gpu` already had
`native_event_wait_windows_timeout_ms` for this reason; the hosted host did not.

### Changes

- `runtime/hosted.odin`: `Hosted_Runtime_State.motion_deadline_ns` is the
  surface's retained-motion deadline.
  - `hosted_motion_sample_due` gates sampling: no active owner clears the
    deadline, an unarmed deadline samples (first response or restore), otherwise
    only `now >= deadline` samples.
  - A non-sampling step calls `motion_clock_set_time(now)` so a description in
    that step still resolves `ui.motion` targets at the current time, without
    sampling or requesting presentation (the reference host's pre-description
    clock update).
  - A sample re-arms `now + HOSTED_MOTION_SAMPLE_INTERVAL_NS` while owners remain
    active and clears the deadline when the response settles.
  - `hosted_motion_deadline` arms the first deadline for a response started by
    this step's description or retained-paint flush, and
    `hosted_runtime_next_deadline` publishes it. A hidden surface drops the
    deadline, so restoration samples once at the current time instead of
    replaying the gap. `hosted_runtime_live_step` shares the same deadline.
- `host/sdl3/run.odin`: `sdl3_webgpu_run_wait_timeout_ms` adds one millisecond
  of slack to a positive wait timeout on Windows, mirroring the reference host.
- `benchmarks/workload_matrix/main.odin`: the fixture did not compile against
  the current `ui.run` signature (positional `state`/`render` mixed with named
  arguments, and `ui.run_webgpu`, which does not exist). It now calls
  `ui.run`/`ui/webgpu.run` with named arguments. This is the harness used for the
  real-window numbers below.

### Fixtures

`runtime/hosted_motion_test.odin` (six tests):

- `test_hosted_motion_runs_to_settlement_without_description_changes`: one
  description requests an opacity response; every following frame is
  presentation-only, the cadence is re-armed from each sample's own time, the
  response settles on its exact target, and a second of subsequent host turns
  presents and describes nothing.
- `test_hosted_motion_samples_on_its_cadence_not_on_host_turns`: 250 host turns
  at 1 ms yield the display cadence (8-24 frames) and terminate; the storm
  cannot stretch the response.
- `test_hosted_motion_hidden_surface_drops_and_restores_its_deadline`: a hidden
  surface publishes no frame/wake and does not advance the pose; restore samples
  once and re-arms.
- `test_hosted_tick_turns_do_not_present_settled_frames`: an installed `on_tick`
  keeps its 16.67 ms turn cadence with zero presented frames and one description.
- `test_hosted_motion_windows_schedule_independently`: two `Hosted_Runtime`
  sessions stepped from one shared loop; an animating child presents its
  bounded run while the settled primary presents zero frames, and vice versa.
- `test_hosted_live_step_shares_the_motion_deadline`: modal-loop steps honour
  the same cadence, do not dispatch ticks, and progress to settlement.

### Measured results (Windows x64, RTX 2080 SUPER)

Retained-motion matrix scenario (`benchmarks/workload_matrix`, one
`ui.motion` reveal, `--frames=1 --smoke --smoke-hold-ms=1200`), hosted
`frames_presented` from `--timings`:

| Scenario | SDL_GPU reference submits | Hosted before | Hosted after |
| --- | ---: | ---: | ---: |
| `transform` D3D12 | 36 | 40 (steps 784) | 37 (steps 93-103) |
| `transform` Vulkan | - | 43 (recorded) | 37 (steps 90) |
| `multiwindow` D3D12 | 29 | 36 (steps 671) | 36 (steps 94) |
| `multiwindow` Vulkan | - | 67 (recorded) | 35 (steps 93) |
| `settled` D3D12 | 1 | 1 (steps 525-1138) | 1 (steps 7) |

`steps` is hosted host-loop turns, not frames: after the change the loop runs
about one turn per presented frame plus the bounded 250 ms device-loss poll, and
the 1.2 s idle window presents nothing. The same binary with the wait slack
disabled by environment for the A/B (probe build, not committed) reported 5256
turns for `transform` and 642 for `settled`, isolating the quantization defect.

Runtime seam, `storm-paced frames` probe before the gating: 200 frames over
400 ms of 1 ms turns; after: 23 frames, still settling on its target.

### Validation

All suites pass: runtime 418 (six new hosted motion tests), host/fonts 5,
host/sdl3 7, live_resize 9, input 8, clipboard 3, dialogs 5, host/menus 8,
host/web 14, host/diagnostics 9, host/presentation 7, renderer/webgpu 8,
renderer/cpu 23, ui 50, testui 13, theme 37, native/sdl_gpu 166,
scroll_capture 6, accessibility contract 1, `odin build tests` and
`out/alicorn_tests.exe`. `examples/16_native_webgpu_ui` passes its seven smokes
(`--smoke`, `--workbench-smoke`, `--titlebar-smoke`, `--child-chrome-smoke`,
`--menu-smoke`, `--services-smoke`, `--tab-drag-smoke`) on D3D12, Vulkan and
SDL_GPU (21/21). Scratchpad (`codex/issue-211-webgpu-frontend` at `b458d6e`,
read-only, candidate root this branch, no Scratchpad source or lock change)
builds and passes `smoke --renderer=webgpu --backend=d3d12`, `--backend=vulkan`
and `--renderer=sdl-gpu`. Full numbers and the before/after probe are in
[`validation/issue-211-motion-scheduling-windows-2026-11-20.md`](validation/issue-211-motion-scheduling-windows-2026-11-20.md).

### Residual work

- **C4 describe-turn residual: not closed; scheduled.** The JSON-scene status
  cue difference is not a motion-scheduling artifact. Both hosts run the same
  three-pass startup turn and the same one-pass follow-up; the reference then
  takes one more host turn whose description finds the caret anchor. That turn
  is not a stabilization pass (hosted would run it inside the same step if the
  application were still invalidated), and it cannot be synthesized by the
  runtime without inventing a description the application did not request. The
  traced cause is an application-state read: `editor_focus_needs_status_cue`
  runs before the virtual list realizes the caret row, so the first pass of a
  turn sees the previous anchor. The fix belongs either in Scratchpad (realize
  the caret row before the status strip, or invalidate when the anchor is newly
  resolved) or in a future host slice that identifies the remaining reference
  turn's invalidation source (the startup pixel-resize event is the leading
  candidate: SDL_GPU applies it after the first description, the hosted host
  adopts the same metrics before its first step). The exact rectangle and trace
  remain in `validation/issue-211-theme-fidelity-windows-2026-11-20.md`.
- Hover and scroll still start style transitions from retained paint; they now
  inherit the same deadline and settle to zero frames, but the interactive
  hover-then-idle case is covered by the runtime fixture rather than a scripted
  OS pointer run (this automation session cannot deliver synthetic pointer
  motion to a real window, as recorded in earlier slices). The founder's
  hands-on hover/scroll is the confirming check.
