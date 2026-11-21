#+build !js

package alicorn

import "core:fmt"
import "core:strings"
import "core:testing"

// Hosted presentation fixtures for Scratchpad's two application-parity gaps:
// syntax-highlighting paint spans and pointer drag-selection. Both fixtures
// describe the same shape Scratchpad's editor uses: an application-owned Root,
// a scroll region holding shaped Text rows with ordered color spans, and a
// runtime-owned Text_Field for the drag-selection path.

Hosted_Parity_Test_App :: struct {
	root:   Node_ID,
	scroll: Node_ID,
	row:    Node_ID,
	field:  Node_ID,
	events: [dynamic]Pointer_Kind,
	// updated_spans replaces the row's spans on the next description; it models
	// a parser/syntax presentation arriving after the first paint.
	updated_spans:                 []Text_Paint_Span,
	redescribe_with_updated_spans: bool,
}

HOSTED_PARITY_TEST_FONT :: #load("../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

hosted_parity_span :: proc(start, end: int, color: Color) -> Text_Paint_Span {
	return Text_Paint_Span{start=start, end=end, color=color, color_set=true}
}

hosted_parity_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	app := cast(^Hosted_Parity_Test_App)data
	app.root = container_begin(
		ui, .Root, label="parity-root", key="parity-root",
		style=layout_style(.Column, grow=1, padding=4, gap=4),
	)
	if app.root == 0 { return }
	scroll := scroll_region_begin(
		ui,
		key=key_string("parity-scroll"),
		content_height=400,
		line_height=20,
		style=layout_style(.Column, grow=1, clip=true),
		label="parity-scroll",
		axes=.Both,
		focusable=true,
	)
	app.scroll = scroll.id
	app.row = text_ex(
		ui,
		"func DetectPath(path string) ID {",
		key="parity-row",
		font=.Monospace,
		style=layout_style(.Row, height=20),
	)
	spans := []Text_Paint_Span{
		hosted_parity_span(0, 4, Color{0.376, 0.290, 0.533, 1}),
		hosted_parity_span(5, 15, Color{0.184, 0.333, 0.486, 1}),
		hosted_parity_span(16, 20, Color{0.141, 0.361, 0.412, 1}),
	}
	if app.redescribe_with_updated_spans { spans = app.updated_spans }
	_ = text_paint_spans(ui, app.row, spans)
	_ = text_interaction(
		ui, app.row,
		Text_Position{byte=0}, Text_Position{byte=len("func DetectPath")},
		true,
	)
	scroll_region_end(ui)
	app.field = text_field_ex(
		ui, "abcdefghij", key="parity-field", style=layout_style(width=200, height=24),
	)
	container_end(ui)
}

hosted_parity_pointer :: proc(data: rawptr, rt: ^Runtime, event: Pointer_Event, target: Node_ID) {
	app := cast(^Hosted_Parity_Test_App)data
	append(&app.events, event.kind)
}

hosted_parity_post :: proc(_data: rawptr) -> bool {
	return true
}

hosted_parity_open :: proc(host: ^Hosted_Runtime, app: ^Hosted_Parity_Test_App, inset_top: f32) -> Hosted_Runtime_Status {
	return hosted_runtime_init(host, Hosted_Runtime_Config{
		state=rawptr(app),
		logical_width=320,
		logical_height=200,
		pixel_width=320,
		pixel_height=200,
		dpi_scale=1,
		content_inset_top=inset_top,
		post_wake_data=rawptr(app),
		post_wake=hosted_parity_post,
		render=hosted_parity_render,
		on_pointer=hosted_parity_pointer,
	})
}

// hosted_parity_field_point converts a byte offset into the window-space point
// of the field's retained shaped run, exactly like an app hit would arrive.
hosted_parity_field_point :: proc(rt: ^Runtime, id: Node_ID, byte: int) -> (x, y: f32, ok: bool) {
	node, found := rt.nodes[id]
	if !found || !node.text_run_valid { return }
	position := Text_Position{byte, .Leading}
	line_index := text_run_line_for_byte(&node.text_run, position)
	if line_index < 0 || line_index >= len(node.text_run.lines) { return }
	local_x, x_ok := text_run_position_x(&node.text_run, line_index, position, rt.scratch_allocator)
	if !x_ok { return }
	line := node.text_run.lines[line_index]
	origin := text_field_run_origin(rt, node, &node.text_run)
	return origin.x+local_x, origin.y+line.y+line.height*0.5, true
}

