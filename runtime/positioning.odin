package alicorn

import "core:fmt"
import "core:math"

// Positioned children are ordinary retained nodes whose owner-local placement
// is authored explicitly instead of consuming flow space. They reuse the same
// measurement, text shaping, paint commands, clipping, and semantic products as
// ordinary children; this file adds placement only.
//
// Coordinates are logical units relative to the owner's content box (its
// bounds inset by its padding). A typical visualization owner keeps padding at
// zero, so placement shares the same origin as a full-bleed custom surface's
// surface-local geometry.
//
// Positioned children do not contribute to a fit-content owner's measured
// size. Give such an owner a definite width/height (or keep flow content in it)
// instead of relying on its positioned labels to size it.

Positioned_Horizontal :: enum u8 {
	Start,
	Center,
	End,
}

Positioned_Vertical :: enum u8 {
	Top,
	Middle,
	Bottom,
	// Baseline anchors the child's measured text baseline. A child without a
	// retained baseline product falls back to its bottom edge, matching the Row
	// baseline convention for non-text visuals.
	Baseline,
}

// Positioned_Placement is compact retained placement data. A child's own
// Layout_Style still owns width, height, min/max sizing, and clipping inputs;
// placement adds only the owner-local anchor and paint policy. opacity applies
// to every paint command the child emits.
Positioned_Placement :: struct {
	x, y: f32,
	opacity: f32,
	horizontal: Positioned_Horizontal,
	vertical: Positioned_Vertical,
	clip: bool,
	valid: bool,
}

// positioned is the authoring constructor for Positioned_Placement. The
// animation/pan/zoom owner supplies x and y in its own logical space; Alicorn
// does not interpret them.
positioned :: proc(
	x, y: f32,
	horizontal := Positioned_Horizontal.Start,
	vertical := Positioned_Vertical.Top,
	clip := false,
	opacity: f32 = 1,
) -> Positioned_Placement {
	return Positioned_Placement{
		x=x,
		y=y,
		opacity=opacity,
		horizontal=horizontal,
		vertical=vertical,
		clip=clip,
		valid=true,
	}
}

positioned_placement_is_valid :: proc(placement: Positioned_Placement) -> bool {
	if !placement.valid { return false }
	if math.is_nan(placement.x) || math.is_inf(placement.x) ||
	   math.is_nan(placement.y) || math.is_inf(placement.y) {
		return false
	}
	if math.is_nan(placement.opacity) || math.is_inf(placement.opacity) ||
	   placement.opacity < 0 || placement.opacity > 1 {
		return false
	}
	if placement.horizontal != .Start && placement.horizontal != .Center && placement.horizontal != .End {
		return false
	}
	if placement.vertical != .Top && placement.vertical != .Middle &&
	   placement.vertical != .Bottom && placement.vertical != .Baseline {
		return false
	}
	return true
}

// position_child marks an already-described direct child as positioned within
// its owner. Call it after describing the child, like semantic_static_text and
// text_input_target. The child's own style may still set sizing and clipping;
// placement supplies the owner-local anchor and alignment.
position_child :: proc(
	ui: ^UI,
	id: Node_ID,
	placement: Positioned_Placement,
	loc := #caller_location,
) -> bool {
	rt := ui != nil ? ui.runtime : nil
	if rt == nil || !rt.frame_open || id == 0 {
		if rt != nil {
			append_diagnostic(rt, fmt.tprintf(
				"position_child requires an open frame and a live child (%s:%d:%d)",
				loc.file_path, loc.line, loc.column,
			))
		}
		return false
	}
	if !positioned_placement_is_valid(placement) {
		append_diagnostic(rt, fmt.tprintf(
			"position_child received a nonfinite, out-of-range, or unsupported placement (%s:%d:%d)",
			loc.file_path, loc.line, loc.column,
		))
		return false
	}
	for i := len(rt.pending)-1; i >= 0; i -= 1 {
		item := &rt.pending[i]
		if item.kind != .Description || item.description.id != id { continue }
		if item.description.parent == 0 || item.description.kind == .Root {
			append_diagnostic(rt, fmt.tprintf(
				"position_child requires a non-root child; node %d has no ordinary owner (%s:%d:%d)",
				id, loc.file_path, loc.line, loc.column,
			))
			return false
		}
		item.description.placement = placement
		return true
	}
	append_diagnostic(rt, fmt.tprintf(
		"position_child references node %d that was not emitted in the current frame (%s:%d:%d)",
		id, loc.file_path, loc.line, loc.column,
	))
	return false
}

hash_positioned_layout :: proc(placement: Positioned_Placement) -> u64 {
	if !placement.valid { return 0 }
	h: u64 = 1469598103934665603
	h = hash_mix(h, u64(transmute(u32)placement.x))
	h = hash_mix(h, u64(transmute(u32)placement.y))
	h = hash_mix(h, u64(placement.horizontal))
	h = hash_mix(h, u64(placement.vertical))
	h = hash_mix(h, u64(placement.clip ? 1 : 0))
	return h
}

