package alicorn

// This file is a research-only retained-paint integration for issue #248.
// It deliberately lives below ui and is not a stable effect-stack contract.

ISSUE248_SURFACE_EFFECT_MAX_LAYERS :: 4

Issue248_Surface_Effect_Kind :: enum u8 {
	Inset_Fill,
	Stroke,
}

Issue248_Surface_Effect_Layer :: struct {
	kind: Issue248_Surface_Effect_Kind,
	inset: f32,
	color: Color,
	stroke_fill: Color,
	stroke: Paint_Stroke,
	stroke_placement: Paint_Stroke_Placement,
}

Issue248_Surface_Effect_Stack :: struct {
	count: u8,
	layers: [ISSUE248_SURFACE_EFFECT_MAX_LAYERS]Issue248_Surface_Effect_Layer,
}

Issue248_Surface_Effect_Stats :: struct {
	geometry_lowerings: u64,
	geometry_cache_hits: u64,
	paint_rebuilds: u64,
	unsupported_owners: u64,
	pending_descriptions_examined: u64,
}

Issue248_Surface_Effect_Geometry :: struct {
	bounds: Rect,
	shape: Surface_Shape,
}

Issue248_Surface_Effect_Entry :: struct {
	stack: Issue248_Surface_Effect_Stack,
	layer_owners: [ISSUE248_SURFACE_EFFECT_MAX_LAYERS]Node_ID,
	layer_geometry: [ISSUE248_SURFACE_EFFECT_MAX_LAYERS]Issue248_Surface_Effect_Geometry,
	geometry_valid: bool,
	geometry_stack: Issue248_Surface_Effect_Stack,
	base_width: f32,
	base_height: f32,
	base_shape: Surface_Shape,
	cleanup_pending: bool,
}

Issue248_Surface_Effect_Command_Owner :: struct {
	owner: Node_ID,
	layer_index: u8,
}

Issue248_Surface_Effect_State :: struct {
	entries: map[Node_ID]Issue248_Surface_Effect_Entry,
	command_owners: map[Node_ID]Issue248_Surface_Effect_Command_Owner,
	cleanup_owners: [dynamic]Node_ID,
	next_command_owner: u64,
	stats: Issue248_Surface_Effect_Stats,
}

issue248_surface_effect_state :: proc(rt: ^Runtime, create: bool = false) -> ^Issue248_Surface_Effect_State {
	if rt == nil { return nil }
	if rt.issue248_surface_effects != nil { return rt.issue248_surface_effects }
	if !create { return nil }
	state := new(Issue248_Surface_Effect_State, allocator=rt.persistent_allocator)
	state.entries = make(map[Node_ID]Issue248_Surface_Effect_Entry, allocator=rt.persistent_allocator)
	state.command_owners = make(map[Node_ID]Issue248_Surface_Effect_Command_Owner, allocator=rt.persistent_allocator)
	state.cleanup_owners = make([dynamic]Node_ID, 0, allocator=rt.persistent_allocator)
	state.next_command_owner = 0xFFFF_FFFF_FFFF_FFFD
	rt.issue248_surface_effects = state
	return state
}

issue248_surface_effect_stack_is_valid :: proc(stack: Issue248_Surface_Effect_Stack) -> bool {
	if stack.count > ISSUE248_SURFACE_EFFECT_MAX_LAYERS { return false }
	for index in 0..<int(stack.count) {
		layer := stack.layers[index]
		if !number_is_finite(layer.inset) || layer.inset < 0 { return false }
		switch layer.kind {
		case .Inset_Fill:
			if !semantic_surface_color_is_valid(layer.color) { return false }
		case .Stroke:
			if !semantic_surface_color_is_valid(layer.stroke_fill) ||
			   !semantic_surface_color_is_valid(layer.stroke.color) ||
			   !number_is_finite(layer.stroke.width) || layer.stroke.width <= 0 || layer.stroke.width > 4096 ||
			   layer.stroke_placement < .Centered || layer.stroke_placement >= .Count {
				return false
			}
		}
	}
	return true
}

issue248_surface_effect_stack_equal :: proc(a, b: Issue248_Surface_Effect_Stack) -> bool {
	if a.count != b.count { return false }
	for index in 0..<int(a.count) {
		if a.layers[index] != b.layers[index] { return false }
	}
	return true
}

