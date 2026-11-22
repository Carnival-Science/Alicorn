# Issue #105: optional scene-local lighting above paint

Status: experimental prototype on `codex/issue-105-lighting-research`. The
measured outcome is recorded in
[`docs/validation/issue-105-lighting-proto-2026-11-22.md`](../validation/issue-105-lighting-proto-2026-11-22.md).
This page documents the boundary and its contracts; it is not a v0.3.0 shipping
commitment.

## Question

Alicorn already resolves signed optical height (`physical_height`) and
explicit material groups on ordinary surfaces, and its analytic-relief
material dogfoods local bevels and a drop shadow in Scratchpad. Can a **small
opt-in 2.5D lighting compositor above the same paint stream** make a scene
meaningfully more expressive — for example a true cross-surface shadow — without
undermining the deterministic, low-cost flat UI?

The experiment copies the *method and contracts* of Rune's `rune-light`
(rounded-slab SDF, source-radius soft shadows, bevel normals) and none of its
scope: no GI, god rays, interreflection, PBR, user shaders, forced scene graph,
or animation engine.

## Boundary: `Lighting_Group_Paint`

Lighting is a **paint-stream boundary**, not a second UI tree and not retained
widget state. The runtime emits one marker command when, and only when, a frame
declares a lighting group and the composed display list contains at least one
non-flat (`physical_height != 0`) surface carrying that group:

```odin
Lighting_Group_Paint :: struct {
	group:      Material_Group_ID,
	generation: u64, // light parameters + resolved accessibility presentation
}
LIGHTING_MARKER_OWNER :: Node_ID(0xFFFF_FFFF_FFFF_FFFE)
```

The marker sits immediately after the last display command whose owner is a
group surface or one of its descendants. Everything painted before that point —
the group's surfaces, their text, icons, and strokes, plus the ordinary paint
behind them — is available to the host compositor. Everything painted after it
(later siblings, overlays, tooltips, drag previews) stays above lighting.

Rules:

- **One effects boundary per frame.** A frame that already emits a
  backdrop-effect boundary keeps ordinary paint and emits no lighting marker.
- **Pixels only.** Lighting never changes bounds, clips, painter order, layout,
  hit testing, focus, semantics, or input routing. The marker is owned by a
  reserved identity that cannot collide with a real node.
- **Bounded surface set.** At most `LIGHTING_MAX_SURFACES` (8) group surfaces are
  shaded per boundary. Additional qualifying surfaces stay on ordinary paint.
- **Bounded light set.** At most `LIGHTING_MAX_LIGHTS` (4) point lights.
- Text is never a shadow caster: only the declared rounded slabs occlude.

## Application API

The declaration is per frame and experimental:

```odin
lights := [1]alicorn.Lighting_Light{{
	position = {120, 80},  // same logical space as surface bounds
	height   = 4.5,        // optical units above the paint plane
	color    = {1, 0.94, 0.84, 1},
	intensity= 1.8,
	radius   = 18,         // source radius -> soft penumbra, logical px
}}
// Inside an open frame, once per frame when lighting is wanted:
alicorn.lighting_group(&ui, group_id, lights[:], ambient=0.48, shadows=true)
```

Surface membership is existing retained state: describe the surfaces with
`material_group=group_id` and a signed `physical_height` in `[-2, 2]`.

The declaration is consumed by the next paint/composite pass and discarded at
the start of the following application description. Hosts resolve the resolved
parameters from the marker, never from application input:

```odin
params, ok := alicorn.lighting_paint_params(rt, marker)
```

`params.flags` is the accessibility presentation variant described below.
`alicorn.lighting_presentation_flags` and `alicorn.lighting_resolved_flags`
exist so tools and tests can predict the same variant.

## Composition (native SDL_GPU prototype)

The host reuses the retained-effects slot, budget, and fence machinery that
already serves backdrop blur, with a second plan kind:

1. **Plan.** The marker region is the union of the group's surface rects
   expanded by `LIGHTING_SHADOW_MARGIN` (24 logical px), intersected with the
   marker clip. The capture is snapped outward to whole physical pixels and
   bounded by the existing 2048 px / 48 MiB policy.
2. **Capture.** Cleared to the opaque effect-prefix color, the painted prefix
   is drawn into one RGBA8 source texture, translated by the capture origin.
   The text mesh is primed for the cropped prefix first so captured glyphs are
   never one frame behind the command list that produced them.
