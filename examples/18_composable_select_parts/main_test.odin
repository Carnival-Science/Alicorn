package main

import "core:fmt"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"
import parts "./select_parts"
import testui "alicorn:testui"
import theme "alicorn:theme"

select_parts_test_open :: proc(app: ^App) -> (handle: testui.Test_Handle(App), status: testui.Status) {
	app_prepare(app)
	handle, status = testui.open(
		app,
		width=1080,
		height=560,
		initialize=initialize,
		build_application=build_application,
		on_text_input=proc(state: rawptr, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Application_Text_Input_Event) {
			app := cast(^App)state
			if event.kind == .Commit && len(event.text) > 0 {
				if app.compact.open {
					_ = parts.select_parts_text(rt, &app.compact, app.compact_groups[:], event.text)
				} else if app.rich.open {
					_ = parts.select_parts_text(rt, &app.rich, app.rich_groups[:], event.text)
				}
			}
		},
		on_text_key=proc(state: rawptr, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Application_Text_Key_Event) -> bool {
			app := cast(^App)state
			if app.compact.open { return parts.select_parts_text_key(rt, &app.compact, app.compact_groups[:], event) }
			if app.rich.open { return parts.select_parts_text_key(rt, &app.rich, app.rich_groups[:], event) }
			return false
		},
	)
	return
}

select_parts_test_find :: proc(
	handle: ^testui.Test_Handle(App),
	role: alicorn.Semantic_Role,
	name: string,
) -> testui.Find_Result {
	return testui.find(handle, testui.Query{role=role, name=name, match_role=true, match_name=true})
}

select_parts_parity_options :: proc() -> [4]alicorn.Select_Option {
	return {
		{key=10, label="Alpha"},
		{key=20, label="Beta"},
		{key=30, label="Charlie"},
		{key=40, label="Unavailable", disabled=true},
	}
}

select_parts_parity_parts_options :: proc() -> [4]parts.Select_Parts_Option {
	return {
		{key=10, label="Alpha", icon=.Info, badge="A"},
		{key=20, label="Beta", icon=.Settings, badge="B"},
		{key=30, label="Charlie", icon=.Terminal, badge="C"},
		{key=40, label="Unavailable", disabled=true, icon=.Warning},
	}
}

Stock_Parity_App :: struct {
	selected: u64,
}

stock_parity_build :: proc(state: rawptr, rt: ^alicorn.Runtime, width, height: int, scale: f32) -> alicorn.Node_ID {
	app := cast(^Stock_Parity_App)state
	ctx, build := alicorn.begin_frame(rt)
	if !build { return 0 }
	root := alicorn.container_begin(&ctx, .Root, label="stock-parity-root", key="stock-parity-root",
		style=alicorn.layout_style(.Column, width=320, height=240, padding=12))
	options := select_parts_parity_options()
	result := alicorn.select_control(&ctx, alicorn.key_string("parity-select"), "Theme", options[:], app.selected)
	if result.changed { app.selected = result.selected_key }
	alicorn.container_end(&ctx)
	alicorn.end_frame(&ctx)
	return root
}

Parts_Parity_App :: struct {
	selected: u64,
	state: parts.Select_Parts_State,
	recipe: parts.Select_Parts_Recipe,
	theme: alicorn.Style_Theme_ID,
	grouped: bool,
	options: [4]parts.Select_Parts_Option,
	groups: [2]parts.Select_Parts_Group,
	group_count: int,
}

parts_parity_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Parts_Parity_App)state
	registration := theme.theme_json_register(rt, string(parts.DEFAULT_THEME_JSON), "examples/18_composable_select_parts/select_parts/theme.json")
	defer theme.theme_json_register_result_destroy(&registration)
	app.theme = registration.theme_id
	app.options = select_parts_parity_parts_options()
	app.groups[0] = parts.Select_Parts_Group{options=app.options[:]}
	app.group_count = 1
	if app.grouped {
		app.groups[0] = parts.Select_Parts_Group{label="Everyday", options=app.options[:2]}
		app.groups[1] = parts.Select_Parts_Group{label="Specialized", options=app.options[2:]}
		app.group_count = 2
	}
}

