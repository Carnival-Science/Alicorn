#+build !js
package alicorn

import "core:testing"

// Issue #229 phase 2 regression coverage for the exact description-reuse gate.
//
// The fast path skips hashing, copying, dirty marking, measure observation,
// layout-ancestor propagation, paint queueing, and the text-run decision when
// the pending description exactly equals the retained description. These tests
// pin three properties:
//
//  1. An identical description really takes the fast path and produces no
//     retained work (counters and per-node product state).
//  2. Every field copy_node_description reads is compared. Each mutation in
//     reuse_mutations must defeat the gate, so a newly added field that is
//     forgotten here cannot silently reuse a stale product.
//  3. Invalidation-shaped events (theme, font, retirement, structure order)
//     clear or bypass the stamp, and a retained runtime stays equivalent to a
//     runtime rebuilt from scratch on every step.

REUSE_ROOT_SITE :: Source_Site{"runtime/description_reuse_test.odin", 10, 1, "reuse_root"}
REUSE_TEXT_SITE :: Source_Site{"runtime/description_reuse_test.odin", 20, 1, "reuse_text"}
REUSE_BASELINE_TEXT :: "alpha"
REUSE_MUTATED_TEXT :: "alpha beta"
REUSE_FONT :: #load("../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

Reuse_App :: struct {
	text:  string,
	width: f32,
	color: Color,
	steps: u64,
}

reuse_app :: proc() -> Reuse_App {
	return Reuse_App{text=REUSE_BASELINE_TEXT, width=200, color=Color{0.2, 0.3, 0.4, 1}}
}

// reuse_runtime creates a Runtime with the primary and monospace faces loaded
// so retained text products can actually be built and invalidated.
reuse_runtime :: proc(t: ^testing.T) -> ^Runtime {
	rt := new(Runtime)
	rt^ = new_runtime(Rect{0, 0, 320, 240})
	testing.expect(t, font_load_bytes(rt, .UI, REUSE_FONT), "the fixture UI font must load")
	testing.expect(t, font_load_bytes(rt, .Monospace, REUSE_FONT), "the fixture monospace font must load")
	return rt
}

reuse_runtime_destroy :: proc(rt: ^Runtime) {
	if rt == nil { return }
	destroy_runtime(rt)
	free(rt)
}

// Reuse_Mutation names one pending-description field family. Each entry must
// change something copy_node_description would write; the gate must reject it.
Reuse_Mutation :: enum {
	None,
	Label,
	Text,
	Tooltip,
	Tooltip_Delay,
	Icon,
	Font,
	Text_Weight,
	Text_Size,
	Text_Overflow,
	Text_Paint_Spans,
	Text_Style_Spans,
	Style_Width,
	Style_Height,
	Style_Padding,
	Style_Gap,
	Style_Direction,
	Style_Align,
	Style_Grow,
	Style_Clip,
	Style_Min_Max,
	Style_Compress,
	Placement,
	Color,
	Color_Theme_Resolved,
	Paint_Background,
	Paint_Value,
	Control_Value,
	Region,
	Region_Revision,
	Focusable,
	Disabled,
	Selected,
	Semantic_ID,
	Surface,
	Scroll_Viewport,
	Scroll_Offsets,
	Scroll_Axes,
	Layout_Scroll_Offsets,
	Split,
	Grid,
	Context_Menu_Bounds,
	Text_Interaction,
	Text_Selection_Background,
	Visual_Row,
	Drag_Source,
	Drop_Target,
	Adaptive,
	Identity_Key,
	Explicit_Key,
	Key,
	Site,
	Button_Content,
	Button_Variant,
	Style_Environment,
}

Reuse_Spans :: struct {
	paint: [2]Text_Paint_Span,
	style: [2]Text_Style_Span,
}

