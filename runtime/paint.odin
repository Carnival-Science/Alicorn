package alicorn

import runa "../third_party/Runa"
import "core:time"

Text_Paint_Caret_Key :: struct {
	line_index: int,
	byte: int,
	affinity: Text_Affinity,
}

Text_Paint_Geometry :: struct {
	grapheme_boundaries: [dynamic]int,
	caret_x: map[Text_Paint_Caret_Key]f32,
}

text_paint_insert_caret :: proc(geometry: ^Text_Paint_Geometry, line_index: int, position: Text_Position, x: f32) {
	key := Text_Paint_Caret_Key{line_index, position.byte, position.affinity}
	if _, found := geometry.caret_x[key]; !found { geometry.caret_x[key] = x }
}

text_paint_boundary_lower_bound :: proc(boundaries: []int, byte: int, strict := false) -> int {
	low, high := 0, len(boundaries)
	for low < high {
		middle := (low+high)/2
		if boundaries[middle] < byte || (strict && boundaries[middle] == byte) { low = middle+1 }
		else { high = middle }
	}
	return low
}

text_paint_geometry_make :: proc(run: ^Text_Run, allocator := context.temp_allocator) -> Text_Paint_Geometry {
	geometry := Text_Paint_Geometry{
		grapheme_boundaries=make([dynamic]int, 0, len(run.value)+1, allocator),
		caret_x=make(map[Text_Paint_Caret_Key]f32, allocator=allocator),
	}
	append(&geometry.grapheme_boundaries, 0)
	it := runa.grapheme_iter_make(run.value)
	for {
		_, end, ok := runa.grapheme_iter_next(&it)
		if !ok { break }
		append(&geometry.grapheme_boundaries, end)
	}
	for line, line_index in run.lines {
		for glyph_index := line.glyph_start; glyph_index < line.glyph_end; glyph_index += 1 {
			glyph := run.glyphs[glyph_index]
			start, end := glyph.cluster_start, glyph.cluster_end
			if start < 0 { start = 0 }
			if end > len(run.value) { end = len(run.value) }
			if end < start { end = start }
			if start == end {
				text_paint_insert_caret(&geometry, line_index, Text_Position{start, .Leading}, glyph.x)
				text_paint_insert_caret(&geometry, line_index, Text_Position{start, .Trailing}, glyph.x)
				continue
			}
			text_paint_insert_caret(&geometry, line_index, Text_Position{start, .Leading}, text_glyph_boundary_x(glyph, start))
			boundary_index := text_paint_boundary_lower_bound(geometry.grapheme_boundaries[:], start, true)
			for boundary_index < len(geometry.grapheme_boundaries) {
				byte := geometry.grapheme_boundaries[boundary_index]
				if byte > end { break }
				x := text_glyph_boundary_x(glyph, byte)
				if byte == end {
					text_paint_insert_caret(&geometry, line_index, Text_Position{byte, .Trailing}, x)
				} else {
					text_paint_insert_caret(&geometry, line_index, Text_Position{byte, .Leading}, x)
					text_paint_insert_caret(&geometry, line_index, Text_Position{byte, .Trailing}, x)
				}
				boundary_index += 1
			}
		}
		text_paint_insert_caret(&geometry, line_index, Text_Position{line.byte_start, .Leading}, line.x)
		text_paint_insert_caret(&geometry, line_index, Text_Position{line.byte_end, .Trailing}, line.width)
	}
	return geometry
}

text_paint_geometry_destroy :: proc(geometry: ^Text_Paint_Geometry) {
	if geometry == nil { return }
	if len(geometry.grapheme_boundaries) > 0 { delete(geometry.grapheme_boundaries) }
	if geometry.caret_x != nil { delete(geometry.caret_x) }
	geometry^ = Text_Paint_Geometry{}
}

text_paint_geometry_position_x :: proc(geometry: ^Text_Paint_Geometry, run: ^Text_Run, line_index: int, byte: int, affinity: Text_Affinity) -> f32 {
	key := Text_Paint_Caret_Key{line_index, byte, affinity}
	if x, found := geometry.caret_x[key]; found { return x }
	line := run.lines[line_index]
	if byte <= line.byte_start { return line.x }
	if byte >= line.byte_end { return line.width }
	return line.x
}

text_paint_grapheme_floor :: proc(boundaries: []int, byte: int) -> int {
	index := text_paint_boundary_lower_bound(boundaries, byte)
	if index < len(boundaries) && boundaries[index] == byte { return byte }
	if index > 0 { return boundaries[index-1] }
	return 0
}

text_paint_first_line_for_byte :: proc(run: ^Text_Run, byte: int) -> int {
	low, high := 0, len(run.lines)
	for low < high {
		middle := (low+high)/2
		if run.lines[middle].byte_end <= byte { low = middle+1 }
		else { high = middle }
	}
	return low
}

text_paint_geometry_needed :: proc(node: ^Node) -> bool {
	if node == nil { return false }
	for span in node.text_paint_spans {
		if span.background_set || span.underline || span.strikethrough { return true }
	}
	return false
}

append_text_paint_geometry :: proc(node: ^Node, geometry: ^Text_Paint_Geometry, command_clip: Rect, backgrounds: bool) {
	if node == nil || !node.text_run_valid || len(node.text_paint_spans) == 0 { return }
	for span in node.text_paint_spans {
		if backgrounds && !span.background_set { continue }
		if !backgrounds && !span.underline && !span.strikethrough { continue }
		start := clamp(span.start, 0, len(node.text_run.value))
		end := clamp(span.end, 0, len(node.text_run.value))
		if start >= end { continue }
		start = text_paint_grapheme_floor(geometry.grapheme_boundaries[:], start)
		end = text_paint_grapheme_floor(geometry.grapheme_boundaries[:], end)
		low, high := start, end
		if low > high { low, high = high, low }
		if low == high { continue }
		line_start_index := text_paint_first_line_for_byte(&node.text_run, low)
		for line_index := line_start_index; line_index < len(node.text_run.lines); line_index += 1 {
			line := node.text_run.lines[line_index]
			if high <= line.byte_start { break }
			if high <= line.byte_start || low >= line.byte_end { continue }
			selection_start := max(low, line.byte_start)
			selection_end := min(high, line.byte_end)
			left := line.x
			right := line.width
			if selection_start > line.byte_start {
				left = text_paint_geometry_position_x(geometry, &node.text_run, line_index, selection_start, .Leading)
			}
			if selection_end < line.byte_end {
				right = text_paint_geometry_position_x(geometry, &node.text_run, line_index, selection_end, .Trailing)
			}
			if right < left { left, right = right, left }
			if right <= left { continue }
			bounds := Rect{left, line.y, right-left, line.height}
			bounds.x += node.bounds.x
			bounds.y += node.bounds.y
			if backgrounds && span.background_set {
				append(&node.paint, paint_surface_command(node.id, bounds, command_clip, span.background))
			}
			if !backgrounds {
				if span.underline {
					append(&node.paint, paint_surface_command(node.id, Rect{bounds.x, bounds.y+line.baseline+1, bounds.w, 1}, command_clip, span.color if span.color_set else node.color))
				}
				if span.strikethrough {
					append(&node.paint, paint_surface_command(node.id, Rect{bounds.x, bounds.y+line.baseline-node.text_run.size*0.32, bounds.w, 1}, command_clip, span.color if span.color_set else node.color))
				}
			}
		}
	}
}

