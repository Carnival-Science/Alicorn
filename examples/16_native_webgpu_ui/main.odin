package main

import "core:fmt"
import "core:os"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"
import webgpu "alicorn:ui/webgpu"
import "vendor:sdl3"

// Example menu commands. The identifiers stay opaque to the host; only the
// application knows what they mean.
MENU_NEW          :: alicorn.Action_ID(0x2101)
MENU_OPEN         :: alicorn.Action_ID(0x2102)
MENU_OPEN_RECENT  :: alicorn.Action_ID(0x2103)
MENU_SAVE         :: alicorn.Action_ID(0x2104)
MENU_CUT          :: alicorn.Action_ID(0x2105)
MENU_COPY         :: alicorn.Action_ID(0x2106)
MENU_PASTE        :: alicorn.Action_ID(0x2107)
MENU_WORD_WRAP    :: alicorn.Action_ID(0x2108)
MENU_PALETTE      :: alicorn.Action_ID(0x2109)
MENU_ABOUT        :: alicorn.Action_ID(0x210A)
MENU_SYNC         :: alicorn.Action_ID(0x210B)

Child_App :: struct {
	windows: ui.UI_Window_Service,
	close_requested: bool,
	open_failed: bool,
}

App :: struct {
	count: int,
	wake_deliveries: int,
	waker: ui.Application_Waker,
	name: ui.Text_Buffer,
	timing_motion: bool,
	windows: ui.UI_Window_Service,
	dialogs: ui.UI_Dialog_Service,
	quit: alicorn.Hosted_Quit_Service,
	dialog_available: bool,
	dialog_accepted: bool,
	dialog_result: string,
	child: Child_App,
	open_child_on_services: bool,
	child_open_accepted: bool,
	// --defer-close proves the hosted close/quit handshake without changing the
	// default behavior driven by validate_native_webgpu_ui.ps1.
	defer_close_once: bool,
	close_deferred: bool,
	// --menu-smoke synthesizes accelerator key events and verifies the native
	// menu command sequence on both the SDL_GPU and WebGPU hosts.
	menu_smoke:  bool,
	menu_ok:     bool,
	menu_count:  int,
	menu_last:   alicorn.Action_ID,
	menu_expected: [3]alicorn.Action_ID,
	menu_seen:     [3]alicorn.Action_ID,
}

render :: proc(app: ^App, ctx: ^ui.UI) {
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Native WebGPU UI", size=24)
		ui.text(ctx, "The retained runtime and surface presenter are shared with the browser host.")
		if ui.button(ctx, "Increment") { app.count += 1 }
		ui.text(ctx, fmt.tprintf("Button activations: %d", app.count))
		if ui.button(ctx, "Queue application wake") { ui.wake(app.waker) }
		ui.text(ctx, fmt.tprintf("Application wake callbacks: %d", app.wake_deliveries))
		ui.text_field(ctx, "Try native text input", &app.name)
		if ui.button(ctx, "Open file dialog") {
			app.dialog_accepted = ui.ui_dialog_show_file(app.dialogs, ui.UI_File_Dialog_Request{
				kind=.Open_File,
				title="Alicorn hosted file dialog",
				accept_label="Choose",
			})
			if !app.dialog_accepted { app.dialog_result = "Request was rejected" }
		}
		ui.text(ctx, fmt.tprintf(
			"Hosted dialogs: %s; last result: %s",
			"available" if app.dialog_available else "unavailable",
			app.dialog_result,
		))
		ui.text(ctx, fmt.tprintf("Native menu commands: %d; last: %d", app.menu_count, u32(app.menu_last)))
		if app.close_deferred {
			ui.text(ctx, "Close deferred; quitting through the hosted quit service.")
			if ui.button(ctx, "Close now") { ui.ui_quit_request(app.quit) }
		}
		if ui.button(ctx, "Open auxiliary window") {
			app.child_open_accepted = open_auxiliary_window(app)
		}
		if app.child_open_accepted { ui.text(ctx, "Auxiliary window request accepted") }
		if app.child.open_failed { ui.text(ctx, "Auxiliary window could not be created") }
		if app.timing_motion {
			if ui.row(ctx, height=24, label="timing-motion-probe") {
				marker := alicorn.container_begin(
					ctx,
					.Container,
					label="retained-motion-timing-probe",
					key="retained-motion-timing-probe",
					style=ui.layout_style(.Row, width=24, height=16),
					color=ui.rgb(0x4EA6C7),
				)
				_ = ui.motion(
					ctx,
					marker,
					ui.Motion_Target{translation=ui.Motion_Vector2{180, 0}, has_translation=true},
					.Reveal,
					ui.Motion_Vector2{-180, 0},
				)
				alicorn.container_end(ctx)
			}
		}
	}
}

