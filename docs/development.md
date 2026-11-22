# Development

This page is for working on Alicorn itself. For a fresh installation and the
native starter app, use [Getting Started](getting-started.md).

## Repository map

```text
runtime/          retained runtime and lower-level public API
ui/               convenience API for ordinary native application UI
ui/webgpu/        opt-in native WebGPU entry for SDL3 hosts (`webgpu.run`)
renderer/cpu/     shared backend-neutral mesh, text, image, and material prep
renderer/webgpu/  shared WebGPU renderer; the host owns device and submission
native/sdl_gpu/   SDL3 / SDL_GPU host and compositor (default renderer)
host/sdl3/        SDL3 WebGPU host plus shared window/event/chrome/accessibility code
host/sdl3/input/  WebGPU-agnostic SDL3 key, pointer, wheel, and text mapping
host/sdl3/clipboard/  shared synchronous SDL3 clipboard service
host/sdl3/dialogs/    shared native file-dialog bridge
host/sdl3/file_drag/  shared native drag-out source (Windows OLE)
host/sdl3/live_resize/  shared modal resize/move dispatch and window-frame geometry
host/sdl3/window_frame/ shared integrated-frame window predicates
host/web/         browser (`js_wasm32`) host: input, composition, scheduling, DOM/ARIA
host/presentation shared hosted-surface presenter (WebGPU)
host/plugin/      embeddable child-HWND editor adapter for external plugin hosts
host/plugin/accessibility optional per-editor AccessKit bridge (Windows)
host/diagnostics/ shared, renderer-neutral developer diagnostics
host/fonts/       shared desktop font seeding
host/menus/       shared native menu model and platform adapters
examples/         numbered native application lessons
tests/fixtures/   focused runtime and lifecycle validation applications
tests/            deterministic foundation tests
benchmarks/       retained-work benchmark workloads
third_party/      vendored dependencies and their notices
```

## Build and test

The standard checks build examples and run the headless suite:

```powershell
.\tools\check.ps1
```

```sh
./tools/check.sh
```

`test.ps1` / `test.sh` also compile the native SDL/GPU entry point before
running tests. The native compile and smoke runner requires the platform setup
from [Getting Started](getting-started.md).

For focused work:

```powershell
.\tools\test.ps1
.\tools\bench.ps1
.\tools\bench_text_layout.ps1
.\tools\native_sdl_gpu.ps1 -SurfaceStress
```

```sh
./tools/test.sh
./tools/bench.sh
./tools/bench_text_layout.sh
./tools/native_sdl_gpu.sh
```

### WebGPU and hosted checks

The default checks never compile wgpu-native. WebGPU-specific work adds:

```powershell
# Builds every example; example 16 uses -define:WGPU_SHARED=true and stages
# SDL3.dll plus wgpu_native.dll in out\examples\.
.\tools\build_examples.ps1
# Proves an SDL_GPU consumer builds and smokes when wgpu-native is unavailable.
.\tools\test_sdl_gpu_without_wgpu_native.ps1
# Scripted real-window runners for example 16.
.\tools\validate_native_webgpu_ui.ps1 -Executable out\examples\16_native_webgpu_ui.exe -Backend d3d12
.\tools\validate_native_webgpu_resize.ps1 -Executable out\examples\16_native_webgpu_ui.exe -Backend d3d12
.\tools\validate_native_webgpu_dpi.ps1 -Executable out\examples\16_native_webgpu_ui.exe -Backend d3d12
.\tools\validate_native_webgpu_tab_drag.ps1 -Executable out\examples\16_native_webgpu_ui.exe -Backend d3d12
# Minimal external Win32 parent hosting embedded editors (issue #121).
.\tools\validate_plugin_host.ps1 -Backend d3d12 -HoldMs 3500 -Screenshot out\plugin-host.png
# Test-only wgpu-native export: induce D3D12 backend removal, then recover.
.\tools\validate_wgpu_native_backend_removal.ps1
```

Browser host code is exercised with `odin check ... -target:js_wasm32` and the
Node tests `tools/test_web_scheduler.js` and `tools/test_webgpu_ui_host.js`.
Example 17's `build.ps1`/`build.sh` stages a localhost page; WebGPU requires a
secure context.

Two harness caveats are recorded for this toolchain and host combination:

- `tools/check.ps1` and `tools/test.ps1` run the AccessKit binding check, whose
  `verify-uia.ps1` window-selection step is intermittently failing upstream in
  [odin-accesskit#1](https://github.com/samanshaiza004/odin-accesskit/issues/1).
  It selects the console or IME window instead of the fixture window under
  Windows PowerShell 5.1; run the stages individually or use PowerShell 7 when
  reproducing.
- `tools/check_web_ui_package.ps1` currently fails to compile the
  `tests/fixtures/web_ui_package` wasm target with `DevicePoll is not declared
  by wgpu`. The failure is recorded in
  [`webgpu-migration.md`](webgpu-migration.md) and is independent of the
  renderer slices.

### Headless application interaction tests
Import `alicorn:testui` to drive an application's normal render procedure and
callbacks against Alicorn's retained runtime without opening SDL or creating a
GPU device. The harness supports typed key/text/pointer/scroll input, semantic
actions, owned semantic/layout snapshots, and explicit virtual time. Physical
clicks still go through hit testing; semantic actions test the separately
advertised accessibility contract. See [`testui/README.md`](../testui/README.md)
for ownership rules and the native/GPU guarantees it does not claim.

The public regression includes a virtualized History-style commit list. Page
Down must update selection and bring the selected row inside the actual scroll
viewport. A negative control updates selection while reveal is disabled and
confirms the selected logical row remains unrealized, proving the assertion
would catch a missing reveal request.

The scripts accept `-Odin PATH` on PowerShell and `--odin PATH` on Unix-like
shells. They otherwise use `ALICORN_ODIN`, then `odin` on `PATH`.

### Physical window validation

Two Windows runners drive real `SendInput` input against
`examples/16_native_webgpu_ui` and assert host behavior that a headless test
cannot reach:

```powershell
.\tools\validate_native_webgpu_chrome.ps1 -Executable out\example16\16_native_webgpu_ui.exe -Backend d3d12
.\tools\validate_native_webgpu_resize.ps1 -Executable out\example16\16_native_webgpu_ui.exe -Backend d3d12
.\tools\validate_native_webgpu_topmost.ps1 -Executable out\example16\16_native_webgpu_ui.exe -Backend d3d12
```

The chrome runner covers hit testing, caption drag/maximize/minimize, edge
resize, and theme-message survival. The resize runner adds
`--live-resize-smoke` and `--test-live-resize-trace` and proves that frames are
presented *during* a modal move/resize drag: it counts per-frame trace lines from
a dedicated reader thread, compares the drawable size and aspect with the live
client rectangle, and cross-checks the fixture's own width accounting. Run it
with `-Mode application -ExtraArguments '--renderer=webgpu'` against a consumer
build (Scratchpad) for the same drags without fixture chrome. The mechanism it
exercises is shared with `native/sdl_gpu`; see
[`hosted-runtime.md`](hosted-runtime.md#live-resize-and-window-movement).
The topmost runner adds `--topmost-child-smoke`, hovers the real cursor in and out of
an `ALWAYS_ON_TOP` integrated-chrome child, and asserts the window rectangle
never moves; without the shared `WM_WINDOWPOSCHANGING` guard
(`host/sdl3/window_frame`) it reports the historical `(-8,-31)` drift.

### Matched renderer/backend capture comparison

`tools/compare_backends.ps1` is the standard evidence harness for renderer
parity. One command runs the same application scene on every renderer/backend,
presses F12 through the host capture shortcut, proves the frame settled (two
consecutive captures byte-identical), and diffs each hosted frame against the
reference frame:

```powershell
.\tools\compare_backends.ps1 `
    -Executable C:\work\scratchpad\out\c4\scratchpad-alicorn.exe `
    -Scene go-editor -Theme cool-light -Reference sdl-gpu `
    -Backends @(
        @{ Name = 'sdl-gpu'; Env = @{ SCRATCHPAD_RENDERER = 'sdl-gpu' } },
        @{ Name = 'webgpu-d3d12'; Env = @{ SCRATCHPAD_RENDERER = 'webgpu' }; Args = @('--backend=d3d12') },
        @{ Name = 'webgpu-vulkan'; Env = @{ SCRATCHPAD_RENDERER = 'webgpu' }; Args = @('--backend=vulkan') }
    ) `
    -StateFiles @(
        @{ Path = "$env:APPDATA\Scratchpad\session.json"; Source = 'fixtures\session-go.json' },
        @{ Path = "$env:LOCALAPPDATA\Scratchpad\preferences.json"; Source = 'fixtures\prefs-cool-light.json' }
    ) `
    -RegionsFile .\tools\compare_regions.scratchpad-1216x799.json `
    -OutputDir out\backend-compare\go-cool-light
```

Each leg launches with `--diagnostics --capture-dir=... --capture-after=600`;
the large `--capture-after` suppresses the host's automatic 2 s capture so the
evidence is the settled frame requested by the harness. `-StateFiles` installs
restored application state for the run (an empty `Source` removes the file),
backs up what was there, and restores it byte-for-byte with SHA-256 verification
in a `finally` block. `-Backends` supplies the per-leg environment and extra
arguments, so the harness is not Scratchpad-specific.

The report contains, per candidate backend, the full-frame channel diff and the
named-region statistics from the regions file: differing channels, percent, max
and mean delta, differing pixels, and the bounding box. Captures, `report.md`,
`report.json`, and the per-pair diff JSON stay under `-OutputDir`, which defaults
to `out\backend-compare\<scene>-<theme>-<stamp>` and is git-ignored.

The capture driving (window activation, F12, bundle discovery) is Windows-only,
matching the other F12 runners; `ppm_diff.py` and `theme_contrast.py` are
portable and can compare any two captured PPMs.

Standalone pieces:

- `python tools/ppm_diff.py --a reference.ppm --b candidate.ppm [--regions ...]`
  prints and optionally writes the diff JSON/markdown; `--fail-on-diff` exits 3.
- `python tools/theme_contrast.py --theme name=style_generated.odin ...` reports
  syntax-token contrast in generated style themes for both the authored sRGB
  intent and the displayed linear-as-sRGB value (see
  [`themes.md`](themes.md) for the transfer contract).
- `python tools/test_compare_tools.py` covers the PPM parser, region statistics,
  and the contrast math.

### Linux NixOS/Mango validation

The Linux-specific runner separates deterministic contracts from evidence that
requires a real Wayland session:

```sh
sh tools/linux_native_acceptance.sh --odin /path/to/odin
```

It forces the Wayland/Vulkan SDL path, records selected host/toolchain probes,
runs the existing headless and native contracts, and writes logs plus a
diagnostic bundle under `out/linux-native-acceptance/`. Use `--headless` only
for compile and contract checks; it cannot validate a compositor, GPU session,
physical input, IME, portals, accessibility clients, monitors, or Mango
behavior. Complete the [Linux native acceptance matrix](validation/linux-native-acceptance.md)
for those boundaries.

### Odin `dev-2026-11` toolchain

Alicorn's supported baseline is the official
[Odin `dev-2026-11` release](https://github.com/odin-lang/Odin/releases/tag/dev-2026-11).
Windows CI pins that release through `laytan/setup-odin`; macOS CI uses
`tools/setup_macos_odin.sh`, which verifies the official Apple Silicon archive
against its pinned SHA-256 before checking the SDK directories and compiler
version. The official release has no Intel macOS binary, so the bootstrap
explicitly builds the signed source tag on `x86_64` using the documented
Xcode/LLVM prerequisites. CI puts the selected SDK first on `PATH` and sets
`ODIN_ROOT` and `ALICORN_ODIN` to the same installation, so an unrelated SDK
cannot supply its libraries.

To reproduce with a fresh installation (no Homebrew Odin changes):

```sh
odin_root="$(mktemp -d)/odin"
sh tools/setup_macos_odin.sh "$odin_root"
export PATH="$odin_root:$PATH" ODIN_ROOT="$odin_root" ALICORN_ODIN="$odin_root/odin"
odin version
./tools/check.sh
./tools/test.sh
./tools/bench.sh
bash tools/build_native_release.sh --odin "$(command -v odin)" --sdl-linkage static
python3 tools/test_package_macos.py
```

The destination must not already exist; the bootstrap never reuses an installed
SDK. Other native prerequisites, including SDL3 `3.4.20`, still apply.

The November migration updates Alicorn for the new Darwin framework bindings,
escape analysis, and `core:image.Image.pixels` representation. Keep default
atomic-order analysis enabled. Run `-vet-atomic-access` separately as an
additional audit; it is stricter and is not part of the normal build flags.
The native SDL version guard enforces SDL 3.4.20 on macOS. The pinned shared
runtime is built from the verified upstream source archive during native CI.

## Native diagnostics

The reusable native `Run` host provides a visual inspector when started with
`--inspector`. Press `F9` to open or close it; `--inspector-open` enables it and
opens it at startup. `Escape` or the inspector's Close button also closes it.
The inspector is disabled by default.

The Tree tab shows a collapsible retained hierarchy. Select a row for node
identity, source location, component/key scope, bounds, and interaction state.
Use Pick (or `P`) and click an application node to inspect it without activating it.
The Focus tab shows keyboard focus, semantic identity, its durable owner, and
its currently realized node. Work shows retained stage counters, presentation
and submission revisions, and host timings. Causes shows bounded recent
transactions with actions, invalidations, stage work, and submissions.
Motion shows the selected owner's captured declaration site and cause,
response intent, target and last presented values with per-property sample
timestamps, residual velocity, per-property tolerances, settlement bound, and
the current runtime clock/source, plus retained
input/accessibility geometry policy. Its fixed 128-event ring records state
transitions, not every sample; the tab displays the latest 64 and reports
evictions. Sampling and owner visits are aggregated. Presentation requests,
coalesced requests, acknowledged app submissions, native timer wakes, restore
samples, and measured sampling time are shown separately from inspector-only
work. Reading or freezing this view never samples, wakes, or mutates the
application runtime.

The inspector is an Alicorn UI in its own retained runtime, composited above
the application. Pointer and wheel input over its panel belongs to the
inspector; input outside the panel continues to the application. A gesture
stays with the runtime that received its press. The application retains
keyboard and IME ownership until the inspector panel is clicked. Clicking the
application returns that ownership, and Pick intercepts an application click
to select a node without activating it. App focus and semantic focus are
otherwise preserved. Async application work and window lifecycle events
continue. It refreshes when inspected state changes or the developer interacts,
and adds no periodic tick or idle polling. An application identity error
remains visible in the inspector. With inspector opt-in, the host suspends
further descriptions of the failed application for the remainder of that run,
allowing the independent inspector to stay usable and return to idle.

Run the inspector fixture for a bounded native check and screenshot:

```powershell
.\tools\native_sdl_gpu.ps1 -InspectorOpen -Smoke -Diagnostics -CaptureAfter 0
```

```sh
./tools/native_sdl_gpu.sh --inspector-open --smoke --diagnostics --capture-after=0
```

The fixture has nested components, semantic focus, a virtual list, and actions.
Its `--inspector-input-smoke` mode injects SDL input through the production host
to check that application composition and committed text still reach the
focused editor while the inspector is visible and after it closes. Picking
isolation and panel ownership are covered by deterministic native-host tests.
Add `--inspector-identity-error` to inspect an intentional duplicate-key error.
These two switches belong to the fixture;
`--inspector` and `--inspector-open` work with any app using the reusable host,
without application diagnostics code.

### Motion inspector and virtual-clock replay

The Motion tab is passive: it shows the selected retained owner's declaration,
cause, intent, target, last presented pose and velocity, tolerances, settlement
bound, and the native scheduler's next presentation deadline. Its bounded trace
records transitions rather than every sample. The runtime replay regression
drives the same A→B→C interruptions with sparse and irregular sample schedules,
then checks no-op retargeting, reduced-motion rewriting, suspension, and a
single current-time sample after a hidden gap.

For a readable native capture of interrupted motion in Example 09, use:

```powershell
.\tools\run_example.ps1 -Example 09_retained_motion -Speed `
  -AppArgs @('--motion-validation', '--motion-inspector-review', '--inspector-motion',
    '--diagnostics', '--capture-after=1', '--capture-dir=out/issue-144/motion-inspector')
```

For the settled state and a bounded idle checkpoint, use:

```powershell
.\tools\run_example.ps1 -Example 09_retained_motion -Speed `
  -AppArgs @('--motion-validation-long', '--motion-inspector-review', '--inspector-motion',
    '--diagnostics', '--capture-after=8', '--idle-validation-seconds=10',
    '--capture-dir=out/issue-144/motion-settled')
```

`--inspector-motion` opts into the native inspector and opens its Motion tab.
The review flag gives the example a larger client area for captures. The
validation report in `docs/validation/issue-144-motion-diagnostics.md` records
the tested commands, screenshots, paired closed-inspector idle run, and its
limits. Native hidden-window suspension remains a separate host lifecycle check;
the virtual-clock replay verifies that inspection during suspension does not
advance the last presented sample.

For a real native accessibility working-set experiment with one million logical
rows, run:

```powershell
.\tools\native_sdl_gpu.ps1 -MillionRowAccessibility
```

The fixture exports visible rows plus an eight-row horizon on either side. Its
status line shows the current range and counts ScrollIntoView, focus, and
collection scroll requests. Use Narrator or NVDA to navigate beyond the
exported horizon and verify that the range advances, old platform items retire,
and the exported item count stays bounded. This fixture is intended to test
actual AT traversal; the runtime test alone does not establish that behavior.

```powershell
.\out\alicorn_sdl_gpu.exe --inspector-fixture --inspector-input-smoke
.\out\alicorn_sdl_gpu.exe --inspector-fixture --inspector-input-smoke --inspector-identity-error
```

Use `--capture-after=0` for a static startup capture, or press `F12` during an
interactive run. A settled event-driven app sleeps rather than waking solely
for the automatic capture timer.

The native window supports `F10` to toggle the host-owned runtime HUD, `F11` to
toggle retained bounds, and `F12` for a diagnostic capture (including repeated
captures during one run). The implementation lives in `host/diagnostics` and is
shared with the hosted SDL3/WebGPU runtime; `native/sdl_gpu` keeps thin
compatibility shims and its own SDL_GPU overlay sink. See
[Host-owned UI loops](hosted-runtime.md#diagnostics) for the hosted contract,
backend identity, and capture-on-failure behavior.
The HUD reports recent application builds,
presentation updates, app-driven GPU submissions, host wakes, surface updates,
runtime allocations, retained-region reuse, last-interaction stage visits, and
input-to-submit latency. Its status classifies the latest work as `IDLE`,
`HOST` (input/wake only), `PRESENT` (retained presentation), `APP` (application
description/build), or `SURFACE` (custom-surface-only). Recent pointer-event
and hover-target-transition counts help distinguish ordinary mouse motion from
retained hover changes. It starts hidden and
does not add retained nodes or change application `Frame_Stats`. When visible,
the host redraws the current scene to composite the overlay; those HUD-only
submissions and encode costs are reported separately in the capture.

The fixed 256-sample flight recorder stores host wake/work counter deltas in a
rolling buffer. Event-driven idle time produces no synthetic frame samples;
zero application work while asleep is expected behavior, not a zero-FPS error.
The HUD uses one-shot idle/counter-expiry waits and returns to sleeping until
the next app or OS event. Timeline samples include an activity class and raw
pointer-event/hover-target-transition counts alongside application builds,
retained stage visits, surface updates, and app-driven GPU submissions.

F12 captures separate application build/tick, event handling, GPU encoding,
submission, and fence-wait timings, alongside retained-tree identity, layout
information, and the recent flight-recorder history.

```powershell
.\tools\native_sdl_gpu.ps1 -Diagnostics -CaptureAfter 2 -CaptureDir out\diagnostics
```

Each capture is written as a bundle under `out/diagnostics/`, for example
`20260928T165642.317Z-0001/diagnostics.json`, `inspector.txt`, `timeline.json`,
and `screenshot.ppm`. The timeline uses a versioned JSON schema and contains at
most the 256 most recent samples in oldest-to-newest order. The UTC timestamp
and sequence make repeated captures
distinct, and the JSON records the capture ID and frame. Treat these as
investigation artifacts, not golden-image compatibility promises.

The native host also supports a lightweight opt-in JSONL breadcrumb recorder.
It writes only fixed event names and correlation metadata (UTC and monotonic
timestamps, thread ID, source, and request ID); it does not record file paths or
event payloads. `--diagnostic-events` enables this recorder without enabling
the inspector HUD or automatic F12 capture. `--diagnostics` and
`--capture-dir=...` enable it alongside the existing diagnostics.

```powershell
.\tools\native_sdl_gpu.ps1 -DialogFixture -DialogInitialLocation none -DiagnosticEvents
```

The isolated folder-dialog fixture has no Caliber or application filesystem
code. Repeat with `-DialogInitialLocation ordinary` and `extended`; use Cancel,
choose a folder, reopen the dialog, and close the app while the dialog is open.
The host prints the `events.jsonl` path. Dialog events mark request receipt,
native invocation/return, callback entry/status/completion, UI-thread result
dispatch, and shutdown. The recorder flushes each rare event so a process
termination preserves the preceding boundary. This is lifecycle evidence, not
a substitute for a platform crash dump or symbols matching the crashed binary.

`tools/validate_images.ps1` on Windows or `sh tools/validate_images.sh` on
macOS builds a small SDL_GPU readback probe. It samples a decoded QOI image,
checks source-over RGB and alpha blending against a transparent-aware target,
and repeats at 100%, 125%, 150%, and 200% scale. This checks the platform's
selected GPU backend; it does not launch a window or validate app-specific
resource paths.

## Change boundaries

- Keep app state in the app; do not make retained nodes own arbitrary pointers.
- Preserve explicit invalidation and stable logical keys.
- Keep SDL and GPU handles inside the native host.
- Run the headless checks for runtime/API changes; run a native smoke on the
  target platform for host, input, text, or rendering changes.
- Use benchmarks to compare a named workload, not as cross-machine promises.
- The [performance evidence index](performance.md) links the published
  cross-platform text-layout runs, Mac retained-work suite, and native-hello
  sample. These are workload-specific observations, not cross-machine
  promises; the native report includes raw evidence and qualified startup
  markers.
