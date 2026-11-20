# Issue #206: fit-content `ui.panel` around a ruler row and geometry surface

Research record for [#206](https://github.com/samanshaiza004/alicorn/issues/206).
Scope: the reported Acetate host-spike ruler at
[`e6cc4e8`](https://github.com/samanshaiza004/Acetate/commit/e6cc4e80453ee56afffea8642eb1f7334089727e),
`host-spike/app/main.odin:489-513`. No production layout policy changed.

## Disposition

There is no panel-specific measurement defect. `ui.panel` and `ui.column`
resolve identical bounds for the reported tree: first frame, retained frames,
window resize, viewport-height sweeps, incremental-versus-fresh solves, and
fractional DPI. `panel` is the same Container node as `column` plus a
semantic-surface sidecar, so it inherits the same fit-content contract.

The reported strip is 8 logical units, which is exactly `2 * padding` for a
padded fit-content scope with **no realized children**. That state is reachable
with either wrapper, and it is an authoring/scope error, not a node-kind gap.
This record documents the correction, and the change adds a measure trace that
names the condition plus regression fixtures that pin both the correct
measurement and the misuse symptom.

## What the host code describes

`build_ruler` at the commit above describes, with no vertical gap:

| Part | Authoring | Height |
| --- | --- | --- |
| wrapper | `ui.column(ctx, padding = 4, label = "ruler")` | fit-content |
| label row | `ui.row(ctx, height = 18, clip = true, label = "ruler-labels")` | 18 fixed |
| text cells | `ui.text(..., style = ui.layout_style(width = ..., height = 14))` | row children |
| ticks | `alicorn.gpu_geometry_surface(ctx, "time-ruler-ticks", ui.layout_style(width = -1, height = 10), dpi_scale)` | 10 fixed |

The expected wrapper height is `18 + 10 + 2 * 4 = 36`. Adding `gap = 4` gives
40. The failing `ui.panel` variant itself was never committed, so the fixtures
compare otherwise identical wrappers instead of guessing its exact text.

## Fixture results

`runtime/layout_measure_panel_test.odin` builds the same nesting as the host
(`Root` with `grow = 1`, a padded content column with `grow = 1`, two header
rows, then the scope under test) once with a plain Container and once with
`surface_begin(.Surface)`, which is the node `ui.panel` opens.

| Wrapper | gap | Wrapper bounds | Row bounds | Ticks bounds |
| --- | --- | --- | --- | --- |
| plain Container | 0 | `y+0, h=36` | `y+4, h=18` | `y+22, h=10` |
| semantic surface | 0 | `y+0, h=36` | `y+4, h=18` | `y+22, h=10` |
| plain Container | 4 | `y+0, h=40` | `y+4, h=18` | `y+26, h=10` |
| semantic surface | 4 | `y+0, h=40` | `y+4, h=18` | `y+26, h=10` |

The retained `Measure_Result` matches `bounds.h` in every case. Resizing
1100x640 to 700x480 keeps `h = 36` and shrinks only the width; a fresh runtime
at the resized viewport produces the same bounds and measure result. A sweep of
viewport heights (140, 220, 360, 900, 640) keeps `h = 36` while the scope has no
`grow`.

`ui/ui_fit_content_panel_test.odin` repeats the comparison through the public
`ui.panel`/`ui.column` helpers and additionally asserts that the panel keeps one
Container identity, one `Surface_Paint` command with its authored fill, the
`Semantic_Surface_Style` sidecar, a child clip equal to the padded scope
bounds, a hit-testable geometry surface, and authored heights for both
children. At DPI scales 1, 1.25, 1.5 and 1.75 the logical bounds are identical
and only the geometry surface's pixel extent scales.

## Why `panel` and `column` must agree

- `ui.column` lowers to `container_begin(.Container, style=layout_style(.Column,
  height=FIT_CONTENT, ...))` (`ui/ui.odin:254`).
- `ui.panel` lowers typed sizing (a no-op for an omitted `sizing`) and then
  calls `surface_begin`, which calls `container_begin_simple` with the same
  style and attaches `Semantic_Surface_Style` to that node
  (`ui/ui.odin:402`, `runtime/style_surface.odin:220`). The surface sidecar
  feeds paint, not measurement.
- Both are measured through `layout_node_has_content_height`
  (`runtime/layout_measure.odin:137`) and `layout_measure_content_height`
  (`runtime/layout_measure.odin:315`), which sums realized child heights, adds
  the authored gap, and adds padding twice.

Any divergence therefore has to come from the description tree or from which
children are realized, not from the wrapper helper.

## What produces the padding-only strip

An empty padded fit-content scope measures `2 * padding`. Directly relevant:
the layout trace now reports

```text
fit-content container has no realized children: measured height is padding only (8.000) for ruler
```

(`runtime/layout_measure.odin`, `layout_measure_content_height`). The
reported 8-unit strip is that state; the surface fill is still painted, so it
looks like a dark bar rather than missing UI.

Scoped helpers are declared with `@(deferred_in_out=...)`, so the closing call
runs at the end of the **block in which the helper was called**, not at the end
of the enclosing procedure. Two everyday forms therefore close the panel before
its children are described:

```odin
// Wrong: the panel closes at the end of this if block.
if ui.panel(ctx, padding = 4, label = "ruler") {
    panel = ctx.runtime.stack[len(ctx.runtime.stack)-1]
}
if ui.row(ctx, height = 18, clip = true, label = "ruler-labels") { ... }
app.ruler.surface = alicorn.gpu_geometry_surface(...) // siblings, not children
```

```odin
// Wrong: the helper proc closes the panel before it returns.
open_ruler :: proc(ctx: ^alicorn.UI) -> bool {
    return ui.panel(ctx, padding = 4, label = "ruler")
}
if open_ruler(ctx) { ... } // this block never owns the panel
```

Both forms are reproducible with `ui.column` as well: the wrapper keeps its
padding-only height and the row and ticks lay out in the parent scope. That is
pinned by
`ui.test_panel_children_described_after_scope_block_measure_padding_only_for_both_wrappers`.
An empty default panel is also `h = 0` without padding and `h = 2 * padding`
with it, which is the documented default sizing.

## Correct authoring

Describe every child inside the block that opened the scope:

```odin
if ui.panel(ctx, padding = 4, fill = ui.rgb(0x131822), label = "ruler") {
    if ui.row(ctx, height = 18, clip = true, label = "ruler-labels") {
        for index in 0 ..< layout.count { ui.text(ctx, label_for(index), key = u64(index)) }
    }
    app.ruler.surface = alicorn.gpu_geometry_surface(
        ctx,
        "time-ruler-ticks",
        ui.layout_style(width = -1, height = 10),
        dpi_scale,
    )
}
```

This is the same shape as the committed `ui.column` ruler, which is why the
workaround looked panel-specific: only the wrapper name changed. Store the
scope id (when it is needed) inside that block and describe children there too.

## Variants and a real caveat

- **Explicit height.** `ui.panel(..., height = 44)` stays 44 and children keep
  their authored heights.
- **`grow = 1`.** A grow child is allocated from its hard minimum (0 for an
  ordinary Container), not from its measured content. With spare space this is
  harmless: the scope expands past 36 and the row and ticks keep 18 and 10.
  When several grow siblings compete for too little space, the share can be
  smaller than the content (`0` in a 120-180-unit viewport in the sweep), and
  the children are clipped. A fixed ruler strip should not carry `grow`; it
  keeps 36 at every tested viewport height without it. Changing that bargain
  is grow/compression policy (#27, #76), not this issue.
- **Resize, retention, DPI.** Covered by the fixtures above; no divergence
  between wrappers.

## Regression guards added

| File | Coverage |
| --- | --- |
| `runtime/layout_measure_panel_test.odin` | container/surface equivalence, gap 0 and 4, resize, viewport-height sweep, incremental/fresh parity, children add/remove transitions, zero-child trace, DPI-independent measurement, explicit height and grow variants |
| `ui/ui_fit_content_panel_test.odin` | public `ui.panel`/`ui.column` equivalence, paint/identity/clip/hit-test preservation, default padding-only sizing, the deferred-scope misuse for both wrappers, DPI pixel scaling |

`tools/test.ps1` remains the full validation entry point; the runtime and UI
packages were run directly with the AccessKit collection arguments.
