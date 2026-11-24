#+build !js
package alicorn

import "core:mem"
import "core:testing"

text_input_target_suspension_test_render :: proc(rt: ^Runtime, include_target: bool) -> Node_ID {
	invalidate_root(rt, "text-input target suspension test")
	ui, should_build := begin_frame(rt)
	if !should_build { return 0 }
	container_begin(&ui, .Root, label="text-input-suspension-root", key=key_string("text-input-suspension-root"))
	owner := container_begin_ex(
		&ui,
		.Scroll_Region,
		site("runtime/text_input_test.odin", 1, 1, "suspension-owner"),
		label="editor input owner",
		key="suspension-owner",
		explicit_key=true,
		style=layout_style(width=240, height=64),
	)
	if include_target { _ = text_input_target(&ui, owner) }
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	return owner
}

@(test)
test_text_input_target_suspend_resume_after_target_omitted :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 120})
	defer destroy_runtime(&rt)

	owner := text_input_target_suspension_test_render(&rt, true)
	testing.expect(t, owner != 0 && text_input_target_is_active(&rt, owner),
		"a described generic text target should begin eligible")
	if owner == 0 || !text_input_target_is_active(&rt, owner) { return }
	testing.expect(t, text_input_target_set_suspended(&rt, owner, true),
		"a live generic target should be suspendable")
	testing.expect(t, text_input_target_is_suspended(&rt, owner) && !text_input_target_is_active(&rt, owner),
		"suspension should immediately remove the target from native eligibility")
	testing.expect(t, !text_input_target_area_set(&rt, owner, Text_Input_Area{rect=Rect{0, 0, 4, 16}}),
		"suspended targets should not update native candidate geometry")

	owner_after_omission := text_input_target_suspension_test_render(&rt, false)
	testing.expect(t, owner_after_omission == owner && !text_input_target_is_active(&rt, owner),
		"omitting the marker on a later description should retain suspension without changing node identity")
	testing.expect(t, text_input_target_is_suspended(&rt, owner),
		"description reconciliation must not silently clear application suspension")
	testing.expect(t, text_input_target_set_suspended(&rt, owner, false),
		"the owner should be resumable after a description omitted its target marker")
	testing.expect(t, !text_input_target_is_suspended(&rt, owner),
		"resume should clear only the suspension flag")
	owner_again := text_input_target_suspension_test_render(&rt, true)
	testing.expect(t, owner_again == owner && text_input_target_is_active(&rt, owner),
		"re-describing a resumed target should restore native eligibility")

	text_input_target_set_suspended(&rt, owner, true)
	testing.expect(t, !text_input_target_set_suspended(&rt, owner, true),
		"repeating the same suspension should be an idempotent no-op")
	text_input_target_set_suspended(&rt, owner, false)
}

TEXT_INPUT_ALLOCATOR_TEST_FONT :: #load("../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

Controlled_Text_Field_Test_State :: struct {
	value: Text_Field_Buffer,
	result: Text_Field_Response,
	pending_semantic_value_uses_current_buffer: bool,
}

controlled_text_field_test_render :: proc(rt: ^Runtime, state: ^Controlled_Text_Field_Test_State) -> Node_ID {
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin(&ui, .Root, key=key_string("controlled-text-field-root"), style=layout_style(.Column, grow=1, gap=8))
	text(&ui, state.value.text, key=key_string("controlled-text-field-echo"))
	state.result = text_field_controlled(
		&ui,
		&state.value,
		key=key_string("controlled-text-field-input"),
		style=layout_style(width=240, height=40),
	)
	_ = semantic_text_field_label(&ui, "Name")
	if len(rt.pending) > 0 {
		pending := rt.pending[len(rt.pending)-1]
		state.pending_semantic_value_uses_current_buffer =
			raw_data(pending.semantic.value) == raw_data(state.value.text)
	}
	container_end(&ui)
	end_frame(&ui)
	return state.result.node
}

