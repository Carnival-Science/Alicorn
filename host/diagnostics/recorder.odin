// Package diagnostics owns Alicorn's host-neutral developer diagnostics:
// the bounded flight recorder, the performance HUD model and overlay geometry,
// retained-bounds inspection geometry, capture bundles, and the JSONL
// breadcrumb recorder.
//
// The package deliberately depends only on alicorn:runtime. Hosts translate
// their renderer frames, backend identity, and platform clock into these
// values, then consume the same overlay geometry and capture schema. This is
// the shared implementation behind native/sdl_gpu's diagnostics; that host
// keeps thin compatibility shims so its long-standing names and tests remain.
package diagnostics

import alicorn "alicorn:runtime"

// RECORDER_CAPACITY bounds retained work samples. Writes overwrite the oldest
// sample once the ring is full. Storage is inline so recording and reading
// never allocate or move existing samples.
RECORDER_CAPACITY :: 256
POINTER_EVENT_CAPACITY :: 256

Sample :: struct {
	timestamp_ns, cause_id: u64,
	build_ns, encode_ns, submit_ns, input_to_submit_ns: u64,
	app_builds, stabilization_rebuilds, host_wakes: u64,
	pointer_events, hover_target_transitions: u64,
	presentation_updates, gpu_submissions, surface_updates: u64,
	descriptions_emitted, descriptions_reused, regions_skipped, retained_subtrees_reused: u64,
	reconcile_visits, layout_visits, paint_visits, composition_visits: u64,
	nodes_created, nodes_retired: u64,
	semantic_descriptions_emitted, semantic_entities_resolved: u64,
	semantic_structure_changes, semantic_property_changes: u64,
	semantic_projection_nodes_added, semantic_projection_nodes_updated, semantic_projection_nodes_removed: u64,
	accessibility_activation_wakes, accessibility_action_wakes, accessibility_reveal_wakes, accessibility_updates_submitted: u64,
	accessibility_requests_received, accessibility_requests_dropped: u64,
	semantic_focus_search_visits, semantic_active_update_visits: u64,
	measure_requests, measure_cache_hits, measure_cache_misses, text_shape_requests: u64,
	measure_nodes_examined, measure_nodes_executed: u64,
	display_commands_finalized, display_finalization_full_passes: u64,
	semantic_order_nodes_examined: u64,
	global_fallbacks: u64,
	global_work_by_reason: [alicorn.Retained_Global_Work_Reason]u64,
	persistent_allocations, persistent_bytes_live, scratch_requested_bytes: u64,
	cause_kind: alicorn.Cause_Kind,
}

// Pointer_Sample records event-time details missing from wake-level work
// samples. It is fixed-size and allocation-free so diagnostics do not change
// the pointer path they are observing.
Pointer_Sample :: struct {
	sequence, timestamp_ns, cause_id: u64,
	kind: alicorn.Pointer_Kind,
	window_x, window_y, x, y: f32,
	inside_application: bool,
	button: int,
	target: alicorn.Node_ID,
	target_kind: alicorn.Node_Kind,
	target_valid: bool,
	captured_before, captured_after: alicorn.Node_ID,
	captured_before_kind, captured_after_kind: alicorn.Node_Kind,
	captured_before_valid, captured_after_valid: bool,
	split_owner: alicorn.Node_ID,
	split_position_before, split_position_after: f32,
	split_dragging_before, split_dragging_after: bool,
	split_state_valid: bool,
	callback_available, callback_called: bool,
	pointer_dispatched: bool,
	callback_blocked_by_context_menu, callback_blocked_by_drag: bool,
	invalidated, layout_pending, presentation_pending: bool,
	presentation_revision, submitted_revision: u64,
}

Activity_Class :: enum {
	Idle,
	Host,
	Present,
	App,
	Surface,
}

Recorder :: struct {
	samples: [RECORDER_CAPACITY]Sample,
	next_index: int,
	count: int,
	sequence: u64,
	pointer_events: [POINTER_EVENT_CAPACITY]Pointer_Sample,
	pointer_next_index: int,
	pointer_count: int,
	pointer_sequence: u64,
}

// record appends one sample without allocation or shifting. Sequence is a
// recorder-wide count of all writes, including samples later overwritten.
record :: proc(rec: ^Recorder, sample: Sample) {
	if rec == nil { return }
	rec.samples[rec.next_index] = sample
	rec.next_index = (rec.next_index + 1) % RECORDER_CAPACITY
	if rec.count < RECORDER_CAPACITY { rec.count += 1 }
	rec.sequence += 1
}

// sample_at returns the sample at a logical oldest-to-newest index. An index
// outside the retained history, or a nil recorder, returns a zero value and
// false.
sample_at :: proc(rec: ^Recorder, logical_index: int) -> (Sample, bool) {
	if rec == nil || logical_index < 0 || logical_index >= rec.count {
		return {}, false
	}
	oldest_index := (rec.next_index-rec.count+RECORDER_CAPACITY) % RECORDER_CAPACITY
	physical_index := (oldest_index+logical_index) % RECORDER_CAPACITY
	return rec.samples[physical_index], true
}

sample_count :: proc(rec: ^Recorder) -> int {
	if rec == nil { return 0 }
	return rec.count
}

// sequence returns the total number of successful record calls, not just the
// retained sample count. It is a monotonic change marker for UI/export code.
sequence :: proc(rec: ^Recorder) -> u64 {
	if rec == nil { return 0 }
	return rec.sequence
}

pointer_record :: proc(rec: ^Recorder, sample: Pointer_Sample) {
	if rec == nil { return }
	rec.pointer_sequence += 1
	recorded := sample
	recorded.sequence = rec.pointer_sequence
	rec.pointer_events[rec.pointer_next_index] = recorded
	rec.pointer_next_index = (rec.pointer_next_index+1) % POINTER_EVENT_CAPACITY
	if rec.pointer_count < POINTER_EVENT_CAPACITY { rec.pointer_count += 1 }
}

pointer_sample_at :: proc(rec: ^Recorder, logical_index: int) -> (Pointer_Sample, bool) {
	if rec == nil || logical_index < 0 || logical_index >= rec.pointer_count { return {}, false }
	oldest_index := (rec.pointer_next_index-rec.pointer_count+POINTER_EVENT_CAPACITY) % POINTER_EVENT_CAPACITY
	physical_index := (oldest_index+logical_index) % POINTER_EVENT_CAPACITY
	return rec.pointer_events[physical_index], true
}

pointer_sample_count :: proc(rec: ^Recorder) -> int {
	if rec == nil { return 0 }
	return rec.pointer_count
}

// pointer_split_state resolves the split owner a pointer sample should
// describe. Hosts call it before dispatch so a drag that begins on the handle
// and continues on the owner remains one retained interaction.
pointer_split_state :: proc(
	rt: ^alicorn.Runtime,
	id: alicorn.Node_ID,
) -> (owner_id: alicorn.Node_ID, position: f32, dragging, found: bool) {
	if rt == nil || id == 0 { return }
	node, node_ok := alicorn.node_info(rt, id)
	if !node_ok { return }
	if node.kind == .Split {
		return node.id, node.split_position, node.split_dragging, true
	}
	if node.kind != .Split_Handle || node.split_owner == 0 { return }
	owner, owner_ok := alicorn.node_info(rt, node.split_owner)
	if !owner_ok || owner.kind != .Split { return }
	return owner.id, owner.split_position, owner.split_dragging, true
}
