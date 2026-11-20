# WebGPU opt-in corrective pass (Windows, 2026-11-19)

This record covers the final pre-merge corrections to PR
[#209](https://github.com/Carnival-Science/Alicorn/pull/209):

1. build-time opt-in isolation for SDL_GPU consumers and a genuine
   no-wgpu-native build/smoke proof;
2. restoration of the opaque hosted `key_code` contract with a typed
   `Application_Key` route;
3. aligned path filters across the three WebGPU workflows;
4. relabelled macOS packaging evidence.

All commands ran on Windows x64 with Odin
`dev-2026-11-nightly:08539cd` at `C:\odin\odin.exe`, shared wgpu-native
`v29.0.1.1`, AccessKit C `0.23.1`, and an NVIDIA GeForce RTX 2080 SUPER.

## 1. Build-time opt-in isolation

### Problem

Renderer selection was opt-in at runtime, but native consumers compiled the
WebGPU host regardless of which entry point they used:

- `ui/run_webgpu_native.odin` was part of package `ui`, so every native
  `alicorn:ui` consumer compiled it and transitively imported
  `alicorn:host/sdl3` and `vendor:wgpu`.
- `native/sdl_gpu/clipboard.odin` imported `alicorn:host/sdl3` just to forward
  the clipboard compatibility names.
- `native/sdl_gpu` imported `alicorn:host/sdl3` for event/pointer/text mapping
  helpers that contain no WebGPU code.
- `ui/run_sdl3_clipboard.odin` imported `alicorn:host/sdl3` for the clipboard
  adapter.

`vendor:wgpu` evaluates `#exists` and `#panic`s when the pinned native library
is missing, so any of these imports made wgpu-native a build requirement even
for an SDL_GPU application.

### Isolation shape

The coupling was incidental. Three moves removed it:

| Moved code | New package | Why it is WebGPU-agnostic |
| --- | --- | --- |
| `host/sdl3/clipboard.odin`, `clipboard_test.odin` | `host/sdl3/clipboard` (`sdl3_clipboard`) | SDL3 clipboard get/set only |
| clipboard-to-`UI_Host_Services` adapter (was `ui/run_sdl3_clipboard.odin`) | `host/sdl3/clipboard/ui_service.odin` | maps a host service; no renderer/GPU state |
| `host/sdl3/event_mapping.odin`, `input_mapping.odin` and tests | `host/sdl3/input` (`sdl3_input`) | SDL event/key/pointer translation only |
| native WebGPU `run` entry (was `ui/run_webgpu_native.odin`) | `ui/webgpu` (`ui_webgpu`) | the only package that imports `alicorn:host/sdl3` |

`host/sdl3/shared_input.odin` re-exports the input helpers for the WebGPU
host's existing call sites. `native/sdl_gpu` imports `host/sdl3/input` and
`host/sdl3/clipboard` directly. `ui.Hosted_Run_State`,
`ui.run_hosted_config`, and the clipboard adapter are shared through public
package symbols instead of the WebGPU entry.

Resulting graph for a native SDL_GPU consumer:

```text
examples/01_hello -> alicorn:ui
  -> alicorn:runtime
  -> alicorn:native/sdl_gpu
       -> alicorn:host/sdl3/input
       -> alicorn:host/sdl3/clipboard
       -> alicorn:host/sdl3/accessibility
  -> alicorn:host/clipboard
  (no alicorn:host/sdl3, no vendor:wgpu)
```

The only native package that still imports `alicorn:host/sdl3` is the opt-in
`alicorn:ui/webgpu` entry (plus the WebGPU fixture, benchmark, and host tests).

Consumer change: `ui.run_webgpu(...)` is now
`webgpu.run(...)` with `import webgpu "alicorn:ui/webgpu"`.
`examples/16_native_webgpu_ui` was updated and remains the WebGPU smoke
consumer.

### No-wgpu-native proof procedure

Reusable script:
`tools/test_sdl_gpu_without_wgpu_native.ps1` (`-Odin <path>`, optional
`-BuildOnly`). It performs:

1. Resolve the Odin SDK root and verify `vendor/wgpu/wgpu.odin` exists.
2. Move `vendor/wgpu/lib` to `vendor/wgpu/lib.alicorn-disabled` (a previous
   interrupted run is self-healed first).
3. **Negative control:** `odin check examples/16_native_webgpu_ui` must fail
   with `Could not find the compiled WGPU Native library`, proving wgpu-native
   is genuinely unreachable rather than merely shadowed.
4. Build `examples/01_hello` (the SDL_GPU `ui.run` starter) into
   `out/without-wgpu/`.
5. Build `examples/03_async_list`, copy `SDL3.dll`, and run `--smoke`
   (3-second bounded lifecycle; prints the SDL application PASS line).
6. Restore `vendor/wgpu/lib` in `finally`, including on failure.

Manual equivalent (Windows PowerShell):

```powershell
$odin = 'C:\odin\odin.exe'
$lib = 'C:\odin\vendor\wgpu\lib'
Move-Item $lib "$lib.alicorn-disabled"

# Negative control must fail:
odin check examples\16_native_webgpu_ui -collection:alicorn=. `
  -collection:accesskit=.deps\odin-accesskit `
  -collection:accesskit_c=.deps\accesskit\accesskit-c-0.23.1\lib\windows\x86_64\msvc\static
# Expect: "Could not find the compiled WGPU Native library"

odin build examples\01_hello -collection:alicorn=. -out:out\without-wgpu\01_hello.exe
odin build examples\03_async_list -collection:alicorn=. -out:out\without-wgpu\03_async_list.exe
Copy-Item C:\odin\vendor\sdl3\SDL3.dll out\without-wgpu\
.\out\without-wgpu\03_async_list.exe --smoke

Move-Item "$lib.alicorn-disabled" $lib
```

### Result

`tools/test_sdl_gpu_without_wgpu_native.ps1 -Odin C:\odin\odin.exe` exited 0:

```text
Temporarily hid wgpu-native: C:\odin\vendor\wgpu\lib -> C:\odin\vendor\wgpu\lib.alicorn-disabled
Negative control passed: the WebGPU consumer cannot find wgpu-native.
Building the SDL_GPU ui.run starter without wgpu-native
Built ...\out\without-wgpu\01_hello.exe
Building the SDL_GPU async-list example without wgpu-native
Running the SDL_GPU async-list --smoke lifecycle without wgpu-native
async_list_smoke items 10000 builds 3 loaded_builds 2 completion_wakes 1 idle true
SDL application PASS submissions 2 primary_gpu_submissions 2 retired 2 ...
PASS: SDL_GPU consumers build and smoke without wgpu-native; WebGPU consumers still require it.
Restored wgpu-native: C:\odin\vendor\wgpu\lib
```

`vendor/wgpu/lib` was present and `lib.alicorn-disabled` absent after the run.
`git diff --check` was clean, and no build output or source file shadowed the
library. The negative control is the key part of the result: the same
environment cannot compile a WebGPU consumer.

### CI adoption

`.github/workflows/foundation.yml` now runs the script after
`tools/test.ps1` on `windows-latest`:

```yaml
- name: Prove SDL_GPU consumers build without wgpu-native
  shell: pwsh
  run: ./tools/test_sdl_gpu_without_wgpu_native.ps1 -Odin odin
```

`tools/test.ps1` and `tools/test.sh` also run the new
`host/sdl3/input` and `host/sdl3/clipboard` packages, so the moved tests remain
in the foundation suite.

### Prerequisite documentation

`docs/getting-started.md` now states precisely that wgpu-native is a
**WebGPU-only** prerequisite (`v29.0.1.1`, `vendor/wgpu`), lists the Windows
archive and the Linux/macOS bootstrap scripts, and notes that default
`ui.run`, examples 01–14, and the headless checks do not need it.

## 2. Opaque hosted `key_code`

`Hosted_Key_Event.key_code` is opaque again. `hosted_runtime_key` only forwards
the event to the application callback; runtime never interprets a numeric value
as `Application_Key`, so an external host's key space cannot preempt text
fields or interaction scopes.

A new typed route,
`hosted_runtime_application_key(host, key: Application_Key, event)`, owns the
previous preemption policy: text-field/IME guard, interaction-scope dispatch,
then the opaque event to `on_key`. The SDL3 native host uses it for its
translated shortcuts. `docs/hosted-runtime.md` documents both routes.

Regression coverage:

- `test_hosted_runtime_opaque_key_code_never_preempts_application_keys` focuses
  a scope that registers `Find`, sends opaque codes `0x000F_0000` and
  `u32(Application_Key.Find)`, and asserts no scope input is queued while both
  events still reach the application callback. It then calls the typed route
  and asserts exactly one queued `.Find` event and no duplicate app callback.
- `test_hosted_runtime_application_key_respects_text_and_composition_precedence`
  retains the original text-field and IME behavior on the typed route.
- `ui/run_hosted_test.odin` exercises the typed route through the shared
  `ui.run` adapter.

## 3. Workflow path filters

`webgpu-linux.yml`, `webgpu-browser.yml`, and `webgpu-macos.yml` now share the
same 31-entry push and pull-request path lists (each also lists its own
workflow file). A diff of the three filters found no missing shared directory;
the only difference is the workflow file name. Coverage now includes
`renderer/**`, `runtime/**`, `ui/**`, `host/clipboard/**`, `host/sdl3/**`,
`host/web/**`, `host/presentation/**`, `native/**`, all WebGPU examples,
`dependencies/patches/**`, and both platform bootstrap toolchains.

## 4. macOS packaging evidence label

`tools/build_native_release.sh` and `docs/webgpu-migration.md` Phase 4 now state
that the static-wgpu packaging job builds `01_hello`, an SDL_GPU consumer that
does not import wgpu. It proves the existing packaging contract (static SDL3,
no leaked developer rpath) has not regressed; it is **not** evidence that a
production WebGPU application packages with static wgpu-native plus AccessKit.
Desktop acceptance still requires packaging and launching an actual WebGPU
application.

## Verification summary

| Check | Result |
| --- | --- |
| `odin test runtime` | 383 tests passed |
| `odin test ui` | 50 tests passed |
| `odin test host/sdl3` | 1 test passed |
| `odin test host/sdl3/input` | 7 tests passed |
| `odin test host/sdl3/clipboard` | 3 tests passed |
| `odin test host/web` | 14 tests passed |
| `odin test host/presentation` | 6 tests passed |
| `odin test native/sdl_gpu` | 173 tests passed |
| `odin test renderer/webgpu` | 6 tests passed |
| `js_wasm32` feasibility fixture build | passed (5,472,137-byte wasm) |
| No-wgpu-native SDL_GPU build + `--smoke` | passed, negative control failed as expected |
| `examples/16_native_webgpu_ui --smoke --backend=d3d12` | exited 0, D3D12 RTX 2080 SUPER |
| `native_hosted_feasibility.exe --backend=d3d12` | PASS: pointer, app text-key, UTF-8 IME preedit/cancel, resize, lifecycle |
| `native_multi_surface_feasibility.exe --backend=d3d12` | PASS: secondary first presentation, independent focus/pointer, resize, two-surface teardown |
| `tests` foundation executable | PASS |
| `odin test testui` / `theme` / `renderer/cpu` | 13 / 37 / 22 tests passed |
| `odin test native/scroll_capture_tests` | 6 tests passed |
| `native/sdl_gpu_entry --text-input-contract-test` | PASS |
| `tools/test_restoration.ps1` | PASS |

The fixture builds for `js_wasm32` were run with `C:\odin\bin` on `PATH` so
`wasm-ld` resolved. The native `hosted` and `multi-surface` feasibility variants
were rebuilt and run separately; both PASS.

The `tools/test.ps1` wrapper could not complete under this shell's Windows
PowerShell 5.1 because the pinned `odin-accesskit` check script treats Odin's
stderr `[INFO]` lines as terminating native-command errors. CI runs PowerShell 7
(`pwsh`) and the individual affected suites above were executed directly, so
this is a local wrapper limitation rather than a test failure.