append_rect_outline :: proc(node: ^Node, color: Color, thickness: f32) {
	append_rect_outline_bounds(node, node.bounds, color, thickness)
}

append_rect_outline_bounds :: proc(node: ^Node, bounds: Rect, color: Color, thickness: f32) {
	width := min(max(thickness, 0), bounds.w/2)
	height := min(max(thickness, 0), bounds.h/2)
	if width <= 0 || height <= 0 { return }
	append(&node.paint, paint_surface_command(node.id, Rect{bounds.x, bounds.y, bounds.w, height}, node.clip, color))
	append(&node.paint, paint_surface_command(node.id, Rect{bounds.x, bounds.y+bounds.h-height, bounds.w, height}, node.clip, color))
	interior_height := max(0, bounds.h-height*2)
	append(&node.paint, paint_surface_command(node.id, Rect{bounds.x, bounds.y+height, width, interior_height}, node.clip, color))
	append(&node.paint, paint_surface_command(node.id, Rect{bounds.x+bounds.w-width, bounds.y+height, width, interior_height}, node.clip, color))
}

append_focus_outline :: proc(node: ^Node, color: Color, thickness: f32, shape := Surface_Shape{kind=.Rectangle}) {
	if surface_shape_has_rounded_corners(shape) {
		append(&node.paint, paint_surface_command(
			node.id,
			node.bounds,
			node.clip,
			Color{0, 0, 0, 0},
			shape=shape,
			stroke=Paint_Stroke{color=color, width=thickness},
		))
		return
	}
	append_rect_outline(node, color, thickness)
}

append_scrollbar_display :: proc(rt: ^Runtime, node: ^Node) {
	if node.kind != .Scroll_Region { return }
	resolved_style := style_scrollbar_resolve_retained(rt, node, Scrollbar_Visual_State{
		hovered=node.hovered,
		pressed=rt.scrollbar_drag_node == node.id,
	})
	if node.scrollbar_vertical_visible {
		append(&rt.display_target, paint_surface_command(node.id, node.scrollbar_vertical_track, node.clip, resolved_style.track))
		append(&rt.display_target, paint_surface_command(node.id, node.scrollbar_vertical_thumb, node.clip, resolved_style.thumb))
	}
	if node.scrollbar_horizontal_visible {
		append(&rt.display_target, paint_surface_command(node.id, node.scrollbar_horizontal_track, node.clip, resolved_style.track))
		append(&rt.display_target, paint_surface_command(node.id, node.scrollbar_horizontal_thumb, node.clip, resolved_style.thumb))
	}
	if node.scrollbar_vertical_visible && node.scrollbar_horizontal_visible {
		corner := Rect{node.scrollbar_vertical_track.x, node.scrollbar_horizontal_track.y, node.scrollbar_vertical_track.w, node.scrollbar_horizontal_track.h}
		append(&rt.display_target, paint_surface_command(node.id, corner, node.clip, resolved_style.corner))
	}
}

// A bulk repaint that covers most of the display is cheaper as one full pass
// than as per-node ancestor validation. The absolute floor keeps small windows
// on the sparse path even when every node changes.
SPARSE_DISPLAY_BULK_QUEUE_THRESHOLD :: 64

// A count-changing splice moves every command after the changed range in both
// display lists and shifts each following node's display_index. The fixup scans
// the moved commands themselves, so its cost has the same shape as the memmove.
// Splice only while that tail work stays proportional to the change: allow up
// to eight moved commands per changed command, but never less than a 256-command
// floor. Above that, one linear full pass composes and finalizes the whole list
// instead of paying a memmove plus a command scan of the same order.
SPARSE_DISPLAY_TAIL_COMMAND_FLOOR :: 256
SPARSE_DISPLAY_TAIL_COMMANDS_PER_CHANGE :: 8

// Compose_Inherited_Presentation carries the translation, opacity and clip a
// node receives from its ancestors, recomputed on demand for sparse range
// finalization.
Compose_Inherited_Presentation :: struct {
	presentation:    Motion_Composition_Values,
	stationary_clip: Rect,
	translated_clip: Rect,
	clip_follow:     bool,
	valid:           bool,
}

// compose_paint_command_presentation applies the presentation inherited from
// an ancestor chain to one cached paint command. Both the full subtree
// compositor and the sparse range finalizer use this so their output cannot
// drift apart.
compose_paint_command_presentation :: proc(
	command: Paint_Command,
	presentation: Motion_Composition_Values,
	clip_follow: bool,
	stationary_clip, translated_clip: Rect,
) -> Paint_Command {
	result := command
	if presentation.has_surface_color && result.semantic_surface_fill {
		if surface, ok := result.payload.(Surface_Paint); ok {
			surface.fill = presentation.surface_color
			result.payload = surface
		}
	}
	result.opacity *= presentation.opacity
	result.translation[0] += presentation.translation[0]
	result.translation[1] += presentation.translation[1]
	if clip_follow {
		result.clip = rect_intersection(stationary_clip, translated_clip)
		if paint_command_is_text(result) {
			result.clip = rect_intersection(result.clip,
				paint_rect_translate(result.bounds, presentation.translation))
		}
	}
	return result
}

// compose_inherited_presentation recomputes the translation, opacity and clip
// a node receives from its ancestors. Sparse finalization validates the
// recomposed run against the commands it replaces, so a changed ancestor
// presentation falls back instead of aliasing stale geometry.
compose_inherited_presentation :: proc(rt: ^Runtime, id: Node_ID) -> (result: Compose_Inherited_Presentation) {
	if rt == nil || id == 0 { return }
	chain: [256]Node_ID
	count := 0
	current := id
	for {
		if count >= len(chain) { return }
		node, found := rt.nodes[current]
		if !found || node == nil { return }
		if current != id && (!node.active || !node.present) { return }
		chain[count] = current
		count += 1
		if node.parent == 0 { break }
		current = node.parent
	}
	// Only trees the display compositor actually walks can be spliced.
	root_found := false
	for top in rt.top_level {
		if top == chain[count-1] { root_found = true; break }
	}
	if !root_found || !visual_part_is_visible(rt, id) { return }

	translation: [2]f32
	opacity := f32(1)
	stationary_clip := rt.viewport
	translated_clip := rt.viewport
	clip_follow := false
	for index := count-1; index >= 0; index -= 1 {
		node, found := rt.nodes[chain[index]]
		if !found || node == nil { return }
		presentation := motion_compose_subtree(rt, node.id, translation, opacity)
		presentation.opacity *= drag_source_opacity(rt, node.id)
		next_clip_follow := clip_follow || presentation.clip_policy == .Follow_Visual
		child_stationary_clip := stationary_clip
		child_translated_clip := translated_clip
		if node.kind == .Scroll_Region || node.style.clip {
			local_clip := node.bounds
			if node.kind == .Scroll_Region { local_clip = node.scroll_viewport_bounds }
			if next_clip_follow {
				child_translated_clip = rect_intersection(child_translated_clip,
					paint_rect_translate(local_clip, presentation.translation))
			} else {
				child_stationary_clip = rect_intersection(child_stationary_clip, local_clip)
			}
		}
		if index == 0 {
			result = Compose_Inherited_Presentation{
				presentation=presentation,
				stationary_clip=stationary_clip,
				translated_clip=translated_clip,
				clip_follow=next_clip_follow,
				valid=true,
			}
		} else {
			translation = presentation.translation
			opacity = presentation.opacity
			stationary_clip = child_stationary_clip
			translated_clip = child_translated_clip
			clip_follow = next_clip_follow
		}
	}
	return
}

