package alicorn

import "core:fmt"
import "core:strings"

stage_word :: proc(value: bool) -> string {
	if value { return "changed" }
	return "reused"
}

style_control_state_name :: proc(state: Style_Control_State) -> string {
	switch state {
	case .Selected: return "selected"
	case .Hovered: return "hovered"
	case .Pressed: return "pressed"
	case .Disabled: return "disabled"
	}
	return "unknown"
}

style_inspector_token_role :: proc(
	sb: ^strings.Builder,
	rt: ^Runtime,
	theme: Style_Theme_ID,
	property, source: string,
	role: Style_Color_Role,
	accent: Style_Accent = 0,
) {
	if role == .Accent && accent != 0 {
		fmt.sbprintf(sb, " %s.%s=%v(environment accent=%d)", property, source, role, u32(accent))
		return
	}
	token := style_theme_color_token(rt, theme, role)
	fmt.sbprintf(sb, " %s.%s=%v", property, source, role)
	if token != 0 {
		fmt.sbprintf(sb, "(token=%d)", u32(token))
		style_inspector_color_token_chain(sb, rt, theme, token)
	}
}

style_inspector_color_token_chain :: proc(sb: ^strings.Builder, rt: ^Runtime, theme: Style_Theme_ID, token: Style_Color_Token_ID) {
	current := token
	first := true
	theme_index := u64(u32(theme))
	if rt == nil || theme_index == 0 || theme_index > u64(len(rt.style_themes)) { return }
	metadata := rt.style_themes[theme_index-1].color_token_provenance
	for _ in 0..<len(metadata) {
		provenance, found := style_token_provenance(rt, theme, current)
		if !found { break }
		if first {
			fmt.sbprintf(sb, " provenance=[%s", provenance.name)
			first = false
		}
		if provenance.alias_target == "" { break }
		fmt.sbprintf(sb, " -> %s", provenance.alias_target)
		next := Style_Color_Token_ID(0)
		for candidate, index in metadata {
			if candidate.name == provenance.alias_target {
				next = Style_Color_Token_ID(index+1)
				break
			}
		}
		if next == 0 { break }
		current = next
	}
	if !first { fmt.sbprintf(sb, "]") }
}

style_inspector_transform_provenance :: proc(
	sb: ^strings.Builder,
	rt: ^Runtime,
	theme: Style_Theme_ID,
	source: string,
	transform: Style_Transform,
	accent: Style_Accent = 0,
) {
	if transform.surface_mix > 0 { style_inspector_token_role(sb, rt, theme, "surface", source, transform.surface_role, accent) }
	if transform.text_mix > 0 { style_inspector_token_role(sb, rt, theme, "text", source, transform.text_role, accent) }
}

style_inspector_control_transform_provenance :: proc(
	sb: ^strings.Builder,
	rt: ^Runtime,
	theme: Style_Theme_ID,
	source: string,
	transform: Control_Part_Transform,
	accent: Style_Accent = 0,
) {
	if transform.surface_mix > 0 { style_inspector_token_role(sb, rt, theme, "surface", source, transform.surface_role, accent) }
	if transform.text_mix > 0 { style_inspector_token_role(sb, rt, theme, "text", source, transform.text_role, accent) }
	if transform.border_mix > 0 { style_inspector_token_role(sb, rt, theme, "border", source, transform.border_role, accent) }
}

style_inspector_surface_shape_name :: proc(kind: Surface_Shape_Kind) -> string {
	switch kind {
	case .Rectangle: return "rectangle"
	case .Rounded_Rectangle: return "rounded-rectangle"
	case .Line: return "line"
	case .Connected_Tab: return "connected-tab-contour"
	case .Rounded_Rectangle_Per_Corner: return "rounded-rectangle-per-corner"
	case .Circle: return "circle"
	case .Arc: return "arc"
	case .Cubic_Bezier: return "cubic-bezier"
	}
	return "unknown"
}

style_inspector_material_kind_name :: proc(kind: Style_Material_Kind) -> string {
	switch kind {
	case .Flat: return "flat"
	case .Analytic_Relief: return "analytic-relief"
	}
	return "unknown"
}

style_inspector_surface_role :: proc(sb: ^strings.Builder, rt: ^Runtime, theme: Style_Theme_ID, role: Semantic_Surface_Color_Role) {
	switch value in role {
	case Style_Color_Role:
		fmt.sbprintf(sb, "role=core.%v", value)
		if token := style_theme_color_token(rt, theme, value); token != 0 {
			fmt.sbprintf(sb, " token=%d", u32(token))
		}
	case Style_Extension_Color_Role_ID:
		name, named := style_extension_color_role_name(rt, theme, value)
		if named { fmt.sbprintf(sb, "role=%s", name) } else { fmt.sbprintf(sb, "role=extension.%d", u64(value)) }
		if token, found := style_extension_color_token(rt, theme, value); found {
			fmt.sbprintf(sb, " token=%d", u32(token))
			style_inspector_color_token_chain(sb, rt, theme, token)
		}
	}
}

style_inspector_text_field_provenance :: proc(sb: ^strings.Builder, rt: ^Runtime, node: ^Node) {
	if rt == nil || node == nil { return }
	environment := node.style_environment
	recipe := style_text_field_recipe(rt, environment)
	state := Text_Field_Visual_State{hovered=node.hovered, focused=rt.focused == node.id}
	_ = style_text_field_resolve_retained(rt, node, state)
	computed, cached := rt.computed_styles[node.id]
	if !cached { return }
	fmt.sbprintf(sb, "  text field style: recipe=text_field.default resolution=retained-cache state=(hovered=%t focused=%t) dependencies=paint generations=(paint=%d)\n",
		state.hovered, state.focused, computed.generations.paint)
	fmt.sbprintf(sb, "  token provenance: text_field.default")
	style_inspector_token_role(sb, rt, environment.theme, "surface", "base", recipe.surface_role, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "text", "base", recipe.text_role, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "border", "base", recipe.border_role, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "focus-border", "focused", recipe.focused_border_role, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "focus", "overlay", recipe.focus_role, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "selection", "base", recipe.selection_role, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "caret", "base", recipe.caret_role, environment.accent)
	if state.hovered { style_inspector_control_transform_provenance(sb, rt, environment.theme, "hovered", recipe.hovered, environment.accent) }
	fmt.sbprintln(sb)
}

