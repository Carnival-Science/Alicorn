# Issue 218: composable Select parts pilot

Date: 2026-11-21
Branch: `codex/issue-218-composable-parts`
Fixture: `examples/18_composable_select_parts`

## Verdict

**GO for the copyable userland parts recipe. NO-GO for a runtime framework
change in this issue.**

The public facilities can compose a complete Select without adding runtime
APIs: `button_begin(presentation=.Custom)`, visual parts, semantic collections,
a retained virtual list, a modal overlay, interaction scopes, after-frame focus
restoration, and theme extension roles. The stock Select (`runtime/select.odin`)
was not modified. Two concrete public-facility gaps remain (collection parent
identity and Context Menu keyboard routing for nested owners); both are recorded
as core candidates rather than patched. The shared-behavior extraction is a
NO-GO for now: the type-ahead/navigation duplication is real but would require a
new model-level runtime API while the stock Select is explicitly out of scope
for this pilot, and the two implementations own different data models, group
layouts, and text-routing paths.

## Baseline and candidate

The pilot compares two applications on one machine with the same 12-option
source (one disabled option, one long option at the end):

- **Baseline** `stock`: `alicorn.select_control` and its runtime-owned popup.
- **Candidate** `parts`: `examples/18_composable_select_parts/select_parts`,
  compact appearance, 12 options in one unlabeled group.

The scripted turns are: open by pointer click, committed text `"t"`, Down,
Home, End, Return (select and close), Escape (close). The measurement fixture is
`pilot_test.odin`; run it with one test thread:

```sh
odin test examples/18_composable_select_parts -define:ODIN_TEST_THREADS=1
```

### Code and API surface

| Metric | Stock Select | Parts package |
|---|---:|---:|
| Runtime implementation | 874 LOC (`runtime/select.odin`) | 0 LOC changed |
| Userland package | n/a | 1,144 LOC (`select_parts.odin` + `theme.odin`) |
| Example app | shared fixture | 272 LOC |
| Example tests | shared fixture | 579 LOC |
| Pilot fixture | shared fixture | 289 LOC |
| New runtime APIs | 0 | **0** |
| Public package declarations | n/a | 39 (14 constants, 7 types incl. helper contracts, 18 procedures) |
| Internal helpers marked `@(private)` | n/a | 29 |
| Direct pending-record access | stock has the same internal patch | 1 parent write + 1 same-frame modal scan (recorded below) |

The 39 declarations include the public state/option/group/recipe/theme contract
and semantic-ID helpers. No `runtime/` file changed in this branch.

## Turn work

Cumulative `testui.Turn_Work` deltas over the seven measured turns. Values are
runtime work units, not frame counts; the parts control describes more visual
nodes per row (icon, badge, hover cue, focus frame, selected indicator).

| Work counter | Stock | Parts | Parts / stock |
|---|---:|---:|---:|
| Turns | 7 | 7 | 1.00x |
| Descriptions emitted | 110 | 390 | 3.55x |
| Descriptions reused | 87 | 339 | 3.90x |
| Reconcile nodes visited | 110 | 390 | 3.55x |
| Measure nodes examined | 1 | 1 | 1.00x |
| Layout nodes visited | 120 | 119 | 0.99x |
| Paint nodes visited | 63 | 71 | 1.13x |
| Composition nodes visited | 114 | 80 | 0.70x |
| Text-shape requests | 13 | 9 | 0.69x |
| Semantic structure changes | 23 | 16 | 0.70x |
| Semantic property changes | 44 | 8 | 0.18x |

The large description/reconcile delta is the rich-parts tax: each option row is
an application-authored Button subtree instead of one runtime-emitted Button.
Layout, composition, text shaping, and semantic publication do not regress; the
candidate publishes fewer semantic property transitions because it does not
re-describe runtime-owned option state on every popup pass.

## Allocation attribution

Allocations observed through the `testui.open` allocator, including the shared
font/text-engine setup. Top sites are truncated by bytes.

| Site | Stock allocations/bytes | Parts allocations/bytes |
|---|---:|---:|
| `text_engine_load_italic_font_role` (shared) | 2 / 180,280 | 2 / 180,280 |
| `text_engine_load_font_role` (shared) | 2 / 168,512 | 2 / 168,512 |
| `emit_key` | 3 / 74,816 | 4 / 160,320 |
| `_dynamic_arena_cycle_new_block` (shared) | 1 / 65,536 | 1 / 65,536 |
| `reconcile` | - | 54 / 109,296 |
| Test/open setup (shared) | 1 / 37,368 | - |
| **Total** | **705 / 870,925** | **1,133 / 1,209,051** |

The parts package allocates 60% more bytes in total. The excess is concentrated
in the larger retained node map and the custom row/trigger descriptions, not in
text shaping or layout. The shared font setup is identical.

## Latency and idle

Measured wall-clock latency per scripted turn includes testui's bounded
descriptions and retained presentation; it is not a GPU frame time.

| Metric | Stock | Parts |
|---|---:|---:|
| p50 turn | 101,100 ns | 158,400 ns |
| p95 turn | 861,700 ns | 1,132,900 ns |
| Idle wakes after settle (`advance_time`, 16 ms) | 0 | 0 |

The candidate is slower per turn, consistent with the larger described subtree.
Wall-clock p50 varied by roughly 40-60 microseconds between repeated local runs;
the work counters above are deterministic and are the primary comparison. Both
controls return to zero scheduled descriptions and zero retained presentation
work after settle.

## Semantic parity

`test_select_parts_semantic_parity_with_stock_select` opens stock and parts
controls with the same option set and normalizes implementation-owned IDs. It
matches six semantic records (Combo_Box trigger, List_Box popup, four
List_Box_Options) on:

- role, label, value, and parent structure (`List_Box` parented to the trigger;
  options parented to the List_Box or a labeled Group);
- Selected/Disabled states, Select/Focus actions, and the trigger's
  Expanded/Focus/Expand-or-Collapse contract;
- logical count, selected identity, and current identity.

`test_select_parts_group_headers_expose_group_parents_without_counting_header_rows`
adds labeled groups and asserts that a Group is published while the List_Box
logical count stays the option count. `test_select_parts_appearance_switch_preserves_semantic_identity`
switches one instance from Compact to Rich and asserts trigger, list, option,
and selected identities survive.

All 12 example tests and all 5 package tests pass.

## GO/NO-GO per extraction candidate

Two-consumer rule: the stock Select and this package both implement prefix
type-ahead and enabled-option navigation. A helper is only worth extracting if
it is small, pure, UI-independent, and both consumers can use it without
changing the stock contract.

| Candidate | Duplication | Verdict | Evidence |
|---|---|---|---|
| Prefix match + case folding | ~35 LOC in each implementation | **NO-GO for #218** | Pure and extractable, but a new runtime model API would be introduced while the stock Select is out of scope. Revisit with a second independent userland consumer. |
| Enabled-option navigation (next/previous/first/last) | ~40 LOC in each implementation | **NO-GO for #218** | The stock implementation works over bounded index arrays; the package works over grouped slices with app-owned presentation fields. Extraction would not remove the group/row-plan duplication. |
| Type-ahead match/restart policy | ~45 LOC | **NO-GO for #218** | The package receives committed text through a generic text target and its own callback; stock owns runtime text-input routing. A model-only helper would still leave both routing paths. |
| Popup placement/flip/clamp | `context_menu_placement` reused | **GO (already shared)** | No new API; both consumers use the same public helper. |
| Popup keyboard routing | different mechanisms | **NO-GO** | Context Menu routes only direct Button children and consumes other keys; nested virtualized rows need a generic owner-routed transient popup. Recorded as a core candidate below. |
| Semantic collection publication | shared public API | **GO (already shared)** | `semantic_collection_begin` / `semantic_collection_item` provide parity, including the collection-level `parent` added by #223. |
| Visual row recipes | package-owned by design | **NO-GO** | The point of parts is app ownership; a shared recipe would recreate the framework this pilot rejects. |

## Core-candidate findings (not solved by this pilot)

These are concrete capability gaps found while composing the package. They are
recorded for a future issue; none were patched in this branch.

1. **Collection parent identity.** `semantic_collection_begin` can publish a
   collection and attach items, but it cannot name the collection's own semantic
   parent. Stock Select patches the pending record internally so the List_Box is
   a child of the Combo_Box trigger. The package isolates the same patch in
   `select_parts_set_collection_parent`; a public parent parameter (or
   `semantic_collection_begin(parent=...)`) would remove this direct
   pending-record access. The only other pending scan detects a foreign modal
   described earlier in the same frame, because retained top-level state advances
   only during reconciliation.
   **Resolved by #223.** `semantic_collection_begin` now takes an optional
   `parent`; stock Select, the testui custom-combobox fixture, and this package
   pass it directly, and `select_parts_set_collection_parent` is deleted.
2. **Generic transient-popup keyboard routing.** Context Menu consumes
   Up/Down/Home/End/Enter/Escape before scoped owners and routes only direct
   Button children. A virtualized, nested listbox therefore cannot receive its
   own navigation through the Context Menu machinery. The package uses a modal
   overlay + modal interaction scope instead. A public owner-routed popup mode
   would preserve placement, outside-click, and focus restoration without the
   direct-child restriction.
3. **Same-frame virtual reveal patch.** `virtual_list_ensure_visible` updates a
   retained scroll region on the next description. Stock Select patches the
   pending scroll record for an immediate same-frame reveal. The package needs
   one extra description on first open; the test suite treats that as part of
   the bounded turn. A public pending-scroll request would close the gap.
4. **Pointer capture for arbitrary owners.** Rich rows and the application-owned
   recent tray need pointer routing outside the Context Menu's direct-child
   model. A generic `capture`/owner pointer scope worked here, but it required a
   full-viewport modal layer; a first-class non-modal popup owner would be
   smaller and less disruptive.
5. **Generic roving focus.** The package focuses its active option with
   `alicorn.focus` plus an after-frame hook. There is no public roving-index
   helper that skips disabled items and survives row virtualization. Stock
   Select keeps this logic in runtime state.
6. **Generic type-ahead.** Type-ahead required marking the active row as a
   generic `text_input_target` and forwarding committed text through the app
   callback. There is no public type-ahead collector for an arbitrary focused
   owner. This also makes Space activation arrive as committed text in the
   generic path; the package maps a bare space with an empty buffer to
   activation.
7. **IME/focus timing.** `composition_yield_keys` correctly yields preedit
   input, and the package leaves the popup open during preedit. Restoring focus
   after a modal dismissal must wait for `ui.after_frame`; calling `focus` on
   the trigger while the retiring modal layer is still retained fails. The
   package uses after-frame for both open focus and close restore.
8. **2D semantic value.** The trigger's visible value and its option identity are
   separate concepts, but a Combo_Box exposes one semantic value string. Rich
   rows cannot advertise a second dimension (for example icon name plus badge)
   without custom matching keys. This was not needed for parity and remains a
   core-candidate semantic extension.

## Reproduction and limits

- The measurement is headless (`testui`) and excludes GPU submission, native
  IME candidate windows, and OS accessibility bridging.
- The parity test compares semantic snapshots after ID normalization. It does
  not prove a physical screen-reader run.
- The example and package tests use the same bundled fonts and the same
  headless runtime as the rest of the validation suite.