@(test)
test_hosted_presentation_preserves_text_paint_spans :: proc(t: ^testing.T) {
	for inset in ([]f32{0, 24}) {
		host: Hosted_Runtime
		app: Hosted_Parity_Test_App
		if hosted_parity_open(&host, &app, inset) != .Ok {
			testing.expect(t, false, "parity fixture should initialize")
			return
		}
		step := hosted_runtime_step(&host, 1)
		testing.expect(t, step.status == .Ok && step.description_built, "parity fixture should describe a frame")

		view, view_status := hosted_runtime_presentation_list(&host)
		testing.expect(t, view_status == .Ok, "presentation list should be available")

		found_text, span_count := 0, 0
		for command in view.commands {
			paint, is_text := command.payload.(Text_Paint)
			if !is_text || command.owner != app.row { continue }
			found_text += 1
			span_count = len(paint.spans)
			testing.expectf(t, span_count == 3,
				"a hosted text command must carry every paint span the description set (got %d)", span_count)
			if span_count == 3 {
				testing.expect(t,
					paint.spans[0].color_set && paint.spans[0].start == 0 && paint.spans[0].end == 4 &&
					paint.spans[1].start == 5 && paint.spans[1].end == 15 &&
					paint.spans[2].start == 16 && paint.spans[2].end == 20,
					"hosted presentation must preserve span byte ranges and order")
				testing.expect(t,
					paint.spans[0].color == Color{0.376, 0.290, 0.533, 1} &&
					paint.spans[1].color == Color{0.184, 0.333, 0.486, 1},
					"hosted presentation must preserve span colors")
			}
			// The host inset is applied once, at presentation, to geometry only.
			testing.expectf(t, command.bounds.y >= inset,
				"host content inset must translate application paint below the band (bounds.y=%v inset=%v)",
				command.bounds.y, inset)
		}
		testing.expect(t, found_text == 1 && span_count == 3,
			"the hosted presentation list must expose the described text span colors")

		// Retained runtime state keeps the same spans the renderer resolves.
		rt, borrow_status := hosted_runtime_borrow(&host)
		if borrow_status == .Ok {
			if node, found := rt.nodes[app.row]; found {
				testing.expect(t, len(node.text_paint_spans) == 3,
					"retained text nodes must keep their paint spans across presentation")
			}
			// A later description that changes only span colors must reach the
			// presentation list. A run cache keyed without spans would keep the
			// earlier, colorless command here.
			updated := []Text_Paint_Span{
				hosted_parity_span(0, 4, Color{0.10, 0.60, 0.20, 1}),
				hosted_parity_span(5, 15, Color{0.60, 0.30, 0.10, 1}),
			}
			app.updated_spans = updated
			app.redescribe_with_updated_spans = true
			invalidate_root(rt, "parity span-only update")
			if second := hosted_runtime_step(&host, 2); second.description_built {
				updated_view, updated_status := hosted_runtime_presentation_list(&host)
				if updated_status == .Ok {
					updated_found := false
					for command in updated_view.commands {
						paint, is_text := command.payload.(Text_Paint)
						if !is_text || command.owner != app.row { continue }
						updated_found = len(paint.spans) == 2 &&
							paint.spans[0].color == Color{0.10, 0.60, 0.20, 1} &&
							paint.spans[1].color == Color{0.60, 0.30, 0.10, 1}
					}
					testing.expect(t, updated_found,
						"a span-only update must reach the hosted presentation list")
				}
			}
		}

		hosted_runtime_destroy(&host)
		delete(app.events)
	}
}

// hosted_parity_reference_route is the native/testui pointer entry point: hit
// test, then dispatch application pointer input. Both hosts must agree on the
// selection this produces for the same description.
hosted_parity_reference_route :: proc(rt: ^Runtime, _target: Node_ID, event: Pointer_Event) {
	target := process_pointer(rt, event)
	_ = application_dispatch_pointer(rt, nil, nil, event, target)
}

