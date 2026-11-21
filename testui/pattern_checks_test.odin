package testui

import "core:testing"
import alicorn "alicorn:runtime"

// ---------------------------------------------------------------------------
// Stock Select positive control
// ---------------------------------------------------------------------------

STOCK_COMBO_LABELS := [12]string{
	"Alpha", "Beta", "Charlie", "Delta", "Echo", "Foxtrot",
	"Golf", "Hotel", "India", "Juliet", "Kilo", "Lima",
}
STOCK_COMBO_KEYS := [12]u64{10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120}
STOCK_COMBO_DISABLED := [12]bool{false, false, false, true, false, false, false, false, false, false, false, false}

Stock_Combo_App :: struct {
	selected: u64,
	peer_selected: u64,
	order: [12]int,
	reorder_bad: bool,
	reordered: bool,
	modal_open: bool,
	selections: int,
}

stock_combo_reset :: proc(app: ^Stock_Combo_App) {
	app.selected = 20
	app.peer_selected = 20
	for index in 0..<len(app.order) { app.order[index] = index }
}

stock_combo_label :: proc(app: ^Stock_Combo_App, index: int) -> string {
	label_index := index
	if app.reorder_bad && app.reordered { label_index = (index+1)%len(STOCK_COMBO_LABELS) }
	return STOCK_COMBO_LABELS[label_index]
}

stock_combo_render :: proc(app: ^Stock_Combo_App, ui: ^alicorn.UI) {
	group_one: [6]alicorn.Select_Option
	group_two: [6]alicorn.Select_Option
	for index in 0..<6 {
		option_index := app.order[index]
		group_one[index] = alicorn.Select_Option{
			key=STOCK_COMBO_KEYS[option_index],
			label=stock_combo_label(app, option_index),
			disabled=STOCK_COMBO_DISABLED[option_index],
		}
	}
	for index in 6..<12 {
		option_index := app.order[index]
		group_two[index-6] = alicorn.Select_Option{
			key=STOCK_COMBO_KEYS[option_index],
			label=stock_combo_label(app, option_index),
			disabled=STOCK_COMBO_DISABLED[option_index],
		}
	}
	groups := [2]alicorn.Select_Group{
		{label="Favorites", options=group_one[:]},
		{label="All choices", options=group_two[:]},
	}
	result := alicorn.select_control_grouped(
		ui,
		alicorn.key_string("stock-primary"),
		"Primary choice",
		groups[:],
		app.selected,
		style=alicorn.layout_style(.Row, height=36, width=260),
	)
	if result.changed {
		app.selected = result.selected_key
		app.selections += 1
	}

	peer_options := [4]alicorn.Select_Option{
		{key=10, label="Alpha"},
		{key=20, label="Beta"},
		{key=30, label="Charlie"},
		{key=40, label="Delta", disabled=true},
	}
	peer := alicorn.select_control(
		ui,
		alicorn.key_string("stock-peer"),
		"Peer choice",
		peer_options[:],
		app.peer_selected,
		style=alicorn.layout_style(.Row, height=36, width=260),
	)
	if peer.changed { app.peer_selected = peer.selected_key }

	if alicorn.button(ui, "Reorder options", key=alicorn.key_string("stock-reorder"), style=alicorn.layout_style(height=32, width=160)) {
		for index in 0..<3 {
			app.order[index], app.order[5-index] = app.order[5-index], app.order[index]
		}
		for index in 6..<9 {
			app.order[index], app.order[11-(index-6)] = app.order[11-(index-6)], app.order[index]
		}
		app.reordered = true
		alicorn.invalidate_root(ui.runtime, "stock fixture reordered options")
	}
	if alicorn.button(ui, "Open modal over select", key=alicorn.key_string("stock-open-modal"), style=alicorn.layout_style(height=32, width=180)) {
		app.modal_open = true
		alicorn.invalidate_root(ui.runtime, "stock fixture opened a background modal")
	}
}

stock_combo_overlays :: proc(app: ^Stock_Combo_App, ui: ^alicorn.UI) {
	if !app.modal_open { return }
	if alicorn.modal_overlay_begin(
		ui,
		alicorn.key_string("stock-background-modal"),
		style=alicorn.layout_style(.Column, align=.Center, justify=.Center),
	) == 0 { return }
	panel := alicorn.container_begin(
		ui,
		.Container,
		label="stock-background-modal-panel",
		style=alicorn.layout_style(.Column, width=360, height=150, padding=16, gap=10),
	)
	if panel != 0 {
		_ = alicorn.semantic_description(ui, .Dialog, "Background modal", "A modal drawn above the Select fixture.")
		_ = alicorn.text(ui, "The Select trigger is covered while this modal is open.", style=alicorn.layout_style(height=24))
		if alicorn.button(ui, "Close modal", key=alicorn.key_string("stock-close-modal"), style=alicorn.layout_style(height=32, width=120)) {
			app.modal_open = false
			alicorn.invalidate_root(ui.runtime, "stock fixture closed the background modal")
		}
		alicorn.container_end(ui)
	}
	alicorn.modal_overlay_end(ui)
}

