package diagnostics

import "core:sort"
import alicorn "alicorn:runtime"

// FRAME_SAMPLES bounds each percentile window. Samples are host wall-clock
// nanoseconds; they never describe GPU execution or display scanout.
FRAME_SAMPLES :: 240

// Timing accumulates host-loop measurements. Hosts fill only the fields their
// backend can measure; a zero means "not measured here", not "no cost".
Timing :: struct {
	frames:              u64,
	event_pump_ns:       u64,
	application_build_ns: u64,
	first_application_submit_ns: u64,
	application_gpu_encode_ns: u64,
	native_chrome_encode_ns: u64,
	devtools_hud_encode_ns: u64,
	inspector_encode_ns: u64,
	native_host_wake_events: u64,
	inspector_submissions: u64,
	application_stabilization_rebuilds: u64,
	application_stabilization_limit_hits: u64,
	application_tick_ns: u64,
	application_tick_calls: u64,
	gpu_encode_ns:       u64,
	gpu_submit_ns:       u64,
	fence_wait_ns:       u64,
	frame_ns_total:      u64,
	frame_ns_max:        u64,
	gpu_submissions:     u64,
	fence_waits:         u64,
	scheduled_wakes:     u64,
	frequent_wakes:      u64,
	opportunistic_wakes: u64,
	scheduled_requests:  u64,
	schedule_coalesces:  u64,
	opportunistic_deferrals: u64,
	maximum_scheduled_lateness_ns: u64,
	motion_samples: u64,
	motion_timer_wakes: u64,
	motion_restore_samples: u64,
	motion_hidden_active_observations: u64,
	motion_coalesced_owners: u64,
	motion_bounded_snaps: u64,
	motion_missed_intervals: u64,
	motion_sample_ns: u64,
	motion_sample_max_ns: u64,
	motion_max_active_owners: u64,
	motion_max_lateness_ns: u64,
	event_pump_max_ns:   u64,
	application_build_max_ns: u64,
	application_tick_max_ns:  u64,
	gpu_encode_max_ns:   u64,
	gpu_submit_max_ns:   u64,
	fence_wait_max_ns:   u64,
	frame_samples:       [dynamic; FRAME_SAMPLES]u64,
	// build_samples records each bounded application description pass, so a
	// capture can report a real per-build CPU distribution instead of only the
	// accumulated total.
	build_samples:       [dynamic; FRAME_SAMPLES]u64,
	// Encode and submit samples describe CPU submission work per primary GPU
	// submission. They exclude event waits and the final idle window.
	gpu_encode_samples:  [dynamic; FRAME_SAMPLES]u64,
	gpu_submit_samples:  [dynamic; FRAME_SAMPLES]u64,
}

Text_Event_Telemetry :: struct {
	text_change_dispatches:    u64,
	text_changes:              u64,
	text_edit_key_events:      u64,
	text_navigation_key_events: u64,
	text_selection_key_events:  u64,
	text_word_key_events:       u64,
	events_this_pump:            u64,
	events_per_pump_max:         u64,
	oldest_event_age_max_ns:     u64,
	pending_input_timestamp:     u64,
	input_to_submit_samples:     [dynamic; FRAME_SAMPLES]u64,
	input_to_submit_max_ns:      u64,
	input_to_submit_sequence:    u64,
	events_received_sequence:    u64,
}

note_input_event :: proc(telemetry: ^Text_Event_Telemetry, timestamp, now_ns: u64) {
	if telemetry == nil { return }
	telemetry.events_this_pump += 1
	if timestamp == 0 { return }
	if now_ns >= timestamp {
		age := now_ns-timestamp
		if age > telemetry.oldest_event_age_max_ns { telemetry.oldest_event_age_max_ns = age }
	}
	if telemetry.pending_input_timestamp == 0 || timestamp < telemetry.pending_input_timestamp {
		telemetry.pending_input_timestamp = timestamp
	}
}

finish_input_pump :: proc(telemetry: ^Text_Event_Telemetry) {
	if telemetry == nil { return }
	if telemetry.events_this_pump > telemetry.events_per_pump_max {
		telemetry.events_per_pump_max = telemetry.events_this_pump
	}
	telemetry.events_this_pump = 0
}

