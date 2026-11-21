# Alicorn

Alicorn is an experimental native GUI runtime for [Odin](https://odin-lang.org/).
Describe a UI with ordinary Odin code; Alicorn retains identity, interaction,
layout, text, and rendering products between updates.

The beginner path is deliberately direct:

```odin
import ui "alicorn:ui"

App :: struct { saved: bool }

render :: proc(app: ^App, ctx: ^ui.UI) {
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Hello, Alicorn")
		if ui.button(ctx, "Save") { app.saved = true }
	}
}

main :: proc() {
	app := App{}
	ui.run(&app, render, title="Alicorn", width=720, height=480)
}
```

<p align="center">
  <img src="assets/screenshots/scratchpad-on-alicorn.png" alt="Scratchpad running on Alicorn, with the workspace file tree and JSON editor visible" width="800" />
</p>

<p align="center"><sub>Scratchpad editing <code>caliber.config.json</code> with its workspace file tree open.</sub></p>

Application state stays in your code. `ui` lowers into the same retained
Runtime as the lower-level API; it adds no application state store or second
widget tree. The API is still evolving, and Alicorn is not production-ready.

## What it provides

- **Direct to write, retained to run.** Procedural `alicorn:ui` authoring over a
  dirty-driven retained Runtime: identity, layout, shaping, paint, interaction,
  and semantics survive descriptions instead of being rebuilt.
- **Two renderer paths.** SDL_GPU is the default, complete production renderer
  and the visual reference. An opt-in WebGPU renderer serves native SDL3 hosts
  and Chromium-family browsers through the same retained paint stream; it is
  experimental and does not replace SDL_GPU yet.
- **Native host services.** Menus and accelerators, integrated titlebar chrome,
  file dialogs, deferred close, a per-surface scheduler, synchronous clipboard,
  native file drag-out and drop-in, secondary windows, and renderer-neutral
  diagnostics (F10 HUD, F11 bounds, F12 capture).
- **Retained UI products.** Surface-local positioned text for rulers and
  timelines, per-corner surfaces, two-stop gradients, bounded shape primitives,
  icons and images, virtualized collections, retained motion, typed themes, and
  an AccessKit bridge for Windows UI Automation and macOS accessibility.
- **Shared hosted API.** `alicorn:runtime`'s `Hosted_Runtime` and
  `alicorn:ui/webgpu` expose the same application callbacks as the reference
  host for applications that own their window and event loop.

**New to Alicorn?** Follow [Getting Started](docs/getting-started.md) to install
the prerequisites, build the project, and run an editable native example. Then
run the [Control Gallery](examples/08_control_gallery/README.md), the single
native tour of forms, collections, tabs, layout, surfaces, overlays, menus,
motion, and themes. Its patterns are collected as copyable
[component recipes](docs/recipes.md).
For the current release's scope and limitations, see the
[changelog](CHANGELOG.md), which consolidates the v0.1.0, v0.2.0, v0.2.1, and
v0.2.2 release notes.

For the reusable native distribution path, see
[Native application packaging](docs/packaging.md).

Browse the [documentation index](docs/README.md) for the complete guide map.
Then explore the [progressive application guide](docs/guide.md),
[API reference](docs/reference.md),
[Choosing Alicorn](docs/choosing-alicorn.md), [examples](examples/README.md),
[typed themes](docs/themes.md),
[performance evidence](docs/performance.md), [architecture](docs/architecture.md),
the [hosted UI loop contract](docs/hosted-runtime.md), the
[WebGPU migration plan](docs/webgpu-migration.md),
or [contributor guide](docs/development.md). The current Linux evidence is
recorded in the [NixOS/Mango validation report](docs/validation/linux-nixos-mangowc-2026-10-23.md).

**Accessibility status:** Alicorn has an experimental AccessKit bridge for
Windows UI Automation and macOS accessibility. Maintainer-confirmed physical
checks include Narrator/NVDA and VoiceOver interaction, editable controls,
modal boundaries, and bounded virtualized content. Linux has no platform
adapter, and this is not comprehensive accessibility conformance; see the
[final acceptance matrix](docs/validation/issue-103-final.md) and the guide's
[accessibility status](docs/guide.md#accessibility-status).
The reusable Odin binding lives in [odin-accesskit](https://github.com/samanshaiza004/odin-accesskit);
Alicorn pins it in [`dependencies/odin-accesskit.json`](dependencies/odin-accesskit.json).
It is separate from Alicorn's semantic projection and SDL window integration.

For live debugging, the native host includes an opt-in
[visual inspector](docs/development.md#native-diagnostics): retained tree,
focus, work counters, and recent causes, rendered using Alicorn itself.

## Platforms

- **Windows** — the native SDL3 host is validated on D3D12 and Vulkan,
  including UI Automation, hosted chrome, and the opt-in WebGPU path.
- **macOS** — the native SDL3/Metal host is validated. WebGPU has CI smoke and
  compile-checked chrome, but physical macOS runs are pending. Development
  packages are ad-hoc signed; distribution signing and notarization remain
  application responsibilities.
- **Linux (Wayland)** — conditional native evidence from one NixOS/Mango
  machine, not broad support; there is no AccessKit adapter. WebGPU has
  lavapipe CI smoke only.
- **Browser** — the same `alicorn:ui` sources run on `js_wasm32` with WebGPU in
  Chromium-family browsers over HTTPS or localhost. Firefox/Safari, native
  menus, dialogs, close policy, and synchronous clipboard are not covered.

## Acknowledgements

Alicorn is its own experiment, but its design has been informed by ideas and
work from other GUI projects:

- [Shirei](https://github.com/hasenj/go-shirei) for direct application-facing
  UI authoring and practical GUI applications.
- [GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui) and
  [Fenestra](https://github.com/richer-richard/fenestra) for thoughtful
  explorations of desktop UI architecture and developer tooling.
- [Dear ImGui](https://github.com/ocornut/imgui) and
  [egui](https://github.com/emilk/egui) for the lesson that UI interaction can
  live beside application logic without a parallel application-owned widget
  state graph.
- [Xilem and Masonry](https://github.com/linebender/xilem) for work on
  incremental UI systems and retaining or pruning derived work.
- [Skald](https://github.com/BuLEEto/Skald) for advancing GUI development in
  Odin and as the project where the work that became Runa began.

The runtime is built with [Odin](https://odin-lang.org/) and its native host
uses [SDL3](https://www.libsdl.org/) with SDL_GPU by default or an opt-in WebGPU
renderer. A browser target (`js_wasm32`) runs the same UI and retained Runtime
on WebGPU in Chromium-family browsers. Text shaping and rasterization are
provided by [Runa](https://github.com/BuLEEto/Runa), vendored in
[`third_party/Runa`](third_party/Runa). These acknowledgements distinguish
design influences from technical foundations; they are not a complete
dependency or licensing inventory. See the relevant component directories
and notices for third-party terms.

## License

Project Alicorn is released under the [zlib License](LICENSE). Bundled fonts
and other third-party components keep their own notices; see
[`assets/fonts/README.md`](assets/fonts/README.md) and the relevant directories.
