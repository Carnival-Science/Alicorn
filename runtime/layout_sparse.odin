package alicorn

// Sparse layout propagation (issue #230, milestone 1).
//
// Column main-axis placement is cumulative: a child's height change shifts the
// following suffix. This sidecar retains the resolved main size and placement
// inputs for every child of a column so a pass caused by one changed child can
// skip the unchanged leading siblings entirely and leave geometrically
// unchanged children untouched.
//
// The full placement path remains the reference implementation. The sparse
// path is only consulted when the container's own placement inputs match the
// retained snapshot exactly; anything else (a resize, a style change, a child
// set change, grow/compress sharing, positioned children, scrolling) falls
// back to the unconditional walk.
//
// The sidecar owns heap slices per parent. Entries are created on the first
// eligible placement pass, replaced in place while the child count is stable,
// and released on retirement or runtime destruction. Nodes and Descriptions
// carry no sparse-layout storage.

// A debug/CI build can force every layout through the reference path. Tests
// also flip Runtime.force_full_layout to compare an incremental sparse runtime
// against a forced-full oracle in the same process.
LAYOUT_FULL_REFERENCE_FORCED :: #config(ALICORN_FULL_LAYOUT, false)

Layout_Sparse_Child :: struct {
	id:          Node_ID,
	// Resolved main-axis size this child was placed with.
	main:        f32,
	// Resolved cross-axis size this child was placed with.
	cross:       f32,
	// Main-axis offset at the start of this child, including leading free
	// space and gaps. Valid for the snapshot below.
	main_offset: Layout_Unit,
	bounds:      Rect,
	clip:        Rect,
}

Layout_Sparse_Placement :: struct {
	parent_bounds:     Rect,
	inner:             Rect,
	parent_clip:       Rect,
	padding:           f32,
	gap_units:         Layout_Unit,
	layout_hash:       u64,
	kind:              Node_Kind,
	direction:         Layout_Direction,
	align:             Align,
	distribution:      Main_Axis_Distribution,
	writing_direction: Writing_Direction,
	clip_children:     bool,
	entries:           []Layout_Sparse_Child,
}

// Layout_Sparse_Plan is assembled before a flow placement pass. `eligible`
// means this container may retain a snapshot at the end of the pass.
// `active` means a matching snapshot was found and the sparse fast paths may
// run. `entries` is the mutable output storage: the retained slice when the
// child count is stable, otherwise scratch that is committed at the end.
Layout_Sparse_Plan :: struct {
	eligible:        bool,
	active:          bool,
	entries:         []Layout_Sparse_Child,
	entries_scratch: bool,
	snapshot:        Layout_Sparse_Placement,
}

layout_sparse_ensure :: proc(rt: ^Runtime) {
	if rt == nil || rt.layout_sparse_sidecar_initialized { return }
	rt.layout_sparse_placements = make(map[Node_ID]Layout_Sparse_Placement, allocator=rt.persistent_allocator)
	rt.layout_sparse_sidecar_initialized = true
}

layout_sparse_forget :: proc(rt: ^Runtime, parent: Node_ID) {
	if rt == nil || !rt.layout_sparse_sidecar_initialized || parent == 0 { return }
	if placement, found := rt.layout_sparse_placements[parent]; found {
		delete(placement.entries, rt.persistent_allocator)
		delete_key(&rt.layout_sparse_placements, parent)
	}
}

layout_sparse_destroy :: proc(rt: ^Runtime) {
	if rt == nil || !rt.layout_sparse_sidecar_initialized { return }
	for _, placement in rt.layout_sparse_placements {
		delete(placement.entries, rt.persistent_allocator)
	}
	delete(rt.layout_sparse_placements)
	rt.layout_sparse_placements = nil
	rt.layout_sparse_sidecar_initialized = false
}