@(test)
test_controlled_text_field_adopts_commits_but_not_ime_preedit :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 120})
	defer destroy_runtime(&rt)
	state: Controlled_Text_Field_Test_State
	value, value_ok := text_field_buffer_init("seed", context.allocator)
	if !value_ok {
		testing.expect(t, false, "the app-owned field buffer should initialize")
		return
	}
	state.value = value
	defer text_field_buffer_destroy(&state.value)

	invalidate_root(&rt, "controlled text field initial description")
	field := controlled_text_field_test_render(&rt, &state)
	testing.expect(t, field != 0 && state.value.text == "seed", "the controlled field should start from the application value")
	if field == 0 { return }
	_ = focus(&rt, field)
	_ = set_text_caret(&rt, field, len(state.value.text))
	testing.expect(t, process_text_editing(&rt, field, "preedit", 0, 0), "the field should accept an IME preedit")
	_ = controlled_text_field_test_render(&rt, &state)
	testing.expect(t, state.value.text == "seed" && !state.result.changed,
		"IME preedit must remain transient and must not mutate application-owned committed text")
	change := process_text_input(&rt, field, "!")
	if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
	invalidate_root(&rt, "controlled text field committed input adoption")
	_ = controlled_text_field_test_render(&rt, &state)
	testing.expect(t, state.value.text == "seed!" && state.result.changed,
		"a committed input event should be copied into the app-owned buffer on the next description")
	testing.expect(t, state.pending_semantic_value_uses_current_buffer,
		"the pending semantic value must be rebound before the app-owned buffer releases its previous text")
	testing.expect(t, state.result.node == field, "controlled adoption must preserve the retained field identity")
	semantic, semantic_found := semantic_node_lookup(&rt, semantic_visual_id(field))
	testing.expect(t, semantic_found && semantic.value == "seed!",
		"the semantic value should track the adopted committed text")
	testing.expect(t, text_field_buffer_set(&state.value, "programmatic"), "the app should be able to replace controlled text explicitly")
	invalidate_root(&rt, "controlled text field programmatic replacement")
	_ = controlled_text_field_test_render(&rt, &state)
	retained, retained_found := rt.nodes[field]
	testing.expect(t, retained_found, "the controlled field should remain retained after a programmatic update")
	if retained_found {
		testing.expect(t, retained.text == "programmatic", "the retained field should adopt the new app-owned text")
	}
	testing.expect(t, !state.result.changed, "programmatic text replacement should not be reported as a user edit")
	text_field_buffer_destroy(&state.value)

	value, value_ok = text_field_buffer_init("submit", context.allocator)
	if !value_ok { return }
	state.value = value
	invalidate_root(&rt, "controlled text field programmatic update")
	field = controlled_text_field_test_render(&rt, &state)
	_ = focus(&rt, field)
	testing.expect(t, text_field_request_submit(&rt, field), "a focused controlled field should accept one submit request")
	_ = controlled_text_field_test_render(&rt, &state)
	testing.expect(t, state.result.submitted, "the next controlled description should consume the submit result once")
	invalidate_root(&rt, "controlled text field submit consumed")
	_ = controlled_text_field_test_render(&rt, &state)
	testing.expect(t, !state.result.submitted, "a consumed submit must not replay on later descriptions")
}

controlled_text_field_visual_test_render :: proc(
	rt: ^Runtime,
	state: ^Controlled_Text_Field_Test_State,
	show_overlay := true,
) -> Node_ID {
	state.result = {}
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin(&ui, .Root, key=key_string("controlled-field-visual-root"), style=layout_style(.Column, grow=1))
	container_end(&ui)
	if show_overlay {
		modal_overlay_begin(
			&ui,
			key_string("controlled-field-visual-overlay"),
			style=layout_style(.Column, grow=1, padding=12, align=.Center, justify=.Center, clip=true),
		)
		if surface_begin(
			&ui,
			surface_core_color_role(.Surface),
			key=key_string("controlled-field-visual-panel"),
			style=layout_style(.Column, width=280, height=88, padding=12, gap=8, clip=true),
		) != 0 {
			_ = text(&ui, "Search", key=key_string("controlled-field-visual-title"))
			if container_begin(&ui, .Container,
				key=key_string("controlled-field-visual-row"),
				style=layout_style(.Row, grow=1, height=40, align=.Center),
			) != 0 {
				state.result = text_field_controlled(
					&ui,
					&state.value,
					key=key_string("controlled-field-visual-input"),
					style=layout_style(.Row, grow=1, height=40),
				)
				_ = semantic_text_field_label(&ui, "Search commands")
				container_end(&ui)
			}
			surface_end(&ui)
		}
		modal_overlay_end(&ui)
	}
	end_frame(&ui)
	return state.result.node
}

