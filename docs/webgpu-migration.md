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
| CPU rendering products to reuse/extract | Paint commands and text runs; image payloads; generic `runtime/gpu_surface` samples; Runa shaping/rasterization and glyph atlas packing in `third_party/Runa`; CPU geometry/material expansion currently next to backend code | Move renderer-facing CPU mesh/atlas preparation behind the shared renderer boundary only when needed. Keep CPU products reconstructible after device loss. |
| SDL_GPU-specific replacement | `native/sdl_gpu/{gpu_frame,solid,text,surface,images,icons,material,retained_effects,effects_compositor,vertex_buffers,render_capture}.odin`; GPU resources, shaders, upload policy, render passes, readback and retirement | Replace incrementally with `renderer/webgpu/` and shared WGSL. Do not alter geometry/shaping as incidental migration work. |
| Native host responsibilities to retain | SDL3 window/event lifecycle, DPI, text input/IME, clipboard, dialogs, drag/drop, titlebars/menus, AccessKit, primary and secondary window scheduling | Keep in SDL3 host modules. Replace only surface/device/presentation integration. |
| Browser host to add | Canvas sizing/DPR, WebGPU surface/device, pointer/wheel/keyboard/touch, browser focus/composition/clipboard, visibility, bounded scheduling, DOM/ARIA projection and capability errors | Add `host/web/` using Odin `js_wasm32` interop and narrow JS integration. No Emscripten or WebGL renderer. |
| Public API/downstream impact | `ui.run` and authoring APIs are public goals; examples and applications currently import `alicorn:native/sdl_gpu` | Preserve `ui.run` and UI/runtime contracts. Provide a temporary narrow import shim only if needed. Coordinate compile/import updates for examples, AliKit, Scratchpad and Punks at migration gates. No raw WGPU handles in widget APIs. |

The exact paint-stream order is a correctness contract. The renderer must not
sort primitives into batches that change stacking. GPU surface declarations are
backend-neutral; their current native payload renderer is not.

## Phase tracker

| Phase | Exit evidence | Status |
| --- | --- | --- |
| 0. Feasibility and baseline | Windows SDL_GPU reference captured; same Odin/WGPU code builds and runs native and browser; solid/clipped/blended/rounded/image/Runa text/waveform/settled-motion/offscreen async readback demonstrated; binding/lifecycle limitations recorded | In progress: native explicit-destroy callback now passes on Windows D3D12 with a pinned wgpu-native source patch; cross-platform lifecycle and recovery evidence remains open |
| 1. Separation | renderer/host package boundary with unchanged runtime and app API | Not started |
| 2. Core parity | solid, clipping, text, image, icon, materials and custom surfaces pass native/browser tests | Not started |
| 3. GPU lifecycle | bounded asynchronous retirement, capture/readback, device loss/recreation and window teardown validated | Not started |
| 4. Desktop acceptance | full regression suite, pixel comparisons, performance and Scratchpad/Punks/AliKit dogfood | Not started |
| 5. SDL_GPU removal | delete production backend, legacy shader artifacts, switches and obsolete docs | Not started |
| 6. Browser host | interaction, accessibility, text/IME, lifecycle and demand-driven scheduling complete | Not started |
| 7. Release readiness | docs, reproducible setup, CI and substantive shared-renderer web example | Not started |

Phase 0 does not authorize a production renderer rewrite. SDL_GPU remains the
reference implementation until parity evidence is available.

## Phase 0 feasibility results (Windows, 2026-11-15)

`examples/15_webgpu_feasibility` builds from the same Odin renderer source for
Windows SDL3/wgpu-native and browser `js_wasm32`. Both targets rendered the
fixture and passed the asynchronous 64×64 RGBA8 offscreen readback check. The
fixture also exercised partial vertex-buffer and texture uploads, resize,
Runa-backed glyph-atlas text, clipped/blended/rounded geometry, waveform bars,
and demand-driven animation that stops after settling. The browser resize and
settled-scheduler behavior were observed in a real WebGPU browser session; the
native run used D3D12 on an RTX 2080 SUPER.

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

Phase 0's shared-rendering feasibility and the patched Windows explicit-destroy
callback path are demonstrated. Phase 0 remains open: this patch has not been
validated on macOS or Linux, and the fixture does not establish
driver/OS-initiated loss, device recreation, general in-flight shutdown safety,
resource retirement, secondary windows, or production performance parity.

## Refreshed Windows validation (2026-11-15)

- `tools/test.ps1 -Odin C:\odin\odin.exe`: passed (343 runtime foundation
  tests, 193 native SDL_GPU frontend tests, and the script's ABI, AccessKit,
  UIA, text-input/navigation, and host-ownership checks). Odin emitted the
  existing large-stack-local warnings for `Native_Secondary_Window`.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe`: passed;
  rebuilt both the native executable and standard `js_wasm32` artifact.
- Native standard fixture: asynchronous 64×64 RGBA8 readback passed; center
  pixel was `(242, 64, 38, 255)`.
- A local static wgpu-native `v29.0.1.1` library built from the pinned source
  and checked-in callback patch passed early-destroy tests in both native
  callback modes, as well as a final-handle-release-before-poll test. The
  patched full fixture passed RGBA8 readback, delivered one `Destroyed`
  notification, and exited through teardown. See the
  [patch validation record](validation/webgpu-device-loss-callback-patch-windows-2026-11-15.md).
- The Windows desktop capture bridge timed out while refreshing the browser
  view, so this run confirms the standard WASM build, not a new browser-GPU
  visual run. An earlier browser session had confirmed the shared scene,
  resizing, and settled no-frame state. The unmodified native callback gap and
  the patched Windows result are distinguished above.
- `git diff --check`: passed.

Phase 0 therefore has credible shared-renderer feasibility evidence, but its
cross-platform device-loss/lifecycle acceptance remains open. The explicit
destroy callback is now verified for the patched Windows D3D12 library; do not
treat that limited probe as evidence of real device-loss recovery or a completed
lifecycle gate for production renderer work.