parts_parity_build :: proc(state: rawptr, rt: ^alicorn.Runtime, width, height: int, scale: f32) -> alicorn.Node_ID {
	app := cast(^Parts_Parity_App)state
	ctx, build := alicorn.begin_frame(rt)
	if !build { return 0 }
	root := alicorn.container_begin(&ctx, .Root, label="parts-parity-root", key="parts-parity-root",
		style=alicorn.layout_style(.Column, width=360, height=260, padding=12))
	scope := alicorn.style_environment_push(&ctx, alicorn.Style_Environment{theme=app.theme})
	_ = parts.select_parts(&ctx, "Theme", &app.state, app.groups[:app.group_count], app.recipe, key=alicorn.key_string("parity-select"), instance_id=9001)
	alicorn.style_environment_pop(&ctx, scope)
	alicorn.container_end(&ctx)
	_ = parts.select_parts_overlay(&ctx, "Theme", &app.state, app.groups[:app.group_count], app.recipe, 9001)
	alicorn.end_frame(&ctx)
	return root
}

Semantic_Record :: struct {
	role: string,
	label: string,
	value: string,
	parent: string,
	states: string,
	actions: string,
	logical_count: u64,
	selected: string,
	current: string,
}

select_parts_parent_name :: proc(by_id: map[alicorn.Semantic_ID]alicorn.Semantic_Node, id: alicorn.Semantic_ID) -> string {
	if id.namespace == 0 && id.value == 0 { return "" }
	if node, found := by_id[id]; found {
		return fmt.tprintf("%v:%s", node.role, node.label)
	}
	return "<missing>"
}

select_parts_semantic_records :: proc(rt: ^alicorn.Runtime) -> []Semantic_Record {
	records: [dynamic]Semantic_Record
	snapshot := alicorn.semantic_snapshot(rt)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	by_id := make(map[alicorn.Semantic_ID]alicorn.Semantic_Node)
	defer delete(by_id)
	for node in snapshot.nodes { by_id[node.id] = node }
	for node in snapshot.nodes {
		#partial switch node.role {
		case .Combo_Box, .List_Box, .List_Box_Option, .Group:
			append(&records, Semantic_Record{
				role=fmt.tprintf("%v", node.role),
				label=node.label,
				value=node.value,
				parent=select_parts_parent_name(by_id, node.parent),
				states=fmt.tprintf("%v", node.states),
				actions=fmt.tprintf("%v", node.actions),
				logical_count=node.logical_count,
				selected=select_parts_parent_name(by_id, node.selected_id),
				current=select_parts_parent_name(by_id, node.current_id),
			})
		}
	}
	return records[:]
}

select_parts_record_sort :: proc(a, b: Semantic_Record) -> bool {
	if a.role != b.role { return a.role < b.role }
	if a.label != b.label { return a.label < b.label }
	return a.parent < b.parent
}

select_parts_sort_records :: proc(records: []Semantic_Record) {
	for index in 1..<len(records) {
		value := records[index]
		cursor := index
		for cursor > 0 && select_parts_record_sort(value, records[cursor-1]) {
			records[cursor] = records[cursor-1]
			cursor -= 1
		}
		records[cursor] = value
	}
}

@(test)
test_select_parts_smoke_open_navigate_and_select :: proc(t: ^testing.T) {
	app := app_default()
	handle, status := select_parts_test_open(&app)
	defer testui.close(&handle)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }

	trigger := select_parts_test_find(&handle, .Combo_Box, "Rendering preset")
	defer testui.destroy_find_result(&trigger)
	if !testing.expect(t, trigger.match == .Unique && trigger.element.has_bounds, "the parts trigger should publish Combo_Box semantics with bounds") { return }
	if !testing.expect(t, testui.click(&handle, &trigger.element) == .Ok, "clicking the trigger should open the parts popup") { return }
	testing.expect(t, app.compact.open, "the package state should record the open popup")
	list := select_parts_test_find(&handle, .List_Box, "Rendering preset")
	defer testui.destroy_find_result(&list)
	testing.expect(t, list.match == .Unique && list.element.has_bounds, "the popup should publish an anchored List_Box")
	beta := select_parts_test_find(&handle, .List_Box_Option, "Balanced")
	defer testui.destroy_find_result(&beta)
	testing.expect(t, beta.match == .Unique && alicorn.semantic_states_has(beta.element.states, .Selected),
		"the selected option should be published as a selected List_Box_Option")

	before := app.compact.selected_key
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Down})
	testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle))
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Return})
	testing.expect(t, status == .Ok && !app.compact.open && app.compact.selected_key != before,
		"Down+Return should move the active option and return one controlled change")
	testing.expect(t, alicorn.focused_node(handle.runtime) == app.compact.trigger_node,
		"closing the popup should restore focus to the trigger after reconciliation")
}

