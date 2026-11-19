# Native WebGPU UI interactive validation — Windows

Captured 2026-11-19 from the Phase 0 migration worktree at commit `4d3643c`
(`codex/webgpu-phase0-feasibility`) on Windows x64 build `10.0.19045` with Odin
`dev-2026-11-nightly:08539cd`, the Odin-pinned wgpu-native `v29.0.1.1`, and an
NVIDIA GeForce RTX 2080 SUPER (driver `595.97`). Display scale was 1.0. Both
runs used the interactive desktop; each native window was visible for only the
7–8 seconds required by the script and was then closed.

This record covers the native `ui.run_webgpu` path of
`examples/16_native_webgpu_ui` under real SDL3 window input. It does not cover
the browser host, SDL_GPU reference behavior, device loss, or menus.

## Build

The optimized example was built with the repository-pinned AccessKit compiler
arguments (the validated shared native AccessKit library configuration) and the
shared wgpu-native library:

```powershell
. .\tools\common.ps1
$AccessKit = Get-AlicornAccessKit
New-Item -ItemType Directory -Force out\webgpu-phase0\interactive-2026-11-19 | Out-Null
& C:\odin\odin.exe build examples\16_native_webgpu_ui `
  -collection:alicorn=. -define:WGPU_SHARED=true -o:speed `
  -out:out\webgpu-phase0\interactive-2026-11-19\native_webgpu_ui.exe `
  @($AccessKit.CompilerArguments)

Copy-Item C:\odin\vendor\sdl3\SDL3.dll `
  out\webgpu-phase0\interactive-2026-11-19\SDL3.dll -Force
Copy-Item C:\odin\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll `
  out\webgpu-phase0\interactive-2026-11-19\wgpu_native.dll -Force
```

Smoke runs of the same executable reported the expected D3D12 and Vulkan
adapters and exited with code 0 before the interactive passes.

## Automation

`tools/validate_native_webgpu_ui.ps1` starts the example on one backend, waits
for its visible `SDL_app` window, brings it to the foreground, and drives the
application with Windows UI Automation plus real input:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\validate_native_webgpu_ui.ps1 `
  -Executable .\out\webgpu-phase0\interactive-2026-11-19\native_webgpu_ui.exe `
  -Backend d3d12 -OutputDir .\out\webgpu-phase0\interactive-2026-11-19\run-d3d12
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\validate_native_webgpu_ui.ps1 `
  -Executable .\out\webgpu-phase0\interactive-2026-11-19\native_webgpu_ui.exe `
  -Backend vulkan -OutputDir .\out\webgpu-phase0\interactive-2026-11-19\run-vulkan
```

The script uses `System.Windows.Forms.SendKeys` for physical-style key events,
`SendInput` with `KEYEVENTF_UNICODE` for a non-ASCII codepoint, and
`System.Windows.Automation` for the tree dump, pattern checks, focus reads and
button invocation. It records a PASS/FAIL/UNTESTED row per check and retries a
failed step once before recording it. Neither backend needed a retry.

Artifacts:

- `docs/validation/raw/native-webgpu-ui-interactive-d3d12-2026-11-19.txt` and
  `...-vulkan-...txt`: full per-check logs.
- `docs/validation/raw/native-webgpu-ui-interactive-d3d12-uia-2026-11-19.txt`
  and `...-vulkan-uia-...txt`: initial, post-input, auxiliary, and final UIA
  trees.
- `docs/validation/assets/native-webgpu-ui-interactive-{d3d12,vulkan}-2026-11-19.png`
  and the matching `-auxiliary-` captures: post-run `PrintWindow` captures of
  the primary and resized auxiliary windows.

## Results

