package alicorn

// Presentation_Output_ID is a Runtime-scoped identity for one independently
// submitted native output. IDs become invalid when the Runtime is destroyed or
// the output is unregistered; a later output never reuses its sequence.
Presentation_Output_ID :: struct {
	runtime_identity: u64,
	sequence:         u64,
}

Presentation_Output_Status :: enum {
	Ok,
	Invalid_Runtime,
	Invalid_Output,
	Invalid_Root,
	Root_Overlap,
	Output_Not_Bound,
	Runtime_Identity_Limit,
	Sequence_Limit,
	Not_Published,
	Stale_Revision,
	No_Pending_Frame,
}

Presentation_Output_Snapshot :: struct {
	id:                   Presentation_Output_ID,
	root:                 Node_ID,
	revision:             u64,
	acknowledged_revision: u64,
	visible:              bool,
	pending:              bool,
}

@(private)
Presentation_Output_State :: struct {
	id:                   Presentation_Output_ID,
	root:                 Node_ID,
	revision:             u64,
	acknowledged_revision: u64,
	visible:              bool,
	pending:              bool,
	dirty:                bool,
}

@(private)
presentation_output_runtime_identity_get :: proc(rt: ^Runtime) -> (identity: u64, status: Presentation_Output_Status) {
	if rt.motion_runtime_identity == 0 {
		identity, valid := motion_runtime_identity_next()
		if !valid { return 0, .Runtime_Identity_Limit }
		rt.motion_runtime_identity = identity
	}
	return rt.motion_runtime_identity, .Ok
}

@(private)
presentation_output_id_equal :: proc(a, b: Presentation_Output_ID) -> bool {
	return a.runtime_identity == b.runtime_identity && a.sequence == b.sequence
}

@(private)
presentation_output_find :: proc(rt: ^Runtime, id: Presentation_Output_ID) -> int {
	if rt == nil || id.runtime_identity == 0 || id.sequence == 0 { return -1 }
	for i in 0..<len(rt.presentation_outputs) {
		if presentation_output_id_equal(rt.presentation_outputs[i].id, id) { return i }
	}
	return -1
}

@(private)
presentation_output_node_in_root :: proc(rt: ^Runtime, node_id, root: Node_ID) -> bool {
	if rt == nil || node_id == 0 || root == 0 { return false }
	current := node_id
	for current != 0 {
		if current == root { return true }
		current = presentation_output_parent(rt, current)
	}
	return false
}

@(private)
presentation_output_parent :: proc(rt: ^Runtime, id: Node_ID) -> Node_ID {
	if rt == nil || id == 0 { return 0 }
	// A root may be registered while it is being described for the first time,
	// before reconciliation moves its pending description into the retained map.
	for item in rt.pending {
		if item.kind == .Description && item.description.id == id {
			return item.description.parent
		}
	}
	if node, found := rt.nodes[id]; found && node != nil { return node.parent }
	return 0
}

@(private)
presentation_output_root_is_described :: proc(rt: ^Runtime, id: Node_ID) -> bool {
	if rt == nil || id == 0 { return false }
	if node, found := rt.nodes[id]; found && node != nil && node.active { return true }
	for item in rt.pending {
		if item.kind == .Description && item.description.id == id { return true }
	}
	return false
}

@(private)
presentation_outputs_are_active :: proc(rt: ^Runtime) -> bool {
	return rt != nil && len(rt.presentation_outputs) > 0
}

@(private)
presentation_output_mark_dirty :: proc(output: ^Presentation_Output_State) {
	if output == nil { return }
	output.dirty = true
	output.pending = true
}

@(private)
presentation_outputs_mark_all_dirty :: proc(rt: ^Runtime) {
	if rt == nil { return }
	for i in 0..<len(rt.presentation_outputs) {
		presentation_output_mark_dirty(&rt.presentation_outputs[i])
	}
}

