package main

import "core:c"
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
MENU_CHILD_ACTION :: alicorn.Action_ID(0x2201)
CHILD_CHROME_TITLE :: "Alicorn child chrome probe"
CHILD_CHROME_HEADER_HEIGHT :: f32(34)
CLIPBOARD_SMOKE_TEXT :: "alicorn hosted services smoke"
DROP_SMOKE_PATH :: "C:\\alicorn\\services-smoke.txt"
SERVICES_SMOKE_TIMEOUT_TICKS :: 900

Child_App :: struct {
	windows: ui.UI_Window_Service,
	dialogs: ui.UI_Dialog_Service,
	quit: alicorn.Hosted_Quit_Service,
	dialogs_available: bool,
	close_requested: bool,
	open_failed: bool,
	// --child-chrome-smoke state. The child owns its own retained chrome nodes,
	// metrics, layout, menu dispatch, close deferral, and dialog service.
	chrome_smoke: bool,
	title: string,
	started: bool,
	stopped: bool,
	header: alicorn.Node_ID,
	body: alicorn.Node_ID,
	interactive: alicorn.Node_ID,
	drag: alicorn.Node_ID,
	regions: [2]alicorn.Window_Chrome_Region,
	header_height: f32,
	metrics_count: int,
	layout_count: int,
	menu_count: int,
	menu_last: alicorn.Action_ID,
	menu_ok: bool,
	close_deferred: bool,
	close_events_pushed: bool,
	quit_sent: bool,
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
	// --titlebar-smoke exercises the integrated titlebar contract shared by the
	// SDL_GPU reference host and the WebGPU hosted host: app-authored header,
	// declared interactive/drag regions, and native metrics.
	titlebar_smoke: bool,
	titlebar_header: alicorn.Node_ID,
	titlebar_body: alicorn.Node_ID,
	titlebar_tabs_region: alicorn.Node_ID,
	titlebar_blank: alicorn.Node_ID,
	titlebar_regions: [2]alicorn.Window_Chrome_Region,
	titlebar_header_height: f32,
	titlebar_content_start_x: f32,
	titlebar_content_end_x: f32,
	titlebar_metrics_count: int,
	titlebar_layout_count: int,
	titlebar_metrics_header_h: f32,
	titlebar_order: [2]u64,
	titlebar_selected: u64,
	titlebar_reorder_count: int,
	titlebar_pointer_count: int,
	// --child-chrome-smoke: the child's own menu tree must outlive the open
	// request because the host borrows its slices for the window lifetime.
	child_chrome_smoke: bool,
	child_menu_items: [1]alicorn.Menu_Item,
	child_menus: [1]alicorn.Menu,
	// --workbench-smoke reproduces the Scratchpad workbench paint that failed
	// first presentation on the hosted WebGPU path: a connected tab opening a
	// rectangular analytic-relief paper surface (negative optical height) with
	// an edge gap that starts exactly at the paper's left edge. The shared CPU
	// preflight counts that split edge conservatively; the renderer must treat
	// it as a reservation, not an exact vertex contract.
	workbench_smoke: bool,
	workbench_material: alicorn.Material_ID,
	// --interactive keeps a fixture open for scripted physical window input.
	interactive: bool,
	// --services-smoke proves the hosted scheduler, synchronous clipboard, file
	// drop, and tick callbacks through ui.run on both renderer paths.
	services_smoke: bool,
	services_scheduler: alicorn.Application_Scheduler,
	services_clipboard: alicorn.Clipboard_Service,
	scheduler_armed: bool,
	scheduled_frequent: int,
	scheduled_opportunistic: int,
	frequent_class_ok: bool,
	opportunistic_class_ok: bool,
	clipboard_ok: bool,
	file_drops: int,
	file_drop_ok: bool,
	ticks: int,
	drop_push_requested: bool,
	drop_path: [64]u8,
	services_done: bool,
}