@(test)
test_select_parts_semantic_parity_with_stock_select :: proc(t: ^testing.T) {
	stock := Stock_Parity_App{selected=20}
	stock_handle, stock_status := testui.open(&stock, width=320, height=240, build_application=stock_parity_build)
	defer if stock_handle.runtime != nil { testui.close(&stock_handle) }
	if !testing.expect(t, stock_status == .Ok, testui.last_turn_diagnostic(&stock_handle)) { return }
	stock_trigger := testui.find(&stock_handle, testui.Query{role=.Combo_Box, name="Theme", match_role=true, match_name=true})
	defer testui.destroy_find_result(&stock_trigger)
	if !testing.expect(t, stock_trigger.match == .Unique, "the stock trigger should be found") { return }
	if !testing.expect(t, testui.click(&stock_handle, &stock_trigger.element) == .Ok, "the stock Select should open") { return }
	stock_records := select_parts_semantic_records(stock_handle.runtime)
	defer delete(stock_records)
	select_parts_sort_records(stock_records)

	parity_app := Parts_Parity_App{selected=20, recipe=parts.recipe_default(.Compact)}
	parity_app.state.selected_key = 20
	parts_handle, parts_status := testui.open(&parity_app, width=320, height=240,
		initialize=parts_parity_initialize, build_application=parts_parity_build)
	defer if parts_handle.runtime != nil { testui.close(&parts_handle) }
	if !testing.expect(t, parts_status == .Ok, testui.last_turn_diagnostic(&parts_handle)) { return }
	parts_trigger := testui.find(&parts_handle, testui.Query{role=.Combo_Box, name="Theme", match_role=true, match_name=true})
	defer testui.destroy_find_result(&parts_trigger)
	if !testing.expect(t, parts_trigger.match == .Unique, "the parts trigger should be found") { return }
	if !testing.expect(t, parts_trigger.element.has_bounds, "parts trigger should have bounds") {
		fmt.println("PARTS BOUNDS", parts_trigger.element.bounds, parts_trigger.element.hit_bounds)
		return
	}
	parts_click := testui.click(&parts_handle, &parts_trigger.element)
	if !testing.expect(t, parts_click == .Ok, "the Parts Select should open") { return }
	parts_records := select_parts_semantic_records(parts_handle.runtime)
	defer delete(parts_records)
	select_parts_sort_records(parts_records)

	testing.expect(t, len(stock_records) == len(parts_records),
		"the stock and parts popups should publish the same number of semantic roles")
	limit := min(len(stock_records), len(parts_records))
	for index in 0..<limit {
		stock_record, parts_record := stock_records[index], parts_records[index]
		testing.expect(t,
			stock_record.role == parts_record.role &&
			stock_record.label == parts_record.label &&
			stock_record.value == parts_record.value &&
			stock_record.parent == parts_record.parent &&
			stock_record.states == parts_record.states &&
			stock_record.actions == parts_record.actions &&
			stock_record.logical_count == parts_record.logical_count &&
			stock_record.selected == parts_record.selected &&
			stock_record.current == parts_record.current,
			fmt.tprintf("semantic mismatch at %d: stock %v parts %v", index, stock_record, parts_record))
	}
}


Behavior_App :: struct {
	a, b: parts.Select_Parts_State,
	recipe: parts.Select_Parts_Recipe,
	options: [6]parts.Select_Parts_Option,
	option_count: int,
	groups: [1]parts.Select_Parts_Group,
	theme: alicorn.Style_Theme_ID,
	modal: bool,
	before_clicks: int,
	after_clicks: int,
}

behavior_options :: proc() -> [6]parts.Select_Parts_Option {
	return {
		{key=10, label="Alpha"},
		{key=20, label="Beta"},
		{key=30, label="Charlie"},
		{key=40, label="Delta", disabled=true},
		{key=50, label="Echo"},
		{key=60, label="Foxtrot"},
	}
}

