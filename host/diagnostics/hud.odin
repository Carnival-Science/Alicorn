package diagnostics

import alicorn "alicorn:runtime"

// The performance HUD is drawn as transient solid quads after the application
// display list. It never enters Runtime.display, changes application nodes, or
// increments Runtime.Frame_Stats. The shared model below decides what to show;
// each host supplies a quad sink for its own renderer.
HUD_REFRESH_INTERVAL_NS :: 1_000_000_000
HUD_IDLE_AFTER_NS       :: 500_000_000
HUD_MAX_RECENT_SAMPLES  :: 48
// Worst-case 8 lines x 65 visible glyphs x 35 quads per glyph, plus the panel
// and activity strip. Hosts that pre-reserve solid geometry use this bound.
HUD_RESERVE_VERTICES :: 131072

// Quad is one solid overlay rectangle in the caller's target space.
Quad :: struct {
	x, y, w, h: f32,
	color:      [4]f32,
}

// Quad_Target is the host's paint sink. emit is required; begin_group/end_group
// are optional batching boundaries used by bounds inspection so one inspected
// command maps to one draw run. A false emit result means the host dropped the
// quad (for example, an exhausted pre-reserved buffer); overlay drawing must
// never fail the application frame.
Quad_Target :: struct {
	data:        rawptr,
	emit:        proc(data: rawptr, quad: Quad) -> bool,
	begin_group: proc(data: rawptr) -> bool,
	end_group:   proc(data: rawptr),
}

quad_target_emit :: proc(target: Quad_Target, quad: Quad) {
	if target.emit == nil { return }
	if quad.w <= 0 || quad.h <= 0 { return }
	_ = target.emit(target.data, quad)
}

quad_target_begin :: proc(target: Quad_Target) -> bool {
	if target.begin_group == nil { return true }
	return target.begin_group(target.data)
}

quad_target_end :: proc(target: Quad_Target) {
	if target.end_group != nil { target.end_group(target.data) }
}

sample_has_activity :: proc(sample: Sample) -> bool {
	return sample.host_wakes > 0 || sample.app_builds > 0 || sample.presentation_updates > 0 ||
		sample.gpu_submissions > 0 || sample.surface_updates > 0 || sample.persistent_allocations > 0 || sample.reconcile_visits > 0 ||
		sample.layout_visits > 0 || sample.paint_visits > 0 || sample.composition_visits > 0 ||
		sample.pointer_events > 0 || sample.hover_target_transitions > 0 ||
		sample.semantic_descriptions_emitted > 0 || sample.semantic_entities_resolved > 0 ||
		sample.semantic_structure_changes > 0 || sample.semantic_property_changes > 0 ||
		sample.semantic_projection_nodes_added+sample.semantic_projection_nodes_updated+sample.semantic_projection_nodes_removed > 0 ||
		sample.accessibility_activation_wakes > 0 || sample.accessibility_action_wakes > 0 || sample.accessibility_reveal_wakes > 0 || sample.accessibility_updates_submitted > 0 ||
		sample.measure_requests > 0 || sample.measure_cache_hits > 0 || sample.measure_cache_misses > 0 || sample.text_shape_requests > 0
}

activity_class :: proc(sample: Sample) -> Activity_Class {
	if sample.app_builds > 0 || sample.semantic_descriptions_emitted > 0 || sample.semantic_entities_resolved > 0 ||
		sample.semantic_structure_changes > 0 || sample.semantic_property_changes > 0 { return .App }
	// Retained stage visits distinguish actual UI presentation work from the
	// presentation revision that a custom-surface-only update also advances.
	if sample.reconcile_visits+sample.layout_visits+sample.paint_visits+sample.composition_visits > 0 ||
		sample.nodes_created+sample.nodes_retired > 0 {
		return .Present
	}
	if sample.surface_updates > 0 { return .Surface }
	if sample.presentation_updates+sample.gpu_submissions+sample.persistent_allocations > 0 ||
		sample.semantic_projection_nodes_added+sample.semantic_projection_nodes_updated+sample.semantic_projection_nodes_removed > 0 ||
		sample.accessibility_reveal_wakes > 0 || sample.accessibility_updates_submitted > 0 { return .Present }
	if sample.host_wakes+sample.pointer_events+sample.hover_target_transitions > 0 { return .Host }
	return .Idle
}

activity_class_name :: proc(class: Activity_Class) -> string {
	switch class {
	case .Idle:    return "idle"
	case .Host:    return "host"
	case .Present: return "present"
	case .App:     return "app"
	case .Surface: return "surface"
	}
	return "unknown"
}

