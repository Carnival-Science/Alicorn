package alicorn

// Experimental scene-local physical lighting above ordinary paint (issue #105).
//
// This is deliberately a paint-stream declaration, not retained widget or
// layout state. An application describes its ordinary surfaces with a shared
// Material_Group_ID, declares one light set for the frame, and the runtime
// emits a single Lighting_Group_Paint boundary at the painter-order position of
// the group's last painted command. A host compositor may then shade the group's
// rounded-slab surfaces and their cross-surface shadows.
//
// Contract:
// - Lighting changes pixels only. Bounds, clips, painter order, layout, hit
//   testing, focus, semantics, and input routing are untouched.
// - One boundary per frame. A frame that already emits a backdrop-effect
//   boundary keeps ordinary paint instead.
// - Text and icons inside the group are captured as ordinary paint. The
//   compositor modulates their luminance within a bounded range; it never
//   replaces their hue and never treats them as shadow casters.
// - No light declaration, or no non-flat surface carrying the declared group,
//   emits no marker and performs no compositor work.

LIGHTING_MAX_LIGHTS :: 4
// The prototype shader resolves a bounded surface set per group. A group with
// more qualifying surfaces keeps the remaining surfaces on ordinary paint.
LIGHTING_MAX_SURFACES :: 8
// Cross-surface shadows need a halo outside the surface union. This is a
// logical-pixel allowance at the group scale; the compositor snaps it outward
// in physical pixels before capture.
LIGHTING_SHADOW_MARGIN :: f32(24)

// Lighting_Light is a point light above the paint plane. Coordinates use the
// same logical space as surface bounds, so the light is a scene property and
// never a widget property.
Lighting_Light :: struct {
	position:  [2]f32,
	height:    f32,
	color:     Color,
	intensity: f32,
	// Source radius drives the soft penumbra. Zero is a hard shadow.
	radius:    f32,
}

LIGHTING_LIGHT_LIMIT_HEIGHT :: f32(1024)
LIGHTING_LIGHT_LIMIT_COORD :: f32(1_048_576)
LIGHTING_LIGHT_LIMIT_INTENSITY :: f32(8)
LIGHTING_LIGHT_LIMIT_RADIUS :: f32(64)

// Lighting_Group is the per-frame declaration. Lights are copied into the
// Runtime; the caller's slice is borrowed only for the call.
Lighting_Group :: struct {
	group:       Material_Group_ID,
	lights:      [LIGHTING_MAX_LIGHTS]Lighting_Light,
	light_count: int,
	ambient:     f32,
	shadows:     bool,
}

Lighting_Flag :: enum u8 {
	// Cross-surface shadows are evaluated at all.
	Shadows,
	// Source radius is ignored: penumbra collapses to the geometric edge.
	Hard_Shadows,
	// Accessibility variant: stronger bevel response and deeper shadow.
	High_Contrast,
}

Lighting_Flags :: bit_set[Lighting_Flag; u8]

// Lighting_Params is the renderer-facing resolved declaration. It is derived
// from the Runtime's published frame declaration plus the root accessibility
// appearance, so a host never has to reinterpret application input.
Lighting_Params :: struct {
	group:       Material_Group_ID,
	generation:  u64,
	lights:      [LIGHTING_MAX_LIGHTS]Lighting_Light,
	light_count: int,
	ambient:     f32,
	flags:       Lighting_Flags,
}

LIGHTING_AMBIENT_DEFAULT :: f32(0.35)
LIGHTING_AMBIENT_LIMIT :: f32(1)

lighting_light_is_valid :: proc(light: Lighting_Light) -> bool {
	if !number_is_finite(light.position[0]) || !number_is_finite(light.position[1]) ||
	   abs(light.position[0]) > LIGHTING_LIGHT_LIMIT_COORD ||
	   abs(light.position[1]) > LIGHTING_LIGHT_LIMIT_COORD { return false }
	if !number_is_finite(light.height) || light.height < 0 || light.height > LIGHTING_LIGHT_LIMIT_HEIGHT { return false }
	if !number_is_finite(light.intensity) || light.intensity < 0 || light.intensity > LIGHTING_LIGHT_LIMIT_INTENSITY { return false }
	if !number_is_finite(light.radius) || light.radius < 0 || light.radius > LIGHTING_LIGHT_LIMIT_RADIUS { return false }
	return semantic_surface_color_is_valid(light.color)
}

lighting_group_is_valid :: proc(group: Lighting_Group) -> bool {
	if group.group == MATERIAL_GROUP_NONE { return false }
	if group.light_count <= 0 || group.light_count > LIGHTING_MAX_LIGHTS { return false }
	if !number_is_finite(group.ambient) || group.ambient < 0 || group.ambient > LIGHTING_AMBIENT_LIMIT { return false }
	for index in 0..<group.light_count {
		if !lighting_light_is_valid(group.lights[index]) { return false }
	}
	return true
}