@(test)
test_hosted_pointer_drag_selection_matches_reference :: proc(t: ^testing.T) {
	// Hosted route.
	host: Hosted_Runtime
	app: Hosted_Parity_Test_App
	if hosted_parity_open(&host, &app, 0) != .Ok {
		testing.expect(t, false, "pointer parity fixture should initialize")
		return
	}
	defer {
		hosted_runtime_destroy(&host)
		delete(app.events)
	}
	rt, _ := hosted_runtime_borrow(&host)
	testing.expect(t, text_engine_load_font(&rt.text_engine, HOSTED_PARITY_TEST_FONT),
		"the pointer parity fixture should load a shaped UI font")
	_ = hosted_runtime_step(&host, 1)
	rt, _ = hosted_runtime_borrow(&host)

	down_x, down_y, down_ok := hosted_parity_field_point(rt, app.field, 1)
	move_x, move_y, move_ok := hosted_parity_field_point(rt, app.field, 8)
	if !down_ok || !move_ok {
		testing.expect(t, false, "the parity fixture must retain a shaped text field")
		return
	}
	_, down_status := hosted_runtime_pointer(&host, Pointer_Event{
		kind=.Down, x=down_x, y=down_y, button=POINTER_BUTTON_PRIMARY,
	})
	testing.expect(t, down_status == .Ok && rt.captured_node == app.field,
		"hosted pointer down must capture the runtime-owned text field")
	_, move_status := hosted_runtime_pointer(&host, Pointer_Event{kind=.Move, x=move_x, y=move_y})
	testing.expect(t, move_status == .Ok, "hosted pointer move must be accepted")
	_, up_status := hosted_runtime_pointer(&host, Pointer_Event{
		kind=.Up, x=move_x, y=move_y, button=POINTER_BUTTON_PRIMARY,
	})
	testing.expect(t, up_status == .Ok && rt.captured_node == 0,
		"hosted pointer release must end the captured selection")

	field := rt.nodes[app.field]
	testing.expectf(t,
		field.selection_anchor.byte == 1 && field.caret.byte == 8,
		"hosted drag must select the pressed-to-moved byte range (anchor=%d caret=%d)",
		field.selection_anchor.byte, field.caret.byte)
	testing.expect(t, len(app.events) == 3 &&
		app.events[0] == .Down && app.events[1] == .Move && app.events[2] == .Up,
		"the application must receive pointer down, move, and up in order")

	// Reference route: the same description driven through the native/testui
	// pointer entry point must produce the identical selection.
	ref_rt := new_runtime(Rect{0, 0, 320, 200})
	defer destroy_runtime(&ref_rt)
	testing.expect(t, text_engine_load_font(&ref_rt.text_engine, HOSTED_PARITY_TEST_FONT),
		"the reference fixture should load a shaped UI font")
	ref_app: Hosted_Parity_Test_App
	{
		ui, build := begin_frame(&ref_rt)
		if !build { testing.expect(t, false, "reference fixture must build"); return }
		hosted_parity_render(&ref_app, &ui, 320, 200, 1)
		end_frame(&ui)
	}
	ref_down_x, ref_down_y, ref_down_ok := hosted_parity_field_point(&ref_rt, ref_app.field, 1)
	ref_move_x, ref_move_y, ref_move_ok := hosted_parity_field_point(&ref_rt, ref_app.field, 8)
	if !ref_down_ok || !ref_move_ok {
		testing.expect(t, false, "the reference fixture must retain a shaped text field")
		return
	}
	hosted_parity_reference_route(&ref_rt, ref_app.field, Pointer_Event{
		kind=.Down, x=ref_down_x, y=ref_down_y, button=POINTER_BUTTON_PRIMARY,
	})
	hosted_parity_reference_route(&ref_rt, ref_app.field, Pointer_Event{
		kind=.Move, x=ref_move_x, y=ref_move_y,
	})
	hosted_parity_reference_route(&ref_rt, ref_app.field, Pointer_Event{
		kind=.Up, x=ref_move_x, y=ref_move_y, button=POINTER_BUTTON_PRIMARY,
	})
	ref_field := ref_rt.nodes[ref_app.field]
	testing.expectf(t,
		field.selection_anchor.byte == ref_field.selection_anchor.byte &&
		field.caret.byte == ref_field.caret.byte,
		"hosted and reference pointer routes must agree (hosted=%d..%d reference=%d..%d)",
		field.selection_anchor.byte, field.caret.byte,
		ref_field.selection_anchor.byte, ref_field.caret.byte)
	delete(ref_app.events)
}

// Hosted drag-preview parity: a tab drag must describe the same preview paint
// commands through the hosted pointer route as through the reference runtime
// route. Scratchpad's connected titlebar tabs use exactly this shape (default
// tab_bar options, magnetic tracking, animate_drag_reorder).
HOSTED_TAB_DRAG_TYPE :: Drag_Type(0x746462)

Hosted_Tab_Drag_App :: struct {
	nodes: [3]Node_ID,
	count: int,
}

hosted_tab_drag_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	app := cast(^Hosted_Tab_Drag_App)data
	root := container_begin(
		ui, .Root, label="tab-drag-root", key="tab-drag-root",
		style=layout_style(.Column, grow=1, padding=6, gap=6),
	)
	if root == 0 { return }
	items := [3]Tab_Bar_Item{
		{key=key_string("tab-drag-main"), label="main.go", selected=true,
			semantic_id=Semantic_ID{namespace=911, value=1}},
		{key=key_string("tab-drag-notes"), label="notes.md",
			semantic_id=Semantic_ID{namespace=911, value=2}},
		{key=key_string("tab-drag-readme"), label="README.md",
			semantic_id=Semantic_ID{namespace=911, value=3}},
	}
	options := DEFAULT_TAB_BAR_OPTIONS
	options.height = 34
	options.min_tab_width = 120
	options.max_tab_width = 160
	options.gap = 0
	options.presentation = .Compact
	options.appearance = .Connected
	options.animate_drag_reorder = true
	options.drag_type = HOSTED_TAB_DRAG_TYPE
	options.drag_tracking = DRAG_TRACKING_HORIZONTAL_MAGNETIC
	result := tab_bar(
		ui, key_string("tab-drag-bar"), items[:], options,
		layout_style(.Row, width=460, height=34, clip=true),
	)
	app.count = len(result.item_nodes)
	for index in 0..<app.count { app.nodes[index] = result.item_nodes[index] }
	container_end(ui)
}

