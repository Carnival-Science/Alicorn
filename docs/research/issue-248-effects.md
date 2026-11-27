# Issue #248: ordered composable visual effects

Research started November 27, 2026. This is an initial renderer prototype and baseline, not a shipping recommendation. The current issue asks whether a surface can retain an ordered effect stack without making flat scenes pay for unused effects or giving every widget a custom material implementation. [Alicorn #248](https://github.com/Carnival-Science/Alicorn/issues/248)

## Current finding

Alicorn already has useful surface ingredients, but they are separate typed features rather than an ordered stack on one surface. Applications can compose several ordinary surfaces, but that is a distinct retained/paint workload and must be the comparison baseline before adding a renderer abstraction. A benchmark-only bounded prototype now lowers ordered inset fills and strokes into the existing `Surface_Paint` command path. It confirms command ordering and exact CPU mesh parity at four scales; it does not establish lower retained work, pixel output, or GPU performance. No public API is recommended yet.

## Existing paint and effect facilities

| Facility | Current contract | What it does not establish |
| --- | --- | --- |
| Surface paint | `Surface_Paint` holds one fill, one stroke, one shape, one `Material_ID`, and optical-height metadata. `Paint_Command` dispatches one payload at a time. | No ordered list of fills, strokes, highlights, or other effects on one surface. |
| Shape and stroke | Rectangles, rounded rectangles (including per-corner radii), circles, arcs, and other existing geometry are available. A stroke has one color and width, with centered/inside/outside placement. | Layered strokes or independently ordered inset/outset treatments. |
| Gradient | Semantic surfaces support one static two-stop linear gradient, horizontal or vertical. The current vertex interpolation requires equal stop alpha; the solid path adds no gradient mesh or pass. | Multi-stop, radial, or arbitrary-direction gradients. |
| Material | `MATERIAL_FLAT` is the zero-cost material path. The current analytic material supplies bevel width/strength and inner/outer shadow parameters; registration stores immutable setup-time values. High Contrast strengthens relief, and Reduce Transparency removes the material's translucent outer shadow. | Arbitrary ordered material layers or proof that a more expensive shadow path improves either consumer. |
| Backdrop | A semantic surface can request bounded Gaussian backdrop blur with a direct-render fallback. The native compositor currently handles one effect boundary per frame; a second boundary causes it to keep ordinary paint. WebGPU has a separate retained backdrop renderer. | General surface-local effect composition or nested/ordered boundaries. |

These boundaries are visible in the [paint payload and surface records](https://github.com/Carnival-Science/Alicorn/blob/b30accd/runtime/paint_types.odin#L10-L90), [shape kinds](https://github.com/Carnival-Science/Alicorn/blob/b30accd/runtime/paint_types.odin#L119-L183), [single stroke and gradient fields](https://github.com/Carnival-Science/Alicorn/blob/b30accd/runtime/paint_types.odin#L302-L356), [`Semantic_Surface_Style` and `surface_begin`](https://github.com/Carnival-Science/Alicorn/blob/b30accd/runtime/style_surface.odin#L18-L62), and the [material definition and flat path](https://github.com/Carnival-Science/Alicorn/blob/b30accd/runtime/material.odin#L3-L55). The [native compositor](https://github.com/Carnival-Science/Alicorn/blob/b30accd/native/sdl_gpu/effects_compositor.odin#L68-L111) explicitly declines a frame with a second effects boundary. The [WebGPU renderer](https://github.com/Carnival-Science/Alicorn/blob/b30accd/renderer/webgpu/backdrop_effects.odin#L29-L57) is specifically a backdrop-effect cache, not an effect-stack renderer.

`Lighting_Group_Paint` and its compositor are experimental work associated with [#105](https://github.com/Carnival-Science/Alicorn/blob/b30accd/docs/research/issue-105-lighting.md). That separate path is not evidence for a general stack, and this research does not extend or revive its lighting model. Existing backdrop lifetime and GPU constraints are documented in the [#111 retained-effects study](../validation/issue-111-retained-effects.md).

## Two consumer candidates

### AliKit Menu popup

AliKit's current Menu popup uses one rounded semantic surface with one role fill and one border stroke; keyboard-active rows are children of its focusable semantic owner. This is a useful consumer because fill, highlight, and inset-stroke treatments can be changed while preserving menu behavior, row identity, and focus ownership. [Popup surface construction at AliKit `0afd8ac`](https://github.com/samanshaiza004/alicorn-kit/blob/0afd8ac6f7134ba5084287c9d479596999f35d98/menu/menu.odin#L596-L616).

### Punks Audition deck

Punks' Audition deck is a better current target than its volume slider: the deck combines a waveform, transport controls, and volume row inside one rounded surface, using the app's registered mounted analytic material and a border. The slider remains application behavior and is not being replaced. A richer deck treatment can be evaluated without changing transport, slider identity, or focus. [Deck construction at Punks `ee08a52`](https://github.com/samanshaiza004/punks/blob/ee08a5288836325f311c3f36c12bcc7c5c1734cd/punks-standalone/odin/library_view.odin#L669-L690) · [mounted material registration](https://github.com/samanshaiza004/punks/blob/029647312c2b0a90a4b19c12093ddf8cbbd99368/punks-standalone/odin/appearance.odin#L10-L22).

These are consumer candidates, not completed application restyles or native captures. The second target focuses the deck surface rather than inventing a track/thumb styling seam that the current slider API does not provide.

## Experiment sequence

### 1. Direct-composition baseline

Use ordinary Odin and current public surfaces/materials to build a visually matched treatment for both consumers. For each, record the source changes, retained nodes, emitted paint commands, surface geometry, layout/shaping work, CPU preparation, GPU passes, uploads, and persistent/peak memory. Check that flat controls retain the current path and that a local appearance change does not reshape text or relayout unrelated content. This shows whether direct composition is already simple and cheap enough.

Compare these concrete candidates before adding filtering:

1. A solid fill plus a second accent fill or highlight.
2. An outside/inside stroke combined with the existing border.
3. Existing analytic relief versus manually composed inset/outset surfaces.
4. A multi-stop linear gradient versus the current two-stop gradient.

Treat visual advantage as a requirement. A new representation that merely packages the same ordinary surfaces does not earn renderer complexity.

### 2. Benchmark-only ordered-stack prototype

`benchmarks/native_material/effect_stack.odin` defines a private fixed-capacity descriptor list with only two initial kinds: inset fill and stroke. It lowers each descriptor to an ordinary surface command, preserving the existing paint union and native surface batch. The prototype is intentionally benchmark-only; it has no Runtime sidecar, per-node payload, public type, or production renderer branch. The [record-size tripwire](https://github.com/Carnival-Science/Alicorn/blob/b30accd/runtime/size_tripwire_test.odin#L7-L26) remains unchanged at 2,048-byte Nodes and 128-byte `Paint_Command`s.

The current benchmark repeats each target shape 256 times and measures CPU mesh preparation at 1×, 1.25×, 1.5×, and 2×. It compares manually composed commands with commands lowered from the stack descriptors. For each shape/scale, both paths emit three surface commands and identical vertices; rounded mesh size and upload bytes are identical. The current solid renderer batches adjacent surface commands, so the prototype adds no effect-specific render pass. The benchmark constructs the descriptor output before timing mesh preparation, so its timings do not measure descriptor lowering, layout, retained-node count, persistent memory, GPU execution, or presentation.

Representative optimized run on the current development Mac:

| Target | Scale | Direct mesh p50/p95 | Stack-lowered mesh p50/p95 | Vertices / vertex bytes | Mesh equality |
| --- | ---: | ---: | ---: | ---: | --- |
| AliKit Menu popup | 1× | 4.57 / 4.90 ms | 4.58 / 4.98 ms | 497,664 / 17,915,904 B | Exact |
| AliKit Menu popup | 2× | 4.54 / 4.82 ms | 4.54 / 4.91 ms | 497,664 / 17,915,904 B | Exact |
| Punks Audition deck | 1× | 6.97 / 7.22 ms | 6.99 / 7.41 ms | 774,144 / 27,869,184 B | Exact |
| Punks Audition deck | 2× | 6.95 / 7.14 ms | 6.96 / 7.09 ms | 774,144 / 27,869,184 B | Exact |

These are geometry-only throughput figures for the 256-surface fixture, not application-frame timings. The near-identical values are expected: both forms lower to the same command sequence, and no stack-specific lowering cost is included. This prototype demonstrates that a bounded ordered representation can reuse today's flat/analytic surface renderer, but it demonstrates no rendering performance advantage. It also does not yet quantify the node/layout work saved by retaining multiple layers under one surface owner.

### Initial decision

- **Inset fill + layered stroke research:** GO to the next consumer pilot. The representation preserves command order and existing CPU mesh output without a renderer pass, but its visual value and retained-work savings remain unproven.
- **Analytic relief replacement or extension:** HOLD. The Punks fixture includes the current material as its base; no visual comparison or integrated-GPU measurement establishes that extra layers improve on relief.
- **Multi-stop gradients, shadows, and backdrop composition:** HOLD. The current experiment does not justify their cost or settle their interpolation, bounds, accessibility, or compositor contracts.
- **Public stack API:** NO-GO for now. The benchmark prototype is only an encoding of the current command stream and has not removed layout nodes, paint commands, allocations, or GPU work.

The next prototype should attach bounded layers to one real retained surface owner, then compare it with the same consumer built from ordinary positioned surfaces. That comparison must include actual node/command counts, layout and shaping visits, allocation/memory, static reuse, and native pixel readback. Only proceed if it removes demonstrated consumer work while preserving painter order and the flat path.

Start with effects that can remain in ordinary surface rendering. Measure multi-stop gradients, multiple fills, layered strokes, and inset/outset treatments separately. Add shadow or backdrop passes only if a consumer shows a visible benefit over analytic relief or positioned surfaces. Preserve the flat fast path, painter order, clipping, opacity, and existing material presets.

## Required validation and decisions

- Read back equivalent native scenes on SDL_GPU and WebGPU at 1×, 1.25×, 1.5×, and 2× scale. Include transparent overlap, nested clips, resize, and painter order. Compare the changed surface against a fresh-runtime reference.
- Check High Contrast, Reduce Transparency, non-color cues, and text/focus visibility. Specify how gradients and translucent layers resolve before claiming accessibility parity.
- Compare direct composition and the prototype with the same content, build, viewport, theme, and interaction trace. Report CPU/GPU p95 and p99, pass count, upload size, live and peak memory, and settled idle. Include integrated GPU evidence before recommending expensive effects.
- Verify local effect edits preserve surface identity and avoid unrelated layout or text shaping. Static unchanged effects should reuse retained output; flat scenes must incur no effect pass or effect allocation.
- Make separate GO/NO-GO calls for each effect and for a public composition API. Do not infer that one successful effect justifies the entire stack.

This initial prototype was built and run locally with `odin build benchmarks/native_material -o:speed -out:out/alicorn_material_benchmark`; the benchmark exited successfully and the stack contract/mesh-equality checks passed. `odin test runtime` passed 531/531 tests and `odin test renderer/cpu` passed 25/25. The documented `./tools/test.sh` could not start because its AccessKit binding check tried to fetch `odin-accesskit` and this environment could not resolve `github.com`; no dependency was installed or changed. Neither consumer app was built, no pixels were captured, and native GPU execution/integrated-GPU behavior were not measured. The earlier [two-stop gradient study](issue-119-two-stop-gradients.md) and [retained-effects study](../validation/issue-111-retained-effects.md) remain the detailed records for their respective implementation constraints.

## Sources inspected

- [Alicorn issue #248](https://github.com/Carnival-Science/Alicorn/issues/248), fetched November 27, 2026.
- Alicorn `b30accd`: `runtime/paint_types.odin`, `runtime/style_surface.odin`, `runtime/material.odin`, `native/sdl_gpu/effects_compositor.odin`, `native/sdl_gpu/retained_effects.odin`, `renderer/webgpu/backdrop_effects.odin`, `docs/research/issue-105-lighting.md`, and `docs/validation/issue-111-retained-effects.md`.
- AliKit `0afd8ac`: `menu/menu.odin`.
- Punks `ee08a52` and `0296473`: `punks-standalone/odin/library_view.odin`, `appearance.odin`, and `library_view_test.odin`.
