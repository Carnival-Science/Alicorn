# Reusable accessibility and interaction pattern checks (issue #217)

Date: 2026-11-21

Branch: `codex/issue-217-pattern-checks`

Status: implemented and covered by the existing `odin test testui` CI entry.
This record documents the test-only conformance layer; it is not a WCAG
conformance claim or native assistive-technology acceptance.

## Scope

Issue #217 asked for reusable pattern-conformance checks that a consumer can
apply to a composed control, not another runtime registry. The implementation is
`testui/pattern_checks.odin`, plus `testui/pattern_checks_test.odin` for the
positive and negative controls. It adds no runtime metadata, marker, or
control-identity table.

The first two patterns are:

1. **Single-select list/combobox** — the stock `select_control` /
   `select_control_grouped` consumer, plus a custom userland combobox assembled
   from public API (`button_begin` with `presentation=.Custom`,
   `semantic_description(.Combo_Box)`, a top-level overlay, and
   `semantic_collection_begin`/`semantic_collection_item`).
2. **Modal dialog** — an application-owned composed dialog over
   `modal_overlay_begin`/`modal_overlay_end`, with its own dismissal and
   focus restoration. It deliberately checks the composition rather than only
   private runtime internals.

A roving toolbar is deferred: there is no consumer yet. Issue #218's pilot is
the natural third pattern once its consumer exists.

## API surface

```odin
Pattern_Kind :: enum { Combobox_Listbox, Modal_Dialog }

Pattern_Part_ID :: enum {
    Trigger, List, Dialog, Nested_Dialog,
    Target_Option, Disabled_Option, Selected_Option, Peer_Trigger,
    Primary_Action, Secondary_Action, Background_Action, Extra_Action,
    Transient_Action, Nested_Action, Nested_Secondary_Action, Modal_Action,
}

Pattern_Part :: struct {
    id: Pattern_Part_ID,
    query: Query,                       // role/name/key filters
    semantic_id: Semantic_ID,           // explicit identity
    semantic_id_valid: bool,
    key: UI_Key,                        // optional exact retained key
    key_valid: bool,
}

Pattern_Config :: struct {
    kind: Pattern_Kind,
    parts: []Pattern_Part,
    expected_selected_id: Semantic_ID,
    expect_selected_id: bool,
    expected_selected_key: u64,
    expect_selected_key: bool,
    expected_option_count: u64,
    expect_option_count: bool,
    expect_virtual_reveal: bool,
    support_semantic_expand: bool,
    max_focus_cycle: int,
}

Pattern_Failure :: struct {
    pattern: Pattern_Kind,
    step: Pattern_Step,
    part: Pattern_Part_ID,
    part_valid: bool,
    semantic_id: Semantic_ID,
    key_valid: bool,
    key_text: [192]u8, key_text_length: int,
    expected: [192]u8, expected_length: int,
    actual: [192]u8, actual_length: int,
    message: [192]u8, message_length: int,
    cause_id: u64,
    cause_kind: Cause_Kind,
    action_id: Action_ID,
    turn: Turn_Report,
}

Pattern_Report :: struct { ok: bool, failure: Pattern_Failure }

pattern_check(handle, config) -> Pattern_Report
pattern_check_combobox(handle, config) -> Pattern_Report
pattern_check_modal_dialog(handle, config) -> Pattern_Report
pattern_failure_diagnostic(failure: ^Pattern_Failure) -> string
```

Parts are resolved by an explicit `Semantic_ID` when supplied, otherwise by
ordinary `Query` filters and an optional exact retained key. Missing or
ambiguous parts are failures with diagnostics; an optional part that is absent
skips only its drive phase.

## Rule tables implemented

### Combobox static contract