hosted_tab_drag_post :: proc(_data: rawptr) -> bool { return true }

// drag_preview_signature is a host-independent description of the drag preview's
// paint commands: content kind, geometry, clip, translation and resolved label.
// Node IDs are deliberately excluded (each host retains its own), so an exact
// string match proves the two hosts describe the same visual.
drag_preview_signature :: proc(rt: ^Runtime, builder: ^strings.Builder) {
	if rt == nil { return }
	preview := rt.drag_preview
	count := 0
	if preview.mode == .Source_Subtree { count = len(preview.commands) }
	fmt.sbprintf(builder, "mode=%v ready=%t size=%.1fx%.1f commands=%d\n",
		preview.mode, preview.ready, preview.width, preview.height, count)
	if rt.drag.phase != .Dragging { return }
	for index in preview.display_start..<len(rt.display) {
		command := rt.display[index]
		if command.owner != 0 { continue }
		kind := "surface"
		switch payload in command.payload {
		case Text_Paint: kind = "text"
		case Icon_Paint: kind = "icon"
		case Image_Paint: kind = "image"
		case Geometry_Paint: kind = "geometry"
		case Surface_Paint: kind = "surface"
		case Backdrop_Effect_Paint: kind = "effect"
		}
		label := ""
		if text, is_text := command.payload.(Text_Paint); is_text {
			if run, found := paint_text_run_resolve(rt, text.run); found && run != nil { label = run.value }
		}
		fmt.sbprintf(builder,
			"%s bounds=(%.2f,%.2f %.2fx%.2f) clip=(%.1f,%.1f %.1fx%.1f) translation=(%.2f,%.2f) opacity=%.2f text=%q\n",
			kind, command.bounds.x, command.bounds.y, command.bounds.w, command.bounds.h,
			command.clip.x, command.clip.y, command.clip.w, command.clip.h,
			command.translation[0], command.translation[1], command.opacity, label)
	}
}

@(test)
test_hosted_tab_drag_preview_matches_the_reference_route :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Tab_Drag_App
	if hosted_runtime_init(&host, Hosted_Runtime_Config{
		state=rawptr(&app),
		logical_width=520, logical_height=240,
		pixel_width=520, pixel_height=240,
		dpi_scale=1,
		post_wake_data=rawptr(&app),
		post_wake=hosted_tab_drag_post,
		render=hosted_tab_drag_render,
	}) != .Ok {
		testing.expect(t, false, "the hosted tab drag fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	hosted_rt, borrowed := hosted_runtime_borrow(&host)
	if borrowed != .Ok {
		testing.expect(t, false, "the hosted fixture should borrow its runtime")
		return
	}
	testing.expect(t, text_engine_load_font(&hosted_rt.text_engine, HOSTED_PARITY_TEST_FONT),
		"the hosted drag preview needs the fixture font")
	_ = hosted_runtime_step(&host, 1_000_000)
	if app.count < 2 {
		testing.expect(t, false, "the hosted fixture should retain both tabs")
		return
	}
	source := hosted_rt.nodes[app.nodes[0]]
	target := hosted_rt.nodes[app.nodes[1]]
	sx := source.bounds.x+source.bounds.w*0.5
	sy := source.bounds.y+source.bounds.h*0.5
	tx := target.bounds.x+target.bounds.w*0.4
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{
		kind=.Down, x=sx, y=sy, button=POINTER_BUTTON_PRIMARY,
	})
	_ = hosted_runtime_step(&host, 2_000_000)
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{kind=.Move, x=sx+DRAG_START_THRESHOLD+2, y=sy})
	_ = hosted_runtime_step(&host, 3_000_000)
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{kind=.Move, x=tx, y=sy})
	_ = hosted_runtime_step(&host, 4_000_000)
	hosted_preview := strings.builder_make()
	defer strings.builder_destroy(&hosted_preview)
	drag_preview_signature(hosted_rt, &hosted_preview)

	// The same description through the reference route: process_pointer, then
	// the interaction-only presentation frame the native host runs.
	reference := new_runtime(Rect{0, 0, 520, 240})
	defer destroy_runtime(&reference)
	testing.expect(t, text_engine_load_font(&reference.text_engine, HOSTED_PARITY_TEST_FONT),
		"the reference drag preview needs the fixture font")
	reference_app: Hosted_Tab_Drag_App
	ui, should_build := begin_frame(&reference)
	if should_build {
		hosted_tab_drag_render(rawptr(&reference_app), &ui, 520, 240, 1)
		end_frame(&ui)
	}
	if reference_app.count < 2 {
		testing.expect(t, false, "the reference fixture should retain both tabs")
		return
	}
	reference_source := reference.nodes[reference_app.nodes[0]]
	reference_target := reference.nodes[reference_app.nodes[1]]
	_ = process_pointer(&reference, Pointer_Event{
		kind=.Down, x=reference_source.bounds.x+reference_source.bounds.w*0.5,
		y=reference_source.bounds.y+reference_source.bounds.h*0.5,
		button=POINTER_BUTTON_PRIMARY,
	})
	// The press invalidates the root; describe that pressed frame before the
	// drag begins, exactly as native/sdl_gpu's loop does.
	describe_ui, describe := begin_frame(&reference)
	if describe {
		hosted_tab_drag_render(rawptr(&reference_app), &describe_ui, 520, 240, 1)
		end_frame(&describe_ui)
	}
	reference_source = reference.nodes[reference_app.nodes[0]]
	reference_target = reference.nodes[reference_app.nodes[1]]
	_ = process_pointer(&reference, Pointer_Event{
		kind=.Move, x=reference_source.bounds.x+reference_source.bounds.w*0.5+DRAG_START_THRESHOLD+2,
		y=reference_source.bounds.y+reference_source.bounds.h*0.5,
	})
	_ = process_pointer(&reference, Pointer_Event{
		kind=.Move, x=reference_target.bounds.x+reference_target.bounds.w*0.4,
		y=reference_source.bounds.y+reference_source.bounds.h*0.5,
	})
	reference_ui, reference_presentation := begin_presentation_frame(&reference)
	if reference_presentation { end_presentation_frame(&reference_ui) }
	reference_preview := strings.builder_make()
	defer strings.builder_destroy(&reference_preview)
	drag_preview_signature(&reference, &reference_preview)

	testing.expect(t, hosted_rt.drag_preview.mode == .Source_Subtree &&
		hosted_rt.drag_preview.mode == reference.drag_preview.mode,
		"both hosts should lift the painted tab, not fall back to a label card")
	testing.expect(t, strings.to_string(hosted_preview) == strings.to_string(reference_preview),
		fmt.tprintf("the hosted drag preview should describe the same paint commands as the reference:\nhosted:\n%s\nreference:\n%s",
			strings.to_string(hosted_preview), strings.to_string(reference_preview)))
	testing.expect(t, strings.contains(strings.to_string(hosted_preview), "text=") &&
		strings.contains(strings.to_string(hosted_preview), `"main.go"`),
		"the lifted tab preview should carry the tab's real label text")
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{
		kind=.Up, x=tx, y=sy, button=POINTER_BUTTON_PRIMARY,
	})
}

