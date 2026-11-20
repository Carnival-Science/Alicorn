# Issue #207: surface-local positioned text

Research and implementation record for
[#207](https://github.com/samanshaiza004/alicorn/issues/207).
Scope: the Acetate ruler spike (`host-spike/app/main.odin`), which emitted
major-label text as fixed-width row cells plus a synthetic leading spacer while
drawing ticks on a separate retained geometry surface. This record covers the
bounded investigation, the option comparison, the chosen seam, and its
renderer-neutral contracts.

## Problem

The label row and the tick surface were described by different layout inputs:

- Major labels were ordinary flow children of a fixed-height Row. Their x
  position came from cell widths and a leading spacer that imitated the gap
  before the first tick.
- Ticks were surface-local geometry inside a `gpu_geometry_surface` child.
- A viewport change relaid out the label row, which invalidated the root and
  could not reuse the retained geometry surface's coordinate origin.
- There was no way to say "this text belongs at this owner-local logical
  coordinate" without authoring placeholder space.

The required product was the smallest retained, renderer-neutral authoring
seam that places labels at explicit surface-local logical coordinates with
alignment/baseline and clip behavior. Reuse of existing text shaping,
`Paint_Command`, font/atlas, clipping, and semantics was mandatory. A raw GPU
canvas, alternate scene graph, general CSS positioning, and a general
constraint solver were explicitly out of scope.

## Options considered

| Option | Verdict |
| --- | --- |
| Positioned overlay layer (new layer node or second scene graph over the existing tree) | Rejected. It would duplicate paint order, semantics, hit testing, font lifetime, and renderer resource behavior, and it would need renderer work to composite against the owner's surface. |
| General CSS-like `position`/constraints on every node | Rejected. It enlarges the layout policy surface, conflicts with fit-content measurement, and is not the smallest useful seam. |
| **Positioned-child layout strategy on ordinary nodes** | **Chosen.** Placement is retained input on an ordinary child; measurement, shaping, paint, clipping, and semantics stay in the existing paths. |
| Anchor-only absolute placement with no owner rectangle | Rejected. Labels must clip and resolve against the owner's rectangle, which the layout resolver already computes. |

## Chosen design

### Retained data

`Positioned_Placement` is compact retained state stored in both `Description`
and `Node` (16 bytes). It holds:

| Field | Meaning |
| --- | --- |
| `x`, `y` | Owner-content-box-local logical coordinates. |
| `horizontal` | `.Start`, `.Center`, `.End` anchor interpretation for `x`. |
| `vertical` | `.Top`, `.Middle`, `.Bottom`, `.Baseline` anchor interpretation for `y`. |
| `clip` | Intersect the child with the owner rectangle in addition to inherited clip. |
| `opacity` | Scales every paint command the child emits. |
| `valid` | Distinguishes an absent placement from the ordinary zero struct. |

Hard boxes, wrapping limits, and ellipsis stay ordinary `Layout_Style` inputs
on the child rather than being duplicated in placement. `ui.positioned_text`
accepts `width`, `height`, and `max_width` for authoring convenience and
lowers them into that style.

The app owns domain coordinates and the time-to-pixel transform. Alicorn owns
only the owner's resolved rectangle, measurement, clipping, and paint order.

### Authoring

- Runtime: `position_child(ui, id, positioned(x, y, ...))` marks an
  already-described direct child, the same pending-mutation pattern as
  `semantic_static_text` and `text_input_target`.
- UI: `ui.positioned_text(ui, value, x, y, ...)` emits one ordinary `.Text`
  node and applies placement. It is decorative by default and calls
  `semantic_static_text` only when `decorative=false`.

### Layout

`layout_children` partitions children once when any direct child of an
ordinary-flow owner has a valid placement. Flow children keep the existing
path; positioned children are resolved by `layout_positioned_children`, which:

1. measures the child with unbounded constraints, so its own `Layout_Style`
   supplies any hard width/height, wrap limit, or ellipsis (auto-width text
   shapes at its natural width),
2. computes anchor-adjusted bounds from the owner's inner content box,
3. sets `hit_bounds` and the inherited or owner-bounds clip,
4. finalizes geometry, syncs semantic bounds, dirties the same stages, and
   recurses exactly like the flow loop.

Positioned children are excluded from:

- flow allocation and gap distribution,
- `layout_measure_content_height` and `layout_measure_content_signature`,
- `layout_measure_content_dependencies`,
- the child's contribution to parent fit-content measurement
  (`parent_size_dependencies = {}`).

`.Grid`, `.Split`, adaptive owners, and context menus retain their specialized
layout policy and do not honor placement. Child declaration order still owns
paint and hit-test order; there is no new z-index.

### Semantics, input, and paint

- Positioned `.Text` nodes are not hit-testable unless they are an explicit
  text-input target; decorative ruler labels therefore do not intercept
  pointers or enter tab order.
- `semantic_static_text` still exports the label as `Static_Text`, and
  `semantic_sync_bounds` publishes the finalized bounds.
- The label paints as an ordinary `Text_Paint` command. Placement opacity is
  multiplied into every command the node emits, including span backgrounds and
  decorations. The SDL GPU text mesh fingerprint already hashes
  `command.opacity` (`native/sdl_gpu/text.odin`, `native_text_mesh_fingerprint`)
  and applies it in `native_text_vertex_color`, so no renderer change is
  needed.

### Invalidation

| Change | Products invalidated |
| --- | --- |
| Label text only | Child measure and its shaped run; paint of that child. Retained geometry payload unaffected. |
| `x`/`y` move only | Layout/dirty placement and paint; measurement input fingerprint unchanged, so the shaped run is reused. |
| Width/height/`max_width` in the child's layout style | Child measurement (wrapping/ellipsis may change), layout, paint. |
| Opacity only | Description/paint hash; layout placement unchanged. |
| Owner rectangle or clip | Positioned layout reruns from the retained owner geometry. |
| Explicit geometry update | Existing `surface_payload_revision` path only; never implied by label work. |

`layout_hash` includes placement layout fields, `description_hash` adds
opacity, and placement adds no measurement-input fields at all. A hard box is
an ordinary style input, already fingerprinted by the existing measure path.
This is why a move performs zero new shaping while a text edit requests only
the required run.

## Evidence

Fixtures added:

- `runtime/positioned_child_test.odin`
  - alignment/baseline bounds math for every horizontal/vertical pair,
  - explicit clip and opacity behavior,
  - decorative labels have no semantic entity, stay non-focusable, and are not
    hit-testable while `semantic_static_text` labels publish bounds,
  - fit-content owner measures only padding/flow content,
  - position-only moves keep `text_shape_requests` unchanged and retain
    `surface_payload_revision`; text edits shape once and still leave the
    geometry payload untouched.
- `ui/ui_positioned_text_test.odin`
  - `ui.positioned_text` resolves the same bounds and paint as manual
    `position_child`,
  - a ruler and a meter share one application-owned transform with retained
    tick geometry (Start and End alignment),
  - DPI scales 1, 1.25, 1.5, 1.75 keep identical logical bounds while the tick
    surface scales pixels,
  - incremental resize matches fresh layout.

Retained sizes remain inside the tripwires: `Node=2024/2048`,
`Description=720/768`, `Paint_Command=128/128`, printed by
`test_retained_record_sizes_stay_within_budget`.

## Limits and risks

- A fit-content owner with only positioned children measures padding plus any
  flow content. Owners that host labels must be sized explicitly; this is
  documented in `docs/guide.md` and `docs/reference.md`.
- Baseline alignment for a child without a retained baseline product falls
  back to its bottom edge, matching the existing Row baseline convention for
  non-text visuals.
- Placement is not a general constraint system: no percentage anchors, no
  z-index, no automatic collision avoidance, and no placement inside
  specialized layout owners.
- Positioned children are included in the parent's child list and preserved
  hierarchy; retained-region identity and lifecycle rules are unchanged.

## WebGPU compatibility

The WebGPU host is not on this branch. The seam emits only ordinary retained
products: `.Text` nodes and `paint_text_command`, whose `Text_Run_Handle`
resolves through `alicorn.paint_text_run_resolve` in every host. There is no
new text-run source, geometry source, or command payload. A WebGPU host that
consumes the same display list and text resolver inherits positioned labels
unchanged; no renderer-specific branch is required for placement, clipping,
opacity, or shaping reuse.
