# 08 · Control Gallery

The Control Gallery is Alicorn's one-stop native showcase. It uses the default
`alicorn:ui` + `alicorn:runtime` path and the SDL_GPU host; it does not require
WebGPU, a browser, or any third-party package.

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
| Foundations | [`foundations.odin`](foundations.odin) | Typography and the `.Monospace` role, all 15 built-in icons, `ui.icon_button`, six Button variants, selected/disabled state, and automatic semantics with a live `.Status` entity. |
| Controls | [`controls.odin`](controls.odin) | `ui.text_field` with app-owned required-field validation and the `.Invalid` state, pointer-bound checkbox and slider, slider value text, `select_control` with a disabled option, and keyboard/focus behavior. |
| Collections | [`collections.odin`](collections.odin) | A 500-row fixed-height `ui.virtual_list`, closable and dirty `tab_bar` document tabs, a drag-reordered list with `Semantic_ID` sources and targets, and a non-virtualized `scroll_region`. |
| Layout & surfaces | [`layout_surfaces.odin`](layout_surfaces.odin) | A draggable split with two panes, a shared-track `Grid`, surface-local `positioned_text`, a two-stop gradient, circle and arc surfaces, and a retained geometry surface updated after layout. |
| Overlays & commands | [`overlays_themes.odin`](overlays_themes.odin) | A modal overlay with application-owned dismissal and focus restoration, a delayed tooltip, persistent notices, a single-level context menu, and native View/Help menus with accelerators. |
| Motion & themes | [`overlays_themes.odin`](overlays_themes.odin) | Paint-only retained motion for a selection marker, theme switching between the default dark theme, a code-registered light theme, and a live-reloaded JSON theme, plus the complete semantic color palette and a scoped accent override. |

`main.odin` owns the shell: state, section navigation, theme compilation worker,
menu storage, native menus, smoke mode, and the footer.

## Try it

1. Tab through the section tabs and each control. Every standard control is
   keyboard reachable and publishes its semantics automatically.
2. In **Controls**, clear the name and choose **Validate** to see app-owned
   validation add the `.Invalid` semantic state.
3. In **Collections**, scroll the virtual list, close and reopen a document tab,
   toggle its dirty dot, and drag one reorder row onto another.
4. In **Layout & surfaces**, drag the split divider, resize the window, and watch
   the positioned ruler and retained geometry stay clipped to their owners.
5. In **Overlays & commands**, open the dialog and the context menu. The View and
   Help menus also expose the same sections and the About notice.
6. In **Motion & themes**, switch to **Light**, then edit
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
- `--theme=light` to start in the code-registered light variant.
- `--dialog` to open the confirmation modal on the first frame.

## Boundaries

- `icon_button` has no selected state in v0.2.2; issue #199 tracks it. Use a
  normal Button (`state=Button_State{selected=true}`) for selection today.
- The gallery does not invent missing widgets: there is no mask/password field,
  multi-line selector, submenu in the context menu, or arbitrary-path hit region.
- Native dialogs, OS file drop, clipboard, and secondary windows are separate host
  services and are not part of this example. See the
  [native menu guide](../../docs/native-menus-and-integrated-titlebar.md),
  [secondary windows guide](../../docs/secondary-native-windows.md), and the
  [reference](../../docs/reference.md).
- The compact layout uses a vertical scroll region. The default window is
  1180×900 logical units; smaller windows scroll instead of hiding controls.