style_inspector_scrollbar_provenance :: proc(sb: ^strings.Builder, rt: ^Runtime, node: ^Node) {
	if rt == nil || node == nil { return }
	environment := node.style_environment
	recipe := style_scrollbar_recipe(rt, environment)
	state := Scrollbar_Visual_State{hovered=node.hovered, pressed=rt.scrollbar_drag_node == node.id}
	_ = style_scrollbar_resolve_retained(rt, node, state)
	computed, cached := rt.computed_styles[node.id]
	if !cached { return }
	fmt.sbprintf(sb, "  scrollbar style: recipe=scrollbar.default resolution=retained-cache state=(hovered=%t pressed=%t) dependencies=paint generations=(paint=%d)\n",
		state.hovered, state.pressed, computed.generations.paint)
	fmt.sbprintf(sb, "  token provenance: scrollbar.default")
	style_inspector_token_role(sb, rt, environment.theme, "track", "base", recipe.track_role, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "thumb", "base", recipe.thumb_role, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "corner", "base", recipe.corner_role, environment.accent)
	if state.hovered { style_inspector_token_role(sb, rt, environment.theme, "thumb", "hovered", recipe.hovered_thumb.role, environment.accent) }
	if state.pressed { style_inspector_token_role(sb, rt, environment.theme, "thumb", "pressed", recipe.pressed_thumb.role, environment.accent) }
	fmt.sbprintln(sb)
}

style_inspector_control_part_recipe :: proc(
	sb: ^strings.Builder,
	rt: ^Runtime,
	theme: Style_Theme_ID,
	name: string,
	recipe: Control_Part_Recipe,
	state: Control_Visual_State,
	accent: Style_Accent,
) {
	fmt.sbprintf(sb, "\n  %s", name)
	style_inspector_token_role(sb, rt, theme, "surface", "base", recipe.surface_role, accent)
	style_inspector_token_role(sb, rt, theme, "text", "base", recipe.text_role, accent)
	style_inspector_token_role(sb, rt, theme, "border", "base", recipe.border_role, accent)
	if state.selected { style_inspector_control_transform_provenance(sb, rt, theme, "selected", recipe.selected, accent) }
	if state.hovered { style_inspector_control_transform_provenance(sb, rt, theme, "hovered", recipe.hovered, accent) }
	if state.pressed { style_inspector_control_transform_provenance(sb, rt, theme, "pressed", recipe.pressed, accent) }
	if state.disabled { style_inspector_control_transform_provenance(sb, rt, theme, "disabled", recipe.disabled, accent) }
}

style_inspector_checkbox_provenance :: proc(sb: ^strings.Builder, rt: ^Runtime, node: ^Node) {
	if rt == nil || node == nil { return }
	environment := node.style_environment
	state := Checkbox_Visual_State{
		checked=node.paint_value&1 != 0,
		hovered=node.hovered,
		pressed=node.pressed,
		disabled=node.disabled,
		focused=rt.focused == node.id,
	}
	recipe := style_checkbox_recipe(rt, environment)
	resolved := style_checkbox_resolve_retained(rt, node, state)
	computed, cached := rt.computed_styles[node.id]
	if !cached { return }
	fmt.sbprintf(sb, "  checkbox style: recipe=checkbox.default resolution=retained-cache state=(checked=%t hovered=%t pressed=%t disabled=%t focused=%t) applied=",
		state.checked, state.hovered, state.pressed, state.disabled, state.focused)
	first := true
	for transform in Style_Control_State {
		if transform not_in resolved.applied_transforms { continue }
		if !first { fmt.sbprintf(sb, ",") }
		fmt.sbprintf(sb, "%s", style_control_state_name(transform))
		first = false
	}
	fmt.sbprintf(sb, " focus-mode=%s dependencies=paint generations=(paint=%d)\n  token provenance: checkbox.default",
		focus_indicator_mode_name(resolved.focus_indicator_mode), computed.generations.paint)
	style_inspector_control_part_recipe(sb, rt, environment.theme, "box", recipe.box,
		Control_Visual_State{selected=state.checked, hovered=state.hovered, pressed=state.pressed, disabled=state.disabled}, environment.accent)
	style_inspector_control_part_recipe(sb, rt, environment.theme, "checkmark", recipe.checkmark,
		Control_Visual_State{selected=state.checked, hovered=state.hovered, pressed=state.pressed, disabled=state.disabled}, environment.accent)
	style_inspector_control_part_recipe(sb, rt, environment.theme, "label", recipe.label,
		Control_Visual_State{selected=state.checked, hovered=state.hovered, pressed=state.pressed, disabled=state.disabled}, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "focus", "overlay", recipe.focus_role, environment.accent)
	fmt.sbprintln(sb)
}

style_inspector_slider_provenance :: proc(sb: ^strings.Builder, rt: ^Runtime, node: ^Node) {
	if rt == nil || node == nil { return }
	environment := node.style_environment
	state := Slider_Visual_State{
		hovered=node.hovered,
		pressed=node.pressed,
		disabled=node.disabled,
		focused=rt.focused == node.id,
	}
	resolved := style_slider_resolve_retained(rt, node, state)
	computed, cached := rt.computed_styles[node.id]
	if !cached { return }
	fmt.sbprintf(sb, "  slider style: recipe=slider.default resolution=retained-cache state=(hovered=%t pressed=%t disabled=%t focused=%t) applied=",
		state.hovered, state.pressed, state.disabled, state.focused)
	first := true
	for transform in Style_Control_State {
		if transform not_in resolved.applied_transforms { continue }
		if !first { fmt.sbprintf(sb, ",") }
		fmt.sbprintf(sb, "%s", style_control_state_name(transform))
		first = false
	}
	fmt.sbprintf(sb, " focus-mode=%s dependencies=paint generations=(paint=%d)\n  token provenance: slider.default",
		focus_indicator_mode_name(resolved.focus_indicator_mode), computed.generations.paint)
	recipe := style_slider_recipe(rt, environment)
	part_state := Control_Visual_State{hovered=state.hovered, pressed=state.pressed, disabled=state.disabled}
	style_inspector_control_part_recipe(sb, rt, environment.theme, "track", recipe.track, part_state, environment.accent)
	style_inspector_control_part_recipe(sb, rt, environment.theme, "fill", recipe.fill, part_state, environment.accent)
	style_inspector_control_part_recipe(sb, rt, environment.theme, "thumb", recipe.thumb, part_state, environment.accent)
	style_inspector_control_part_recipe(sb, rt, environment.theme, "label", recipe.label, part_state, environment.accent)
	style_inspector_token_role(sb, rt, environment.theme, "focus", "overlay", recipe.focus_role, environment.accent)
	fmt.sbprintln(sb)
}