render :: proc(app: ^App, ctx: ^ui.UI) {
	if app.titlebar_smoke {
		titlebar_render(app, ctx)
		return
	}
	if app.workbench_smoke {
		workbench_render(app, ctx)
		return
	}
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

TITLEBAR_SMOKE_TAB_DRAG :: alicorn.Drag_Type(0x746162)

workbench_render :: proc(app: ^App, ctx: ^ui.UI) {
	if alicorn.container_begin(
		ctx, .Root, label="workbench-smoke-root", key="workbench-smoke-root",
		style=alicorn.layout_style(.Column, grow=1, clip=true),
		color=alicorn.Color{0.16, 0.16, 0.14, 1},
	) == 0 { return }
	// The tab strip and paper share a left edge and abut vertically, so the
	// selected connected tab opens the paper's top optical edge starting at
	// the surface's own left coordinate.
	tabs_width := f32(640)
	header := alicorn.container_begin(
		ctx, .Container, label="workbench-smoke-tabs", key="workbench-smoke-tabs",
		style=alicorn.layout_style(.Row, width=tabs_width, height=32, clip=true),
	)
	items := [2]alicorn.Tab_Bar_Item{
		{key=alicorn.key_string("workbench-tab-main"), label="main.odin", selected=true},
		{key=alicorn.key_string("workbench-tab-notes"), label="notes.md", selected=false},
	}
	options := alicorn.DEFAULT_TAB_BAR_OPTIONS
	options.height = 32
	options.min_tab_width = 160
	options.max_tab_width = 160
	options.gap = 0
	options.presentation = .Compact
	options.appearance = .Connected
	result := alicorn.tab_bar(
		ctx, alicorn.key_string("workbench-smoke-tab-bar"), items[:], options,
		alicorn.layout_style(.Row, width=tabs_width, height=32),
	)
	alicorn.container_end(ctx)
	paper := alicorn.surface_begin(
		ctx,
		alicorn.surface_core_color_role(.Surface),
		key=alicorn.key_string("workbench-smoke-paper"),
		label="workbench-smoke-paper",
		style=alicorn.layout_style(.Column, width=tabs_width, grow=1, padding=12, gap=4, clip=true),
		material=app.workbench_material,
		physical_height=-0.75,
		fill=alicorn.Color{0.94, 0.92, 0.86, 1},
		open_top_edge=result.selected_tab,
	)
	// Editor-like content: a selected row, gutter-ish rounded material rows,
	// and ordinary text. These exercise the same shared surface/text lanes as
	// the Scratchpad workbench without depending on its frontend.
	alicorn.container_begin(
		ctx, .Container, label="workbench-smoke-selected-row", key="workbench-smoke-selected-row",
		style=alicorn.layout_style(.Row, height=22),
		color=alicorn.Color{0.865, 0.748, 0.556, 0.38},
	)
	alicorn.container_end(ctx)
	for index in 0..<8 {
		alicorn.container_begin(
			ctx, .Container,
			label="workbench-smoke-row", key=alicorn.key_string(fmt.tprintf("workbench-smoke-row-%d", index)),
			style=alicorn.layout_style(.Row, height=22, gap=8),
		)
		alicorn.text(ctx, fmt.tprintf("    %d\tif document.open {", index+1),
			key=alicorn.key_string(fmt.tprintf("workbench-smoke-row-text-%d", index)))
		alicorn.container_end(ctx)
	}
	side := alicorn.surface_begin(
		ctx,
		alicorn.surface_core_color_role(.Subtle_Surface),
		key=alicorn.key_string("workbench-smoke-side"),
		label="workbench-smoke-side",
		style=alicorn.layout_style(.Row, width=180, height=80, padding=8),
		shape=alicorn.Surface_Shape{kind=.Rounded_Rectangle, corner_radius=6},
		material=app.workbench_material,
		physical_height=1,
		fill=alicorn.Color{0.87, 0.85, 0.78, 1},
	)
	alicorn.text(ctx, "workspace", key=alicorn.key_string("workbench-smoke-side-text"))
	alicorn.surface_end(ctx)
	alicorn.surface_end(ctx)
	alicorn.container_end(ctx)
	app.titlebar_header = header
	app.titlebar_body = paper
}

titlebar_render :: proc(app: ^App, ctx: ^ui.UI) {
	if alicorn.container_begin(
		ctx, .Root, label="titlebar-smoke-root", key="titlebar-smoke-root",
		style=alicorn.layout_style(.Column, grow=1, clip=true),
		color=alicorn.Color{0.04, 0.05, 0.08, 1},
	) == 0 { return }
	height := max(app.titlebar_header_height, 32)
	header := alicorn.container_begin(
		ctx, .Container, label="titlebar-smoke-header", key="titlebar-smoke-header",
		style=alicorn.layout_style(.Row, height=height, clip=true),
		color=alicorn.Color{0.125, 0.137, 0.16, 1},
	)
	leading := max(app.titlebar_content_start_x, 8)
	_ = alicorn.container_begin(ctx, .Container, label="titlebar-leading-inset", key="titlebar-leading-inset",
		style=alicorn.layout_style(.Row, width=leading, height=height))
	alicorn.container_end(ctx)
	tab_width := 300
	tabs_region := alicorn.container_begin(
		ctx, .Container, label="titlebar-tabs-region", key="titlebar-tabs-region",
		style=alicorn.layout_style(.Row, width=f32(tab_width), height=height, clip=true),
	)
	items: [2]alicorn.Tab_Bar_Item
	item_ids: [2]u64
	count := 0
	for tab_id in app.titlebar_order {
		if tab_id == 0 || tab_id > 2 { continue }
		items[count] = alicorn.Tab_Bar_Item{
			key=alicorn.key_string("titlebar-tab-one") if tab_id == 1 else alicorn.key_string("titlebar-tab-two"),
			label="Alicorn Overview" if tab_id == 1 else "Connected Input Probe",
			selected=app.titlebar_selected == tab_id,
			closable=false,
		}
		item_ids[count] = tab_id
		count += 1
	}
	options := alicorn.DEFAULT_TAB_BAR_OPTIONS
	options.height = height
	options.min_tab_width = 130
	options.max_tab_width = 160
	options.gap = 0
	options.presentation = .Compact
	options.appearance = .Connected
	options.animate_drag_reorder = true
	options.drag_type = TITLEBAR_SMOKE_TAB_DRAG
	result := alicorn.tab_bar(
		ctx, alicorn.key_string("titlebar-smoke-tabs"), items[:count], options,
		alicorn.layout_style(.Row, width=f32(tab_width), height=height, compress_weight=1),
	)
	if result.item_index >= 0 && result.item_index < count && result.action == .Select {
		app.titlebar_selected = item_ids[result.item_index]
		alicorn.invalidate_root(ctx.runtime, "titlebar smoke tab selected")
	}
	alicorn.container_end(ctx)
	blank := alicorn.container_begin(
		ctx, .Container, label="titlebar-drag-region", key="titlebar-drag-region",
		style=alicorn.layout_style(.Row, grow=1, height=height),
	)
	alicorn.container_end(ctx)
	trailing := max(app.titlebar_content_end_x-f32(tab_width)-leading, 0)
	if trailing > 0 {
		_ = alicorn.container_begin(ctx, .Container, label="titlebar-caption-reservation", key="titlebar-caption-reservation",
			style=alicorn.layout_style(.Row, width=trailing, height=height))
		alicorn.container_end(ctx)
	}
	alicorn.container_end(ctx)
	body := alicorn.container_begin(
		ctx, .Container, label="titlebar-smoke-body", key="titlebar-smoke-body",
		style=alicorn.layout_style(.Column, grow=1, padding=20, gap=10, clip=true),
	)
	alicorn.text(ctx, "Alicorn-rendered connected tabs share the native titlebar band.")
	alicorn.text(ctx, "Drag a tab onto its sibling to reorder; drag blank band space to move the window.")
	alicorn.text(ctx, fmt.tprintf(
		"metrics=%d header=%0.1fpt usable=%0.1f..%0.1f reorders=%d pointers=%d",
		app.titlebar_metrics_count,
		app.titlebar_metrics_header_h,
		app.titlebar_content_start_x,
		app.titlebar_content_end_x,
		app.titlebar_reorder_count,
		app.titlebar_pointer_count,
	))
	alicorn.container_end(ctx)
	alicorn.container_end(ctx)
	app.titlebar_header = header
	app.titlebar_tabs_region = tabs_region
	app.titlebar_blank = blank
	app.titlebar_body = body
}

titlebar_metrics :: proc(data: rawptr, _rt: ^alicorn.Runtime, metrics: alicorn.Window_Chrome_Metrics) {
	app := cast(^App)data
	app.titlebar_metrics_count += 1
	app.titlebar_metrics_header_h = metrics.header.h
	app.titlebar_header_height = max(metrics.header.h, 1)
	app.titlebar_content_start_x = metrics.content_start_x
	app.titlebar_content_end_x = metrics.content_end_x
}

titlebar_layout :: proc(data: rawptr, _rt: ^alicorn.Runtime) -> alicorn.Window_Chrome_Layout {
	app := cast(^App)data
	app.titlebar_regions[0] = alicorn.Window_Chrome_Region{node=app.titlebar_tabs_region, kind=.Interactive}
	app.titlebar_regions[1] = alicorn.Window_Chrome_Region{node=app.titlebar_blank, kind=.Window_Drag}
	app.titlebar_layout_count += 1
	return alicorn.Window_Chrome_Layout{header=app.titlebar_header, regions=app.titlebar_regions[:]}
}

titlebar_pointer :: proc(app: ^App, _rt: ^alicorn.Runtime, _event: alicorn.Pointer_Event, _target: alicorn.Node_ID) {
	app.titlebar_pointer_count += 1
}

titlebar_drag :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Drag_Event) {
	if event.drag_type != TITLEBAR_SMOKE_TAB_DRAG { return }
	if event.kind != .Dropped || event.target.value == 0 || event.source.value == event.target.value { return }
	if event.position == .Before {
		app.titlebar_order = [2]u64{event.source.value, event.target.value}
	} else if event.position == .After {
		app.titlebar_order = [2]u64{event.target.value, event.source.value}
	}
	app.titlebar_reorder_count += 1
	alicorn.invalidate_root(rt, "titlebar smoke tabs reordered")
}