note_input_submission :: proc(telemetry: ^Text_Event_Telemetry, now_ns: u64) {
	if telemetry == nil || telemetry.pending_input_timestamp == 0 { return }
	if now_ns >= telemetry.pending_input_timestamp {
		latency := now_ns-telemetry.pending_input_timestamp
		add_sample(&telemetry.input_to_submit_samples, latency)
		telemetry.input_to_submit_sequence += 1
		if latency > telemetry.input_to_submit_max_ns { telemetry.input_to_submit_max_ns = latency }
	}
	telemetry.pending_input_timestamp = 0
}

timing_accumulate :: proc(total, maximum: ^u64, elapsed: u64) {
	total^ += elapsed
	if elapsed > maximum^ { maximum^ = elapsed }
}

add_sample :: proc(samples: ^[dynamic; FRAME_SAMPLES]u64, value: u64) {
	if len(samples^) >= FRAME_SAMPLES {
		for i := 1; i < len(samples^); i += 1 {
			samples^[i-1] = samples^[i]
		}
		pop(samples)
	}
	append(samples, value)
}

timing_add_frame :: proc(timing: ^Timing, frame_ns: u64) {
	if timing == nil { return }
	timing.frames += 1
	timing.frame_ns_total += frame_ns
	if frame_ns > timing.frame_ns_max { timing.frame_ns_max = frame_ns }
	add_sample(&timing.frame_samples, frame_ns)
}

// timing_add_build records one bounded application description pass. Hosts call
// it once per build pass, so its percentiles describe description CPU time
// rather than loop wall time that includes event waits.
timing_add_build :: proc(timing: ^Timing, build_ns: u64) {
	if timing == nil { return }
	add_sample(&timing.build_samples, build_ns)
}

timing_percentile :: proc(samples: []u64, fraction: f64) -> u64 {
	if len(samples) == 0 { return 0 }
	ordered := make([]u64, len(samples))
	defer delete(ordered)
	copy(ordered, samples)
	sort.quick_sort(ordered)
	index := int(fraction*f64(len(ordered)-1))
	return ordered[index]
}

// Cursor captures cumulative counters at the last recorder boundary. Samples
// therefore describe only work since the previous host wake.
Cursor :: struct {
	stats: alicorn.Frame_Stats,
	presentation_revision: u64,
	application_build_ns: u64,
	application_gpu_encode_ns: u64,
	gpu_submit_ns: u64,
	stabilization_rebuilds: u64,
	persistent_allocations: u64,
	input_to_submit_sequence: u64,
	events_received_sequence: u64,
	application_tick_calls: u64,
	scheduled_wakes: u64,
}

cursor_init :: proc(
	rt: ^alicorn.Runtime,
	timing: ^Timing,
	telemetry: ^Text_Event_Telemetry,
) -> Cursor {
	if rt == nil || timing == nil || telemetry == nil { return {} }
	return Cursor{
		stats=rt.stats,
		presentation_revision=rt.presentation_revision,
		application_build_ns=timing.application_build_ns,
		application_gpu_encode_ns=timing.application_gpu_encode_ns,
		gpu_submit_ns=timing.gpu_submit_ns,
		stabilization_rebuilds=timing.application_stabilization_rebuilds,
		persistent_allocations=rt.allocation_stats.persistent_alloc_calls if rt.allocation_stats != nil else 0,
		input_to_submit_sequence=telemetry.input_to_submit_sequence,
		events_received_sequence=telemetry.events_received_sequence,
		application_tick_calls=timing.application_tick_calls,
		scheduled_wakes=timing.scheduled_wakes,
	}
}