// Sparse placement is limited to a non-scrolling Column whose children all
// have rigid main sizes. Grow/compress participants reallocate siblings and
// therefore stay on the reference path (a later milestone), as do grids,
// splits, adaptive owners, positioned children, and free-space distribution.
layout_sparse_eligible :: proc(rt: ^Runtime, parent: ^Node, children: []Node_ID, distribution: Main_Axis_Distribution, has_positioned: bool) -> bool {
	if rt == nil || parent == nil || len(children) == 0 { return false }
	if LAYOUT_FULL_REFERENCE_FORCED || rt.force_full_layout { return false }
	if has_positioned { return false }
	if parent.style.direction != .Column { return false }
	if parent.kind != .Root && parent.kind != .Container { return false }
	if distribution != .Start { return false }
	for id in children {
		child := rt.nodes[id]
		if child == nil { return false }
		if layout_grow_weight_is_finite_positive(child.style.grow) || child.style.compress_weight > 0 {
			return false
		}
	}
	return true
}

layout_sparse_snapshot_matches :: proc(placement: Layout_Sparse_Placement, snapshot: Layout_Sparse_Placement, children: []Node_ID) -> bool {
	if placement.kind != snapshot.kind || placement.direction != snapshot.direction {
		return false
	}
	if placement.align != snapshot.align || placement.distribution != snapshot.distribution {
		return false
	}
	if placement.writing_direction != snapshot.writing_direction || placement.clip_children != snapshot.clip_children {
		return false
	}
	if placement.layout_hash != snapshot.layout_hash || placement.padding != snapshot.padding || placement.gap_units != snapshot.gap_units {
		return false
	}
	if !rect_equal(placement.parent_bounds, snapshot.parent_bounds) || !rect_equal(placement.inner, snapshot.inner) {
		return false
	}
	if !rect_equal(placement.parent_clip, snapshot.parent_clip) { return false }
	if len(placement.entries) != len(children) { return false }
	for id, index in children {
		if placement.entries[index].id != id { return false }
	}
	return true
}

layout_sparse_prepare :: proc(
	rt: ^Runtime,
	parent: ^Node,
	children: []Node_ID,
	inner: Rect,
	gap_units: Layout_Unit,
	distribution: Main_Axis_Distribution,
	has_positioned: bool,
) -> Layout_Sparse_Plan {
	plan: Layout_Sparse_Plan
	if !layout_sparse_eligible(rt, parent, children, distribution, has_positioned) {
		// Drop a snapshot the container can no longer honor (its child set,
		// sizing policy, or flow path changed). The next eligible pass rebuilds.
		if rt != nil { layout_sparse_forget(rt, parent.id) }
		return plan
	}
	plan.eligible = true
	plan.snapshot = Layout_Sparse_Placement{
		parent_bounds=parent.bounds,
		inner=inner,
		parent_clip=parent.clip,
		padding=parent.style.padding,
		gap_units=gap_units,
		layout_hash=parent.layout_hash,
		kind=parent.kind,
		direction=parent.style.direction,
		align=parent.style.align,
		distribution=distribution,
		writing_direction=layout_effective_writing_direction(rt, parent),
		clip_children=parent.style.clip,
	}
	layout_sparse_ensure(rt)
	placement, found := rt.layout_sparse_placements[parent.id]
	if !found { return plan }
	if len(placement.entries) != len(children) {
		// Keep the stale slice out of this pass's output; commit will release it.
		return plan
	}
	plan.entries = placement.entries
	plan.active = layout_sparse_snapshot_matches(placement, plan.snapshot, children)
	return plan
}

// layout_sparse_needs_measure mirrors the two measurement sites in
// layout_children. Fixed-size containers and other rigid children perform no
// measurement work here; their retained Measure bit is not a placement input.
layout_sparse_needs_measure :: proc(rt: ^Runtime, parent: ^Node, child: ^Node) -> bool {
	if rt == nil || parent == nil || child == nil { return false }
	if parent.style.direction == .Column && layout_node_has_content_height(child) { return true }
	if node_has_text_product(child.kind, child.button_presentation) &&
		!(parent.style.direction == .Row && layout_grow_weight_is_finite_positive(child.style.grow)) {
		return true
	}
	return false
}

