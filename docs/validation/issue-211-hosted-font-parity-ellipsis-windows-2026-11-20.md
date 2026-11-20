# Hosted font initialization parity and the U+22EF Pinned control

Windows x64, NVIDIA GeForce RTX 2080 SUPER, 2026-11-20

Alicorn `codex/issue-211-scratchpad-webgpu` (this slice)
Scratchpad `codex/issue-211-webgpu-frontend` @ `b458d6e`, candidate root this
branch, `--allow-alicorn-revision`, no Scratchpad source or lock change.

## Symptom and scene

The hosted WebGPU Scratchpad build drew the Pinned card's "more actions" button
as a missing-glyph box. The control is a text button labelled U+22EF
HORIZONTAL MIDLINE ELLIPSIS (`frontends/alicorn/pinned_surface.odin:998-1004`)
at 20 px.

Both legs used one restored Scratchpad session (workspace
`C:\Users\saman\dev\scratchpad`, active README document, two pinned ranges),
the same 1216x799 window, and the opt-in `SCRATCHPAD_PINNED_FIXTURE=1` capture
fixture. The hosted leg captured automatically at 25 s; the SDL_GPU leg captured
with F12 after the fixture settled.

## What each backend resolved

| Build | Font stack before the slice | U+22EF result |
| --- | --- | --- |
| Hosted WebGPU (pre-fix binary @ Alicorn `3df0f69`) | bundled Atkinson only (0 fallback faces) | `.notdef`: primary face id 1, glyph 0, a box |
| SDL_GPU reference (pre-fix) | bundled + 5 DirectWrite faces + `NotoSansJP-VF.ttf` | face id 10, glyph 17470 (real glyph) |
| Hosted WebGPU after the fix | identical shared stack | face id 10, glyph 17470 |
| SDL_GPU reference after the fix | identical shared stack | face id 10, glyph 17470 |

`runtime/text.odin`/`text_run_build` with the bundled-only stack produced
`gid=0 face=1 source=Primary`; with the reference stack it produced
`gid=17470 face=10 source=Fallback`. A direct probe of the registry showed the
five DirectWrite faces do **not** cover U+22EF and face 10 is the optional UI
fallback (`C:/Windows/Fonts/NotoSansJP-VF.ttf`, shaped glyph 17470).

Coverage facts on this machine:

| Face | U+22EF |
| --- | --- |
| bundled Atkinson Next / Mono | absent |
| `segoeui.ttf` | absent |
| `consola.ttf` | absent |
| `NotoSansJP-VF.ttf` | present (shaped glyph 17470) |
| `seguisym.ttf` | present (not registered by the startup contract) |

So the reference's pre-fix success was incidental: on a Windows machine without
Noto Sans JP, the reference would fall back to `segoeui.ttf` and also draw the
box. The hosted-only observation was a font-initialization parity gap, and the
bundled stack has a general coverage gap behind it.

## Fix 1: one desktop font stack for both hosts

`native/sdl_gpu/fonts*.odin` moved to a new `alicorn:host/fonts` package.
`load_default_fonts` installs the bundled default faces, the bounded Windows
DirectWrite startup mappings, and the optional UI/monospace fallbacks. The
reference host (`native/sdl_gpu/main.odin`), `ui.run`'s native path, and
`ui/webgpu.run` all call it. `native/sdl_gpu/fonts.odin` keeps thin aliases for
the existing validation fixtures.

`host/fonts` is `#+build !js`; the browser `ui/webgpu.run` path still loads
bundled defaults only and is documented as such.

`runtime/inspector.odin` now records, per text run (including button labels):

```text
  text run: valid=true bytes=3 paint-spans=0 style-spans=0 faces=[10] unresolved=false
  text fallback glyphs: [0,3)face=10 gid=17470
```

`faces` is the ordered distinct face list (bounded to 8), `unresolved` is the
runtime's missing-coverage marker, and the fallback line reports up to four
fallback glyphs with byte range, face id, and shaped glyph id. A capture bundle
can now distinguish a resolved fallback from a `.notdef` box without a
screenshot, on either host.

## Fix 2: a semantic icon for "more actions"

The control should not depend on an optional system face. Alicorn now ships a
15th built-in icon, `More_Horizontal` (Reicon filled `ui/more-h`, pinned
revision, regenerated atlas): `icon_button(ui, "More actions",
.More_Horizontal, ...)` paints a theme-tinted coverage mask with no text run and
keeps the explicit accessible name. The Pinned control can adopt it without any
font fallback.

Exact Scratchpad-side change (not applied here; Scratchpad is read-only for this
slice), in `frontends/alicorn/pinned_surface.odin`:

1. Replace the body of `pinned_more_button` with
   `id, clicked := alicorn.icon_button(ui, "More actions", .More_Horizontal,
   key=alicorn.key_string("pinned-more"), style=alicorn.layout_style(.Row,
   width=32, height=32), variant=.Quiet)`.
2. Keep `alicorn.semantic_description(ui, .Button, "More actions",
   actions={.Press, .Focus})`, `Pinned_Control{id, pin, "more"}`, and the
   `pinned_open_action_menu` call unchanged.
3. Delete the `text_style=Text_Style{font_size=20}` argument; the icon has no
   text run and its size comes from the 32x32 button style.
