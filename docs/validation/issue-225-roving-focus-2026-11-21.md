# Generic roving focus model and list/grid pattern checks (issue #225)

Date: 2026-11-21

Branch: `codex/issue-225-roving-focus`

Status: implemented. Runtime model, `testui` patterns, the in-repo
`select_parts` migration, the AliKit icon-picker migration, and cross-repo
validation are complete. This is not a WCAG conformance claim and does not
replace native assistive-technology acceptance.

## Decision

The model is a **pure, UI-independent procedure set over a caller-owned value
view** in `runtime/roving.odin`. It is not a runtime service, does not allocate,
does not retain state, and does not publish semantics.

The #218 pilots differed in application data, disabled policy, and ownership, so
extracting a shared component or a runtime state machine would have failed the
two-consumer rule. Index arithmetic is the part that was genuinely identical:
given `count`, optional grid `columns`, an enabled predicate, and a current
index, where does an arrow/Home/End/Page move land? That is what was extracted.
The application keeps:

- the focused index and its stable item identity;
- selection policy and whether focus selects;
- reveal requests (`virtual_list_ensure_visible` and the after-frame hook);
- activation, focus restoration, modal/popup lifecycle, and invalidation.

Dynamic membership is caller-owned. The model returns `-1` when the current
index is outside the current count; callers re-clamp and repair with
`roving_nearest_enabled`. The model never hides a stale count.

## API surface

```odin
Roving_View :: struct {
    count:       int,
    columns:     int,   // <= 1 linear; > 1 grid stride
    enabled:     proc(data: rawptr, index: int) -> bool,
    data:        rawptr,
    page:        int,   // <= 0 disables Page_Up/Page_Down
    wrap:        bool,
    row_bounded: bool,  // grid Left/Right stop at row edges when wrap is false
    home_end:    Roving_Home_End, // .All or .Row
}

Roving_Move :: enum { Left, Right, Up, Down, Page_Up, Page_Down, Home, End }

roving_propose(view, current, move) -> int
roving_enabled(view, index) -> bool
roving_index_valid(view, index) -> bool
roving_clamp(view, index) -> int
roving_first_enabled(view) -> int
roving_last_enabled(view) -> int
roving_first_enabled_from(view, start, direction := 1) -> int
roving_nearest_enabled(view, index, prefer := 1) -> int
roving_move_for_key(key) -> (Roving_Move, bool)
roving_move_for_text_key(key) -> (Roving_Move, bool)
```

The zero view is linear, non-wrapping, all-enabled, whole-set Home/End. The
shipped icon-picker behavior is the default for every policy except grid
columns/page/row-scoped Home/End, which the consumer passes explicitly.