activity_class_label :: proc(class: Activity_Class) -> string {
	switch class {
	case .Idle:    return "IDLE"
	case .Host:    return "HOST"
	case .Present: return "PRESENT"
	case .App:     return "APP"
	case .Surface: return "SURFACE"
	}
	return "UNKNOWN"
}

HUD :: struct {
	visible: bool,
}

hud_toggle :: proc(hud: ^HUD) {
	if hud == nil { return }
	hud.visible = !hud.visible
}

// latest_activity returns the newest sample with activity, preferring a
// still-unrecorded preview from the current host wake.
latest_activity :: proc(
	recorder: ^Recorder,
	now_ns: u64,
	preview: Sample = {},
	preview_valid := false,
) -> (latest: Sample, found: bool) {
	latest_ns: u64 = 0
	for logical_index := 0; logical_index < sample_count(recorder); logical_index += 1 {
		sample, ok := sample_at(recorder, logical_index)
		if !ok || !sample_has_activity(sample) || sample.timestamp_ns > now_ns { continue }
		if found && sample.timestamp_ns <= latest_ns { continue }
		latest = sample
		latest_ns = sample.timestamp_ns
		found = true
	}
	if preview_valid && sample_has_activity(preview) && preview.timestamp_ns <= now_ns &&
		(!found || preview.timestamp_ns > latest_ns) {
		latest = preview
		found = true
	}
	return
}

hud_activity_class :: proc(
	recorder: ^Recorder,
	now_ns: u64,
	preview: Sample = {},
	preview_valid := false,
) -> Activity_Class {
	latest, found := latest_activity(recorder, now_ns, preview, preview_valid)
	if !found || now_ns-latest.timestamp_ns >= HUD_IDLE_AFTER_NS { return .Idle }
	return activity_class(latest)
}

Recent :: struct {
	app_builds:          u64,
	presentation_updates: u64,
	gpu_submissions:     u64,
	host_wakes:          u64,
	surface_updates:     u64,
	persistent_allocations: u64,
	pointer_events:      u64,
	hover_target_transitions: u64,
	semantic_entity_changes: u64,
	semantic_projection_changes: u64,
	accessibility_action_wakes: u64,
	accessibility_reveal_wakes: u64,
}

// recent aggregates the one-second window ending at now_ns. It includes the
// optional preview exactly once.
recent :: proc(
	recorder: ^Recorder,
	now_ns: u64,
	preview: Sample = {},
	preview_valid := false,
) -> (summary: Recent, last: Sample, has_last: bool) {
	count := sample_count(recorder)
	cutoff := u64(0)
	if now_ns > 1_000_000_000 { cutoff = now_ns-1_000_000_000 }
	for logical_index := 0; logical_index < count; logical_index += 1 {
		sample, ok := sample_at(recorder, logical_index)
		if !ok { continue }
		last = sample
		has_last = true
		if sample.timestamp_ns < cutoff || sample.timestamp_ns > now_ns { continue }
		recent_add(&summary, sample)
	}
	if preview_valid && preview.timestamp_ns >= cutoff && preview.timestamp_ns <= now_ns {
		recent_add(&summary, preview)
		last = preview
		has_last = true
	}
	return
}

recent_add :: proc(summary: ^Recent, sample: Sample) {
	summary.app_builds += sample.app_builds
	summary.presentation_updates += sample.presentation_updates
	summary.gpu_submissions += sample.gpu_submissions
	summary.host_wakes += sample.host_wakes
	summary.surface_updates += sample.surface_updates
	summary.persistent_allocations += sample.persistent_allocations
	summary.pointer_events += sample.pointer_events
	summary.hover_target_transitions += sample.hover_target_transitions
	summary.semantic_entity_changes += sample.semantic_entities_resolved
	summary.semantic_projection_changes += sample.semantic_projection_nodes_added+sample.semantic_projection_nodes_updated+sample.semantic_projection_nodes_removed
	summary.accessibility_action_wakes += sample.accessibility_action_wakes
	summary.accessibility_reveal_wakes += sample.accessibility_reveal_wakes
}