// reuse_apply_mutation edits one field family on a pending description. It
// runs after emit so the test controls exactly one difference per frame.
reuse_apply_mutation :: proc(d: ^Description, mutation: Reuse_Mutation, spans: ^Reuse_Spans) {
	switch mutation {
	case .None:
	case .Label: d.label = "changed label"
	case .Text: d.text = REUSE_MUTATED_TEXT
	case .Tooltip: d.tooltip_text = "tooltip"
	case .Tooltip_Delay: d.tooltip_delay_ms = 700
	case .Icon: d.icon_id = Icon_ID(7)
	case .Font: d.font = .Monospace
	case .Text_Weight: d.text_style.font_weight = FONT_WEIGHT_BOLD
	case .Text_Size: d.text_style.font_size = 15
	case .Text_Overflow: d.text_style.overflow = .Ellipsis
	case .Text_Paint_Spans:
		spans.paint[0] = Text_Paint_Span{start=0, end=2, color=Color{0.9, 0.2, 0.1, 1}, color_set=true}
		d.text_paint_spans = spans.paint[:1]
	case .Text_Style_Spans:
		spans.style[0] = Text_Style_Span{start=0, end=3, font_weight_set=true, font_weight=FONT_WEIGHT_BOLD}
		d.text_style_spans = spans.style[:1]
	case .Style_Width: d.style.width = 180
	case .Style_Height: d.style.height = 26
	case .Style_Padding: d.style.padding = 6
	case .Style_Gap: d.style.gap = 3
	case .Style_Direction: d.style.direction = .Row
	case .Style_Align: d.style.align = .Center
	case .Style_Grow: d.style.grow = 1
	case .Style_Clip: d.style.clip = true
	case .Style_Min_Max:
		d.style.min_width = 20
		d.style.max_width = 260
	case .Style_Compress: d.style.compress_weight = 2
	case .Placement: d.placement = positioned(4, 6)
	case .Color: d.color = Color{0.8, 0.4, 0.2, 1}
	case .Color_Theme_Resolved: d.color_theme_resolved = true
	case .Paint_Background: d.paint_background = false
	case .Paint_Value: d.paint_value = 3
	case .Control_Value: d.control_value = 0.75
	case .Region: d.region = true
	case .Region_Revision: d.region_revision = 9
	case .Focusable: d.focusable = true
	case .Disabled: d.disabled = true
	case .Selected: d.selected = true
	case .Semantic_ID: d.semantic_id = Semantic_ID{namespace=77, value=3}
	case .Surface:
		d.kind = .Custom_Surface
		d.surface_kind = .Geometry
		d.surface_pixel_width = 64
		d.surface_pixel_height = 32
		d.surface_dpi_scale = 1.5
	case .Scroll_Viewport:
		d.kind = .Scroll_Region
		d.scroll_content_height = 400
		d.scroll_viewport_height = 120
		d.scroll_content_width = 200
		d.scroll_viewport_width = 180
		d.scroll_line_height = 18
		d.scroll_line_width = 24
	case .Scroll_Offsets:
		d.kind = .Scroll_Region
		d.scroll_offset_y = 24
		d.scroll_offset_x = 6
	case .Scroll_Axes:
		d.kind = .Scroll_Region
		d.scroll_axes = .Horizontal
		d.scroll_axis_behavior = .Free
		d.scrollbar_policy = .Always
	case .Layout_Scroll_Offsets:
		d.kind = .Scroll_Region
		d.layout_scroll_offset_y = 12
		d.layout_scroll_offset_x = 3
	case .Split:
		d.kind = .Split
		d.split_axis = .Vertical
		d.split_min_first = 20
		d.split_min_second = 30
		d.split_owner = 9001
		d.split_handle_size = 6
		d.split_hit_size = 10
		d.split_position = 40
	case .Grid:
		d.grid_item = true
		d.grid_row = 1
		d.grid_column = 2
		d.grid_row_span = 2
		d.grid_column_span = 3
		d.grid_align_x = .Center
		d.grid_align_y = .End
	case .Context_Menu_Bounds: d.context_menu_bounds = Rect{2, 4, 120, 80}
	case .Text_Interaction:
		d.kind = .Text
		d.text_interaction = true
		d.text_interaction_anchor = Text_Position{1, .Leading}
		d.text_interaction_focus = Text_Position{3, .Trailing}
		d.text_interaction_show_caret = true
	case .Text_Selection_Background:
		d.text_selection_background = .Fill_Node_When_Single_Line
	case .Visual_Row:
		d.visual_row_enabled = true
		d.visual_row_text_node = 42
		d.visual_row_position = Text_Position{2, .Leading}
		d.visual_row_color = Color{0.1, 0.9, 0.1, 1}
	case .Drag_Source:
		d.drag_source_type = Drag_Type(3)
		d.drag_source_id = Semantic_ID{namespace=5, value=6}
	case .Drop_Target:
		d.drop_target_type = Drag_Type(4)
		d.drop_target_id = Semantic_ID{namespace=7, value=8}
		d.drop_target_mode = .Between_Horizontal
	case .Adaptive:
		d.adaptive_owner = true
		d.adaptive_alternative = true
		d.adaptive_min_width = 120
	case .Identity_Key: d.identity_key = "identity"
	case .Explicit_Key: d.explicit_key = true
	case .Key: d.key = "explicit-key"
	case .Site: d.site = Source_Site{"runtime/description_reuse_test.odin", 99, 7, "moved"}
	case .Button_Content: d.button_content_style = button_content_style(.End, .Center, padding_x=3, padding_y=4)
	case .Button_Variant: d.button_variant = .Primary
	case .Style_Environment:
		d.style_environment.density = 1.25
		d.style_environment.text_scale = 1.5
	}
}

