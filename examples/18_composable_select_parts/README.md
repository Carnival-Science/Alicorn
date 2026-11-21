# Composable Select Parts

This example is a userland Select composed from Alicorn's public facilities.
It is intentionally **not** a runtime framework change: the stock
`alicorn.select_control` implementation is untouched. The package demonstrates
the opposite direction: applications can copy, edit, and extend a select with
their own rows, icons, badges, trigger visuals, and app-specific data shaping.

Run it from the repository root:

```sh
./tools/run_example.sh 18_composable_select_parts
```

```powershell
.\tools\run_example.ps1 -Example 18_composable_select_parts
```

The package theme JSON is embedded beside the package, so the executable does
not depend on the current working directory.

## Package

`select_parts/select_parts.odin` exposes a small copyable contract:

- `Select_Parts_State` owns the controlled selected key, open/active state,
  retained trigger/list/panel identities, the bounded type-ahead buffer, and an
  application-extensible recent-key ring.
- `Select_Parts_Option` and `Select_Parts_Group` mirror stock Select data:
  stable keys, labels, disabled flags, single-level groups, plus presentation
  fields (`icon`, `badge`) that do not affect semantic identity.
- `Select_Parts_Recipe` declares the two appearances (`Compact`, `Rich`), the
  extension color roles, geometry, and the virtualized popup size.
- `select_parts(ctx, label, state, groups, recipe, key, instance_id) -> bool`
  describes the trigger and reports one controlled change.
- `select_parts_overlay(...)` describes the popup from the host's
  `render_overlays` hook after the ordinary root closes.
- `select_parts_text` and `select_parts_text_key` receive committed text and
  normalized text-navigation keys for the focused option row.
- `select_parts_note_recent`, `select_parts_clear_recent`, and
  `select_parts_recent_keys` support an application-owned pinned group.

Semantic identities are derived from `instance_id` and stable option keys:

```odin
option_id := select_parts.select_parts_option_id(instance_id, option.key)
```

The same key in two owner instances therefore remains distinct, while one
instance keeps identity across the compact and rich appearances.

## How the behavior is composed

Every behavior uses public facilities only:

| Behavior | Public composition |
|---|---|
| Trigger hit testing, keyboard focus, activation | `button_begin` / `button_end` with `presentation=.Custom` |
| Trigger visuals and focus ring | `surface_begin`, `visual_part_attach` (`.Surface`, `.Label`, `.Overlay`, `.Focus_Indicator` / `.Owner_Focus_Visible`) |
| Popup ownership and outside-click dismissal | `modal_overlay_begin` / `modal_overlay_end`, a full-viewport blocker, and a modal `ui.interaction_scope` |
| Popup placement | `context_menu_placement` |
| Option rows and rich parts | ordinary nested `Button` owners with custom presentation, plus icons, text, badge surfaces, hover cues, and selected indicators |
| Groups and rows | `semantic_collection_begin(.List_Box, parent=trigger)`, `semantic_collection_item(.List_Box_Option)`, `.Group` headers, and semantic `parent` links |
| Virtual reveal | `virtual_list_begin`, `virtual_list_end`, and `virtual_list_ensure_visible` |
| Keyboard navigation | modal `interaction_scope` for Up/Down/Home/End/Return/Space/Escape; normalized text keys for Home/End/Tab on the focused row |
| Type-ahead | the focused row is a generic `text_input_target`; committed text reaches `select_parts_text`, which owns its own bounded prefix buffer |
| Focus open/restore | `ui.after_frame` focuses the active option after layout and restores the trigger (or traverses on Tab) after the retiring popup is reconciled |
| Theme contract | extension color roles, `style_extension_color_role_id`, and the package's `theme_contract_check` |
| Application extension | app-owned state/procedures and `ui.interaction_scope` on the package-owned trigger |

The popup is deliberately a modal layer rather than the Context Menu machinery.
A Context Menu routes keys only to direct Button children and consumes all other
keys before scoped owners, so a nested virtualized listbox cannot receive its
own navigation. This is recorded as a core-candidate finding in the pilot
validation rather than patched in the runtime.

## Two appearances

Both instances bind the same contract:

- **Compact**: a short trigger and compact dropdown rows.
- **Rich**: a taller trigger and rows with circular icon surfaces, badges,
  selected checkmarks, hover cues, and the same semantic IDs and behavior.

`main_test.odin` switches one instance from Compact to Rich in place and asserts
that trigger, list, option, and selected identities survive.

## Application-authored behavior

`build_compact_groups` partitions the option source into a pinned `Recent` group
and an `All presets` group, using only the package's public recent-key helpers
and app-owned data. The example also registers its own scoped input on the
package-owned trigger: focus the trigger and press **Ctrl+1** to pin the current
value, or use the **Pin current** button. No engine change is required.

## Validation

`main_test.odin` covers:

- open/close, Up/Down/Home/End/Enter/Escape, disabled skipping, type-ahead,
  extension-backed IME preedit yielding, and one controlled change;
- outside-click dismissal and focus restoration;
- Tab/Shift+Tab traversal after reconciliation;
- two owner instances with the same option keys;
- option reorder/deletion preserving the selected stable key;
- grouped `Group` parents and a List_Box count that excludes headers;
- a foreign modal layer closing/rejecting the parts popup;
- compact/rich appearance identity;
- idle time after settle and teardown with retained overlay state.

`test_select_parts_semantic_parity_with_stock_select` compares the stock
`select_control` popup and the parts popup for the same option set. It asserts
role, label, value, parent structure, states, actions, logical count, selected
identity, and current identity match after normalizing the implementation-owned
IDs.

`select_parts/select_parts_test.odin` covers the pure model helpers:
case-insensitive Unicode prefix matching, duplicate/malformed group rejection,
stable instance/key identity, the bounded recent ring, and recipe/theme
contract validation.

`pilot_test.odin` runs the stock and parts controls through the same scripted
turns for the GO/NO-GO measurement in
[docs/validation/issue-218-parts-pilot-2026-11-21.md](../../docs/validation/issue-218-parts-pilot-2026-11-21.md).