make_sample :: proc(
	cursor: ^Cursor,
	rt: ^alicorn.Runtime,
	timing: ^Timing,
	telemetry: ^Text_Event_Telemetry,
	cause: alicorn.Cause_Context,
	timestamp_ns: u64,
	host_wakes: u64 = 0,
) -> Sample {
	if cursor == nil || rt == nil || timing == nil || telemetry == nil { return {} }
	current := rt.stats
	previous := cursor.stats
	sample := Sample{
		timestamp_ns=timestamp_ns,
		cause_id=cause.id,
		cause_kind=cause.kind,
		build_ns=timing.application_build_ns-cursor.application_build_ns,
		encode_ns=timing.application_gpu_encode_ns-cursor.application_gpu_encode_ns,
		host_wakes=host_wakes,
		pointer_events=current.pointer_events-previous.pointer_events,
		hover_target_transitions=current.hover_target_transitions-previous.hover_target_transitions,
		app_builds=current.frames_built-previous.frames_built,
		stabilization_rebuilds=timing.application_stabilization_rebuilds-cursor.stabilization_rebuilds,
		presentation_updates=rt.presentation_revision-cursor.presentation_revision,
		surface_updates=current.surface_updates-previous.surface_updates,
		descriptions_emitted=current.descriptions_emitted-previous.descriptions_emitted,
		descriptions_reused=current.descriptions_reused-previous.descriptions_reused,
		regions_skipped=current.regions_skipped-previous.regions_skipped,
		retained_subtrees_reused=current.retained_subtrees_reused-previous.retained_subtrees_reused,
		reconcile_visits=current.reconcile_nodes_visited-previous.reconcile_nodes_visited,
		layout_visits=current.layout_nodes_visited-previous.layout_nodes_visited,
		paint_visits=current.paint_nodes_visited-previous.paint_nodes_visited,
		composition_visits=current.composition_nodes_visited-previous.composition_nodes_visited,
		nodes_created=current.nodes_created-previous.nodes_created,
		nodes_retired=current.nodes_retired-previous.nodes_retired,
		semantic_descriptions_emitted=current.semantic_descriptions_emitted-previous.semantic_descriptions_emitted,
		semantic_entities_resolved=current.semantic_entities_resolved-previous.semantic_entities_resolved,
		semantic_structure_changes=current.semantic_structure_changes-previous.semantic_structure_changes,
		semantic_property_changes=current.semantic_property_changes-previous.semantic_property_changes,
		semantic_projection_nodes_added=current.semantic_projection_nodes_added-previous.semantic_projection_nodes_added,
		semantic_projection_nodes_updated=current.semantic_projection_nodes_updated-previous.semantic_projection_nodes_updated,
		semantic_projection_nodes_removed=current.semantic_projection_nodes_removed-previous.semantic_projection_nodes_removed,
		accessibility_activation_wakes=current.accessibility_activation_wakes-previous.accessibility_activation_wakes,
		accessibility_action_wakes=current.accessibility_action_wakes-previous.accessibility_action_wakes,
		accessibility_reveal_wakes=current.accessibility_reveal_wakes-previous.accessibility_reveal_wakes,
		accessibility_updates_submitted=current.accessibility_updates_submitted-previous.accessibility_updates_submitted,
		accessibility_requests_received=current.accessibility_requests_received-previous.accessibility_requests_received,
		accessibility_requests_dropped=current.accessibility_requests_dropped-previous.accessibility_requests_dropped,
		semantic_focus_search_visits=current.semantic_focus_search_visits-previous.semantic_focus_search_visits,
		semantic_active_update_visits=current.semantic_active_update_visits-previous.semantic_active_update_visits,
		measure_requests=current.measure_requests-previous.measure_requests,
		measure_cache_hits=current.measure_cache_hits-previous.measure_cache_hits,
		measure_cache_misses=current.measure_cache_misses-previous.measure_cache_misses,
		measure_nodes_examined=current.measure_nodes_examined-previous.measure_nodes_examined,
		measure_nodes_executed=current.measure_nodes_executed-previous.measure_nodes_executed,
		display_commands_finalized=current.display_commands_finalized-previous.display_commands_finalized,
		display_finalization_full_passes=current.display_finalization_full_passes-previous.display_finalization_full_passes,
		semantic_order_nodes_examined=current.semantic_order_nodes_examined-previous.semantic_order_nodes_examined,
		global_fallbacks=current.global_fallbacks-previous.global_fallbacks,
		text_shape_requests=current.text_shape_requests-previous.text_shape_requests,
	}
	for reason in alicorn.Retained_Global_Work_Reason {
		sample.global_work_by_reason[reason] = current.global_work_by_reason[reason]-previous.global_work_by_reason[reason]
	}
	if rt.allocation_stats != nil {
		sample.persistent_allocations = rt.allocation_stats.persistent_alloc_calls-cursor.persistent_allocations
		if rt.allocation_stats.persistent_requested_bytes_live > 0 {
			sample.persistent_bytes_live = u64(rt.allocation_stats.persistent_requested_bytes_live)
		}
		sample.scratch_requested_bytes = rt.allocation_stats.scratch_requested_bytes_epoch
	}
	return sample
}