start :: proc(app: ^App, waker: ui.Application_Waker) {
	app.waker = waker
	if app.menu_smoke {
		// Synthetic native key transitions exercise the real host accelerator
		// path. Disabled Paste and Save must be ignored; the rest dispatch in
		// order. They are queued before the window is shown, so the first event
		// poll after presentation delivers them.
		menu_smoke_push_shortcut(sdl3.K_X, sdl3.KMOD_CTRL)
		menu_smoke_push_shortcut(sdl3.K_V, sdl3.KMOD_CTRL)
		menu_smoke_push_shortcut(sdl3.K_S, sdl3.KMOD_CTRL)
		menu_smoke_push_shortcut(sdl3.K_P, sdl3.KMOD_CTRL|sdl3.KMOD_SHIFT)
		menu_smoke_push_shortcut(sdl3.K_Y, sdl3.KMOD_CTRL)
	}
}

@(private)
menu_smoke_push_shortcut :: proc(key: sdl3.Keycode, modifiers: sdl3.Keymod) {
	event: sdl3.Event
	event.key = sdl3.KeyboardEvent{
		commonEvent={type=.KEY_DOWN},
		key=key,
		mod=modifiers,
		down=true,
	}
	_ = sdl3.PushEvent(&event)
}

menu_command :: proc(app: ^App, rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
	app.menu_count += 1
	app.menu_last = command
	alicorn.invalidate_root(rt, "native menu command")
	if !app.menu_smoke { return }
	if app.menu_count <= len(app.menu_seen) { app.menu_seen[app.menu_count-1] = command }
	if app.menu_count == len(app.menu_expected) {
		app.menu_ok = true
		for expected, index in app.menu_expected {
			if app.menu_seen[index] != expected { app.menu_ok = false }
		}
		ui.ui_quit_request(app.quit)
	}
}

wake :: proc(app: ^App, ctx: ui.Application_Context) {
	if app == nil || ctx == nil { return }
	app.wake_deliveries += 1
	ui.invalidate(ctx, "native WebGPU application wake delivered")
}

auxiliary_render :: proc(data: rawptr, ctx: ^alicorn.UI, _width, _height: int, _dpi: f32) {
	child := cast(^Child_App)data
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Independent retained surface", size=22)
		ui.text(ctx, "This window has its own focus, input state, and Runtime on the shared WebGPU device.")
		if ui.button(ctx, "Close auxiliary window") {
			child.close_requested = true
			ui.ui_window_close(child.windows)
		}
	}
}

auxiliary_post_wake :: proc(_data: rawptr) -> bool {
	// The SDL3 host replaces this placeholder with its per-window wake event.
	return true
}

auxiliary_initialize :: proc(_data: rawptr, rt: ^alicorn.Runtime) {
	if !alicorn.text_engine_load_default_fonts(rt) { panic("could not initialize auxiliary text fonts") }
}

auxiliary_host_services :: proc(data: rawptr, services: alicorn.Hosted_Host_Services) {
	child := cast(^Child_App)data
	child.windows = services.windows
}

auxiliary_open_failed :: proc(data: rawptr) {
	child := cast(^Child_App)data
	child.open_failed = true
}

open_auxiliary_window :: proc(app: ^App) -> bool {
	config := alicorn.Hosted_Runtime_Config{
		state=rawptr(&app.child),
		post_wake_data=rawptr(&app.child),
		post_wake=auxiliary_post_wake,
		render=auxiliary_render,
		on_initialize=auxiliary_initialize,
		on_host_services=auxiliary_host_services,
	}
	return ui.ui_window_open(app.windows, ui.UI_Window_Description{
		title="Alicorn auxiliary window",
		width=560,
		height=320,
		config=config,
		on_open_failed=auxiliary_open_failed,
	})
}

dialog_done :: proc(app: ^App, rt: ^alicorn.Runtime, result: ^ui.UI_File_Dialog_Result) {
	switch result.status {
	case .Accepted:
		app.dialog_accepted = true
		app.dialog_result = "Accepted"
	case .Cancelled:
		app.dialog_accepted = false
		app.dialog_result = "Cancelled"
	case .Error:
		app.dialog_accepted = false
		app.dialog_result = "Error"
	}
	alicorn.invalidate_root(rt, "hosted file dialog completed")
}

close_requested :: proc(app: ^App, rt: ^alicorn.Runtime) -> alicorn.Hosted_Close_Result {
	if app.defer_close_once {
		app.defer_close_once = false
		app.close_deferred = true
		alicorn.invalidate_root(rt, "hosted close request deferred")
		return .Defer
	}
	return .Allow
}