example_initialize :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app == nil || rt == nil || !app.workbench_smoke { return }
	app.workbench_material = alicorn.style_material_register(rt, alicorn.Style_Material{
		kind=.Analytic_Relief,
		bevel_width=1,
		bevel_strength=0.36,
		inner_shadow_strength=0.18,
	})
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

child_chrome_render :: proc(child: ^Child_App, ctx: ^ui.UI) {
	if alicorn.container_begin(
		ctx, .Root, label="child-chrome-root", key="child-chrome-root",
		style=alicorn.layout_style(.Column, grow=1, clip=true),
		color=alicorn.Color{0.04, 0.05, 0.08, 1},
	) == 0 { return }
	height := max(child.header_height, CHILD_CHROME_HEADER_HEIGHT)
	header := alicorn.container_begin(
		ctx, .Container, label="child-chrome-header", key="child-chrome-header",
		style=alicorn.layout_style(.Row, height=height, clip=true),
		color=alicorn.Color{0.125, 0.137, 0.16, 1},
	)
	interactive := alicorn.container_begin(
		ctx, .Container, label="child-chrome-action", key="child-chrome-action",
		style=alicorn.layout_style(.Row, width=190, height=height),
	)
	if ui.button(ctx, "Child action") {
		alicorn.invalidate_root(ctx.runtime, "child chrome action")
	}
	alicorn.container_end(ctx)
	drag := alicorn.container_begin(
		ctx, .Container, label="child-chrome-drag", key="child-chrome-drag",
		style=alicorn.layout_style(.Row, grow=1, height=height),
	)
	alicorn.container_end(ctx)
	alicorn.container_end(ctx)
	body := alicorn.container_begin(
		ctx, .Container, label="child-chrome-body", key="child-chrome-body",
		style=alicorn.layout_style(.Column, grow=1, padding=20, gap=10, clip=true),
	)
	alicorn.text(ctx, "Independent retained chrome, menu, dialog, and close policy.")
	alicorn.text(ctx, fmt.tprintf(
		"metrics=%d layouts=%d menus=%d deferred=%v started=%v",
		child.metrics_count, child.layout_count, child.menu_count,
		child.close_deferred, child.started,
	))
	alicorn.container_end(ctx)
	alicorn.container_end(ctx)
	child.header = header
	child.body = body
	child.interactive = interactive
	child.drag = drag
	if child.chrome_smoke && child.close_deferred && !child.quit_sent {
		child.quit_sent = true
		ui.ui_quit_request(child.quit)
	}
}