// next_wake_ns is the one-shot deadline that lets a host redraw the transition
// to IDLE and age recent counters out without polling an idle application. New
// samples request an immediate presentation independently.
next_wake_ns :: proc(recorder: ^Recorder, now_ns: u64) -> u64 {
	count := sample_count(recorder)
	if count <= 0 { return 0 }
	latest_activity_ns: u64 = 0
	oldest_recent_ns: u64 = 0
	latest_activity_found := false
	oldest_recent_found := false
	for logical_index := 0; logical_index < count; logical_index += 1 {
		sample, ok := sample_at(recorder, logical_index)
		if !ok { continue }
		if sample_has_activity(sample) && sample.timestamp_ns <= now_ns &&
			(!latest_activity_found || sample.timestamp_ns > latest_activity_ns) {
			latest_activity_ns = sample.timestamp_ns
			latest_activity_found = true
		}
		has_recent_count := sample.app_builds+sample.presentation_updates+sample.gpu_submissions+
			sample.host_wakes+sample.surface_updates+sample.persistent_allocations+
			sample.pointer_events+sample.hover_target_transitions+sample.semantic_entities_resolved+
			sample.accessibility_action_wakes+sample.accessibility_reveal_wakes > 0
		if has_recent_count && sample.timestamp_ns <= now_ns && now_ns-sample.timestamp_ns < 1_000_000_000 {
			if !oldest_recent_found || sample.timestamp_ns < oldest_recent_ns {
				oldest_recent_ns = sample.timestamp_ns
				oldest_recent_found = true
			}
		}
	}
	deadline: u64 = 0
	if latest_activity_found && now_ns-latest_activity_ns < HUD_IDLE_AFTER_NS {
		deadline = latest_activity_ns+HUD_IDLE_AFTER_NS
	}
	if oldest_recent_found {
		counter_deadline := oldest_recent_ns+1_000_000_000
		if deadline == 0 || counter_deadline < deadline { deadline = counter_deadline }
	}
	if deadline <= now_ns { return 0 }
	return deadline
}

cause_name :: proc(cause: alicorn.Cause_Kind) -> string {
	switch cause {
	case .Pointer:          return "POINTER"
	case .Keyboard:         return "KEYBOARD"
	case .Text_Input:       return "TEXT INPUT"
	case .Text_Composition: return "COMPOSITION"
	case .Scroll:           return "SCROLL"
	case .Native_Command:   return "COMMAND"
	case .Async_Wake:       return "ASYNC WAKE"
	case .Scheduled_Wake:   return "SCHEDULED"
	case .Application:      return "APPLICATION"
	case .Host_Event:       return "HOST EVENT"
	case .None:             return "NONE"
	}
	return "UNKNOWN"
}

Line :: struct {
	bytes:  [128]u8,
	length: int,
}

line_append :: proc(line: ^Line, value: string) {
	for ch in value {
		if line.length >= len(line.bytes) { return }
		line.bytes[line.length] = u8(ch)
		line.length += 1
	}
}

line_append_u64 :: proc(line: ^Line, value: u64) {
	digits: [20]u8
	count := 0
	remaining := value
	if remaining == 0 {
		digits[0] = '0'
		count = 1
	} else {
		for remaining > 0 && count < len(digits) {
			digits[count] = u8('0'+remaining%10)
			remaining /= 10
			count += 1
		}
	}
	for i := count-1; i >= 0; i -= 1 {
		if line.length >= len(line.bytes) { return }
		line.bytes[line.length] = digits[i]
		line.length += 1
	}
}

line_string :: proc(line: ^Line) -> string {
	return string(line.bytes[:line.length])
}

line_number :: proc(prefix: string, value: u64) -> Line {
	line: Line
	line_append(&line, prefix)
	line_append_u64(&line, value)
	return line
}

