# Issue #248: ordered composable visual effects

Research started November 27, 2026. The latest retained-paint integration is a research-branch prototype, not a shipping recommendation or a stable API. The current issue asks whether a surface can retain ordered effects without making flat scenes pay for unused effects or giving every widget a custom material implementation. [Alicorn #248](https://github.com/Carnival-Science/Alicorn/issues/248)

## Current finding

Alicorn already has useful surface ingredients, but they are separate typed features rather than an ordered stack on one surface. Directly composed surfaces remain the comparison baseline. A bounded issue-specific sidecar now stores inset fills and strokes on a retained owner, inserts the resulting commands into that owner's existing paint range, and resolves per-corner shape data by sparse synthetic paint-owner IDs. It does not add per-node payload or a renderer branch. The public effect-stack API remains NO-GO pending native output and broader consumer evidence.

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

### 2. Benchmark-only ordered-stack prototype (historical stage)

The first prototype in `benchmarks/native_material/effect_stack.odin` used a fixed-capacity descriptor list with two kinds: inset fill and stroke. It lowered each descriptor to an ordinary surface command and established exact CPU mesh parity. That stage had no Runtime sidecar or retained-pipeline integration. The later research-branch integration below now reuses the same descriptor types. The [record-size tripwire](https://github.com/Carnival-Science/Alicorn/blob/b30accd/runtime/size_tripwire_test.odin#L7-L26) remains unchanged at 2,048-byte Nodes and 128-byte `Paint_Command`s.

The geometry benchmark repeats each target shape 256 times and measures CPU mesh preparation at 1×, 1.25×, 1.5×, and 2×. It compares manually composed commands with commands lowered from the stack descriptors. For each shape/scale, both paths emit three surface commands and identical vertices; rounded mesh size and upload bytes are identical. The current solid renderer batches adjacent surface commands, so the prototype adds no effect-specific render pass. The geometry timings still exclude descriptor lowering, layout, retained-node count, persistent memory, GPU execution, and presentation.

Descriptor lowering is measured separately after warm-up with 101 samples of 100 lowerings per sample. On this Apple Silicon host, both fixtures reported 100 ns p50, 110 ns p95/p99, zero context allocator operations, and zero persistent runtime allocations after warm-up. These small timings are near the clock-resolution floor and should be read as an allocation check and upper-bound indication, not as evidence of a meaningful speedup.

Representative optimized run on the current development Mac:

| Target | Scale | Direct mesh p50/p95 | Stack-lowered mesh p50/p95 | Vertices / vertex bytes | Mesh equality |
| --- | ---: | ---: | ---: | ---: | --- |
| AliKit Menu popup | 1× | 4.57 / 4.90 ms | 4.58 / 4.98 ms | 497,664 / 17,915,904 B | Exact |
| AliKit Menu popup | 2× | 4.54 / 4.82 ms | 4.54 / 4.91 ms | 497,664 / 17,915,904 B | Exact |
| Punks Audition deck | 1× | 6.97 / 7.22 ms | 6.99 / 7.41 ms | 774,144 / 27,869,184 B | Exact |
| Punks Audition deck | 2× | 6.95 / 7.14 ms | 6.96 / 7.09 ms | 774,144 / 27,869,184 B | Exact |

These are geometry-only throughput figures for the 256-surface fixture, not application-frame timings. The near-identical values are expected: both forms lower to the same command sequence, and no stack-specific lowering cost is included. This prototype demonstrates that a bounded ordered representation can reuse today's flat/analytic surface renderer, but it demonstrates no rendering performance advantage. It also does not yet quantify the node/layout work saved by retaining multiple layers under one surface owner.

### Stage-one decision

- **Inset fill + layered stroke research:** GO to the next consumer pilot. The representation preserves command order and existing CPU mesh output without a renderer pass, but its visual value and retained-work savings remain unproven.
- **Analytic relief replacement or extension:** HOLD. The Punks fixture includes the current material as its base; no visual comparison or integrated-GPU measurement establishes that extra layers improve on relief.
- **Multi-stop gradients, shadows, and backdrop composition:** HOLD. The current experiment does not justify their cost or settle their interpolation, bounds, accessibility, or compositor contracts.
- **Public stack API:** NO-GO at this stage. The geometry prototype only encodes the current command stream and provides no reduction in paint commands or GPU work.

## Retained-owner benchmark-only experiment (historical stage)

The benchmark-only follow-up compared the same rounded surface, two ordered decoration layers, and unchanged text child in two forms: direct positioned surface children and a harness-owned sparse sidecar keyed by the retained surface owner. It ran 1, 100, 1,000, and 3,000 surfaces and checked the expanded paint stream. That experiment motivated the retained-paint integration below; its memory totals include a harness-owned expanded-output buffer and are not the current comparison.

The exact output from the successful optimized run is preserved in [the raw benchmark capture](issue-248-retained-effects-macos-2026-11-27.txt). Scaling observations from that run:

| Surfaces | Direct nodes | Sparse-owner nodes | Direct persistent bytes | Sparse-owner persistent bytes |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 5 | 3 | 459,458 B | 464,772 B |
| 100 | 401 | 201 | 3,749,341 B | 2,639,717 B |
| 1,000 | 4,001 | 2,001 | 30,606,401 B | 20,455,889 B |
| 3,000 | 12,001 | 6,001 | 95,599,729 B | 59,395,489 B |

At one surface, the sparse entry costs 5,314 B more than the two decorative retained nodes it replaces. In this fixture, the saved runtime storage outweighs that entry by 100 surfaces.

Representative single-run operation observations at 3,000 surfaces:

| Measure | Direct positioned children | Private sparse owner | Notes |
| --- | ---: | ---: | --- |
| Initial live nodes | 12,001 | 6,001 | Two decorative nodes removed per owner; root and text children remain. |
| Initial runtime persistent requested bytes | 95,599,729 B | 59,395,489 B | Runtime accounting, not process RSS; includes the sparse cache on the sidecar path. |
| Initial build + output-ready time | 84.83 ms | 60.56 ms | Sidecar timing includes lowering and expansion to the same 12,001 surface commands. |
| Identical re-description | 13.55 ms | 7.57 ms | Zero layout, text shaping, or paint visits in both runtimes. |
| Change one layer color | 13.38 ms | 7.34 ms | Direct path visits one paint node; sidecar lowers one entry and hits 2,999. |
| Change one layer inset | 18.36 ms | 7.24 ms | Direct path revisits its decoration layout/paint nodes; sidecar lowers one entry and hits 2,999. |
| Remove one layer | 23.25 ms | 7.47 ms | Direct path retires one decoration node; sidecar retains owner identity. |
| Add one layer | 23.46 ms | 8.40 ms | Direct path creates one decoration node; sidecar lowers one entry. |
| Resize one owner | 26.53 ms | 14.37 ms | In a flow column this also moves 1,500 following surfaces. |

The observations support further research: the private representation cut the fixture's live node count in half, reduced runtime-accounted persistent storage by about 38%, and produced equivalent expanded paint commands. It did not reduce the total number of output surface commands. The timing rows are one invocation each rather than distributions; use them as a directional baseline, not published comparative performance claims.

The resize case exposes a limitation in this prototype. Since the middle owner's height change moves the following 1,500 items, the sidecar's current key comparison treats their new absolute bounds as a reason to lower 1,500 entries again. A production design would need to separate owner-relative effect geometry from the owner's current bounds and translation. The sparse cache also stores per-owner command data; its memory is included above rather than treated as free.

The runtime's paint-visit and finalization counters do not see sidecar display-list expansion. The reported elapsed time does include that expansion, and output parity is checked, but there is no renderer/GPU readback. This is a benchmark model of retained ownership, not an Alicorn implementation or a complete renderer comparison.

### Consumer dogfood

The AliKit Menu now uses a positioned accent highlight in the popup's top padding. The Punks Audition deck uses a positioned accent rim in its panel's top padding. Both use existing surface and positioned-child APIs; both preserve the existing menu/deck owners and put no decorative node into flow layout. Regression assertions cover menu highlight identity/placement and Punks deck-child geometry and identity across its existing loading, seeking, resize, and text-scale scenarios.

These are code-level dogfoods, not validated native visual captures. AliKit's Menu check and Punks' Odin build/tests could not run in this environment: the pinned `accesskit:accesskit` checkout is absent, and Punks' Alicorn/Caliber submodules could not be cloned because `github.com` did not resolve. No native readback, physical DPI capture, or GPU cost was collected.

### Follow-up: positioned fill width and benchmark parity

The first visual review reproduced a real sizing-contract gap. A positioned child is measured at its authored/intrinsic size; `width=-1` is not a request to stretch it across its owner. Added the opt-in `Positioned_Width_Mode.Fill_Available` for positioned children and `ui.positioned_text`. It measures from the placement x offset to the owner's current content-box trailing edge, respects child min/max width, participates in retained layout invalidation, and leaves the existing `.Authored` default unchanged. The option uses the existing placement tag byte; the retained `Node` remains 2,032 bytes. The runtime regression verifies paint bounds and same-identity resize from a 200-unit owner to a 240-unit owner.

AliKit now opts its popup accent into fill mode, makes separator strokes grow across their row, sizes the stock trigger to its label when placed in a normal row, and resolves the default checkmark to the theme's text role. Its fractional-scale test checks the accent and separators against actual popup content bounds, trigger width, checkmark contrast, and stable accent identity. Punks opts the audition rim into the same fill mode; its existing width assertion now passes across the resize/loading scenarios.

The retained-owner benchmark now compares the entire ordered paint stream, including shaped text values, glyph and line data, surface payloads, resolved shapes, clips, and painter order. Runtime-local owner handles are ignored. The `semantic_surface_fill` animation marker is normalized because direct child surfaces carry the marker while sparse layers contain the already-resolved explicit fill. Motion timing now ends after `motion_tick` and presentation finalization on both paths; sparse display expansion and output parity run outside both timers. Cache comparison ignores owner placement, clip, opacity, and translation, and rebases cached layer bounds/clip at display construction. In the 3,000-surface resize scenario, sparse lowering dropped from reprocessing following owners to one changed owner (1 lowering, 2,999 cache hits).

The expanded sparse output buffer is allocated by the benchmark harness rather than the Runtime allocator, so the updated capture reports its capacity separately and adds it to the sidecar total: at 3,000 surfaces, 59,509,033 runtime-requested bytes plus a 2,304,000-byte output capacity equals 61,813,033 bytes, compared with 95,826,809 direct bytes. This is a 35.5% reduction including the external output buffer, with 12,001 to 6,001 retained nodes. It remains a synthetic one-process run; operation timings are single observations, not performance distributions or native GPU results. See [the follow-up raw capture](issue-248-retained-effects-macos-2026-11-27-followup.txt).

Validation on the development Mac: Alicorn runtime 532/532, UI 63/63, CPU renderer 25/25, AliKit Menu 7/7, and Punks 11/11 passed. The complete `tools/test.sh` progressed through foundation/runtime/font checks but stopped when Odin's SDL3 host test imported its missing `libwgpu_native.dylib`; that library is absent from the installed Homebrew Odin toolchain. TestUI's 57-test suite has three unrelated existing failures (history Page Down and two roving-grid assertions), reproduced unchanged at baseline `e2e88dc`. The AliKit Menu and Punks executables build against this checkout; Punks used its already-built Caliber dylib because that vendored Cargo crate is incomplete. Fresh native pixel captures and GPU readback remain unverified.

## Retained-paint integration prototype (research branch)

The next experiment moved the effect descriptor/cache into Alicorn's existing paint stage on `research/issue-248-retained-paint`. It remains issue-specific research code in `runtime/issue248_effects.odin`; no `ui` effect API or generalized effect framework was added. The setter only accepts an existing retained owner or one being described in the current frame. Effect state and the synthetic-command-owner map are created lazily when a consumer opts in. Ordinary flat scenes leave the sidecar nil. The retained `Node` remains 2,032 bytes and `Paint_Command` remains 128 bytes.

When an owner is painted, the runtime inserts its effect commands immediately after the first owned surface command and before the owner's later paint and descendants. The commands participate in the node's existing retained paint list, sparse display-range splice, clipping, opacity, presentation-output filtering, and shape resolution. Geometry is cached relative to the base surface size and shape; placement is read from the current command. Per-corner radii are retained in sparse metadata keyed by unique layer command owners. Removed owners stay mapped until their old display range is replaced, so count-changing layer removal cannot leave stale commands behind.

The direct-child and integrated paths were compared at 1, 100, 1,000, and 3,000 surfaces. Each fixture includes two ordered decoration layers and unchanged text. The harness compares the complete ordered output, including surfaces, resolved per-corner shapes, clips, text runs, painter order, transforms, and opacity. All four sizes passed exact output parity. Both paths emit the same number of display commands; the integration reduces layout nodes and retained storage rather than GPU command count.

| Surfaces | Direct nodes | Integrated nodes | Direct persistent bytes | Integrated persistent bytes |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 5 | 3 | 459,458 B | 464,020 B |
| 100 | 401 | 201 | 3,749,341 B | 2,619,253 B |
| 1,000 | 4,001 | 2,001 | 30,606,401 B | 20,292,065 B |
| 3,000 | 12,001 | 6,001 | 95,599,729 B | 57,888,177 B |

At 3,000 surfaces, the integrated path used 37,711,552 fewer runtime-requested persistent bytes (39.4%) while keeping all 12,001 display commands and exact output parity. This is runtime allocator accounting, not whole-process RSS. One surface still costs 4,562 more bytes because the sidecar has fixed/map overhead; the savings appear once enough owners share the mechanism.

For one middle owner in the 3,000-surface fixture, the stage counters show:

| Operation | Direct-child path | Integrated path |
| --- | --- | --- |
| Identical description | 12,001 reconcile visits; no measure, layout, shaping, paint, or finalization visits. | 6,001 reconcile visits; no measure, layout, shaping, paint, or finalization visits. |
| Change layer color | One decorative paint node, one command finalized. | One owner paint visit, one geometry-cache hit, three commands finalized; no measurement, layout, or text shaping. |
| Change layer inset | Two nodes measured, seven layout visits, two paint visits; full display finalization. | One geometry lowering and one owner paint visit; three commands finalized, with no measurement, layout, or text shaping. |
| Remove one layer | Retires one decoration node. | Replaces the owning paint range and preserves the owner. |
| Add one layer | Creates one decoration node. | Lowers one owner's geometry. |
| Resize the owner | 7,502 layout visits and 6,000 paint visits. | 4,502 layout visits, 3,000 paint visits, one geometry lowering and 1,499 geometry-cache hits. |

The executable emits elapsed nanoseconds for investigation, but each operation currently has a single observation. Those values are not reported as comparative performance results or distributions. The work counters provide the stronger result: changing an inset now updates only the owner's three paint commands without layout or shaping. The resize scenario is not viewport-bounded: changing the middle item's height moves following flow items, so normal layout and repaint work still scales with affected siblings.

Settled idle requested no new description in either path and recorded zero new layout visits or text-shape requests. Motion samples preserved exact output and produced no layout visits. No native GPU submission, readback, pixel comparison, process RSS, or physical DPI capture was performed.

Validation on this research branch: `odin test runtime` passed 535/535, including the retained-node size tripwire (`Node` 2,032 B; `Paint_Command` 128 B), and the optimized retained-effects benchmark completed all four sizes with exact ordered-output parity. The repository `sh tools/check.sh` passed its AccessKit ABI and smoke checks, then stopped in the Web UI package check: the installed Odin toolchain reports `core:os` unsupported for js/wasm and a missing `core:testing` logging symbol (`log.do_level_header`). The standalone `odin check runtime -target:js_wasm32 -no-entry-point` reaches the same toolchain errors. This leaves cross-target validation and all native GPU/pixel checks open.

The benchmark's `--issue248-retention-only` argument skips unrelated material benchmarks. Run `sh tools/bench_material.sh --issue248-retention-only`. The full command captures remain in `/tmp/alicorn-issue248-retention-final.txt` for this run; that temporary capture is not checked in.

The first integration run uncovered and fixed two correctness issues before this result was recorded: removed layer-owner metadata must survive until the old retained range is spliced, and the clipped-owner bounds guard must distinguish effect geometry from the owner's own bounds. Regression tests verify full display-command removal, color-only and inset-only paint locality, resize re-lowering, per-corner shape resolution, flat-path laziness, and owner retirement.

### Updated decision

- **Bounded inset-fill/layered-stroke research:** GO to visual and renderer validation. The sidecar pilot now demonstrates fewer retained nodes and lower runtime-requested memory for a 3,000-surface synthetic workload, with equivalent expanded CPU paint data.
- **Public stack API:** NO-GO. Consumer dogfood uses ordinary positioned surfaces, the comparison sidecar is benchmark-only, and native pixels/GPU costs are still unverified.
- **Flat fast path:** Preserve it. This experiment has no evidence that flat controls should pay effect-specific node, allocation, or pass costs.
- **Multi-stop gradients:** Keep independent. The retained-owner result neither proves nor rejects CPU tessellation versus shader evaluation.

Start with effects that can remain in ordinary surface rendering. Measure multi-stop gradients, multiple fills, layered strokes, and inset/outset treatments separately. Add shadow or backdrop passes only if a consumer shows a visible benefit over analytic relief or positioned surfaces. Preserve the flat fast path, painter order, clipping, opacity, and existing material presets.

## Required validation and decisions

- Read back equivalent native scenes on SDL_GPU and WebGPU at 1×, 1.25×, 1.5×, and 2× scale. Include transparent overlap, nested clips, resize, and painter order. Compare the changed surface against a fresh-runtime reference.
- Check High Contrast, Reduce Transparency, non-color cues, and text/focus visibility. Specify how gradients and translucent layers resolve before claiming accessibility parity.
- Compare direct composition and the prototype with the same content, build, viewport, theme, and interaction trace. Report CPU/GPU p95 and p99, pass count, upload size, live and peak memory, and settled idle. Include integrated GPU evidence before recommending expensive effects.
- Verify local effect edits preserve surface identity and avoid unrelated layout or text shaping. Static unchanged effects should reuse retained output; flat scenes must incur no effect pass or effect allocation.
- Make separate GO/NO-GO calls for each effect and for a public composition API. Do not infer that one successful effect justifies the entire stack.

The updated benchmark was built with `odin build benchmarks/native_material -o:speed` and its full executable run exited successfully. The raw capture includes the earlier CPU geometry runs, 101-sample descriptor-lowering checks, and retained-owner workloads at all four sizes. The earlier `odin test runtime` result was 531/531 and `odin test renderer/cpu` was 25/25 at the first prototype stage; production runtime files remain unchanged in this follow-up. Consumer Odin tests/builds, native pixels, GPU execution, and integrated-GPU behavior remain unverified for the reasons above. The earlier [two-stop gradient study](issue-119-two-stop-gradients.md) and [retained-effects study](../validation/issue-111-retained-effects.md) remain the detailed records for their respective implementation constraints.

## Sources inspected

- [Alicorn issue #248](https://github.com/Carnival-Science/Alicorn/issues/248), fetched November 27, 2026.
- Alicorn baseline `f071810`: `runtime/paint_types.odin`, `runtime/style_surface.odin`, `runtime/material.odin`, `native/sdl_gpu/effects_compositor.odin`, `native/sdl_gpu/retained_effects.odin`, `renderer/webgpu/backdrop_effects.odin`, `docs/research/issue-105-lighting.md`, and `docs/validation/issue-111-retained-effects.md`.
- AliKit baseline `baf2d0b`: `menu/menu.odin` and `menu/menu_test.odin`.
- Punks baseline `0296473`: `punks-standalone/odin/library_view.odin`, `appearance.odin`, and `library_view_test.odin`.