Reuse_Mutations :: []Reuse_Mutation{
	.Label, .Text, .Tooltip, .Tooltip_Delay, .Icon, .Font, .Text_Weight, .Text_Size,
	.Text_Overflow, .Text_Paint_Spans, .Text_Style_Spans, .Style_Width, .Style_Height,
	.Style_Padding, .Style_Gap, .Style_Direction, .Style_Align, .Style_Grow, .Style_Clip,
	.Style_Min_Max, .Style_Compress, .Placement, .Color, .Color_Theme_Resolved,
	.Paint_Background, .Paint_Value, .Control_Value, .Region, .Region_Revision,
	.Focusable, .Disabled, .Selected, .Semantic_ID, .Surface, .Scroll_Viewport,
	.Scroll_Offsets, .Scroll_Axes, .Layout_Scroll_Offsets, .Split, .Grid,
	.Context_Menu_Bounds, .Text_Interaction, .Text_Selection_Background, .Visual_Row,
	.Drag_Source, .Drop_Target, .Adaptive, .Identity_Key, .Explicit_Key, .Key, .Site,
	.Button_Content, .Button_Variant, .Style_Environment,
}

Reuse_Frame :: struct {
	text_id: Node_ID,
	root_id: Node_ID,
	built:   bool,
}

// reuse_describe drives the retained runtime through one ordinary frame. It
// emits a root and a text child, then applies at most one pending-description
// mutation so the test controls the exact difference from the prior frame.
reuse_describe :: proc(rt: ^Runtime, app: ^Reuse_App, mutation: Reuse_Mutation, spans: ^Reuse_Spans) -> Reuse_Frame {
	invalidate_root(rt, "description reuse fixture")
	ui, build := begin_frame(rt)
	if !build { return {} }
	root := container_begin_ex(
		&ui, .Root, REUSE_ROOT_SITE, key="reuse-root", explicit_key=true,
		style=layout_style(.Column, width=320, height=240, gap=4, padding=4),
	)
	text_id := emit(
		&ui, .Text, REUSE_TEXT_SITE,
		text=app.text,
		style=layout_style(width=app.width, height=20),
		color=app.color,
	)
	if mutation != .None && len(rt.pending) > 0 {
		reuse_apply_mutation(&rt.pending[len(rt.pending)-1].description, mutation, spans)
	}
	container_end(&ui)
	end_frame(&ui)
	return {text_id=text_id, root_id=root, built=true}
}

reuse_prime :: proc(t: ^testing.T, rt: ^Runtime, app: ^Reuse_App, spans: ^Reuse_Spans) -> Node_ID {
	first := reuse_describe(rt, app, .None, spans)
	if !first.built || first.text_id == 0 {
		testing.expect(t, false, "the reuse fixture must describe a retained text node")
		return 0
	}
	// A second identical pass establishes the baseline reuse the table starts
	// from; the first pass necessarily creates.
	second := reuse_describe(rt, app, .None, spans)
	if !second.built || second.text_id != first.text_id {
		testing.expect(t, false, "identical descriptions must keep the same retained node")
		return 0
	}
	return first.text_id
}

// reuse_describe_font is the font-generation fixture: identical to
// reuse_describe except for the retained text font role.
reuse_describe_font :: proc(rt: ^Runtime, app: ^Reuse_App) -> Node_ID {
	invalidate_root(rt, "description reuse font fixture")
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin_ex(
		&ui, .Root, REUSE_ROOT_SITE, key="reuse-root", explicit_key=true,
		style=layout_style(.Column, width=320, height=240, gap=4, padding=4),
	)
	id := emit(
		&ui, .Text, REUSE_TEXT_SITE,
		text=app.text,
		font=.Monospace,
		style=layout_style(width=app.width, height=20),
		color=app.color,
	)
	container_end(&ui)
	end_frame(&ui)
	return id
}

