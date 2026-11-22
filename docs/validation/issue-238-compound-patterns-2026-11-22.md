# Radio group, static table, and data-grid pattern checks (issue #238)

Date: 2026-11-22

Branch: `codex/issue-238-patterns`

Status: implemented. The three `testui` pattern kinds, positive fixtures,
negative controls, reference documentation, and suite validation are complete.
The runtime-side focus/action findings are recorded as core asks; no runtime
behavior changed in this slice. This is not a WCAG conformance claim and does
not replace native assistive-technology acceptance.

## Decision

Issue #238 asked for `Radio_Group` and `Table` pattern kinds. The founder's
2026-11-22 revision added two corrections and one separate requirement:

1. Split the static `Table` contract from an interactive `.Data_Grid` contract.
   They have different authoring obligations and are not merged into one
   checker.
2. A radio group may legitimately begin with no selection. The checker enforces
   **at most one** checked radio and checked/`selected_id` agreement, never
   "exactly one" unless the consumer opts in.
3. Advertised accessibility actions must correspond to performable actions; an
   advertised-but-rejected action is a checker failure.

All three are implemented. Existing `.Roving_List` and `.Roving_Grid` behavior is
unchanged.

## Pattern rule tables

### `.Radio_Group`

| Rule | Assertion |
| --- | --- |
| Group structure | one realized `Radio_Group` collection; every logical item realized as a `Radio_Button` collected by and parented to the group; unique positions |
| Mutual exclusion | at most one item carries `Checked` or `Selected`; zero is valid |
| Agreement | when one item is checked, the group `selected_id` names it; when none is checked, `selected_id` is unset |
| Opt-in selection | `Pattern_Radio_Config.require_initial_selection` turns an empty initial group into `Static_Contract` failure |
| Disabled policy | a `Disabled` radio is not focusable, is not focused, and advertises no `Focus`, `Press`, or `Select` |
| Focus | exactly one focused enabled radio at rest and after every arrow turn |
| Navigation | Left/Right/Up/Down, Home/End; disabled skipping; `radio.wrap` controls opposite-end continuation |
| Activation | Space, Return, pointer click, and semantic `Press` each leave exactly one checked radio, matching `selected_id`, with the previous radio cleared |
| Action parity | every advertised `Focus`, `Press`, and `Select` is performed; a rejected or ineffective advertised action fails `Semantic_Action_Parity` |

### `.Table` (static)

| Rule | Assertion |
| --- | --- |
| Table structure | one realized `Table` collection with a nonzero logical row count |
| Row structure | `Table_Row` child collections at unique row coordinates, parented to and collected by the table; `size_of_set` agrees with the table count |
| Cell structure | `Table_Cell`, `Table_Column_Header`, and `Table_Row_Header` cells are collected by and parented to a published row |
| Coordinates | each realized row publishes contiguous, unique column positions; every realized row has the same column count |
| Logical counts | a realized row publishes exactly its logical cell count; virtual rows publish their own logical count |
| Header grouping | a configured `Header_Row` is a table row and owns every `Table_Column_Header`; column headers in one row when no header part is configured |
| Virtual rows | all logical row items are published as virtual rows outside the realized window, or only the realized window is published; the window matches the realized row count |
| Reveal | with `expect_virtual_reveal`, ordinary Page Down advances the realized window and the refreshed structure still conforms |
| Focus | none required; the static contract never asserts managed focus or roving |

### `.Data_Grid` (interactive)

| Rule | Assertion |
| --- | --- |
| Structure | the shared table structure, with every logical row realized for deterministic navigation |
| Columns | `grid.columns` agrees with the published column count and is greater than one |
| Disabled policy | disabled cells and rows are non-focusable, unfocused, and advertise no `Focus`, `Press`, or `Select`; a disabled row marks its cells disabled |
| Focus | exactly one focused cell at rest and after every turn; zero is `Containment`, more than one is a focus-contract failure |
| Navigation | Left/Right move cells, Up/Down move rows, Home/End use the configured row or whole-set scope; disabled cells and rows are skipped; `wrap` and `row_bounded` follow the configuration |
| Containment | focus stays on a grid cell or row; an arrow that sends focus outside fails `Containment` |
| Reveal | a focused cell must be realized inside the grid viewport when `expect_reveal` is set |
| Selection | `.Cell` requires exactly one selected cell and a matching grid `selected_id`; `.Row` requires the same for the activated cell's row; `.None` skips selection assertions |
| Activation parity | Space, Return, pointer click, and semantic `Press` keep the configured selection agreement |
| Action parity | every advertised `Focus`, `Press`, and `Select` is performed; rejection or no effect fails |

The v1 grid uses `.Table` roles. A dedicated grid role is not introduced; that
role question is recorded below rather than decided in this slice.

## Fixtures and controls

Fixtures live in `testui/compound_pattern_test.odin`. The radio and static-table
fixtures mirror the app-authored shapes in `ui/ui_semantic_compound_test.odin`;
the radio fixture adds the roving keyboard and activation drive, and the table
fixtures add header/coordinate and virtual-window variants.

### Positive controls