controlled_text_field_visual_expect_visible_value :: proc(
	t: ^testing.T,
	rt: ^Runtime,
	field: Node_ID,
	expected: string,
) {
	retained, retained_found := rt.nodes[field]
	testing.expect(t, retained_found, "the controlled modal field should remain retained")
	if !retained_found { return }
	testing.expect(t, retained.text == expected,
		"the retained value should match the committed query")
	testing.expect(t, retained.active && retained.present && retained.text_run_valid,
		"the visible modal field should have a current shaped text run")
	if !retained.text_run_valid { return }
	testing.expect(t, retained.text_run.value == expected,
		"the shaped text run should match the committed query")
	visible_glyphs := 0
	for glyph in retained.text_run.glyphs {
		if !glyph.control_advance { visible_glyphs += 1 }
	}
	paint_found := false
	for command in rt.display {
		if command.owner != field { continue }
		paint, is_text := command.payload.(Text_Paint)
		if !is_text { continue }
		run, run_found := paint_text_run_resolve(rt, paint.run)
		bounds_visible := rect_intersection(command.bounds, command.clip)
		paint_found = run_found && run != nil && run.value == expected &&
			visible_glyphs > 0 && paint.color.a > 0 && bounds_visible.w > 0 && bounds_visible.h > 0
		break
	}
	testing.expect(t, visible_glyphs > 0 && paint_found,
		"the final display list should resolve drawable query glyphs inside the clipped field")
}