// compose_presentation_fields_match compares the fields the presentation
// compositor overrides: inherited opacity, translation and clip. Bounds are the
// node's own painted geometry and may legitimately change during a same-count
// repaint, as a slider thumb or fill does.
compose_presentation_fields_match :: proc(a, b: Paint_Command) -> bool {
	return a.owner == b.owner && a.clip == b.clip &&
		a.opacity == b.opacity && a.translation == b.translation
}

compose_owned_command_run :: proc(commands: []Paint_Command, start: int, owner: Node_ID) -> int {
	count := 0
	for index := start; index < len(commands); index += 1 {
		if commands[index].owner != owner { break }
		count += 1
	}
	return count
}

// paint_commands_have_backdrop_effect reports whether a retained paint list
// contains a backdrop boundary. Until the range splice can reason about the
// compositor's captured prefix, any live boundary disables it.
paint_commands_have_backdrop_effect :: proc(commands: []Paint_Command) -> bool {
	for command in commands {
		if paint_command_is_backdrop_effect(command) { return true }
	}
	return false
}

// paint_sparse_inherited_is_neutral reports whether the node receives no
// translation, opacity, clip or motion surface from its ancestors (and none
// from its own motion state). A count-changing repaint shifts command roles, so
// it has no stable slot to validate the inherited presentation against. Splice
// only while the presentation is neutral, which keeps the recomposed prefix
// byte-identical to a full composition; motion, ancestor clips and animated
// surface colors take the full compositor.
paint_sparse_inherited_is_neutral :: proc(rt: ^Runtime, inherited: Compose_Inherited_Presentation) -> bool {
	if rt == nil || !inherited.valid { return false }
	return inherited.presentation.opacity == 1 &&
		inherited.presentation.translation == [2]f32{} &&
		!inherited.presentation.has_surface_color &&
		!inherited.clip_follow &&
		inherited.stationary_clip == rt.viewport &&
		inherited.translated_clip == rt.viewport
}

// paint_sparse_insertion_point finds where a node that previously owned no
// display commands inserts its first run. The node's own commands precede every
// descendant command, so the first command anywhere in its subtree is the
// insertion point. The walk stops at the first child subtree that contributes a
// command; later siblings are strictly later in display order. Nodes without
// any command-bearing descendant are not anchored by this rule.
paint_sparse_insertion_point :: proc(rt: ^Runtime, node: ^Node) -> int {
	for child_id in node.children {
		child, ok := rt.nodes[child_id]
		if !ok || child == nil || !child.active { continue }
		if child.display_index >= 0 { return child.display_index }
		if index := paint_sparse_insertion_point(rt, child); index >= 0 { return index }
	}
	return -1
}

// paint_sparse_splice_tail resizes one retained display list and moves the
// commands after the changed range by delta slots. Both lists are spliced the
// same way so display stays the finalized mirror of display_target.
paint_sparse_splice_tail :: proc(
	commands: ^[dynamic]Paint_Command,
	start, old_count, new_count: int,
) -> (moved_commands: int, ok: bool) {
	if commands == nil { return 0, false }
	old_len := len(commands^)
	tail := old_len - (start + old_count)
	if start < 0 || old_count < 0 || new_count < 0 || tail < 0 { return 0, false }
	if new_count == old_count { return 0, true }
	new_len := old_len + new_count - old_count
	source := start + old_count
	destination := start + new_count
	if new_count > old_count {
		resize(commands, new_len)
		for offset := tail - 1; offset >= 0; offset -= 1 {
			commands[destination + offset] = commands[source + offset]
		}
	} else {
		// Move the tail before shrinking so every source slot is still inside
		// the array's length.
		for offset := 0; offset < tail; offset += 1 {
			commands[destination + offset] = commands[source + offset]
		}
		resize(commands, new_len)
	}
	return tail, true
}

// paint_sparse_fixup_display_indices shifts display_index for every node whose
// first command follows the spliced range. It walks the moved tail commands
// instead of the retained tree: display_index is by definition the slot of a
// node's first owned command, so a node needs the shift exactly when that slot
// is the slot being visited. The cost is O(moved commands), the same bound as
// the memmove itself, and needs no ordered-tree sidecar. The two passes mark
// then publish first-command slots so a scroll region's later scrollbar run
// cannot shift its owner twice.
paint_sparse_fixup_display_indices :: proc(rt: ^Runtime, boundary, length, delta: int) -> int {
	shifted := 0
	for index := boundary; index < length; index += 1 {
		owner := rt.display_target[index].owner
		if owner == 0 { continue }
		node, ok := rt.nodes[owner]
		if !ok || node == nil { continue }
		if node.display_index == index {
			node.display_index = -(index + 1)
			shifted += 1
		}
	}
	for index := boundary; index < length; index += 1 {
		owner := rt.display_target[index].owner
		if owner == 0 { continue }
		node, ok := rt.nodes[owner]
		if !ok || node == nil { continue }
		if node.display_index < 0 && -node.display_index - 1 == index {
			node.display_index = index + delta
		}
	}
	return shifted
}

