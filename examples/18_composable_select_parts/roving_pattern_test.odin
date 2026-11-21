package main

// Positive list control for the Roving_List pattern check. The popup is the
// copyable select_parts package; the pattern opens it through the trigger and
// asserts the package's published roving contract, including wrap, disabled
// skipping, activation, and focus restoration.

import "core:testing"
import alicorn "alicorn:runtime"
import testui "alicorn:testui"
import theme "alicorn:theme"
import parts "./select_parts"

ROVING_LIST_COUNT :: 6

ROVING_LIST_LABELS := [ROVING_LIST_COUNT]string{
	"Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot",
}

Roving_List_App :: struct {
	selected: u64,
	state:    parts.Select_Parts_State,
	recipe:   parts.Select_Parts_Recipe,
	theme:    alicorn.Style_Theme_ID,
	options:  [ROVING_LIST_COUNT]parts.Select_Parts_Option,
	groups:   [1]parts.Select_Parts_Group,
}

roving_list_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Roving_List_App)state
	registration := theme.theme_json_register(rt, string(parts.DEFAULT_THEME_JSON), "examples/18_composable_select_parts/select_parts/theme.json")
	defer theme.theme_json_register_result_destroy(&registration)
	app.theme = registration.theme_id
	for label, index in ROVING_LIST_LABELS {
		app.options[index] = parts.Select_Parts_Option{
			key=u64(index+1),
			label=label,
			disabled=index == 3,
		}
	}
	app.groups[0] = parts.Select_Parts_Group{options=app.options[:]}
	app.selected = 2
	app.state.selected_key = app.selected
}

roving_list_build :: proc(state: rawptr, rt: ^alicorn.Runtime, width, height: int, scale: f32) -> alicorn.Node_ID {
	app := cast(^Roving_List_App)state
	ctx, build := alicorn.begin_frame(rt)
	if !build { return 0 }
	root := alicorn.container_begin(&ctx, .Root, label="roving-list-root", key=alicorn.key_string("roving-list-root"),
		style=alicorn.layout_style(.Column, width=340, height=240, padding=12))
	scope := alicorn.style_environment_push(&ctx, alicorn.Style_Environment{theme=app.theme})
	if parts.select_parts(
		&ctx,
		"Roving list",
		&app.state,
		app.groups[:],
		app.recipe,
		key=alicorn.key_string("roving-list-select"),
		instance_id=9911,
	) {
		app.selected = app.state.selected_key
	}
	alicorn.style_environment_pop(&ctx, scope)
	alicorn.container_end(&ctx)
	_ = parts.select_parts_overlay(&ctx, "Roving list", &app.state, app.groups[:], app.recipe, 9911)
	alicorn.end_frame(&ctx)
	return root
}

roving_list_on_text_input :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Input_Event,
) {
	app := cast(^Roving_List_App)state
	if event.kind == .Commit && len(event.text) > 0 && app.state.open {
		_ = parts.select_parts_text(rt, &app.state, app.groups[:], event.text)
	}
}

roving_list_on_text_key :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	app := cast(^Roving_List_App)state
	if app.state.open { return parts.select_parts_text_key(rt, &app.state, app.groups[:], event) }
	return false
}

@(test)
test_pattern_check_roving_list_conforms :: proc(t: ^testing.T) {
	app := Roving_List_App{}
	app.recipe = parts.recipe_default()
	handle, status := testui.open(
		&app,
		width=360,
		height=260,
		initialize=roving_list_initialize,
		build_application=roving_list_build,
		on_text_key=roving_list_on_text_key,
		on_text_input=roving_list_on_text_input,
	)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) {
		if handle.runtime != nil { testui.close(&handle) }
		return
	}
	defer testui.close(&handle)

	pattern_parts := []testui.Pattern_Part{
		{id=.Trigger, query=testui.Query{role=.Combo_Box, name="Roving list", match_role=true, match_name=true}},
		{id=.Container, query=testui.Query{role=.List_Box, name="Roving list", match_role=true, match_name=true}},
		{id=.Target_Option, query=testui.Query{role=.List_Box_Option, name="Foxtrot", match_role=true, match_name=true}},
		{id=.Disabled_Option, query=testui.Query{role=.List_Box_Option, name="Delta", match_role=true, match_name=true}},
	}
	report := testui.pattern_check(&handle, testui.Pattern_Config{
		kind=.Roving_List,
		parts=pattern_parts,
		roving=testui.Pattern_Roving_Config{
			focus=.Item,
			wrap=true,
			expect_reveal=true,
			activation_closes=true,
			expect_selection=true,
			expect_escape_restore=true,
		},
	})
	if !testing.expect(t, report.ok, testui.pattern_failure_diagnostic(&report.failure)) {
		testing.expectf(t, !app.state.open, "select_parts state should be closed after keyboard activation (open=%v selected=%d active=%d)",
			app.state.open, app.selected, app.state.active_index)
		return
	}
	testing.expect_value(t, app.selected, u64(6))
}