stock_combo_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	app := cast(^Stock_Combo_App)state
	if key == .Escape && app.modal_open {
		app.modal_open = false
		alicorn.invalidate_root(rt, "stock fixture dismissed the background modal with Escape")
		return true
	}
	return false
}

@(test)
test_pattern_check_stock_select_conforms :: proc(t: ^testing.T) {
	app := Stock_Combo_App{}
	stock_combo_reset(&app)
	h, status := open(&app, stock_combo_render, width=520, height=420,
		render_overlays=stock_combo_overlays, on_key=stock_combo_on_key)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)

	parts := []Pattern_Part{
		{id=.Trigger, query=Query{role=.Combo_Box, name="Primary choice", match_role=true, match_name=true}},
		{id=.List, query=Query{role=.List_Box, name="Primary choice", match_role=true, match_name=true}},
		{id=.Target_Option, query=Query{role=.List_Box_Option, name="Kilo", match_role=true, match_name=true}},
		{id=.Disabled_Option, query=Query{role=.List_Box_Option, name="Delta", match_role=true, match_name=true}},
		{id=.Peer_Trigger, query=Query{role=.Combo_Box, name="Peer choice", match_role=true, match_name=true}},
		{id=.Extra_Action, query=Query{role=.Button, name="Reorder options", match_role=true, match_name=true}},
		{id=.Modal_Action, query=Query{role=.Button, name="Open modal over select", match_role=true, match_name=true}},
		{id=.Dialog, query=Query{role=.Dialog, name="Background modal", match_role=true, match_name=true}},
	}
	report := pattern_check(&h, Pattern_Config{
		kind=.Combobox_Listbox,
		parts=parts,
		expected_selected_key=20,
		expect_selected_key=true,
		expected_option_count=12,
		expect_option_count=true,
		expect_virtual_reveal=true,
		support_semantic_expand=true,
	})
	if !testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure)) { return }
	testing.expect(t, app.selections >= 1 && app.selected == 110,
		"keyboard selection should update the controlled key, and later parity phases should keep it")
}

// ---------------------------------------------------------------------------
// Custom userland combobox positive control and fault variants
// ---------------------------------------------------------------------------

CUSTOM_COMBO_NAMESPACE :: u64(0x435553544F4D0001)
CUSTOM_COMBO_LIST_ID :: alicorn.Semantic_ID{namespace=CUSTOM_COMBO_NAMESPACE, value=1000}
CUSTOM_COMBO_LABELS := [6]string{"Alpha", "Beta", "Charlie", "Delta", "Echo", "Foxtrot"}
CUSTOM_COMBO_KEYS := [6]u64{10, 20, 30, 40, 50, 60}

Custom_Combo_Fault :: enum {
	None,
	Not_Combo_Role,
	List_Unparented,
	Disabled_Advertises,
	Trigger_Not_Focusable,
}

Custom_Combo_App :: struct {
	selected: u64,
	active_key: u64,
	open: bool,
	fault: Custom_Combo_Fault,
	trigger_semantic: alicorn.Semantic_ID,
	activations: int,
}

custom_combo_option_id :: proc(key: u64) -> alicorn.Semantic_ID {
	return alicorn.Semantic_ID{namespace=CUSTOM_COMBO_NAMESPACE, value=key}
}

custom_combo_label :: proc(key: u64) -> string {
	for candidate, index in CUSTOM_COMBO_KEYS {
		if candidate == key { return CUSTOM_COMBO_LABELS[index] }
	}
	return ""
}

custom_combo_enabled :: proc(key: u64) -> bool {
	return key != 40
}

custom_combo_drain_requests :: proc(app: ^Custom_Combo_App, rt: ^alicorn.Runtime) {
	for {
		event, found := alicorn.semantic_request_pop(rt)
		if !found { break }
		node, node_found := alicorn.semantic_node_lookup(rt, event.id)
		if !node_found || node.role != .Combo_Box { continue }
		if event.action == .Expand && !app.open {
			app.open = true
			app.active_key = app.selected
		} else if event.action == .Collapse && app.open {
			app.open = false
		}
	}
}