// Scratchpad's editor publishes rebased syntax spans on the optimistic edit and
// exact spans when the parser catches up. The hosted runtime must carry both
// presentations and must not rebuild the text product of untouched rows. This
// fixture models that sequence directly: two highlighted rows, a value edit
// with locally rebased spans, then a later exact publication.
Hosted_Parity_Edit_App :: struct {
	root:         Node_ID,
	scroll:       Node_ID,
	edited:       Node_ID,
	stable:       Node_ID,
	edited_value: string,
	edited_spans: []Text_Paint_Span,
	stable_value: string,
	stable_spans: []Text_Paint_Span,
}

hosted_parity_edit_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	app := cast(^Hosted_Parity_Edit_App)data
	app.root = container_begin(
		ui, .Root, label="edit-root", key="edit-root",
		style=layout_style(.Column, grow=1, padding=4, gap=4),
	)
	if app.root == 0 { return }
	scroll := scroll_region_begin(
		ui,
		key=key_string("edit-scroll"),
		content_height=120,
		line_height=20,
		style=layout_style(.Column, grow=1, clip=true),
		label="edit-scroll",
		axes=.Vertical,
		focusable=true,
	)
	app.scroll = scroll.id
	app.edited = text_ex(
		ui, app.edited_value, key="edit-edited-row", font=.Monospace,
		style=layout_style(.Row, height=20),
	)
	_ = text_paint_spans(ui, app.edited, app.edited_spans)
	app.stable = text_ex(
		ui, app.stable_value, key="edit-stable-row", font=.Monospace,
		style=layout_style(.Row, height=20),
	)
	_ = text_paint_spans(ui, app.stable, app.stable_spans)
	scroll_region_end(ui)
	container_end(ui)
}

hosted_parity_edit_post :: proc(_data: rawptr) -> bool { return true }

hosted_parity_edit_open :: proc(host: ^Hosted_Runtime, app: ^Hosted_Parity_Edit_App) -> Hosted_Runtime_Status {
	return hosted_runtime_init(host, Hosted_Runtime_Config{
		state=rawptr(app),
		logical_width=360,
		logical_height=160,
		pixel_width=360,
		pixel_height=160,
		dpi_scale=1,
		post_wake_data=rawptr(app),
		post_wake=hosted_parity_edit_post,
		render=hosted_parity_edit_render,
	})
}