@(private)
presentation_output_mark_node_dirty :: proc(rt: ^Runtime, node_id: Node_ID) {
	if rt == nil || len(rt.presentation_outputs) == 0 { return }
	matched := false
	for i in 0..<len(rt.presentation_outputs) {
		output := &rt.presentation_outputs[i]
		if output.root != 0 && presentation_output_node_in_root(rt, node_id, output.root) {
			presentation_output_mark_dirty(output)
			matched = true
			break
		}
	}
	if !matched {
		// Changes outside every registered output can affect shared chrome or
		// an overlay. Conservatively make each bound output repaint.
		presentation_outputs_mark_all_dirty(rt)
	}
}

@(private)
presentation_outputs_publish_dirty :: proc(rt: ^Runtime, revision: u64) {
	if rt == nil { return }
	for i in 0..<len(rt.presentation_outputs) {
		output := &rt.presentation_outputs[i]
		if output.dirty && output.root != 0 {
			output.revision = revision
			output.dirty = false
			output.pending = true
		}
	}
}

@(private)
presentation_outputs_refresh_aggregate :: proc(
	rt: ^Runtime,
	completed_submission := false,
	discard_removed_work := false,
) {
	if rt == nil { return }
	visible_pending := false
	any_pending := false
	for output in rt.presentation_outputs {
		pending := output.root != 0 &&
			(output.dirty || (output.pending && output.revision != output.acknowledged_revision))
		if pending {
			any_pending = true
			if output.visible { visible_pending = true }
		}
	}
	if !visible_pending { rt.submitted_revision = rt.presentation_revision }
	// Hidden outputs keep their content pending but never keep the native loop
	// awake. Retain global motion/surface pending state until they are shown and
	// actually submitted, or the host unregisters them.
	if !any_pending && (completed_submission || discard_removed_work) && rt.motion_frame_pending {
		if diagnostics := rt.motion_diagnostics; diagnostics != nil {
			diagnostics.stats.presentation_submissions += 1
		}
		rt.motion_frame_pending = false
	}
	if !any_pending && (completed_submission || discard_removed_work) && rt.surface_frame_pending {
		rt.surface_frame_pending = false
		rt.stats.surface_frames_consumed += 1
	}
	if completed_submission && !any_pending {
		cause := rt.submission_cause if !rt.submission_cause_mixed else Cause_Context{}
		record_trace_with_cause(rt, .Submit, 0, "all presentation outputs acknowledged", cause)
		rt.submission_cause = Cause_Context{}
		rt.submission_cause_seen = false
		rt.submission_cause_mixed = false
	}
}

@(private)
presentation_outputs_prune_retired_roots :: proc(rt: ^Runtime) {
	if rt == nil { return }
	for i in 0..<len(rt.presentation_outputs) {
		output := &rt.presentation_outputs[i]
		if output.root == 0 { continue }
		root, found := rt.nodes[output.root]
		if found && root != nil && root.active { continue }
		output.root = 0
		output.pending = false
		output.dirty = false
		output.revision = rt.presentation_revision
		output.acknowledged_revision = rt.presentation_revision
		presentation_outputs_refresh_aggregate(rt, discard_removed_work=true)
	}
}

// presentation_output_register creates one initially visible output. Bind its
// retained root during description before its first presentation can be
// submitted. Output roots must be disjoint; shared changes outside those roots
// conservatively invalidate all outputs.
presentation_output_register :: proc(rt: ^Runtime) -> (id: Presentation_Output_ID, status: Presentation_Output_Status) {
	if rt == nil { return {}, .Invalid_Runtime }
	identity, identity_status := presentation_output_runtime_identity_get(rt)
	if identity_status != .Ok { return {}, identity_status }
	if rt.presentation_output_sequence == u64(0xffffffffffffffff) { return {}, .Sequence_Limit }
	rt.presentation_output_sequence += 1
	if rt.presentation_output_sequence == 0 { return {}, .Sequence_Limit }
	id = Presentation_Output_ID{identity, rt.presentation_output_sequence}
	append(&rt.presentation_outputs, Presentation_Output_State{
		id=id,
		root=0,
		revision=rt.presentation_revision,
		acknowledged_revision=rt.presentation_revision,
		visible=true,
	})
	return id, .Ok
}