behavior_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^Behavior_App)state
	registration := theme.theme_json_register(rt, string(parts.DEFAULT_THEME_JSON), "examples/18_composable_select_parts/select_parts/theme.json")
	defer theme.theme_json_register_result_destroy(&registration)
	app.theme = registration.theme_id
}

behavior_build :: proc(state: rawptr, rt: ^alicorn.Runtime, width, height: int, scale: f32) -> alicorn.Node_ID {
	app := cast(^Behavior_App)state
	ctx, build := alicorn.begin_frame(rt)
	if !build { return 0 }
	root := alicorn.container_begin(&ctx, .Root, label="behavior-root", key="behavior-root",
		style=alicorn.layout_style(.Column, width=420, height=360, padding=10, gap=8))
	scope := alicorn.style_environment_push(&ctx, alicorn.Style_Environment{theme=app.theme})
	if ui_button_before := alicorn.button(&ctx, "Before", key=alicorn.key_string("behavior-before"),
		style=alicorn.layout_style(width=100, height=30)); ui_button_before { app.before_clicks += 1 }
	app.groups[0] = parts.Select_Parts_Group{options=app.options[:app.option_count]}
	_ = parts.select_parts(&ctx, "First choice", &app.a, app.groups[:], app.recipe,
		key=alicorn.key_string("behavior-first"), instance_id=701)
	_ = parts.select_parts(&ctx, "Second choice", &app.b, app.groups[:], app.recipe,
		key=alicorn.key_string("behavior-second"), instance_id=702)
	if alicorn.button(&ctx, "After", key=alicorn.key_string("behavior-after"),
		style=alicorn.layout_style(width=100, height=30)) { app.after_clicks += 1 }
	alicorn.style_environment_pop(&ctx, scope)
	alicorn.container_end(&ctx)
	if app.modal {
		if alicorn.modal_overlay_begin(&ctx, key=alicorn.key_string("behavior-modal")) != 0 {
			_ = alicorn.button(&ctx, "Modal owner", key=alicorn.key_string("behavior-modal-owner"),
				style=alicorn.layout_style(width=160, height=32))
			alicorn.modal_overlay_end(&ctx)
		}
	}
	_ = parts.select_parts_overlay(&ctx, "First choice", &app.a, app.groups[:], app.recipe, 701)
	_ = parts.select_parts_overlay(&ctx, "Second choice", &app.b, app.groups[:], app.recipe, 702)
	alicorn.end_frame(&ctx)
	return root
}

behavior_open :: proc(app: ^Behavior_App) -> (handle: testui.Test_Handle(Behavior_App), status: testui.Status) {
	app.recipe = parts.recipe_default(.Compact)
	app.options = behavior_options()
	app.option_count = 6
	app.a.selected_key = 20
	app.b.selected_key = 20
	app.groups[0] = parts.Select_Parts_Group{options=app.options[:app.option_count]}
	return testui.open(app, width=420, height=360, initialize=behavior_initialize, build_application=behavior_build,
		on_text_input=proc(state: rawptr, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Application_Text_Input_Event) {
			app := cast(^Behavior_App)state
			if event.kind != .Commit || len(event.text) == 0 { return }
			if app.a.open { _ = parts.select_parts_text(rt, &app.a, app.groups[:], event.text) }
			else if app.b.open { _ = parts.select_parts_text(rt, &app.b, app.groups[:], event.text) }
		},
		on_text_key=proc(state: rawptr, rt: ^alicorn.Runtime, owner: alicorn.Node_ID, event: alicorn.Application_Text_Key_Event) -> bool {
			app := cast(^Behavior_App)state
			if app.a.open { return parts.select_parts_text_key(rt, &app.a, app.groups[:], event) }
			if app.b.open { return parts.select_parts_text_key(rt, &app.b, app.groups[:], event) }
			return false
		},
	)
}

behavior_click_trigger :: proc(handle: ^testui.Test_Handle(Behavior_App), name: string) -> testui.Status {
	found := testui.find(handle, testui.Query{role=.Combo_Box, name=name, match_role=true, match_name=true})
	defer testui.destroy_find_result(&found)
	if found.match != .Unique { return .Not_Realized }
	return testui.click(handle, &found.element)
}