// paint_sparse_finalize_range recomposes only the node's own contiguous
// display commands and finalizes them in place. Same-count repaints keep every
// later display_index. Count-changing repaints splice the range: both display
// lists are resized, the following tail is moved verbatim (finalization is
// position-independent), and every following node's display_index shifts by the
// delta. The splice is attempted only while the moved tail stays bounded and
// the inherited presentation can be validated; everything else falls back to
// rebuild_display.
paint_sparse_finalize_range :: proc(rt: ^Runtime, node: ^Node) -> bool {
	if rt == nil || node == nil { return false }
	// Transient overlays (drag preview, tooltip) are appended after every
	// top-level tree and re-appended by rebuild_display. Their commands have no
	// owner node and are not part of the tree tail, so a splice must not move
	// them; the full rebuild handles any frame in which they are present.
	if rt.composition_rebuild || rt.transient_overlay_kind != .None || rt.drag.phase == .Dragging ||
		rt.tooltip.visible { return false }
	// A backdrop marker anywhere in the retained display captures a prefix for
	// the effects compositor. Keep the full rebuild until range edits can
	// update that prefix. A published lighting-group marker owns the same
	// prefix-capture contract.
	if rt.retained_backdrop_effect_nodes != 0 || rt.lighting_marker_present { return false }
	if node.kind == .Scroll_Region { return false }
	if len(rt.display) != len(rt.display_target) { return false }
	part_visible := visual_part_is_visible(rt, node.id)
	start := node.display_index
	new_count := len(node.paint)
	old_count := 0
	if start < 0 {
		// The node owned no commands at the last composition. A repaint that
		// still emits none (or whose part is hidden) changes nothing here.
		if new_count == 0 || !part_visible { return false }
		start = paint_sparse_insertion_point(rt, node)
		if start < 0 {
			if len(rt.display_target) == 0 { start = 0 }
			else { return false }
		}
	} else {
		if start >= len(rt.display_target) { return false }
		old_count = compose_owned_command_run(rt.display_target[:], start, node.id)
		display_count := compose_owned_command_run(rt.display[:], start, node.id)
		if old_count == 0 || display_count != old_count { return false }
		if !part_visible {
			// The node's own run disappears, and an untagged hidden part hides
			// its children too. The full compositor applies both cases.
			return false
		}
	}
	count_changed := new_count != old_count
	// A clipping node's bounds are inherited by its descendants. A count change
	// has no old slots to validate new command bounds against, so let the full
	// compositor handle that combination.
	if count_changed && node.style.clip { return false }
	inherited := compose_inherited_presentation(rt, node.id)
	if !inherited.valid { return false }
	// Validate the slots the repaint replaces. A same-count repaint keeps one
	// command per slot, so every recomposed command must match the inherited
	// presentation of the slot it replaces. A count-changing repaint shifts
	// command roles (a checkmark is inserted before a label, a focus outline
	// before text), so there is no stable slot to compare; require a neutral
	// inherited presentation instead, which is the static-tree case these
	// splices target. Motion, ancestor clips and animated surface colors keep
	// the full compositor.
	if !count_changed {
		for offset in 0..<old_count {
			composed := compose_paint_command_presentation(node.paint[offset], inherited.presentation,
				inherited.clip_follow, inherited.stationary_clip, inherited.translated_clip)
			existing := rt.display_target[start+offset]
			if !compose_presentation_fields_match(composed, existing) ||
				(node.style.clip && composed.bounds != existing.bounds) {
				return false
			}
		}
	} else if !paint_sparse_inherited_is_neutral(rt, inherited) {
		return false
	}
	moved_commands := 0
	tail_commands := 0
	delta := new_count - old_count
	if count_changed {
		tail_commands = len(rt.display_target) - (start + old_count)
		delta_magnitude := delta if delta >= 0 else -delta
		tail_limit := SPARSE_DISPLAY_TAIL_COMMAND_FLOOR
		if scaled := SPARSE_DISPLAY_TAIL_COMMANDS_PER_CHANGE * delta_magnitude; scaled > tail_limit {
			tail_limit = scaled
		}
		if tail_commands < 0 || tail_commands > tail_limit {
			rt.stats.display_splice_tail_rejections += 1
			return false
		}
	}
	started := time.now()
	tail_nodes := 0
	if count_changed {
		tail_nodes = paint_sparse_fixup_display_indices(rt, start + old_count,
			len(rt.display_target), delta)
		if moved, ok := paint_sparse_splice_tail(&rt.display_target, start, old_count, new_count); ok {
			moved_commands += moved
		} else {
			return false
		}
		if moved, ok := paint_sparse_splice_tail(&rt.display, start, old_count, new_count); ok {
			moved_commands += moved
		} else {
			return false
		}
	}
	if part_visible {
		for command, offset in node.paint {
			rt.display_target[start+offset] = compose_paint_command_presentation(command,
				inherited.presentation, inherited.clip_follow, inherited.stationary_clip,
				inherited.translated_clip)
		}
	}
	if count_changed {
		if new_count == 0 {
			node.display_index = -1
		} else {
			node.display_index = start
		}
	}
	if new_count > 0 {
		if !layout_finalize_display_range(rt, node.id, start,
			rt.display_target[start:start+new_count]) {
			return false
		}
	}
	rt.stats.display_splice_count += 1
	rt.stats.display_splice_elapsed_ns +=
		u64(time.duration_nanoseconds(time.since(started)))
	rt.stats.display_splice_bytes_moved +=
		u64(moved_commands) * u64(size_of(Paint_Command))
	rt.stats.display_splice_tail_commands += u64(tail_commands)
	rt.stats.display_splice_tail_nodes += u64(tail_nodes)
	return true
}

compose_subtree :: proc(
	rt: ^Runtime,
	id: Node_ID,
	inherited_translation: [2]f32,
	inherited_opacity: f32,
	stationary_clip, translated_clip: Rect,
	inherited_clip_follow: bool,
) {
	node, ok := rt.nodes[id]
	if !ok || !node.active || !node.present { return }
	part_visible := visual_part_is_visible(rt, id)
	// A focus-visible part may be a surface wrapper around the control's
	// ordinary content. Hide that part's paint when keyboard focus is absent,
	// but keep its retained children composed and interactive.
	if !part_visible {
		part, tagged := rt.visual_parts[id]
		if !tagged || !part.defined || part.visibility != .Owner_Focus_Visible { return }
	}
	presentation := motion_compose_subtree(rt, id, inherited_translation, inherited_opacity)
	presentation.opacity *= drag_source_opacity(rt, node.id)
	clip_follow := inherited_clip_follow || presentation.clip_policy == .Follow_Visual

	node.display_index = -1
	if part_visible {
		for cached_command in node.paint {
			command := compose_paint_command_presentation(cached_command, presentation,
				clip_follow, stationary_clip, translated_clip)
			if node.display_index < 0 { node.display_index = len(rt.display_target) }
			append(&rt.display_target, command)
			rt.stats.composition_nodes_visited += 1
			rt.stats.stage_visits[.Composite] += 1
		}
	}
	child_stationary_clip := stationary_clip
	child_translated_clip := translated_clip
	if node.kind == .Scroll_Region || node.style.clip {
		local_clip := node.bounds
		if node.kind == .Scroll_Region { local_clip = node.scroll_viewport_bounds }
		if clip_follow {
			child_translated_clip = rect_intersection(child_translated_clip,
				paint_rect_translate(local_clip, presentation.translation))
		} else {
			child_stationary_clip = rect_intersection(child_stationary_clip, local_clip)
		}
	}
	for child in node.children {
		compose_subtree(rt, child, presentation.translation, presentation.opacity,
			child_stationary_clip, child_translated_clip, clip_follow)
	}
	// Scrollbars are local retained chrome: they paint above their scroll
	// region's descendants, but remain below later siblings and top-level
	// overlays such as modal command palettes.
	scrollbar_start := len(rt.display_target)
	append_scrollbar_display(rt, node)
	for index := scrollbar_start; index < len(rt.display_target); index += 1 {
		rt.display_target[index].opacity *= presentation.opacity
		rt.display_target[index].translation[0] += presentation.translation[0]
		rt.display_target[index].translation[1] += presentation.translation[1]
		if clip_follow {
			rt.display_target[index].clip = rect_intersection(stationary_clip, translated_clip)
		}
	}
}

