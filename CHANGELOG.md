# Changelog

All notable Alicorn releases are recorded here. The project release notes are
consolidated in this file; vendored components retain their own upstream
changelogs.

## [0.2.2] - 2026-11-20

Alicorn is an experimental native GUI runtime for Odin. This release collects
the authoring, hosted-runtime, rendering, diagnostics, and validation work after
v0.2.1. The SDL_GPU renderer remains the default and the visual reference; the
new WebGPU renderer is opt-in. Release date: 2026-11-20.

Compare: [v0.2.1...v0.2.2](https://github.com/Carnival-Science/Alicorn/compare/v0.2.1...v0.2.2)

### Highlights

- **Opt-in WebGPU renderer (PR [#209](https://github.com/Carnival-Science/Alicorn/pull/209)).**
  Native SDL3 and browser hosts can present the same retained Runtime through a
  shared WebGPU renderer with its own compositor, text/icon/image/material
  paths, retained caches, and device-loss recovery. It is selected by importing
  `alicorn:ui/webgpu` or by building the browser target; the default `ui.run`,
  the numbered SDL_GPU examples (01-14 and `15_host_owned_sdl_gpu`), and the
  headless checks keep using SDL_GPU and do not require wgpu-native. Windows
  D3D12/Vulkan, macOS Metal CI, Linux lavapipe CI, and headless Chromium
  SwiftShader exercise the shared fixtures. Phase 4 — In progress. Windows
  Scratchpad interactive parity and performance validated; sustained
  dogfooding, Punks, physical macOS/Linux sessions and WebGPU application
  packaging remain outstanding. SDL_GPU removal has not started.
- **Retained positioned text.** `ui.positioned_text` places ordinary Text nodes
  at explicit surface-local coordinates, so rulers, meters, and timelines can
  label retained geometry without spacer cells or a parallel label-row layout.
  Alignment, baseline placement, clipping, and opacity are explicit; shaping is
  retained across moves, and labels stay decorative and out of tab order unless
  the application opts into semantics.
- **Hosted application parity.** The hosted Runtime and `ui/webgpu.run` now
  expose native menus, integrated titlebar chrome, file dialogs, deferred close,
  a per-surface scheduler, synchronous clipboard, file drag-out/drop-in, and one
  secondary window with its own chrome and services. Diagnostics (F10 HUD, F11
  bounds, F12 capture), live resize, high-DPI transitions, motion scheduling,
  theme/font fidelity, tab drag previews, topmost re-entry, and interactive
  Scratchpad runs are validated on Windows against the SDL_GPU reference.
- **Live resize and drag parity.** Both SDL3 renderers share one modal-loop
  dispatch core. The hosted WebGPU path now presents during a resize or move
  drag instead of stretching the last frame, adopts geometry at the window
  message, and suppresses re-entrant presentation while a native drag-out is
  modal.
- **Fit-content authoring diagnostics.** The #206 investigation found no
  panel-specific measurement defect: a padded fit-content container whose scope
  closes early measures its padding only. The runtime now names that condition
  in its measure trace, regression fixtures pin both the correct tree and the
  misuse symptom, and `AGENTS.md` documents the deferred-scope invocation rule.
- **Broader authoring surface.** Per-corner surface radii, two-stop semantic
  gradients, bounded circle/arc/Bezier primitives, complete custom Button
  presentation, retained interaction scopes, and cluster-aware Unicode fallback
  are available to ordinary applications and third-party components.

### Added

- Added `ui.positioned_text` and the lower-level `alicorn.position_child` seam.
  `horizontal` selects `.Start`, `.Center`, or `.End`; `vertical` selects
  `.Top`, `.Middle`, `.Bottom`, or `.Baseline`. A supplied `width` or `height` is
  a hard box, `max_width` bounds wrapping, and `clip` intersects the owner's
  rectangle. Positioned children reuse retained shaping, paint commands,
  clipping, and semantics, and do not contribute to a fit-content owner's
  measured size. `.Grid`, `.Split`, adaptive owners, and context menus keep
  their specialized layout policy and ignore placement.
- Added a fit-content measurement trace and fixtures for issue #206. The trace
  names a padded fit-content scope that realized no children, and the fixtures
  compare `ui.panel` and `ui.column` across first frame, retained frames,
  resize, viewport sweeps, incremental-versus-fresh solves, and fractional DPI.
- Added the opt-in native WebGPU entry `alicorn:ui/webgpu` (`webgpu.run`) and
  the browser `ui.run` path for `js_wasm32`. Both reuse the shared
  `renderer/webgpu` renderer, `host/presentation` surface presenter,
  `host/sdl3` native host, and `host/web` browser host. The example set gains
  host-owned SDL_GPU presentation (`15_host_owned_sdl_gpu`), the WebGPU
  feasibility fixture (`15_webgpu_feasibility`), native WebGPU UI
  (`16_native_webgpu_ui`), and browser WebGPU UI (`17_browser_webgpu_ui`).
- Added a shared WebGPU renderer with solid, text, icon, image, material,
  custom-surface, compositor, cropped-viewport, and bounded backdrop-effect
  paths over retained CPU geometry and shared WGSL sources. Retained caches
  survive surface translation and text revisions without rebuilding meshes.
- Added browser host capabilities: demand-driven frame scheduling, canvas
  sizing/DPR, pointer/wheel/keyboard/textarea input, text composition, focus
  mirroring, bounded DOM/ARIA projection, an asynchronous permission-gated
  clipboard service, bfcache preservation, and bounded adapter/device retry.
- Added native WebGPU device-loss recovery that drains callbacks, preserves the
  Hosted_Runtime and input state, recreates primary and secondary surfaces, and
  reattaches both presenters. A test-only wgpu-native export can induce D3D12
  backend removal for the third loss rung. Opt-in presenter timings and retained
  renderer counters expose CPU stages without changing presentation.
- Added the application callback surface to `Hosted_Runtime_Config`,
  `ui.run`, and `ui/webgpu.run`: `on_after_frame`, `on_close_requested`,
  `on_menu_command`, `on_dialog`, `on_file_drop`, and `on_tick`.
  `ui/webgpu.run` uses application-owned root rendering, matching
  `native/sdl_gpu`; `ui.run` keeps the host-owned-root contract.
- Added `Hosted_Host_Services` with `windows`, `dialogs`, `quit`, `clipboard`,
  `file_drag`, and a per-surface `scheduler`, plus `UI_Host_Services` injection
  into the `ui.run` entry points. The hosted scheduler mirrors the reference's
  replaceable Frequent/Opportunistic deadlines and 150 ms opportunistic
  deferral.
- Added one shared native menu model (`runtime/menus.odin`) and `host/menus`
  adapters, one shared dialog bridge (`host/sdl3/dialogs`), a hosted chrome
  contract and content inset, integrated titlebar chrome for hosted SDL3, and a
  secondary window with independent chrome, menus, dialogs, close policy, and
  input.
- Added the shared `host/sdl3/live_resize` dispatch core: SDL exposure redraws,
  opt-in queued-resize geometry, a Windows modal move/size timer, primary and
  secondary slots, and re-entrancy guards. Both SDL3 renderers plug their frame
  policy into the same mechanism.
- Added renderer-neutral developer diagnostics to the hosted path:
  `host/diagnostics` supplies the F10 runtime HUD, F11 retained bounds, and F12
  capture bundle, including backend identity and capture-on-failure, to every
  `ui/webgpu.run` surface.
- Added `host/fonts` desktop font seeding and the 15th built-in icon,
  `More_Horizontal`. The SDL_GPU reference, `ui.run`'s native path, and hosted
  `ui/webgpu.run` install the same bundled and platform/DirectWrite stack. The
  inspector records each text run's resolved faces, unresolved coverage, and
  fallback glyphs.
- Added bounded per-corner surface radii, opt-in horizontal and vertical
  two-stop semantic gradients, and circle/arc/cubic-Bezier shape primitives.
  Radii and gradients keep the existing vertex, clipping, and material paths.
- Added `Button` custom presentation, third-party component recipes, retained
  interaction scopes, dynamic image byte buffers, and cluster-aware Unicode
  fallback with generation-scoped reshaping.
- Added optional per-output presentation revisions for hosts that render
  disjoint retained subtrees into separate targets, plus retained point markers,
  a bounded rectangle batch, typed semantic-surface color motion, and a
  presenter encode-before-acquire window.
- Added the matched backend capture harness `tools/compare_backends.ps1` with
  `ppm_diff.py`, `theme_contrast.py`, and their tests, plus Windows runners for
  chrome, resize, topmost, DPI, and tab-drag evidence and physical-session
  WebGPU runbooks for macOS, Linux, and Windows high DPI.

### Changed

- Updated Alicorn's pinned native SDL version to 3.4.20 across macOS builds,
  Windows static-link preparation, runtime validation, and package provenance.
- Native WebGPU is strictly opt-in at build time. The entry moved from
  `ui.run_webgpu` to `alicorn:ui/webgpu`, and every native `alicorn:ui`
  consumer no longer compiles the WebGPU host or requires wgpu-native. The
  `WGPU_SHARED` define selects shared rather than static wgpu-native linkage for
  the WebGPU examples and fixtures.
- The hosted SDL3/WebGPU path now keeps SDL display scale separate from the
  drawable-to-logical pixel density. Application descriptions receive display
  scale, while presentation derives independent X/Y scales from the drawable.
- The Win32 topmost-promotion guard that preserves an integrated-frame window's
  rectangle on mouse entry moved into `host/sdl3/window_frame`. The hosted
  chrome had dropped it; the native SDL_GPU host now delegates to the same
  predicate instead of carrying a private copy.
- Repository links in current documentation, the changelog, and the website now
  use the canonical `Carnival-Science/Alicorn` name. Historical CI runs, pinned
  commit links, and dependency provenance keep their original URLs.

### Fixed

- Fixed hosted retained-motion scheduling. `Hosted_Runtime` sampled motion on
  every step, so pointer storms and submission-completion wakes drove an
  animation faster than the display cadence (a 1 ms turn storm presented
  200 frames in 400 ms where the reference presents about 24). Each
  surface now owns one motion deadline; only a due step samples, and a settled
  surface publishes no deadline. A settled window went from 525-1138
  idle loop turns per 1.2 s to 7.
- Fixed hosted font-initialization parity. The hosted path loaded only bundled
  faces, so text outside bundled coverage (for example U+22EF in Scratchpad's
  Pinned "more actions" control) boxed only there. Both desktop hosts now seed
  the same font stack, and the pinned Scratchpad frame is byte-identical.
- Fixed hosted WebGPU output-transfer parity. The reference presents linear-sRGB
  theme channels through a non-sRGB swapchain, while the hosted hosts selected
  an sRGB surface and applied a second transfer function. Backgrounds, surfaces,
  and per-glyph syntax spans were lightened; a light-theme editor read as plain
  text. Hosted SDL3 and browser presentations now select a non-sRGB format
  first, and a settled Scratchpad frame matches the reference byte for byte.
- Fixed hosted pointer dispatch to match `native/sdl_gpu` arbitration. The
  hosted route now applies interaction scopes first, suppresses application
  callbacks while a drag or context menu consumes input, and keeps a captured
  split handle's callback, so editor selection and drag gestures behave like
  the reference.
- Fixed tab drag reorder previews on both hosts. A tab bar that left
  `drag_preview_mode` at its default drew an empty 96x28 card because a tab's
  name lives in a child text node. `Drag_Preview_Mode` now has an `Auto` zero
  value that resolves to `Source_Subtree`, lifting the real tab contour, label,
  and state while hiding the source slot; `.Label` mode borrows the first
  painted descendant text run when the source has no label.
- Fixed syntax highlighting disappearing while typing on the hosted path.
  Hosted descriptions dropped text paint spans across an edit sequence; the
  hosted description path and the retained edit path now preserve spans, and a
  regression pins span presentation across a sequence of edits.
- Fixed hosted WebGPU first-frame rejection for workbench-like scenes. The
  WebGPU solid pass treated a conservative split-quad vertex reservation as an
  exact contract and returned `Render_Failure` before submitting. It now uses
  the emitted count and grows the buffer only when emission exceeds the
  reservation; encode failures log their stage.
- Fixed hosted topmost re-entry. An `ALWAYS_ON_TOP` integrated-chrome child
  moved up and to the left on every mouse entry because the hosted port never
  carried the Win32 rectangle guard. The shared predicate now prevents the
  historical `(-8,-31)` drift in both renderers.
- Fixed hosted high-DPI monitor transitions. Display scale and pixel density
  now follow the SDL_GPU reference through synthetic `WM_DPICHANGED` and
  `WM_DISPLAYCHANGE` sequences, with per-window independence, text
  re-rasterization, chrome re-sync, and hit-test agreement.
- Fixed hosted live resize and window movement. The hosted path previously
  adopted a new size only on mouse release and stretched the old frame during
  the drag. Shared dispatch now presents during the modal loop and adopts
  geometry at the window message; measured latency is recorded below.
- Fixed hosted close, menu, and dialog integration: a deferred close now
  returns `Close_Deferred`, menu commands arrive under the native-command
  cause, and both SDL3 hosts share one dialog implementation. Windows
  `Content_Title_Bar` windows keep their system decorations where required.
- Fixed the hosted opaque `key_code` contract with a typed `Application_Key`
  route, so application key handling sees the same values as the reference.
- Fixed macOS appearance preferences so a change refreshes every open window,
  not only the one that received the notification.
- Fixed browser focus and accessibility lifetime edges: focus is restored after
  semantic node removal, accessibility payloads are released safely, and the
  WebGPU host survives bfcache restoration. Keyboard-focusable controls now
  advertise the AccessKit `Focus` action, so UI Automation reports
  `IsKeyboardFocusable` correctly.
- Fixed the Odin browser binding's eight rejected-Promise callback chains in
  generated build copies; one-shot callbacks can no longer run a success and an
  error handler for the same request. Also restored `js_wasm32` guards, passed
  the Alicorn collection to point-marker validation, and kept CI SDL rpaths out
  of macOS bundles.
- Fixed the browser package-boundary build. The shared presenter called
  wgpu-native's `DevicePoll` even on `js_wasm32`, where Odin's JS bindings
  deliberately do not declare it (`wgpuDevicePoll(mode, timeout)` is a
  native-only API), so `tools/check_web_ui_package.ps1` failed with
  `DevicePoll is not declared by wgpu`. The poll seam now splits by target:
  native keeps the byte-identical `DevicePoll` retirement path used by modal
  move/resize loops, and the browser target defines the same symbol as a
  documented no-op because browser WebGPU delivers queue completion through the
  event loop and the presenter's `QueueOnSubmittedWorkDone` callback.
- Fixed magnetic tab dragging to stay inside the strip and to avoid vertical
  autoscroll during the gesture; disabled buttons no longer emit `Press`
  actions; custom segmented-control labels center correctly; stroked path end
  caps are bounded; and canceled marker mask uploads retry.

### Performance and measurement

- Retained solid meshes are now stored in local coordinates and reused across
  surface translation and text revisions. A settled scene no longer rebuilds
  every solid mesh when the paint stream shifts.
- The hosted live-resize path cut D3D12's message-to-present stretch window
  from 7.3 ms to 2.6 ms at p50 (65%) and 55% at p95, with zero mesh rebuilds
  during the drag. Hosted presented 74-75 frames where the reference
  presented 58 because the reference also redraws exposures that change
  nothing. Vulkan's remaining 4.7 ms is swapchain recreation.
- The matched-description workload matrix ran one scene through both renderers
  with asserted description counts: identical, transform, color, localized
  layout, 1k/10k scroll, multi-window, and settled idle. It records 131
  expectations (129 pass, 2 fail), CPU p50/p95/p99, retained-work counters, and
  the SDL_GPU solid re-upload finding.
- The app-level WebGPU-versus-SDL_GPU comparison uses one executable, one UI
  description, and one event loop; only the renderer differs. These are
  workload- and machine-specific observations, not a general performance claim.
  See the [workload matrix](docs/validation/webgpu-vs-sdlgpu-workload-matrix-windows-2026-11-19.md)
  and [app-level comparison](docs/validation/webgpu-vs-sdlgpu-perf-windows-2026-11-19.md).

### Validation

- Hosted Scratchpad runs on Windows D3D12 and Vulkan match the SDL_GPU
  reference for syntax spans and drag selection, tab drag previews, theme color
  fidelity, motion scheduling, live resize, topmost re-entry, file
  drag-out/drop-in, and font parity. The DPI fixture adds synthetic
  `WM_DPICHANGED`/`WM_DISPLAYCHANGE` transitions for geometry, text, hit
  testing, and chrome. Several settled frames are byte-identical rather than
  merely close. See the [validation index](docs/validation/README.md).
- Native WebGPU interaction was exercised with real `SendInput`/`SendKeys` and
  UIA on D3D12 and Vulkan: ASCII and Unicode text, Tab/Shift+Tab, UIA Invoke,
  wake callbacks, and an auxiliary window's open/resize/close. Screenshot
  evidence, not speech output, remains the accessibility boundary.
- The CI feasibility matrix covers macOS arm64 Metal, Linux x64 lavapipe, and
  headless Chromium SwiftShader. A live Windows Chromium-family run passed the
  core/compositor/effects/material readback matrix on hardware with
  `fallback=false`.
- Headless suites, examples, smokes, and the Scratchpad validator passed for
  the recorded commits. The current record is in
  [`webgpu-migration.md`](docs/webgpu-migration.md) and the dated validation
  reports; no aggregate test count is a compatibility promise.

### Dependencies and toolchain

- Odin baseline: `dev-2026-11`. Native WebGPU builds require the pinned
  wgpu-native `v29.0.1.1` matching Odin's `vendor:wgpu` bindings. Browser builds
  need `wasm-ld` and `-extra-linker-flags:"--export-table"`.
- The native host uses SDL 3.4.20; text shaping and rasterization remain on
  vendored Runa 1.5.3; the AccessKit C ABI remains 0.23.1 with the separately
  pinned Odin binding.
- Linux font fallback continues to use Fontconfig. Linux still has no AccessKit
  adapter, and this release does not claim broad Linux desktop validation.

### Scope and known limitations

- WebGPU is opt-in and experimental. SDL_GPU remains the default, complete
  renderer and the parity reference. Phase 4 — In progress. Windows Scratchpad
  interactive parity and performance validated; sustained dogfooding, Punks,
  physical macOS/Linux sessions and WebGPU application packaging remain
  outstanding. Phase 5 (SDL_GPU removal) has not started, and this release does
  not replace the production renderer.
- Hosted parity evidence is Windows-based. Browser evidence is Chromium-family;
  Firefox and Safari are untested. Browser native menus, dialog/close behavior,
  and drag-out are not implemented, the browser clipboard remains asynchronous,
  and physical browser IME, clipboard permission, and assistive-technology
  behavior are unverified.
- Physical macOS and Linux WebGPU runs are pending; those platforms have CI
  smoke evidence only. Genuine driver/OS device loss has not been triggered;
  the recorded recovery evidence is callback-path and harness-induced.
- The hosted sRGB surface-format correction is reference parity through
  non-sRGB swapchains, not a true sRGB output pipeline. A genuine sRGB
  output-transfer path is a separate tracked change and is not part of v0.2.2.
- One harness caveat remains for the current toolchain: Windows PowerShell 5.1
  can turn the AccessKit binding check's stderr progress into a terminating
  error in `tools/test.ps1`. Run the individual stages directly, or use
  PowerShell 7, when reproducing a local run. The browser package-boundary
  build now compiles on `dev-2026-11-nightly:08539cd`; see the Fixed section.
- Alicorn remains experimental and API-unstable. This release does not promise
  production readiness or long-term API compatibility.

## [0.2.1] — 2026-11-10

Alicorn remains an experimental native GUI runtime for Odin. This release
collects the merged runtime, authoring, native-host, rendering-test, build, and
performance work after v0.2.0.

Compare: [v0.2.0...v0.2.1](https://github.com/Carnival-Science/Alicorn/compare/v0.2.0...v0.2.1)

### Highlights

- **Retained visual effects:** native SDL_GPU surfaces can request bounded
  Gaussian backdrop blur with retained cache reuse and direct fallback; the
  first application consumer is Scratchpad Quick Open.
- **Application-level headless testing:** the public `alicorn:testui` harness
  drives real application build callbacks with synthetic input, virtual time,
  semantic queries, and owned layout snapshots.
- **Live style updates and motion:** non-default themes can be replaced in
  place, and eligible Button hover fills can transition with retained timing.
- **More capable tabs and fonts:** horizontal tab bars support opt-in magnetic
  reorder/tear-off interactions, and the runtime has a bounded font-file/face
  registry with shared backing for identical files.
- Retained motion now has generation-checked targets, intent-based authoring,
  reduced-motion handling, per-window scheduling, replay/causal diagnostics,
  and native Windows move/minimize lifecycle handling.
- Connected document tabs share a consistent curved silhouette, support live
  reorder previews and motion indicators, and use a font-independent close
  affordance while preserving the existing hit targets.
- Layout invalidation traces retain structured causes and format diagnostic
  text only when inspected. This preserves diagnostic output while reducing
  construction work and allocations.
- Alicorn includes a bounded test-only CPU paint reference renderer and a
  Windows/macOS GPU comparison corpus for the supported paint subset.

### Added

- Added lexical UI key scopes, actionable identity diagnostics, explicit
  virtual-list focusability, and a text-buffer update helper.
- Added native lifecycle breadcrumbs as an opt-in diagnostic, a native OS file
  drag service, and content-owned scroll focus visuals.
- Added typed size declarations for the demonstrated fixed/fit/expansion and
  definite-parent percentage-width cases. Percentage widths remain opt-in and
  broader sizing research remains deferred.
- Added analytic residual motion response, generation-safe retained targets,
  per-window presentation scheduling, reduced-motion intent controls, and
  causal diagnostics/replay. Tab bars can expose motion indicator owners and
  render live browser-style reorder previews.
- Added a bounded, headless CPU reference for flat integer-aligned rectangles,
  stationary clipping, integer translation, opacity, and per-pass RGBA8
  source-over quantization. Unsupported operations return typed diagnostics;
  the production renderer and app-facing paint APIs are unchanged.
- Moved the reusable Odin AccessKit binding to the standalone
  [odin-accesskit](https://github.com/samanshaiza004/odin-accesskit) dependency.
- Added bounded retained Gaussian backdrop blur to native SDL_GPU semantic
  surfaces. Alicorn owns prefix capture, filtering, fence-tracked cache slots,
  composition, and direct fallback; no general effects graph was introduced.
- Added `alicorn:testui` with full-application build callbacks, shared logical
  input routing, explicit virtual time, owned semantic/layout snapshots, and
  bounded replay logs. Native GPU pixels and OS input remain outside its
  headless guarantee.
- Added in-place replacement of non-default runtime style themes while
  preserving theme identity and invalidating affected retained dependencies.
  The Control Gallery demonstrates validated, last-good live color editing.
- Added opt-in timed hover-fill transitions for eligible Button recipes, with
  Linear and CSS Ease timing, reversible entry/exit, retained scheduling, and
  reduced-motion fallback.
- Added opt-in magnetic horizontal tab dragging with tear-off and reattachment
  thresholds, constrained reorder hit testing, and preserved raw pointer
  coordinates for host decisions.
- Added a bounded runtime font-file/face registry with stable IDs and shared
  backing storage for identical font files.

### Fixed

- Corrected typed panel sizing precedence and retained definite-parent
  percentage dependencies across cached-region reuse and viewport resizing.
- Fixed motion owner isolation and release, coherent inspector velocity
  samples, and local clips moving with animated subtrees.
- On Windows, avoid tight SDL timeout retries; suspend motion while minimized;
  advance motion during native move loops; stop the move timer after settling;
  and service every window during a move loop. Added secondary-window lifecycle
  regressions for motion.
- Filled editor row-selection backgrounds for hard line-break/control rows.
- Refined connected-tab close painting with a centered font-independent icon,
  contrast-aware ink, and hover treatment kept inside the tab contour; dirty
  markers and close hit targets remain intact.
- Corrected helper-default normalization and cached percentage sizing bugs
  discovered during the #109 Scratchpad/Punks experiment.

- Replaced the sparse stretched binomial backdrop filter with a normalized,
  sampled discrete Gaussian and higher-precision intermediate targets. Added
  retained-effect recovery after temporary GPU-fence deferral, correct cache
  invalidation when GPU-surface content changes, and explicit CPU-reference
  rejection for unsupported backdrop effects.
- Closed native callback and text-input lifetime gaps, preserved headless
  pointer-target reports across corrective descriptions, and bounded magnetic
  tab dragging to the tab strip while preserving free-subtree preview motion.
- Refresh retained motion time before interaction-only paint so newly started
  transitions receive their first scheduled frame without further pointer
  input.
- Restore macOS trackpad momentum scrolling in the SDL host while preserving
  SDL environment overrides.
- Refine connected-tab close painting so its centered, font-independent icon
  stays within the tab contour with contrast-aware ink and hover treatment.
- Use the Odin-supported image pixel representation for current toolchains.

### Performance and measurement

- PR [#159](https://github.com/Carnival-Science/Alicorn/pull/159) replaces five
  eagerly formatted invalidation reasons with structured events and lazy,
  cached formatting. On the Apple M1 comparison, median end-frame CPU fell
  21.5% for 10,000 containers, 15.6% for 10,000 short-text nodes, and 24.6%
  for the 100-panel form; approximately 30,000 persistent allocation calls
  were removed per 10,000-node workload. The exact trace text and event order
  remain covered by regressions.
- PR [#160](https://github.com/Carnival-Science/Alicorn/pull/160) completes
  bounded construction-cost attribution. Remaining retained measurement and
  geometry costs were accepted based on the recorded workload evidence rather
  than prompting a speculative allocator or data-layout rewrite.
- The matched Windows candidate scorecard measured lower construction time
  across four synthetic workloads. Its Scratchpad nine-action workload showed
  a paired median 6.19% reduction in cumulative app-build callback time;
  first submission, process CPU, and peak working set were effectively flat.
  The separate macOS Scratchpad comparison recorded an 8% callback-time
  improvement with process CPU and peak RSS flat.
- These are workload- and machine-specific results, not universal performance
  guarantees. Active native frame p99, continuous resize/input responsiveness,
  DPI/refresh transitions, and a comparable second-GPU-backend performance run
  remain outside the recorded benchmark coverage. See the
  [performance scorecard](docs/benchmarks/performance-scorecard-v0.2.1-windows-2026-11-04.md).

### Validation

- PR [#161](https://github.com/Carnival-Science/Alicorn/pull/161) passed its
  Windows D3D12 and macOS Metal CPU/GPU comparison suites: 156 targeted cases,
  32 generated scenes, and a permanent minimized clip/translation regression
  on each backend, at 2/255 per-channel tolerance. The CPU renderer is test
  support only and intentionally does not model fractional geometry, non-unit
  DPI, antialiasing, rounded surfaces, text, icons, images, or materials.
- The Odin dev-2026-11 migration record reports Windows validation with
  317 runtime, 39 UI, 35 theme, 168 native SDL GPU, 6 scroll/capture, and
  1 accessibility-contract tests passing, along with examples, AccessKit ABI,
  package smoke, and atomic-access checks. The report also marks macOS/Linux
  physical behavior, Intel macOS execution, and local static-SDL packaging
  without CMake as unverified.
- Windows and macOS performance reports are separate experiments. Their
  measurements must not be combined as if they were a single cross-platform
  run. The complete evidence and limits are indexed in
  [validation](docs/validation/README.md) and
  [benchmarks](docs/benchmarks/README.md).
- The public `alicorn:testui` harness was exercised against History's real
  application build and keyboard callbacks. Its negative control detects when
  selection changes without revealing the selected row in the viewport.
- Live-theme editing was validated on Windows and dogfooded in Scratchpad; the
  Button hover-transition implementation is opt-in and its documented property
  scope remains limited to eligible flat fills.
- The v0.2.1 source baseline `974d74cde2c2e38f931c1cfb74280dfc5966f680`
  passed all five hosted checks, including macOS Metal and Windows D3D12 effect
  readback. Release-preparation documentation checks also passed; current
  evidence and limits are in the
  [release validation report](docs/validation/release-v0.2.1.md).
- Local `tools/check.sh` and `tools/test.sh` passed with Odin `dev-2026-11`.
  Local Metal readback could not start because the available SDL environment
  enumerated no displays; the hosted Metal readback passed.

### Dependencies and toolchain

- Odin baseline: dev-2026-11. The checked migration evidence uses the Windows
  archive compiler dev-2026-11-nightly:9a69916.
- The native host remains on SDL 3.4.18; text shaping/rasterization remains
  on vendored Runa 1.5.3; the AccessKit C ABI remains 0.23.1. The Odin
  binding is now pinned separately in dependencies/odin-accesskit.json.
- Linux font fallback continues to use Fontconfig. Linux has no AccessKit
  adapter, and this release does not claim broad Linux desktop validation.

### Scope and known limitations

- v0.2.1 includes the already merged typed fixed/fit-height and
  definite-parent percentage-width behavior. It does not expand layout
  resizing into percentage height, intrinsic fit width, arbitrary relative
  constraints, aspect-ratio solving, or a general constraint solver. Broader
  layout-resizing work is deferred to a future pass; see the v0.3.0
  [#109 research record](docs/research/issue-109-completion-plan.md).
- Alicorn remains experimental and API-unstable; this release does not promise
  production readiness or long-term API compatibility.
- The CPU reference renderer is deliberately bounded test support, not a
  general software renderer.
- Windows and macOS native acceptance is limited to the exact reports and
  commits cited above. This release does not certify every OS version, driver,
  display scale, assistive technology, or GPU.
- macOS development packages are ad-hoc signed, not Developer ID signed or
  notarized. Distribution signing, installers, updates, and notarization remain
  application-release responsibilities.

### Merged pull requests

- [#159 — Defer layout trace formatting until inspection](https://github.com/Carnival-Science/Alicorn/pull/159)
- [#160 — Complete Issue #157 construction attribution](https://github.com/Carnival-Science/Alicorn/pull/160)
- [#161 — Add a bounded CPU paint reference for #90](https://github.com/Carnival-Science/Alicorn/pull/161)
- [#176 — Refine the connected-tab close affordance](https://github.com/Carnival-Science/Alicorn/pull/176)
- [#178 — Retained Gaussian backdrop effects](https://github.com/Carnival-Science/Alicorn/pull/178)
- [#185 — Headless application test harness](https://github.com/Carnival-Science/Alicorn/pull/185)
- [#186 — Full-application test harness callbacks](https://github.com/Carnival-Science/Alicorn/pull/186)
- [#188 — Retained Button hover-fill transitions](https://github.com/Carnival-Science/Alicorn/pull/188)

### Complete commit ledger

All 93 non-merge commits from the v0.2.0 tag through source baseline
`974d74cde2c2e38f931c1cfb74280dfc5966f680` are listed below. Pull-request
merges are represented by the linked PRs; intermediate merge commits are
omitted.
- [6aba0b2](https://github.com/samanshaiza004/alicorn/commit/6aba0b2bdbbc0a02147958a65679191103a8e0ed) — feat(ui): add lexical key scopes and actionable identity diagnostics
- [7980c0d](https://github.com/samanshaiza004/alicorn/commit/7980c0d27fec6ff2aff53e4641b2d90137e5303a) — feat(ui): bridge native lifecycle and scoped virtual lists
- [1d20f30](https://github.com/samanshaiza004/alicorn/commit/1d20f308643d9a2900d0c26a90137b4d8e5850d7) — feat(ui): prototype theme metrics and typed sizing
- [b78d834](https://github.com/samanshaiza004/alicorn/commit/b78d834d698b1b30507523f823317e9972315f17) — feat(ui): prototype definite percentage widths
- [0792ecd](https://github.com/samanshaiza004/alicorn/commit/0792ecda71a5d21013fe90d9bbe658f6fbb1a65e) — feat(ui): support percentage sized panels
- [835b832](https://github.com/samanshaiza004/alicorn/commit/835b8322b128ae4b84090206b96fd224aea7549b) — docs(ui): show percentage overflow with sibling gap
- [046c9cd](https://github.com/samanshaiza004/alicorn/commit/046c9cd2c55f5750dc075b8c1893d129be930cb3) — feat(ui): expose virtual list focusability
- [0f842c7](https://github.com/samanshaiza004/alicorn/commit/0f842c73ed297a6594c0d7389403b6260953b8da) — feat(ui): expose text buffer update helper
- [829e463](https://github.com/samanshaiza004/alicorn/commit/829e463b16fbb8d8a73bc9f186c9f2afaf1696c3) — feat(native): add opt-in persistent lifecycle breadcrumbs
- [006871f](https://github.com/samanshaiza004/alicorn/commit/006871f3f3e7347dc745b964c410dc027ddaffd4) — docs(layout): propose issue 109 completion with app evidence gates
- [21a91a9](https://github.com/samanshaiza004/alicorn/commit/21a91a99569c080abeed85107f51eac7f7063b64) — fix(ui): let typed panel sizing override helper defaults
- [075e517](https://github.com/samanshaiza004/alicorn/commit/075e5176821d2a04e9791eb76107b0c16d2e8981) — fix(layout): retain percentages through cached regions
- [974baf8](https://github.com/samanshaiza004/alicorn/commit/974baf86dffa3b9732fa4a6ee45fb1e97c33a8af) — feat(tabs): unify connected tab silhouettes
- [6d1cdae](https://github.com/samanshaiza004/alicorn/commit/6d1cdaecca09d18c3aa1221d71580b34b8faf1bc) — docs: record issue 109 dogfood results
- [29c5f6b](https://github.com/samanshaiza004/alicorn/commit/29c5f6baeaa93926b533f5cb48a97fca4a5e36db) — docs: record issue 109 sizing dogfood evidence
- [01d9253](https://github.com/samanshaiza004/alicorn/commit/01d925303d8198e6969b64dceeb774261134a2b1) — docs: close issue 109 research decision
- [bd0dd59](https://github.com/samanshaiza004/alicorn/commit/bd0dd594609599a81aa2662759522770d71339d2) — Move AccessKit Odin binding to standalone dependency
- [f49562c](https://github.com/samanshaiza004/alicorn/commit/f49562c442e0140ebdf996d993b510b0a511d089) — feat(motion): add analytic residual response math
- [4c2873f](https://github.com/samanshaiza004/alicorn/commit/4c2873f2b7c29bc58b3f8068b1a8624afe55d78f) — feat(motion): add generation-safe retained targets
- [78295ff](https://github.com/samanshaiza004/alicorn/commit/78295ffe8348d0d63744c20a4330ac9df3fb398f) — fix(motion): isolate runtime handles and release owners
- [84edd5e](https://github.com/samanshaiza004/alicorn/commit/84edd5e3aae071176e115eaf96e11605ea503232) — feat(motion): schedule retained presentation per window
- [7ed32c2](https://github.com/samanshaiza004/alicorn/commit/7ed32c2c98303677e618fb9797a145756c59816b) — test(motion): clarify bounded window fallback
- [9690333](https://github.com/samanshaiza004/alicorn/commit/9690333ea5dbe335737d59a1c0bfb331edd3ee44) — feat(motion): add intent-based authoring and reduced motion
- [82e415d](https://github.com/samanshaiza004/alicorn/commit/82e415d39d1b265024bc366c2df9563a06e70241) — feat(motion): add causal diagnostics and replay
- [e93ac0d](https://github.com/samanshaiza004/alicorn/commit/e93ac0d58ed3ccfbc4617691a8c3bc9b0073279a) — fix(motion): keep inspector velocity sample-coherent
- [92ad5dd](https://github.com/samanshaiza004/alicorn/commit/92ad5dd1e4df471919ec86142d106cfb0f477ebb) — docs(validation): record motion diagnostics overhead
- [d9e3c88](https://github.com/samanshaiza004/alicorn/commit/d9e3c8827c0375ec84c1aa7ae3871c5677fb354c) — docs(validation): note hosted CI status limitation
- [7b637a5](https://github.com/samanshaiza004/alicorn/commit/7b637a5eeb2d0bb8317ccf8e7a64835d6a97417c) — feat(native): add OS file drag service
- [772ac45](https://github.com/samanshaiza004/alicorn/commit/772ac4546ef81d3282969b993e67cc07dd0c390d) — test(motion): cover native interrupted settling
- [01b6b34](https://github.com/samanshaiza004/alicorn/commit/01b6b34ded7a41297eac637f9c1b5b2fb3c517e8) — docs(validation): record Windows motion smoke
- [719029f](https://github.com/samanshaiza004/alicorn/commit/719029f5f9d171879d38475a991ab9e6f09a90d6) — docs(validation): confirm motion CI results
- [5f7913b](https://github.com/samanshaiza004/alicorn/commit/5f7913b15f6ace26917d2b7322db63f16eb6393f) — fix(native): avoid tight SDL timeout retries on Windows
- [45c9f48](https://github.com/samanshaiza004/alicorn/commit/45c9f4846064725582906a8c9cbd71d2ba358e01) — docs(validation): record Windows wait-loop findings
- [cf3f0b4](https://github.com/samanshaiza004/alicorn/commit/cf3f0b4db60bf70b1ac1511c8c0d5871f7f2852f) — docs(validation): record Windows motion lifecycle
- [4e6ac10](https://github.com/samanshaiza004/alicorn/commit/4e6ac10d51e3746b3e84cae30d95a5c71f70666e) — fix(native): suspend motion for minimized Win32 windows
- [ccc9a66](https://github.com/samanshaiza004/alicorn/commit/ccc9a66d95580cae94635d3da7e18b7d17523fa8) — docs(validation): record active motion restore on Windows
- [c01c149](https://github.com/samanshaiza004/alicorn/commit/c01c149070616fa292c131a5f2295d9035ac5d4e) — test(native): validate secondary-window motion lifecycle
- [06e93ea](https://github.com/samanshaiza004/alicorn/commit/06e93ea30c10e175586768bc4ed8523e4201def4) — docs(validation): record secondary window motion results
- [7f697c5](https://github.com/samanshaiza004/alicorn/commit/7f697c5d4761eebfc439da7bbf5f0bc3a1dcdcfb) — fix(native): advance motion during Windows window moves
- [d0595a7](https://github.com/samanshaiza004/alicorn/commit/d0595a7594d73b90002dab7f8797fc36d043625e) — docs(validation): add Windows move-loop acceptance
- [35d3953](https://github.com/samanshaiza004/alicorn/commit/35d395327eceeb6f1fd22c92e8dc66547df02cba) — fix(native): stop move timer at motion settlement
- [08ff726](https://github.com/samanshaiza004/alicorn/commit/08ff726db59bbd0ece247fb2e326aa994a3ecdcd) — docs(validation): record move timer settlement behavior
- [1a1cff7](https://github.com/samanshaiza004/alicorn/commit/1a1cff797c88d0e0cf52eea63834a635d71666ad) — fix(native): service motion in all windows during move loop
- [b257f4f](https://github.com/samanshaiza004/alicorn/commit/b257f4fd714e07858f7260fefbbddd7b16cde3c4) — docs(validation): record dual-window move observation
- [1e207dd](https://github.com/samanshaiza004/alicorn/commit/1e207dd3f533bca79fa099f3dd90b244967e8426) — feat(tabs): expose motion indicator owners
- [54aec2c](https://github.com/samanshaiza004/alicorn/commit/54aec2cf22e1fccf8de2d63cec347b1f57aa02ad) — feat(motion): complete causal inspector replay gaps
- [571db7b](https://github.com/samanshaiza004/alicorn/commit/571db7b3d306eab4cd7753f37324c8271b4e91da) — docs(motion): record issue 144 failure-path audit
- [403e775](https://github.com/samanshaiza004/alicorn/commit/403e7751a0543c43efd3bac0f1ab5e4a932203c6) — test(runtime): add seeded invalidation coherence oracle
- [06daa41](https://github.com/samanshaiza004/alicorn/commit/06daa41350472aba20bd68c6d3cb51e8e30592fa) — feat(runtime): add browser-style live tab reorder previews
- [1fd3779](https://github.com/samanshaiza004/alicorn/commit/1fd3779907b845ff03287e0b7e10418fe3ccedc2) — fix(motion): move local clips with animated subtrees
- [0349be5](https://github.com/samanshaiza004/alicorn/commit/0349be5c0127a1e65d07ff515d8b796f1b0d72e4) — feat: support content-owned scroll focus visuals
- [5930abb](https://github.com/samanshaiza004/alicorn/commit/5930abbe3a4d813ce4fdceccc9882f44b31287a5) — fix(text): fill editor row selection backgrounds
- [1fde82b](https://github.com/samanshaiza004/alicorn/commit/1fde82b324be957ee685a5b7b3ce0fffef19bf3b) — build: adopt Odin dev-2026-11
- [fe8967f](https://github.com/samanshaiza004/alicorn/commit/fe8967f08fed8b29e7cd27d5989f52b7a85f405c) — fix(build): correct Odin macOS archive checksum
- [dfed741](https://github.com/samanshaiza004/alicorn/commit/dfed7411732b704bcfb849b64c6c1f2a449ffff3) — research: prototype bounded retained effects
- [a031daa](https://github.com/samanshaiza004/alicorn/commit/a031daaa3fa35dc269412ef69fd0972111d205da) — feat: dogfood retained effects in application host
- [067ff0c](https://github.com/samanshaiza004/alicorn/commit/067ff0c73551821474c30fc12d0eea2dea4a3009) — perf: defer layout invalidation trace formatting
- [4375e64](https://github.com/samanshaiza004/alicorn/commit/4375e64642570d93c180244fb6c6f665bf8e679f) — fix(gpu): replace sparse backdrop blur with Gaussian
- [736277f](https://github.com/samanshaiza004/alicorn/commit/736277f899b7777d0cf907a1b7c962370d7217b0) — perf: complete Issue #157 construction attribution
- [bafe2fa](https://github.com/samanshaiza004/alicorn/commit/bafe2fa6db6b49c404538d63756b32590566d89a) — docs: record v0.2.1 Windows performance benchmarks
- [c6eb8fe](https://github.com/samanshaiza004/alicorn/commit/c6eb8fe6fd0c6229cafb2f2d2592876ca786a6cc) — docs: record matched Windows Scratchpad benchmarks
- [a2f1be0](https://github.com/samanshaiza004/alicorn/commit/a2f1be071d3856a7c356025f98cc415a6c09c600) — test(renderer): add bounded CPU paint reference for #90
- [7cc8b3b](https://github.com/samanshaiza004/alicorn/commit/7cc8b3b4b84b2c0bac42fb26f729c6293a13e23d) — feat: promote retained Gaussian backdrop effects
- [6a5a104](https://github.com/samanshaiza004/alicorn/commit/6a5a104001dd92b7a7274a8d3b891d202ffcf78e) — style: refine tab close affordance
- [072aaf5](https://github.com/samanshaiza004/alicorn/commit/072aaf5a29e97f5dad6296dff84835f9f707fcbf) — style: refine tab close affordance
- [44a7b84](https://github.com/samanshaiza004/alicorn/commit/44a7b84d3c87a687e718162e7235412782e97c8e) — docs(release): prepare Alicorn v0.2.1
- [eef2468](https://github.com/samanshaiza004/alicorn/commit/eef2468e3faba11a50442fa28a9cbae4dcca10b9) — Remove scroll momentum change from effects PR
- [27056f4](https://github.com/samanshaiza004/alicorn/commit/27056f451af0154c838115aa577aa0c6e5c7dd56) — fix(test): reject backdrop effects in CPU reference
- [74b4f34](https://github.com/samanshaiza004/alicorn/commit/74b4f349ca6be6cef629fab40a0b662c287da19d) — style: remove trailing blank line from effects cache
- [52a9fa9](https://github.com/samanshaiza004/alicorn/commit/52a9fa9a1ad3216eb862d1c1ee31d825adfbf472) — refactor: consolidate duplicate implementations
- [291d1f6](https://github.com/samanshaiza004/alicorn/commit/291d1f68dda2a3a8e92d94af5cf22fa907850b96) — fix(effects): invalidate cached backdrop for GPU surface updates
- [9d3e015](https://github.com/samanshaiza004/alicorn/commit/9d3e0159d6d0339056855b7a4977b4494e80545d) — fix: close native callback and text lifetime gaps
- [328b8d4](https://github.com/samanshaiza004/alicorn/commit/328b8d463d29b97547915a7229333054e1cb44c4) — feat: add headless application test harness
- [29bf6ac](https://github.com/samanshaiza004/alicorn/commit/29bf6acceb4a9955b3f26e4041736d70557c7f8e) — fix: preserve headless test interaction reports
- [e75d4f2](https://github.com/samanshaiza004/alicorn/commit/e75d4f2c38b41f6897eae0b4fbd94d20faffe587) — feat(testui): support full application build callbacks
- [a941240](https://github.com/samanshaiza004/alicorn/commit/a94124062a4c917cd23b5d24acd931dd15dc08ab) — feat(testui): add bounded semantic replay logs
- [9c0931c](https://github.com/samanshaiza004/alicorn/commit/9c0931c405f38e52dee5aca482330996bc9ae29f) — chore: normalize issue 165 follow-up file endings
- [755c1fa](https://github.com/samanshaiza004/alicorn/commit/755c1fa32f4388e2559d59059a282f59effe75a3) — feat: add experimental live color preview
- [d23c20d](https://github.com/samanshaiza004/alicorn/commit/d23c20dc2bd39d2a1d5ee14c295cf6bca6c6af6f) — fix: build live theme gallery with current Odin
- [80c037e](https://github.com/samanshaiza004/alicorn/commit/80c037e2f6e8a72fe1f6ca93aa55bd2d01ba6ede) — feat: add opt-in live theme editing prototype
- [c359610](https://github.com/samanshaiza004/alicorn/commit/c3596108d1003cb24a242ef3d02995ab5d26df21) — fix: validate live theme on pinned Odin
- [de5f45d](https://github.com/samanshaiza004/alicorn/commit/de5f45ddfad10a76ffec2ecce9ff589d07ffa786) — docs: record Windows live theme validation
- [ae43c83](https://github.com/samanshaiza004/alicorn/commit/ae43c830d2e0f86de28ac27ef2d7968302570654) — docs: record interactive live theme validation
- [0fc31ca](https://github.com/samanshaiza004/alicorn/commit/0fc31ca75c0c666a9be4d766fd91a96acbc14c26) — docs: record Scratchpad live theme validation
- [b6b670a](https://github.com/samanshaiza004/alicorn/commit/b6b670a739b63ee9853daa6af093928e331b6015) — docs: propose timed visual state transitions
- [d6f8245](https://github.com/samanshaiza004/alicorn/commit/d6f824592b57bd960b7fc091641b8a75c42f5d6e) — fix(mac): restore trackpad scroll momentum
- [8d9bf17](https://github.com/samanshaiza004/alicorn/commit/8d9bf17fe2fed5b0b55dac97bdaea1475b0a81e7) — Add retained Button hover fill transitions
- [0c8b44b](https://github.com/samanshaiza004/alicorn/commit/0c8b44bc0365803ebb2ccc464a64633ff0dcfe73) — feat: add magnetic horizontal tab dragging
- [ee2ca73](https://github.com/samanshaiza004/alicorn/commit/ee2ca732b9b18b408f3be856369cb9e7893d2599) — fix: refresh motion time before retained paint
- [5e31467](https://github.com/samanshaiza004/alicorn/commit/5e31467d961c22c25c0437df44a001f6a0f0f7b1) — fix(drag): preserve free subtree preview movement
- [38205de](https://github.com/samanshaiza004/alicorn/commit/38205de02fdd2add4b1de02bf9b463bfad9a1080) — fix: bound magnetic tab dragging to strip
- [4339592](https://github.com/samanshaiza004/alicorn/commit/4339592865cd05116d4d1c8aa119ce0c3bb5957e) — feat: add bounded font face registry
- [974d74c](https://github.com/samanshaiza004/alicorn/commit/974d74cde2c2e38f931c1cfb74280dfc5966f680) — fix: use supported Odin image pixel representation


---

## Alicorn v0.2.0

Alicorn is an experimental native GUI runtime for Odin. Applications describe
interfaces with ordinary Odin code; Alicorn retains identity, interaction,
layout, text, semantics, and rendering products between updates. v0.2.0 keeps
that model and adds a simpler authoring surface, more capable layout and
controls, native accessibility on Windows and macOS, and reusable native-app
packaging tools.

This changelog summarizes the changes from [v0.1.0 to v0.2.0](https://github.com/Carnival-Science/Alicorn/compare/v0.1.0...v0.2.0).
It groups related fixes and features instead of repeating merge commits.

### Highlights

- **Direct to write, retained to run.** The new `alicorn:ui` package lets
  applications write controls and interactions procedurally while preserving
  ordinary Odin application state and the retained runtime underneath.
- **A broader native application surface.** Alicorn now has composite tabs,
  adaptive and elastic layout, richer text editing, secondary windows, and
  integrated titlebar/menu options.
- **Accessible GPU-rendered controls.** Windows UI Automation and macOS
  Accessibility receive semantic controls and text interaction through
  AccessKit; the controls remain Alicorn-rendered rather than native text
  widgets.
- **Measured retained work.** The runtime continues to avoid work on idle and
  preserve localized updates. The final Windows benchmark refresh is recorded
  in the [performance report](docs/benchmarks/performance-final-windows-2026-10-28.md).

### Changelog

#### Added

- Added `alicorn:ui`, a concise procedural API for ordinary application
  composition, controlled text fields, pointer-bound checkboxes and sliders,
  icon controls, automatic informational-text semantics, interaction results,
  and common layout helpers. The form example imports only this package;
  repeated data retains stable explicit-key support. The focused form lesson
  uses bare widget calls, with icon examples in a separate Control Gallery.
- Added a composite `Tab_Bar` with selected and dirty states, an integrated
  close action, hover and pressed treatment, shrink-to-fit and overflow
  behavior, active-tab visibility, reorder feedback, and keyboard navigation.
- Added Checkbox and Slider recipes, accessible Select and notice controls,
  delayed tooltips, and opt-in analytic raised/recessed materials and button
  relief.
- Added adaptive regions; elastic Row/Column allocation; bounded retained
  Grid layout; content-sized and fit-content sizing; retained leaf measurement;
  and typed measurement dependencies with inspector explanations.
- Added scoped theme, density, text-scale, and accessibility-appearance
  environments. Added a typed design-token/theme compiler, static Odin theme
  generation, component recipes, retained computed styles, and composable
  visual parts.
- Added renderer-neutral paint commands so component composition and style
  output are separate from native GPU drawing.
- Added secondary native windows on Windows and macOS, durable UI restoration
  hooks, and integrated client-area menus/titlebar controls on Windows. Added
  integrated titlebar tabs on Windows and macOS.
- Added native accessibility appearance detection for increased contrast,
  reduced motion, reduced transparency, and color differentiation where the
  platform reports support. Added Windows system text-scale import.
- Added the bounded semantic accessibility core and an experimental AccessKit
  bridge for Windows UI Automation and macOS Accessibility. The bridge covers
  common controls, tabs, static text, text runs, selection, editing actions,
  keyboard focus, modal boundaries, and bounded virtual collections.
- Extracted a reusable Odin AccessKit package with typed nodes/actions,
  explicit ownership-transfer APIs, platform adapters, and an ABI contract
  probe against AccessKit C 0.23.1.
- Added asynchronous image decoding with runtime-owned adoption, corrected SDR
  image color handling, and added compiled Reicon mask atlases with
  cross-platform generation/reproducibility checks.
- Added Linux per-glyph font fallback through Fontconfig and native acceptance
  tooling for a documented NixOS/Mango environment.
- Expanded diagnostics with nonmodal visual inspection, mutation invalidation
  causes, typed measurement traces, package provenance, and more focused native
  fixtures and regression checks.
- Added native application packaging and dependency-audit tools. These can
  build Windows applications with static SDL linkage and construct/audit
  macOS `.app` bundles.

#### Changed and improved

- Text fields now expose controlled value APIs and interaction state, with
  content geometry and typography, caret/selection support, clipboard
  integration, IME composition, and shared pointer/text-interaction logic.
- Text measurement and layout now track relevant metric dependencies so density,
  text scale, and content-size changes invalidate the affected measurements
  without treating every style change as a full layout change.
- Tab close visibility and dirty markers share a stable trailing slot; hover
  work is scoped to the tab subtree so close-state changes do not reflow the
  bar or traverse unrelated UI.
- Image decoding and runtime adoption have separate ownership/lifecycle paths;
  native diagnostics preserve pixel channel order and SDR color encoding.
- Windows and macOS build/package scripts now report resolved toolchain and
  architecture details, verify native dependency assumptions, and provide
  clearer failure output.
- Moved the interactive macOS package-launch acceptance app and result protocol
  out of `01_hello` into a dedicated fixture, keeping the starter focused on
  ordinary application state and controls.

#### Fixed

- **Windows native chrome and menus:** corrected caption button alignment,
  full-edge close hover and hit testing, hover contrast, popup-cancel state,
  F10 DevTools handling, and redraw wakeups. Kept editor hit-testing separate
  from native frame areas and preserved the window position when pointer
  tracking begins.
- **macOS input and titlebars:** preserved pointer-button identity through
  release, mapped Control-click to context-click, corrected fullscreen/titlebar
  geometry and lifecycle, and kept shortcut key storage alive for native
  callbacks.
- **Multiple windows and text input:** fixed Darwin shared-host inclusion,
  cross-window text-input state/diagnostics, secondary-input backpressure, and
  region identity handling. Added regression coverage for secondary-window
  interaction and close/reopen behavior.
- **Accessibility contracts:** aligned tab collection positions with the
  platform's zero-based set indexing; preserved the first item's position;
  unified action payloads across platforms; corrected Windows AccessKit hash
  setup; and enforced modal/disabled action eligibility for semantic requests.
- **System appearance:** corrected Windows reduced-transparency detection and
  WinRT activation, and made native preference changes update the inherited
  appearance input without overriding application-scoped values.
- **Text and layout correctness:** preserved text-change ownership without a
  runtime, guarded nested adaptive presentation changes, corrected RTL Grid
  end alignment, retained fit-content cross sizing, and fixed split-drag event
  routing and diagnostics.
- **Rendering and assets:** preserved SDR color encoding and diagnostic
  swapchain channel order, validated source-over blending, normalized shader
  hashes across platforms, checked generated icon pixels, and removed an unused
  icon stroke-width API.
- **Packaging:** corrected static SDL link requirements and Windows CRT
  alignment, validated macOS binary architecture and desktop launch, and fixed
  Windows/macOS packaging probes and workflow toolchain selection.
- Closed additional runtime correctness findings in retained layout, input,
  styles, semantics, images, and lifecycle paths; the related checks are part
  of the Windows/macOS foundation and native-packaging workflows.

#### Performance and validation

- Removed redundant semantic-focus node visits when no realized semantic focus
  exists, and skipped virtual-collection pruning scans when no collection was
  touched. The relevant counters and regression tests verify the bounded work.
- Preserved idle behavior: the 10,000-node retained-work fixture completed
  10,000 idle frames with zero allocations or reconciliation/layout/paint/
  composition work and zero GPU submissions.
- In the final matched Windows `-o:speed` rerun, all five retained-work median
  timings were lower than the October 27 post-merge medians. The largest
  reductions were 13.7% for a 10,000-node root invalidation with one changed
  value, 11.9% for reuse of a retained 10,000-node subtree, and 5.1% for a
  changed 100-node region. The one-million-item virtual-list result was
  effectively unchanged. These are same-machine, three-process observations;
  the runtime source did not change between captures, so they are not attributed
  to a new optimization. Text and material timings remain within overlapping
  ranges. See the [full methodology, ranges, and raw capture](docs/benchmarks/performance-final-windows-2026-10-28.md).
- The earlier release-candidate workflows passed Windows foundation, macOS
  foundation, native packaging, and icon reproducibility checks on implementation
  commit `e00b966`: [Windows foundation](https://github.com/samanshaiza004/alicorn/actions/runs/40631856576),
  [macOS foundation](https://github.com/samanshaiza004/alicorn/actions/runs/40631856709),
  [native packaging](https://github.com/samanshaiza004/alicorn/actions/runs/40631856629),
  and [icon reproducibility](https://github.com/samanshaiza004/alicorn/actions/runs/40631856602).
  The later authoring-experience follow-up is covered by the Windows `tools/check.ps1`
  run and the hosted workflows for its exact commit; do not treat the earlier
  candidate runs as validation for this follow-up. The physical acceptance
  details are in the [candidate validation record](docs/validation/issue-103-final.md).

### Dependencies and platform baseline

- Native host and release packaging pin **SDL 3.4.18**.
- Text shaping, segmentation, line breaking, and rasterization use vendored
  **Runa v1.5.3**.
- Windows/macOS accessibility uses **AccessKit C 0.23.1**, with a reusable
  Odin binding in this repository.
- The tested Odin compiler is **`dev-2026-09-nightly:a2fb372`**.
- Linux glyph fallback uses the system **Fontconfig** facilities. Linux native
  support has only a conditional NixOS/Mango validation record and has no
  AccessKit adapter.

### Tested platforms

Physical validation is recorded for **Windows 10 22H2 x64 with Direct3D 12**
and **macOS 27.0 on Apple M1 with Metal**. The final acceptance matrix records
foreground input, IME, mixed-DPI movement, lifecycle, appearance changes, and
real screen-reader checks, including modal boundaries and virtualized content.
Some per-session reader/IME versions, display scales, and action traces were
not supplied; see the [acceptance matrix](docs/validation/issue-103-final.md)
for the exact evidence boundaries. This is focused validation, not a claim of
support for every OS version, device, GPU driver, or assistive technology.

### Experimental status and known limitations

- Alicorn remains **experimental and API-unstable**; this release does not
  promise production readiness or long-term API compatibility.
- Accessibility is not comprehensive WCAG or platform conformance. Linux has
  no screen-reader adapter, and some less common widgets/context menus may have
  incomplete semantics.
- The blend readback suite covers offscreen RGBA8 targets; it does not validate
  every native swapchain format or display color-management path.
- macOS packages are locally ad-hoc signed, not Developer ID signed or
  notarized. Signing, notarization, installers, updates, and distribution are
  the application's release responsibility.
- No process-memory high-water/leak comparison or representative Scratchpad
  stress benchmark was completed for this candidate. Headless timings do not
  measure GPU residency or native startup/interactive latency.

### Release artifacts

v0.2.0 is a **source/toolkit release**. It does not include prebuilt example
applications. Follow [Getting Started](docs/getting-started.md) to build the
examples, and the [packaging guide](docs/packaging.md) to package an application.

---

## Alicorn v0.1.0

Alicorn is an experimental native GUI runtime for Odin. This first release
provides a small retained UI runtime and an SDL3/SDL_GPU native host, with
application state kept in ordinary Odin code.

### What’s included

- Procedural UI descriptions with retained identity, layout, focus, and
  interaction state.
- Common controls and text input, plus native-host keyboard, pointer, window,
  and menu integration.
- Keyed virtual lists, retained regions, and bounded custom GPU surfaces for
  larger collections and visualization workloads.
- An opt-in visual inspector for the retained tree, focus, runtime work, and
  recent causes; the host also provides a runtime HUD and diagnostic captures.
- A five-step example progression from a native window and controls through
  asynchronous virtual lists, custom surfaces, and the inspector.

Start with [Getting Started](docs/getting-started.md), then see the
[application guide](docs/guide.md), [API reference](docs/reference.md),
[examples](examples/README.md), and [native diagnostics guide](docs/development.md#native-diagnostics).

### Platform validation

The native path has been exercised on Windows and macOS. Checked-in validation
records include Windows 10 22H2 and macOS 27.0 on Apple silicon. Linux has a
conditional validation record for one NixOS 26.11/Mango 0.16.2 machine; it is
not broad Linux support or certification across OS versions, hardware, or GPU
drivers. See the [Linux validation record](docs/validation/linux-nixos-mangowc-2026-10-23.md).

### Experimental status and limitations

This release is **not production-ready**. Alicorn is experimental, its public
API is not frozen and may change, and the available widget set is intentionally
small. v0.1.0 does not promise a full-featured toolkit or long-term production
API stability.

Keyboard focus and operation, semantic focus identities, and native text-input
composition are supported. They are not a platform accessibility bridge:
Alicorn does not expose its GPU-rendered controls as Windows UI Automation or
macOS Accessibility/NSAccessibility elements, so screen readers cannot inspect
or operate that control tree.

The native starter scripts are development workflows, not a general app
packager. Windows development currently stages SDL3 beside the executable;
macOS development links the installed SDL3 library. v0.1.0 does not provide a
first-party self-contained app bundle, installer, signing, or notarization
pipeline. Those deployment responsibilities remain with each application for
now; reusable SDL/runtime packaging belongs with Alicorn's native-host tools,
not Caliber's frontend-neutral ABI layer.

### Performance evidence

The published measurements are author-run, workload-specific observations,
not cross-framework comparisons or general performance guarantees. They cover
focused text-layout workloads and retained-work tests on Windows and macOS,
plus bounded native-host samples. See the [performance evidence index](docs/performance.md)
for methodology, platform reports, raw captures, and limitations.
