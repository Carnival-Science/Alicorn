#+build !js

package testui

import "core:testing"
import alicorn "alicorn:runtime"
import host_menus "alicorn:host/menus"

Bindings_Test_App :: struct {
	commands:      [8]alicorn.Action_ID,
	command_count: int,
}

bindings_test_render :: proc(app: ^Bindings_Test_App, ui: ^alicorn.UI) {
	root := alicorn.container_begin(
		ui,
		.Root,
		label="bindings-root",
		key="bindings-root",
		style=alicorn.layout_style(.Column, grow=1, padding=8),
	)
	if root == 0 { return }
	_ = alicorn.button(
		ui, "Action", key="bindings-action",
		style=alicorn.layout_style(.Row, width=120, height=32),
	)
	alicorn.container_end(ui)
}

bindings_test_command :: proc(app: ^Bindings_Test_App, _rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
	if app == nil || app.command_count >= len(app.commands) { return }
	app.commands[app.command_count] = command
	app.command_count += 1
}

bindings_test_key :: proc(
	key: alicorn.Key_Spec,
	modifiers: alicorn.Key_Modifiers = {},
) -> alicorn.Binding_Key {
	return alicorn.Binding_Key{key=key, modifiers=modifiers}
}

bindings_test_primary_modifiers :: proc(shift := false) -> alicorn.Input_Modifiers {
	// Primary is Control on Windows/Linux and Command on macOS. Hosts normalize
	// platform modifier state before dispatch, so the fixture must too.
	modifiers: alicorn.Input_Modifiers
	when ODIN_OS == .Darwin {
		modifiers.super = true
	} else {
		modifiers.control = true
	}
	modifiers.shift = shift
	return modifiers
}

bindings_test_open :: proc(
	app: ^Bindings_Test_App,
	bindings: alicorn.Binding_Table,
) -> (handle: Test_Handle(Bindings_Test_App), status: Status) {
	return open(
		app,
		bindings_test_render,
		bindings=bindings,
		on_command=bindings_test_command,
	)
}

@(test)
test_testui_single_stroke_binding_dispatches_arbitrary_action_id :: proc(t: ^testing.T) {
	bindings := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(9001),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.F5, {.Primary})}},
			scope="Global",
		},
	}
	app: Bindings_Test_App
	handle, status := bindings_test_open(&app, alicorn.Binding_Table{bindings=bindings})
	if status != .Ok { testing.expect(t, false, "testui should open"); return }
	defer close(&handle)
	status = step(&handle, Input{kind=.Key, key=.F5, modifiers=bindings_test_primary_modifiers()})
	testing.expect_value(t, status, Status.Ok)
	testing.expect_value(t, app.command_count, 1)
	testing.expect_value(t, app.commands[0], alicorn.Action_ID(9001))
	testing.expect_value(t, last_turn(&handle).binding_command, alicorn.Action_ID(9001))
}