| Rule | Failure step |
| --- | --- |
| Trigger role is `Combo_Box` | `Static_Contract` |
| Enabled trigger advertises `Focus` | `Static_Contract` |
| Collapsed trigger has `Expand`, not `Expanded`/`Collapse`; open trigger has `Expanded`/`Collapse`, not `Expand` | `Static_Contract` |
| A realized `List_Box` is parented to the trigger semantic | `Static_Contract` |
| `List_Box` is a collection with `Focus` and the expected `logical_count` | `Static_Contract` |
| Realized options use `List_Box_Option`, belong to the List_Box collection, and have in-range unique positions | `Static_Contract` |
| Exactly one option is `Selected`; `selected_id` agrees; trigger value agrees | `Static_Contract` |
| Enabled options advertise `Select` and `Focus`; disabled options advertise neither and are not focusable | `Static_Contract` |
| Disabled option has `Disabled` and no selectable/focusable actions | `Static_Contract` |
| Option keys are unique within one owner | `Static_Contract` |
| Labeled-group options have a named `Group` parent owned by the List_Box; unlabeled options parent directly to the list | `Static_Contract` |
| Configured initial selected key/id and logical count | `Static_Contract` |

### Combobox drive contract

| Phase | Assertion |
| --- | --- |
| `Keyboard_Open` | Semantic `Focus` + Space opens; focus is on the trigger or inside the List_Box; open states/actions are consistent |
| `Navigation` | Home/End select the first/last enabled option; Down/Up skip disabled and wrap; no disabled option ever becomes current |
| `Keyboard_Selection` | Return selects `Target_Option`; popup closes; trigger regains focus; selected key/label match; trigger remains operable |
| `Escape_Cancel` | Down then Escape closes without changing the controlled key; focus returns to the trigger |
| `Typeahead` | Committed text moves the current option to an enabled prefix match and never lands on a disabled option |
| `Tab_Close` | Tab closes the popup and removes focus from the trigger |
| `Pointer_Parity` | Pointer opens and an option click selects the same key as keyboard selection |
| `Semantic_Action_Parity` | Semantic `Expand` (stock handler) or pointer opening (custom composition) is followed by semantic option `Select` with the same key |
| `Disabled_Option` | Semantic `Select` is rejected; type-ahead and navigation skip the disabled option |
| `Virtual_Reveal` | In a long stock list, End realizes the active option and it intersects the visible List_Box bounds |
| `Owner_Identity` | The same stable keys in two Select owners publish distinct option `Semantic_ID`s |
| `Reorder_Identity` | Reordering application options keeps the selected key, label, and `Semantic_ID`, and moves its published position |
| `Modal_Rejection` | A trigger behind a modal rejects semantic `Expand` without changing state; Escape dismisses the modal |

### Modal dialog contract

| Phase | Assertion |
| --- | --- |
| `Focus_Inside` | Opening from the trigger publishes one `Dialog` and moves focus inside its bounds |
| `Containment` | Pointer click and semantic `Press` on a background control are rejected; focus stays inside the dialog |
| `Traversal_Wrap` | Repeated Tab stays inside the dialog and wraps to its starting control with at least two distinct stops |
| `Dismissal` | Escape removes the Dialog and restores focus to the saved opener |
| `Activation_Parity` | Pointer, Return on focused primary, and semantic `Press` all activate the application primary action and close |
| `Focus_Recovery` | Removing the focused dialog child re-publishes the parent dialog and recovers focus inside it |
| `Nested_Overlay` | A second overlay owns focus and blocks the covered first dialog; closing it restores the first dialog and finally the original opener |

## Positive controls

| Control | Result |
| --- | --- |
| Stock `select_control_grouped`: 12 options, two labeled groups, one disabled option, long enough to scroll | passes all phases, including virtual reveal, peer-owner identity, reorder identity, and background-modal rejection |
| Custom userland combobox: `button_begin(.Custom)` + explicit `Combo_Box` semantics + non-modal top-level overlay + `semantic_collection_begin` option items + application keyboard/type-ahead/focus handling | passes trigger/list/option static rules, keyboard and pointer selection, Escape/Tab, disabled rejection, type-ahead, semantic option `Select`, and selected-key checks |
| App-owned modal: `modal_overlay_begin`, explicit `Dialog` semantics, own Escape/primary dismissal and `after_frame` focus restoration, nested second overlay | passes containment, wrap, parity, mid-dialog removal recovery, nesting, and restoration |

The custom combobox sets `support_semantic_expand=false`: the stock Select
accessibility handler currently claims `Combo_Box` Expand requests, so the
checker opens that composition through pointer input and still verifies the
semantic option `Select` path.

## Negative controls