custom_combo_move :: proc(app: ^Custom_Combo_App, direction: int) {
	count := len(CUSTOM_COMBO_KEYS)
	start := 0
	for key, index in CUSTOM_COMBO_KEYS { if key == app.active_key { start = index; break } }
	for offset in 1..=count {
		index := (start+direction*offset) % count
		for index < 0 { index += count }
		key := CUSTOM_COMBO_KEYS[index]
		if custom_combo_enabled(key) {
			app.active_key = key
			return
		}
	}
}

custom_combo_render :: proc(app: ^Custom_Combo_App, ui: ^alicorn.UI) {
	custom_combo_drain_requests(app, ui.runtime)
	display := custom_combo_label(app.selected)
	if len(display) == 0 { display = "Choose" }
	focusable := app.fault != .Trigger_Not_Focusable
	trigger, activated := alicorn.button_begin(
		ui,
		display,
		key=alicorn.key_string("custom-combo"),
		style=alicorn.layout_style(.Row, width=260, height=36, padding=10, gap=6, align=.Center),
		presentation=.Custom,
		focusable=focusable,
	)
	if trigger != 0 {
		app.trigger_semantic = alicorn.semantic_visual_id(trigger)
		if app.fault != .Not_Combo_Role {
			states := alicorn.Semantic_States{}
			actions := alicorn.Semantic_Actions{}
			if focusable { actions = alicorn.semantic_actions_add(actions, .Focus) }
			if app.open {
				states = alicorn.semantic_states_add(states, .Expanded)
				actions = alicorn.semantic_actions_add(actions, .Collapse)
			} else {
				actions = alicorn.semantic_actions_add(actions, .Expand)
			}
			_ = alicorn.semantic_description(ui, .Combo_Box, "Custom choice", value=display, states=states, actions=actions)
		}
		if app.open { _ = alicorn.text_input_target(ui, trigger) }
		_ = alicorn.text(ui, display, style=alicorn.layout_style(.Row, height=24, grow=1))
		_ = alicorn.text(ui, "v", style=alicorn.layout_style(.Row, width=16, height=24))
		alicorn.button_end(ui)
		if activated && focusable {
			app.open = !app.open
			if app.open { app.active_key = app.selected }
			alicorn.invalidate_root(ui.runtime, "custom combo trigger activated")
		}
	}
	if alicorn.button(ui, "Custom after", key=alicorn.key_string("custom-after"), style=alicorn.layout_style(height=32, width=120)) {
		// Focus target for Tab close; the button body intentionally has no model effect.
	}
}

custom_combo_overlays :: proc(app: ^Custom_Combo_App, ui: ^alicorn.UI) {
	if !app.open { return }
	overlay := alicorn.container_begin_simple(
		ui,
		.Container,
		label="custom-combo-overlay",
		key=alicorn.key_string("custom-combo-overlay"),
		style=alicorn.layout_style(.Column, width=f32(ui.runtime.viewport.w), height=f32(ui.runtime.viewport.h), align=.Center, justify=.Center),
		color=alicorn.Color{0.02, 0.025, 0.04, 0.28},
	)
	if overlay == 0 { return }
	panel := alicorn.container_begin(
		ui,
		.Container,
		label="custom-combo-panel",
		style=alicorn.layout_style(.Column, width=300, height=250, padding=8, gap=2),
	)
	if panel != 0 {
		list := alicorn.container_begin(
			ui,
			.Container,
			label="custom-combo-list",
			style=alicorn.layout_style(.Column, grow=1, gap=2),
		)
		if list != 0 {
			selected_id := custom_combo_option_id(app.selected)
			current_id := custom_combo_option_id(app.active_key)
			collection_parent := app.trigger_semantic
			if app.fault == .List_Unparented { collection_parent = {} }
			collection := alicorn.semantic_collection_begin(
				ui,
				list,
				CUSTOM_COMBO_LIST_ID,
				.List_Box,
				"Custom choice options",
				u64(len(CUSTOM_COMBO_KEYS)),
				selected_id=selected_id,
				current_id=current_id,
				realized_first=0,
				realized_last=u64(len(CUSTOM_COMBO_KEYS)),
				actions=alicorn.semantic_actions_add({}, .Focus),
				parent=collection_parent,
			)
			for key, index in CUSTOM_COMBO_KEYS {
				enabled := custom_combo_enabled(key)
				advertise_disabled := app.fault == .Disabled_Advertises && !enabled
				option, option_activated := alicorn.button_begin(
					ui,
					custom_combo_label(key),
					key=alicorn.key_pair(u64(app.trigger_semantic.value), key),
					style=alicorn.layout_style(.Row, height=32, padding=8),
					state=alicorn.Button_State{disabled=!enabled},
					presentation=.Custom,
					focusable=enabled || advertise_disabled,
				)
				if option != 0 {
					states := alicorn.Semantic_States{}
					actions := alicorn.Semantic_Actions{}
					if key == app.selected { states = alicorn.semantic_states_add(states, .Selected) }
					if !enabled {
						states = alicorn.semantic_states_add(states, .Disabled)
						if advertise_disabled {
							actions = alicorn.semantic_actions_add(actions, .Select)
							actions = alicorn.semantic_actions_add(actions, .Focus)
						}
					} else {
						actions = alicorn.semantic_actions_add(actions, .Select)
						actions = alicorn.semantic_actions_add(actions, .Focus)
					}
					_ = alicorn.semantic_collection_item(ui, collection, u64(index), alicorn.Semantic_Node_Description{
						id=custom_combo_option_id(key),
						role=.List_Box_Option,
						label=custom_combo_label(key),
						value=custom_combo_label(key),
						states=states,
						actions=actions,
					})
					_ = alicorn.text(ui, custom_combo_label(key), style=alicorn.layout_style(.Row, height=24, grow=1))
					alicorn.button_end(ui)
					if option_activated && enabled {
						app.selected = key
						app.open = false
						app.activations += 1
						alicorn.invalidate_root(ui.runtime, "custom combo option selected")
					}
				}
			}
			alicorn.container_end(ui)
		}
		alicorn.container_end(ui)
	}
	alicorn.container_end(ui)
}