glyph_rows :: proc(character: u8) -> [7]u8 {
	ch := character
	if ch >= 'a' && ch <= 'z' { ch -= 'a'-'A' }
	switch ch {
	case 'A': return {14, 17, 17, 31, 17, 17, 17}
	case 'B': return {30, 17, 17, 30, 17, 17, 30}
	case 'C': return {14, 17, 16, 16, 16, 17, 14}
	case 'D': return {30, 17, 17, 17, 17, 17, 30}
	case 'E': return {31, 16, 16, 30, 16, 16, 31}
	case 'F': return {31, 16, 16, 30, 16, 16, 16}
	case 'G': return {14, 17, 16, 23, 17, 17, 15}
	case 'H': return {17, 17, 17, 31, 17, 17, 17}
	case 'I': return {14, 4, 4, 4, 4, 4, 14}
	case 'J': return {7, 2, 2, 2, 18, 18, 12}
	case 'K': return {17, 18, 20, 24, 20, 18, 17}
	case 'L': return {16, 16, 16, 16, 16, 16, 31}
	case 'M': return {17, 27, 21, 21, 17, 17, 17}
	case 'N': return {17, 25, 21, 19, 17, 17, 17}
	case 'O': return {14, 17, 17, 17, 17, 17, 14}
	case 'P': return {30, 17, 17, 30, 16, 16, 16}
	case 'Q': return {14, 17, 17, 17, 21, 18, 13}
	case 'R': return {30, 17, 17, 30, 20, 18, 17}
	case 'S': return {15, 16, 16, 14, 1, 1, 30}
	case 'T': return {31, 4, 4, 4, 4, 4, 4}
	case 'U': return {17, 17, 17, 17, 17, 17, 14}
	case 'V': return {17, 17, 17, 17, 17, 10, 4}
	case 'W': return {17, 17, 17, 21, 21, 21, 10}
	case 'X': return {17, 17, 10, 4, 10, 17, 17}
	case 'Y': return {17, 17, 10, 4, 4, 4, 4}
	case 'Z': return {31, 1, 2, 4, 8, 16, 31}
	case '0': return {14, 17, 19, 21, 25, 17, 14}
	case '1': return {4, 12, 4, 4, 4, 4, 14}
	case '2': return {14, 17, 1, 2, 4, 8, 31}
	case '3': return {30, 1, 1, 14, 1, 1, 30}
	case '4': return {2, 6, 10, 18, 31, 2, 2}
	case '5': return {31, 16, 16, 30, 1, 1, 30}
	case '6': return {14, 16, 16, 30, 17, 17, 14}
	case '7': return {31, 1, 2, 4, 8, 8, 8}
	case '8': return {14, 17, 17, 14, 17, 17, 14}
	case '9': return {14, 17, 17, 15, 1, 1, 14}
	case ':': return {0, 4, 4, 0, 4, 4, 0}
	case '.': return {0, 0, 0, 0, 0, 6, 6}
	case ',': return {0, 0, 0, 0, 6, 6, 4}
	case '-': return {0, 0, 0, 31, 0, 0, 0}
	case '+': return {0, 4, 4, 31, 4, 4, 0}
	case '/': return {1, 2, 2, 4, 8, 8, 16}
	case '#': return {10, 31, 10, 10, 31, 10, 0}
	case '_': return {0, 0, 0, 0, 0, 0, 31}
	case ' ': return {}
	}
	return {}
}

draw_text :: proc(target: Quad_Target, value: string, x, y, pixel_scale: int, color: [4]f32, clip_right: int) {
	if pixel_scale <= 0 { return }
	cursor_x := x
	for character in value {
		if cursor_x+5*pixel_scale > clip_right { break }
		rows := glyph_rows(u8(character))
		for row in 0..<7 {
			bits := rows[row]
			if bits == 0 { continue }
			// Emit one rect per contiguous run of set pixels. Hosts that turn each
			// quad into a paint command (the hosted WebGPU path) stay cheap without
			// changing the glyph's physical pixels.
			column := 0
			for column < 5 {
				mask := u8(1 << u32(4-column))
				if bits & mask == 0 { column += 1; continue }
				run_start := column
				for column < 5 {
					next_mask := u8(1 << u32(4-column))
					if bits & next_mask == 0 { break }
					column += 1
				}
				quad_target_emit(target, Quad{
					x=f32(cursor_x+run_start*pixel_scale), y=f32(y+row*pixel_scale),
					w=f32((column-run_start)*pixel_scale), h=f32(pixel_scale), color=color,
				})
			}
		}
		cursor_x += 6*pixel_scale
	}
}

draw_line :: proc(target: Quad_Target, line: ^Line, x, y, pixel_scale, clip_right: int, color: [4]f32) {
	draw_text(target, line_string(line), x, y, pixel_scale, color, clip_right)
}