// reuse_describe_children is the structure fixture; children are keyed so a
// reorder is an order change and an insert is a membership change.
reuse_describe_children :: proc(rt: ^Runtime, count: int, reverse: bool) -> Node_ID {
	invalidate_root(rt, "description reuse structure fixture")
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin_ex(
		&ui, .Root, REUSE_ROOT_SITE, key="reuse-root", explicit_key=true,
		style=layout_style(.Column, width=320, height=240),
	)
	first: Node_ID = 0
	for step in 0..<count {
		index := step
		if reverse { index = count-1-step }
		id := emit_key(
			&ui, .Text, REUSE_TEXT_SITE, key=key_u64(u64(index)),
			text="row", style=layout_style(width=100, height=16),
		)
		if first == 0 { first = id }
	}
	container_end(&ui)
	end_frame(&ui)
	return first
}

// reuse_describe_root_only retires every child of the fixture root.
reuse_describe_root_only :: proc(rt: ^Runtime) {
	invalidate_root(rt, "description reuse retirement fixture")
	ui, build := begin_frame(rt)
	if !build { return }
	container_begin_ex(
		&ui, .Root, REUSE_ROOT_SITE, key="reuse-root", explicit_key=true,
		style=layout_style(.Column, width=320, height=240, gap=4, padding=4),
	)
	container_end(&ui)
	end_frame(&ui)
}

// test_description_reuse_exact_match_skips_retained_work pins the fast path:
// an identical description performs no copy, no dirty marking, no measurement,
// no layout, no paint queueing, and no semantic property change.
@(test)
test_description_reuse_exact_match_skips_retained_work :: proc(t: ^testing.T) {
	rt := reuse_runtime(t)
	defer reuse_runtime_destroy(rt)
	app := reuse_app()
	spans := Reuse_Spans{}
	id := reuse_prime(t, rt, &app, &spans)
	if id == 0 { return }

	node := rt.nodes[id]
	if node == nil {
		testing.expect(t, false, "retained node missing")
		return
	}
	before := rt.stats
	reason_before := node.last_reason
	hash_before := node.description_hash
	text_before := node.text
	text_run_before := node.text_run_valid

	again := reuse_describe(rt, &app, .None, &spans)
	if !again.built || again.text_id != id {
		testing.expect(t, false, "the third identical pass must keep the retained node")
		return
	}
	node = rt.nodes[id]
	if node == nil {
		testing.expect(t, false, "retained node disappeared on reuse")
		return
	}
	delta_match := rt.stats.descriptions_retained_match-before.descriptions_retained_match
	delta_reused := rt.stats.descriptions_reused-before.descriptions_reused
	testing.expectf(t, delta_match == 2,
		"both described nodes must take the exact reuse gate (got %d)", delta_match)
	testing.expect(t, delta_reused >= delta_match, "exact reuse must also count as a reused description")
	testing.expect(t, rt.stats.measure_requests == before.measure_requests,
		"an exact match must not request measurement")
	testing.expect(t, rt.stats.layout_nodes_visited == before.layout_nodes_visited,
		"an exact match must not visit layout")
	testing.expect(t, rt.stats.paint_updates == before.paint_updates,
		"an exact match must not queue paint")
	testing.expect(t, rt.stats.semantic_property_changes == before.semantic_property_changes,
		"an exact match must not republish semantic property changes")
	testing.expect(t, node.dirty == Dirty_Stages{}, "an exact match must leave no dirty stage")
	testing.expect(t, !node.paint_queued, "an exact match must not queue the node for paint")
	testing.expect(t, node.description_hash == hash_before, "an exact match must keep the retained hash")
	testing.expect(t, node.text == text_before, "an exact match must not re-copy the retained text")
	testing.expect(t, node.text_run_valid == text_run_before, "an exact match must not destroy the retained text run")
	testing.expect(t, node.last_reason == reason_before, "an exact match must preserve the last work reason")
}