custom_combo_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	app := cast(^Custom_Combo_App)state
	if !app.open { return false }
	#partial switch key {
	case .Escape:
		app.open = false
		alicorn.invalidate_root(rt, "custom combo canceled")
		return true
	case .Return:
		if custom_combo_enabled(app.active_key) {
			app.selected = app.active_key
			app.activations += 1
		}
		app.open = false
		alicorn.invalidate_root(rt, "custom combo committed")
		return true
	case .Down:
		custom_combo_move(app, 1)
		alicorn.invalidate_root(rt, "custom combo moved down")
		return true
	case .Up:
		custom_combo_move(app, -1)
		alicorn.invalidate_root(rt, "custom combo moved up")
		return true
	case .Home:
		for key in CUSTOM_COMBO_KEYS {
			if custom_combo_enabled(key) { app.active_key = key; break }
		}
		alicorn.invalidate_root(rt, "custom combo moved home")
		return true
	case .End:
		for index := len(CUSTOM_COMBO_KEYS)-1; index >= 0; index -= 1 {
			if custom_combo_enabled(CUSTOM_COMBO_KEYS[index]) { app.active_key = CUSTOM_COMBO_KEYS[index]; break }
		}
		alicorn.invalidate_root(rt, "custom combo moved end")
		return true
	case:
		return false
	}
}

custom_combo_focus_next :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	_ = alicorn.application_dispatch_tab_focus(rt, false)
}

custom_combo_on_text_key :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	app := cast(^Custom_Combo_App)state
	if !app.open { return false }
	if event.key == .Tab {
		app.open = false
		alicorn.invalidate_root(rt, "custom combo tabbed away")
		_ = alicorn.interaction_after_frame_register(rt, rawptr(app), custom_combo_focus_next)
		return true
	}
	if event.key == .Home {
		for key in CUSTOM_COMBO_KEYS {
			if custom_combo_enabled(key) { app.active_key = key; break }
		}
		alicorn.invalidate_root(rt, "custom combo home through text-key route")
		return true
	}
	if event.key == .End {
		for index := len(CUSTOM_COMBO_KEYS)-1; index >= 0; index -= 1 {
			if custom_combo_enabled(CUSTOM_COMBO_KEYS[index]) { app.active_key = CUSTOM_COMBO_KEYS[index]; break }
		}
		alicorn.invalidate_root(rt, "custom combo end through text-key route")
		return true
	}
	return false
}

custom_combo_on_text_input :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Input_Event,
) {
	app := cast(^Custom_Combo_App)state
	if !app.open || event.kind != .Commit || len(event.text) == 0 { return }
	matched := false
	for key in CUSTOM_COMBO_KEYS {
		if !custom_combo_enabled(key) { continue }
		label := custom_combo_label(key)
		if len(label) < len(event.text) { continue }
		ok := true
		for index in 0..<len(event.text) {
			left := label[index]
			right := event.text[index]
			if left >= 'A' && left <= 'Z' { left += 'a'-'A' }
			if right >= 'A' && right <= 'Z' { right += 'a'-'A' }
			if left != right { ok = false; break }
		}
		if ok { app.active_key = key; matched = true; break }
	}
	if matched { alicorn.invalidate_root(rt, "custom combo type-ahead") }
}

