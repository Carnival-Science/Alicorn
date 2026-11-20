# Tab drag reorder preview fidelity (Windows, 2026-11-20)

Issue #211 Stage C slice 2. Founder testing of the hosted WebGPU Scratchpad build
reported that the dragged tab rendered as a dark, empty ~96x28 rectangle instead
of the real tab. This record covers the root cause, the fix, and the parity
evidence against the SDL_GPU reference.

Environment: Windows x64, NVIDIA GeForce RTX 2080 SUPER, Odin `C:\odin\odin.exe`,
Alicorn `codex/issue-211-scratchpad-webgpu` at `3df0f69` plus this slice.
Hosted backends: D3D12 and Vulkan through `host/sdl3` + `renderer/webgpu`.
Reference: `--backend=sdl-gpu` (`native/sdl_gpu`).

## Root cause

The fallback is `drag_preview_begin`'s last resort in `runtime/drag_drop.odin`:
a 96x28 dark card painted when no preview content could be produced. A probe
that described Scratchpad's titlebar tab bar and dragged through the hosted
runtime showed:

```text
magnetic false preview Label tabA Rect{x = 6, y = 6, w = 160, h = 32} tabB Rect{x = 166, y = 6, w = 160, h = 32}
after-start drag_phase Dragging mode Label ready false w 96 h 28 commands 0
  overlay 10 owner 0 text false bounds Rect{x = 2, y = 3, w = 96, h = 28}
  overlay 11 owner 0 text false bounds Rect{x = 0, y = 0, w = 96, h = 28}
```

Two combined causes, neither hosted-specific:

1. `Drag_Preview_Mode.Label` was the enum's zero value and therefore the default
   for any `Tab_Bar_Options` that did not set `drag_preview_mode`. Scratchpad's
   hosted frontend enables `drag_type` and `animate_drag_reorder` but not the
   preview mode. The reference Scratchpad branch sets `.Source_Subtree`
   explicitly, which is why the SDL_GPU app looked right.
2. A tab is a composed button: the tab root's own `label`/`text` are empty and
   its visible name is a child text node. The label path had nothing to shape, so
   `drag_preview.ready` stayed false and the card kept its 96x28 default.

The hosted capture path itself was sound. With `.Source_Subtree` requested, the
hosted pointer route and the reference `process_pointer` + presentation-frame
route captured the identical three commands (`mode=Source_Subtree ready=false
w 160 h 32 commands 3`), including the tab surface, its text run and its
zero-height indicator. Text-resource lifetime, transient translation updates and
stacking were already host-neutral.

## Fix

- `runtime/runtime.odin`: `Drag_Preview_Mode` gained `Auto = 0` before `Label`
  and `Source_Subtree`.
- `runtime/tab_bar.odin`: `Auto` resolves to `.Source_Subtree` for tab bars, so
  the dragged tab is lifted with its real contour, label and state. `.Label`
  remains available as an explicit opt-out.
- `runtime/drag_drop.odin`: `drag_preview_source_label` resolves a label preview
  from the first painted descendant text run when the source node has no label
  of its own (value, size, font, weight and style spans). The preview shapes an
  owned copy, so the borrowed run may retire with its node.
- `runtime/inspector.odin`: capture bundles record the drag session and up to 16
  preview paint commands.

No paint-pipeline behavior changed: the lifted copy is still appended at the
display tail, clipped by the window viewport, translated by
`drag_preview_pointer_moved` without a display rebuild, and the source slot is
still hidden by `drag_source_opacity`.

## Evidence

### Fixture smoke, identical on all three backends

`16_native_webgpu_ui --tab-drag-smoke` prints one line per host:

```text
tab_drag_smoke PASS mode=Source_Subtree ready=false commands=3 size=150.0x32.0 tab=150.0x32.0 size_ok=true text="Alicorn Overvi." text_found=true marker=true source_hidden=true neighbor_visible=true topmost=true owner_zero=true viewport_clip=true translation=150.0,0.0 drop_target 2 drop_position After
```

### Mid-drag capture bundles