// presentation_output_bind_root associates a retained subtree with an output.
// Call it from the UI thread after describing the root node. Output roots may
// not contain one another, which keeps node-to-output routing unambiguous.
presentation_output_bind_root :: proc(rt: ^Runtime, id: Presentation_Output_ID, root: Node_ID) -> Presentation_Output_Status {
	if rt == nil { return .Invalid_Runtime }
	index := presentation_output_find(rt, id)
	if index < 0 { return .Invalid_Output }
	if !presentation_output_root_is_described(rt, root) { return .Invalid_Root }
	for i in 0..<len(rt.presentation_outputs) {
		if i == index { continue }
		other_root := rt.presentation_outputs[i].root
		if other_root == 0 { continue }
		if presentation_output_node_in_root(rt, root, other_root) ||
			presentation_output_node_in_root(rt, other_root, root) {
			return .Root_Overlap
		}
	}
	output := &rt.presentation_outputs[index]
	if output.root != root {
		output.root = root
		presentation_output_mark_dirty(output)
		rt.presentation_pending = true
	}
	return .Ok
}

// presentation_output_set_visible suspends scheduling while an output is
// hidden. Restoring visibility makes its current retained contents pending.
presentation_output_set_visible :: proc(rt: ^Runtime, id: Presentation_Output_ID, visible: bool) -> Presentation_Output_Status {
	if rt == nil { return .Invalid_Runtime }
	index := presentation_output_find(rt, id)
	if index < 0 { return .Invalid_Output }
	output := &rt.presentation_outputs[index]
	if output.visible == visible { return .Ok }
	output.visible = visible
	if visible && output.root != 0 {
		presentation_output_mark_dirty(output)
		rt.presentation_pending = true
	}
	return .Ok
}

presentation_output_snapshot :: proc(rt: ^Runtime, id: Presentation_Output_ID) -> (snapshot: Presentation_Output_Snapshot, status: Presentation_Output_Status) {
	if rt == nil { return {}, .Invalid_Runtime }
	index := presentation_output_find(rt, id)
	if index < 0 { return {}, .Invalid_Output }
	output := rt.presentation_outputs[index]
	snapshot = Presentation_Output_Snapshot{
		id=output.id,
		root=output.root,
		revision=output.revision,
		acknowledged_revision=output.acknowledged_revision,
		visible=output.visible,
		pending=output.root != 0 && output.visible && output.pending && !output.dirty &&
			output.revision != output.acknowledged_revision,
	}
	return snapshot, .Ok
}

// presentation_output_frame_submission_succeeded acknowledges exactly the
// published revision submitted for this output. A delayed acknowledgement
// cannot clear work created by a newer update.
presentation_output_frame_submission_succeeded :: proc(
	rt: ^Runtime,
	id: Presentation_Output_ID,
	revision: u64,
) -> Presentation_Output_Status {
	if rt == nil { return .Invalid_Runtime }
	index := presentation_output_find(rt, id)
	if index < 0 { return .Invalid_Output }
	output := &rt.presentation_outputs[index]
	if output.root == 0 { return .Output_Not_Bound }
	if !output.pending || !output.visible { return .No_Pending_Frame }
	if output.dirty { return .Not_Published }
	if revision != output.revision {
		if revision < output.revision { return .Stale_Revision }
		return .Not_Published
	}
	if revision == output.acknowledged_revision { return .No_Pending_Frame }
	output.acknowledged_revision = revision
	output.pending = false
	record_trace(rt, .Submit, output.root, "presentation output submission acknowledged")
	presentation_outputs_refresh_aggregate(rt, completed_submission=true)
	return .Ok
}

presentation_output_unregister :: proc(rt: ^Runtime, id: Presentation_Output_ID) -> Presentation_Output_Status {
	if rt == nil { return .Invalid_Runtime }
	index := presentation_output_find(rt, id)
	if index < 0 { return .Invalid_Output }
	ordered_remove(&rt.presentation_outputs, index)
	presentation_outputs_refresh_aggregate(rt, discard_removed_work=true)
	return .Ok
}