@(test)
test_pattern_check_custom_combobox_conforms :: proc(t: ^testing.T) {
	app := Custom_Combo_App{selected=20, active_key=20}
	h, status := open(&app, custom_combo_render, width=520, height=420,
		render_overlays=custom_combo_overlays,
		on_key=custom_combo_on_key,
		on_text_key=custom_combo_on_text_key,
		on_text_input=custom_combo_on_text_input)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)

	parts := []Pattern_Part{
		{id=.Trigger, query=Query{role=.Combo_Box, name="Custom choice", match_role=true, match_name=true}},
		{id=.List, query=Query{role=.List_Box, name="Custom choice options", match_role=true, match_name=true}},
		{id=.Target_Option, query=Query{role=.List_Box_Option, name="Echo", match_role=true, match_name=true}},
		{id=.Disabled_Option, query=Query{role=.List_Box_Option, name="Delta", match_role=true, match_name=true}},
	}
	report := pattern_check(&h, Pattern_Config{
		kind=.Combobox_Listbox,
		parts=parts,
		expected_selected_key=20,
		expect_selected_key=true,
		expected_option_count=6,
		expect_option_count=true,
	})
	if !testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure)) { return }
	testing.expect(t, app.selected == 50 && app.activations > 0,
		"the custom userland control should observe the same driven selection contract")
}

// ---------------------------------------------------------------------------
// App-owned modal dialog positive control and a non-modal fault variant
// ---------------------------------------------------------------------------

Modal_Pattern_App :: struct {
	open: bool,
	nested_open: bool,
	transient_visible: bool,
	focus_pending: bool,
	nested_focus_pending: bool,
	primary_activations: int,
	secondary_activations: int,
	background_activations: int,
}

modal_pattern_focus_opener :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	if id, found := alicorn.node_by_key(rt, alicorn.key_string("modal-open-dialog"), .Button); found {
		_ = alicorn.focus(rt, id)
	}
}

modal_pattern_focus_primary :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	if id, found := alicorn.node_by_key(rt, alicorn.key_string("dialog-confirm"), .Button); found {
		_ = alicorn.focus(rt, id)
	}
}

modal_pattern_focus_nested_close :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	if id, found := alicorn.node_by_key(rt, alicorn.key_string("dialog-nested-close"), .Button); found {
		_ = alicorn.focus(rt, id)
	}
}

modal_pattern_focus_nested_opener :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	if id, found := alicorn.node_by_key(rt, alicorn.key_string("dialog-nested-open"), .Button); found {
		_ = alicorn.focus(rt, id)
	}
}

modal_pattern_close_dialog :: proc(app: ^Modal_Pattern_App, ui: ^alicorn.UI) {
	app.open = false
	app.nested_open = false
	alicorn.invalidate_root(ui.runtime, "modal pattern dialog dismissed")
	_ = alicorn.interaction_after_frame_register(ui.runtime, rawptr(app), modal_pattern_focus_opener)
}

modal_pattern_render :: proc(app: ^Modal_Pattern_App, ui: ^alicorn.UI) {
	if alicorn.button(ui, "Open dialog", key=alicorn.key_string("modal-open-dialog"), style=alicorn.layout_style(height=34, width=140)) {
		app.open = true
		app.transient_visible = true
		app.focus_pending = true
		alicorn.invalidate_root(ui.runtime, "modal pattern dialog opened")
	}
	if alicorn.button(ui, "Background action", key=alicorn.key_string("modal-background-action"), style=alicorn.layout_style(height=34, width=160)) {
		app.background_activations += 1
	}
	_ = alicorn.text(ui, "The modal must own focus, pointer input, and activation.", style=alicorn.layout_style(height=24))
}