`tools/validate_native_webgpu_tab_drag.ps1` runs the fixture with
`--diagnostics --capture-after=1 --capture-dir=...`, focuses the window, presses
F12, and keeps the bundle whose `inspector.txt` contains
`drag: phase=Dragging`. Raw lines:

- [hosted D3D12](../validation/raw/tab-drag-preview-hosted-d3d12-2026-11-20.txt)
- [hosted Vulkan](../validation/raw/tab-drag-preview-hosted-vulkan-2026-11-20.txt)
- [SDL_GPU reference](../validation/raw/tab-drag-preview-sdl-gpu-2026-11-20.txt)

Hosted D3D12 and Vulkan are byte-identical. The reference differs only in node
IDs and the absolute display index (`display-start=14` instead of `13`; the
reference list has one extra earlier command):

```text
drag: phase=Dragging ... position=After state=Horizontal_Track tracking=Horizontal_Magnetic preview=(mode=Source_Subtree ready=false 150.0x32.0 display-start=13 commands=3)
  preview[0] index=13 kind=surface bounds=(269.0,0.0 150.0x32.0) clip=(0.0,0.0 736.0x519.0) translation=(150.0,0.0) opacity=1.00 text=""
  preview[1] index=14 kind=text    bounds=(289.0,6.0 110.0x20.0) clip=(0.0,0.0 736.0x519.0) translation=(150.0,0.0) opacity=1.00 text="Alicorn Overvi."
  preview[2] index=15 kind=surface bounds=(269.0,31.0 150.0x0.0) clip=(0.0,0.0 736.0x519.0) translation=(150.0,0.0) opacity=1.00 text=""
```

### Pixel comparison of the drag frame

Both bundles carry `screenshot.ppm` for the same 736x519 drawable. Comparing the
hosted D3D12 drag frame with the SDL_GPU drag frame:

```text
full frame differing pixels 0 of 381984 max channel delta 0
preview rect differing pixels 0 of 4800 max channel delta 0
```

### Suites and app validation

- Suites run individually with the pinned AccessKit arguments: runtime 410
  (includes the three new fixtures), host/sdl3, host/sdl3/live_resize,
  host/sdl3/input, host/sdl3/clipboard, host/sdl3/dialogs, host/menus, host/web,
  host/diagnostics, host/presentation, renderer/webgpu, renderer/cpu, ui,
  testui, theme, native/sdl_gpu (169), native/scroll_capture_tests,
  `odin build tests` and `out/alicorn_tests.exe`, and the accessibility contract
  fixture. All pass.
- All examples build with `tools/build_examples.ps1`'s arguments. Example 16
  passes `--smoke`, `--workbench-smoke`, `--titlebar-smoke`,
  `--child-chrome-smoke`, `--menu-smoke`, `--services-smoke` and
  `--tab-drag-smoke` on `--backend=d3d12`, `--backend=vulkan` and
  `--backend=sdl-gpu` (21/21).
- Scratchpad (`codex/issue-211-webgpu-frontend` at `b458d6e`, candidate root this
  branch, no Scratchpad source or lock file changed) built with
  `--allow-alicorn-revision` and passed both smoke legs on
  `--renderer=webgpu --backend=d3d12`, `--renderer=webgpu --backend=vulkan` and
  `--renderer=sdl-gpu` (`publication_rendered`, `wake_observed`,
  `ordered_shutdown`, `session_restore` all true).

## Residual work and hands-on items

- This automation session cannot deliver synthetic OS pointer input to the
  Scratchpad window (same limitation as Stage B slice 5): host keys arrive,
  pointer motion does not. The Scratchpad drag is verified at the hosted-runtime
  seam and by the instrumented example 16 fixture, not by a pixel capture of the
  real app. The founder's real tab drag is the confirming check.
- Neighbor "make room" motion is application policy (`Tab_Bar_Result.item_nodes`
  + `ui.motion`). Scratchpad implements it; the example 16 fixture does not, so
  its source slot is simply empty.
- A source that painted nothing at drag start still falls back to the label
  card; with the descendant-label resolution it now shows that source's text
  instead of an empty rectangle.
