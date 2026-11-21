# Collection parent parameter (issue #223)

Date: 2026-11-21

Branch: `codex/issue-223-collection-parent`

Status: implemented and covered by `odin test runtime`, `odin test testui`,
`odin test ui`, and the example 18 test suite. No native assistive-technology
session was needed: this closes a public-API gap and preserves the published
semantic snapshot.

## Gap

`semantic_collection_begin` published a collection and attached items, but it
could not name the collection's own semantic parent. A popup list therefore had
to patch the pending description record after publication:

- stock Select did this internally to make the popup `List_Box` a child of the
  `Combo_Box` trigger;
- the #218 userland pilot isolated the same patch in
  `select_parts_set_collection_parent`;
- the testui custom-combobox pattern fixture patched the pending record too.

## Shape

The minimal backward-compatible option was chosen: an optional trailing
`parent := Semantic_ID{}` parameter on `semantic_collection_begin`. Zero keeps
the existing nearest-described-semantic-ancestor fallback; a valid parent is
written into the pending descriptor's `semantic.parent` at publication, before
the owner node is realized. No post-creation reparent API was added.

```odin
semantic_collection_begin(
    ui,
    owner,
    id,
    .List_Box,
    label,
    logical_count,
    realized_first=0,
    realized_last=logical_count,
    parent=trigger_semantic_id,
)
```

An item's own `parent` (for example a labeled Select group) is independent of
the collection parent, so the two mechanisms compose exactly as before.

## Consumers migrated

| Consumer | Change |
|---|---|
| `runtime/select.odin` | Passes `parent=state.trigger_semantic_id`; the pending-record patch is removed. Group headers now publish through the public `semantic_collection_item` path with `parent=` instead of patching `semantic.parent`/`collection_id`. |
| `examples/18_composable_select_parts/select_parts/select_parts.odin` | Passes `parent=state.trigger_semantic_id`; `select_parts_set_collection_parent` is deleted. |
| `testui/pattern_checks_test.odin` | Passes the trigger as `parent`, or zero for the deliberate `List_Unparented` negative control. |

## Tests

`runtime/semantic_collection_parent_test.odin` covers:

- an explicit parent overriding visual ancestry (`List_Box.parent` is the
  trigger, not the panel's visual ancestor);
- the zero-parent default keeping the nearest described semantic ancestor;
- publication through an unrealized pending record, including a parent entity
  described later in the same frame, then surviving re-description on the next
  frame;
- grouped options where the collection names the trigger, the group names the
  list, and options name the group or the list through `item.parent`.

Existing regression coverage remains authoritative for behavior parity:

- `runtime/select_test.odin` asserts the stock popup `List_Box` parent and the
  grouped-option parents;
- `testui/pattern_checks_test.odin` keeps the positive custom combobox and the
  `List_Unparented` negative control;
- `examples/18_composable_select_parts/main_test.odin` compares stock and parts
  semantic records position by position, including parent structure, and keeps
  the grouped-parent and appearance-identity checks.

## Evidence

| Check | Result |
|---|---|
| `odin test runtime` | 434 tests, all successful (including 4 new #223 tests) |
| `odin test testui` | 22 tests, all successful |
| `odin test ui` | 57 tests, all successful |
| `odin test examples/18_composable_select_parts` | 12 tests, all successful, including stock-versus-parts semantic parity |
| `odin build examples/18_composable_select_parts` | successful |
| `odin build tests` + `out/alicorn_tests.exe` | successful; foundation fixture reports PASS |

The parity comparison normalizes implementation-owned IDs and compares role,
label, value, parent, collection, states, actions, logical count, selected ID,
and current ID. Its result is unchanged.

## Limits

The parameter names a semantic relationship; it does not reorder visual layout,
create a semantic entity for a missing parent, or validate that the parent role
is a `Combo_Box`. Callers own that relationship, as with `item.parent`.
`semantic_collection_virtual_item` still parents logical items to the collection
itself; subgroup parenting for logical-only rows remains a separate concern.