// test_description_reuse_rejects_every_copied_field is the field audit for the
// gate. Each mutation must defeat exact matching; otherwise the retained node
// would keep the previous value of a field copy_node_description writes.
@(test)
test_description_reuse_rejects_every_copied_field :: proc(t: ^testing.T) {
	rt := reuse_runtime(t)
	defer reuse_runtime_destroy(rt)
	app := reuse_app()
	spans := Reuse_Spans{}
	id := reuse_prime(t, rt, &app, &spans)
	if id == 0 { return }

	for mutation in Reuse_Mutations {
		// Interpolate the mutation between two identical baseline frames so the
		// table never depends on retained state from the previous entry.
		_ = reuse_describe(rt, &app, .None, &spans)
		gate_before := rt.stats.descriptions_retained_match
		mutated := reuse_describe(rt, &app, mutation, &spans)
		if !mutated.built || mutated.text_id != id {
			testing.expectf(t, false, "%v must keep the retained identity", mutation)
			continue
		}
		gate_delta := rt.stats.descriptions_retained_match-gate_before
		// The unchanged root takes the gate; the mutated text node must not.
		testing.expectf(t, gate_delta == 1,
			"%v changed a copied field but the exact reuse gate accepted it (delta %d)",
			mutation, gate_delta)

		// Returning to the baseline description must reuse again, proving the
		// rejection above did not leave the node looking permanently changed.
		// The first restored frame re-copies the previous mutation; the next
		// identical frame must take the gate for both nodes again.
		_ = reuse_describe(rt, &app, .None, &spans)
		restored_before := rt.stats.descriptions_retained_match
		_ = reuse_describe(rt, &app, .None, &spans)
		restored_delta := rt.stats.descriptions_retained_match-restored_before
		testing.expectf(t, restored_delta == 2,
			"%v must return to exact reuse once the description is restored (delta %d)",
			mutation, restored_delta)
	}
}

// test_description_reuse_changed_field_refreshes_products checks the other half
// of the contract: a changed description must run the ordinary copy path and
// refresh the products it feeds.
@(test)
test_description_reuse_changed_field_refreshes_products :: proc(t: ^testing.T) {
	rt := reuse_runtime(t)
	defer reuse_runtime_destroy(rt)
	app := reuse_app()
	spans := Reuse_Spans{}
	id := reuse_prime(t, rt, &app, &spans)
	if id == 0 { return }

	app.text = REUSE_MUTATED_TEXT
	measure_before := rt.stats.measure_cache_misses
	paint_before := rt.stats.paint_updates
	_ = reuse_describe(rt, &app, .None, &spans)
	node := rt.nodes[id]
	if node == nil {
		testing.expect(t, false, "retained node missing after text change")
		return
	}
	testing.expect(t, node.text == REUSE_MUTATED_TEXT, "changed text must be re-copied")
	testing.expect(t, rt.stats.measure_cache_misses > measure_before, "changed text must be measured again")
	testing.expect(t, rt.stats.paint_updates > paint_before, "changed text must repaint")

	// A paint-only field change must reach the node and repaint.
	app.color = Color{0.9, 0.1, 0.1, 1}
	paint_before = rt.stats.paint_updates
	_ = reuse_describe(rt, &app, .None, &spans)
	node = rt.nodes[id]
	testing.expect(t, node != nil && color_equal(node.color, app.color), "changed color must be re-copied")
	testing.expect(t, rt.stats.paint_updates > paint_before, "a paint-only change must repaint")
}

// reuse_describe_theme describes the fixture under a pushed theme scope, which
// is how applications select a theme between description frames.
reuse_describe_theme :: proc(rt: ^Runtime, app: ^Reuse_App, theme: Style_Theme_ID) -> Node_ID {
	invalidate_root(rt, "description reuse theme fixture")
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin_ex(
		&ui, .Root, REUSE_ROOT_SITE, key="reuse-root", explicit_key=true,
		style=layout_style(.Column, width=320, height=240, gap=4, padding=4),
	)
	// A style-environment scope must be pushed after its container boundary is
	// open; this is the same ordering applications use.
	scope := style_environment_push(&ui, Style_Environment{theme=theme})
	id := emit(
		&ui, .Text, REUSE_TEXT_SITE,
		text=app.text,
		style=layout_style(width=app.width, height=20),
		color=app.color,
	)
	style_environment_pop(&ui, scope)
	container_end(&ui)
	end_frame(&ui)
	return id
}