3. **Encode.** Nothing is filtered. The plan generation is the existing prefix
   content hash mixed with the marker's parameter generation, so identical
   content and lights hit the cached slot; a moved light or changed pixel
   re-captures.
4. **Composite.** One full-region textured quad at the marker's painter-order
   position, scissored to the output clip, blending disabled (the shader writes
   every covered pixel exactly once).

Per pixel the fragment program:

- evaluates the rounded-rect signed distance of every surface in the group
  directly (no height buffer);
- selects the covering surface with the greatest signed height;
- derives a bevel normal from the SDF gradient over the physical bevel width;
- accumulates every declared point light with a soft studio falloff;
- occludes each light by ray-marching the 2D segment toward it against the other
  raised slabs, softened by the light's source radius (penumbra);
- adds direction-independent contact occlusion near raised neighbours;
- multiplies the captured albedo by a bounded luminance modulation
  (`[0.5, 1.4]` inside surfaces), so captured text and icons keep their hue and
  their contrast stays legible.

The captured prefix must be treated as premultiplied SDR paint, like the blur
path; lighting is not a linear-light pipeline.

Uniform block: `Lighting_GPU_Uniforms` in `renderer/cpu/lighting.odin` (416
bytes, float4 rows). Fragment uniforms use SDL_GPU's `b0 space3 / set 3`,
fragment samplers `t0 space2 / set 2`. Shaders live in
`native/sdl_gpu/lighting_shaders/` (HLSL, GLSL, MSL sources; pinned DXC/glslang
DXIL and SPIR-V artifacts) and are rebuilt with
`tools/build_lighting_shaders.ps1` (`-Verify` checks the manifest hashes).

## Accessibility

`lighting_resolved_flags` derives the variant from the root appearance
preferences, matching the existing `style_material_accessibility_variant`
semantics:

| Preference | Behaviour |
| --- | --- |
| default | shadows on, soft penumbra, normal bevel response |
| `increased_contrast` | hard shadows (source radius collapsed), stronger bevel response |
| `reduce_transparency` | hard shadows; no translucent penumbra |
| `reduce_motion` | all shadow cues disabled (no moving shadow) |

The flags participate in the marker generation, so changing a preference
invalidates the cached composite exactly like a light movement.

## Determinism

Everything the compositor evaluates is a pure function of:

- the captured prefix (hashed by the existing content-generation walk),
- the group's resolved surface rects, radii, and signed heights,
- the declared lights, ambient, shadow switch, and accessibility flags,
- the capture origin, scale, and pixel snapping.

There is no wall clock, random source, history, or frame counter in the path.
The same frame inputs produce the same generation, uniforms, and pixels. Light
animation is application-owned: an app that moves a light must request a frame
itself.

## Cost shape

- One RGBA8 source target plus the shared vertex/transfer pair: about 420 KiB at
  1x for the probe scene, 1.43 MiB at 2x. There is no half-float filter
  ping-pong, so a same-size blur would charge roughly four times the texture
  bytes.
- Per frame with a live light: capture clear + prefix draw + composite (three
  effect passes) and one extra prefix draw's worth of geometry.
- At rest with an unchanged generation: capture and encode are skipped; only
  the composite runs. A static scene submits nothing at all because the host
  only draws on invalidation.
- Unused: with no declaration or no qualifying surface the runtime emits no
  marker, allocates no effect resources, and performs no effect passes. With no
  prior marker, `lighting_publish` is one boolean test.

## Limitations

- Shading applies only inside the captured region; a long cast shadow can be cut
  at the region's shadow margin. The prototype places the light so the shadow
  lands inside the group.
- Overlapping group surfaces resolve by greatest signed height, not by painter
  order among equal heights; there is no height buffer.
- Per-corner radii collapse to their maximum for the analytic slab.
- Shadows use a bounded 12-step occlusion ray and a per-light, per-surface
  loop; four lights is the tested maximum.
- The lighting shader path exists only in the SDL_GPU reference host. The
  WebGPU hosted presenter and browser host still paint the group without
  lighting (the marker is an unknown payload there and is skipped by ordinary
  paint dispatch).

## Reproduction

```powershell
.\tools\validate_effects.ps1
```

The fixture writes `out/lighting/*.ppm` plus the comparison PNGs used by the
validation record, and prints the determinism, idle, accessibility, and cost
lines consumed by the record.