@(test)
test_controlled_text_field_committed_input_keeps_visible_text_paint :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 180})
	defer destroy_runtime(&rt)
	if !text_engine_load_font(&rt.text_engine, TEXT_INPUT_ALLOCATOR_TEST_FONT) {
		testing.expect(t, false, "the controlled-field visual fixture should load the UI font")
		return
	}
	state: Controlled_Text_Field_Test_State
	value, value_ok := text_field_buffer_init("", context.allocator)
	if !value_ok {
		testing.expect(t, false, "the controlled field should initialize an empty app-owned query")
		return
	}
	state.value = value
	defer text_field_buffer_destroy(&state.value)

	invalidate_root(&rt, "controlled field visual fixture initial description")
	field := controlled_text_field_visual_test_render(&rt, &state)
	if field == 0 {
		testing.expect(t, false, "the modal fixture should retain its controlled query field")
		return
	}
	shape_calls_before_edit := rt.text_engine.shape_calls
	measure_requests_before_edit := rt.stats.measure_requests
	_ = focus(&rt, field)
	change := process_text_input(&rt, field, "browse")
	if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
	invalidate_root(&rt, "controlled field visual fixture committed edit")
	updated_field := controlled_text_field_visual_test_render(&rt, &state)
	testing.expect(t, updated_field == field && state.value.text == "browse",
		"committing an empty-field edit should preserve its retained identity and adopt the visible query")
	testing.expect(t, focused_node(&rt) == field,
		"committing visible text should preserve controlled-field focus")
	retained, retained_found := rt.nodes[field]
	testing.expect(t, retained_found, "the controlled field should remain retained after the committed edit")
	if !retained_found { return }
	testing.expect(t, retained.text == "browse", "the retained field should adopt the committed query")
	testing.expect(t, retained.active && retained.present,
		"the described modal query field should remain active and present after editing")
	testing.expect(t, retained.bounds.w > 0 && retained.bounds.h > 0 &&
		rect_intersection(retained.bounds, retained.clip).w > 0 && rect_intersection(retained.bounds, retained.clip).h > 0,
		"the modal query field should have nonempty clipped layout bounds")
	_, ui_font_loaded := text_engine_font(&rt.text_engine, retained.font)
	testing.expect(t, ui_font_loaded, "the field's resolved font role should remain loaded")
	testing.expect(t, rt.text_engine.shape_calls > 0,
		"the runtime should have invoked text shaping for visible modal text")
	testing.expect(t, rt.text_engine.shape_calls > shape_calls_before_edit,
		"the edited modal field should be reshaped after committed text invalidation")
	testing.expect(t, rt.stats.measure_requests > measure_requests_before_edit,
		"the edited modal field should pass through retained measurement after committed text invalidation")
	controlled_text_field_visual_expect_visible_value(t, &rt, field, "browse")

	change = process_text_input(&rt, field, " palette")
	if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
	invalidate_root(&rt, "controlled field repeated typing")
	updated_field = controlled_text_field_visual_test_render(&rt, &state)
	testing.expect(t, updated_field == field && state.value.text == "browse palette",
		"repeated typing should preserve identity and update the controlled query")
	controlled_text_field_visual_expect_visible_value(t, &rt, field, "browse palette")

	// A paste delivered as committed platform text uses the same runtime edit
	// path as typed characters and must refresh the visible product as well.
	change = process_text_input(&rt, field, " pasted")
	if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
	invalidate_root(&rt, "controlled field committed paste")
	updated_field = controlled_text_field_visual_test_render(&rt, &state)
	testing.expect(t, updated_field == field && state.value.text == "browse palette pasted",
		"pasted committed text should preserve identity and appear in the controlled query")
	controlled_text_field_visual_expect_visible_value(t, &rt, field, "browse palette pasted")

	change = process_text_edit(&rt, field, Text_Edit{.Backspace, ""})
	if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
	invalidate_root(&rt, "controlled field backspace")
	updated_field = controlled_text_field_visual_test_render(&rt, &state)
	testing.expect(t, updated_field == field && state.value.text == "browse palette paste",
		"backspace should preserve identity and display the shortened query")
	controlled_text_field_visual_expect_visible_value(t, &rt, field, "browse palette paste")

	_ = set_text_selection(&rt, field, 7, 14)
	change = process_text_edit(&rt, field, Text_Edit{.Insert, "commands"})
	if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
	invalidate_root(&rt, "controlled field selection replacement")
	updated_field = controlled_text_field_visual_test_render(&rt, &state)
	testing.expect(t, updated_field == field && state.value.text == "browse commands paste",
		"selection replacement should preserve identity and display only the replacement value")
	controlled_text_field_visual_expect_visible_value(t, &rt, field, "browse commands paste")

	_ = set_text_caret(&rt, field, len(state.value.text))
	testing.expect(t, process_text_editing(&rt, field, "pre", 0, 0),
		"the field should accept transient IME preedit without replacing committed text")
	_ = controlled_text_field_visual_test_render(&rt, &state)
	retained = rt.nodes[field]
	testing.expect(t, state.value.text == "browse commands paste" && retained.text_run_valid &&
		retained.composition_run_valid && retained.composition_run.value == "browse commands pastepre",
		"IME preedit should keep committed text and produce a separate projected composition run")
	change = process_text_input(&rt, field, "!")
	if len(change.text) > 0 { delete(change.text, rt.persistent_allocator) }
	invalidate_root(&rt, "controlled field IME commit")
	updated_field = controlled_text_field_visual_test_render(&rt, &state)
	testing.expect(t, updated_field == field && state.value.text == "browse commands paste!",
		"IME commit should become visible controlled text under the same field identity")
	controlled_text_field_visual_expect_visible_value(t, &rt, field, "browse commands paste!")

	testing.expect(t, text_field_buffer_set(&state.value, "programmatic"),
		"the app should be able to replace the query programmatically")
	invalidate_root(&rt, "controlled field programmatic replacement")
	updated_field = controlled_text_field_visual_test_render(&rt, &state)
	testing.expect(t, updated_field == field, "programmatic replacement should preserve field identity")
	controlled_text_field_visual_expect_visible_value(t, &rt, field, "programmatic")

	testing.expect(t, runtime_set_viewport(&rt, Rect{0, 0, 480, 240}),
		"the modal fixture should accept a host resize")
	updated_field = controlled_text_field_visual_test_render(&rt, &state)
	testing.expect(t, updated_field == field, "resizing the modal should preserve the query field identity")
	controlled_text_field_visual_expect_visible_value(t, &rt, field, "programmatic")

	invalidate_root(&rt, "controlled field modal close")
	closed_field := controlled_text_field_visual_test_render(&rt, &state, show_overlay=false)
	testing.expect(t, closed_field == 0 && !node_is_presentation_active(&rt, field),
		"closing the modal should retire its field without losing the app-owned query")
	invalidate_root(&rt, "controlled field modal reopen")
	reopened_field := controlled_text_field_visual_test_render(&rt, &state)
	testing.expect(t, reopened_field != 0 && state.value.text == "programmatic",
		"reopening the modal should restore a field initialized from the current app-owned query")
	controlled_text_field_visual_expect_visible_value(t, &rt, reopened_field, "programmatic")
}

