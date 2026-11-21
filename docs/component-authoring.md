# Component authoring

Alicorn ships layout, styling, motion, interaction, accessibility, rendering, and
testing primitives. It does not ship a component framework. A component is a
package of ordinary Odin values and procedures over the public `alicorn:ui` and
`alicorn:runtime` interfaces, with its tests driving the same input paths a host
uses.

This page is the standard for authoring one. It covers the layered
responsibility split, the five-point standard every sufficiently complex
component must demonstrate, the extraction rule that keeps the architecture
small, the verification loop for AI-assisted development, and the document
template for publishing a component.

The opportunity is concrete: an AI agent can copy an existing component,
radically alter its appearance and layout, and then verify that its interaction
and accessibility contracts still hold. That works not by inventing another way
to describe interfaces, but by making correctness inspectable, composable, and
testable.

## Division of responsibility

| Layer | Owns | Does not own |
| --- | --- | --- |
| **Alicorn** (`alicorn:ui`, `alicorn:runtime`, `alicorn:testui`) | Layout, styling, motion, interaction, accessibility semantics, rendering, and testing primitives. Public controls such as Button, Select, virtual lists, splits, tabs, overlays, and semantic collections. | A ready-made component catalog, application policy, or a second component lifecycle. |
| **AliKit** (optional, external) | Composable component parts and ready-to-use reference implementations that combine Alicorn primitives for a recurring job. | A second runtime, theme engine, retained tree, state store, or required framework. |
| **Application** | Custom behaviors as ordinary Odin procedures, composition, domain state, visual identity, and product policy. | Private runtime storage, a parallel accessibility tree, or a new engine subsystem. |

The dependency direction is one-way:

```text
Application
├── AliKit (optional)
│   └── Alicorn
└── Alicorn
```

Alicorn never imports AliKit or an application. AliKit imports the public
Alicorn packages, never private runtime fields. An application may skip AliKit
entirely and copy a component into its own tree; the copy remains an ordinary
public-API consumer.

State follows the same split. The application owns domain values and stable
identities. A component receives a caller-owned state pointer for ephemeral
interaction such as an open flag, an active row, or a query buffer. Alicorn
retains no pointer into application values.

If a component needs private runtime storage or a new host hook, stop and make
that a focused Alicorn API proposal. Do not add a component-local workaround
that reads private state, and do not grow AliKit into a second runtime.

## The five-point component standard