issue248_surface_effect_owner_is_described :: proc(rt: ^Runtime, owner: Node_ID) -> (described: bool, examined: u64) {
	if rt == nil || owner == 0 { return }
	if node, found := rt.nodes[owner]; found && node != nil && node.active { return true, 0 }
	// New owners must declare effects immediately after their description. This
	// keeps initial construction O(1) per owner and avoids scanning the pending
	// tree for an ID that has not entered the retained-node map yet.
	if len(rt.pending) == 0 { return false, 0 }
	examined = 1
	item := rt.pending[len(rt.pending)-1]
	return item.kind == .Description && item.description.id == owner, examined
}

// issue248_surface_effect_stack_set is an issue-specific runtime research hook
// used by the benchmark and dogfood consumers. It is intentionally absent
// from ui and carries no stable API compatibility promise.
// The owner must be an existing retained node or the most recently described
// item in the currently open frame. A zero-layer stack removes a declaration.
issue248_surface_effect_stack_set :: proc(
	rt: ^Runtime,
	owner: Node_ID,
	stack: Issue248_Surface_Effect_Stack,
) -> bool {
	if rt == nil || owner == 0 || !issue248_surface_effect_stack_is_valid(stack) { return false }
	described, examined := issue248_surface_effect_owner_is_described(rt, owner)
	if !described { return false }
	state := issue248_surface_effect_state(rt, stack.count > 0)
	if state == nil { return true }
	state.stats.pending_descriptions_examined += examined
	previous, found := state.entries[owner]
	previous_count := previous.stack.count
	if stack.count == 0 {
		if !found || previous.stack.count == 0 { return true }
		previous.stack = {}
		state.entries[owner] = previous
	} else {
		if found && issue248_surface_effect_stack_equal(previous.stack, stack) { return true }
		previous.stack = stack
		state.entries[owner] = previous
	}
	if found && previous_count > stack.count && !previous.cleanup_pending {
		previous.cleanup_pending = true
		state.entries[owner] = previous
		append(&state.cleanup_owners, owner)
	}
	if node, found := rt.nodes[owner]; found && node != nil && node.active {
		dirty_set(&node.dirty, .Paint, true)
		dirty_set(&node.dirty, .Composite, true)
		queue_paint(rt, owner)
		request_presentation_for_node(rt, owner, "issue 248 surface effects changed")
	}
	return true
}

issue248_surface_effect_stats :: proc(rt: ^Runtime) -> Issue248_Surface_Effect_Stats {
	if state := issue248_surface_effect_state(rt); state != nil { return state.stats }
	return {}
}

issue248_surface_effect_stats_reset :: proc(rt: ^Runtime) {
	if state := issue248_surface_effect_state(rt); state != nil { state.stats = {} }
}

issue248_surface_effect_command_parent :: proc(rt: ^Runtime, command_owner: Node_ID) -> Node_ID {
	if rt == nil || command_owner == 0 { return 0 }
	state := issue248_surface_effect_state(rt)
	if state == nil { return 0 }
	if metadata, found := state.command_owners[command_owner]; found { return metadata.owner }
	return 0
}

issue248_surface_effect_command_belongs_to :: proc(rt: ^Runtime, command_owner, node_owner: Node_ID) -> bool {
	if command_owner == node_owner { return true }
	return issue248_surface_effect_command_parent(rt, command_owner) == node_owner
}

issue248_surface_effect_command_shape :: proc(rt: ^Runtime, command_owner: Node_ID, compact: Surface_Paint_Shape) -> (shape: Surface_Shape, ok: bool) {
	state := issue248_surface_effect_state(rt)
	if state == nil { return }
	metadata, found := state.command_owners[command_owner]
	if !found { return }
	entry, entry_found := state.entries[metadata.owner]
	if !entry_found || !entry.geometry_valid || metadata.layer_index >= entry.stack.count { return }
	shape = entry.layer_geometry[metadata.layer_index].shape
	if shape.kind != compact.kind { return {}, false }
	return shape, true
}