// test_description_reuse_theme_change_refreshes_every_node proves a theme
// change is never reused: the style-environment change forces the copy path,
// updates the retained environment, and repaints.
@(test)
test_description_reuse_theme_change_refreshes_every_node :: proc(t: ^testing.T) {
	rt := reuse_runtime(t)
	defer reuse_runtime_destroy(rt)
	app := reuse_app()
	spans := Reuse_Spans{}
	theme_a := DEFAULT_STYLE_THEME
	theme_b := DEFAULT_STYLE_THEME
	theme_b.colors[int(Style_Color_Role.Surface)] = Color{0.32, 0.12, 0.14, 1}
	id_a := style_theme_register(rt, theme_a)
	id_b := style_theme_register(rt, theme_b)
	if id_a == 0 || id_b == 0 || id_a == id_b {
		testing.expect(t, false, "the fixture must register two distinct themes")
		return
	}
	id := reuse_describe_theme(rt, &app, id_a)
	if id == 0 { return }
	_ = reuse_describe_theme(rt, &app, id_a)
	gate_before := rt.stats.descriptions_retained_match
	paint_before := rt.stats.paint_updates
	_ = reuse_describe_theme(rt, &app, id_b)
	node := rt.nodes[id]
	// The Root is described before the pushed scope, so only it is unchanged;
	// the themed text node must not reuse.
	gate_delta := rt.stats.descriptions_retained_match-gate_before
	testing.expectf(t, gate_delta == 1,
		"a theme change must not reuse the themed node (gate accepted %d of 2 nodes)", gate_delta)
	testing.expect(t, node != nil && node.style_environment.theme == id_b,
		"a theme change must update the retained style environment")
	testing.expect(t, rt.stats.paint_updates > paint_before, "a theme change must repaint")
	// The next identical themed frame must reuse again.
	gate_before = rt.stats.descriptions_retained_match
	_ = reuse_describe_theme(rt, &app, id_b)
	testing.expect(t, rt.stats.descriptions_retained_match == gate_before+2,
		"an unchanged themed description must return to exact reuse")
}

// test_description_reuse_font_change_refreshes_text_products pins the font
// generation dependency: changing the font role must invalidate and rebuild
// the retained text product.
@(test)
test_description_reuse_font_change_refreshes_text_products :: proc(t: ^testing.T) {
	rt := reuse_runtime(t)
	defer reuse_runtime_destroy(rt)
	app := reuse_app()
	spans := Reuse_Spans{}
	id := reuse_prime(t, rt, &app, &spans)
	if id == 0 { return }
	node := rt.nodes[id]
	if node == nil || !node.text_run_valid {
		testing.expect(t, false, "the fixture requires a valid retained text run")
		return
	}
	gate_before := rt.stats.descriptions_retained_match
	run_generation_before := node.text_run_generation
	_ = reuse_describe_font(rt, &app)
	node = rt.nodes[id]
	testing.expect(t, rt.stats.descriptions_retained_match-gate_before < 2,
		"a font change must not take the exact reuse gate")
	testing.expect(t, node != nil && node.font == .Monospace, "a font change must be re-copied")
	testing.expect(t, node != nil && node.text_run_generation != run_generation_before,
		"a font change must rebuild the retained text product")
}

// test_description_reuse_retirement_clears_the_stamp proves retirement cannot
// leave a retained stamp behind: a rebuilt node is created fresh and reports
// full retained work instead of reusing the retired node's products.
@(test)
test_description_reuse_retirement_clears_the_stamp :: proc(t: ^testing.T) {
	rt := reuse_runtime(t)
	defer reuse_runtime_destroy(rt)
	app := reuse_app()
	spans := Reuse_Spans{}
	id := reuse_prime(t, rt, &app, &spans)
	if id == 0 { return }

	created_before := rt.stats.nodes_created
	retired_before := rt.stats.nodes_retired
	reuse_describe_root_only(rt)
	testing.expect(t, rt.stats.nodes_retired == retired_before+1, "omitting the node must retire it")
	testing.expect(t, rt.nodes[id] == nil, "a retired node must not remain retained")

	gate_before := rt.stats.descriptions_retained_match
	measure_before := rt.stats.measure_requests
	again := reuse_describe(rt, &app, .None, &spans)
	if !again.built || again.text_id != id {
		testing.expect(t, false, "re-describing the identity must recreate the node")
		return
	}
	testing.expect(t, rt.stats.nodes_created == created_before+1, "the rebuilt node must be created fresh")
	testing.expect(t, rt.stats.descriptions_retained_match-gate_before < 2,
		"a freshly created node must not report an exact reuse")
	testing.expect(t, rt.stats.measure_requests > measure_before, "a rebuilt node must be measured")
	testing.expect(t, rt.nodes[id] != nil, "the rebuilt node must be retained")
}