auxiliary_render :: proc(data: rawptr, ctx: ^alicorn.UI, _width, _height: int, _dpi: f32) {
	child := cast(^Child_App)data
	if child.chrome_smoke {
		child_chrome_render(child, ctx)
		return
	}
	if ui.column(ctx, padding=24, gap=12) {
		ui.text(ctx, "Independent retained surface", size=22)
		ui.text(ctx, "This window has its own focus, input state, and Runtime on the shared WebGPU device.")
		if ui.button(ctx, "Close auxiliary window") {
			child.close_requested = true
			ui.ui_window_close(child.windows)
		}
	}
}

child_chrome_metrics :: proc(data: rawptr, _rt: ^alicorn.Runtime, metrics: alicorn.Window_Chrome_Metrics) {
	child := cast(^Child_App)data
	child.metrics_count += 1
	if metrics.header.h > 0 { child.header_height = metrics.header.h }
}

child_chrome_layout :: proc(data: rawptr, _rt: ^alicorn.Runtime) -> alicorn.Window_Chrome_Layout {
	child := cast(^Child_App)data
	child.layout_count += 1
	child.regions[0] = alicorn.Window_Chrome_Region{node=child.interactive, kind=.Interactive}
	child.regions[1] = alicorn.Window_Chrome_Region{node=child.drag, kind=.Window_Drag}
	return alicorn.Window_Chrome_Layout{header=child.header, regions=child.regions[:]}
}