modal_pattern_overlays :: proc(app: ^Modal_Pattern_App, ui: ^alicorn.UI) {
	if app.open {
		if alicorn.modal_overlay_begin(
			ui,
			alicorn.key_string("modal-pattern-overlay"),
			style=alicorn.layout_style(.Column, align=.Center, justify=.Center),
			backdrop_color=alicorn.Color{0.01, 0.02, 0.04, 0.74},
		) != 0 {
			panel := alicorn.container_begin(
				ui,
				.Container,
				label="modal-pattern-panel",
				style=alicorn.layout_style(.Column, width=440, height=380, padding=20, gap=10),
			)
			if panel != 0 {
				_ = alicorn.semantic_description(ui, .Dialog, "Confirm record deletion", "A modal confirmation with destructive and cancel actions.")
				_ = alicorn.text(ui, "Confirm record deletion", style=alicorn.layout_style(height=28))
				_ = alicorn.text(ui, "This fixture proves the checker follows the composed control, not runtime internals.", style=alicorn.layout_style(height=24))
				if alicorn.button(ui, "Confirm", key=alicorn.key_string("dialog-confirm"), style=alicorn.layout_style(height=32, width=110)) {
					app.primary_activations += 1
					modal_pattern_close_dialog(app, ui)
				}
				if alicorn.button(ui, "Cancel", key=alicorn.key_string("dialog-cancel"), style=alicorn.layout_style(height=32, width=110)) {
					app.secondary_activations += 1
					modal_pattern_close_dialog(app, ui)
				}
				if app.transient_visible {
					if alicorn.button(ui, "Remove transient action", key=alicorn.key_string("dialog-remove"), style=alicorn.layout_style(height=30, width=180)) {
						app.transient_visible = false
						alicorn.invalidate_root(ui.runtime, "modal pattern transient action removed")
					}
					if alicorn.button(ui, "Transient action", key=alicorn.key_string("dialog-transient"), style=alicorn.layout_style(height=30, width=140)) {
						// Deliberately inert; its only job is to hold focus before removal.
					}
				}
				if alicorn.button(ui, "Open details", key=alicorn.key_string("dialog-nested-open"), style=alicorn.layout_style(height=30, width=120)) {
					app.nested_open = true
					app.nested_focus_pending = true
					alicorn.invalidate_root(ui.runtime, "modal pattern nested dialog opened")
				}
				if app.focus_pending {
					app.focus_pending = false
					_ = alicorn.interaction_after_frame_register(ui.runtime, rawptr(app), modal_pattern_focus_primary)
				}
				alicorn.container_end(ui)
			}
			alicorn.modal_overlay_end(ui)
		}
	}
	if app.open && app.nested_open {
		if alicorn.modal_overlay_begin(
			ui,
			alicorn.key_string("modal-pattern-nested-overlay"),
			style=alicorn.layout_style(.Column, align=.Center, justify=.Center),
			backdrop_color=alicorn.Color{0.1, 0.02, 0.02, 0.6},
		) != 0 {
			panel := alicorn.container_begin(
				ui,
				.Container,
				label="modal-pattern-nested-panel",
				style=alicorn.layout_style(.Column, width=300, height=150, padding=16, gap=10),
			)
			if panel != 0 {
				_ = alicorn.semantic_description(ui, .Dialog, "Details dialog", "A nested dialog over the confirmation.")
				_ = alicorn.text(ui, "Details dialog", style=alicorn.layout_style(height=26))
				if alicorn.button(ui, "Close details", key=alicorn.key_string("dialog-nested-close"), style=alicorn.layout_style(height=32, width=130)) {
					app.nested_open = false
					alicorn.invalidate_root(ui.runtime, "modal pattern nested dialog closed")
					_ = alicorn.interaction_after_frame_register(ui.runtime, rawptr(app), modal_pattern_focus_nested_opener)
				}
				if app.nested_focus_pending {
					app.nested_focus_pending = false
					_ = alicorn.interaction_after_frame_register(ui.runtime, rawptr(app), modal_pattern_focus_nested_close)
				}
				alicorn.container_end(ui)
			}
			alicorn.modal_overlay_end(ui)
		}
	}
}

modal_pattern_on_key :: proc(state: rawptr, rt: ^alicorn.Runtime, key: alicorn.Application_Key) -> bool {
	app := cast(^Modal_Pattern_App)state
	if key != .Escape { return false }
	if app.nested_open {
		app.nested_open = false
		alicorn.invalidate_root(rt, "modal pattern nested dialog dismissed by Escape")
		_ = alicorn.interaction_after_frame_register(rt, rawptr(app), modal_pattern_focus_nested_opener)
		return true
	}
	if app.open {
		app.open = false
		app.nested_open = false
		alicorn.invalidate_root(rt, "modal pattern dialog dismissed by Escape")
		_ = alicorn.interaction_after_frame_register(rt, rawptr(app), modal_pattern_focus_opener)
		return true
	}
	return false
}