// emit_quads emits the complete HUD overlay for the current recorder state into
// target. Coordinates and target_width/height are in the target's paint units;
// scale_x/scale_y describe that unit in physical pixels and only choose glyph
// scale, matching the native SDL_GPU host.
emit_quads :: proc(
	target: Quad_Target,
	recorder: ^Recorder,
	now_ns: u64,
	preview: Sample = {},
	preview_valid := false,
	target_width, target_height: int,
	scale_x, scale_y: f32,
	last_invalidation: string = "",
) -> bool {
	if target.emit == nil || target_width <= 0 || target_height <= 0 { return false }
	font_scale := int(max(scale_x, scale_y)+0.5)
	if font_scale < 1 { font_scale = 1 }
	if font_scale > 3 { font_scale = 3 }
	margin := 12*font_scale
	panel_w := min(target_width-2*margin, 410*font_scale)
	if panel_w < 150*font_scale { return true }
	panel_h := 126*font_scale
	if target_height < panel_h+2*margin { return true }
	panel_x := target_width-panel_w-margin
	panel_y := margin

	quad_target_emit(target, Quad{f32(panel_x), f32(panel_y), f32(panel_w), f32(panel_h), [4]f32{0.025, 0.035, 0.055, 0.96}})
	quad_target_emit(target, Quad{f32(panel_x), f32(panel_y), f32(panel_w), f32(3*font_scale), [4]f32{0.20, 0.68, 0.86, 1}})

	summary, last, has_last := recent(recorder, now_ns, preview, preview_valid)
	class := hud_activity_class(recorder, now_ns, preview, preview_valid)
	content_x := panel_x+10*font_scale
	clip_right := panel_x+panel_w-8*font_scale
	line_y := panel_y+8*font_scale
	line_height := 10*font_scale
	white := [4]f32{0.82, 0.89, 0.96, 1}
	muted := [4]f32{0.52, 0.62, 0.72, 1}
	green := [4]f32{0.32, 0.88, 0.58, 1}
	cyan := [4]f32{0.38, 0.78, 0.96, 1}

	line: Line
	line_append(&line, "ALICORN DEVTOOLS")
	line_append(&line, "  ")
	line_append(&line, activity_class_label(class))
	status_color := green
	switch class {
	case .Host: status_color = muted
	case .Present: status_color = cyan
	case .App: status_color = [4]f32{0.98, 0.78, 0.36, 1}
	case .Surface: status_color = [4]f32{0.34, 0.84, 0.62, 1}
	case .Idle: status_color = green
	}
	draw_line(target, &line, content_x, line_y, font_scale, clip_right, status_color)

	line = {}
	line_append(&line, "1S BLD ")
	line_append_u64(&line, summary.app_builds)
	line_append(&line, " PRES ")
	line_append_u64(&line, summary.presentation_updates)
	line_append(&line, " GPU ")
	line_append_u64(&line, summary.gpu_submissions)
	draw_line(target, &line, content_x, line_y+line_height, font_scale, clip_right, white)

	line = {}
	line_append(&line, "WAKE ")
	line_append_u64(&line, summary.host_wakes)
	line_append(&line, " SURF ")
	line_append_u64(&line, summary.surface_updates)
	line_append(&line, " PTR ")
	line_append_u64(&line, summary.pointer_events)
	line_append(&line, " HOV ")
	line_append_u64(&line, summary.hover_target_transitions)
	line_append(&line, " ALLOC ")
	line_append_u64(&line, summary.persistent_allocations)
	draw_line(target, &line, content_x, line_y+2*line_height, font_scale, clip_right, muted)

	last_work := last
	if has_last {
		count := sample_count(recorder)
		for logical_index := count-1; logical_index >= 0; logical_index -= 1 {
			sample, ok := sample_at(recorder, logical_index)
			if !ok { continue }
			if sample.host_wakes > 0 || sample.app_builds+sample.presentation_updates+sample.gpu_submissions+sample.surface_updates+sample.semantic_entities_resolved+sample.accessibility_action_wakes+sample.accessibility_reveal_wakes > 0 {
				last_work = sample
				break
			}
		}
	}
	if preview_valid && (preview.host_wakes > 0 || preview.app_builds+preview.presentation_updates+preview.gpu_submissions+preview.surface_updates+preview.semantic_entities_resolved+preview.accessibility_action_wakes+preview.accessibility_reveal_wakes > 0) {
		last_work = preview
	}
	line = {}
	line_append(&line, "LAST ")
	line_append(&line, cause_name(last_work.cause_kind))
	if last_work.cause_id != 0 {
		line_append(&line, " #")
		line_append_u64(&line, last_work.cause_id)
	}
	draw_line(target, &line, content_x, line_y+3*line_height, font_scale, clip_right, white)

	line = {}
	line_append(&line, "WORK B")
	line_append_u64(&line, last_work.app_builds)
	line_append(&line, " D")
	line_append_u64(&line, last_work.descriptions_emitted)
	line_append(&line, " R")
	line_append_u64(&line, last_work.reconcile_visits)
	line_append(&line, " L")
	line_append_u64(&line, last_work.layout_visits)
	draw_line(target, &line, content_x, line_y+4*line_height, font_scale, clip_right, cyan)

	line = {}
	line_append(&line, "P")
	line_append_u64(&line, last_work.paint_visits)
	line_append(&line, " C")
	line_append_u64(&line, last_work.composition_visits)
	line_append(&line, " N+")
	line_append_u64(&line, last_work.nodes_created)
	line_append(&line, " -")
	line_append_u64(&line, last_work.nodes_retired)
	line_append(&line, " SK")
	line_append_u64(&line, last_work.regions_skipped)
	line_append(&line, " RE")
	line_append_u64(&line, last_work.retained_subtrees_reused)
	line_append(&line, " A")
	line_append_u64(&line, last_work.persistent_allocations)
	draw_line(target, &line, content_x, line_y+5*line_height, font_scale, clip_right, muted)

	line = {}
	line_append(&line, "BUILD ")
	line_append_u64(&line, last_work.build_ns/1000)
	line_append(&line, "US ENC ")
	line_append_u64(&line, last_work.encode_ns/1000)
	line_append(&line, "US IN~ ")
	line_append_u64(&line, last_work.input_to_submit_ns/1000)
	line_append(&line, "US SCR ")
	line_append_u64(&line, last_work.scratch_requested_bytes)
	draw_line(target, &line, content_x, line_y+6*line_height, font_scale, clip_right, white)

	line = {}
	line_append(&line, "SEM E")
	line_append_u64(&line, summary.semantic_entity_changes)
	line_append(&line, " P")
	line_append_u64(&line, summary.semantic_projection_changes)
	line_append(&line, " ACT")
	line_append_u64(&line, summary.accessibility_action_wakes)
	line_append(&line, " REV")
	line_append_u64(&line, summary.accessibility_reveal_wakes)
	draw_line(target, &line, content_x, line_y+7*line_height, font_scale, clip_right, cyan)

	line = {}
	line_append(&line, "INV ")
	line_append(&line, last_invalidation)
	draw_line(target, &line, content_x, line_y+8*line_height, font_scale, clip_right, muted)

	// Draw a bounded oldest-to-newest activity strip. Colors distinguish the
	// classified work without implying a fixed frame rate.
	strip_y := panel_y+panel_h-17*font_scale
	strip_x := content_x
	strip_w := max(panel_w-20*font_scale, 0)
	bar_count := min(sample_count(recorder), HUD_MAX_RECENT_SAMPLES)
	bar_gap := font_scale
	bar_width := max((strip_w-(bar_count-1)*bar_gap)/max(bar_count, 1), font_scale)
	max_work: u64 = 1
	for logical_index := max(sample_count(recorder)-bar_count, 0); logical_index < sample_count(recorder); logical_index += 1 {
		sample, ok := sample_at(recorder, logical_index)
		if !ok { continue }
		work := sample.app_builds+sample.presentation_updates+sample.gpu_submissions+sample.host_wakes+sample.semantic_entities_resolved+sample.accessibility_action_wakes+sample.accessibility_reveal_wakes
		if work > max_work { max_work = work }
	}
	for bar_index := 0; bar_index < bar_count; bar_index += 1 {
		logical_index := sample_count(recorder)-bar_count+bar_index
		sample, ok := sample_at(recorder, logical_index)
		if !ok { continue }
		work := sample.app_builds+sample.presentation_updates+sample.gpu_submissions+sample.host_wakes+sample.semantic_entities_resolved+sample.accessibility_action_wakes+sample.accessibility_reveal_wakes
		bar_h := font_scale+int(u64(10*font_scale)*work/max_work)
		bar_color := [4]f32{0.23, 0.34, 0.44, 1}
		switch activity_class(sample) {
		case .Host: bar_color = [4]f32{0.48, 0.55, 0.62, 1}
		case .Present: bar_color = [4]f32{0.28, 0.70, 0.88, 1}
		case .App: bar_color = [4]f32{0.98, 0.78, 0.36, 1}
		case .Surface: bar_color = [4]f32{0.34, 0.84, 0.62, 1}
		case .Idle: bar_color = [4]f32{0.23, 0.34, 0.44, 1}
		}
		x := strip_x+bar_index*(bar_width+bar_gap)
		if x+bar_width > strip_x+strip_w { bar_width = max(strip_x+strip_w-x, 0) }
		bar_top := strip_y+12*font_scale-bar_h
		quad_target_emit(target, Quad{f32(x), f32(bar_top), f32(bar_width), f32(bar_h), bar_color})
	}
	return true
}