paint_rect_translate :: proc(rect: Rect, translation: [2]f32) -> Rect {
	return Rect{rect.x+translation[0], rect.y+translation[1], rect.w, rect.h}
}

rebuild_display :: proc(rt: ^Runtime) {
	clear(&rt.display_target)
	for id in rt.top_level {
		compose_subtree(rt, id, {}, 1, rt.viewport, rt.viewport, false)
	}
	rt.transient_overlay_kind = .None
	append_drag_preview(rt)
	append_tooltip_overlay(rt)
	rt.stats.composite_updates += 1
	frontier_note_changed(rt, .Composite, 0)
	rt.composition_rebuild = false
	layout_finalize_display(rt, .Display_Structure_Rebuild)
	record_trace(rt, .Composite, 0, "retained display list rebuilt after structure change")
}

append_visual_row_background :: proc(rt: ^Runtime, row: ^Node) {
	if rt == nil || row == nil || !row.visual_row_enabled { return }
	text, found := rt.nodes[row.visual_row_text_node]
	if !found || !text.active || text.kind != .Text || !text.text_run_valid || len(text.text_run.lines) == 0 { return }
	position := text_position_normalize(&text.text_run, row.visual_row_position)
	line_index := text_run_line_for_byte(&text.text_run, position)
	if line_index < 0 || line_index >= len(text.text_run.lines) { return }
	line := text.text_run.lines[line_index]
	bounds := Rect{row.bounds.x, text.bounds.y+line.y, row.bounds.w, line.height}
	if bounds.w <= 0 || bounds.h <= 0 { return }
	append(&row.paint, paint_surface_command(row.id, bounds, row.clip, row.visual_row_color))
}

