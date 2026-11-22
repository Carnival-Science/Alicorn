#+build !js

package alicorn

import "core:testing"

Hosted_Bindings_Test_App :: struct {
	commands:     [8]Action_ID,
	command_count: int,
	keys:         [8]u32,
	key_count:    int,
}

hosted_bindings_test_render :: proc(data: rawptr, ui: ^UI, _width, _height: int, _dpi: f32) {
	root := container_begin(
		ui,
		.Root,
		label="hosted-bindings-root",
		key="hosted-bindings-root",
		style=layout_style(.Column, grow=1),
	)
	if root != 0 { container_end(ui) }
}

hosted_bindings_test_post :: proc(_data: rawptr) -> bool { return true }

hosted_bindings_test_command :: proc(data: rawptr, _rt: ^Runtime, command: Action_ID) {
	app := cast(^Hosted_Bindings_Test_App)data
	if app != nil && app.command_count < len(app.commands) {
		app.commands[app.command_count] = command
		app.command_count += 1
	}
}

hosted_bindings_test_key :: proc(data: rawptr, _rt: ^Runtime, _owner: Node_ID, event: Hosted_Key_Event) -> bool {
	app := cast(^Hosted_Bindings_Test_App)data
	if app != nil && app.key_count < len(app.keys) {
		app.keys[app.key_count] = event.key_code
		app.key_count += 1
	}
	return true
}

hosted_bindings_test_open :: proc(
	app: ^Hosted_Bindings_Test_App,
	bindings: Binding_Table,
) -> (host: Hosted_Runtime, ok: bool) {
	status := hosted_runtime_init(&host, Hosted_Runtime_Config{
		state=rawptr(app),
		logical_width=320,
		logical_height=200,
		pixel_width=320,
		pixel_height=200,
		dpi_scale=1,
		render=hosted_bindings_test_render,
		post_wake_data=rawptr(app),
		post_wake=hosted_bindings_test_post,
		bindings=bindings,
		on_command=hosted_bindings_test_command,
		on_key=hosted_bindings_test_key,
	})
	return host, status == .Ok
}

@(test)
test_hosted_key_event_dispatches_binding_outside_application_key_vocabulary :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{
			command=Action_ID(900),
			strokes=[][]Binding_Key{{{key=.S, modifiers={.Primary}}}},
			scope="Global",
			description="Application-owned save",
		},
	}
	app: Hosted_Bindings_Test_App
	host, ok := hosted_bindings_test_open(&app, Binding_Table{bindings=bindings, chord_timeout_ns=500_000_000})
	if !ok { testing.expect(t, false, "hosted runtime should initialize"); return }
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1_000)

	handled, status := hosted_runtime_key_event(&host, Key_Event{
		key=.S,
		modifiers={.Primary},
		application_key=.Find,
		has_application_key=true,
	})
	testing.expect(t, status == .Ok && handled)
	testing.expect_value(t, app.command_count, 1)
	testing.expect_value(t, app.commands[0], Action_ID(900))
	testing.expect(t, app.key_count == 0,
		"a consumed binding does not also reach the legacy on_key callback")
}

@(test)
test_hosted_key_event_chord_and_timeout_scheduled_wake :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{
			command=Action_ID(910),
			strokes=[][]Binding_Key{{
				{key=.K, modifiers={.Primary}},
				{key=.S, modifiers={.Primary}},
			}},
			scope="Global",
		},
		{
			command=Action_ID(911),
			strokes=[][]Binding_Key{{{key=.G, modifiers={.Primary}}}},
			scope="Global",
		},
		{
			command=Action_ID(912),
			strokes=[][]Binding_Key{{
				{key=.G, modifiers={.Primary}},
				{key=.G, modifiers={.Primary}},
			}},
			scope="Global",
		},
	}
	app: Hosted_Bindings_Test_App
	host, ok := hosted_bindings_test_open(&app, Binding_Table{bindings=bindings, chord_timeout_ns=500_000_000})
	if !ok { testing.expect(t, false, "hosted runtime should initialize"); return }
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1_000)

	handled, _ := hosted_runtime_key_event(&host, Key_Event{key=.K, modifiers={.Primary}})
	testing.expect(t, handled)
	pending, pending_status := hosted_runtime_binding_pending(&host)
	testing.expect(t, pending_status == .Ok && len(pending) == 1)
	handled, _ = hosted_runtime_key_event(&host, Key_Event{key=.S, modifiers={.Primary}})
	testing.expect(t, handled)
	testing.expect_value(t, app.commands[0], Action_ID(910))

	// The shorter exact match wins only after the chord deadline. The deadline
	// is reported as the next wake, so the host sleeps instead of polling.
	handled, _ = hosted_runtime_key_event(&host, Key_Event{key=.G, modifiers={.Primary}})
	testing.expect(t, handled)
	step := hosted_runtime_step(&host, 1_100)
	testing.expect(t, step.next_wake_ns == 1_000+500_000_000)
	testing.expect_value(t, app.command_count, 1)
	_ = hosted_runtime_step(&host, 1_000+500_000_000)
	testing.expect_value(t, app.command_count, 2)
	testing.expect_value(t, app.commands[1], Action_ID(911))
	pending, _ = hosted_runtime_binding_pending(&host)
	testing.expect(t, len(pending) == 0)
}

@(test)
test_hosted_application_key_shim_preserves_opaque_event_and_ordinary_path :: proc(t: ^testing.T) {
	app: Hosted_Bindings_Test_App
	host, ok := hosted_bindings_test_open(&app, {})
	if !ok { testing.expect(t, false, "hosted runtime should initialize"); return }
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1_000)
	handled, status := hosted_runtime_application_key(&host, .Find, Hosted_Key_Event{
		key_code=u32(Application_Key.Find),
		pressed=true,
		modifiers=Input_Modifiers{control=true},
	})
	testing.expect(t, status == .Ok && handled)
	testing.expect_value(t, app.key_count, 1)
	testing.expect_value(t, app.keys[0], u32(Application_Key.Find))
	testing.expect(t, app.command_count == 0,
		"no bindings means no resolver state and no command dispatch")
	deadline, found := binding_state_deadline(&host.state.binding_state)
	testing.expect(t, !found && deadline == 0, "the ordinary path arms no chord deadline")
}

@(test)
test_hosted_binding_cancel_on_text_and_pointer :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{
			command=Action_ID(920),
			strokes=[][]Binding_Key{{
				{key=.K, modifiers={.Primary}},
				{key=.S, modifiers={.Primary}},
			}},
			scope="Global",
		},
	}
	app: Hosted_Bindings_Test_App
	host, ok := hosted_bindings_test_open(&app, Binding_Table{bindings=bindings, chord_timeout_ns=500_000_000})
	if !ok { testing.expect(t, false, "hosted runtime should initialize"); return }
	defer hosted_runtime_destroy(&host)
	_ = hosted_runtime_step(&host, 1_000)
	_, _ = hosted_runtime_key_event(&host, Key_Event{key=.K, modifiers={.Primary}})
	pending, _ := hosted_runtime_binding_pending(&host)
	testing.expect(t, len(pending) == 1)
	status := hosted_runtime_binding_cancel(&host)
	testing.expect(t, status == .Ok)
	pending, _ = hosted_runtime_binding_pending(&host)
	testing.expect(t, len(pending) == 0)
}
