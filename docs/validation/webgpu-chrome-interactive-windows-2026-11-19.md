# WebGPU chrome physical interaction — Windows

Captured 2026-11-19 from `codex/issue-211-scratchpad-webgpu` at implementation
commit `fe1dc7f` on Windows x64 build `10.0.19045` with Odin
`dev-2026-11-nightly:08539cd` and an NVIDIA GeForce RTX 2080 SUPER
(driver `595.97`). Display scale was 1.0. Runs used the interactive desktop; the
scripted windows were visible only for the interaction sequence and were then
closed.

This record covers the hosted SDL3/WebGPU chrome host and the SDL_GPU reference
host through `examples/16_native_webgpu_ui`. It does not cover physical macOS or
Linux, browser window chrome, or genuine device-loss recovery.

## Automation

```powershell
.\out\slice4\native_webgpu_ui.exe --child-chrome-smoke --backend=d3d12
.\out\slice4\native_webgpu_ui.exe --child-chrome-smoke --backend=sdl-gpu

powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\validate_native_webgpu_chrome.ps1 `
  -Executable .\out\slice4\native_webgpu_ui.exe -Backend d3d12
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\validate_native_webgpu_chrome.ps1 `
  -Executable .\out\slice4\native_webgpu_ui.exe -Backend sdl-gpu
```

`tools/validate_native_webgpu_chrome.ps1` launches the integrated-titlebar
fixture with `--titlebar-smoke --interactive`, sizes it to 1100×700, and then
uses real `SendInput` left-button transitions plus `SetCursorPos` motion. It
reads the fixture's own `WM_NCHITTEST` result before each gesture. The drag point
is discovered by scanning the titlebar band for the contiguous `HTCAPTION` run,
because the application-authored drag region grows between the measured menu
labels, tab strip, and caption reservation. Caption clicks use
`DWMWA_CAPTION_BUTTON_BOUNDS`, converted from client to screen coordinates.

The existing UI Automation harness was re-run on both WebGPU backends and reports
`failures=0`; its focus step now attaches to the foreground thread so scripted
activation is not lost to a terminal window. New focus evidence is in
`docs/validation/raw/webgpu-chrome-uia-{d3d12,vulkan}-2026-11-19.txt`.

## Results — physical-style window chrome

| Check | D3D12 | SDL_GPU | Detail |
| --- | --- | --- | --- |
| Window created, foreground, 1100×700 | PASS | PASS | visible `SDL_app` window |
| `Window_Drag` region returns `HTCAPTION` | PASS | PASS | `WM_NCHITTEST=2` at the scanned band point (offset 770 at 1100×700) |
| Drag-to-move on the caption band | PASS | PASS | window moved +100,+50 for a +100,+50 pointer drag |
| Double-click band maximizes | PASS | PASS | `IsZoomed=true` |
| Second double-click restores | PASS | PASS | `IsZoomed=false` |
| Right edge returns `HTRIGHT` | PASS | PASS | `WM_NCHITTEST=11` |
| Resize by right-edge drag | PASS | PASS | width +120 for a +120 pointer drag |
| Caption minimize click | PASS | PASS | `IsIconic=true`; restored afterwards |
| Caption maximize click | PASS | PASS | `IsZoomed=true` |
| Caption restore click | PASS | PASS | `IsZoomed=false` |
| Theme/settings message path | PASS | PASS | `WM_SETTINGCHANGE`, `WM_THEMECHANGED`, and `WM_SYSCOLORCHANGE` delivered without terminating the host; not a visual theme comparison |
| Caption close click | PASS | PASS | process exited with code 0 |
| Snap Layouts flyout | HANDS-ON | HANDS-ON | requires a human pointer hovering the maximize button; flyout and snapped placement are OS-owned |
| Theme/contrast visual switch | HANDS-ON | HANDS-ON | changes the live user desktop; visual color/contrast comparison is not scripted |
| Mixed-DPI monitor move (150% → 200%) | HANDS-ON | HANDS-ON | user-owned monitor arrangement; `WM_DPICHANGED` handling is compile-checked but not scripted |
| Trackpad inertia / precision-touchpad feel | HANDS-ON | HANDS-ON | scripted pointer motion and wheel deltas do not exercise OS inertia |