style_inspector_semantic_surface :: proc(sb: ^strings.Builder, rt: ^Runtime, node: ^Node, style: Semantic_Surface_Style) {
	if rt == nil || node == nil || !style.defined { return }
	resolved := style_semantic_surface_resolve_retained(rt, node, style)
	computed, cached := rt.computed_styles[node.id]
	if !cached { return }
	fmt.sbprintf(sb, "  semantic surface: ")
	if style.fill_override_set { fmt.sbprintf(sb, "direct fill") }
	else { style_inspector_surface_role(sb, rt, node.style_environment.theme, style.role) }
	material, material_found := style_material_resolve(rt, style.material)
	material_kind := "unavailable"
	if material_found { material_kind = style_inspector_material_kind_name(material.kind) }
	radii := surface_shape_corner_radii(style.shape)
	fmt.sbprintf(sb, " shape=%s radius=%.2f corner-radii=(%.2f %.2f %.2f %.2f) arc=(center=%.3f,%.3f radius=%.3f start=%.3f sweep=%.3f) bezier=%v material=%d(%s) height=%.2f group=%d fill=(%.3f,%.3f,%.3f,%.3f) gradient=%v end=(%.3f,%.3f,%.3f,%.3f) stroke=(%.3f,%.3f,%.3f,%.3f;%.2f;%v) resolution=retained-cache dependencies=paint,material generations=(paint=%d material=%d)\n",
		style_inspector_surface_shape_name(style.shape.kind), style.shape.corner_radius,
		radii.top_left, radii.top_right, radii.bottom_right, radii.bottom_left,
		style.shape.arc.center[0], style.shape.arc.center[1], style.shape.arc.radius,
		style.shape.arc.start_angle, style.shape.arc.sweep_angle, style.shape.bezier.points,
		u32(style.material), material_kind, style.physical_height, u32(style.material_group),
		resolved.fill.r, resolved.fill.g, resolved.fill.b, resolved.fill.a,
		resolved.gradient.axis, resolved.gradient.end.r, resolved.gradient.end.g, resolved.gradient.end.b, resolved.gradient.end.a,
		resolved.stroke.color.r, resolved.stroke.color.g, resolved.stroke.color.b, resolved.stroke.color.a, resolved.stroke.width, resolved.stroke_placement,
		computed.generations.paint, computed.generations.material)
}

// inspector_text_run_line records span provenance plus the registered faces and
// fallback glyphs Runa selected. A capture bundle can then show whether a boxed
// character is an unresolved .notdef or a face the host actually resolved, and
// whether both hosts picked the same face for the run.
inspector_text_run_line :: proc(sb: ^strings.Builder, node: ^Node) {
	run := &node.text_run
	fmt.sbprintf(sb, "  text run: valid=%t bytes=%d paint-spans=%d style-spans=%d",
		node.text_run_valid, len(run.value) if node.text_run_valid else 0,
		len(node.text_paint_spans), len(node.text_style_spans))
	span_limit := min(len(node.text_paint_spans), 32)
	for span in node.text_paint_spans[:span_limit] {
		if span.color_set {
			fmt.sbprintf(sb, " [%d,%d)fg=(%.3f,%.3f,%.3f,%.3f)", span.start, span.end,
				span.color.r, span.color.g, span.color.b, span.color.a)
		}
		if span.background_set {
			fmt.sbprintf(sb, " [%d,%d)bg=(%.3f,%.3f,%.3f,%.3f)", span.start, span.end,
				span.background.r, span.background.g, span.background.b, span.background.a)
		}
	}
	// The low generation byte is the runtime's unresolved-coverage marker.
	unresolved := run.font_generation & TEXT_RUN_FALLBACK_GENERATION_MASK != 0
	seen: [8]Font_Face_ID
	seen_count := 0
	truncated := false
	for glyph in run.glyphs {
		known := false
		for prior in seen[:seen_count] {
			if prior == glyph.font_face { known = true; break }
		}
		if known { continue }
		if seen_count == len(seen) { truncated = true; break }
		seen[seen_count] = glyph.font_face
		seen_count += 1
	}
	fmt.sbprintf(sb, " faces=[")
	for face, index in seen[:seen_count] {
		if index > 0 { fmt.sbprintf(sb, ",") }
		fmt.sbprintf(sb, "%d", u32(face))
	}
	if truncated { fmt.sbprintf(sb, ",...") }
	fmt.sbprintf(sb, "] unresolved=%t\n", unresolved)
	// Bounded fallback-glyph provenance: identity, face, and shaped glyph id.
	fallback_count := 0
	for glyph in run.glyphs {
		if glyph.font_source != .Fallback { continue }
		if fallback_count == 4 {
			fmt.sbprintf(sb, " ...")
			break
		}
		if fallback_count == 0 { fmt.sbprintf(sb, "  text fallback glyphs:") }
		fmt.sbprintf(sb, " [%d,%d)face=%d gid=%d",
			glyph.cluster_start, glyph.cluster_end, u32(glyph.font_face), u32(glyph.glyph_id))
		fallback_count += 1
	}
	if fallback_count > 0 { fmt.sbprintln(sb) }
}