@(test)
test_pattern_check_app_owned_modal_dialog_conforms :: proc(t: ^testing.T) {
	app := Modal_Pattern_App{transient_visible=true}
	h, status := open(&app, modal_pattern_render, width=640, height=480,
		render_overlays=modal_pattern_overlays, on_key=modal_pattern_on_key)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)
	parts := []Pattern_Part{
		{id=.Trigger, query=Query{role=.Button, name="Open dialog", match_role=true, match_name=true}},
		{id=.Dialog, query=Query{role=.Dialog, name="Confirm record deletion", match_role=true, match_name=true}},
		{id=.Primary_Action, query=Query{role=.Button, name="Confirm", match_role=true, match_name=true}},
		{id=.Secondary_Action, query=Query{role=.Button, name="Cancel", match_role=true, match_name=true}},
		{id=.Background_Action, query=Query{role=.Button, name="Background action", match_role=true, match_name=true}},
		{id=.Transient_Action, query=Query{role=.Button, name="Transient action", match_role=true, match_name=true}},
		{id=.Extra_Action, query=Query{role=.Button, name="Remove transient action", match_role=true, match_name=true}},
		{id=.Nested_Action, query=Query{role=.Button, name="Open details", match_role=true, match_name=true}},
		{id=.Nested_Dialog, query=Query{role=.Dialog, name="Details dialog", match_role=true, match_name=true}},
	}
	report := pattern_check(&h, Pattern_Config{kind=.Modal_Dialog, parts=parts})
	if !testing.expect(t, report.ok, pattern_failure_diagnostic(&report.failure)) { return }
	testing.expect(t, app.background_activations == 0,
		"a covered background control must never observe activation while the modal is open")
	testing.expect(t, app.primary_activations >= 3,
		"pointer, keyboard, and semantic primary activation should all reach the application")
}

Bad_Modal_Fault :: enum {
	Background_Focusable,
}

Bad_Modal_App :: struct {
	open: bool,
	fault: Bad_Modal_Fault,
	focus_pending: bool,
	background_activations: int,
	primary_activations: int,
}

bad_modal_focus_confirm :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	if id, found := alicorn.node_by_key(rt, alicorn.key_string("bad-dialog-confirm"), .Button); found {
		_ = alicorn.focus(rt, id)
	}
}

bad_modal_render :: proc(app: ^Bad_Modal_App, ui: ^alicorn.UI) {
	if alicorn.button(ui, "Open dialog", key=alicorn.key_string("bad-open-dialog"), style=alicorn.layout_style(height=34, width=140)) {
		app.open = true
		app.focus_pending = true
		alicorn.invalidate_root(ui.runtime, "bad modal opened")
	}
	if alicorn.button(ui, "Background action", key=alicorn.key_string("bad-background"), style=alicorn.layout_style(height=34, width=160)) {
		app.background_activations += 1
	}
}

bad_modal_overlays :: proc(app: ^Bad_Modal_App, ui: ^alicorn.UI) {
	if !app.open { return }
	// Deliberately not a modal_overlay_begin: this draws above the page but
	// leaves the background in the ordinary focus and semantic activation scope.
	overlay := alicorn.container_begin_simple(
		ui,
		.Container,
		label="bad-modal-overlay",
		key=alicorn.key_string("bad-modal-overlay"),
		style=alicorn.layout_style(.Column, width=f32(ui.runtime.viewport.w), height=f32(ui.runtime.viewport.h), align=.Center, justify=.Center),
		color=alicorn.Color{0.02, 0.02, 0.02, 0.6},
	)
	if overlay == 0 { return }
	panel := alicorn.container_begin(ui, .Container, label="bad-modal-panel", style=alicorn.layout_style(.Column, width=360, height=180, padding=16, gap=10))
	if panel != 0 {
		_ = alicorn.semantic_description(ui, .Dialog, "Not really modal", "A composed overlay that forgot the modal focus scope.")
		if alicorn.button(ui, "Confirm", key=alicorn.key_string("bad-dialog-confirm"), style=alicorn.layout_style(height=32, width=110)) {
			app.primary_activations += 1
			app.open = false
			alicorn.invalidate_root(ui.runtime, "bad modal confirmed")
		}
		if alicorn.button(ui, "Cancel", key=alicorn.key_string("bad-dialog-cancel"), style=alicorn.layout_style(height=32, width=110)) {
			app.open = false
			alicorn.invalidate_root(ui.runtime, "bad modal canceled")
		}
		if app.focus_pending {
			app.focus_pending = false
			_ = alicorn.interaction_after_frame_register(ui.runtime, rawptr(app), bad_modal_focus_confirm)
		}
		alicorn.container_end(ui)
	}
	alicorn.container_end(ui)
}

