#+build !js

package alicorn

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