4. `frontends/alicorn/pinned_surface_test.odin` does not assert the glyph text;
   its layout/semantics checks keep working with the icon. Optionally add an
   assertion that the `pinned-more` node paints `.More_Horizontal` so the
   font-independent control stays pinned in the consumer suite.

Alicorn-side regression: `runtime/icons_test.odin`
`test_more_horizontal_icon_button_needs_no_text_glyph` asserts the icon paint,
no text command/run, and the accessible name.

## Regression tests

- `host/fonts/fonts_test.odin`
  - `test_canonical_stack_resolves_midline_ellipsis_when_platform_faces_cover_it`
    pins the resolved face/glyph for U+22EF, or the unresolved `.notdef` marker
    when the machine has no covering optional face.
  - `test_hosted_and_reference_initialization_choose_the_same_face` asserts two
    independent `load_default_fonts` runtimes expose the same face stack and the
    same face/glyph/source for the codepoint.
  - The existing DirectWrite CJK/color-emoji and Fontconfig tests moved with the
    implementation.
- `runtime/text_resolution_diagnostics_test.odin` asserts the inspector emits
  `faces=[1] unresolved=true` for the bundled-only glyph and does not claim
  fallback provenance.
- `runtime/icons_test.odin` validates every `Icon_ID` (now 15) at every physical
  size and pins the `More_Horizontal` control shape.

## Validation (Windows x64)

Alicorn:

- runtime 412/412, host/fonts 5/5, ui 50/50, testui 13/13, theme 37/37,
  renderer/cpu 23/23, host/sdl3 7/7, live_resize 9/9, input 8/8, clipboard 3/3,
  dialogs 5/5, host/menus 8/8, host/web 14/14, host/diagnostics 9/9,
  native/sdl_gpu 166/166, native/scroll_capture 6/6,
  accessibility_contract 1/1, the headless `alicorn_tests.exe`,
  restoration checks, and the text-input contract all pass.
- `python tools/test_icon_assets.py` 7/7;
  `python tools/generate_icon_atlas.py --resvg .deps/icon-tools/bin/resvg.exe
  --verify` verifies all 5 generated artifacts.
- Example 16 built with `-define:WGPU_SHARED=true`; all seven smokes
  (`--smoke`, `--workbench-smoke`, `--titlebar-smoke`, `--child-chrome-smoke`,
  `--menu-smoke`, `--services-smoke`, `--tab-drag-smoke`) exit 0 on D3D12,
  Vulkan, and SDL_GPU (21/21). D3D12/Vulkan `--smoke`/`--workbench-smoke` in
  this automation session present and exit 0 without the timing/workload
  instrumentation lines; the same behavior occurs with an example 16 binary
  built from `062b772` without this slice's changes.

Scratchpad:

- `go run ./cmd/alicorn-dev smoke --renderer webgpu --backend d3d12`,
  `--backend vulkan`, and `--renderer sdl-gpu` (candidate root this branch):
  `publication_rendered true wake_observed true ordered_shutdown true
  session_restore true` on all three, including the clean and recovery session
  legs.

Pixel parity re-check (same pinned scene, 1216x799):

| Pair | Differing channels | Max | Differing pixels | Bounding box |
| --- | --- | --- | --- | --- |
| hosted **before** vs SDL_GPU reference | 642 / 2,914,752 | 130 | 214 | (1176,96)-(1193,304) |
| hosted **after** vs SDL_GPU reference | **0 / 2,914,752** | 0 | 0 | - |

The pre-fix difference is exactly the two `pinned-more` button rectangles
(second card at y=281); no other pixel changed. Both post-fix frames also have
identical `text run:` lines for both controls:

```text
  text run: valid=true bytes=3 paint-spans=0 style-spans=0 faces=[10] unresolved=false
  text fallback glyphs: [0,3)face=10 gid=17470
```

The only inspector differences are frame/semantics round counters and the F12
key event itself; all 114 text-run lines and all span tuples match.

Evidence:

- `docs/validation/assets/issue-211-pinned-more-before.png` (hosted pre-fix
  crop; missing-glyph boxes)
- `docs/validation/assets/issue-211-pinned-more-after.png` (hosted post-fix
  crop; three dots)
- `docs/validation/raw/scratchpad-pinned-ellipsis-hosted-2026-11-20.txt`
- `docs/validation/raw/scratchpad-pinned-ellipsis-sdl-gpu-2026-11-20.txt`

## Harness limits

- This automation session runs Windows PowerShell 5.1. `tools/test.ps1` cannot
  complete there because `.deps/odin-accesskit/tools/check.ps1` sets
  `$ErrorActionPreference = 'Stop'` and a native test runner writes progress to
  stderr, which PS 5.1 turns into a terminating error. The same commands were
  run directly (including the AccessKit binding check and tests) and all pass;
  the standard script is unchanged for PowerShell 7.
- `tools/check_web_ui_package.ps1` fails on this branch and on a clean
  `062b772` checkout with `'DevicePoll' is not declared by 'wgpu'` under
  `-target:js_wasm32` with the installed `dev-2026-11-nightly:08539cd`
  toolchain. This slice adds no wasm error; `odin check runtime -target:js_wasm32`
  passes after guarding the new host/fonts package.
- Synthetic OS pointer input still cannot be delivered to the Scratchpad window
  in this session; the Pinned fixture, F12, and the capture path work. The
  founder's hands-on click of the control remains the confirming interaction.