| Check | D3D12 | Vulkan | Detail |
| --- | --- | --- | --- |
| Main window created and focused | PASS | PASS | visible `SDL_app` window, foreground confirmed |
| UIA tree exposes the fixture | PASS | PASS | 9 elements: window, 2 headings, 3 buttons, 2 status texts, 1 edit |
| Text field name, `ValuePattern`, `TextPattern` | PASS | PASS | name `Try native text input`, initial value `Type here` |
| UIA `SetFocus` on text field | PASS | PASS | focused element read back as the edit |
| Physical clear (`Ctrl+A`, `Backspace`) | PASS | PASS | value became empty |
| Physical ASCII typing | PASS | PASS | `Native input ok` reflected through `ValuePattern` |
| Unicode codepoint input | PASS | PASS | `é` (U+00E9) via `SendInput` `KEYEVENTF_UNICODE`; not an IME composition |
| Tab traversal | PASS | PASS | 8 tabs cycle `Open auxiliary window` → `Increment` → `Queue application wake` → text field, twice |
| Shift+Tab reverse traversal | PASS | PASS | from text field to `Queue application wake` |
| `InvokePattern` on `Increment` | PASS | PASS | status text became `Button activations: 1` |
| `InvokePattern` on wake button | PASS | PASS | status text became `Application wake callbacks: 1` |
| Auxiliary window open | PASS | PASS | real keyboard `Space` on the Tab-focused "Open auxiliary window" button |
| Auxiliary window title/UIA tree | PASS | PASS | `Alicorn auxiliary window`; 4-element tree incl. `Close auxiliary window` |
| Auxiliary resize | PASS | PASS | `SetWindowPos` 576×359 → 760×420; post-resize capture shows the child layout painted at the new size |
| Auxiliary close | PASS | PASS | `InvokePattern` destroyed the window; primary window stayed alive |
| Primary state after auxiliary lifecycle | PASS | PASS | text still `Native input ok` |
| Main window close / process exit | PASS | PASS | `WM_CLOSE`, exit code 0 |
| Clipboard shortcuts | UNTESTED | UNTESTED | fixture has no clipboard control; native text editing has no clipboard path |
| IME composition | UNTESTED | UNTESTED | Unicode text delivery was exercised; no TSF/IME composition session was driven |
| Menus and integrated titlebar | UNTESTED | UNTESTED | this fixture has no menu or custom titlebar |
| Screen-reader speech | UNTESTED | UNTESTED | UIA tree and patterns were read programmatically; Narrator/NVDA were not run |

The two status updates (`Button activations: 1`, `Application wake callbacks: 1`)
were read back from the live UIA tree, so they also verify incremental semantic
updates after UIA activation, not just initial projection.

## UIA tree summary

The primary window exposes a `ControlType.Window` named `Alicorn` (`SDL_app`
class) with `ControlType.Text` headings and status lines, three
`ControlType.Button` elements (`Increment`, `Queue application wake`,
`Open auxiliary window`), and one `ControlType.Edit` (`Try native text input`).
The buttons expose `InvokePattern`; the edit exposes `ValuePattern` and
`TextPattern`. The auxiliary window exposes its heading, explanatory text, and
`Close auxiliary window` button with the same patterns.

One adapter property is worth recording for the accessibility follow-up: UIA
reports `IsKeyboardFocusable=false` for all three buttons, yet Tab and Shift+Tab
move keyboard focus to them and Space activates the focused auxiliary-window
button. Both backends behaved identically. Assistive technology that gates
navigation on `IsKeyboardFocusable` may therefore skip controls that the
application can still focus by keyboard.

## Regression checks

`tools/test.ps1` aborted in the pinned AccessKit dependency's native UIA example
check with `Accessible Button missing`. That check starts the dependency example
hidden and then selects the last top-level window for the process without
filtering window class or visibility; the process also owns a console window and
IME windows, so enumeration order decides whether the script finds the
application. The same dependency check passed intermittently (3 of 7 attempts)
and is unrelated to this fixture. With that dependency example step skipped
(`check.ps1 -SkipNativeExample`), the rest of `tools/test.ps1` passed: 363 core,
11 native host, 14 web host, 42 UI, 13 test UI, 37 theme, 22 CPU renderer, 172
native SDL_GPU, 6 scroll-capture, plus the accessibility contract, package
build, theme CLI, restoration and text-input-contract checks.

## Limits

- Both passes were single scripted runs on one machine and one desktop session;
  no check was repeated after the first success and none failed/retried.
- The automation used a real desktop window and real `SendInput`/`SendKeys`
  events, but the text content and timing were scripted. Human-perceived typing
  latency, key repeat, dead keys, IME candidate windows, composition styling,
  and physical clipboard behavior remain untested.
- `Ctrl+A`/`Backspace`/`Tab`/`Shift+Tab`/`Space` and ASCII typing went through
  the SDL3 keyboard path. The Unicode codepoint used the same `SendInput`
  Unicode packet path, which reaches SDL3 as text input, not as an IME
  composition.
- The auxiliary-window capture is a `PrintWindow` image, not a pixel readback
  comparison. The resize check confirms geometry and that a post-resize capture
  contains the child layout; it does not measure present latency.
- Clipboard, menus/titlebars, genuine device loss and recovery, Narrator/NVDA
  speech output, high-DPI interaction, and macOS/Linux behavior remain open.
