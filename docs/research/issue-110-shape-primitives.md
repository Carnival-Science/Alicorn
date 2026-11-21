# Issue #110: shape primitives and shape-aware input

**Status (2026-11-20):** accepted on the Windows D3D12 native backend. The bounded Circle/Arc/Cubic-Bezier prototype and example 14 ship in v0.2.2; [issue-110-shapes-windows-2026-11-20.md](../validation/issue-110-shapes-windows-2026-11-20.md) records four-scale pixel probes, clipping and translucent overlap, circular pointer pass-through, keyboard activation, rectangular accessibility bounds, and CPU/GPU stage costs. macOS Metal and Linux hardware runs remain unrecorded.

## Research and decision

Issue [#110](https://github.com/Carnival-Science/Alicorn/issues/110) asks for a small renderer-neutral visual vocabulary that lowers into Alicorn's existing retained paint stream, plus explicitly opted-in nonrectangular pointer targeting. It rules out a mandatory SDF renderer, a canvas or SVG editor, arbitrary shader graphs, and duplicating the backend comparison in [#104](https://github.com/Carnival-Science/Alicorn/issues/104).

PanGui's [September 2026 update](https://pangui.io/blog/07-progress-update-september/) describes both shape drawing and SVG meshes, and uses shapes in instrument-cluster gauges. That is useful evidence that compact controls and gauges benefit from richer geometry. Alicorn's narrower prototype keeps its single semantic/layout tree and uses its existing `Geometry_Paint` path as the escape hatch for arbitrary geometry.

The chosen prototype is **Circle, Arc, and Cubic Bezier**. Circles cover concentric knobs and meter endpoints; open arcs cover gauges; cubic Bezier strokes cover curved connections. There is no new widget kind or second display tree. Shape metadata is retained with the existing semantic-surface style, while paint commands continue to carry only compact shape identifiers and owner IDs.

## Implemented contract

- `surface_shape_circle`, `surface_shape_arc`, and `surface_shape_cubic_bezier` describe normalized geometry through the semantic-surface API.
- Circle surfaces support fill and stroke placement. Arcs and Beziers are open centered strokes; their fill is ignored. Curved shapes require flat material, no gradient, and no backdrop effect.
- The SDL_GPU renderer expands these shapes into the existing solid-surface batch. Tessellation is derived from pixel extent and capped at 96 segments, with a 16 segment minimum for visible curves and a transparent subpixel fringe. Rectangles keep their existing flat six-vertex route.
- `button_begin(pointer_hit_shape=.Circle)` optionally restricts pointer hits to the inscribed circle of that Button's bounds. The ordinary rectangle remains the default. Child hit testing, keyboard interaction, focus, and accessibility bounds retain their existing behavior.
- Theme roles resolve shape fills through the normal semantic-surface path. Core roles use Alicorn's contrast adaptations; extension-role palettes remain the component author's responsibility in increased-contrast mode. Reduced-transparency makes role-derived fills opaque. Explicit stroke colors retain their authored alpha. These primitives do not animate, so reduced-motion mode adds no shape work. Components should draw a theme-resolved focus cue.
- Clipping and source-over blending use the existing solid renderer and parent clip. Stroke and antialias outsets are included in visibility bounds. No additional texture, shader, render pass, or idle scheduler was added.

The [Shape Primitives example](../../examples/14_shape_primitives/README.md) demonstrates a concentric Gain control with circular pointer targeting, an output-meter arc, and a curved signal cable.

## Validation recorded

On macOS with Odin `dev-2026-11:9a6991685` and the repository-pinned AccessKit dependency:

- `odin check runtime -no-entry-point -collection:alicorn=.` — passed.
- `odin check native/sdl_gpu -no-entry-point` with the pinned `accesskit` and `accesskit_c` collections — passed. Odin emitted existing large-stack warnings from `secondary_window_host_test.odin`.
- Built `examples/14_shape_primitives` with the repository's AccessKit linker flags — passed; the linker reported a duplicate `-lobjc` warning.

These are compile checks, not GPU visual-readback or performance results. No automated tests were run for this prototype.

## Acceptance recorded (2026-11-20)

The Windows D3D12 run closes the rendering and interaction gate:

1. Circle fill/stroke, Arc stroke, and Cubic-Bezier stroke were sampled at 1×, 1.25×, 1.5×, and 2×, including a clipped circle, translucent overlap, and replay equality. The native probes and the existing 16-mask per-corner matrix all pass. A direct pixel A/B against a hand-written `Geometry_Paint` version was not recorded; the example and geometry measurements cover the production path.
2. Circular pointer targeting passes through square corners to an ordinary rectangular button underneath. Pointer capture follows the fall-through target, Enter activates the same Button, and the semantic snapshot retains the rectangular accessibility bounds.
3. Generated vertices/upload bytes, one draw slot and one pass per surface, CPU build/upload/encode/submit/fence distributions, and 64-control 64×64 worst-case tessellation are recorded. No scheduler/pass/texture was added. Integrated-GPU and binary-size isolation were not measured.
4. The `Geometry_Paint` comparison remains qualitative: shapes lower to the shared solid batch and keep the semantic/theme/hit contract, while `Geometry_Paint` requires application-owned triangles.

Residual hardware limits (macOS Metal, Linux, integrated GPU) are recorded in the validation record rather than treated as implementation gaps.