update_paint :: proc(rt: ^Runtime) {
	paint_mark := perf_mark_begin()
	semantic_surface_refresh_top_edge_gaps(rt)
	// A sparse range splice walks the changed node's ancestor chain and
	// validates its recomposition against the retained slots. When most of the
	// display is changing (a broad theme replacement, for example), one full
	// pass is cheaper and is still proportional to the changed content.
	if !rt.composition_rebuild && len(rt.display_target) > 0 {
		queued := 0
		for id in rt.paint_queue {
			node, ok := rt.nodes[id]
			if ok && node != nil && node.active && node.present { queued += 1 }
		}
		if queued >= SPARSE_DISPLAY_BULK_QUEUE_THRESHOLD && queued*8 >= len(rt.display_target) {
			rt.composition_rebuild = true
		}
	}
	// Only nodes queued by description or layout changes are visited. An
	// unchanged retained display command is left in place.
	for id in rt.paint_queue {
		node, ok := rt.nodes[id]
		if !ok { continue }
		node.paint_queued = false
		if !node.active || !node.present { continue }
		rt.stats.paint_nodes_visited += 1
		rt.stats.stage_visits[.Paint] += 1
		paint_count_before := len(node.paint)
		if dirty_has(node.dirty, .Paint) || len(node.paint) == 0 {
			had_backdrop_effect := paint_commands_have_backdrop_effect(node.paint[:])
			field_style := Text_Field_Resolved_Style{}
			checkbox_style := Checkbox_Resolved_Style{}
			slider_style := Slider_Resolved_Style{}
			if node.kind == .Text_Field {
				field_style = style_text_field_resolve_retained(rt, node, Text_Field_Visual_State{
					hovered=node.hovered,
					focused=rt.focused == node.id,
				})
			}
			field_content_bounds := Rect{}
			field_content_clip := node.clip
			field_text_origin := [2]f32{}
			if node.kind == .Text_Field {
				field_content_bounds = text_field_content_bounds(rt, node)
				field_content_clip = rect_intersection(node.clip, field_content_bounds)
				field_text_origin = text_field_run_origin(rt, node, &node.text_run)
			}
			if node.kind == .Checkbox {
				checkbox_style = style_checkbox_resolve_retained(rt, node, Checkbox_Visual_State{
					checked=node.paint_value&1 != 0,
					hovered=node.hovered,
					pressed=node.pressed,
					disabled=node.disabled,
					focused=rt.focused == node.id,
				})
			}
			if node.kind == .Slider {
				slider_style = style_slider_resolve_retained(rt, node, Slider_Visual_State{
					hovered=node.hovered,
					pressed=node.pressed,
					disabled=node.disabled,
					focused=rt.focused == node.id,
				})
			}
			if node.kind == .Text_Field && node.composition.active {
				prepare_text_composition_node(rt, node)
				if node.composition_run_valid {
					field_text_origin = text_field_run_origin(rt, node, &node.composition_run)
				}
			}
			clear(&node.paint)
			if node.kind == .Text_Field {
				append(&node.paint, paint_surface_command(node.id, node.bounds, node.clip, field_style.surface))
			}
			if node.kind == .Text_Field && node.text_run_valid {
				if !node.composition.active {
					selection := text_run_selection_rects(
						&node.text_run,
						node.selection_anchor,
						node.selection_focus,
						allocator=rt.scratch_allocator,
						scratch_allocator=rt.scratch_allocator,
					)
					for selected in selection {
						bounds := selected.rect
						selection_origin := text_field_run_origin(rt, node, &node.text_run)
						bounds.x += selection_origin.x
						bounds.y += selection_origin.y
						append(&node.paint, paint_surface_command(node.id, bounds, field_content_clip, field_style.selection))
						if node.style_environment.accessibility.increased_contrast {
							append_rect_outline_bounds(node, bounds,
								style_environment_color(rt, node.style_environment, .Focus),
								style_structural_border_thickness(node.style_environment))
						}
					}
					delete(selection)
				} else if node.composition_run_valid {
					visual_start := text_composition_visual_start(node)
					preedit_start := visual_start + grapheme_floor_boundary(node.composition.text, node.composition.selection_start)
					preedit_end := visual_start + grapheme_ceil_boundary(node.composition.text, node.composition.selection_end)
					if preedit_start == preedit_end {
						preedit_end = visual_start + len(node.composition.text)
					}
					selection := text_run_selection_rects(
						&node.composition_run,
						Text_Position{preedit_start, .Leading},
						Text_Position{preedit_end, .Trailing},
						allocator=rt.scratch_allocator,
						scratch_allocator=rt.scratch_allocator,
					)
					for selected in selection {
						bounds := selected.rect
						composition_origin := text_field_run_origin(rt, node, &node.composition_run)
						bounds.x += composition_origin.x
						bounds.y += composition_origin.y + bounds.h - 2
						bounds.h = 1
						append(&node.paint, paint_surface_command(node.id, bounds, field_content_clip, style_environment_color(rt, node.style_environment, .Accent)))
					}
					delete(selection)
				}
			}
			if node.kind == .Root || node.kind == .Modal_Overlay || node.kind == .Context_Menu_Overlay || node.kind == .Context_Menu_Panel || node.kind == .Container || node.kind == .Virtual_List || node.kind == .Virtual_Row || node.kind == .Split || node.kind == .Scroll_Region {
				// Layout containers are non-painting unless the caller explicitly
				// supplied a background. This keeps structural wrappers from
				// producing accidental rectangles in the compositor.
				if semantic_surface_style, found := rt.semantic_surfaces[node.id]; found {
					resolved_surface := style_semantic_surface_resolve_retained(rt, node, semantic_surface_style)
					if semantic_surface_style.backdrop_effect.kind == .Blur {
						append(&node.paint, paint_backdrop_effect_command(node.id, node.bounds, node.clip, semantic_surface_style.backdrop_effect))
					}
					if resolved_surface.fill.a > 0 || resolved_surface.gradient.axis != .None || resolved_surface.stroke.width > 0 {
						surface_command := paint_surface_command(
							node.id,
							node.bounds,
							node.clip,
							resolved_surface.fill,
							shape=semantic_surface_style.shape,
							material=semantic_surface_style.material,
							physical_height=semantic_surface_style.physical_height,
							material_group=semantic_surface_style.material_group,
							stroke=resolved_surface.stroke,
							stroke_placement=resolved_surface.stroke_placement,
							top_edge_gap=semantic_surface_top_edge_gap(rt, node, semantic_surface_style),
						)
						surface_command.semantic_surface_gradient = resolved_surface.gradient.axis != .None
						surface_command.semantic_surface_fill = true
						append(&node.paint, surface_command)
					}
				} else if node.paint_background {
					append(&node.paint, paint_surface_command(node.id, node.bounds, node.clip, node.color))
				}
				append_visual_row_background(rt, node)
				if node.kind == .Context_Menu_Panel {
					append_rect_outline(node, style_environment_color(rt, node.style_environment, .Border), style_structural_border_thickness(node.style_environment))
				}
				if node.kind == .Scroll_Region && rt.scroll_focus_visuals[node.id] == .Outline && semantic_focus_owner_needs_outline(rt, node.id) {
					append_focus_outline(node, style_environment_color(rt, node.style_environment, .Focus), style_focus_indicator_thickness(node.style_environment))
				}
				if node.icon_id != .None {
					append(&node.paint, paint_icon_command(node.id, node.bounds, node.clip, node.icon_id, node.color))
				}
			} else if node.kind == .Button && node.button_presentation == .Default {
				padding_x := maxf(node.button_content_style.padding_x, 0)
				padding_y := maxf(node.button_content_style.padding_y, 0)
				content_bounds := Rect{
					node.bounds.x + padding_x,
					node.bounds.y + padding_y,
					maxf(node.bounds.w - 2*padding_x, 0),
					maxf(node.bounds.h - 2*padding_y, 0),
				}
				text_bounds := content_bounds
				if node.icon_id != .None { text_bounds.w = maxf(text_bounds.w-ICON_TRAILING_SLOT_WIDTH, 0) }
				if node.text_run_valid {
					#partial switch node.button_content_style.horizontal {
					case .Center:
						text_bounds.x += (text_bounds.w-node.text_run.width)/2
					case .End:
						text_bounds.x += text_bounds.w-node.text_run.width
					}
					#partial switch node.button_content_style.vertical {
					case .Center:
						text_bounds.y += (content_bounds.h-node.text_run.height)/2
					case .End:
						text_bounds.y += content_bounds.h-node.text_run.height
					}
				}
				text_clip := rect_intersection(node.clip, content_bounds)
				text_color := style_environment_color(rt, node.style_environment, .Text)
				connected_style, connected := rt.semantic_surfaces[node.id]
				connected = connected && connected_style.shape.kind == .Connected_Tab
				selected_connected := connected && node.selected
				parent_is_context_menu := false
				if parent, ok := rt.nodes[node.parent]; ok {
					parent_is_context_menu = parent.kind == .Context_Menu_Panel
				}
				close_tab, show_dirty_marker := tab_close_owner(rt, node)
				if close_tab != nil {
					style_transition_owner_cancel(rt, node.id)
					tab_close_append_paint(rt, node, close_tab, show_dirty_marker)
				} else if parent_is_context_menu {
					style_transition_owner_cancel(rt, node.id)
					// Menu navigation and pointer hover share the menu's active-row
					// highlight. Ordinary buttons still receive their independent
					// focus outline below.
					resolved_style := style_button_resolve_retained(rt, node, Button_Visual_State{
						selected=node.selected,
						hovered=node.hovered || rt.focused == node.id,
						pressed=node.pressed,
						disabled=node.disabled,
					})
					text_color = resolved_style.text
					if resolved_style.surface.a > 0 {
						append(&node.paint, paint_surface_command(node.id, node.bounds, node.clip, resolved_style.surface, shape=resolved_style.shape, material=resolved_style.material, physical_height=resolved_style.physical_height))
					}
				} else {
					hovered := visual_part_owner_hovered(rt, node.id)
					resolved_style := style_button_resolve_retained(rt, node, Button_Visual_State{
						selected=node.selected,
						hovered=hovered,
						pressed=node.pressed,
						disabled=node.disabled,
					}, node.drop_position == .On)
					if !connected {
						resolved_style.surface = style_transition_button_fill(rt, node, resolved_style, hovered)
					}
					text_color = resolved_style.text
					if connected {
						style_transition_owner_cancel(rt, node.id)
						connected_fill, connected_text := connected_tab_visual_colors(
							rt, node, resolved_style, hovered, node.pressed, node.drop_position == .On,
						)
						text_color = connected_text
						decoration_bounds := connected_tab_visual_bounds(node.bounds, node.selected)
						append(&node.paint, paint_surface_command(node.id, decoration_bounds, node.clip, connected_fill, shape=connected_style.shape))
					} else if resolved_style.surface.a > 0 {
						append(&node.paint, paint_surface_command(node.id, node.bounds, node.clip, resolved_style.surface, shape=resolved_style.shape, material=resolved_style.material, physical_height=resolved_style.physical_height))
					}
					if resolved_style.selected_indicator == .Underline && !visual_part_owner_has_role(rt, node.id, .Selected_Indicator) {
						indicator_height := minf(2, node.bounds.h)
						indicator := Rect{node.bounds.x, node.bounds.y+node.bounds.h-indicator_height, node.bounds.w, indicator_height}
						append(&node.paint, paint_surface_command(node.id, indicator, node.clip, resolved_style.selected_indicator_color))
					}
					if node.semantic_active { append_focus_outline(node, resolved_style.semantic_active, style_structural_border_thickness(node.style_environment), resolved_style.shape) }
					if selected_connected && (node.style_environment.accessibility.increased_contrast || node.style_environment.accessibility.differentiate_without_color) {
						// Keep a non-color selection cue above the seam rather than
						// reinstating the underline across the paper connection.
						marker := Rect{node.bounds.x+24, node.bounds.y+5, maxf(node.bounds.w-48, 0), 2}
						append(&node.paint, paint_surface_command(node.id, marker, node.clip, resolved_style.selected_indicator_color))
					}
					show_focus := resolved_style.focus_indicator_mode == .Always || rt.focus_visible
					if show_focus && rt.focused == node.id && !node.disabled {
						// Focus is an independent outline so it remains visible without
						// replacing the selected, hover, or pressed fill.
						append_focus_outline(node, resolved_style.focus, style_focus_indicator_thickness(node.style_environment), resolved_style.shape)
					}
				}
				if len(node.label) > 0 {
					append(&node.paint, paint_text_command(node.id, text_bounds, text_clip, paint_text_handle_for_node(node), text_color))
				}
				if node.icon_id != .None && close_tab == nil {
					icon_size := minf(16, maxf(content_bounds.h-4, 10))
					icon_x := node.bounds.x+node.bounds.w-padding_x-icon_size
					if len(node.label) == 0 { icon_x = node.bounds.x+(node.bounds.w-icon_size)*0.5 }
					icon_bounds := Rect{
						icon_x,
						node.bounds.y+(node.bounds.h-icon_size)*0.5,
						icon_size,
						icon_size,
					}
					append(&node.paint, paint_icon_command(node.id, icon_bounds, node.clip, node.icon_id, text_color))
				}
			} else if node.kind == .Button {
				// Custom-presentation Buttons retain interaction and semantics but
				// own no paint. Their described children provide the full visual.
				style_transition_owner_cancel(rt, node.id)
			} else if node.kind == .Checkbox {
				box_size := minf(18, maxf(node.bounds.h-6, 12))
				box := Rect{node.bounds.x+4, node.bounds.y+(node.bounds.h-box_size)*0.5, box_size, box_size}
				append(&node.paint, paint_surface_command(node.id, box, node.clip, checkbox_style.box.border))
				inner := Rect{box.x+2, box.y+2, maxf(box.w-4, 0), maxf(box.h-4, 0)}
				append(&node.paint, paint_surface_command(node.id, inner, node.clip, checkbox_style.box.surface))
				if node.paint_value&1 != 0 {
					check_color := checkbox_style.checkmark.text
					mark_bounds := Rect{box.x+3, box.y+3, maxf(box.w-6, 0), maxf(box.h-6, 0)}
					append(&node.paint, paint_icon_command(node.id, mark_bounds, node.clip, .Check, check_color))
				}
				show_focus := checkbox_style.focus_indicator_mode == .Always || rt.focus_visible
				if checkbox_style.focused && show_focus && !checkbox_style.disabled {
					append_focus_outline(node, checkbox_style.focus, style_focus_indicator_thickness(node.style_environment))
				}
				text_bounds := Rect{node.bounds.x+30, node.bounds.y, maxf(node.bounds.w-34, 0), node.bounds.h}
				if node.text_run_valid { text_bounds.y += (text_bounds.h-node.text_run.height)*0.5 }
				append(&node.paint, paint_text_command(node.id, text_bounds, rect_intersection(node.clip, text_bounds), paint_text_handle_for_node(node), checkbox_style.label.text))
			} else if node.kind == .Slider {
				label_bounds := Rect{node.bounds.x+8, node.bounds.y+1, maxf(node.bounds.w-16, 0), minf(maxf(node.bounds.h-14, 0), node.text_run.height)}
				append(&node.paint, paint_text_command(node.id, label_bounds, rect_intersection(node.clip, label_bounds), paint_text_handle_for_node(node), slider_style.label.text))
				track_x := node.bounds.x + minf(8, node.bounds.w*0.25)
				track_width := maxf(node.bounds.w-minf(16, node.bounds.w*0.5), 1)
				track_y := node.bounds.y + node.bounds.h - 8
				track := Rect{track_x, track_y-2, track_width, 4}
				fraction: f32 = 0
				if node.control_maximum > node.control_minimum {
					fraction = clampf((node.control_value-node.control_minimum)/(node.control_maximum-node.control_minimum), 0, 1)
				}
				thumb_x := track_x + fraction*track_width
				thumb := Rect{thumb_x-5, track_y-6, 10, 12}
				append(&node.paint,
					paint_surface_command(node.id, track, node.clip, slider_style.track.surface),
					paint_surface_command(node.id, Rect{track_x, track_y-2, maxf(thumb_x-track_x, 0), 4}, node.clip, slider_style.fill.surface),
					paint_surface_command(node.id, thumb, node.clip, slider_style.thumb.surface),
				)
				append_rect_outline_bounds(node, thumb, slider_style.thumb.border, 1)
				show_focus := slider_style.focus_indicator_mode == .Always || rt.focus_visible
				if slider_style.focused && show_focus && !slider_style.disabled {
					append_focus_outline(node, slider_style.focus, style_focus_indicator_thickness(node.style_environment))
				}
			} else if node.kind == .Split_Handle {
				handle_color := Color{0.20, 0.24, 0.31, 1}
				if node.hovered { handle_color = Color{0.35, 0.53, 0.72, 1} }
				if node.pressed { handle_color = Color{0.42, 0.66, 0.90, 1} }
				append(&node.paint, paint_surface_command(node.id, node.bounds, node.clip, handle_color))
			} else if node.kind == .Custom_Surface {
				// Waveforms retain their backing surface as an ordinary paint
				// primitive. Image layers paint above that background and below
				// app-authored geometry; geometry remains transparent unless it
				// supplies fills.
				if node.surface_kind == .Waveform {
					append(&node.paint, paint_surface_command(node.id, node.bounds, node.clip, Color{0.08, 0.14, 0.24, 1}))
				}
				if layers, found := rt.gpu_surface_images[node.id]; found {
					surface_clip := rect_intersection(node.clip, node.bounds)
					for layer in layers {
						if _, image_ok := image_resolve(rt, layer.image); !image_ok { continue }
						bounds := Rect{node.bounds.x+layer.bounds.x, node.bounds.y+layer.bounds.y, layer.bounds.w, layer.bounds.h}
						clip := rect_intersection(surface_clip, bounds)
						if clip.w <= 0 || clip.h <= 0 { continue }
						append(&node.paint, paint_image_command(node.id, bounds, clip, layer.image, opacity=layer.opacity))
					}
				}
				append(&node.paint, paint_geometry_command(node.id, node.bounds, node.clip, paint_geometry_handle_for_node(node)))
			} else if node.kind == .Image {
				image_handle := Image_Handle(node.paint_value)
				if _, image_ok := image_resolve(rt, image_handle); image_ok {
					append(&node.paint, paint_image_command(node.id, node.bounds, node.clip, image_handle))
				}
			} else {
				text_clip := node.clip
				text_bounds := node.bounds
				if node.kind == .Text_Field {
					text_bounds = Rect{field_text_origin.x, field_text_origin.y, field_content_bounds.w, field_content_bounds.h}
					text_clip = field_content_clip
				} else if node.text_style.overflow != .Wrap {
					text_clip = rect_intersection(node.clip, node.bounds)
				}
				paint_geometry := Text_Paint_Geometry{}
				if node.kind == .Text && node.text_run_valid && text_paint_geometry_needed(node) {
					paint_geometry = text_paint_geometry_make(&node.text_run, rt.scratch_allocator)
				}
				append_text_paint_geometry(node, &paint_geometry, text_clip, true)
				if node.kind == .Text && node.text_interaction && node.text_run_valid {
					single_line_background_height: f32
					if node.text_selection_background == .Fill_Node_When_Single_Line {
						single_line_background_height = node.bounds.h
					}
					selection := text_run_selection_rects(
						&node.text_run,
						node.text_interaction_anchor,
						node.text_interaction_focus,
						allocator=rt.scratch_allocator,
						scratch_allocator=rt.scratch_allocator,
						single_line_background_height=single_line_background_height,
					)
					for selected in selection {
						bounds := selected.rect
						bounds.x += node.bounds.x
						bounds.y += node.bounds.y
						append(&node.paint, paint_surface_command(node.id, bounds, text_clip, style_environment_color(rt, node.style_environment, .Selection)))
					}
					delete(selection)
				}
				text_run_handle := paint_text_handle_for_node(node)
				if node.kind == .Text_Field && node.composition.active && node.composition_run_valid {
					text_run_handle = paint_text_handle_for_composition(node)
				}
				text_color := node.color
				if node.kind == .Text_Field {
					text_color = field_style.text
				} else if node.kind == .Text {
					if part_color, found := visual_part_label_color(rt, node.id); found {
						text_color = part_color
					}
				}
				append(&node.paint, paint_text_command(node.id, text_bounds, text_clip, text_run_handle, text_color, node.text_paint_spans[:]))
				append_text_paint_geometry(node, &paint_geometry, text_clip, false)
				text_paint_geometry_destroy(&paint_geometry)
			}
			if node.kind == .Text && node.text_interaction && node.text_interaction_show_caret && node.text_run_valid {
				caret := text_node_caret_geometry(rt, node.id, node.text_interaction_focus)
				if caret.valid {
					// A caret belongs to a text boundary, which can sit just beyond the
					// glyph extent. Clip it by the containing viewport.
					append(&node.paint, paint_surface_command(node.id, caret.rect, node.clip, style_environment_color(rt, node.style_environment, .Accent)))
				}
			}
			if node.kind == .Text_Field && rt.focused == node.id {
				caret := text_field_caret_geometry(rt, node.id)
				if caret.valid {
					append(&node.paint, paint_surface_command(node.id, caret.rect, field_content_clip, field_style.caret))
				}
			}
			if node.kind == .Text_Field {
				append_rect_outline(node, field_style.border, style_structural_border_thickness(node.style_environment))
				if field_style.focused { append_focus_outline(node, field_style.focus, style_focus_indicator_thickness(node.style_environment)) }
			}
			if node.drop_position == .On {
				append(&node.paint, paint_surface_command(node.id, node.bounds, node.clip, style_environment_color(rt, node.style_environment, .Success)))
			} else if node.drop_position == .Before || node.drop_position == .After {
				marker := Rect{}
				if node.drop_target_mode == .Between_Horizontal {
					marker_edge := node.bounds.x if node.drop_position == .Before else node.bounds.x+node.bounds.w
					marker = Rect{marker_edge-1.5, node.bounds.y+2, 3, maxf(node.bounds.h-4, 0)}
					halo := Rect{marker_edge-3.5, node.bounds.y+2, 7, maxf(node.bounds.h-4, 0)}
					halo_color := style_environment_color(rt, node.style_environment, .Accent)
					halo_color.a *= 0.24
					append(&node.paint, paint_surface_command(node.id, halo, node.clip, halo_color))
				} else {
					marker_y := node.bounds.y if node.drop_position == .Before else node.bounds.y+node.bounds.h-2
					marker = Rect{node.bounds.x+2, marker_y, maxf(node.bounds.w-4, 0), 2}
				}
				append(&node.paint, paint_surface_command(node.id, marker, node.clip, style_environment_color(rt, node.style_environment, .Accent)))
			}
			if node.placement.valid && node.placement.opacity != 1 {
				// Positioned opacity applies to every product the child emits,
				// including span backgrounds and decorations. Renderers already
				// consume Paint_Command.opacity for ordinary text commands.
				for &command in node.paint {
					command.opacity *= node.placement.opacity
				}
			}
			rt.stats.paint_updates += 1
			frontier_note_changed(rt, .Paint, id)
			has_backdrop_effect := paint_commands_have_backdrop_effect(node.paint[:])
			if has_backdrop_effect != had_backdrop_effect {
				if has_backdrop_effect { rt.retained_backdrop_effect_nodes += 1 }
				else if rt.retained_backdrop_effect_nodes > 0 { rt.retained_backdrop_effect_nodes -= 1 }
			}
			dirty_set(&node.dirty, .Composite, true)
			record_trace(rt, .Paint, id, node.last_reason)
		}
		if node.kind != .Scroll_Region && node.display_index < 0 && paint_count_before == 0 && len(node.paint) == 0 {
			// The node contributed no display commands before or after this
			// repaint (for example a non-painting layout container). Its
			// descendants keep their own ranges, so there is nothing to
			// finalize and no structure change to rebuild.
		} else if !rt.composition_rebuild && node.kind != .Scroll_Region &&
			(node.display_index >= 0 || paint_count_before == 0) {
			if paint_sparse_finalize_range(rt, node) {
				rt.stats.composition_nodes_visited += 1
				rt.stats.stage_visits[.Composite] += 1
				rt.stats.composite_updates += 1
				frontier_note_changed(rt, .Composite, id)
				record_trace(rt, .Composite, id, "retained display commands updated and finalized")
			} else {
				rt.stats.global_fallbacks += 1
				rt.stats.global_work_by_reason[.Display_Incremental_Fallback] += 1
				rt.composition_rebuild = true
				record_trace(rt, .Composite, id, "retained display range changed; full rebuild required")
			}
		} else {
			rt.composition_rebuild = true
		}
		dirty_set(&node.dirty, .Description, false)
		dirty_set(&node.dirty, .Paint, false)
		dirty_set(&node.dirty, .Composite, false)
	}
	clear(&rt.paint_queue)
	perf_add_mark(rt, .Paint, paint_mark)
	if rt.composition_rebuild {
		compose_mark := perf_mark_begin()
		rebuild_display(rt)
		perf_add_mark(rt, .Composition, compose_mark)
	}
	// The optional lighting boundary is a paint-stream product: it is placed
	// after this stage's display list is final. With no declaration (and no
	// carried marker) this is one boolean test.
	lighting_publish(rt)
}