// hash_positioned_placement adds paint-only placement inputs on top of the
// layout fingerprint. Opacity changes repaint without invalidating placement.
hash_positioned_placement :: proc(placement: Positioned_Placement) -> u64 {
	if !placement.valid { return 0 }
	h := hash_positioned_layout(placement)
	h = hash_mix(h, u64(transmute(u32)placement.opacity))
	return h
}

layout_parent_supports_positioned_children :: proc(parent: ^Node) -> bool {
	if parent == nil { return false }
	#partial switch parent.kind {
	case .Context_Menu_Overlay, .Grid:
		return false
	}
	if parent.kind == .Split && len(parent.children) == 3 { return false }
	if parent.adaptive_owner { return false }
	return true
}

parent_has_positioned_children :: proc(rt: ^Runtime, children: []Node_ID) -> bool {
	if rt == nil { return false }
	for id in children {
		if child, ok := rt.nodes[id]; ok && child != nil && child.placement.valid { return true }
	}
	return false
}

// layout_positioned_children resolves explicit owner-local placement. It is
// the positioned sibling of the ordinary flow loop in layout_children: the
// same measurement, finalization, semantic sync, dirtying, and recursion apply.
layout_positioned_children :: proc(rt: ^Runtime, parent: ^Node, inner: Rect, children: []Node_ID) {
	if rt == nil || parent == nil { return }
	for id in children {
		child, found := rt.nodes[id]
		if !found || child == nil || !child.active || !child.placement.valid { continue }
		placement := child.placement
		layout_note_node_visit(rt, child)

		// A label is measured at its natural width unless its own Layout_Style
		// supplies a hard box, wrap limit, or ellipsis constraint. The existing
		// measure path already reads those inputs.
		constraints := Layout_Constraints{
			width=layout_axis_constraint_normalize(0, -1),
			height=layout_axis_constraint_normalize(0, -1),
		}
		// An unconstrained label must shape at its natural width even if an
		// earlier explicit box produced a wrapped run.
		measured := layout_measure_node(rt, child, constraints, force_unbounded_text_shape=true)
		state := rt.measure_states[id]
		// The owner's fit-content size never depends on positioned children.
		state.parent_size_dependencies = {}
		rt.measure_states[id] = state

		width := layout_unit_to_f32(measured.size.width)
		height := layout_unit_to_f32(measured.size.height)
		baseline := height
		if measured.baseline_valid { baseline = layout_unit_to_f32(measured.baseline) }

		anchor_x := layout_unit_to_f32(layout_unit_position(inner.x)+layout_unit_position(placement.x))
		anchor_y := layout_unit_to_f32(layout_unit_position(inner.y)+layout_unit_position(placement.y))
		left := anchor_x
		#partial switch placement.horizontal {
		case .Center: left -= width*0.5
		case .End: left -= width
		}
		top := anchor_y
		#partial switch placement.vertical {
		case .Middle: top -= height*0.5
		case .Bottom: top -= height
		case .Baseline: top -= baseline
		}

		old_bounds := child.bounds
		old_clip := child.clip
		child.bounds = Rect{left, top, maxf(width, 0), maxf(height, 0)}
		child.hit_bounds = child.bounds
		// Positioned children inherit the owner's effective clip exactly like
		// flow children. clip=true additionally clips to the owner's rectangle.
		child.clip = parent.clip
		if parent.kind == .Scroll_Region {
			child.clip = rect_intersection(parent.clip, parent.scroll_viewport_bounds)
		} else if parent.style.clip {
			child.clip = rect_intersection(parent.clip, parent.bounds)
		}
		if placement.clip {
			child.clip = rect_intersection(child.clip, parent.bounds)
		}
		layout_finalize_node_geometry_for_node(rt, child)
		semantic_sync_bounds(rt, child)
		bounds_changed := !rect_equal(old_bounds, child.bounds)
		clip_changed := !rect_equal(old_clip, child.clip)
		if bounds_changed && child.kind == .Custom_Surface && child.surface_kind == .Geometry &&
		   (old_bounds.w != child.bounds.w || old_bounds.h != child.bounds.h) {
			// Geometry payload coordinates are surface-local; a changed extent
			// needs one app description rebuild to regenerate its projection.
			rt.geometry_surface_bounds_changed = true
		}
		if bounds_changed && child.kind == .Scroll_Region {
			rt.scroll_geometry_changed = true
		}
		if bounds_changed || clip_changed {
			dirty_set(&child.dirty, .Layout, true)
			dirty_set(&child.dirty, .Paint, true)
			dirty_set(&child.dirty, .Composite, true)
			queue_paint(rt, id)
			rt.stats.layout_updates += 1
			frontier_note_changed(rt, .Layout, child.id)
			record_trace(rt, .Layout, id, "positioned child bounds changed")
		} else if dirty_has(child.dirty, .Layout) {
			rt.stats.layout_updates += 1
			frontier_note_changed(rt, .Layout, child.id)
			record_trace(rt, .Layout, id, "positioned child layout hash changed")
		}
		if bounds_changed || clip_changed || dirty_has(child.dirty, .Layout) {
			layout_children(rt, id)
		}
		dirty_set(&child.dirty, .Layout, false)
	}
}