child_menu_command :: proc(data: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID) {
	child := cast(^Child_App)data
	child.menu_count += 1
	child.menu_last = command
	child.menu_ok = command == MENU_CHILD_ACTION
	alicorn.invalidate_root(rt, "child chrome menu command")
}

child_close_requested :: proc(data: rawptr, rt: ^alicorn.Runtime) -> alicorn.Hosted_Close_Result {
	child := cast(^Child_App)data
	if !child.close_deferred {
		child.close_deferred = true
		alicorn.invalidate_root(rt, "child chrome close deferred")
		return .Defer
	}
	return .Allow
}

child_dialog_done :: proc(data: rawptr, _rt: ^alicorn.Runtime, _result: ^alicorn.File_Dialog_Result) {
	child := cast(^Child_App)data
	child.dialogs_available = true
}

child_window_id_by_title :: proc(title: string) -> sdl3.WindowID {
	count: c.int
	windows := sdl3.GetWindows(&count)
	if windows == nil { return 0 }
	for index in 0..<int(count) {
		window_title := sdl3.GetWindowTitle(windows[index])
		if window_title != nil && string(window_title) == title {
			return sdl3.GetWindowID(windows[index])
		}
	}
	return 0
}

// child_push_chrome_events queues one child-targeted accelerator and one native
// close request. The host routes both by window ID: the primary application
// must ignore them and the child must dispatch its own menu and close policy.
child_push_chrome_events :: proc(child: ^Child_App) {
	if child.close_events_pushed { return }
	window_id := child_window_id_by_title(child.title)
	if window_id == 0 { return }
	key_event: sdl3.Event
	key_event.key = sdl3.KeyboardEvent{
		commonEvent=sdl3.CommonEvent{type=.KEY_DOWN},
		windowID=window_id,
		key=sdl3.K_K,
		mod=sdl3.KMOD_CTRL|sdl3.KMOD_SHIFT,
		down=true,
	}
	_ = sdl3.PushEvent(&key_event)
	close_event: sdl3.Event
	close_event.type = .WINDOW_CLOSE_REQUESTED
	close_event.window.windowID = window_id
	_ = sdl3.PushEvent(&close_event)
	child.close_events_pushed = true
}

auxiliary_post_wake :: proc(_data: rawptr) -> bool {
	// The SDL3 host replaces this placeholder with its per-window wake event.
	return true
}