Summary: `failures=0 pass=15 hands_on=4` for both backends.

Raw logs:
`docs/validation/raw/webgpu-chrome-interactive-{d3d12,sdl-gpu}-2026-11-19.txt`.
Post-run captures:
`docs/validation/assets/webgpu-chrome-interactive-{d3d12,sdl-gpu}-2026-11-19.png`.

## Results — child chrome parity

`examples/16_native_webgpu_ui --child-chrome-smoke` opens a 760×460 child with
its own integrated titlebar, menu tree, accelerator, chrome metrics/layout,
dialog service, and close-deferral policy. The child pushes one child-targeted
`Ctrl+Shift+K` transition and one native `WINDOW_CLOSE_REQUESTED`, then completes
its deferred close through its own quit service. The primary application must
ignore both events.

| Backend | Result | Detail |
| --- | --- | --- |
| D3D12 (hosted SDL3/WebGPU) | PASS | `started=true stopped=true metrics=1 layouts=7 menus=1 deferred=true dialogs=true open_failed=false` |
| SDL_GPU (reference) | PASS | `started=true stopped=true metrics=1 layouts=2 menus=1 deferred=true dialogs=true open_failed=false` |

The hosted path additionally observes its own chrome callbacks on every
description; the reference path re-syncs the app-authored layout once the child
has a frame. Both prove that the child menu command, close request, and dialog
service are not cross-wired to the primary window. No modal dialog is opened by
the smoke; it verifies that each child has its own dialog bridge without
blocking an automated run.

Raw logs:
`docs/validation/raw/webgpu-child-chrome-smoke-{d3d12,sdl-gpu}-2026-11-19.txt`.

## Bugs found and fixed

1. `ui.run` never published `UI_Host_Services.windows` on the reference SDL_GPU
   path. A hosted child request therefore returned `false` silently, and the
   previous `--child-smoke` could pass without creating a child. `ui/run_native`
   now owns a hosted-to-native secondary-window bridge.
2. That bridge initially passed the hosted chrome callbacks through unchanged.
   The reference host invokes them with `Application.state` (the bridge), while
   the hosted contract passes `Hosted_Runtime_Config.state`. Metrics/layout were
   delivered to the wrong object; wrappers now forward the hosted state.
3. The reference secondary-window loop re-synced appearance and text but not
   `native_menu_sync_chrome_layout`, so an app-authored child header had no
   chrome regions after its first description. It now re-syncs whenever the
   child has a pending frame, matching the primary loop.
4. A caption double-click that changed zoom could leave
   `gesture_owner = .Window` latched because Windows does not always deliver the
   matching `WM_NCLBUTTONUP`. Every later hit test then returned `HTCAPTION`.
   Both the hosted and reference Win32 adapters now clear the gesture when the
   maximized state changes.
5. On macOS, AppKit's main menu is process-global. A second hosted menu adapter
   would replace the primary menu and route selections through the global
   `darwin_active_adapter`. The hosted child now leaves menus to the primary
   window, matching the reference host's secondary-window policy.

## macOS pointer-sample correction

The reference macOS titlebar pairs each Cocoa hit-test point and button snapshot
with the SDL pointer event that follows it, because SDL can queue a stale point
during a native window drag. The hosted macOS titlebar now carries the same
sample ring, press/release matching, consumed-event drain, and last-point
fallback. `host/menus/chrome_darwin_test.odin` mirrors the reference tests for
pairing, consumed samples, and fallback.

`odin check host\menus -target:darwin_arm64 -no-entry-point` passes. This code
has not run on a physical Mac; drag distance, traffic-light exclusion, and
fullscreen transitions remain unverified there.

## Limits

- One machine, one desktop session, one scripted pass per backend. The successful
  runs did not need a retry after the focus helper was fixed.
- The drag, resize, and caption gestures are real OS input, but their timing and
  coordinates are scripted. Human pointer acceleration, Snap Layouts, and
  trackpad feel are not reproduced.
- The theme/settings check exercises the message path, not a live theme or
  high-contrast visual comparison.
- Captures are `PrintWindow` images for evidence, not pixel-readback parity
  assertions.
- The auxiliary child capture in the existing UIA run is likewise a window
  capture, not a pixel comparison.
