# Styling foundation: typed properties and visual parts

November 22, 2026 · Initial research for [#244](https://github.com/Carnival-Science/Alicorn/issues/244) and [#246](https://github.com/Carnival-Science/Alicorn/issues/246).

Radio Group and Segmented Control already share selection policy in AliKit.
The experiment is whether ordinary Odin style values can change their anatomy
while the existing components keep ownership of input, layout boundaries,
keys, accessible names, and semantics. Begin with a pair of AliKit consumers
and the current Alicorn renderer. Keep the style values local to the pilot
until evidence supports a public vocabulary. [Styling roadmap](https://github.com/Carnival-Science/Alicorn/issues/243) · [Component standard](../component-authoring.md)

## What is already available

| Control or layer | Existing styling surface | Limit relevant to this study |
| --- | --- | --- |
| Button | Explicit layout and label typography, theme variants and state transforms, and a custom presentation path that keeps the Button owner. | Stock recipes expose predefined parts. A custom presentation authors its own geometry using public primitives. |
| Checkbox and Slider | Typed recipes for Checkbox box/checkmark/label/focus and Slider track/fill/thumb/label/focus, and separate logical sizing APIs. | These recipe families use typed Odin setup. The sparse theme JSON Button override contract does not expose equivalent authoring for them. |
| Text Field | Typed field/text/border/selection/caret/focus recipe, with an inset shared by shaping and input geometry. | Inset changes affect measurement and editing geometry. Moving a decorative surface cannot move caret hit testing or the IME anchor. |
| Scrollbar | Typed track/thumb/corner recipe. | The scroll region owns input and scroll metrics. Keyboard behavior and styling role changes are tracked separately in [#242](https://github.com/Carnival-Science/Alicorn/issues/242). |
| Public visual parts | `visual_part_attach` names an existing node or descendant with a core or namespaced ID. Supported owner-state visibility is resolved by the runtime. | A part ID identifies a node for paint and diagnostics. The procedure does not synthesize nodes or set layout, appearance, input, or semantics. A decorative node still needs the appropriate inert or decorative declaration. |
| AliKit Radio, Progress, Sidebar, Segmented, and Menu | Radio exposes option owners, optional default indicator and label; Progress and Sidebar expose component parts; Menu composes its trigger, popup and item parts. Segmented starts with a complete equal-width wrapper, a track, and an animated selected surface. | These are component-specific contracts. Radio already allows custom option contents. Segmented needs a way to replace item paint and omit its moving indicator without copying focus and selection logic. |

Sources: [Typed themes and control recipes](../themes.md#built-in-control-recipes) · [Visual-part attachment](../../runtime/visual_parts.odin) · [Custom Button presentation example](../../examples/12_custom_segmented_control/segmented/segmented.odin) · [AliKit component catalog at the #246 reference revision](https://github.com/samanshaiza004/alicorn-kit/blob/78a6df7/docs/components.md).

## Selection and appearance

AliKit's `selection.View` borrows stable value keys and enabled state, and
`selection.State` tracks the active key and index. Alicorn's roving helper
proposes focus movement. AliKit's shared procedures reconcile focus after
membership changes and produce the selected-key proposal in `Follow_Focus`
or `Activate` mode. The application accepts the proposed key and supplies the
controlled value on the next description. Style data has no role in that
decision. [Shared selection research](https://github.com/samanshaiza004/alicorn-kit/blob/78a6df7/docs/research/issue-005-selection-and-shared-behaviors.md) · [Selection source](https://github.com/samanshaiza004/alicorn-kit/blob/78a6df7/selection/selection.odin)

- **Radio Group.** Use its existing public group/item parts and provide the
  visual label and indicator inside the existing Button owner. Keep
  `Radio_Group`/`Radio_Button`, the component's accessible labels, and its
  keyboard, pointer and semantic `Press` behavior. [AliKit Radio Group](https://github.com/samanshaiza004/alicorn-kit/blob/78a6df7/docs/radio-group.md)
- **Segmented Control.** Add an optional item painter to the existing wrapper
  and allow it to omit the group selection surface. Keep the equal-width
  owner strip, shared selection behavior, and `Tab_List`/`Tab` roles for
  choosing views. Preserve the default path when no custom painter is
  supplied. [AliKit Segmented Control](https://github.com/samanshaiza004/alicorn-kit/blob/78a6df7/docs/segmented.md)

Name the component and its parts independently of the treatment. Use keyed
owners for items and fixed identities for each slot. Layout-bearing values
include the row/segment size, padding, gap, and label measurement. Optional
faces, marks, underlines, and focus outlines can be decorative children with
owner-local positioning. Appearance changes may resize the existing targets
through explicit layout inputs. A decorative transform only moves the
decoration. [Runtime layout and part types](../../runtime/runtime.odin) · [Positioned labels](../reference.md#positioned-labels)

The pilot compares Minimal, Hardware, and Paper treatments across the two
controls. It varies typography, geometry, and the selection marks and layered
surfaces supplied by each style. Selection needs a shape or mark in each
treatment, and the visible focus cue needs to distinguish roving focus from
the controlled selection in `Activate` mode.

## First prototype results

The AliKit pilot applies the same typed `Item_Style` to both controls.
Minimal uses compact flat faces and a short bar. Hardware uses inset relief
faces, heavier monospaced type, and a dot. Paper uses larger type, shallower
corners and an underline. Each mark is an optional paint child in a space
reserved by ordinary layout. Radio uses its existing public parts. Segmented
adds an opt-in drawing procedure inside the existing segment Button owner
and can omit its moving indicator when the replacement supplies a cue.
[Pilot source and instructions](https://github.com/samanshaiza004/alicorn-kit/tree/11b7d9a678cc399a59c4995db685caa07707ca30/examples/selection_styles)

One precedence detail matters for custom ink. A built-in `.Label` visual part
inherits text color from its Button owner's recipe. The pilot attaches a
namespaced label part instead to keep the explicit style color. The component
still supplies the option's semantic label. This distinction is covered by
checking the emitted text paint for all three treatments.
[Label color resolution](../../runtime/visual_parts.odin) · [Text paint emission](../../runtime/paint.odin)

- The headless pilot passed with AliKit's pin `47c9d4a` and Alicorn
  `113cccc4`. It checked retained owner identity, semantic identity and
  actions, focus continuity across treatment changes, resized bounds,
  material and text paint, keyboard disabled skipping, pointer and semantic
  selection, and no descriptions during a settled time advance.
- The existing Radio Group and Segmented Control suites passed 8 and 5
  tests respectively at the pin. An external copy of the pilot and its
  component sources built with local imports and the Alicorn collection.
- All three initial treatments passed macOS Metal startup smoke using
  SDL 3.4.20. This exercised startup and frame submission. Native pixel
  comparisons and physical input validation remain pending.
- The Alicorn `tools/test.sh` run stopped at its retained record size gate.
  Of 521 runtime tests, 520 passed. On the unmodified core at `113cccc4`,
  `Node` measured 2,096 bytes against its 2,048-byte limit.
  [Size tripwire](../../runtime/size_tripwire_test.odin)

## Scratchpad follow-up

Scratchpad's wide Settings sidebar now uses the same typed property and
named visual part approach on its category Buttons. Standard uses a bar,
Flat an underline, and Workbench Relief a dot on a raised face. The app's
existing Surface treatment preference chooses the presentation. Category
owners retain their names, focus and selection behavior across treatments.
The optical preference also keeps its existing logical target geometry.
[Scratchpad implementation and validation](https://github.com/samanshaiza004/scratchpad/blob/5d40e33a0e08131d1dfd09dea96191f9f995bb1f/docs/validation/settings-navigation-styles.md)

Scratchpad's Metal readback recorded all three treatments at 1×, 1.25×,
1.5× and 2× pixel density. The capture caught clipping from using uniform
padding for a horizontal label inset and an opaque fill covering focused
text. The final captures show each mark, intact labels and a separate
keyboard focus outline. They use a fixed logical viewport and text scale.
[DPI comparison](https://github.com/samanshaiza004/scratchpad/blob/5d40e33a0e08131d1dfd09dea96191f9f995bb1f/docs/validation/settings-navigation-styles/dpi-comparison.png)

| Change to the settled Settings scene | Layout visits | Shaping requests | Paint visits |
| --- | ---: | ---: | ---: |
| Idle or force the same description | 0 | 0 | 0 |
| Selected fill | 0 | 0 | 3 |
| Font size for four labels | 42 | 4 | 4 |
| Height for four rows | 42 | 0 | 21 |
| Selected material | 0 | 0 | 1 |
| Standard to Workbench Relief | 21 | 1 | 45 |

These counts match across densities on Scratchpad's Alicorn v0.2.3 pin
`28cc7f92`. Both fill and material still finalize 40 display commands.
Forced re-description of equal values visits reconciliation and allocates,
even though it schedules no layout, shaping or paint. The raw data includes
persistent and scratch allocation calls.
[28 measured samples](https://github.com/samanshaiza004/scratchpad/blob/5d40e33a0e08131d1dfd09dea96191f9f995bb1f/docs/validation/settings-navigation-styles/runtime-work.csv)

The fresh-runtime oracle exposed stale positioned decoration bounds after
in-place extent changes on the pin. A focus outline kept its old 44-unit
height after a 50-unit description, and the relief dot inherited the old
bar extent. Scratchpad now recreates each affected decoration when its
geometry changes. The exact comparison of navigation bounds, surface paint,
text ink and glyph placement then passed. The Button keys and named part
IDs stay stable. This result identifies a limit of reusing positioned visual
nodes on the tested revision.

### Positioned decoration extent follow-up

Reproducing the case against Alicorn master `4182ae1c` on 2026-11-23 confirmed
the stale bounds were a core measurement-cache bug, not a Scratchpad-only
limitation. Positioned children were measured with unconstrained dimensions,
so changing an authored surface width or height did not change the cached
measurement inputs. The layout pass ran but reused the previous extent.

Positioned children now use their authored width, height and min/max constraints
as measurement inputs. The same retained node updates its bounds and paint when
its extent changes; radius-only edits remain paint-only. Regression coverage
checks 44-to-50 height changes, bar-to-dot replacement, stroke clipping,
fresh-runtime parity, geometry edits during motion and fit-content measurement.
This is a core correctness fix, with no new styling API. It removes the need to
recommend key-changing as a workaround for extent changes.

The focused regressions passed 3/3. The full runtime suite passed 525/526; the
sole failure is the existing `Node` size tripwire (`2,096` bytes against a
`2,048`-byte budget), which also fails on untouched `4182ae1c`. The documented
`./tools/check.sh` could not fetch its pinned AccessKit dependency because
network DNS was unavailable. This follow-up has headless geometry coverage but
does not add native GPU pixel or DPI captures.

A Scratchpad theme switch also retained the focused category and selection
at 150% text scale with Increased Contrast, Differentiate Without Color and
Reduce Transparency. Named parts received the resolved ink on description.
The same-ID paint-only replacement case remains open for app-authored colors
copied into retained nodes, especially in keyed regions. The Node size-budget
failure remains separate. These results support continuing the pilot before
generalizing the API, with independent component anatomy such as Progress
still to validate. The styling language remains in wave 3.
[Appearance revision tracking in #232](https://github.com/Carnival-Science/Alicorn/issues/232)

## Typed properties and their effects

| Candidate | Existing application path | Expected work and precedence |
| --- | --- | --- |
| Width, height, bounds, padding, gap | `Layout_Style` and the components' typed options | A metric change may remeasure the affected layout and move hit and semantic bounds. A wider constraint can change wrapping. A consumer's explicit geometry takes precedence over a style fallback. A minimum target remains a separate logical constraint, not a decorative inset. |
| Font role, size, weight | `Font_Role` and `Text_Style` on the label | A typography change can reshape text and change intrinsic metrics. The component still owns the string and its accessible name. A configurable line-height field needs a distinct text/layout contract; the current `Text_Style` has no such field. |
| Fill, stroke, radius, valid material ID | Typed semantic surface fields and registered roles/materials | Paint and material changes should update the existing decoration while leaving the owning control's layout and text products intact. An added or removed layer changes the display list; if it takes layout space, classify that as a metric change. |
| Motion or decoration translation | Existing retained motion on the decoration | The owner's input and semantic geometry stay authoritative. Sample only while moving and honor reduced motion. |

Use existing component defaults for omitted fields. Resolve a style into existing
arguments before describing the parts. Keep explicit per-instance layout or
typography stronger than style defaults and preserve the built-in theme and
sparse JSON rules. Alicorn's current core control metrics treat a definite
height as an author override; a consumer that needs a target floor must keep
its own applicable minimum constraint. No new core theme resolution cache is
needed to start this experiment. [Control metrics and precedence](../themes.md#control-metrics) · [Existing dependency resolution](../../runtime/style_resolution.odin) · [Semantic surface contract](../../runtime/style_surface.odin)

## External references

- PanGui demonstrates a single toggle interaction with several authored
  visual shapes and state-dependent styling. Its stylesheet, SDF effects,
  and reported timings describe PanGui's own design. The Alicorn experiment
  asks which of those visual changes are expressible through today's public
  primitives. [PanGui styling article](https://www.pangui.io/blog/03-immediate-mode-styling/)
- Radix exposes the anatomy and state of its primitives so presentation can
  vary while the primitive handles interaction. The comparable Alicorn
  boundary is an explicit, keyed part and owner-state contract.
  [Radix styling guide](https://www.radix-ui.com/primitives/docs/guides/styling)
- W3C's radio pattern specifies selection, focus movement and semantic roles
  independently of appearance. It distinguishes normal radio navigation from
  toolbar navigation, so a shared single-selection helper need not imply
  identical policy or roles for every control.
  [WAI-ARIA radio group pattern](https://www.w3.org/WAI/ARIA/apg/patterns/radio/)

## Evidence required before extracting the API

1. Compare the same keyed options in all three appearances with the original
   wrappers. Drive pointer, keyboard, and semantic activation. Include
   disabled options, reorder and removal, follow-focus and explicit
   activation, and appearance switches while focused. Compare semantic IDs,
   names, states, actions, and the single focus stop. Give the external
   package and source-copy paths their own build checks.
2. Compare retained output after style edits with a fresh runtime built from
   the same values. Include fill-only and metric-only edits, decoration
   removal, a same-value edit, and a missing invalidation as a negative
   control. Inspect part identity and the affected metrics, typography,
   paint, and material work. Record whether diagnostics can point from the
   emitted visual back to the chosen style source.
3. Capture native pixels at multiple scale factors, with larger text and
   increased contrast. Confirm non-color selection cues, visible keyboard
   focus, clipping, and adequate logical hit targets. Measure description,
   layout, shaping, paint, allocations, and submissions after a change and
   at idle. Existing AliKit package and source-copy smoke results are a
   baseline, not evidence for the new treatments.
4. Compare the prototype's authored code and output with direct composition.
   Generalize only the fields or seams used in both controls. Before calling
   #244 complete, check built-in default and legacy-theme parity, intrinsic
   and virtualized layout, and one additional product use such as Scratchpad
   chrome or a Punks control. Leave the recipe-composition and styling
   language decisions until their requirements are evident.

Sources: [#106 fresh-runtime oracle](../validation/issue-106-invalidation-oracle.md) · [AliKit external consumer evidence](https://github.com/samanshaiza004/alicorn-kit/blob/fded57a94e6a2c5bf44d8b980befe5a260ff5ed5/docs/research/issue-006-phase-6-external-consumers.md) · [#245 recipe composition](https://github.com/Carnival-Science/Alicorn/issues/245).