// lighting_group declares the frame's single lighting group. Call it inside an
// open frame, before end_frame, once per frame when lighting is wanted. The
// declaration is consumed by the next paint/composite pass and then discarded
// at the start of the following frame unless declared again.
lighting_group :: proc(
	ui: ^UI,
	group: Material_Group_ID,
	lights: []Lighting_Light,
	ambient := LIGHTING_AMBIENT_DEFAULT,
	shadows := true,
	loc := #caller_location,
) -> bool {
	if ui == nil || ui.runtime == nil { return false }
	rt := ui.runtime
	if !rt.frame_open { return false }
	declaration := Lighting_Group{group=group, ambient=ambient, shadows=shadows}
	count := min(len(lights), LIGHTING_MAX_LIGHTS)
	for index in 0..<count { declaration.lights[index] = lights[index] }
	declaration.light_count = count
	if len(lights) > LIGHTING_MAX_LIGHTS {
		append_diagnostic(rt, "lighting_group ignored lights beyond LIGHTING_MAX_LIGHTS")
	}
	if !lighting_group_is_valid(declaration) {
		append_diagnostic(rt, "lighting_group requires a non-zero material group, one to four finite point lights, and ambient in [0,1]")
		return false
	}
	rt.lighting_declared = true
	rt.lighting_declaration = declaration
	return true
}

@(private)
lighting_hash_f32 :: proc(hash: u64, value: f32) -> u64 {
	return hash_mix(hash, u64(transmute(u32)value))
}

@(private)
lighting_hash_color :: proc(hash: u64, color: Color) -> u64 {
	result := hash
	for value in ([4]f32{color.r, color.g, color.b, color.a}) {
		result = lighting_hash_f32(result, value)
	}
	return result
}

// lighting_presentation_flags resolves accessibility preferences into the
// compositor variant. Increased contrast strengthens the bevel response and
// removes penumbra; reduced transparency removes penumbra; reduced motion
// disables moving shadow cues entirely.
lighting_presentation_flags :: proc(preferences: Accessibility_Appearance_Preferences) -> Lighting_Flags {
	flags := Lighting_Flags{}
	if preferences.reduce_motion { return flags }
	if preferences.increased_contrast || preferences.reduce_transparency {
		flags += {.Hard_Shadows}
	}
	if preferences.increased_contrast {
		flags += {.High_Contrast}
	}
	return flags + {.Shadows}
}

// lighting_resolved_flags applies both the declared shadow switch and the
// accessibility variant. Marker publication and renderer resolution must use
// this exact function so their generations cannot diverge.
lighting_resolved_flags :: proc(
	declaration: Lighting_Group,
	preferences: Accessibility_Appearance_Preferences,
) -> Lighting_Flags {
	flags := lighting_presentation_flags(preferences)
	if !declaration.shadows { flags -= {.Shadows} }
	return flags
}

// lighting_group_hash covers the declared light parameters and their resolved
// accessibility presentation. It deliberately excludes wall-clock time and
// random state: replaying the same frame inputs reproduces the same generation.
lighting_declaration_hash :: proc(group: Lighting_Group, flags: Lighting_Flags) -> u64 {
	hash := u64(0x1C6967_6874696E) // issue #105 seed
	hash = hash_mix(hash, u64(u32(group.group)))
	hash = hash_mix(hash, u64(group.light_count))
	hash = hash_mix(hash, u64(group.shadows))
	hash = lighting_hash_f32(hash, group.ambient)
	for index in 0..<group.light_count {
		light := group.lights[index]
		hash = lighting_hash_f32(hash, light.position[0])
		hash = lighting_hash_f32(hash, light.position[1])
		hash = lighting_hash_f32(hash, light.height)
		hash = lighting_hash_color(hash, light.color)
		hash = lighting_hash_f32(hash, light.intensity)
		hash = lighting_hash_f32(hash, light.radius)
	}
	for flag in Lighting_Flag { hash = hash_mix(hash, u64(flags & {flag} != {})) }
	if hash == 0 { return 1 }
	return hash
}

// lighting_paint_params resolves the marker's declared parameters. A stale
// generation is rejected rather than reading the next frame's declaration.
lighting_paint_params :: proc(rt: ^Runtime, marker: Paint_Command) -> (params: Lighting_Params, ok: bool) {
	payload, is_lighting := marker.payload.(Lighting_Group_Paint)
	if !is_lighting || rt == nil || !rt.lighting_declared { return }
	if payload.group == MATERIAL_GROUP_NONE || payload.group != rt.lighting_declaration.group { return }
	flags := lighting_resolved_flags(rt.lighting_declaration, rt.root_accessibility_appearance)
	generation := lighting_declaration_hash(rt.lighting_declaration, flags)
	if payload.generation != generation { return }
	return Lighting_Params{
		group=rt.lighting_declaration.group,
		generation=generation,
		lights=rt.lighting_declaration.lights,
		light_count=rt.lighting_declaration.light_count,
		ambient=rt.lighting_declaration.ambient,
		flags=flags,
	}, true
}

