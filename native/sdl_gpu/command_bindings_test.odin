package alicorn_sdl_gpu

import "core:testing"
import alicorn "../../runtime"

Native_Binding_Test_App :: struct {
	commands:      [4]alicorn.Action_ID,
	command_count: int,
}

native_binding_test_command :: proc(state: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
	app := cast(^Native_Binding_Test_App)state
	if app != nil && app.command_count < len(app.commands) {
		app.commands[app.command_count] = command
		app.command_count += 1
	}
}

@(test)
test_native_binding_dispatch_uses_native_command_cause_and_enabled_gate :: proc(t: ^testing.T) {
	runtime: alicorn.Runtime
	runtime = alicorn.new_runtime(alicorn.Rect{0, 0, 320, 200})
	defer alicorn.destroy_runtime(&runtime)
	app: Native_Binding_Test_App
	application := Application{
		state=rawptr(&app),
		on_command=native_binding_test_command,
	}
	ok := native_binding_dispatch(rawptr(&application), &runtime, alicorn.Action_ID(77))
	testing.expect(t, ok)
	testing.expect_value(t, app.command_count, 1)
	testing.expect_value(t, app.commands[0], alicorn.Action_ID(77))
	testing.expect(t, runtime.invalidated,
		"a native binding dispatch invalidates the application description")

	// A disabled borrowed menu item blocks the same command through the shared
	// enabled gate, matching native menu accelerators.
	items := [?]alicorn.Menu_Item{
		{
			kind=.Command,
			command=alicorn.Action_ID(78),
			label="Disabled",
			state=alicorn.Action_State{enabled=false},
		},
	}
	menus := [?]alicorn.Menu{{label="Edit", items=items[:]}}
	application.menus = menus[:]
	ok = native_binding_dispatch(rawptr(&application), &runtime, alicorn.Action_ID(78))
	testing.expect(t, !ok)
	testing.expect_value(t, app.command_count, 1)
}
