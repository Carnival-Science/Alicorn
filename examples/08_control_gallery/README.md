# 08 · Control Gallery

The Control Gallery is a native example built with `alicorn:ui`,
`alicorn:runtime`, and the SDL_GPU host. The Signal Workbench opens first.
Try a waveform preset, change the gain, and move the playhead. The Ember
and Paper buttons switch the entire gallery's palette.

Run it from the repository root:

```powershell
.\tools\run_example.ps1 -Example 08_control_gallery
```

```sh
./tools/run_example.sh 08_control_gallery
```

The legacy `tools/widget_gallery.ps1` / `tools/widget_gallery.sh` runner still
launches this example.

## Sections

The top tab bar selects one section at a time. Every section is ordinary
application code in this directory.

| Section | File | What it demonstrates |
|---|---|---|
| Overview | [`showcase.odin`](showcase.odin), [`foundations.odin`](foundations.odin) | A waveform built with retained geometry, a grouped Select, a gradient surface, a keyboard-accessible gain slider, and paint-only playhead motion. Scroll down for typography, built-in icons, buttons, and semantics. |
| Controls | [`controls.odin`](controls.odin) | `ui.text_field` with app-owned required-field validation and the `.Invalid` state, pointer-bound checkbox and slider, slider value text, `select_control` with a disabled option, and keyboard/focus behavior. |
| Collections | [`collections.odin`](collections.odin) | A 500-row fixed-height `ui.virtual_list`, connected document tabs with close and dirty states, a drag-reordered list with `Semantic_ID` sources and targets, and a non-virtualized `scroll_region`. |
| Layout & surfaces | [`layout_surfaces.odin`](layout_surfaces.odin) | A draggable split with two panes, a shared-track `Grid`, surface-local `positioned_text`, a two-stop gradient, circle and arc surfaces, and a retained geometry surface updated after layout. |
| Overlays | [`overlays_themes.odin`](overlays_themes.odin) | A modal overlay with application-owned dismissal and focus restoration, a delayed tooltip, persistent notices, a single-level context menu, and native View/Help menus with accelerators. |
| Motion & themes | [`overlays_themes.odin`](overlays_themes.odin) | Paint-only retained motion, Ember and Paper palettes registered in code, the runtime default, a live-reloaded JSON theme, and a scoped accent override. |

`main.odin` owns the shell: state, section navigation, theme compilation worker,
menu storage, native menus, smoke mode, and the footer.

## Try it

1. In **Overview**, pick **Triangle** or **Pulse** from the grouped Waveform
   menu. Try the arrow keys on Gain, the playhead buttons, and the Paper palette.
   The chart republishes geometry when its data, colors, or size change. The
   playhead uses retained motion without an application tick.
2. In **Controls**, clear the name and choose **Validate** to see app-owned
   validation add the `.Invalid` semantic state.
3. In **Collections**, scroll the virtual list, close and reopen a document tab,
   toggle its dirty dot, and drag one reorder row onto another.
4. In **Layout & surfaces**, drag the split divider, resize the window, and watch
   the positioned ruler and retained geometry stay clipped to their owners.
5. In **Overlays**, open the dialog and the context menu. The View and
   Help menus also expose the same sections and the About notice.
6. In **Motion & themes**, switch to **Paper**, then edit
   [`theme.json`](theme.json) and choose **Reload theme.json**. Only color values
   may change; the last good palette stays active on parse or structure errors.

## Theme reload

`theme.json` is compiled by a worker thread and adopted on the application
thread. It starts from `alicorn.base` and currently overrides the accent token.
The live-editing contract is intentionally narrow: token names, bindings,
lengths, recipes, and materials must stay fixed. See
[Typed themes](../../docs/themes.md#experimental-live-color-editing).

## Smoke and focused review

```powershell
.\tools\run_example.ps1 -Example 08_control_gallery -AppArgs @('--smoke')
```

```sh
./tools/run_example.sh 08_control_gallery --smoke
```

`--smoke` describes every section plus the modal once, prints
`gallery_smoke sections 6 modal true ok true`, and exits with status zero.

For screenshots and focused review, the example also accepts:

- `--section=N` where `N` is `0` through `5`, the section order above.
- `--theme=light` to start in Paper, `--theme=default` for the runtime palette,
  or `--theme=custom` for the bundled JSON palette.
- `--dialog` to open the confirmation modal on the first frame.

## Boundaries

- Toggle the **Search** icon button in Overview's Foundations section to see
  its application-owned selected state.
- The gallery does not invent missing widgets: there is no mask/password field,
  multi-line selector, submenu in the context menu, or arbitrary-path hit region.
- Native dialogs, OS file drop, clipboard, and secondary windows are separate host
  services and are not part of this example. See the
  [native menu guide](../../docs/native-menus-and-integrated-titlebar.md),
  [secondary windows guide](../../docs/secondary-native-windows.md), and the
  [reference](../../docs/reference.md).
- The default content area is 1180×756 logical units. The signal controls and
  reference cards stack at narrower widths, with vertical scrolling for samples
  below the fold.