behavior_rebuild :: proc(handle: ^testui.Test_Handle(Behavior_App)) -> testui.Status {
	alicorn.invalidate_root(handle.runtime, "behavior fixture rebuild")
	return testui.step(handle, testui.Input{kind=.Time_Advance, delta_ns=0})
}

@(test)
test_select_parts_keyboard_navigation_typeahead_and_disabled_parity :: proc(t: ^testing.T) {
	app := Behavior_App{}
	handle, status := behavior_open(&app)
	defer testui.close(&handle)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }
	if !testing.expect(t, behavior_click_trigger(&handle, "First choice") == .Ok, "the first parts select should open") { return }

	status = testui.step(&handle, testui.Input{kind=.Key, key=.End})
	testing.expect(t, status == .Ok && app.a.active_key == 60,
		"End should land on the last enabled option and skip the disabled Delta row")
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Home})
	testing.expect(t, status == .Ok && app.a.active_key == 10, "Home should land on the first enabled option")
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Down})
	testing.expect(t, status == .Ok && app.a.active_key == 20, "Down should advance to the next enabled option")
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Down})
	testing.expect(t, status == .Ok && app.a.active_key == 30, "Down should keep crossing enabled options")
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Up})
	testing.expect(t, status == .Ok && app.a.active_key == 20, "Up should return to the previous enabled option")

	status = testui.step(&handle, testui.Input{kind=.Text_Commit, text="c"})
	testing.expect(t, status == .Ok && app.a.active_key == 30, "case-insensitive type-ahead should select Charlie")
	status = testui.step(&handle, testui.Input{kind=.Text_Commit, text="e"})
	testing.expect(t, status == .Ok && app.a.active_key == 50, "type-ahead prefixes should extend across enabled options")
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Return})
	testing.expect(t, status == .Ok && app.a.selected_key == 50 && !app.a.open,
		"Return should choose the active option and close exactly one controlled change")
	testing.expect(t, alicorn.focused_node(handle.runtime) == app.a.trigger_node,
		"Return should restore focus to the first trigger")
}

@(test)
test_select_parts_escape_outside_click_and_tab_focus_restore :: proc(t: ^testing.T) {
	app := Behavior_App{}
	handle, status := behavior_open(&app)
	defer testui.close(&handle)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }

	if !testing.expect(t, behavior_click_trigger(&handle, "First choice") == .Ok, "the first select should open") { return }
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Escape})
	testing.expect(t, status == .Ok && !app.a.open && alicorn.focused_node(handle.runtime) == app.a.trigger_node,
		"Escape should close and restore trigger focus")
	if !testing.expect(t, behavior_click_trigger(&handle, "First choice") == .Ok, "the first select should reopen") { return }
	status = testui.step(&handle, testui.Input{kind=.Pointer, pointer=alicorn.Pointer_Event{
		kind=.Down, x=410, y=350, button=alicorn.POINTER_BUTTON_PRIMARY}})
	status = testui.step(&handle, testui.Input{kind=.Pointer, pointer=alicorn.Pointer_Event{
		kind=.Up, x=410, y=350, button=alicorn.POINTER_BUTTON_PRIMARY}})
	testing.expect(t, status == .Ok && !app.a.open, "an outside pointer press should dismiss the parts popup")
	testing.expect(t, alicorn.focused_node(handle.runtime) == app.a.trigger_node,
		"outside dismissal should restore trigger focus")

	if !testing.expect(t, behavior_click_trigger(&handle, "First choice") == .Ok, "the first select should reopen for Tab") { return }
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Tab})
	testing.expect(t, status == .Ok && !app.a.open, "Tab should close the parts popup")
	testing.expect(t, alicorn.focused_node(handle.runtime) == app.b.trigger_node,
		"Tab should advance focus to the next focusable control after the trigger")
	if !testing.expect(t, behavior_click_trigger(&handle, "Second choice") == .Ok, "the second select should open") { return }
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Tab, modifiers=alicorn.Input_Modifiers{shift=true}})
	testing.expect(t, status == .Ok && !app.b.open, "Shift+Tab should close the second popup")
	testing.expect(t, alicorn.focused_node(handle.runtime) == app.a.trigger_node,
		"Shift+Tab should traverse backward from the second trigger")
}