issue248_surface_effect_command_owner_allocate :: proc(rt: ^Runtime, state: ^Issue248_Surface_Effect_State) -> (owner: Node_ID, ok: bool) {
	if rt == nil || state == nil { return }
	if state.next_command_owner == 0 { state.next_command_owner = 0xFFFF_FFFF_FFFF_FFFD }
	// This allocator runs during paint, after reconciliation has moved pending
	// descriptions into rt.nodes. Map probes avoid scanning the whole retained
	// tree for every layer on a large initial construction.
	limit := len(rt.nodes) + len(state.command_owners) + 2
	for _ in 0..<limit {
		candidate := Node_ID(state.next_command_owner)
		state.next_command_owner -= 1
		if candidate == 0 || candidate == LIGHTING_MARKER_OWNER { continue }
		if _, found := rt.nodes[candidate]; found { continue }
		if _, found := state.command_owners[candidate]; found { continue }
		return candidate, true
	}
	return
}

issue248_surface_effect_layer_shape :: proc(shape: Surface_Shape, inset: f32) -> Surface_Shape {
	result := shape
	#partial switch result.kind {
	case .Rounded_Rectangle:
		result.corner_radius = max(0, result.corner_radius-inset)
	case .Rounded_Rectangle_Per_Corner:
		result.corner_radii.top_left = max(0, result.corner_radii.top_left-inset)
		result.corner_radii.top_right = max(0, result.corner_radii.top_right-inset)
		result.corner_radii.bottom_right = max(0, result.corner_radii.bottom_right-inset)
		result.corner_radii.bottom_left = max(0, result.corner_radii.bottom_left-inset)
	}
	return result
}

issue248_surface_effect_owner_clip :: proc(base: Paint_Command) -> Rect {
	left := max(base.clip.x, base.bounds.x)
	top := max(base.clip.y, base.bounds.y)
	right := min(base.clip.x+base.clip.w, base.bounds.x+base.bounds.w)
	bottom := min(base.clip.y+base.clip.h, base.bounds.y+base.bounds.h)
	if right <= left || bottom <= top { return Rect{left, top, 0, 0} }
	return Rect{left, top, right-left, bottom-top}
}

issue248_surface_effect_geometry_matches :: proc(
	entry: Issue248_Surface_Effect_Entry,
	stack: Issue248_Surface_Effect_Stack,
	base: Paint_Command,
	shape: Surface_Shape,
) -> bool {
	if !entry.geometry_valid || entry.base_width != base.bounds.w || entry.base_height != base.bounds.h ||
	   entry.base_shape != shape || entry.geometry_stack.count != stack.count {
		return false
	}
	for index in 0..<int(stack.count) {
		if entry.geometry_stack.layers[index].kind != stack.layers[index].kind ||
		   entry.geometry_stack.layers[index].inset != stack.layers[index].inset {
			return false
		}
	}
	return true
}

issue248_surface_effect_geometry_build :: proc(
	entry: ^Issue248_Surface_Effect_Entry,
	stack: Issue248_Surface_Effect_Stack,
	base: Paint_Command,
	base_shape: Surface_Shape,
) -> bool {
	if entry == nil || stack.count > ISSUE248_SURFACE_EFFECT_MAX_LAYERS ||
	   (base_shape.kind != .Rectangle && base_shape.kind != .Rounded_Rectangle &&
	    base_shape.kind != .Rounded_Rectangle_Per_Corner) {
		return false
	}
	for index in 0..<int(stack.count) {
		layer := stack.layers[index]
		if base.bounds.w <= layer.inset*2 || base.bounds.h <= layer.inset*2 { return false }
		shape := issue248_surface_effect_layer_shape(base_shape, layer.inset)
		if !surface_shape_is_valid(shape) { return false }
		entry.layer_geometry[index] = Issue248_Surface_Effect_Geometry{
			bounds=Rect{layer.inset, layer.inset, base.bounds.w-2*layer.inset, base.bounds.h-2*layer.inset},
			shape=shape,
		}
	}
	entry.base_width = base.bounds.w
	entry.base_height = base.bounds.h
	entry.base_shape = base_shape
	entry.geometry_stack = stack
	entry.stack = stack
	entry.geometry_valid = true
	return true
}

issue248_surface_effect_forget_owner :: proc(rt: ^Runtime, owner: Node_ID) {
	state := issue248_surface_effect_state(rt)
	if state == nil { return }
	entry, found := state.entries[owner]
	if !found { return }
	for index in 0..<ISSUE248_SURFACE_EFFECT_MAX_LAYERS {
		if entry.layer_owners[index] != 0 { delete_key(&state.command_owners, entry.layer_owners[index]) }
	}
	delete_key(&state.entries, owner)
}