services :: proc(app: ^App, value: ui.UI_Host_Services) {
	app.windows = value.windows
	app.dialogs = value.dialogs
	app.quit = value.quit
	app.dialog_available = value.dialogs.show_file != nil
	if app.open_child_on_services {
		app.child_open_accepted = open_auxiliary_window(app)
	}
}

stop :: proc(app: ^App) {
	ui.text_buffer_destroy(&app.name)
}

main :: proc() {
	name, ok := ui.text_buffer("Type here")
	if !ok { panic("could not allocate example text buffer") }
	app := App{name=name, dialog_result="none"}
	smoke := false
	sdl_gpu_reference := false
	for argument in os.args {
		if argument == "--smoke" { smoke = true }
		if argument == "--backend=sdl-gpu" { sdl_gpu_reference = true }
		if argument == "--timing-motion" { app.timing_motion = true }
		if argument == "--defer-close" { app.defer_close_once = true }
		if argument == "--child-smoke" {
			smoke = true
			app.open_child_on_services = true
		}
		if argument == "--menu-smoke" {
			app.menu_smoke = true
			app.menu_expected = [3]alicorn.Action_ID{MENU_CUT, MENU_PALETTE, MENU_SYNC}
		}
	}
	// A Scratchpad-shaped menu tree: four popup menus, a nested recent-files
	// submenu, accelerators, separators, checked and disabled items, plus one
	// direct top-level command.
	recent_items := [?]alicorn.Menu_Item{
		{kind=.Command, command=MENU_OPEN_RECENT, label="notes.md", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'1', {.Primary}}},
	}
	file_items := [?]alicorn.Menu_Item{
		{kind=.Command, command=MENU_NEW, label="New", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'N', {.Primary}}},
		{kind=.Command, command=MENU_OPEN, label="Open…", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'O', {.Primary}}},
		{kind=.Submenu, label="Open Recent", state=alicorn.Action_State{enabled=true}, items=recent_items[:]},
		{kind=.Separator},
		{kind=.Command, command=MENU_SAVE, label="Save", state=alicorn.Action_State{enabled=false}, shortcut=alicorn.Menu_Shortcut{'S', {.Primary}}},
	}
	edit_items := [?]alicorn.Menu_Item{
		{kind=.Command, command=MENU_CUT, label="Cut", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'X', {.Primary}}},
		{kind=.Command, command=MENU_COPY, label="Copy", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'C', {.Primary}}},
		{kind=.Command, command=MENU_PASTE, label="Paste", state=alicorn.Action_State{enabled=false}, shortcut=alicorn.Menu_Shortcut{'V', {.Primary}}},
		{kind=.Separator},
	}
	view_items := [?]alicorn.Menu_Item{
		{kind=.Command, command=MENU_WORD_WRAP, label="Word Wrap", state=alicorn.Action_State{enabled=true, checked=true}},
		{kind=.Command, command=MENU_PALETTE, label="Command Palette", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'P', {.Primary, .Shift}}},
	}
	help_items := [?]alicorn.Menu_Item{
		{kind=.Command, command=MENU_ABOUT, label="About Alicorn", state=alicorn.Action_State{enabled=true}},
	}
	menus := [?]alicorn.Menu{
		{label="File", items=file_items[:]},
		{label="Edit", items=edit_items[:]},
		{label="View", items=view_items[:]},
		{label="Help", items=help_items[:]},
		{label="Sync", command=MENU_SYNC, state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'Y', {.Primary}}},
	}
	presentation := alicorn.Menu_Presentation.Labels
	when ODIN_OS == .Windows {
		// Scratchpad hides integrated-titlebar labels on Windows. This fixture
		// still uses system decorations, where Hidden leaves the system menu bar
		// visible, so the same policy is safe to exercise here.
		presentation = .Hidden
	}
	if sdl_gpu_reference {
		ui.run(&app, render, title="Alicorn · Native Renderer Probe", on_start=start, on_wake=wake,
			on_stop=stop, smoke=smoke, on_services=services, on_dialog=dialog_done,
			on_close_requested=close_requested, menus=menus[:], menu_presentation=presentation,
			on_menu_command=menu_command)
	} else {
		webgpu.run(&app, render, title="Alicorn · Native Renderer Probe", on_start=start, on_wake=wake,
			on_stop=stop, smoke=smoke, on_services=services, on_dialog=dialog_done,
			on_close_requested=close_requested, menus=menus[:], menu_presentation=presentation,
			on_menu_command=menu_command)
	}
	if app.menu_smoke {
		if !app.menu_ok {
			fmt.eprintln("menu_smoke FAIL", "commands", app.menu_count, "last", u32(app.menu_last))
			os.exit(1)
		}
		fmt.println("menu_smoke PASS", "commands", app.menu_count)
	}
}
