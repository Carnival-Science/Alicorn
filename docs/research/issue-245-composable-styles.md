# Composable styles: recipe, fragments, and explicit contexts

Updated November 27, 2026 · External AliKit consumer and workload pilot complete.
Decision: **NO-GO for a public Alicorn style-composition API**; keep the
experiment in ordinary Odin and revisit only when another real consumer shows
that the added authoring model removes work.

This follows the [#244/#246 styling foundation](issue-244-246-styling-foundation.md)
and the current [#245 issue requirements](https://github.com/Carnival-Science/Alicorn/issues/245).

## Question and constraints

Can named typed recipes and reusable fragments make a control easier to restyle
in different contexts, while leaving application state, component identity,
input, layout ownership, and accessibility with the existing components?

The experiment excludes selector matching, string-based properties, a second
widget tree, and per-frame style lookup. Styling remains an authoring choice;
layout, typography, and paint continue to use Alicorn's typed values.

## Experiments

### Private Alicorn Button prototype

[`style_composition_prototype_test.odin`](../../runtime/style_composition_prototype_test.odin)
keeps the first prototype private. It composes typed Button fields through a
recipe inheritance chain, ordered fragments, explicit outer-to-inner
Toolbar/Dialog contexts, and an instance override. It reports the winning
source for each field and rejects duplicate identities, missing references,
cycles, and ambiguous context rules. A shared Button helper is used in the two
contexts, then each resolved paint recipe is adapted to an ordinary
`Style_Theme` snapshot.

This is evidence that deterministic typed resolution is possible with the
current theme contract. It is not a public runtime API. The adapter creates a
registered theme copy per context, and the prototype does not automatically
scope contexts through a subtree.

### External AliKit consumer

AliKit commit [`a482bbf`](https://github.com/samanshaiza004/alicorn-kit/commit/a482bbf3731fbe41512177392ab44be0db614439)
updates `examples/selection_styles` to compose a typed style in application
code. Named Odin procedures provide metric, surface, typography, and indicator
fragments. The caller passes an explicit `Toolbar` or `Dialog` context and can
apply a typed instance height override. `style_explain` returns a typed source
for each field.

The same resolved `Item_Style` feeds AliKit Radio Group and Segmented Control.
Their existing component owners continue to control focus, hit geometry,
selection, semantic roles, and controlled values. Styles are resolved at
initialization or when the selected treatment changes; the render procedure
does not resolve them per frame. No new Alicorn API or AliKit style registry is
used.

The external consumer test passed. It checks field provenance, instance
precedence, treatment paint and geometry, stable visual and semantic identity,
focus, keyboard/pointer/semantic activation, disabled behavior, and idle
descriptions.

## Measurements

Environment: macOS arm64, Odin `dev-2026-11:9a6991685`, Alicorn `dbd862a`,
and the pinned AccessKit binding. The optimized style-only microbenchmark uses
25 samples of 200 passes per size. The retained workload uses seven fresh
TestUI runtimes per size and creates that many styled Button nodes. It reports
initial description timings and deterministic stage visits; it has no GPU and
is not a native frame-latency measurement.

| Styled Buttons | Style resolver p50 per style | Initial description p50 | Max of 7 | Layout visits | Text shape requests | Paint visits | Settled idle |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| 100 | 1.00 ns | 0.551 ms | 7.769 ms | 203 | 100 | 102 | zero work |
| 1,000 | 1.01 ns | 5.485 ms | 6.733 ms | 2,003 | 1,000 | 1,002 | zero work |
| 3,000 | 0.98 ns | 17.492 ms | 21.145 ms | 6,003 | 3,000 | 3,002 | zero work |

The resolver-only values are below the precision needed to compare authoring
strategies and should be read as “small in this microbenchmark,” not as a
runtime performance claim. Runtime stage visits and text shaping scale with
the described scene. After settling, the idle check found no descriptions,
reconciliation, layout, shaping, paint, composition, or semantic work in the
TestUI counters. TestUI has no native GPU submission path, so this pilot says
nothing about GPU idleness. The resolver code contains no allocator, registry,
or string lookup, but the benchmark does not instrument allocator calls.

The runtime numbers have no matched direct-style baseline. Seven runs are also
too few for a stable p95; the table reports the maximum observed instead. No
native pixels, physical DPI behavior, high-contrast capture, or GPU work were
measured in this pilot.

## Validation

At Alicorn `dbd862a`, the runtime suite passed 531/531 tests and the retained
`Node` record measured 2,032 bytes, below its 2,048-byte budget. The AliKit
focused selection-style test passed 1/1 against that runtime and its pinned
AccessKit binding. The optimized `--bench` run completed for all three node
counts and reported zero measured post-settle TestUI work. These checks
establish headless behavior and the recorded CPU-pipeline workload only; they do not
replace the native Progress captures and DPI/accessibility checks still listed
below.

## Decision

The external consumer proves that the composition can work through ordinary
typed Odin functions, with an explicit context and local field explanations.
It does not prove that a generalized runtime API makes authoring clearer or
less repetitive. The previous `style_for` preset was a single typed switch;
the composition experiment adds provenance and benchmark code, and the complete
example grew from 195 to 479 lines. That full-file change is not a clean
authoring-only comparison, but it is enough to reject a claim that the current
generic resolver is already simpler.

Keep the demonstrated functions and component-specific style values in
userland. Do not extract the ID catalog, context registry, theme-snapshot
bridge, or field-patch system into Alicorn. Existing `Style_Environment`,
`Style_Theme`, and component-owned typed values remain the supported contract.
No stylesheet or style language is proposed.

## Remaining evidence

- A distinct AliKit component outside the selection-control family must show
  that the same composition convention removes meaningful duplication before
  shared package code is extracted.
- Compare identical authoring tasks with direct typed values and function
  composition, including source size and clarity; compare runtime allocations
  and frame costs against a matched baseline.
- Keep #244/#246's native Progress DPI, text-scale, contrast, and legacy-theme
  checks tracked in the foundation record.

These are research follow-ups, not prerequisites to use the existing typed
theme, layout, paint, and visual-part APIs.