Move rules are in
[`docs/reference.md#roving-focus-model`](../reference.md#roving-focus-model).
Disabled items are skipped in the direction of travel. `wrap` continues at the
opposite edge and may cross row edges even when `row_bounded` is set;
`row_bounded` only applies to grid Left/Right while `wrap` is false.
`roving_propose` returns `-1` for a boundary, an all-disabled direction, a
zero/negative page size, an out-of-range current index, or a move that would
land on the current index.

## Consumer adoption

### `select_parts` (linear popup)

Policy: linear order, `wrap=true`, whole-set Home/End, disabled options and
disabled groups skipped.

Removed from the package:

- `select_parts_first_enabled`'s bespoke scan;
- `select_parts_next_enabled`, including its manual modulo wrap and
  invalid-index start fix-up (13 lines);
- `select_parts_groups_has_enabled` (8 lines), replaced by the model's first
  enabled lookup;
- eight explicit Up/Down/Home/End branches across the interaction-event and
  generic-text-key paths, replaced by one key-vocabulary mapping call in each
  path.

The package gained a small projection (`Select_Parts_Roving` borrowed groups
slice plus a view builder and a compact move helper) because the model
deliberately has no knowledge of `Select_Parts_Group`.

Measured diff for `select_parts.odin` against `master` (`ce040b4`):

```text
49 insertions, 40 deletions (net +9)
```

The net line count rose slightly, but the navigation surface collapsed: two
bespoke index procedures and eight hand-written key branches became one shared
policy plus two keyed calls. The adapter is projection only; no wrap, stride,
disabled-skip, boundary, or Home/End decision remains local. This is the
in-repo proof that a userland component still on Odin public API can adopt the
model without new runtime state or a second tree.

### AliKit `icon_picker` (2D grid)

Policy: filtered match order, `columns=6`-style stride, filtered-boundary stop
(no wrap), shipped linear Left/Right crossing at row edges
(`row_bounded=false`), row-scoped Home/End, page = `columns * visible_rows`.

Removed from `icon_picker/icon_picker.odin`:

- `grid_move` (18 lines of linear-over-filtered-order movement);
- `first_enabled_from` and `first_enabled`;
- `row_bounds`;
- `page_stride`;
- the 20-line Home/End/Page/arrow switch in `apply_navigation`.

Added: a `Picker_Roving` borrowed context, a view projection, and one
`roving_move_for_key` call. Measured diff against the AliKit pilot branch base
(`5dbc083`), including the added cross-repo pattern test:

```text
icon_picker/icon_picker.odin       48 insertions, 74 deletions (net -26)
icon_picker/icon_picker_test.odin  +1 test (11 -> 12)
```

This is the demonstrably-simpler consumer: the picker's entire grid/row/page
index policy is deleted and all navigation now flows through the shared model.
Its suite stayed green, including the grid shape, disabled skipping, row bounds,
filtering, reorder/removal repair, and the new `Roving_Grid` pattern check against
the real picker (not a copy).

### AliKit `tree_view` (evaluated, not adopted)

`tree_view` delegates to `tree_model`, which owns:

- stable `Item_ID` focus independent of row position;
- loaded-window projections with `Window{offset, total_count}`;
- `Range_Requested` when a move targets a row not currently loaded;
- expand/collapse and parent focus on Left/Right;
- pending focus completed by a later window.

A pure fully-known `Roving_View` cannot express "the next enabled index is not
loaded yet, request that range" or expansion-aware Left/Right. Restricting the
model to Up/Down/Home/End would leave the actual navigation, range, and parent
policy in `tree_model` and add a second partial path. The justified decision is
to keep `tree_model` navigation; this is the model's boundary, not a missing
consumer. The two adopted consumers cover the linear and 2D grid shapes the
issue asked for.

## TestUI patterns

New kinds `Pattern_Kind.Roving_List` and `Pattern_Kind.Roving_Grid` share one
checker with `Pattern_Roving_Config`:

```odin
Pattern_Roving_Config :: struct {
    focus: Pattern_Roving_Focus, // .Container or .Item
    columns: int,
    wrap: bool,
    row_bounded: bool,
    home_end_row: bool,
    expect_reveal: bool,
    activation_closes: bool,
    expect_selection: bool,
    expect_escape_restore: bool,
}
```

Rules asserted against published semantics and normal input:

1. `Container` is a realized `List_Box` collection; every logical item is
   realized, has a unique position, and publishes consistent `Current` identity.
2. Exactly one enabled item is `Current`; the collection `current_id` agrees.
3. Exactly one focus representative exists: a focusable container
   (`focus=.Container`, items may be non-focusable/virtual) or a focusable
   current item (`focus=.Item`). Focus is on that representative after every
   turn.
4. Disabled items are not focusable, have no `Focus`/`Select` actions, and never
   become `Current` during arrow traversal.
5. Arrow navigation matches the configured linear or grid policy, including
   stride, disabled skipping, row-bounded Left/Right, boundary stops, and wrap.
6. Home/End match the configured set or row scope.
7. The current item is realized with bounds intersecting the container when
   `expect_reveal=true`.
8. Keyboard Return and a pointer click on `Target_Option` publish the same
   `Selected` identity (`expect_selection=true`). A popup with
   `activation_closes=true` must close and return focus to `Trigger`;
   `expect_escape_restore=true` adds the Escape-close path.

Positive controls:

| Consumer | Kind | Focus | Notes |
| --- | --- | --- | --- |
| `select_parts` (example 18) | `Roving_List` | `.Item` | opens through the trigger, wrap, disabled option, keyboard and pointer activation, Escape restoration |
| In-repo roving grid fixture (`testui/roving_pattern_test.odin`) | `Roving_Grid` | `.Container` | focusable virtual list, 4-column stride, row bounds, disabled cell, reveal, selection |
| AliKit `icon_picker` test | `Roving_Grid` | `.Container` | real consumer at the pinned Alicorn revision; 6-column grid, row Home/End, disabled cell, keyboard/pointer selection |

Negative controls and named failures:

| Fault | Named step | Assertion |
| --- | --- | --- |
| disabled cell visual control remains focusable | `Focus_Contract` | disabled item is not focusable |
| neither container nor any item is focusable | `Focus_Contract` | one focus representative exists |
| arrow navigation moves `Current` but sends focus outside | `Containment` | retained focus stays on the container |

The checker requires the whole item set to be realized. This is deliberate:
navigation to an unrealized row cannot be distinguished from a missing contract
without adding runtime introspection. Positive fixtures keep their sets inside
the realized window; the AliKit picker's 12 choices fit its two realized rows.
Large virtualized sets remain covered by the consumer's own reveal tests.

## Validation

Commands and results from this branch:

```text
odin test runtime                     459 tests, all successful
odin test testui                      30 tests, all successful (was 26)
odin test examples/18_composable_select_parts
                                      13 tests, all successful (was 12)
```

`odin test runtime` includes 11 new pure-model tests: linear moves, grid stride,
row bounds, disabled skipping, wrap, Home/End row versus set, page moves,
membership shrink/grow, single/empty/all-disabled sets, nil predicate, and the
navigation-key mappings.

`testui` grew from 26 to 30: one positive grid fixture and three negative
controls. Example 18 grew from 12 to 13 with the `Roving_List` positive control.

AliKit cross-repo validation (branch `codex/issue-3-parts-pilot`, pin
`5f6fe8ec7bd4bf5e87a2a27cdf71980b03b48b9c`):

```text
icon_picker                            12 tests, all successful (was 11)
```

The remaining AliKit stages were run individually because the PowerShell 5.1
`tools/test.ps1` wrapper stops on the Odin test runner's INFO stderr (the
documented harness caveat). All returned success against the bumped pin:

```text
palette_model      tree_model      command_palette
tree_view          palette_parts    icon_picker
examples/command_palette, examples/tree_view, examples/icon_picker builds
out/copyable/icon_picker source build without the alikit collection
```

The same caveat stopped `tools/test.ps1` at the AccessKit binding check, so the
Alicorn runtime/testui/ui/theme/example-18 stages above were also invoked
directly with the pinned AccessKit compiler arguments.

## Limits

- The model proposes indexes only. It cannot validate that an application
  actually moved focus, revealed the item, or published the right semantics;
  the `testui` patterns and application tests cover those contracts.
- The patterns do not exercise native accessibility bridges, OS IME candidate
  windows, pixels, or screen readers.
- `tree_view` is intentionally outside the model while navigation depends on
  loaded-window range requests and expansion. That boundary is recorded above
  rather than hidden behind a partial adoption.