// frontier_why_touched answers the issue's second question for one node:
// "why did changing this value touch this panel?" It reads only the bounded
// capture and never infers application memory.
frontier_why_touched :: proc(rt: ^Runtime, cause_id: u64, node: Node_ID) -> string {
	if rt == nil { return "invalid runtime" }
	if !INVALIDATION_FRONTIER_ENABLED {
		return "frontier capture unavailable: build a debug runtime with ALICORN_INVALIDATION_FRONTIER=true"
	}
	capture, found := frontier_capture(rt, cause_id)
	if !found { return fmt.tprintf("no frontier captured for cause #%d", cause_id) }
	if node == 0 { return fmt.tprintf("cause #%d did not reference a retained node", cause_id) }
	for subscriber, index in capture.subscribers[:capture.subscriber_count] {
		if subscriber != node { continue }
		if capture.region_key_length > 0 {
			return fmt.tprintf("cause #%d invalidated region key %s at revision %d; node #%d is subscribed instance %d",
				cause_id, frontier_key_text(&capture), capture.region_revision, node, index)
		}
		return fmt.tprintf("cause #%d resolved node #%d as subscribed instance %d", cause_id, node, index)
	}
	for ancestor, index in capture.ancestors[:capture.ancestor_count] {
		if ancestor == node {
			return fmt.tprintf("cause #%d reached node #%d as ancestor %d of subscribed region key %s; the invalidation propagated through it",
				cause_id, node, index, frontier_key_text(&capture))
		}
	}
	if capture.root_invalidations > 0 {
		return fmt.tprintf("cause #%d requested a root invalidation; node #%d is inside the whole-tree scope", cause_id, node)
	}
	if capture.region_invalidations > 0 {
		return fmt.tprintf("cause #%d invalidated region key %s but node #%d is neither a subscriber nor an ancestor; it is outside the declared frontier",
			cause_id, frontier_key_text(&capture), node)
	}
	return fmt.tprintf("cause #%d has no captured region or root invalidation edge to node #%d", cause_id, node)
}

// frontier_inspect renders the novice-facing report for one captured cause.
// Domain reason strings stay in the local trace ring; the report prints IDs,
// counts, stage names, fallback reasons, and the copied region key only.
frontier_inspect :: proc(rt: ^Runtime, cause_id: u64) -> string {
	sb := strings.builder_make()
	fmt.sbprintln(&sb, "Alicorn invalidation frontier")
	if rt == nil {
		fmt.sbprintln(&sb, "invalid runtime")
		return strings.to_string(sb)
	}
	if !INVALIDATION_FRONTIER_ENABLED {
		fmt.sbprintln(&sb, "capture unavailable: this is a release build or ALICORN_INVALIDATION_FRONTIER=false")
		fmt.sbprintln(&sb, "build with -debug (the default gate) to record invalidation frontiers")
		return strings.to_string(sb)
	}
	capture, found := frontier_capture(rt, cause_id)
	if !found {
		fmt.sbprintf(&sb, "no frontier captured for cause #%d (older than the bounded capture ring or no declared work)\n", cause_id)
		return strings.to_string(sb)
	}
	summary := frontier_trace_summary(rt, cause_id)
	cause_kind := fmt.tprintf("%v", capture.cause_kind)
	if capture.cause_id == 0 { cause_kind = "unassigned" }
	fmt.sbprintf(&sb, "cause #%d (%s, action=%d)\n", capture.cause_id, cause_kind, u32(capture.action_id))
	fmt.sbprintf(&sb, "  trace window: #%d..#%d, events=%d, invalidations=%d\n",
		capture.first_sequence, capture.latest_sequence, summary.events, capture.invalidations)
	if capture.region_invalidations > 0 {
		fmt.sbprintf(&sb, "  invalidated region: key=%s revision=%d key-hash=%d requests=%d\n",
			frontier_key_text(&capture), capture.region_revision, capture.region_key_hash, capture.region_invalidations)
		fmt.sbprintf(&sb, "  subscribers (%d): ", capture.subscriber_count)
		frontier_append_nodes(&sb, capture.subscribers[:], capture.subscriber_count)
		fmt.sbprintf(&sb, "\n  ancestors (%d): ", capture.ancestor_count)
		frontier_append_nodes(&sb, capture.ancestors[:], capture.ancestor_count)
		fmt.sbprintln(&sb)
	} else if capture.root_invalidations > 0 {
		fmt.sbprintf(&sb, "  invalidated: root (%d request(s)); every retained node is in scope\n", capture.root_invalidations)
	} else {
		fmt.sbprintln(&sb, "  invalidated: no region or root request was captured for this cause")
	}
	fmt.sbprintf(&sb, "  stage visits: description/reconcile=%d measure=%d layout=%d paint=%d composite=%d\n",
		summary.visits[.Reconcile], summary.visits[.Measure], summary.visits[.Layout],
		summary.visits[.Paint], summary.visits[.Composite])
	fmt.sbprintf(&sb, "  changed outputs: description=%d measure=%d layout=%d paint=%d composite=%d\n",
		capture.changed[.Description], capture.changed[.Measure], capture.changed[.Layout],
		capture.changed[.Paint], capture.changed[.Composite])
	total_changed := frontier_changed_total(&capture)
	if total_changed == 0 && capture.invalidations > 0 {
		fmt.sbprintln(&sb, "  description ran without a changed output: this cause visited stages but no retained output changed")
	}
	fmt.sbprintf(&sb, "  fallbacks: ")
	frontier_append_fallbacks(&sb, &capture)
	fmt.sbprintf(&sb, " (observed work=%d)\n", capture.fallback_work)
	fmt.sbprintf(&sb, "  sampled nodes: reconcile=")
	frontier_append_samples(&sb, &summary.samples[.Reconcile])
	fmt.sbprintf(&sb, " measure=")
	frontier_append_samples(&sb, &summary.samples[.Measure])
	fmt.sbprintf(&sb, " layout=")
	frontier_append_samples(&sb, &summary.samples[.Layout])
	fmt.sbprintf(&sb, " paint=")
	frontier_append_samples(&sb, &summary.samples[.Paint])
	fmt.sbprintf(&sb, " composite=")
	frontier_append_samples(&sb, &summary.samples[.Composite])
	fmt.sbprintln(&sb)
	last_changed := Frontier_Stage.Description
	have_changed := false
	for stage in Frontier_Stage {
		if capture.changed[stage] == 0 { continue }
		last_changed = stage
		have_changed = true
	}
	if have_changed {
		fmt.sbprintf(&sb, "  where work stopped: %s (last stage that produced a changed output)\n",
			frontier_stage_name(last_changed))
	} else if capture.invalidations > 0 {
		fmt.sbprintln(&sb, "  where work stopped: before description output (the invalidation scheduled a description but nothing changed)")
	} else {
		fmt.sbprintln(&sb, "  where work stopped: no changed stage was captured")
	}
	for subscriber in capture.subscribers[:capture.subscriber_count] {
		fmt.sbprintf(&sb, "  why node #%d was touched: %s\n", subscriber, frontier_why_touched(rt, cause_id, subscriber))
	}
	if total_changed > 0 {
		for stage in Frontier_Stage {
			count := capture.changed_node_count[stage]
			if count == 0 { continue }
			fmt.sbprintf(&sb, "  changed %s nodes: ", frontier_stage_name(stage))
			frontier_append_nodes(&sb, capture.changed_nodes[stage][:], count)
			fmt.sbprintln(&sb)
		}
	}
	return strings.to_string(sb)
}