// lighting_command_rect is the resolved logical rect a paint command draws
// into, including its presentation translation.
@(private)
lighting_command_rect :: proc(command: Paint_Command) -> Rect {
	return Rect{command.bounds.x+command.translation[0], command.bounds.y+command.translation[1], command.bounds.w, command.bounds.h}
}

@(private)
lighting_rect_union :: proc(a, b: Rect) -> Rect {
	left := min(a.x, b.x)
	top := min(a.y, b.y)
	right := max(a.x+a.w, b.x+b.w)
	bottom := max(a.y+a.h, b.y+b.h)
	return Rect{left, top, max(right-left, 0), max(bottom-top, 0)}
}

@(private)
lighting_owner_in_group :: proc(rt: ^Runtime, owner: Node_ID, members: []Node_ID) -> bool {
	id := owner
	for _ in 0..<64 {
		for member in members { if id == member { return true } }
		if id == 0 { return false }
		node, found := rt.nodes[id]
		if !found || node == nil || node.parent == 0 { return false }
		id = node.parent
	}
	return false
}

@(private)
lighting_display_remove_marker :: proc(commands: ^[dynamic]Paint_Command) {
	if commands == nil { return }
	for index := 0; index < len(commands^); {
		if paint_command_is_lighting_group(commands^[index]) {
			for move := index+1; move < len(commands^); move += 1 {
				commands^[move-1] = commands^[move]
			}
			resize(commands, len(commands^)-1)
			continue
		}
		index += 1
	}
}

@(private)
lighting_display_insert :: proc(commands: ^[dynamic]Paint_Command, index: int, command: Paint_Command) -> bool {
	if commands == nil || index < 0 || index > len(commands^) { return false }
	resize(commands, len(commands^)+1)
	for move := len(commands^)-1; move > index; move -= 1 {
		commands^[move] = commands^[move-1]
	}
	commands^[index] = command
	return true
}

// lighting_publish runs at the end of every reconciled paint stage. It removes
// any previous boundary and re-emits at most one marker for the current frame.
// With no declaration and no prior marker it is a single boolean test.
lighting_publish :: proc(rt: ^Runtime) {
	if rt == nil { return }
	if !rt.lighting_declared && !rt.lighting_marker_present { return }
	lighting_display_remove_marker(&rt.display_target)
	lighting_display_remove_marker(&rt.display)
	rt.lighting_marker_present = false
	rt.lighting_marker_index = -1
	if !rt.lighting_declared { return }
	rt.lighting_publishes += 1

	group := rt.lighting_declaration.group
	members: [LIGHTING_MAX_SURFACES]Node_ID
	member_count := 0
	region := Rect{}
	clip := rt.viewport
	first := true
	last_surface_index := -1
	for command, index in rt.display_target {
		// One effects boundary per frame keeps the narrow API contract
		// unambiguous; an existing backdrop boundary wins.
		if paint_command_is_backdrop_effect(command) { return }
		surface, is_surface := command.payload.(Surface_Paint)
		if !is_surface || surface.material_group != group || surface.physical_height == 0 { continue }
		rect := lighting_command_rect(command)
		if rect.w <= 0 || rect.h <= 0 { continue }
		if member_count < LIGHTING_MAX_SURFACES { members[member_count] = command.owner; member_count += 1 }
		region = rect if first else lighting_rect_union(region, rect)
		clip = rect_intersection(clip, command.clip)
		first = false
		last_surface_index = index
	}
	if member_count == 0 || last_surface_index < 0 || clip.w <= 0 || clip.h <= 0 { return }

	margin := LIGHTING_SHADOW_MARGIN
	region = Rect{region.x-margin, region.y-margin, region.w+2*margin, region.h+2*margin}
	clip = rect_intersection(clip, rt.viewport)
	if clip.w <= 0 || clip.h <= 0 { return }

	// Extend the boundary across the group's descendants so their text and
	// decoration are captured with the surfaces and shaded consistently.
	end := last_surface_index
	for index := last_surface_index+1; index < len(rt.display_target); index += 1 {
		if lighting_owner_in_group(rt, rt.display_target[index].owner, members[:member_count]) { end = index }
	}
	insert := end+1
	generation := lighting_declaration_hash(rt.lighting_declaration,
		lighting_resolved_flags(rt.lighting_declaration, rt.root_accessibility_appearance))
	marker := paint_lighting_group_command(LIGHTING_MARKER_OWNER, region, clip, group, generation)
	if !lighting_display_insert(&rt.display_target, insert, marker) { return }
	finalized := layout_finalize_paint_command(marker, rt.presentation_scale_x, rt.presentation_scale_y)
	if !lighting_display_insert(&rt.display, insert, finalized) {
		// Keep the two lists aligned even if the mirror insert fails.
		lighting_display_remove_marker(&rt.display_target)
		return
	}
	rt.lighting_marker_present = true
	rt.lighting_marker_index = insert
	rt.lighting_emits += 1
}