observed_wake :: proc(
	cursor: ^Cursor,
	sample: Sample,
	timing: ^Timing,
	telemetry: ^Text_Event_Telemetry,
) -> bool {
	if cursor == nil || timing == nil || telemetry == nil { return false }
	return sample.app_builds > 0 || sample.presentation_updates > 0 || sample.gpu_submissions > 0 ||
		sample.surface_updates > 0 || sample.reconcile_visits > 0 || sample.layout_visits > 0 ||
		sample.paint_visits > 0 || sample.composition_visits > 0 || sample.nodes_created > 0 ||
		sample.nodes_retired > 0 || sample.pointer_events > 0 || sample.hover_target_transitions > 0 ||
		sample.semantic_descriptions_emitted > 0 || sample.semantic_entities_resolved > 0 ||
		sample.semantic_structure_changes > 0 || sample.semantic_property_changes > 0 ||
		sample.semantic_projection_nodes_added > 0 || sample.semantic_projection_nodes_updated > 0 ||
		sample.semantic_projection_nodes_removed > 0 || sample.accessibility_activation_wakes > 0 ||
		sample.accessibility_action_wakes > 0 || sample.accessibility_reveal_wakes > 0 || sample.accessibility_updates_submitted > 0 ||
		sample.measure_requests > 0 || sample.measure_cache_hits > 0 || sample.measure_cache_misses > 0 || sample.text_shape_requests > 0 ||
		sample.persistent_allocations > 0 || timing.application_tick_calls != cursor.application_tick_calls ||
		timing.scheduled_wakes != cursor.scheduled_wakes ||
		telemetry.events_received_sequence != cursor.events_received_sequence
}

// record_wake appends counter deltas at a host-loop boundary. It does not
// inspect or mutate the retained tree; recording is a fixed struct copy into
// the host-owned ring.
record_wake :: proc(
	recorder: ^Recorder,
	cursor: ^Cursor,
	rt: ^alicorn.Runtime,
	timing: ^Timing,
	telemetry: ^Text_Event_Telemetry,
	cause: alicorn.Cause_Context,
	timestamp_ns: u64,
	host_wakes: u64 = 0,
) {
	if recorder == nil || cursor == nil || rt == nil || timing == nil || telemetry == nil { return }
	sample := make_sample(cursor, rt, timing, telemetry, cause, timestamp_ns, host_wakes)
	sample.gpu_submissions = rt.stats.gpu_submits-cursor.stats.gpu_submits
	if sample.gpu_submissions > 0 {
		// A host submits its command buffer as a whole. With an optional overlay
		// shown, this call also includes that tiny overlay draw, while the
		// reported GPU-submission count and application render encoding remain
		// application-only.
		sample.submit_ns = timing.gpu_submit_ns-cursor.gpu_submit_ns
	}
	if telemetry.input_to_submit_sequence > cursor.input_to_submit_sequence && len(telemetry.input_to_submit_samples) > 0 {
		sample.input_to_submit_ns = telemetry.input_to_submit_samples[len(telemetry.input_to_submit_samples)-1]
	}
	if sample_has_activity(sample) || sample.nodes_created+sample.nodes_retired > 0 ||
		sample.measure_nodes_examined+sample.measure_nodes_executed > 0 ||
		sample.display_commands_finalized+sample.display_finalization_full_passes > 0 ||
		sample.semantic_order_nodes_examined+sample.global_fallbacks > 0 {
		record(recorder, sample)
	}
	cursor^ = cursor_init(rt, timing, telemetry)
}
