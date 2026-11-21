# Connected-tab visual acceptance audit (issue #120)

Windows 11 x64, NVIDIA GeForce RTX 2080 SUPER, 2026-11-21

Alicorn `origin/master` at `67b31b8` (tag `v0.2.2`). Scratchpad frontend
`adb28fc` (`codex/issue-211-webgpu-frontend`, dirty generated style files),
built against that Alicorn revision with `--alicorn-root` +
`--allow-alicorn-revision`; Odin `dev-2026-11-nightly:08539cd`; SDL 3.4.20;
renderer `native/sdl_gpu` on D3D12. Primary display: AORUS CV27Q
(2560x1440, 100% default); secondary: F22 (1920x1080).

This record is the visual acceptance audit for
[issue #120](https://github.com/Carnival-Science/Alicorn/issues/120). The
connected appearance, the editor-paper selected fill, and the open top-edge
seam were already present on `master` (PR #135 plus the later tab-bar work);
this run validates that shipped treatment. No runtime or native source changed
in this slice.

## What shipped

The accepted treatment is **option A (color/seam) + option C (bounded curved
shoulders)**:

- `Tab_Bar_Options.appearance = .Connected` opts a specific tab bar into the
  treatment; the global `Button_Variant.Tab` recipe is unchanged
  (`runtime/tab_bar.odin`). Scratchpad sets
  `options.selected_fill` from its **editor-paper extension color**
  (`workbench_layout.odin`), so warm and cool-light select the paper color;
  there is no hard-coded cream in the component.
- The selected tab and its adjoining editor surface share one retained
  `open_top_edge` link (`runtime/style_surface.odin`). The top material edge,
  relief, and stroke are omitted only inside the selected tab's visible
  interval, so the selected fill and the paper meet continuously.
- The selected indicator is retained with zero height; the connected tab has
  no rectangular underline.
- The contour is a bounded, fixed-budget shape kind (`.Connected_Tab`):
  `CONNECTED_TAB_VERTICES = 20*18+6 = 366` vertices, clipped to the tab's own
  allocation, with the baseline fully opaque so it joins the paper without an
  antialias seam (`renderer/cpu/material.odin`,
  `native/sdl_gpu/connected_tab_test.odin`). This is a component-private paint
  decoration on the generic surface/material pipeline, not an SVG/path
  renderer.

**Options B and D were intentionally not pursued.** Per-corner top rounding
(#118) is already available but would make every tab a separate rounded
rectangle; it does not produce the continuous selected-page silhouette this
issue is about. A two-stop gradient (#119) changes emphasis but not ownership,
and the seam/color work already carries the selected page into the tab. The
issue's **NO-GO** clause is applied to a general-purpose bespoke
shoulder/path primitive: the bounded `.Connected_Tab` contour and the
`open_top_edge` seam are sufficient, and no public path/SVG API is
recommended.

## Method

- Built Scratchpad against Alicorn `67b31b8` with the normal consumer path
  (`go run ./cmd/alicorn-dev build --odin C:\odin\odin.exe
  --alicorn-root <alicorn> --allow-alicorn-revision`).
- Ran a three-document fixture workspace (`main.odin`, `notes.md`,
  `settings.json`) restored from an isolated session, so the tab strip has a
  selected tab with an inactive neighbour on each side.
- Selected the theme through the real preference path
  (`%LOCALAPPDATA%\Scratchpad\preferences.json`), not a fixture overlay:
  - warm: `"color_theme":"builtin:warm"`, `"surface_treatment":"standard"`
  - cool-light: `"color_theme":"builtin:cool-light"`,
    `"surface_treatment":"standard"`
  - relief: `"color_theme":"builtin:warm"`,
    `"surface_treatment":"workbench-relief"`
- Launched with `--diagnostics --capture-dir=... --capture-after=600`,
  focused the SDL window, pressed F12 twice, and accepted a leg only when the
  two `screenshot.ppm` captures were byte-identical (settled frame).
- For each non-100% leg the display scale was changed **after** the window was
  running with the platform's per-monitor DPI scale API: 125% (step 1),
  150% (step 2), 200% (step 4); this panel supports steps 0..5 (100%..225%).
  The original scale was restored in a `finally` block and verified at 0
  (100%) after the run.
- Every leg's capture bundle contains `diagnostics.json`, `inspector.txt`,
  `timeline.json`, and `screenshot.ppm`; the bundles report
  `display_scale` 1.0000/1.2500/1.5000/2.0000 and three
  `shape=connected-tab-contour` paints (selected + two inactive tabs).

Raw bundles are under `out/issue-120/raw/<theme>-<scale>/captures/` and are
git-ignored. The committed PNG copies live in
`docs/validation/assets/issue-120/`. Each leg ran as:

```powershell
out\alicorn\scratchpad-alicorn.exe --diagnostics `
    --capture-dir=out\issue-120\raw\<theme>-<scale> --capture-after=600
# then two F12 presses through the host capture shortcut
```

## Capture matrix

Full frames are 1216x799, 1218x807, 1222x816, and 1226x831 px at 100, 125,
150, and 200%. `tab h` is the retained tab height from the inspector; every leg
has the same selected fill as its paper.

| Theme | Scale | Frame | tab h | Selected fill | Paper | Committed image |
| --- | ---: | --- | ---: | --- | --- | --- |
| warm | 1.0 | 1216x799 | 32 | `#f0ebdb` | `#f0ebdb` | [full](assets/issue-120/warm-1.0-full.png) · [tabs](assets/issue-120/warm-1.0-tabs.png) |
| warm | 1.25 | 1218x807 | 40 | `#f0ebdb` | `#f0ebdb` | [full](assets/issue-120/warm-1.25-full.png) · [tabs](assets/issue-120/warm-1.25-tabs.png) |
| warm | 1.5 | 1222x816 | 48 | `#f0ebdb` | `#f0ebdb` | [full](assets/issue-120/warm-1.5-full.png) · [tabs](assets/issue-120/warm-1.5-tabs.png) |
| warm | 2.0 | 1226x831 | 64 | `#f0ebdb` | `#f0ebdb` | [full](assets/issue-120/warm-2.0-full.png) · [tabs](assets/issue-120/warm-2.0-tabs.png) |
| cool-light | 1.0 | 1216x799 | 32 | `#f4f6fd` | `#f4f6fd` | [full](assets/issue-120/cool-light-1.0-full.png) · [tabs](assets/issue-120/cool-light-1.0-tabs.png) |
| cool-light | 1.25 | 1218x807 | 40 | `#f4f6fd` | `#f4f6fd` | [full](assets/issue-120/cool-light-1.25-full.png) · [tabs](assets/issue-120/cool-light-1.25-tabs.png) |
| cool-light | 1.5 | 1222x816 | 48 | `#f4f6fd` | `#f4f6fd` | [full](assets/issue-120/cool-light-1.5-full.png) · [tabs](assets/issue-120/cool-light-1.5-tabs.png) |
| cool-light | 2.0 | 1226x831 | 64 | `#f4f6fd` | `#f4f6fd` | [full](assets/issue-120/cool-light-2.0-full.png) · [tabs](assets/issue-120/cool-light-2.0-tabs.png) |
| relief | 1.0 | 1216x799 | 32 | `#f0ebdb` | `#f0ebdb` | [full](assets/issue-120/relief-1.0-full.png) · [tabs](assets/issue-120/relief-1.0-tabs.png) |
| relief | 1.25 | 1218x807 | 40 | `#f0ebdb` | `#f0ebdb` | [full](assets/issue-120/relief-1.25-full.png) · [tabs](assets/issue-120/relief-1.25-tabs.png) |
| relief | 1.5 | 1222x816 | 48 | `#f0ebdb` | `#f0ebdb` | [full](assets/issue-120/relief-1.5-full.png) · [tabs](assets/issue-120/relief-1.5-tabs.png) |
| relief | 2.0 | 1226x831 | 64 | `#f0ebdb` | `#f0ebdb` | [full](assets/issue-120/relief-2.0-full.png) · [tabs](assets/issue-120/relief-2.0-tabs.png) |

### Control: Standard tab appearance

A same-build before image of the app was not available (see residual gaps).
The closest controlled comparison is the native titlebar fixture with the
default tab appearance, captured through the same host and F12 path:
[full](assets/issue-120/before-standard-full.png) ·
[tabs](assets/issue-120/before-standard-tabs.png). It shows the unmodified
`Button_Variant.Tab` treatment: a rectangular selected tab with a 1-pixel
underline, no shoulders, and no continuous page fill. The global recipe still
renders this way for every consumer that does not opt into `.Connected`.

## Observations

### Warm (1.0/1.25/1.5/2.0)

- The selected tab fill is exactly the editor paper (`#f0ebdb`); the inactive
  tabs stay workbench-recessed (`#3e3e35`, paint dropped 3 px) against the
  `#47473d` titlebar.
- Both shoulders render on every scale. The left shoulder rises from the
  baseline at the pane edge and the crown is flat; the right shoulder mirrors
  it. The 2.0 tab is twice as tall (64 px), so the shoulder/crown proportion is
  visibly larger while the label and close target stay 1x.
- The seam is open: the last tab row and the first editor row are both paper
  (the first editor row is the current-line tint, `#c1b397`), with no dark or
  accent underline at the join.
- The close × is present on the selected tab only, inset inside the crown; the
  inactive tabs have no × (close policy `Selected_Or_Hover`) and no hover tint
  in these settled captures.

### Cool-light (1.0/1.25/1.5/2.0)

- Same geometry with the cool palette: selected fill and paper are `#f4f6fd`;
  inactive tabs `#c7d1e1` on `#c4cede`; the first editor row's tint is
  `#9cadca`.
- Shoulders, seam, close affordance, and inactive recession match warm. There
  is no selected underline.

### Relief (1.0/1.25/1.5/2.0)

- Relief uses the warm palette with `workbench-relief` material. The selected
  tab and paper are `#f0ebdb`; the shoulder edge and the paper's top edge show
  the analytic relief shading where it is not opened by the seam.
- The seam stays open through the material: the paper's top relief and stroke
  are omitted across the selected tab's visible interval, so the selected tab
  remains continuous with the paper rather than sitting on a raised lip.
- Inactive tabs remain recessed and distinguishable. No underline appears.

### DPI note

The retained tab height follows the native titlebar band:
32/40/48/64 px at 100/125/150/200%, and the client height grows with that band
(799→807→816→831 px) while the width moves by only the small chrome/content
adjustment (2–10 px). The connected contour is drawn at that height, so the
shoulder scale changes with the band and remains clipped to the tab.

However, the native `native/sdl_gpu` host reports `logical == pixel` at every
scale (`diagnostics.json`: `display_scale` 1.25/1.5/2.0,
`logical_width == pixel_width`), and Scratchpad's style environment remains
`text-scale=1.00`. The screenshots therefore show 1x-density text and tab
widths inside a physically smaller window on the scaled desktop; they are not
a 2x re-rasterization of the whole UI. The contour's scale stability (fixed
vertex budget, bounded fringe, opaque baseline) is covered separately by the
native geometry test at 1/1.25/1.5/2 and by Scratchpad's headless
`connected_titlebar_test` scale loop.

## Constraints checklist

| Constraint | Result | Evidence |
| --- | --- | --- |
| Selection preserved | Pass | Every capture shows `main.odin` selected; `connected_tabs_test` asserts the selected node, `selected=true`, and `selected_fill`/`selected_text` are the controlled values. |
| Stable IDs | Pass | Tab keys `workbench-view-1/2/3` are identical in every scale's inspector. `test_connected_tab_appearance...` asserts `tab_after == tab` after a theme-fill invalidation and no text reshape or layout visit. |
| Drag/reorder/detach | Pass (contract) | The connected appearance keeps the normal tab button, drag type, and close slot; the [tab-drag preview parity record](webgpu-tab-drag-preview-windows-2026-11-20.md) and `runtime/tab_bar_test.odin` cover the preview/reorder path. Not re-captured here (see gaps). |
| Accessibility semantics | Pass (contract) | The bar advertises `.Tab_List`, each tab `.Tab`; labels are not duplicated into semantics; inactive tabs stay keyboard-focusable with `Keyboard_Only` focus visibility and contrast ≥4.5 for text and ≥3 for the focus ring (`connected_tabs_test`). |
| Rectangular hit regions | Pass | Decoration only moves paint: inactive tabs drop their paint bounds by 3 px while `owner.bounds` is unchanged; the close target stays 24x24; hover highlight and icon stay inside the contour and centered on the unchanged hit rect. |
| Close affordance | Pass | Selected tab only (policy `Selected_Or_Hover`); independent 24-unit hit target; hover paints a tint and icon without moving the target. |
| Zero idle work | Pass | An unchanged presentation frame does not repaint (`unchanged connected tabs must require no idle paint work`); a selected-fill change preserves identity and schedules paint only, with no layout/text reshaping. |
| Global Tab recipe unchanged | Pass | `style_button_recipe(..., .Tab)` still reports `surface_visible=false` and `selected_indicator=.Underline`; Scratchpad's Files/Search tab consumers are unaffected. |
| Overflow/scroll join | Pass (contract) | Horizontal scroll moves the paper's top-edge opening to the selected tab's visible interval, and a retained Split drag moves both in one presentation (`test_connected_surface_join_follows_retained_scroll...`). |
| Separate top edge when not adjacent | Pass (contract) | A surface separated from its tab by another strip keeps its complete top edge (`semantic_surface_top_edge_gap`). |

## Suites

- `odin test runtime` (Odin `C:\odin\odin.exe`, `-collection:alicorn=<repo>`):
  421 tests finished, all successful.
- Scratchpad frontend and Alicorn native suites were not re-run in this slice;
  only the headless runtime suite was requested for this validation-only
  change.

## Residual gaps

- **No same-build before image.** The pre-fix Scratchpad build is not present
  in this checkout, and the installed packaged Scratchpad 0.1.1
  (Alicorn `4480d0e`, before the connected tabs) does not emit diagnostics
  captures; a screen-grab attempt was abandoned after the packaged window did
  not respond. The Standard-appearance fixture is the controlled component
  comparison, not an app-level before.
- **Not a full device-density matrix.** As described above, the native host
  keeps `logical == pixel` on Windows, so these captures show the app at each
  desktop scale but not a re-rasterized 1.25/1.5/2x text/mesh layer. A host
  change that makes the window's drawable follow the display scale is outside
  #120; the contour itself is scale-stable by its fixed-budget geometry test.
- **Drag preview not re-captured.** Synthetic pointer motion is not reliably
  delivered to this Scratchpad window in the automation session. The drag
  preview and reorder path remain covered by the 2026-11-20 parity record and
  by the runtime/tab-bar tests.
- **Windows only.** macOS and Linux titlebar/chrome behavior is not exercised
  by this record. Mixed-monitor drag and screen-reader traversal are also not
  re-run here.
- **200% is only supported on the primary panel.** The secondary (1080p) tops
  out at 175%; the 200% leg therefore uses the primary display. All legs were
  restored to 100% afterward and the preference/session files were restored
  byte-for-byte.