| Fixture | Contract |
| --- | --- |
| Radio group (`radio_fixture_*`) | four radios with one disabled; initial checked item; roving arrows with wrap; Space/Return/pointer/semantic Press |
| Radio group with no selection | same fixture starting at `selected=-1`; conforms because the W3C pattern permits it |
| Static table (`table_fixture_*`) | header row plus two body rows, two columns, row headers, column headers, logical counts |
| Virtual static table (`virtual_table_*`) | eight logical rows in a bounded scroll window, virtual row items outside the window, Page Down reveal |
| Data grid, cell selection (`grid_fixture_*`) | four-by-four grid, one disabled cell, one disabled row, cell focus, arrows, Home/End, reveal, cell selection, keyboard/pointer/semantic activation |
| Data grid, row selection | the same grid with `.Row` selection; the activated cell's row carries `Selected` and the grid `selected_id` names the row |

Results: all six positives conform.

### Negative controls

| Fault | Named failure |
| --- | --- |
| Two radios publish `Checked` | `Radio_Group/Static_Contract` |
| `Checked` item does not match group `selected_id` | `Radio_Group/Static_Contract` |
| Disabled radio remains focusable | `Radio_Group/Focus_Contract` |
| Enabled radio advertises `Focus` but is not focusable | `Radio_Group/Semantic_Action_Parity` |
| Empty initial group with `require_initial_selection=true` | `Radio_Group/Static_Contract` |
| Body row publishes fewer cells than its logical count | `Table/Static_Contract` |
| Cell collected directly by the table | `Table/Static_Contract` |
| Column header parented to the table instead of its row | `Table/Static_Contract`, part `Header_Row` |
| Two semantic cells name one focused visual node | `Data_Grid/Static_Contract` |
| Right arrow moves focus to a control outside the grid | `Data_Grid/Containment` |
| Activation selects a different cell than the focused one | `Data_Grid/Semantic_Action_Parity` |
| Enabled grid cell advertises `Focus` but is not focusable | `Data_Grid/Semantic_Action_Parity` |

Every negative fails at the named step, and each positive passes with the same
configuration. The data-grid selection-mismatch fault is caught by the semantic
action-parity sweep because that sweep presses every enabled cell before the
keyboard activation phase; the reported step is therefore
`Semantic_Action_Parity`, not `Activation_Parity`.

## Advertised-versus-performable findings

Building the checkers surfaced four runtime behaviors. None is fixed in this
slice; the first is the #218/AliKit-#3 core ask already carried by the issue.

1. **Semantic `Focus` on a non-focusable item is rejected.**
   `semantic_action_request(.Focus)` returns false when the semantic item's
   visual node is not focusable, even if the item advertises `Focus`. A
   non-Tab-stop roving row or radio therefore fails action parity. The honest
   alternatives for a consumer today are to make the item focusable or stop
   advertising `Focus`; the runtime fix (roving semantic focus for non-Tab-stop
   items) remains a core ask.

2. **Semantic `Press` routes only for control roles.**
   `semantic_action_request(.Press)` routes as control activation only for
   `Button`, `Checkbox`, and `Radio_Button`. A `Table_Cell` or row/column header
   advertising `Press` is queued as a logical `Perform` request instead. The
   data-grid fixture consumes that request and applies selection, which makes
   its advertised `Press` performable. A composition that advertises `Press` on
   a table role but does not drain the request will fail the checker because
   nothing changes.

3. **Collection `Focus` is unconditional.**
   `semantic_collection_begin` adds `Focus` to every collection, including a
   non-focusable static table and its rows. The static `Table` kind deliberately
   does not assert action parity because it has no activation contract, but the
   advertised `Focus` on those collections is not performable and belongs with
   the same runtime ask.

4. **`semantic_collection_item` ignores a supplied `visual_node`.**
   `Semantic_Node_Description.visual_node` is not copied by
   `semantic_collection_item`; the collection item always binds to the visual
   node whose description is pending. A composition cannot point a collection
   item at a different visual owner through that API. The two-focused negative
   control uses the public `semantic_node_set` path instead.

## Validation

Commands run from this branch:

```text
odin test runtime                                       520 tests, all successful
odin test testui -collection:alicorn=<repo> ...          55 tests, all successful (was 37)
odin test ui -collection:alicorn=<repo> ...              58 tests, all successful
odin test theme                                          37 tests, all successful
```

The testui growth is 18 tests: seven radio controls, five static-table controls
(including the virtual positive), and six data-grid controls (including cell and
row selection). The existing 37 tests, including the roving list/grid controls,
still pass.

Windows `tools/test.ps1` still stops on the Odin test runner's INFO stderr, so
the affected stages were invoked directly with the pinned AccessKit compiler
arguments, matching the #225 record.

## Limits

- The checkers consume published semantics and logical input only. They do not
  exercise a native accessibility bridge, OS IME candidate windows, pixels, or a
  screen reader.
- The interactive grid positive keeps every logical row realized. Virtual-row
  windows are covered by the static table positive; navigation across an
  unrealized grid row would look like a missing contract without additional
  runtime introspection.
- The v1 grid is non-spanned like the issue's table scope. Row-focus compositions
  are accepted structurally, but the positive fixture exercises cell focus.
- A dedicated grid role, and the runtime focus/action behaviors above, are
  recorded asks, not part of this slice.