A component is ready to publish when all five points hold. Its documentation
must make each one inspectable. The [documentation
template](#documentation-template-for-component-pages) encodes this list.

1. **A complete, copyable implementation.** Ship the full working package, its
   theme data, a runnable call site, and its tests. A reader must be able to copy
   the folder into another project and build it without missing glue. The
   AliKit `icon_picker` pilot proves this by building a copied source tree
   outside AliKit's collection topology.

2. **Individually composable parts.** Expose the trigger, list or grid, rows,
   actions, and overlays as separate public types and procedures with stable
   keys and semantic identities. The caller must be able to omit a part,
   replace a row rendering, or compose the parts into a different shell. The
   [composable Select](../examples/18_composable_select_parts/README.md) splits
   the trigger, overlay, row visuals, and text/input adapters while leaving the
   stock `alicorn.select_control` untouched.

3. **Custom styling and motion.** Provide a component-owned recipe and style
   with namespaced theme extension roles, validate required roles at setup, and
   allow per-instance overrides without forking the component. Selection must
   remain apparent without relying on color alone. Motion uses `ui.motion`,
   retargets from the current presentation, honors reduced motion, and settles
   to idle. The [custom segmented
   control](../examples/12_custom_segmented_control/README.md) and the
   [Mode Rail](../examples/11_third_party_component/README.md) are the
   references.

4. **Keyboard and accessibility contracts.** State the key map, the focus owner,
   focus restoration, disabled behavior, and the published semantic role,
   name, value, states, and actions. State what the component does *not* claim.
   A Button group is not a radio group with arrow navigation unless it actually
   implements that contract. A control can reuse Alicorn's Button semantics
   without pretending to be a different widget.

5. **`testui` conformance examples.** Include positive tests for keyboard,
   pointer, and semantic activation parity; focus and selection continuity;
   removal, reorder, and disabled behavior; and an idle-settle assertion. Use
   `testui.pattern_check` where a documented pattern fits, and add a negative
   control that fails at a named contract step. The two current patterns are
   `.Combobox_Listbox` and `.Modal_Dialog`; see [pattern conformance
   checks](reference.md#pattern-conformance-checks-testui).

### Behaviors are ordinary Odin procedures

There is no component base type, lifecycle registry, event bus, or second
widget tree. A component is:

- a state value the caller owns and passes by pointer;
- procedures that describe its parts and return one controlled result;
- input routed through existing scopes (`ui.interaction_scope`, text targets,
  `ui.after_frame`) and existing semantic facilities.

The `select_parts` package is the worked shape:

```odin
state: select_parts.Select_Parts_State

changed := select_parts.select_parts(
	ctx,
	"Theme",
	&state,
	groups,
	recipe,
	ui.key_u64(1),
	1,
)
if changed {
	app.selected_key = state.selected_key
}

// In the host's render_overlays hook, after the ordinary root closes.
// The return value reports whether the popup was described; the next root
// pass reports a controlled change through select_parts.
if select_parts.select_parts_overlay(ctx, "Theme", &state, groups, recipe, 1) {
	// Popup described.
}
```

The [issue 218 pilot](validation/issue-218-parts-pilot-2026-11-21.md)
returned **GO for the copyable userland parts recipe** and **NO-GO for a runtime
framework change**. It added zero runtime APIs, changed zero lines of
`runtime/select.odin`, and composed the complete Select from public facilities.
The AliKit [issue 3
pilot](https://github.com/samanshaiza004/alicorn-kit/blob/codex/issue-3-parts-pilot/docs/research/issue-003-parts-pilot.md)
independently returned **GO for copyable source components and parts-based
results**, and **NO-GO for a generic behavior framework** or further migration.
It patched no Alicorn code.

Both pilots also found real core gaps and recorded them instead of smuggling a
framework around them. Collection parent identity is now closed by issue #223:
`semantic_collection_begin` accepts an optional `parent`, and the pilot package
passes its trigger there instead of editing the pending collection record.
Generic transient-popup keyboard routing, roving semantic focus, type-ahead
ownership for a generic text target, and a roving grid/list pattern check remain
open. Until a public API closes a gap, compose with what exists and document the
limit. The `icon_picker` pilot, for
example, documents that Space activation is unavailable under the current text
preemption rule rather than inventing a private workaround.

## The verification story for AI-assisted development

The copy-and-change loop is the product feature. It is deliberately mechanical:

1. **Copy** a complete exemplar into the application or package.
2. **Restyle and rearrange** the appearance and layout. Change recipe values,
   style overrides, container structure, and row rendering. Keep stable keys and
   semantic identities.
3. **Run the pattern checks** through `testui.pattern_check` when the component
   publishes a documented pattern. Use a deliberate negative control to prove
   the check still rejects a broken composition.
4. **Compare semantic snapshots** with the stock or reference implementation
   where one exists. Normalize implementation-owned IDs, then compare role,
   label, value, parent structure, states, actions, logical count, and
   selected/current identity.
5. **Drive interaction parity**: keyboard open/navigation/selection/cancel, Tab,
   pointer activation, semantic activation, disabled rejection, focus
   restoration, and identity across reorder or appearance changes.
6. **Advance virtual time after settle** and assert that no description or
   presentation wake remains.

The evidence is recorded, not assumed:

| Claim | Evidence | Where |
| --- | --- | --- |
| A userland composition can match the stock Select semantically | Six normalized semantic records match on role, label, value, parent, states, actions, logical count, selected and current identity | [issue 218 pilot, Semantic parity](validation/issue-218-parts-pilot-2026-11-21.md#semantic-parity) |
| Changing appearance preserves identity | Compact and Rich keep trigger, list, option, and selected identities; the AliKit picker keeps the same IDs and names across Grid and List | `examples/18_composable_select_parts/main_test.odin`, [AliKit issue 3 pilot](https://github.com/samanshaiza004/alicorn-kit/blob/codex/issue-3-parts-pilot/docs/research/issue-003-parts-pilot.md) |
| The checker rejects broken compositions | Six negative controls fail at a specific step: missing Combo_Box role, unparented List_Box, disabled option advertising actions, trigger missing Focus, a focusable control left behind a modal, and a stale key/label after reorder | [`testui/pattern_checks_test.odin`](../testui/pattern_checks_test.odin) |
| Both controls return to idle | Zero scheduled descriptions and zero retained presentation work after `advance_time` at 16 ms | [issue 218 pilot, Latency and idle](validation/issue-218-parts-pilot-2026-11-21.md#latency-and-idle) |
| No framework was required | Zero new runtime APIs in both pilots; stock components unchanged | Both pilot verdicts above |

Pattern checks are assertions over the semantics a component already publishes,
not a new metadata layer. They resolve named parts, verify the static contract,
then drive ordinary input. A positive run and a broken-fixture run should both
appear in the tests:

```odin
parts := []testui.Pattern_Part{
	{id=.Trigger, query=testui.Query{role=.Combo_Box, name="Theme", match_role=true, match_name=true}},
	{id=.List, query=testui.Query{role=.List_Box, name="Theme", match_role=true, match_name=true}},
	{id=.Target_Option, query=testui.Query{role=.List_Box_Option, name="Dark", match_role=true, match_name=true}},
}

report := testui.pattern_check(&h, testui.Pattern_Config{
	kind=.Combobox_Listbox,
	parts=parts,
	expected_option_count=3,
	expect_option_count=true,
})
testing.expect(t, report.ok, testui.pattern_failure_diagnostic(&report.failure))

// The negative control uses the same config against a deliberately broken fixture.
```

The checker does not simulate a platform accessibility bridge, OS IME candidate
window, native dialog, or pixels. It is not a WCAG conformance suite. Keep those
claims with the physical checks in `tools/validate_native_webgpu_ui.ps1` and the
validation records.

## The two-consumer extraction rule

Extract a shared helper only when all of these hold:

- at least two **dissimilar consumers** need the same generic contract;
- the helper is small, pure, and UI-independent;
- both consumers can adopt it without changing their public contract or data
  model;
- it removes more code than it adds, without a shape/parameter that recreates
  the duplication it was meant to remove.

Otherwise keep the local implementation. Duplication that is visible and
tested is cheaper than a premature abstraction that every consumer must work
around.

The rule has now returned NO-GO three times at the level that matters:

1. **#218 shared behavior extraction.** Three candidates were rejected: prefix
   matching, enabled-option navigation, and type-ahead. The stock Select was out
   of scope, and the two implementations own different data models, group
   layouts, and text-routing paths. Extraction would have introduced a new
   model-level runtime API while leaving the routing duplication in place.
2. **AliKit #3 shared navigation and popup helpers.** The palette parts and the
   icon picker keep caller-owned filtering and identity, but the picker adds 2D
   stride, row bounds, and appearance-dependent strides. A shared helper would
   need a navigation-shape parameter that recreates what each source already
   expresses in about 40 lines. Extracting the modal adapter would force focus
   restoration policy onto callers and recreate a component framework.
3. **A generic behavior framework.** Both pilots rejected it. The composites are
   ordinary state and procedures; a framework would add a second abstraction
   without a demonstrated consumer.

The rule is not anti-sharing. Alicorn already shares the primitives that earned
their place: `context_menu_placement`, `semantic_collection_begin` /
`semantic_collection_item`, public focus and interaction scopes, and `testui`
pattern checks. Sharing belongs in those primitives, not in a new component
layer.

## Exemplars

| Exemplar | What it demonstrates |
| --- | --- |
| [Custom segmented control](../examples/12_custom_segmented_control/README.md) | A complete third-party control that owns its pixels while public Button owners keep hit testing, focus, activation, and semantics. Two responsive presentations, a checked theme contract, per-instance styling, and interruptible marker motion. |
| [Third-party Mode Rail](../examples/11_third_party_component/README.md) | A reusable compound control with namespaced vendor roles, optional role fallbacks, per-instance overrides, and focus identity that survives an adaptive layout change. |
| [Composable Select parts](../examples/18_composable_select_parts/README.md) | A copyable userland Select split into trigger, overlay, rows, groups, virtual reveal, and text adapters. Semantic parity with the stock Select, grouped parents, type-ahead, modal input, and focus restoration. |
| [AliKit `icon_picker`](https://github.com/samanshaiza004/alicorn-kit) | An external complete component on the [`codex/issue-3-parts-pilot` branch](https://github.com/samanshaiza004/alicorn-kit/blob/codex/issue-3-parts-pilot/docs/research/issue-003-parts-pilot.md), with search, two appearances, a virtualized roving grid/list, semantic collection identity, and one application-authored interaction. |
| [Component recipes](recipes.md) | Compact, copyable excerpts from the Control Gallery. Useful building blocks, not a substitute for a complete component page. |
| [Pattern conformance checks](reference.md#pattern-conformance-checks-testui) | The `testui.pattern_check` API, part contract, and negative-control recipe. |

## Documentation template for component pages

Every component page uses this section order. A short component may combine
sections, but it must not omit one silently.

| Five-point standard | Document section |
| --- | --- |
| Complete, copyable implementation | **Copyable implementation** |
| Individually composable parts | **Parts and identities** |
| Custom styling and motion | **Styling, motion, and theme** |
| Keyboard and accessibility contracts | **Keyboard and accessibility contract** |
| `testui` conformance examples | **Conformance tests** |

```markdown
# <Component>

<One paragraph: what it is, when to use it, and when not to.>

## Responsibility split

<Table: Alicorn / package / application. State what the caller initializes,
destroys, and owns.>

## Copyable implementation

<File map and the smallest complete call site. Include setup, theme
registration, and teardown. The reader must be able to copy and run it.>

## Parts and identities

<Parts table. Stable keys and semantic IDs. What can be omitted or replaced.
What happens on removal, reorder, and duplicate identity.>

## Styling, motion, and theme

<Recipe and style fields. Namespaced roles. Setup-time validation. Per-instance
overrides. Motion targets, reduced motion, and idle behavior.>

## Keyboard and accessibility contract

<Key map. Focus owner and restoration. Disabled behavior. Semantic role, name,
value, states, and actions. Explicit non-claims.>

## Conformance tests

<Positive behavior tests. Pattern kinds used, or why none fits. Negative control
and expected failure step. Parity and identity tests. Idle settle.>

## Limits

<Headless versus native assistive technology. Unsupported keys. Known core
gaps. Performance notes.>

## Source map

<Links to package, example, tests, theme JSON, and pilot record.>
```

### Worked example: custom segmented control

This is the [segmented control
package](../examples/12_custom_segmented_control/segmented/segmented.odin)
rendered through the template.

#### Responsibility split

| Layer | Responsibility |
| --- | --- |
| Alicorn | Button hit testing, Tab focus, Space/Return activation, disabled behavior, Button semantics, layout, surfaces, visual parts, motion, and theme extension roles. |
| `segmented` package | Track and segment surfaces, responsive presentations, label and marker visuals, focus frame, semantic IDs and description, recipe/style, and the theme contract. |
| Application | Selected and disabled state, theme registration, optional per-instance accent, and lifecycle. |

#### Copyable implementation

Files: `segmented/segmented.odin`, `segmented/theme.json`,
`main.odin`, and `main_test.odin`. The component owns no destroyable resources;
the deferred theme-registration cleanup releases the registration result.

```odin
App :: struct {
	view:     segmented.Segmented_State,
	recipe:   segmented.Recipe,
	theme_id: alicorn.Style_Theme_ID,
}

app := App{
	view=segmented.Segmented_State{selected=.Edit},
	recipe=segmented.recipe_default(),
}

// In on_initialize, with the imports and THEME_PATH from main.odin:
registration := theme.theme_json_register(
	rt,
	string(segmented.DEFAULT_THEME_JSON),
	THEME_PATH,
)
defer theme.theme_json_register_result_destroy(&registration)
app.theme_id = registration.theme_id
contract := segmented.theme_contract_default(app.recipe)
report := segmented.theme_contract_check(rt, app.theme_id, contract)
_, missing_count := segmented.theme_contract_missing_required(contract, report)
if app.theme_id == 0 || missing_count > 0 {
	// The first return value (discarded here) names the missing roles.
	// Report them and show a visible error state; the full path is main.odin.
}

// In render:
_ = segmented.segmented_control(
	ctx,
	"Workspace view",
	&app.view,
	app.recipe,
	segmented.style_default(),
	key=ui.key_u64(10),
	instance_id=101,
)
```

#### Parts and identities

Each segment is an ordinary `button_begin(presentation=.Custom)` owner. The face,
label, hover accent, selection marker, and focus frame are visual parts attached
to that owner with `visual_part_attach`. The package binds each choice with a
stable ID:

```odin
_ = alicorn.semantic_bind(ctx, segmented.semantic_id(instance_id, choice))
```

The wide and compact presentations use different retained keys but the same
logical ID, so focus survives a resize. The selected value remains in
`Segmented_State`; the package returns whether an option was activated. The
visible parts are the track, one Button owner per choice, the focus frame, the
segment face, the label, and the selection marker. None of them is a second
widget tree.

#### Styling, motion, and theme

`Recipe` declares seven required extension-color roles. `Style` carries
geometry and an optional per-instance accent. The app validates the contract
once at initialization or theme replacement and stops rendering on a missing
required role.

```odin
style := segmented.style_default()
style.instance_accent_role = alicorn.style_extension_color_role_id(
	"app.example", "segmented_custom_accent",
)
style.track_radius = 30
style.marker_height = 7
style.label_size = 19
```

Selection changes the surface, label weight, and marker opacity/position, not
color alone. The marker animates through `ui.motion`; a new target interrupts
from the current presentation, reduced motion is honored, and a settled marker
returns the window to idle.

#### Keyboard and accessibility contract

- Each segment is a Button: Tab reaches it, Space and Return activate it, and
  pointer hit testing uses the public Button owner.
- Disabled choices are not activatable and publish the disabled state.
- The track publishes a `Group` with an accessible name, description, and value;
  each choice binds a stable semantic ID and a spoken description.
- The focus frame is attached with `.Owner_Focus_Visible`, so it appears for
  keyboard-visible focus without moving layout.
- Not claimed: radio-group arrow-key navigation. This is deliberately a Button
  group; a radio interaction contract would be a separate component decision.
- Headless tests do not prove a physical VoiceOver or Windows UIA session.

#### Conformance tests

The example tests drive the production initializer and renderer:

- parts stay inside the hit surface in both layouts;
- exposed corner radii follow both orientations;
- the theme contract and native Button semantics hold;
- keyboard activation and pointer hit testing update application state;
- logical focus survives responsive presentations;
- motion is interruptible and returns to idle;
- disabled state and larger text scale remain usable.

There is no `testui` pattern kind for a roving or radio-style group at this
revision. The component uses explicit drive assertions instead of claiming a
pattern that does not exist. A roving grid/list pattern is recorded as a core
candidate in the AliKit #3 pilot.

#### Limits

The package owns visible paint but not a new interaction model. It keeps Button
semantics, does not claim arrow-key radio behavior, and does not replace native
assistive-technology checks.

#### Source map

- [Package](../examples/12_custom_segmented_control/segmented/segmented.odin)
- [Theme JSON](../examples/12_custom_segmented_control/segmented/theme.json)
- [Example](../examples/12_custom_segmented_control/main.odin)
- [Tests](../examples/12_custom_segmented_control/main_test.odin)
- [Authoring notes](../examples/12_custom_segmented_control/README.md)

## Before calling a component done

Use this checklist in the component issue or its documentation page:

- [ ] A complete copy builds outside its own folder, with no private runtime
      access and no missing glue.
- [ ] Parts can be omitted, replaced, or recomposed; stable keys and semantic
      IDs survive reorder, removal, and appearance changes.
- [ ] Style and motion are recipe-driven, namespaced, setup-validated, and
      idle-settling; selection does not rely on color alone.
- [ ] The keyboard, focus, disabled, and semantic contracts are documented,
      including explicit non-claims.
- [ ] Positive and negative `testui` checks pass, semantic parity is recorded
      where a reference exists, and the idle assertion is present.
- [ ] The two-consumer rule was applied before extracting any shared helper.
- [ ] The component page follows the template and links to its source, tests,
      theme data, and exemplar.