// test_description_reuse_structure_sequence_is_exact covers the second gate:
// child-list changes must still reconcile, and an unchanged sequence must skip
// the structure diff entirely.
@(test)
test_description_reuse_structure_sequence_is_exact :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 240})
	defer destroy_runtime(&rt)
	first := reuse_describe_children(&rt, 3, false)
	if first == 0 {
		testing.expect(t, false, "structure fixture must describe children")
		return
	}
	root := rt.top_level[0]
	root_node := rt.nodes[root]
	if root_node == nil || len(root_node.children) != 3 {
		testing.expect(t, false, "the root must retain three children")
		return
	}
	original := [3]Node_ID{root_node.children[0], root_node.children[1], root_node.children[2]}
	if original[0] != first {
		testing.expect(t, false, "the first child must keep its identity")
	}

	matches_before := rt.stats.structure_sequence_matches
	_ = reuse_describe_children(&rt, 3, false)
	testing.expect(t, rt.stats.structure_sequence_matches == matches_before+1,
		"an identical emitted sequence must skip the structure diff")

	_ = reuse_describe_children(&rt, 3, true)
	root_node = rt.nodes[root]
	if root_node == nil || len(root_node.children) != 3 {
		testing.expect(t, false, "the root must keep three children after reorder")
		return
	}
	testing.expect(t, root_node.children[0] == original[2] && root_node.children[2] == original[0],
		"a reordered emitted sequence must reconcile the retained child order")

	_ = reuse_describe_children(&rt, 4, false)
	root_node = rt.nodes[root]
	testing.expect(t, root_node != nil && len(root_node.children) == 4,
		"an inserted child must reconcile the retained child list")
}

// test_description_reuse_retained_matches_fresh_runtime runs a churn sequence
// against a retained runtime and compares each step to a runtime rebuilt from
// scratch with the same application state. This is the equivalence oracle for
// reuse: it observes paint projection, semantics, and public node info rather
// than retained internals.
@(test)
test_description_reuse_retained_matches_fresh_runtime :: proc(t: ^testing.T) {
	rt := reuse_runtime(t)
	defer reuse_runtime_destroy(rt)
	app := reuse_app()
	spans := Reuse_Spans{}
	id := reuse_prime(t, rt, &app, &spans)
	if id == 0 { return }

	colors := [4]Color{
		{0.2, 0.3, 0.4, 1}, {0.8, 0.2, 0.1, 1}, {0.1, 0.7, 0.2, 1}, {0.2, 0.2, 0.8, 1},
	}
	texts := [3]string{"alpha", "alpha beta", "alpha beta gamma"}
	for step in 0..<8 {
		app.steps = u64(step)
		app.text = texts[step%len(texts)]
		app.width = f32(120+step*7)
		app.color = colors[step%len(colors)]
		frame := reuse_describe(rt, &app, .None, &spans)
		if !frame.built {
			testing.expect(t, false, "the retained fixture must build every step")
			return
		}

		fresh := reuse_runtime(t)
		_ = reuse_describe(fresh, &app, .None, &spans)
		fresh_node := fresh.nodes[id]
		retained_node := rt.nodes[id]
		testing.expect(t, fresh_node != nil && retained_node != nil,
			"both runtimes must retain the fixture identity")
		if retained_node != nil {
			testing.expect(t, retained_node.text == app.text,
				"retained text must track the application state")
			testing.expect(t, retained_node.style.width == app.width,
				"retained width must track the application state")
			testing.expect(t, color_equal(retained_node.color, app.color),
				"retained color must track the application state")
		}
		testing.expect(t, reuse_paint_lists_match(rt, fresh),
			"retained paint display list must match a freshly built runtime")
		testing.expect(t, coherence_semantics_match(rt, fresh),
			"retained semantics must match a freshly built runtime")
		reuse_runtime_destroy(fresh)
	}
}