// layout_sparse_measure_pending reports a child which still needs this parent
// to measure it before placement can be trusted.
layout_sparse_measure_pending :: proc(rt: ^Runtime, parent: ^Node, child: ^Node) -> bool {
	if !layout_sparse_needs_measure(rt, parent, child) { return false }
	if child == nil || !dirty_has(child.dirty, .Measure) { return false }
	return true
}

// layout_sparse_measure_unchanged reports whether a clean child's retained
// measurement can stand in for this pass. The container snapshot must match and
// the child must not need measurement work that this pass would perform.
layout_sparse_measure_unchanged :: proc(rt: ^Runtime, plan: Layout_Sparse_Plan, parent, child: ^Node, index: int) -> bool {
	if rt == nil || !plan.active || parent == nil || child == nil || index < 0 || index >= len(plan.entries) { return false }
	if plan.entries[index].id != child.id { return false }
	if dirty_has(child.dirty, .Layout) { return false }
	if !layout_sparse_needs_measure(rt, parent, child) { return true }
	if layout_sparse_measure_pending(rt, parent, child) { return false }
	state, state_ok := rt.measure_states[child.id]
	return state_ok && state.cache_key.valid
}

// layout_sparse_first_change returns the first child whose placement inputs
// differ from the retained snapshot, or len(children) when every child is
// unchanged. A clean child cannot change cross size without becoming dirty:
// the container snapshot already guarantees the parent extent and alignment
// are unchanged, and an image/measure/style change marks the child. Leading
// children therefore keep both their cached offsets and their cached bounds,
// so callers may skip them without writing geometry.
layout_sparse_first_change :: proc(
	rt: ^Runtime,
	plan: Layout_Sparse_Plan,
	parent: ^Node,
	children: []Node_ID,
	main_sizes: []f32,
) -> int {
	if rt == nil || !plan.active { return 0 }
	first := len(children)
	for id, index in children {
		child := rt.nodes[id]
		if child == nil { return 0 }
		cached := plan.entries[index]
		_, finalized_ok := rt.finalized_geometry[id]
		changed := main_sizes[index] != cached.main || !child.present || !finalized_ok ||
			!rect_equal(child.bounds, cached.bounds) || !rect_equal(child.clip, cached.clip) ||
			dirty_has(child.dirty, .Layout) || layout_sparse_measure_pending(rt, parent, child)
		if changed && first == len(children) { first = index }
	}
	return first
}

layout_sparse_record :: proc(plan: ^Layout_Sparse_Plan, index: int, id: Node_ID, main, cross: f32, main_offset: Layout_Unit, bounds, clip: Rect) {
	if plan == nil || index < 0 || index >= len(plan.entries) { return }
	plan.entries[index] = Layout_Sparse_Child{
		id=id,
		main=main,
		cross=cross,
		main_offset=main_offset,
		bounds=bounds,
		clip=clip,
	}
}

// layout_sparse_commit publishes the completed pass's inputs and child
// placements. A stable child count reuses the retained slice, so steady-state
// passes allocate nothing.
layout_sparse_commit :: proc(rt: ^Runtime, parent: ^Node, plan: ^Layout_Sparse_Plan) {
	if rt == nil || parent == nil || plan == nil || !plan.eligible || len(plan.entries) == 0 { return }
	layout_sparse_ensure(rt)
	existing, found := rt.layout_sparse_placements[parent.id]
	snapshot := plan.snapshot
	if found && len(existing.entries) == len(plan.entries) {
		copy(existing.entries, plan.entries)
		snapshot.entries = existing.entries
	} else {
		if found { delete(existing.entries, rt.persistent_allocator) }
		snapshot.entries = make([]Layout_Sparse_Child, len(plan.entries), allocator=rt.persistent_allocator)
		copy(snapshot.entries, plan.entries)
	}
	rt.layout_sparse_placements[parent.id] = snapshot
}