// inspector_append_frontiers adds the bounded frontier inventory to inspect().
// Capture bundles that already include inspect() therefore include it too.
inspector_append_frontiers :: proc(sb: ^strings.Builder, rt: ^Runtime) {
	fmt.sbprintln(sb, "frontiers:")
	if rt == nil { fmt.sbprintln(sb, "  invalid runtime"); return }
	if !INVALIDATION_FRONTIER_ENABLED {
		fmt.sbprintln(sb, "  capture disabled (release build or ALICORN_INVALIDATION_FRONTIER=false)")
		return
	}
	if !frontier_append_recent(sb, rt, 12) {
		fmt.sbprintln(sb, "  no causes captured")
	}
}

inspect :: proc(rt: ^Runtime) -> string {
	previous_suppression := false
	if rt != nil {
		previous_suppression = rt.style_stats_suppressed
		rt.style_stats_suppressed = true
	}
	defer {
		if rt != nil { rt.style_stats_suppressed = previous_suppression }
	}
	sb := strings.builder_make()
	fmt.sbprintln(&sb, "Alicorn inspector")
	fmt.sbprintf(&sb, "keyboard focus: %d selected node: %d captured: %d\n", rt.focused, rt.selected, rt.captured_node)
	if semantic_id_is_valid(rt.semantic_focus.id) {
		fmt.sbprintf(&sb, "semantic focus: namespace=%d value=%d owner=%d realized=%d\n",
			rt.semantic_focus.id.namespace, rt.semantic_focus.id.value,
			rt.semantic_focus.owner, rt.semantic_focus.realized_node)
	} else {
		fmt.sbprintln(&sb, "semantic focus: none")
	}
	if rt.semantic_focus_restore.token != RESTORE_TOKEN_NONE {
		state := rt.semantic_focus_restore
		fmt.sbprintf(&sb, "semantic focus restore: token=%d outcome=%v reason=%v identity=(%d,%d) owner=%d realized=%d\n",
			u64(state.token), state.outcome, state.reason, state.semantic_id.namespace,
			state.semantic_id.value, rt.semantic_focus.owner, state.realized_node)
	}
	for target, state in rt.restore_controls {
		fmt.sbprintf(&sb, "restore: target=%d control=%v token=%d outcome=%v reason=%v requested=(%.2f,%.2f) preferred=(%.2f,%.2f) resolved=(%.2f,%.2f) semantic=(%d,%d) realized=%d layout=%d\n",
			target.node, target.control, u64(state.token), state.outcome, state.reason,
			state.requested.x, state.requested.y, state.preferred.x, state.preferred.y,
			state.resolved.x, state.resolved.y, state.semantic_id.namespace, state.semantic_id.value,
			state.realized_node, state.layout_generation)
	}
	fmt.sbprintf(&sb, "retained nodes: %d\n", len(rt.nodes))
	queued_semantic_requests := max(len(rt.semantic_requests)-rt.semantic_request_read_index, 0)
	fmt.sbprintf(&sb,
		"semantics: revision=%d entities=%d latest=(%d>%d +%d -%d) requests=%d work=(described=%d resolved=%d structure=%d properties=%d focus-search=%d active-update=%d)\n",
		rt.semantic_revision, len(rt.semantic_entities), rt.semantic_last_from_revision, rt.semantic_last_to_revision,
		len(rt.semantic_last_changed), len(rt.semantic_last_removed), queued_semantic_requests,
		rt.stats.semantic_descriptions_emitted, rt.stats.semantic_entities_resolved,
		rt.stats.semantic_structure_changes, rt.stats.semantic_property_changes,
		rt.stats.semantic_focus_search_visits, rt.stats.semantic_active_update_visits)
	fmt.sbprintf(&sb, "last invalidation: %s\n", rt.last_invalidation_reason)
	inspector_append_drag(&sb, rt)
	fmt.sbprintf(&sb, "frame: %d built=%d idle=%d regions-skipped=%d subtrees-reused=%d adjacency-rebuilds=%d surface-updates=%d geometry-updates=%d surface-clears=%d stale-surface-updates=%d geometry-overflow-rejections=%d surface-pending=%t presentation=%d submitted=%d\n", rt.stats.frame, rt.stats.frames_built, rt.stats.idle_frames, rt.stats.regions_skipped, rt.stats.retained_subtrees_reused, rt.stats.adjacency_rebuilds, rt.stats.surface_updates, rt.stats.surface_geometry_updates, rt.stats.surface_clear_count, rt.stats.surface_stale_update_rejections, rt.stats.surface_geometry_overflow_rejections, rt.surface_frame_pending, rt.presentation_revision, rt.submitted_revision)
	fmt.sbprintf(&sb, "work: reconcile=%d measure=%d measure_hits=%d measure_misses=%d text_shapes=%d layout=%d paint=%d compose=%d style_resolutions=%d style_cache_hits=%d created=%d retired=%d\n", rt.stats.reconcile_nodes_visited, rt.stats.measure_requests, rt.stats.measure_cache_hits, rt.stats.measure_cache_misses, rt.stats.text_shape_requests, rt.stats.layout_nodes_visited, rt.stats.paint_nodes_visited, rt.stats.composition_nodes_visited, rt.stats.style_resolutions, rt.stats.style_cache_hits, rt.stats.nodes_created, rt.stats.nodes_retired)
	fmt.sbprintln(&sb, "actions:")
	for entry in rt.actions {
		fmt.sbprintf(&sb, "  %s · %s (id=%d enabled=%t checked=%t)\n", entry.descriptor.name, entry.descriptor.label, u32(entry.descriptor.id), entry.state.enabled, entry.state.checked)
	}
	fmt.sbprintln(&sb, "recent trace:")
	trace := trace_snapshot(rt)
	defer delete(trace)
	trace_start := max(0, len(trace)-12)
	for event in trace[trace_start:] {
		if event.cause_id == 0 {
			fmt.sbprintf(&sb, "  #%d %v cause=none node=%d %s\n", event.sequence, event.kind, event.node, event.reason)
		} else {
			if event.action_id != Action_ID(0) {
				descriptor, state, found := action_lookup(rt, event.action_id)
				if found {
					fmt.sbprintf(&sb, "  #%d %v cause=#%d origin=%v action=%s · %s (id=%d enabled=%t checked=%t) node=%d %s\n", event.sequence, event.kind, event.cause_id, event.cause_kind, descriptor.name, descriptor.label, u32(event.action_id), state.enabled, state.checked, event.node, event.reason)
				} else {
					fmt.sbprintf(&sb, "  #%d %v cause=#%d origin=%v action=%d node=%d %s\n", event.sequence, event.kind, event.cause_id, event.cause_kind, u32(event.action_id), event.node, event.reason)
				}
			} else {
				fmt.sbprintf(&sb, "  #%d %v cause=#%d origin=%v node=%d %s\n", event.sequence, event.kind, event.cause_id, event.cause_kind, event.node, event.reason)
			}
		}
	}
	inspector_append_frontiers(&sb, rt)
	for id in rt.order {
		node, ok := rt.nodes[id]
		if !ok { continue }
		if node.identity_key_kind == 3 {
			fmt.sbprintf(&sb, "Node: %d parent=%d kind=%v source=%s:%d:%d component=%s key=%q scope_pair=(%d,%d) bounds=(%.1f,%.1f %.1fx%.1f)\n", node.id, node.parent, node.kind, node.site.file, node.site.line, node.site.column, node.site.component, node.key, node.identity_key_pair.first, node.identity_key_pair.second, node.bounds.x, node.bounds.y, node.bounds.w, node.bounds.h)
		} else if node.identity_key_numeric {
			fmt.sbprintf(&sb, "Node: %d parent=%d kind=%v source=%s:%d:%d component=%s key=%q scope_u64=%d bounds=(%.1f,%.1f %.1fx%.1f)\n", node.id, node.parent, node.kind, node.site.file, node.site.line, node.site.column, node.site.component, node.key, node.identity_key_u64, node.bounds.x, node.bounds.y, node.bounds.w, node.bounds.h)
		} else {
			fmt.sbprintf(&sb, "Node: %d parent=%d kind=%v source=%s:%d:%d component=%s key=%q scope=%q bounds=(%.1f,%.1f %.1fx%.1f)\n", node.id, node.parent, node.kind, node.site.file, node.site.line, node.site.column, node.site.component, node.key, node.identity_key, node.bounds.x, node.bounds.y, node.bounds.w, node.bounds.h)
		}
		if node.kind == .Split {
			fmt.sbprintf(&sb, "  split: axis=%v preferred=%.2f resolved=%.2f dragging=%t\n", node.split_axis, node.split_preferred_position, node.split_position, node.split_dragging)
		}
		if node.kind == .Split_Handle {
			geometry := layout_node_finalized_geometry(rt, id)
			owner_position: f32 = 0
			owner_dragging := false
			if owner, owner_ok := rt.nodes[node.split_owner]; owner_ok {
				owner_position = owner.split_position
				owner_dragging = owner.split_dragging
			}
			fmt.sbprintf(&sb,
				"  split handle: owner=%d captured=%t visual=(%.1f,%.1f %.1fx%.1f) hit=(%.1f,%.1f %.1fx%.1f) owner-position=%.2f owner-dragging=%t\n",
				node.split_owner, rt.captured_node == id,
				geometry.bounds.x, geometry.bounds.y, geometry.bounds.w, geometry.bounds.h,
				geometry.hit_bounds.x, geometry.hit_bounds.y, geometry.hit_bounds.w, geometry.hit_bounds.h,
				owner_position, owner_dragging)
		}
		fmt.sbprintf(&sb, "  description: %s layout: %s paint: %s composite: %s\n", stage_word(dirty_has(node.dirty, .Description)), stage_word(dirty_has(node.dirty, .Layout)), stage_word(dirty_has(node.dirty, .Paint)), stage_word(dirty_has(node.dirty, .Composite)))
		if hit_shape, custom_hit := rt.pointer_hit_shapes[id]; custom_hit {
			fmt.sbprintf(&sb, "  pointer hit shape: %v (layout and accessibility bounds remain rectangular)\n", hit_shape)
		}
		appearance := node.style_environment.accessibility
		fmt.sbprintf(&sb,
			"  style environment: text-scale=%.2f accessibility-appearance=(increased-contrast=%t reduce-motion=%t reduce-transparency=%t differentiate-without-color=%t)\n",
			node.style_environment.text_scale, appearance.increased_contrast, appearance.reduce_motion,
			appearance.reduce_transparency, appearance.differentiate_without_color)
		if node.region {
			fmt.sbprintf(&sb, "  region: revision=%d cached=%t\n", node.region_revision, node.region_cached)
		}
		if node.kind == .Custom_Surface {
		fmt.sbprintf(&sb, "  surface: payload-revision=%d interaction=%v kind=%v samples=%d rectangles=%d segments=%d circles=%d point-markers=%d pixels=%dx%d dpi=%.2f clip=(%.1f,%.1f %.1fx%.1f)\n", u64(node.surface_payload_revision), node.surface_interaction, node.surface_geometry_active ? GPU_Surface_Kind.Geometry : GPU_Surface_Kind.Waveform, len(node.surface_samples), len(node.surface_rectangles), len(node.surface_segments), len(node.surface_circles), len(gpu_surface_point_markers_resolve(rt, id)), node.surface_pixel_width, node.surface_pixel_height, node.surface_dpi_scale, node.clip.x, node.clip.y, node.clip.w, node.clip.h)
		}
		if semantic_style, has_semantic_style := rt.semantic_surfaces[id]; has_semantic_style {
			style_inspector_semantic_surface(&sb, rt, node, semantic_style)
		}
		fmt.sbprintf(&sb, "  selected=%t semantic_active=%t hovered=%t pressed=%t caret=(%d,%v) selection=(%d,%v)->(%d,%v) reason: %s\n", node.selected, node.semantic_active, node.hovered, node.pressed, node.caret.byte, node.caret.affinity, node.selection_anchor.byte, node.selection_anchor.affinity, node.selection_focus.byte, node.selection_focus.affinity, node.last_reason)
		if node.kind == .Text || node.kind == .Text_Field {
			inspector_text_run_line(&sb, node)
		}
		if node.kind == .Button {
			recipe := style_button_recipe(rt, node.style_environment, node.button_variant)
			hovered := visual_part_owner_hovered(rt, node.id)
			fmt.sbprintf(&sb, "  button/tab state: presentation=%v selected=%t hovered=%t pressed=%t disabled=%t focused=%t keyboard-focus-visible=%t\n",
				node.button_presentation, node.selected, hovered, node.pressed, node.disabled,
				rt.focused == node.id, rt.focused == node.id && rt.focus_visible)
			resolved := style_button_resolve_retained(rt, node, Button_Visual_State{
				selected=node.selected,
				hovered=hovered,
				pressed=node.pressed,
				disabled=node.disabled,
			}, node.drop_position == .On)
			computed_style := rt.computed_styles[node.id]
			if node.button_variant == .Tab {
				fmt.sbprintf(&sb, "  tab identity: label=%q recipe=tab.document variant=button.tab\n", visual_part_owner_label(rt, node.id))
			} else {
				fmt.sbprintf(&sb, "  button identity: label=%q\n", node.label)
			}
			if node.text_run_valid { inspector_text_run_line(&sb, node) }
			fmt.sbprintf(&sb, "  button recipe: variant=%s recipe=button.%s base=(%v,%v) surface=(%.3f,%.3f,%.3f,%.3f) text=(%.3f,%.3f,%.3f,%.3f) indicator=%v/%v\n",
				button_variant_name(node.button_variant), button_variant_name(node.button_variant), recipe.surface_role, recipe.text_role,
				resolved.surface.r, resolved.surface.g, resolved.surface.b, resolved.surface.a,
				resolved.text.r, resolved.text.g, resolved.text.b, resolved.text.a,
				resolved.selected_indicator, recipe.selected_indicator_role)
			fmt.sbprintf(&sb, "  applied transforms:")
			for style_state in Style_Control_State {
				if style_state in resolved.applied_transforms { fmt.sbprintf(&sb, " %s", style_control_state_name(style_state)) }
			}
			fmt.sbprintf(&sb, " | focus-mode=%s\n", focus_indicator_mode_name(recipe.focus_indicator_mode))
			fmt.sbprintf(&sb, " | focus overlay=%v semantic-active overlay=%v\n", recipe.focus_role, recipe.semantic_active_role)
			if recipe.rest_surface.defined || recipe.pressed_surface.defined || resolved.shape.kind != .Rectangle {
				radii := surface_shape_corner_radii(resolved.shape)
				fmt.sbprintf(&sb, "  optical surface: shape=%s radius=%.2f corner-radii=(%.2f %.2f %.2f %.2f) material=%d height=%.3f (paint only)\n",
					style_inspector_surface_shape_name(resolved.shape.kind), resolved.shape.corner_radius,
					radii.top_left, radii.top_right, radii.bottom_right, radii.bottom_left,
					u32(resolved.material), resolved.physical_height)
			}
			fmt.sbprintf(&sb, "  computed style: dependencies=")
			first_domain := true
			for domain in Style_Domain {
				if domain not_in computed_style.dependencies { continue }
				if !first_domain { fmt.sbprintf(&sb, ",") }
				first_domain = false
				switch domain {
				case .Metrics: fmt.sbprintf(&sb, "metrics")
				case .Typography: fmt.sbprintf(&sb, "typography")
				case .Paint: fmt.sbprintf(&sb, "paint")
				case .Material: fmt.sbprintf(&sb, "material")
				}
			}
			fmt.sbprintf(&sb, " resolution=retained-cache generations=(metrics=%d typography=%d paint=%d material=%d)\n",
				computed_style.generations.metrics, computed_style.generations.typography,
				computed_style.generations.paint, computed_style.generations.material)
			provenance := computed_style.provenance
			provenance_variant := Button_Variant(provenance.variant)
			provenance_state := style_button_state_from_bits(provenance.state_bits)
			fmt.sbprintf(&sb, "  token provenance: button.%s", button_variant_name(provenance_variant))
			style_inspector_token_role(&sb, rt, provenance.theme, "surface", "base", recipe.surface_role, provenance.accent)
			style_inspector_token_role(&sb, rt, provenance.theme, "text", "base", recipe.text_role, provenance.accent)
			style_inspector_token_role(&sb, rt, provenance.theme, "focus", "base", recipe.focus_role, provenance.accent)
			style_inspector_token_role(&sb, rt, provenance.theme, "semantic-active", "base", recipe.semantic_active_role, provenance.accent)
			style_inspector_token_role(&sb, rt, provenance.theme, "indicator", "base", recipe.selected_indicator_role, provenance.accent)
			if provenance_state.selected { style_inspector_transform_provenance(&sb, rt, provenance.theme, "selected", recipe.selected, provenance.accent) }
			if provenance_state.hovered { style_inspector_transform_provenance(&sb, rt, provenance.theme, "hovered", recipe.hovered, provenance.accent) }
			if provenance_state.pressed { style_inspector_transform_provenance(&sb, rt, provenance.theme, "pressed", recipe.pressed, provenance.accent) }
			if provenance_state.disabled { style_inspector_transform_provenance(&sb, rt, provenance.theme, "disabled", recipe.disabled, provenance.accent) }
			if provenance.drop_target_on && !provenance_state.disabled {
				style_inspector_token_role(&sb, rt, provenance.theme, "surface", "drop-target", .Success, provenance.accent)
			}
			fmt.sbprintf(&sb, "\n")
		}
		if node.kind == .Checkbox { style_inspector_checkbox_provenance(&sb, rt, node) }
		if node.kind == .Slider { style_inspector_slider_provenance(&sb, rt, node) }
		if node.kind == .Text_Field {
			style_inspector_text_field_provenance(&sb, rt, node)
		}
		if node.kind == .Scroll_Region {
			style_inspector_scrollbar_provenance(&sb, rt, node)
		}
		if node.composition.active {
			fmt.sbprintf(&sb, "  composition: active text-bytes=%d selection=(%d,%d) replaces=(%d,%v)->(%d,%v)\n", len(node.composition.text), node.composition.selection_start, node.composition.selection_end, node.composition.replace_anchor.byte, node.composition.replace_anchor.affinity, node.composition.replace_focus.byte, node.composition.replace_focus.affinity)
		}
	}
	if rt.hard_error {
		fmt.sbprintf(&sb, "HARD ERROR: %s\n", rt.diagnostic)
	}
	return strings.to_string(sb)
}