| Negative fixture | Expected and asserted failing step |
| --- | --- |
| Plain button instead of a `Combo_Box` trigger | `Static_Contract` |
| List_Box not parented to the trigger | `Static_Contract` |
| Disabled option advertising `Select` and `Focus` | `Static_Contract` |
| Trigger missing `Focus`/focusable contract | `Static_Contract` |
| Selected key rebound to a different label after reorder | `Reorder_Identity` |
| Custom "modal" drawn without the modal focus scope, leaving the background focusable and semantically activatable | `Containment` |

Each test asserts both `!report.ok` and the exact `Pattern_Failure.step`.

## `testui.Element` extension

The following backward-compatible fields are copied from the published
`Semantic_Node`:

- `parent_semantic_id`, `collection_id`
- `position_in_set`, `size_of_set`, `logical_count`
- `tree_order`, `is_collection`, `is_virtual_item`
- `collection_selected`, `collection_current`
- `collection_selected_id`, `collection_current_id`

`find` populates collection flags by consulting the owning collection in the
same snapshot. Existing `Element` fields and test consumers are unchanged.

## Determinism and diagnostics

- Every interaction is followed by a fresh query; a stale `Element` is a
  failure, not a crash.
- No real sleeps are used. Time advances only through explicit virtual time.
- `Did_Not_Stabilize` and non-`Ok` turn statuses are reported with the turn
  diagnostic.
- A stock pointer option activation closes on the description after the frame
  that consumed activation. `pattern_settle_description` forces one ordinary
  follow-up description (no clock advance, no sleep) so the check observes the
  settled state.
- The first failure stops the check and records pattern/step, expected/actual,
  part, semantic ID, retained key, causal ID/kind/action, and turn metadata.

## External consumer note (AliKit)

The checker is exported from `alicorn:testui`, so an external package that
imports Alicorn can apply the same API to its own composition. The companion
AliKit command-palette positive control lives in the separate `alicorn-kit`
repository (pilot phase) and was not modified here. It can consume the API as:

```odin
import testui "alicorn:testui"

report := testui.pattern_check(&handle, testui.Pattern_Config{
    kind=.Combobox_Listbox,
    parts=parts,
    // explicit semantic IDs are available for the pilot's owned parts
})
```

## Honest limits

These checks operate on published semantics and logical input only. They do not
exercise an OS accessibility bridge, Narrator/NVDA/VoiceOver, a native IME
candidate window, native menus/dialogs, a device driver, shaders, or pixels.
They are not a WCAG conformance suite and do not prove native AT behavior.
Those claims remain with the physical acceptance path
(`tools/validate_native_webgpu_ui.ps1`) and the platform validation records.

## Verification

Environment: Windows, Odin at `C:\odin\odin.exe`, repository collection mapped
to this worktree. AccessKit was bootstrapped for the UI/example checks at
`.deps/odin-accesskit` with native headers under
`.deps/accesskit/accesskit-c-0.23.1/lib/windows`.

| Command | Result |
| --- | --- |
| `odin test testui -collection:alicorn=<worktree>` | 22/22 tests passed (13 pre-existing + 9 new pattern/Element tests), no tracked leaks or bad frees |
| `odin test runtime` | 427/427 tests passed |
| `odin check ui -collection:alicorn=<worktree> -collection:accesskit=<binding> -collection:accesskit_c=<lib> -no-entry-point` | passed (only pre-existing large-stack warnings) |
| `odin check examples/08_control_gallery` with the same collections | passed |
| `tools/test.ps1 -Odin C:\odin\odin.exe` | not usable in this environment: the AccessKit dependency's own `verify-uia.ps1` failed with `Accessible Button missing` before the Alicorn suites ran. This is the native Windows UIA contract fixture, not a change in this branch. The affected Alicorn packages were run individually as above. |

The new tests also pass with the default parallel runner and with
`-define:ODIN_TEST_THREADS=1`; virtual time and separate test handles keep them
deterministic. The repository's `tools/test.ps1`/`tools/test.sh` already include
`odin test testui`, so no CI entry was added.

## Files

- `testui/pattern_checks.odin` — types, resolution, static rules, drive phases,
  diagnostics.
- `testui/pattern_checks_test.odin` — stock, custom, modal, and negative
  fixtures/tests.
- `testui/testui.odin` — relationship snapshots on `Element`.
- `docs/reference.md` — adoption and negative-control recipe, rule summary,
  limits.
- `testui/README.md` — harness-level pointer to the new section.