@(test)
test_select_parts_two_owner_instances_and_application_owned_identity :: proc(t: ^testing.T) {
	app := Behavior_App{}
	handle, status := behavior_open(&app)
	defer testui.close(&handle)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }

	testing.expect(t, parts.select_parts_option_id(701, 20) != parts.select_parts_option_id(702, 20),
		"the same stable option key should have different semantic identity in two owner instances")
	testing.expect(t, parts.select_parts_option_id(701, 20) == parts.select_parts_option_id(701, 20),
		"one owner instance should retain stable option identity across descriptions")

	if !testing.expect(t, behavior_click_trigger(&handle, "First choice") == .Ok, "the first select should open") { return }
	_ = testui.step(&handle, testui.Input{kind=.Text_Commit, text="echo"})
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Return})
	testing.expect(t, status == .Ok && app.a.selected_key == 50 && app.b.selected_key == 20,
		"selecting in the first owner must not mutate the second application-owned selection")
	trigger := testui.find(&handle, testui.Query{role=.Combo_Box, name="First choice", match_role=true, match_name=true})
	testing.expect(t, trigger.match == .Unique && trigger.element.value == "Echo",
		"the first trigger should display the newly controlled value")
	testui.destroy_find_result(&trigger)
}

@(test)
test_select_parts_reorder_and_deletion_preserve_stable_selected_key :: proc(t: ^testing.T) {
	app := Behavior_App{}
	handle, status := behavior_open(&app)
	defer testui.close(&handle)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }

	app.options[0] = parts.Select_Parts_Option{key=10, label="Alpha"}
	app.options[1] = parts.Select_Parts_Option{key=30, label="Charlie"}
	app.options[2] = parts.Select_Parts_Option{key=20, label="Beta"}
	app.options[3] = parts.Select_Parts_Option{key=40, label="Delta", disabled=true}
	app.options[4] = parts.Select_Parts_Option{key=50, label="Echo"}
	app.options[5] = parts.Select_Parts_Option{key=60, label="Foxtrot"}
	status = behavior_rebuild(&handle)
	testing.expect(t, status == .Ok && app.a.selected_key == 20, "reordering options must preserve the selected key")
	trigger := testui.find(&handle, testui.Query{role=.Combo_Box, name="First choice", match_role=true, match_name=true})
	testing.expect(t, trigger.match == .Unique && trigger.element.value == "Beta",
		"the trigger should resolve the stable selected key after reordering")
	testui.destroy_find_result(&trigger)

	app.option_count = 5 // delete Foxtrot (key 60) from the source projection
	status = behavior_rebuild(&handle)
	testing.expect(t, status == .Ok && app.a.selected_key == 20,
		"deleting an unrelated option must leave the selected key intact")
	if !testing.expect(t, behavior_click_trigger(&handle, "First choice") == .Ok, "the reordered select should open") { return }
	beta := testui.find(&handle, testui.Query{role=.List_Box_Option, name="Beta", match_role=true, match_name=true})
	testing.expect(t, beta.match == .Unique && alicorn.semantic_states_has(beta.element.states, .Selected),
		"the same stable key should remain the selected semantic option after reorder and deletion")
	testui.destroy_find_result(&beta)
}

@(test)
test_select_parts_modal_overlay_blocks_nested_popup_and_teardown_is_clean :: proc(t: ^testing.T) {
	app := Behavior_App{}
	handle, status := behavior_open(&app)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }
	if !testing.expect(t, behavior_click_trigger(&handle, "First choice") == .Ok, "the first select should open") { return }

	app.modal = true
	status = behavior_rebuild(&handle)
	testing.expect(t, status == .Ok && !app.a.open && !app.b.open,
		"a foreign modal overlay should close an open parts popup rather than nesting another transient layer")

	// Force a trigger activation while the foreign modal remains retained. The
	// package must refuse to open and must not describe a second modal layer.
	handle.runtime.activation_sequence += 1
	handle.runtime.activation_node = app.a.trigger_node
	alicorn.invalidate_root(handle.runtime, "forced nested activation test")
	status = testui.step(&handle, testui.Input{kind=.Time_Advance, delta_ns=0})
	testing.expect(t, status == .Ok && !app.a.open, "nested activation must not open a parts popup over a modal")
	testing.expect(t, alicorn.modal_overlay_root(handle.runtime) != 0,
		"the foreign modal should remain the active transient layer")

	app.modal = false
	status = behavior_rebuild(&handle)
	testing.expect(t, status == .Ok, "the fixture should settle after removing the modal")
	testing.expect(t, !handle.runtime.invalidated && !alicorn.presentation_needs_frame(handle.runtime),
		"a settled parts fixture should have no pending descriptions or presentations")
	_ = behavior_click_trigger(&handle, "First choice")
	testui.close(&handle)
	testing.expect(t, true, "teardown with an open popup or retained overlay must not crash")
}