auxiliary_initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	child := cast(^Child_App)data
	if child != nil { child.started = true }
	if !alicorn.text_engine_load_default_fonts(rt) { panic("could not initialize auxiliary text fonts") }
}

auxiliary_host_services :: proc(data: rawptr, services: alicorn.Hosted_Host_Services) {
	child := cast(^Child_App)data
	if child == nil { return }
	child.windows = services.windows
	child.dialogs = services.dialogs
	child.quit = services.quit
	child.dialogs_available = services.dialogs.show_file != nil
	if child.chrome_smoke { child_push_chrome_events(child) }
}

auxiliary_stop :: proc(data: rawptr) {
	child := cast(^Child_App)data
	if child != nil { child.stopped = true }
}

auxiliary_open_failed :: proc(data: rawptr) {
	child := cast(^Child_App)data
	if child != nil { child.open_failed = true }
}

open_auxiliary_window :: proc(app: ^App) -> bool {
	child := &app.child
	title := CHILD_CHROME_TITLE if child.chrome_smoke else "Alicorn auxiliary window"
	config := alicorn.Hosted_Runtime_Config{
		state=rawptr(child),
		post_wake_data=rawptr(child),
		post_wake=auxiliary_post_wake,
		render=auxiliary_render,
		on_initialize=auxiliary_initialize,
		on_host_services=auxiliary_host_services,
		on_stop=auxiliary_stop,
	}
	if child.chrome_smoke {
		config.menus = app.child_menus[:]
		config.menu_presentation = .Labels
		config.on_menu_command = child_menu_command
		config.on_close_requested = child_close_requested
		config.on_dialog = child_dialog_done
		config.window_chrome_height = CHILD_CHROME_HEADER_HEIGHT
		config.window_chrome_metrics = child_chrome_metrics
		config.window_chrome_layout = child_chrome_layout
		when ODIN_OS == .Windows {
			config.window_decorations = .Integrated_Title_Bar
		}
	}
	return ui.ui_window_open(app.windows, ui.UI_Window_Description{
		title=title,
		width=760,
		height=460,
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
	app.services_scheduler = value.scheduler
	app.services_clipboard = value.clipboard_text
	app.dialog_available = value.dialogs.show_file != nil
	if app.services_smoke {
		clipboard_set := ui.ui_clipboard_set_text(app.services_clipboard, CLIPBOARD_SMOKE_TEXT)
		clipboard_text, clipboard_read := ui.ui_clipboard_get_text(app.services_clipboard)
		app.clipboard_ok = clipboard_set && clipboard_read && clipboard_text == CLIPBOARD_SMOKE_TEXT
		if len(clipboard_text) > 0 { delete(clipboard_text) }
		app.scheduler_armed = ui.ui_schedule_after(app.services_scheduler, .Frequent, 0)
	}
	if app.open_child_on_services {
		app.child_open_accepted = open_auxiliary_window(app)
	}
}

services_scheduled_wake :: proc(app: ^App, rt: ^alicorn.Runtime, class: alicorn.Scheduled_Wake_Class) {
	switch class {
	case .Frequent:
		app.scheduled_frequent += 1
		app.frequent_class_ok = true
		_ = ui.ui_schedule_after(app.services_scheduler, .Opportunistic, 5_000_000)
	case .Opportunistic:
		app.scheduled_opportunistic += 1
		app.opportunistic_class_ok = true
	}
	alicorn.invalidate_root(rt, "services smoke scheduled wake")
}

services_file_drop :: proc(app: ^App, rt: ^alicorn.Runtime, path: string) {
	if !app.services_smoke { return }
	app.file_drops += 1
	app.file_drop_ok = path == DROP_SMOKE_PATH
	alicorn.invalidate_root(rt, "services smoke file drop")
}

services_push_file_drop :: proc(app: ^App) {
	if app.drop_push_requested { return }
	path := DROP_SMOKE_PATH
	copy(app.drop_path[:], path)
	app.drop_path[len(path)] = 0
	event: sdl3.Event
	event.type = .DROP_FILE
	event.drop.commonEvent.type = .DROP_FILE
	event.drop.windowID = 0
	event.drop.data = cstring(rawptr(&app.drop_path[0]))
	app.drop_push_requested = sdl3.PushEvent(&event)
}

services_tick :: proc(app: ^App, _rt: ^alicorn.Runtime) {
	app.ticks += 1
	if !app.services_smoke || app.services_done { return }
	if !app.drop_push_requested && app.ticks >= 5 { services_push_file_drop(app) }
	if app.scheduled_frequent == 0 && app.ticks%60 == 0 {
		app.scheduler_armed = app.scheduler_armed ||
			ui.ui_schedule_after(app.services_scheduler, .Frequent, 0)
	}
	complete := app.scheduler_armed && app.scheduled_frequent >= 1 &&
		app.scheduled_opportunistic >= 1 && app.clipboard_ok &&
		app.file_drops >= 1 && app.file_drop_ok
	if complete || app.ticks > SERVICES_SMOKE_TIMEOUT_TICKS {
		app.services_done = true
		ui.ui_quit_request(app.quit)
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
		if argument == "--child-chrome-smoke" {
			smoke = true
			app.open_child_on_services = true
			app.child_chrome_smoke = true
			app.child.chrome_smoke = true
			app.child.title = CHILD_CHROME_TITLE
		}
		if argument == "--interactive" { app.interactive = true }
		if argument == "--services-smoke" { app.services_smoke = true }
		if argument == "--menu-smoke" {
			app.menu_smoke = true
			app.menu_expected = [3]alicorn.Action_ID{MENU_CUT, MENU_PALETTE, MENU_SYNC}
		}
		if argument == "--titlebar-smoke" {
			app.titlebar_smoke = true
			app.titlebar_order = [2]u64{1, 2}
			app.titlebar_selected = 1
			app.titlebar_header_height = 32
			app.titlebar_content_end_x = 900
			smoke = true
		}
		if argument == "--workbench-smoke" {
			app.workbench_smoke = true
			smoke = true
		}
	}
	if app.interactive { smoke = false }
	// The services smoke owns its quit: it completes only after the scheduler,
	// clipboard, and file-drop callbacks have all run, so the bounded --smoke
	// first-present exit must not stop it early.
	if app.services_smoke { smoke = false }
	if app.child_chrome_smoke {
		app.child_menu_items[0] = alicorn.Menu_Item{
			kind=.Command,
			command=MENU_CHILD_ACTION,
			label="Child Command",
			state=alicorn.Action_State{enabled=true},
			shortcut=alicorn.Menu_Shortcut{'K', {.Primary, .Shift}},
		}
		app.child_menus[0] = alicorn.Menu{
			label="Floating",
			items=app.child_menu_items[:],
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
	if app.titlebar_smoke {
		// The integrated fixture reserves measured label space and exercises the
		// visible-label band; Scratchpad's Hidden policy is covered by tests.
		presentation = .Labels
	}
	decorations := alicorn.Window_Decoration_Mode.System
	chrome_h: f32
	chrome_metrics: alicorn.Window_Chrome_Metrics_Proc
	chrome_layout: alicorn.Window_Chrome_Layout_Proc
	if app.titlebar_smoke {
		decorations = .Integrated_Title_Bar
		when ODIN_OS == .Darwin { decorations = .Content_Title_Bar }
		chrome_h = 32
		chrome_metrics = titlebar_metrics
		chrome_layout = titlebar_layout
	}
	pointer_proc: proc(^App, ^alicorn.Runtime, alicorn.Pointer_Event, alicorn.Node_ID)
	drag_proc: proc(^App, ^alicorn.Runtime, alicorn.Drag_Event)
	if app.titlebar_smoke {
		pointer_proc = titlebar_pointer
		drag_proc = titlebar_drag
	}
	scheduled_proc: proc(^App, ^alicorn.Runtime, alicorn.Scheduled_Wake_Class)
	file_drop_proc: proc(^App, ^alicorn.Runtime, string)
	tick_proc: proc(^App, ^alicorn.Runtime)
	if app.services_smoke {
		scheduled_proc = services_scheduled_wake
		file_drop_proc = services_file_drop
		tick_proc = services_tick
	}
	if sdl_gpu_reference {
		ui.run(&app, render, title="Alicorn · Native Renderer Probe", on_start=start, on_wake=wake,
			on_stop=stop, smoke=smoke, on_services=services, on_dialog=dialog_done,
			on_close_requested=close_requested, menus=menus[:], menu_presentation=presentation,
			on_menu_command=menu_command, window_decorations=decorations,
			window_chrome_height=chrome_h, window_chrome_metrics=chrome_metrics,
			window_chrome_layout=chrome_layout, on_pointer=pointer_proc,
			on_drag=drag_proc, on_scheduled_wake=scheduled_proc,
			on_file_drop=file_drop_proc, on_tick=tick_proc,
			on_initialize=example_initialize)
	} else {
		webgpu.run(&app, render, title="Alicorn · Native Renderer Probe", on_start=start, on_wake=wake,
			on_stop=stop, smoke=smoke, on_services=services, on_dialog=dialog_done,
			on_close_requested=close_requested, menus=menus[:], menu_presentation=presentation,
			on_menu_command=menu_command, window_decorations=decorations,
			window_chrome_height=chrome_h, window_chrome_metrics=chrome_metrics,
			window_chrome_layout=chrome_layout, on_pointer=pointer_proc,
			on_drag=drag_proc, on_scheduled_wake=scheduled_proc,
			on_file_drop=file_drop_proc, on_tick=tick_proc,
			on_initialize=example_initialize)
	}
	if app.services_smoke {
		ok := app.scheduler_armed && app.scheduled_frequent >= 1 &&
			app.scheduled_opportunistic >= 1 && app.frequent_class_ok &&
			app.opportunistic_class_ok && app.clipboard_ok && app.file_drops >= 1 &&
			app.file_drop_ok && app.ticks >= 1
		fmt.println(
			"services_smoke", "PASS" if ok else "FAIL",
			"scheduler", app.scheduler_armed,
			"frequent", app.scheduled_frequent,
			"opportunistic", app.scheduled_opportunistic,
			"classes", app.frequent_class_ok && app.opportunistic_class_ok,
			"clipboard", app.clipboard_ok,
			"drops", app.file_drops,
			"drop_ok", app.file_drop_ok,
			"ticks", app.ticks,
		)
		if !ok { os.exit(1) }
	}
	if app.menu_smoke {
		if !app.menu_ok {
			fmt.eprintln("menu_smoke FAIL", "commands", app.menu_count, "last", u32(app.menu_last))
			os.exit(1)
		}
		fmt.println("menu_smoke PASS", "commands", app.menu_count)
	}
	if app.child_chrome_smoke {
		ok := app.child.started && app.child.stopped && app.child.close_events_pushed &&
			app.child.close_deferred && app.child.dialogs_available && !app.child.open_failed
		when ODIN_OS == .Windows {
			ok = ok && app.child.metrics_count > 0 && app.child.layout_count > 0 &&
				app.child.header != 0 && app.child.interactive != 0 && app.child.drag != 0 &&
				app.child.menu_ok && app.child.menu_count == 1
		}
		fmt.println(
			"child_chrome_smoke", "PASS" if ok else "FAIL",
			"started", app.child.started,
			"stopped", app.child.stopped,
			"metrics", app.child.metrics_count,
			"layouts", app.child.layout_count,
			"menus", app.child.menu_count,
			"deferred", app.child.close_deferred,
			"dialogs", app.child.dialogs_available,
			"open_failed", app.child.open_failed,
		)
		if !ok { os.exit(1) }
	}
	if app.titlebar_smoke {
		ok := app.titlebar_metrics_count > 0 && app.titlebar_metrics_header_h > 0 &&
			app.titlebar_layout_count > 0 && app.titlebar_tabs_region != 0 && app.titlebar_blank != 0
		fmt.println(
			"titlebar_smoke", "PASS" if ok else "FAIL",
			"metrics", app.titlebar_metrics_count,
			"layouts", app.titlebar_layout_count,
			"header_h", app.titlebar_metrics_header_h,
			"usable_x", app.titlebar_content_start_x, app.titlebar_content_end_x,
			"pointer_events", app.titlebar_pointer_count,
			"reorders", app.titlebar_reorder_count,
		)
		if !ok { os.exit(1) }
	}
}