@(test)
test_pattern_check_negative_background_left_focusable :: proc(t: ^testing.T) {
	app := Bad_Modal_App{}
	h, status := open(&app, bad_modal_render, width=640, height=480, render_overlays=bad_modal_overlays)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)
	parts := []Pattern_Part{
		{id=.Trigger, query=Query{role=.Button, name="Open dialog", match_role=true, match_name=true}},
		{id=.Dialog, query=Query{role=.Dialog, name="Not really modal", match_role=true, match_name=true}},
		{id=.Primary_Action, query=Query{role=.Button, name="Confirm", match_role=true, match_name=true}},
		{id=.Background_Action, query=Query{role=.Button, name="Background action", match_role=true, match_name=true}},
	}
	report := pattern_check(&h, Pattern_Config{kind=.Modal_Dialog, parts=parts})
	if !testing.expect(t, !report.ok, "a background control left focusable must fail the modal pattern") { return }
	testing.expect(t, report.failure.step == .Containment,
		pattern_failure_diagnostic(&report.failure))
}

// ---------------------------------------------------------------------------
// Negative controls: each must fail at a specific contract step
// ---------------------------------------------------------------------------

run_custom_combo_fault :: proc(t: ^testing.T, fault: Custom_Combo_Fault, expected: Pattern_Step) {
	app := Custom_Combo_App{selected=20, active_key=20, fault=fault}
	h, status := open(&app, custom_combo_render, width=520, height=420,
		render_overlays=custom_combo_overlays,
		on_key=custom_combo_on_key,
		on_text_key=custom_combo_on_text_key,
		on_text_input=custom_combo_on_text_input)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)
	parts := []Pattern_Part{
		{id=.Trigger, query=Query{key=alicorn.key_string("custom-combo"), match_key=true}},
		{id=.List, query=Query{role=.List_Box, name="Custom choice options", match_role=true, match_name=true}},
		{id=.Target_Option, query=Query{role=.List_Box_Option, name="Echo", match_role=true, match_name=true}},
		{id=.Disabled_Option, query=Query{role=.List_Box_Option, name="Delta", match_role=true, match_name=true}},
	}
	report := pattern_check(&h, Pattern_Config{
		kind=.Combobox_Listbox,
		parts=parts,
		expected_option_count=6,
		expect_option_count=true,
	})
	if !testing.expect(t, !report.ok, "the fault variant must fail") { return }
	testing.expect(t, report.failure.step == expected, pattern_failure_diagnostic(&report.failure))
}

@(test)
test_pattern_check_negative_missing_combo_box_role :: proc(t: ^testing.T) {
	run_custom_combo_fault(t, .Not_Combo_Role, .Static_Contract)
}

@(test)
test_pattern_check_negative_list_not_parented_to_trigger :: proc(t: ^testing.T) {
	run_custom_combo_fault(t, .List_Unparented, .Static_Contract)
}

@(test)
test_pattern_check_negative_disabled_option_advertises_actions :: proc(t: ^testing.T) {
	run_custom_combo_fault(t, .Disabled_Advertises, .Static_Contract)
}

@(test)
test_pattern_check_negative_trigger_missing_focus :: proc(t: ^testing.T) {
	run_custom_combo_fault(t, .Trigger_Not_Focusable, .Static_Contract)
}

@(test)
test_pattern_check_negative_stale_key_binding_after_reorder :: proc(t: ^testing.T) {
	app := Stock_Combo_App{reorder_bad=true}
	stock_combo_reset(&app)
	h, status := open(&app, stock_combo_render, width=520, height=420,
		render_overlays=stock_combo_overlays, on_key=stock_combo_on_key)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)
	parts := []Pattern_Part{
		{id=.Trigger, query=Query{role=.Combo_Box, name="Primary choice", match_role=true, match_name=true}},
		{id=.List, query=Query{role=.List_Box, name="Primary choice", match_role=true, match_name=true}},
		{id=.Target_Option, query=Query{role=.List_Box_Option, name="Kilo", match_role=true, match_name=true}},
		{id=.Disabled_Option, query=Query{role=.List_Box_Option, name="Delta", match_role=true, match_name=true}},
		{id=.Extra_Action, query=Query{role=.Button, name="Reorder options", match_role=true, match_name=true}},
	}
	report := pattern_check(&h, Pattern_Config{
		kind=.Combobox_Listbox,
		parts=parts,
		expected_selected_key=20,
		expect_selected_key=true,
		expected_option_count=12,
		expect_option_count=true,
		support_semantic_expand=true,
	})
	if !testing.expect(t, !report.ok, "a stale key/label binding after reorder must fail") { return }
	testing.expect(t, report.failure.step == .Reorder_Identity, pattern_failure_diagnostic(&report.failure))
}
