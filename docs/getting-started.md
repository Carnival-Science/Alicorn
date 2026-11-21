# Getting Started

This gets a small native Alicorn application on screen. You will build the
project, run the starter app, change its UI, and run it again.

## 1. Install the prerequisites

Install Git and a **complete Odin distribution** from the
[official Odin installation guide](https://odin-lang.org/docs/install/). Keep
the compiler beside its `base`, `core`, and `vendor` directories; copying only
`odin.exe` or `odin` is not enough. Alicorn's supported compiler baseline is
the official Odin [`dev-2026-11` release](https://github.com/odin-lang/Odin/releases/tag/dev-2026-11).

Also install the native platform tools:

- **Windows:** Visual Studio or Build Tools with **Desktop development with
  C++**, including MSVC and a Windows SDK. Use an Odin distribution with its
  `vendor/sdl3` package and `SDL3.dll`.
- **macOS:** Xcode Command Line Tools (`xcode-select --install`) and SDL3
  `3.4.20` (`brew install sdl3`). Keep the SDL3 version at `3.4.20`; the host
  checks it when it starts.
- **Linux:** a Wayland session, Vulkan-capable SDL3 development and library
  outputs, Fontconfig, `pkg-config`, and a C compiler. `vulkan-tools` and
  `wayland-utils` are recommended for host inventory. On NixOS, the
  [Linux acceptance matrix](validation/linux-native-acceptance.md) uses a
  temporary shell so the system profile is not changed.

Native build helpers check out [odin-accesskit](https://github.com/samanshaiza004/odin-accesskit)
at the exact commit in [`dependencies/odin-accesskit.json`](../dependencies/odin-accesskit.json)
into the ignored `.deps/odin-accesskit/` directory. They invoke its native
bootstrap with Alicorn's existing `.deps/accesskit/` cache, preserving the
AccessKit C `0.23.1` release archive and checksum verification. Network access
is needed on first use, after removing a cache, or when the pin changes. The
helpers pass the binding collection to Odin and do not modify the Odin
installation. The native AccessKit adapter is currently Windows/macOS only.
See [dependency and external consumer usage](../dependencies/README.md) for
manual builds.

### Native WebGPU builds are opt-in and need wgpu-native

There are two renderer paths. The default `ui.run` path, examples 01-14 and
`15_host_owned_sdl_gpu`, and the headless checks render with SDL_GPU and do
**not** need wgpu-native. The opt-in native WebGPU entry lives in
`alicorn:ui/webgpu`; the WebGPU examples (`15_webgpu_feasibility`,
`16_native_webgpu_ui`) require the pinned wgpu-native `v29.0.1.1` library that
matches Odin's `vendor:wgpu` bindings. Install it into the Odin distribution:

- **Windows:** the official Odin Windows archive already contains
  `vendor/wgpu/lib/wgpu-windows-x86_64-msvc-release/`.
- **Linux x86_64:** run
  `sh tools/setup_linux_wgpu_native.sh "$(odin root)"` (or pass the absolute
  Odin root).
- **macOS arm64:** run
  `sh tools/setup_macos_wgpu_native.sh "$(odin root)"`.

If the library is missing, compiling a WebGPU consumer fails with a
`Could not find the compiled WGPU Native library` panic. SDL_GPU consumers are
unaffected. See
[dependencies/webgpu-toolchain.md](../dependencies/webgpu-toolchain.md) for the
pin and hashes.

To try the native WebGPU host, build all examples and run the native UI
fixture. On Windows, `build_examples` stages `SDL3.dll` and the shared
`wgpu_native.dll` beside the executable:

```powershell
.\tools\build_examples.ps1
.\out\examples\16_native_webgpu_ui.exe
```

```sh
./tools/build_examples.sh
./out/examples/16_native_webgpu_ui
```

The browser path uses `ui.run` on `js_wasm32` without the SDK or Linux/macOS
setup scripts. Example 17 builds with its own script and must be served over
localhost because WebGPU requires a secure context:

```powershell
cd examples\17_browser_webgpu_ui
.\build.ps1
python -m http.server 8092 --directory out/web
```

```sh
cd examples/17_browser_webgpu_ui
./build.sh
python3 -m http.server 8092 --directory out/web
```

Open `http://localhost:8092/` in a Chromium-family browser with WebGPU. Browser
evidence in this release is Chromium-family only; Firefox and Safari are
untested.

Put the directory containing `odin` on `PATH`. In a new terminal, verify it:

```text
odin version
```

For matching the tested toolchain, the output should identify
`dev-2026-11`. The official Windows and Apple Silicon release archives report
`dev-2026-11-nightly:9a69916`; the Intel macOS bootstrap builds the signed
`dev-2026-11` source tag because Odin no longer publishes an Intel macOS binary.

## 2. Clone and check the project

```text
git clone https://github.com/Carnival-Science/Alicorn.git
cd alicorn
```

Build the headless examples and run Alicorn's tests:

```powershell
.\tools\check.ps1
```

```sh
./tools/check.sh
```

The check is headless; it does not open a window. The same script and
`.\tools\test.ps1` also compile the native entry point and run the platform
suites. Two harness caveats are recorded for the current toolchain: on Windows
PowerShell 5.1 the AccessKit binding check can abort because a native test
runner writes progress to stderr, which that shell treats as a terminating
error (use PowerShell 7 or run the stages directly), and
`tools/check_web_ui_package.ps1` currently fails to compile the wasm fixture
with `DevicePoll is not declared by wgpu`. See [Development](development.md).

## 3. Run the native starter app

The starter has an **Increment** button and displays its count. Run the command
for your platform:

```powershell
.\tools\native_hello.ps1
```

```sh
./tools/native_hello.sh
```

Close the window to return to the terminal. The Windows runner copies the
matching `SDL3.dll` from the Odin distribution into `out/` before launch. The
macOS runner links against the SDL3 installation from step 1.

For an unsigned distributable folder or `.app`, including the static-SDL release
path and dependency audit, see [Native application packaging](packaging.md).

## 4. Make a change

Open [`examples/01_hello/main.odin`](../examples/01_hello/main.odin).
Try changing `"Hello, Alicorn"` or the button label, save, and rerun the same
native command. The runner rebuilds before launching.

The app keeps its count in an ordinary Odin struct. Its render procedure
describes text and a button; when the button activates, the app updates that
struct. `ui.run` supplies the routine single-window host and frame lifecycle.
That is enough to start building your own UI.

## Explore the form example

The form uses only `alicorn:ui` for layout, text, a managed controlled text
field, and pointer-bound checkbox and slider. Informational text and standard
controls expose their accessibility semantics by default; use
`decorative=true` for text that should remain visual-only:

```powershell
.\tools\run_example.ps1 -Example 02_form
```

```sh
./tools/run_example.sh 02_form
```

The app source is [`examples/02_form/main.odin`](../examples/02_form/main.odin).
Browse icons and named icon buttons in the
[Control Gallery](../examples/08_control_gallery/main.odin).
The [Retained Motion example](../examples/09_retained_motion/main.odin) shows a
decorative retained indicator driven by the native motion clock and scheduler.
Continue through the [numbered example progression](../examples/README.md) for
worker-backed virtualization, custom GPU surfaces, and the built-in inspector.
Step 3 keeps the same typed render procedure and `alicorn:ui` import, adding
app-owned workers through `ui.run` lifecycle hooks and a scoped virtual list.

## If Odin is not on `PATH`

You can point a single command at the compiler instead:

```powershell
.\tools\check.ps1 -Odin 'C:\dev\Odin\odin.exe'
```

```sh
./tools/check.sh --odin /opt/odin/odin
```

Or set `ALICORN_ODIN` for the current shell. Install the full Odin
distribution before using a custom compiler path.

## Platform status

The native path is exercised on Windows and macOS. Linux has a conditional
validation record from one NixOS 26.11/Mango 0.16.2 Wayland machine, but this is
not broad Linux support, Linux has no AccessKit adapter, and the native app
remains experimental. See the
[Linux validation record](validation/linux-nixos-mangowc-2026-10-23.md) and the
[repeatable acceptance matrix](validation/linux-native-acceptance.md).

The opt-in WebGPU host has Windows D3D12/Vulkan validation and CI smoke
evidence on macOS Metal and Linux lavapipe; physical macOS/Linux WebGPU
sessions are still pending. The browser target is Chromium-family only in this
release.

If a build fails, check `odin version`, the platform prerequisites above, and
the compiler's complete `base`, `core`, and `vendor` installation. The
[application guide](guide.md) is the next step after the window appears.