// inspector_append_drag records the local drag session and the paint commands
// its preview contributes at the tail of the display list. Capture bundles from
// the reference and hosted hosts can then be compared command for command:
// the preview must carry the dragged control's real content, the same
// geometry, and the same stacking index, not a fallback card.
inspector_append_drag :: proc(sb: ^strings.Builder, rt: ^Runtime) {
	if rt == nil { return }
	preview := rt.drag_preview
	pending := 0
	if preview.mode == .Source_Subtree { pending = len(preview.commands) }
	if pending == 0 && preview.ready { pending = 1 }
	fmt.sbprintf(sb,
		"drag: phase=%v type=%d source=(%d,%d) source-node=%d target=(%d,%d) target-node=%d position=%v state=%v tracking=%v preview=(mode=%v ready=%t %.1fx%.1f display-start=%d commands=%d)\n",
		rt.drag.phase, u32(rt.drag.drag_type), rt.drag.source.namespace, rt.drag.source.value,
		rt.drag.source_node, rt.drag.target.namespace, rt.drag.target.value, rt.drag.target_node,
		rt.drag.position, rt.drag.presentation_state, rt.drag.tracking.mode,
		preview.mode, preview.ready, preview.width, preview.height,
		preview.display_start, pending)
	if rt.drag.phase != .Dragging || preview.display_start < 0 { return }
	shown := 0
	for index in preview.display_start..<len(rt.display) {
		if shown >= 16 { break }
		command := rt.display[index]
		if command.owner != 0 { continue }
		shown += 1
		label := ""
		if text, is_text := command.payload.(Text_Paint); is_text {
			if run, found := paint_text_run_resolve(rt, text.run); found && run != nil { label = run.value }
			if len(label) > 120 { label = label[:grapheme_floor_boundary(label, 120)] }
		}
		kind := "surface"
		switch payload in command.payload {
		case Text_Paint: kind = "text"
		case Icon_Paint: kind = "icon"
		case Image_Paint: kind = "image"
		case Geometry_Paint: kind = "geometry"
		case Surface_Paint: kind = "surface"
		case Backdrop_Effect_Paint: kind = "effect"
		}
		fmt.sbprintf(sb,
			"  preview[%d] index=%d kind=%s bounds=(%.1f,%.1f %.1fx%.1f) clip=(%.1f,%.1f %.1fx%.1f) translation=(%.1f,%.1f) opacity=%.2f text=%q\n",
			shown-1, index, kind, command.bounds.x, command.bounds.y, command.bounds.w, command.bounds.h,
			command.clip.x, command.clip.y, command.clip.w, command.clip.h,
			command.translation[0], command.translation[1], command.opacity, label)
	}
}