issue248_surface_effects_destroy :: proc(rt: ^Runtime) {
	if rt == nil || rt.issue248_surface_effects == nil { return }
	state := rt.issue248_surface_effects
	delete(state.entries)
	delete(state.command_owners)
	delete(state.cleanup_owners)
	free(state, allocator=rt.persistent_allocator)
	rt.issue248_surface_effects = nil
}

issue248_surface_effect_apply :: proc(rt: ^Runtime, node: ^Node) {
	state := issue248_surface_effect_state(rt)
	if state == nil || node == nil { return }
	entry, found := state.entries[node.id]
	if !found { return }
	if entry.stack.count == 0 { return }
	base_index := -1
	base := Paint_Command{}
	for command, index in node.paint {
		if command.owner != node.id { continue }
		if _, is_surface := command.payload.(Surface_Paint); is_surface {
			base_index = index
			base = command
			break
		}
	}
	if base_index < 0 {
		state.stats.unsupported_owners += 1
		return
	}
	base_surface, base_ok := base.payload.(Surface_Paint)
	base_shape, shape_ok := surface_paint_shape_resolve(rt, node.id, base_surface.shape)
	if !base_ok || !shape_ok {
		state.stats.unsupported_owners += 1
		return
	}
	if !issue248_surface_effect_geometry_matches(entry, entry.stack, base, base_shape) {
		if !issue248_surface_effect_geometry_build(&entry, entry.stack, base, base_shape) {
			state.stats.unsupported_owners += 1
			return
		}
		state.stats.geometry_lowerings += 1
	} else {
		state.stats.geometry_cache_hits += 1
	}
	for index in 0..<int(entry.stack.count) {
		if entry.layer_owners[index] == 0 {
			owner, allocated := issue248_surface_effect_command_owner_allocate(rt, state)
			if !allocated {
				state.stats.unsupported_owners += 1
				return
			}
			entry.layer_owners[index] = owner
		}
		state.command_owners[entry.layer_owners[index]] = Issue248_Surface_Effect_Command_Owner{node.id, u8(index)}
	}
	state.entries[node.id] = entry

	layer_count := int(entry.stack.count)
	old_length := len(node.paint)
	for _ in 0..<layer_count { append(&node.paint, Paint_Command{}) }
	for index := old_length-1; index > base_index; index -= 1 {
		node.paint[index+layer_count] = node.paint[index]
	}
	clip := issue248_surface_effect_owner_clip(base)
	for index in 0..<layer_count {
		layer := entry.stack.layers[index]
		geometry := entry.layer_geometry[index]
		bounds := Rect{
			base.bounds.x+geometry.bounds.x,
			base.bounds.y+geometry.bounds.y,
			geometry.bounds.w,
			geometry.bounds.h,
		}
		command: Paint_Command
		switch layer.kind {
		case .Inset_Fill:
			command = paint_surface_command(
				entry.layer_owners[index], bounds, clip, layer.color,
				opacity=base.opacity, translation=base.translation, shape=geometry.shape,
			)
		case .Stroke:
			command = paint_surface_command(
				entry.layer_owners[index], bounds, clip, layer.stroke_fill,
				opacity=base.opacity, translation=base.translation, shape=geometry.shape,
				stroke=layer.stroke, stroke_placement=layer.stroke_placement,
			)
		}
		node.paint[base_index+1+index] = command
	}
	state.stats.paint_rebuilds += 1
}

// Removed layer owners remain mapped until the retained range has been
// replaced. Otherwise a count-changing splice cannot recognize the old tail
// command as part of the node's run and can leave stale paint behind.
issue248_surface_effect_finalize_paint :: proc(rt: ^Runtime) {
	state := issue248_surface_effect_state(rt)
	if state == nil { return }
	for owner in state.cleanup_owners {
		entry, found := state.entries[owner]
		if !found { continue }
		if entry.stack.count == 0 {
			issue248_surface_effect_forget_owner(rt, owner)
			continue
		}
		for index in int(entry.stack.count)..<ISSUE248_SURFACE_EFFECT_MAX_LAYERS {
			if entry.layer_owners[index] != 0 {
				delete_key(&state.command_owners, entry.layer_owners[index])
				entry.layer_owners[index] = 0
			}
		}
		entry.cleanup_pending = false
		state.entries[owner] = entry
	}
	clear(&state.cleanup_owners)
}
