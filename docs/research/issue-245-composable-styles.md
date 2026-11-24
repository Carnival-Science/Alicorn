# Composable styles: recipe, fragments, and explicit contexts

November 24, 2026 · Private Button prototype; public runtime API is **NO-GO**
pending a second consumer and authoring/performance evidence. See the
[styling foundation record](issue-244-246-styling-foundation.md) for the
preceding #232, #244, and #246 validation.

## Design boundary

The useful target is typed composition, not a runtime stylesheet. An
application should be able to define a reusable recipe, extend it with
fragments, apply a named context to a subtree, and inspect the source of each
resolved field. The runtime should not match selectors, parse strings during
description, or create a second component tree.

The prototype uses distinct numeric IDs for recipes, fragments, and contexts.
Its Button patch has a fixed field enum and typed value struct for a small
cross-domain set: height and padding (`Layout_Style`), font size
(`Text_Style`), and shape, color roles, surface visibility, selection marker,
and focus policy (`Button_Recipe`). A fragment cannot contain an untyped
property bag or assign a value with the wrong field type.

## Deterministic precedence

The experiment resolves one recipe at setup time, in this order:

1. Alicorn defaults and the selected typed theme variant.
2. Recipe inheritance from the oldest parent to the leaf. Each recipe applies
   its fragments in declaration order, then its own direct patch.
3. Explicit context IDs in caller-provided outer-to-inner order. A context rule
   targets one exact recipe ID; it does not inspect widget structure or match
   a selector.
4. Explicit instance patch.

The result retains a provenance source for every field: core default, theme
variant, recipe ID, fragment ID, context ID plus fragment ID, or instance
override. Setup rejects duplicate IDs, missing references, inheritance
cycles, duplicate context rules for one recipe, and repeated active context
IDs. Runtime description uses only the already-resolved typed values.

## Prototype and evidence

[`style_composition_prototype_test.odin`](../../runtime/style_composition_prototype_test.odin)
contains the private setup compiler and its regression test. It deliberately
does not export a runtime type or procedure. The test composes a shared
Control → Compact → Primary recipe chain, resolves it in Toolbar and Dialog
contexts, checks nested outer-to-inner precedence and per-field provenance,
and verifies that an instance override wins. It also rejects an identity
collision, cyclic inheritance, and an ambiguous context rule.

For an integration check, the test materializes each resolved Button recipe
into an ordinary `Style_Theme`, registers those snapshots once, then calls the
same Button helper in both contexts with the resolved layout and text values.
The retained Button geometry and paint differ as requested while both remain
ordinary Button nodes with the same label. The current bridge therefore works,
but each context requires its own registered theme snapshot and callers still
pass layout and typography explicitly. There is no public context scope or
runtime provenance inspector for these composed values.

The focused Windows test passes. The prototype is bounded to 64 definitions
and checks catalogs during setup; it has no 100/1,000/3,000-node workload
benchmark, native pixel comparison, or consumer outside this one Alicorn
test fixture. AliKit Progress currently validates typed part composition and
semantic preservation, but it does not consume the same recipe fragments or
context contract. Progress-specific range and animation options also remain
appropriately owned by that component.

## API decision

Do not extract the prototype as a public runtime API yet. The evidence shows
that typed composition can resolve correctly and adapt to the current theme
contract. It does not yet show that the API reduces real application code, how
contexts should reach retained Button resolution without one theme copy per
context, or how composition scales under the #245 workload.

The next GO review should require:

- A second package consuming the same recipes, fragments, and explicit
  contexts, with a copyable example and a measured reduction in repeated style
  declarations. The consumer must be an actual AliKit component using the
  same composition definitions, not only a consumer of Alicorn's current
  theme or visual-part APIs.
- A context integration that keeps interaction, layout boundaries, component
  identity, and focus semantics owned by the existing controls.
- Unchanged built-in and legacy-theme defaults, fresh-runtime parity, and
  deterministic interaction/accessibility state conflicts and theme
  replacement.
- Benchmarks at 100, 1,000, and 3,000 retained nodes, plus evidence of no
  per-frame string lookup, allocation, or work during settled idle.
- A public explain/provenance result that identifies the winning source for a
  field and a reject-then-preserve behavior for invalid catalogs.
- Fresh-runtime parity for layout, text, paint, and material values, along
  with native visual checks for focus and high-contrast states.

This keeps the research moving without committing Alicorn to a property bag,
selector engine, or generalized style framework before a second consumer
shows which composition seams are genuinely shared.

Source: [Alicorn #245](https://github.com/Carnival-Science/Alicorn/issues/245).