// Returns a shallow copy of the bounded trace window in chronological order.
// Structured layout reasons are formatted on first inspection and cached in
// their ring entries. The returned event slice does not own reason strings;
// ring-backed reasons remain valid only until their entry is overwritten or
// the runtime is destroyed.
trace_snapshot :: proc(rt: ^Runtime) -> []Trace_Event {
	result := make([]Trace_Event, rt.trace.count)
	start := (rt.trace.next - rt.trace.count + len(rt.trace.events)) % len(rt.trace.events)
	for i := 0; i < rt.trace.count; i += 1 {
		index := (start+i)%len(rt.trace.events)
		trace_materialize_layout_reason(rt, &rt.trace.events[index])
		result[i] = rt.trace.events[index]
	}
	return result
}

// trace_sequence returns the newest sequence number without allocating.
trace_sequence :: proc(rt: ^Runtime) -> u64 {
	if rt == nil { return 0 }
	return rt.trace.sequence
}

// trace_latest_event_after returns the newest borrowed trace event written
// after sequence. Its reason string remains ring-backed and must not be kept
// beyond the next runtime mutation or trace overwrite.
trace_latest_event_after :: proc(rt: ^Runtime, sequence: u64) -> (event: Trace_Event, found: bool) {
	if rt == nil || rt.trace.count <= 0 || len(rt.trace.events) <= 0 || rt.trace.sequence <= sequence {
		return {}, false
	}
	index := (rt.trace.next - 1 + len(rt.trace.events)) % len(rt.trace.events)
	return rt.trace.events[index], true
}