@(test)
test_select_parts_appearance_switch_preserves_semantic_identity :: proc(t: ^testing.T) {
	app := Parts_Parity_App{selected=20, recipe=parts.recipe_default(.Compact)}
	app.state.selected_key = 20
	handle, status := testui.open(&app, width=360, height=280,
		initialize=parts_parity_initialize, build_application=parts_parity_build)
	defer testui.close(&handle)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }
	trigger := testui.find(&handle, testui.Query{role=.Combo_Box, name="Theme", match_role=true, match_name=true})
	if !testing.expect(t, trigger.match == .Unique, "the compact trigger should exist") { testui.destroy_find_result(&trigger); return }
	opened := testui.click(&handle, &trigger.element)
	testui.destroy_find_result(&trigger)
	if !testing.expect(t, opened == .Ok, "the compact appearance should open") { return }

	compact_trigger_id := app.state.trigger_semantic_id
	compact_list_id := app.state.list_semantic_id
	compact_ids: [4]alicorn.Semantic_ID
	for key, index in ([4]u64{10, 20, 30, 40}) { compact_ids[index] = parts.select_parts_option_id(9001, key) }
	compact_selected := app.state.selected_key

	status = testui.step(&handle, testui.Input{kind=.Key, key=.Escape})
	if !testing.expect(t, status == .Ok && !app.state.open, "Escape should close the compact appearance") { return }
	app.recipe = parts.recipe_default(.Rich)
	alicorn.invalidate_root(handle.runtime, "switch to rich appearance")
	status = testui.step(&handle, testui.Input{kind=.Time_Advance, delta_ns=1})
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }
	trigger = testui.find(&handle, testui.Query{role=.Combo_Box, name="Theme", match_role=true, match_name=true})
	if !testing.expect(t, trigger.match == .Unique, "the rich trigger should exist") { testui.destroy_find_result(&trigger); return }
	opened = testui.click(&handle, &trigger.element)
	testui.destroy_find_result(&trigger)
	if !testing.expect(t, opened == .Ok, "the rich appearance should open") { return }

	testing.expect(t, app.state.trigger_semantic_id == compact_trigger_id &&
		app.state.list_semantic_id == compact_list_id && app.state.selected_key == compact_selected,
		"switching appearance must preserve trigger, list, and selected identities")
	for key, index in ([4]u64{10, 20, 30, 40}) {
		testing.expect(t, parts.select_parts_option_id(9001, key) == compact_ids[index],
			"stable option keys must retain their semantic identity across appearances")
	}
	beta := testui.find(&handle, testui.Query{role=.List_Box_Option, name="Beta", match_role=true, match_name=true})
	defer testui.destroy_find_result(&beta)
	testing.expect(t, beta.match == .Unique && alicorn.semantic_states_has(beta.element.states, .Selected),
		"the rich appearance should keep the same selected semantic option")
	if beta.match == .Unique && beta.element.visual_node != 0 {
		icon_label := false
		badge_label := false
		for id in handle.runtime.order {
			node, found := handle.runtime.nodes[id]
			if !found { continue }
			if node.label == "select-parts-row-icon" { icon_label = true }
			if node.label == "select-parts-row-badge" { badge_label = true }
		}
		testing.expect(t, icon_label, "the rich appearance should contribute an icon child under option Buttons")
		testing.expect(t, badge_label, "the rich appearance should contribute badge children under option Buttons")
	}
}