hosted_parity_text_command :: proc(view: ^Paint_Display_List_View, owner: Node_ID) -> (paint: Text_Paint, found: bool) {
	for command in view.commands {
		if command.owner != owner { continue }
		if text, is_text := command.payload.(Text_Paint); is_text { return text, true }
	}
	return {}, false
}

@(test)
test_hosted_presentation_preserves_spans_across_an_edit_sequence :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app := Hosted_Parity_Edit_App{
		edited_value="func DetectPath(path string) ID {",
		edited_spans=[]Text_Paint_Span{
			hosted_parity_span(0, 4, Color{0.376, 0.290, 0.533, 1}),
			hosted_parity_span(5, 15, Color{0.184, 0.333, 0.486, 1}),
			hosted_parity_span(16, 20, Color{0.141, 0.361, 0.412, 1}),
		},
		stable_value="return nil",
		stable_spans=[]Text_Paint_Span{
			hosted_parity_span(0, 6, Color{0.55, 0.18, 0.44, 1}),
		},
	}
	if hosted_parity_edit_open(&host, &app) != .Ok {
		testing.expect(t, false, "the edit-sequence fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	rt, borrow_status := hosted_runtime_borrow(&host)
	if borrow_status != .Ok {
		testing.expect(t, false, "the edit-sequence fixture should borrow its runtime")
		return
	}
	testing.expect(t, text_engine_load_font(&rt.text_engine, HOSTED_PARITY_TEST_FONT),
		"the edit-sequence fixture should load a shaped font")

	_ = hosted_runtime_step(&host, 1)
	view, view_status := hosted_runtime_presentation_list(&host)
	if view_status != .Ok {
		testing.expect(t, false, "the edit-sequence presentation list should be available")
		return
	}
	edited_before, edited_found := hosted_parity_text_command(&view, app.edited)
	stable_before, stable_found := hosted_parity_text_command(&view, app.stable)
	if !edited_found || !stable_found {
		testing.expect(t, false, "both highlighted rows must reach the presentation list")
		return
	}
	testing.expect(t, len(edited_before.spans) == 3 && len(stable_before.spans) == 1,
		"the settled rows should carry their syntax spans")
	edited_run_before := edited_before.run
	stable_run_before := stable_before.run

	// Optimistic edit: the value grows by one byte and the application rebases
	// every span that does not touch the insertion point. Nothing else changes.
	app.edited_value = "xfunc DetectPath(path string) ID {"
	app.edited_spans = []Text_Paint_Span{
		hosted_parity_span(0, 5, Color{0.376, 0.290, 0.533, 1}),
		hosted_parity_span(6, 16, Color{0.184, 0.333, 0.486, 1}),
		hosted_parity_span(17, 21, Color{0.141, 0.361, 0.412, 1}),
	}
	invalidate_root(rt, "fixture optimistic edit with rebased spans")
	_ = hosted_runtime_step(&host, 2)
	view, view_status = hosted_runtime_presentation_list(&host)
	if view_status != .Ok {
		testing.expect(t, false, "the optimistic edit presentation list should be available")
		return
	}
	edited_edit, edited_edit_found := hosted_parity_text_command(&view, app.edited)
	stable_edit, stable_edit_found := hosted_parity_text_command(&view, app.stable)
	if !edited_edit_found || !stable_edit_found {
		testing.expect(t, false, "both rows must remain paintable after the optimistic edit")
		return
	}
	testing.expect(t, len(edited_edit.spans) == 3 &&
		edited_edit.spans[0].start == 0 && edited_edit.spans[0].end == 5 &&
		edited_edit.spans[1].start == 6 && edited_edit.spans[1].end == 16 &&
		edited_edit.spans[2].start == 17 && edited_edit.spans[2].end == 21,
		"rebased span ranges must reach the hosted presentation for the edited value")
	if edited_run, edited_run_ok := paint_text_run_resolve(rt, edited_edit.run); edited_run_ok {
		testing.expect(t, edited_run.value == app.edited_value,
			"the edited row's text command must resolve the new value")
	}
	testing.expectf(t, edited_edit.run != edited_run_before,
		"the edited row must build a new text product (before=%v after=%v)",
		edited_run_before, edited_edit.run)
	testing.expect(t, len(stable_edit.spans) == 1 &&
		stable_edit.spans[0].start == 0 && stable_edit.spans[0].end == 6,
		"the untouched row must retain its highlight throughout the edit")
	testing.expectf(t, stable_edit.run == stable_run_before,
		"the untouched row must reuse its text product (before=%v after=%v)",
		stable_run_before, stable_edit.run)

	// Exact publication: the parser answers for the accepted revision with its
	// own ranges and colors. The earlier rebased ranges must be replaced, not
	// merged, and the untouched row must still be unchanged.
	app.edited_spans = []Text_Paint_Span{
		hosted_parity_span(1, 5, Color{0.11, 0.55, 0.22, 1}),
		hosted_parity_span(6, 16, Color{0.70, 0.28, 0.10, 1}),
		hosted_parity_span(17, 21, Color{0.20, 0.40, 0.70, 1}),
	}
	invalidate_root(rt, "fixture parser publication")
	_ = hosted_runtime_step(&host, 3)
	view, view_status = hosted_runtime_presentation_list(&host)
	if view_status != .Ok {
		testing.expect(t, false, "the publication presentation list should be available")
		return
	}
	edited_after, edited_after_found := hosted_parity_text_command(&view, app.edited)
	stable_after, stable_after_found := hosted_parity_text_command(&view, app.stable)
	if !edited_after_found || !stable_after_found {
		testing.expect(t, false, "both rows must remain paintable after publication")
		return
	}
	testing.expect(t, len(edited_after.spans) == 3 &&
		edited_after.spans[0].start == 1 && edited_after.spans[0].end == 5 &&
		edited_after.spans[0].color == Color{0.11, 0.55, 0.22, 1} &&
		edited_after.spans[1].color == Color{0.70, 0.28, 0.10, 1},
		"the exact parser publication must replace the rebased spans")
	testing.expect(t, len(stable_after.spans) == 1 &&
		stable_after.spans[0].color == Color{0.55, 0.18, 0.44, 1} &&
		stable_after.run == stable_run_before,
		"the untouched row must keep the same spans and text product after publication")
}

// Internal retained drag-and-drop between two drop targets. Scratchpad's
// workspace tree moves a document by semantic identity; the hosted pointer
// route must emit the same Started/Target_Changed/Dropped sequence as the
// reference process_pointer route. The source and target are application
// nodes, so this fixture exercises the same retained drag machinery both hosts
// run, not a renderer-specific copy.
HOSTED_DND_TYPE :: Drag_Type(0x484F5354444E44)
HOSTED_DND_SOURCE :: Semantic_ID{namespace=812, value=1}
HOSTED_DND_TARGET :: Semantic_ID{namespace=812, value=2}

Hosted_Parity_Dnd_App :: struct {
	root:   Node_ID,
	source: Node_ID,
	target: Node_ID,
	events: [dynamic]Drag_Event,
}

hosted_parity_dnd_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	app := cast(^Hosted_Parity_Dnd_App)data
	app.root = container_begin(
		ui, .Root, label="dnd-root", key="dnd-root",
		style=layout_style(.Row, width=400, height=100, gap=20, padding=10),
	)
	if app.root == 0 { return }
	app.source, _ = button_begin(
		ui, "document.txt", key=key_string("dnd-source"),
		style=layout_style(width=120, height=50),
	)
	_ = semantic_bind(ui, HOSTED_DND_SOURCE)
	_ = drag_source(ui, HOSTED_DND_TYPE, HOSTED_DND_SOURCE, .Auto)
	button_end(ui)
	app.target = container_begin_simple(
		ui, .Container, label="dnd-target", key=key_string("dnd-target"),
		style=layout_style(.Row, width=160, height=50),
	)
	_ = semantic_bind(ui, HOSTED_DND_TARGET)
	_ = drop_target(ui, HOSTED_DND_TYPE, HOSTED_DND_TARGET, .On)
	_ = text(ui, "folder", key=key_string("dnd-target-text"))
	container_end(ui)
	container_end(ui)
}