@(test)
test_controlled_text_field_runtime_snapshot_released_on_destroy :: proc(t: ^testing.T) {
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)

	rt := new_runtime(
		Rect{0, 0, 320, 120},
		Runtime_Config{persistent_allocator=mem.tracking_allocator(&tracking)},
	)
	runtime_alive := true
	defer { if runtime_alive { destroy_runtime(&rt) } }
	state: Controlled_Text_Field_Test_State
	value, value_ok := text_field_buffer_init("owned", context.allocator)
	if !value_ok {
		testing.expect(t, false, "the app-owned field buffer should initialize")
		return
	}
	state.value = value
	defer text_field_buffer_destroy(&state.value)

	invalidate_root(&rt, "controlled field allocator lifecycle test")
	_ = controlled_text_field_test_render(&rt, &state)
	testing.expect(t, len(rt.controlled_text_fields) == 1,
		"the runtime should retain only its own committed-value snapshot for the active controlled field")
	if len(tracking.allocation_map) == 0 {
		testing.expect(t, false, "the runtime fixture should have tracked retained allocations before destruction")
		return
	}
	destroy_runtime(&rt)
	runtime_alive = false
	testing.expect(t, len(tracking.allocation_map) == 0,
		"runtime destruction should release the controlled-field snapshot and its sidecar storage")
}

text_input_allocator_test_render :: proc(rt: ^Runtime) -> Node_ID {
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin(&ui, .Root, key=key_string("text-input-allocator-root"), style=layout_style(.Column, grow=1))
	id := text_field(
		&ui,
		"seed",
		key=key_string("text-input-allocator-field"),
		style=layout_style(width=240, height=40),
	)
	container_end(&ui)
	end_frame(&ui)
	return id
}

@(test)
test_text_composition_projection_uses_runtime_allocator :: proc(t: ^testing.T) {
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)

	rt := new_runtime(
		Rect{0, 0, 320, 120},
		Runtime_Config{persistent_allocator=mem.tracking_allocator(&tracking)},
	)
	runtime_alive := true
	defer { if runtime_alive { destroy_runtime(&rt) } }
	if !text_engine_load_font(&rt.text_engine, TEXT_INPUT_ALLOCATOR_TEST_FONT) {
		testing.expect(t, false, "the composition allocator fixture should load its UI font")
		return
	}
	field := text_input_allocator_test_render(&rt)
	if field == 0 {
		testing.expect(t, false, "the composition allocator fixture should retain its text field")
		return
	}
	testing.expect(t, process_text_editing(&rt, field, "preedit", 0, 0),
		"a focused text field should accept a preedit update")
	updated_field := text_input_allocator_test_render(&rt)
	node, found := rt.nodes[updated_field]
	testing.expect(t, found && node.composition_run_valid && node.composition_run.value == "seedpreedit",
		"rendering IME preedit with a distinct runtime allocator should retain the projected run")

	destroy_runtime(&rt)
	runtime_alive = false
	testing.expect(t, len(tracking.allocation_map) == 0,
		"the runtime should release all preedit projection and retained allocations through their owners")
}