@(test)
test_testui_chord_pending_then_complete_and_timeout_returns_to_idle :: proc(t: ^testing.T) {
	bindings := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(910),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.K, {.Primary})}},
			scope="Global",
		},
		{
			command=alicorn.Action_ID(911),
			strokes=[][]alicorn.Binding_Key{{
				bindings_test_key(.K, {.Primary}), bindings_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
	}
	app: Bindings_Test_App
	handle, status := bindings_test_open(
		&app, alicorn.Binding_Table{bindings=bindings, chord_timeout_ns=500_000_000},
	)
	if status != .Ok { testing.expect(t, false, "testui should open"); return }
	defer close(&handle)

	status = step(&handle, Input{kind=.Key, key=.K, modifiers=bindings_test_primary_modifiers()})
	testing.expect_value(t, status, Status.Ok)
	testing.expect(t, last_turn(&handle).binding_pending, "the exact prefix is held pending")
	testing.expect(t, !handle.runtime.invalidated,
		"arming a chord does not invalidate or produce idle descriptions")
	testing.expect_value(t, last_turn(&handle).descriptions, 0)
	testing.expect_value(t, app.command_count, 0)

	status = step(&handle, Input{kind=.Key, key=.S, modifiers=bindings_test_primary_modifiers()})
	testing.expect_value(t, status, Status.Ok)
	testing.expect_value(t, app.command_count, 1)
	testing.expect_value(t, app.commands[0], alicorn.Action_ID(911))
	testing.expect(t, !last_turn(&handle).binding_pending)

	// Re-arm and let the virtual clock cross the chord deadline. The shorter
	// exact match fires, then the resolver is back to true idle.
	status = step(&handle, Input{kind=.Key, key=.K, modifiers=bindings_test_primary_modifiers()})
	testing.expect_value(t, status, Status.Ok)
	status = advance_time(&handle, 500_000_000)
	testing.expect_value(t, status, Status.Ok)
	testing.expect_value(t, app.command_count, 2)
	testing.expect_value(t, app.commands[1], alicorn.Action_ID(910))
	testing.expect(t, !last_turn(&handle).binding_pending)
	testing.expect(t, !handle.runtime.invalidated)
}

@(test)
test_testui_rebind_keeps_menu_accelerator_and_dispatch_synchronized :: proc(t: ^testing.T) {
	items := [1]alicorn.Menu_Item{
		{
			kind=.Command,
			command=alicorn.Action_ID(930),
			label="Save",
			state=alicorn.Action_State{enabled=true},
			shortcut=alicorn.Menu_Shortcut{'S', {.Primary}},
		},
	}
	menus := [1]alicorn.Menu{{label="Edit", items=items[:]}}
	service: host_menus.Menu_Service
	host_menus.menu_service_init(&service, menus[:], .Labels, nil, nil)
	bindings := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(930),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.S, {.Primary})}},
			scope="Global",
		},
	}
	app: Bindings_Test_App
	handle, status := bindings_test_open(&app, alicorn.Binding_Table{bindings=bindings})
	if status != .Ok { testing.expect(t, false, "testui should open"); return }
	defer close(&handle)

	command, found := host_menus.menu_service_match_shortcut(
		&service, 'S', alicorn.Menu_Modifiers{.Primary},
	)
	testing.expect(t, found && command == alicorn.Action_ID(930))
	_ = step(&handle, Input{kind=.Key, key=.S, modifiers=bindings_test_primary_modifiers()})
	testing.expect_value(t, app.command_count, 1)

	// The application remaps both borrowed surfaces. The native adapter would
	// refresh its labels from the same menu storage; testui proves dispatch and
	// the menu accelerator table read the updated values together.
	items[0].shortcut = alicorn.Menu_Shortcut{'J', {.Primary, .Shift}}
	host_menus.menu_service_update(&service, menus[:], .Labels)
	rebound := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(930),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.J, {.Primary, .Shift})}},
			scope="Global",
		},
	}
	set_bindings(&handle, alicorn.Binding_Table{bindings=rebound})

	_, old_found := host_menus.menu_service_match_shortcut(
		&service, 'S', alicorn.Menu_Modifiers{.Primary},
	)
	testing.expect(t, !old_found, "the old menu accelerator stops matching")
	command, found = host_menus.menu_service_match_shortcut(
		&service, 'J', alicorn.Menu_Modifiers{.Primary, .Shift},
	)
	testing.expect(t, found && command == alicorn.Action_ID(930))
	_ = step(&handle, Input{kind=.Key, key=.S, modifiers=bindings_test_primary_modifiers()})
	testing.expect_value(t, app.command_count, 1)
	_ = step(&handle, Input{
		kind=.Key, key=.J,
		modifiers=bindings_test_primary_modifiers(shift=true),
	})
	testing.expect_value(t, app.command_count, 2)
	testing.expect_value(t, app.commands[1], alicorn.Action_ID(930))
}

@(test)
test_testui_binding_cancel_cases_unmatched_pointer_and_rebind :: proc(t: ^testing.T) {
	bindings := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(920),
			strokes=[][]alicorn.Binding_Key{{
				bindings_test_key(.K, {.Primary}), bindings_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
	}
	app: Bindings_Test_App
	handle, status := bindings_test_open(&app, alicorn.Binding_Table{bindings=bindings})
	if status != .Ok { testing.expect(t, false, "testui should open"); return }
	defer close(&handle)

	// A key that is not a continuation abandons the chord and is reprocessed.
	_ = step(&handle, Input{kind=.Key, key=.K, modifiers=bindings_test_primary_modifiers()})
	_ = step(&handle, Input{kind=.Key, key=.P, modifiers=bindings_test_primary_modifiers()})
	testing.expect(t, !last_turn(&handle).binding_pending)
	testing.expect_value(t, app.command_count, 0)

	// Pointer-down cancels a pending chord.
	_ = step(&handle, Input{kind=.Key, key=.K, modifiers=bindings_test_primary_modifiers()})
	testing.expect(t, last_turn(&handle).binding_pending)
	_ = click_at(&handle, 16, 16)
	testing.expect(t, !last_turn(&handle).binding_pending)

	// A runtime rebind cancels pending work and moves dispatch to the new chord.
	rebound := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(921),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.J, {.Primary, .Shift})}},
			scope="Global",
		},
	}
	_ = step(&handle, Input{kind=.Key, key=.K, modifiers=bindings_test_primary_modifiers()})
	set_bindings(&handle, alicorn.Binding_Table{bindings=rebound})
	testing.expect(t, len(alicorn.binding_state_pending(&handle.binding_state)) == 0)
	_ = step(&handle, Input{kind=.Key, key=.K, modifiers=bindings_test_primary_modifiers()})
	_ = step(&handle, Input{kind=.Key, key=.S, modifiers=bindings_test_primary_modifiers()})
	testing.expect_value(t, app.command_count, 0)
	_ = step(&handle, Input{
		kind=.Key, key=.J,
		modifiers=bindings_test_primary_modifiers(shift=true),
	})
	testing.expect_value(t, app.command_count, 1)
	testing.expect_value(t, app.commands[0], alicorn.Action_ID(921))
}