hosted_parity_dnd_drag :: proc(data: rawptr, _rt: ^Runtime, event: Drag_Event) {
	app := cast(^Hosted_Parity_Dnd_App)data
	append(&app.events, event)
}

hosted_parity_dnd_post :: proc(_data: rawptr) -> bool { return true }

hosted_parity_dnd_take_reference :: proc(rt: ^Runtime, events: ^[dynamic]Drag_Event) {
	for {
		event, ok := drag_event_take(rt)
		if !ok { return }
		append(events, event)
	}
}

hosted_parity_dnd_equal :: proc(a, b: Drag_Event) -> bool {
	return a.kind == b.kind && a.drag_type == b.drag_type && a.source == b.source &&
		a.previous_target == b.previous_target && a.target == b.target &&
		a.position == b.position && a.presentation_state == b.presentation_state
}

@(test)
test_hosted_retained_drag_drop_between_targets_matches_the_reference_route :: proc(t: ^testing.T) {
	host: Hosted_Runtime
	app: Hosted_Parity_Dnd_App
	defer delete(app.events)
	if hosted_runtime_init(&host, Hosted_Runtime_Config{
		state=rawptr(&app),
		logical_width=400, logical_height=100,
		pixel_width=400, pixel_height=100,
		dpi_scale=1,
		post_wake_data=rawptr(&app),
		post_wake=hosted_parity_dnd_post,
		render=hosted_parity_dnd_render,
		on_drag=hosted_parity_dnd_drag,
	}) != .Ok {
		testing.expect(t, false, "the hosted drag/drop fixture should initialize")
		return
	}
	defer hosted_runtime_destroy(&host)
	hosted_rt, borrowed := hosted_runtime_borrow(&host)
	if borrowed != .Ok {
		testing.expect(t, false, "the hosted drag/drop fixture should borrow its runtime")
		return
	}
	_ = hosted_runtime_step(&host, 1)
	if app.source == 0 || app.target == 0 {
		testing.expect(t, false, "the hosted drag/drop fixture should retain a source and target")
		return
	}
	source := hosted_rt.nodes[app.source]
	target := hosted_rt.nodes[app.target]
	sx := source.bounds.x+source.bounds.w*0.5
	sy := source.bounds.y+source.bounds.h*0.5
	tx := target.bounds.x+target.bounds.w*0.5
	ty := target.bounds.y+target.bounds.h*0.5
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{kind=.Down, x=sx, y=sy, button=POINTER_BUTTON_PRIMARY})
	_ = hosted_runtime_step(&host, 2)
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{kind=.Move, x=sx+DRAG_START_THRESHOLD+2, y=sy})
	_ = hosted_runtime_step(&host, 3)
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{kind=.Move, x=tx, y=ty})
	_ = hosted_runtime_step(&host, 4)
	_, _ = hosted_runtime_pointer(&host, Pointer_Event{kind=.Up, x=tx, y=ty, button=POINTER_BUTTON_PRIMARY})
	_ = hosted_runtime_step(&host, 5)

	// Reference route: process_pointer plus the drag-event take/dispatch the
	// native host performs after each pointer event.
	reference := new_runtime(Rect{0, 0, 400, 100})
	defer destroy_runtime(&reference)
	reference_app: Hosted_Parity_Dnd_App
	ui, should_build := begin_frame(&reference)
	if should_build {
		hosted_parity_dnd_render(rawptr(&reference_app), &ui, 400, 100, 1)
		end_frame(&ui)
	}
	if reference_app.source == 0 || reference_app.target == 0 {
		testing.expect(t, false, "the reference drag/drop fixture should retain a source and target")
		return
	}
	reference_source := reference.nodes[reference_app.source]
	reference_target := reference.nodes[reference_app.target]
	reference_sx := reference_source.bounds.x+reference_source.bounds.w*0.5
	reference_sy := reference_source.bounds.y+reference_source.bounds.h*0.5
	reference_tx := reference_target.bounds.x+reference_target.bounds.w*0.5
	reference_ty := reference_target.bounds.y+reference_target.bounds.h*0.5
	reference_events := make([dynamic]Drag_Event, 0, allocator=context.temp_allocator)
	defer delete(reference_events)
	_ = process_pointer(&reference, Pointer_Event{kind=.Down, x=reference_sx, y=reference_sy, button=POINTER_BUTTON_PRIMARY})
	hosted_parity_dnd_take_reference(&reference, &reference_events)
	_ = process_pointer(&reference, Pointer_Event{kind=.Move, x=reference_sx+DRAG_START_THRESHOLD+2, y=reference_sy})
	hosted_parity_dnd_take_reference(&reference, &reference_events)
	_ = process_pointer(&reference, Pointer_Event{kind=.Move, x=reference_tx, y=reference_ty})
	hosted_parity_dnd_take_reference(&reference, &reference_events)
	_ = process_pointer(&reference, Pointer_Event{kind=.Up, x=reference_tx, y=reference_ty, button=POINTER_BUTTON_PRIMARY})
	hosted_parity_dnd_take_reference(&reference, &reference_events)

	if len(app.events) < 3 || len(app.events) != len(reference_events) {
		testing.expect(t, false, fmt.tprintf(
			"both routes must emit the same drag sequence: hosted=%d reference=%d",
			len(app.events), len(reference_events),
		))
		return
	}
	for event, index in app.events {
		testing.expect(t, hosted_parity_dnd_equal(event, reference_events[index]),
			fmt.tprintf("drag event %d must match the reference route: hosted=%v reference=%v",
				index, event, reference_events[index]))
	}
	testing.expect(t, app.events[0].kind == .Started &&
		app.events[0].source == HOSTED_DND_SOURCE &&
		app.events[0].drag_type == HOSTED_DND_TYPE,
		"the hosted drag starts from the document source identity")
	found_target_change := false
	for event in app.events {
		if event.kind == .Target_Changed && event.target == HOSTED_DND_TARGET && event.position == .On {
			found_target_change = true
		}
	}
	testing.expect(t, found_target_change,
		"crossing the drop target reports Target_Changed with the target identity and On position")
	last := app.events[len(app.events)-1]
	testing.expect(t, last.kind == .Dropped && last.target == HOSTED_DND_TARGET && last.position == .On,
		"releasing over the target drops the document with the target identity")
}