// test_description_reuse_mutations_match_fresh_runtime is the second
// fresh-equivalence oracle. It applies each audited field mutation to a
// retained runtime and rebuilds the same description on a fresh runtime, then
// compares the observed products. This catches both a gate that reused a stale
// value and a copy path that dropped a field.
@(test)
test_description_reuse_mutations_match_fresh_runtime :: proc(t: ^testing.T) {
	rt := reuse_runtime(t)
	defer reuse_runtime_destroy(rt)
	app := reuse_app()
	spans := Reuse_Spans{}
	id := reuse_prime(t, rt, &app, &spans)
	if id == 0 { return }

	for mutation in Reuse_Mutations {
		mutated := reuse_describe(rt, &app, mutation, &spans)
		if !mutated.built {
			testing.expectf(t, false, "%v must build on the retained runtime", mutation)
			continue
		}
		fresh := reuse_runtime(t)
		_ = reuse_describe(fresh, &app, mutation, &spans)
		testing.expectf(t, reuse_paint_lists_match(rt, fresh),
			"%v must produce the same paint display list as a fresh runtime", mutation)
		testing.expectf(t, coherence_semantics_match(rt, fresh),
			"%v must produce the same semantics as a fresh runtime", mutation)
		reuse_runtime_destroy(fresh)
		// Return to the baseline so the next entry starts from the same state.
		_ = reuse_describe(rt, &app, .None, &spans)
		_ = reuse_describe(rt, &app, .None, &spans)
	}
}

// reuse_paint_lists_match compares the finalized display lists of two runtimes
// without comparing text-run handles, which are runtime-local resources. Paint
// content, order, geometry, and resources must agree.
reuse_paint_lists_match :: proc(a, b: ^Runtime) -> bool {
	left, left_ok := paint_display_list(a)
	right, right_ok := paint_display_list(b)
	if !left_ok || !right_ok || len(left.commands) != len(right.commands) { return false }
	for index in 0..<len(left.commands) {
		l, r := left.commands[index], right.commands[index]
		if l.owner != r.owner || l.bounds != r.bounds || l.clip != r.clip ||
		   l.opacity != r.opacity || l.translation != r.translation ||
		   l.stroke_placement != r.stroke_placement ||
		   l.semantic_surface_gradient != r.semantic_surface_gradient { return false }
		l_surface, l_surface_ok := l.payload.(Surface_Paint)
		r_surface, r_surface_ok := r.payload.(Surface_Paint)
		if l_surface_ok || r_surface_ok {
			if !l_surface_ok || !r_surface_ok || l_surface != r_surface { return false }
			continue
		}
		l_text, l_text_ok := l.payload.(Text_Paint)
		r_text, r_text_ok := r.payload.(Text_Paint)
		if l_text_ok || r_text_ok {
			if !l_text_ok || !r_text_ok || l_text.color != r_text.color ||
			   len(l_text.spans) != len(r_text.spans) { return false }
			for span, span_index in l_text.spans {
				if span != r_text.spans[span_index] { return false }
			}
		}
	}
	return true
}

// test_description_hash_covers_region_semantics_and_scroll_line_metrics
// documents and pins the description-hash audit. Fields that the description
// hash does not represent must be covered by another typed product hash
// (layout, paint, measure) or by exact comparison in the reuse gate. These are
// the extensions issue #229 phase 2 added so a field cannot escape both.
@(test)
test_description_hash_covers_region_semantics_and_scroll_line_metrics :: proc(t: ^testing.T) {
	base := Description{kind=.Scroll_Region}
	surface := Semantic_Surface_Style{}
	part := Visual_Part_Style{}
	accessibility := Accessibility_Appearance_Preferences{}
	base_hash := description_hash(base, surface, part, accessibility)

	region := base
	region.region = true
	testing.expect(t, description_hash(region, surface, part, accessibility) != base_hash,
		"the region declaration must be part of the description hash")

	semantic := base
	semantic.semantic_id = Semantic_ID{namespace=3, value=4}
	testing.expect(t, description_hash(semantic, surface, part, accessibility) != base_hash,
		"the semantic id must be part of the description hash")

	line_height := base
	line_height.scroll_line_height = 18
	testing.expect(t, description_hash(line_height, surface, part, accessibility) != base_hash,
		"the scroll line height must be part of the description hash")

	line_width := base
	line_width.scroll_line_width = 24
	testing.expect(t, description_hash(line_width, surface, part, accessibility) != base_hash,
		"the scroll line width must be part of the description hash")
}