@(test)
test_select_parts_idle_time_and_ime_preedit_leave_no_residual_wake :: proc(t: ^testing.T) {
	app := Behavior_App{}
	handle, status := behavior_open(&app)
	defer testui.close(&handle)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }
	if !testing.expect(t, behavior_click_trigger(&handle, "First choice") == .Ok, "the first select should open") { return }

	status = testui.step(&handle, testui.Input{
		kind=.Text_Preedit,
		text="ae",
		composition_start_char=0,
		composition_length_char=2,
	})
	testing.expect(t, status == .Ok && app.a.open,
		"IME preedit should be yielded by the modal scope and leave the popup open")
	status = testui.advance_time(&handle, 16_000_000)
	testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle))
	testing.expect(t, !handle.runtime.invalidated && !alicorn.presentation_needs_frame(handle.runtime),
		"the settled parts fixture should not schedule another description or presentation wake")
}

@(test)
test_select_parts_group_headers_expose_group_parents_without_counting_header_rows :: proc(t: ^testing.T) {
	app := Parts_Parity_App{selected=20, recipe=parts.recipe_default(.Compact), grouped=true}
	app.state.selected_key = 20
	handle, status := testui.open(&app, width=360, height=280,
		initialize=parts_parity_initialize, build_application=parts_parity_build)
	defer testui.close(&handle)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }
	trigger := testui.find(&handle, testui.Query{role=.Combo_Box, name="Theme", match_role=true, match_name=true})
	if !testing.expect(t, trigger.match == .Unique, "the grouped trigger should exist") { testui.destroy_find_result(&trigger); return }
	opened := testui.click(&handle, &trigger.element)
	testui.destroy_find_result(&trigger)
	if !testing.expect(t, opened == .Ok, "the grouped select should open") { return }

	everyday := testui.find(&handle, testui.Query{role=.Group, name="Everyday", match_role=true, match_name=true})
	defer testui.destroy_find_result(&everyday)
	testing.expect(t, everyday.match == .Unique, "labeled groups should publish a semantic Group header")
	if everyday.match == .Unique {
		alpha := testui.find(&handle, testui.Query{role=.List_Box_Option, name="Alpha", match_role=true, match_name=true})
		defer testui.destroy_find_result(&alpha)
		alpha_node, alpha_found := alicorn.semantic_node_lookup(handle.runtime, alpha.element.semantic_id)
		testing.expect(t, alpha.match == .Unique && alpha_found &&
			alpha_node.parent == everyday.element.semantic_id,
			"a labeled group's option should name that Group as its semantic parent")
	}
	list := testui.find(&handle, testui.Query{role=.List_Box, name="Theme", match_role=true, match_name=true})
	defer testui.destroy_find_result(&list)
	testing.expect(t, list.match == .Unique,
		"the List_Box should keep its semantic identity while group headers are present")
	if list.match == .Unique {
		testing.expect(t, list.element.semantic_id == app.state.list_semantic_id,
			"the popup should keep the package-owned List_Box identity")
	}
}

@(test)
test_select_parts_pointer_option_click_and_disabled_row :: proc(t: ^testing.T) {
	app := Behavior_App{}
	handle, status := behavior_open(&app)
	defer testui.close(&handle)
	if !testing.expect(t, status == .Ok, testui.last_turn_diagnostic(&handle)) { return }
	if !testing.expect(t, behavior_click_trigger(&handle, "First choice") == .Ok, "the first select should open") { return }

	disabled := testui.find(&handle, testui.Query{role=.List_Box_Option, name="Delta", match_role=true, match_name=true})
	if testing.expect(t, disabled.match == .Unique, "the disabled option should still be published") {
		clicked := testui.click(&handle, &disabled.element)
		testing.expect(t, clicked != .Ok && app.a.open && app.a.selected_key == 20,
			"a disabled option must not be hit-testable or change the controlled value")
	}
	testui.destroy_find_result(&disabled)

	echo := testui.find(&handle, testui.Query{role=.List_Box_Option, name="Echo", match_role=true, match_name=true})
	if !testing.expect(t, echo.match == .Unique, "the enabled option should be published") { testui.destroy_find_result(&echo); return }
	clicked := testui.click(&handle, &echo.element)
	testui.destroy_find_result(&echo)
	testing.expect(t, clicked == .Ok && !app.a.open && app.a.selected_key == 50,
		"a pointer click on a rich row should close the popup and return the stable key")
	testing.expect(t, alicorn.focused_node(handle.runtime) == app.a.trigger_node,
		"pointer option activation should restore trigger focus")
}
