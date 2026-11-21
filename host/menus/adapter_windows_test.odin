#+build windows

package host_menus

import "core:strings"
import "core:sync"
import "core:testing"
import win "core:sys/windows"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

foreign import user32 "system:User32.lib"
foreign user32 {
	GetMenuItemCount :: proc "system" (menu: win.HMENU) -> i32 ---
	GetSubMenu :: proc "system" (menu: win.HMENU, position: i32) -> win.HMENU ---
	GetMenuState :: proc "system" (menu: win.HMENU, id: win.UINT, flags: win.UINT) -> win.UINT ---
}

WIN32_MF_GRAYED_MASK :: win.UINT(0x00000001)

win32_menu_test_mutex: sync.Mutex

Win32_Chrome_Test_State :: struct {
	header, tabs, blank, body: alicorn.Node_ID,
	metrics: alicorn.Window_Chrome_Metrics,
	metrics_count: int,
	regions: [2]alicorn.Window_Chrome_Region,
	pointer_events: int,
}

win32_chrome_test_render :: proc(data: rawptr, ui: ^alicorn.UI, _width, _height: int, _dpi: f32) {
	state := cast(^Win32_Chrome_Test_State)data
	if alicorn.container_begin(ui, .Root, label="chrome-test", key="chrome-test-root",
		style=alicorn.layout_style(.Column, grow=1)) == 0 { return }
	header := alicorn.container_begin(ui, .Container, label="chrome-test-header", key="chrome-test-header",
		style=alicorn.layout_style(.Row, height=32, clip=true), color=alicorn.Color{0.15,0.15,0.15,1})
	_ = alicorn.container_begin(ui, .Container, label="leading", key="chrome-leading",
		style=alicorn.layout_style(.Row, width=80, height=32))
	alicorn.container_end(ui)
	tabs := alicorn.container_begin(ui, .Container, label="tabs", key="chrome-tabs",
		style=alicorn.layout_style(.Row, width=160, height=32))
	alicorn.container_end(ui)
	blank := alicorn.container_begin(ui, .Container, label="blank", key="chrome-blank",
		style=alicorn.layout_style(.Row, grow=1, height=32))
	alicorn.container_end(ui)
	alicorn.container_end(ui)
	body := alicorn.container_begin(ui, .Container, label="body", key="chrome-body",
		style=alicorn.layout_style(.Column, grow=1, padding=8))
	alicorn.container_end(ui)
	state.header, state.tabs, state.blank, state.body = header, tabs, blank, body
	state.regions[0] = alicorn.Window_Chrome_Region{node=tabs, kind=.Interactive}
	state.regions[1] = alicorn.Window_Chrome_Region{node=blank, kind=.Window_Drag}
}

win32_chrome_test_metrics :: proc(data: rawptr, _rt: ^alicorn.Runtime, metrics: alicorn.Window_Chrome_Metrics) {
	state := cast(^Win32_Chrome_Test_State)data
	state.metrics = metrics
	state.metrics_count += 1
}

win32_chrome_test_layout :: proc(data: rawptr, _rt: ^alicorn.Runtime) -> alicorn.Window_Chrome_Layout {
	state := cast(^Win32_Chrome_Test_State)data
	return alicorn.Window_Chrome_Layout{header=state.header, regions=state.regions[:]}
}

win32_chrome_test_post :: proc(_data: rawptr) -> bool { return true }
win32_chrome_test_init :: proc(_data: rawptr, rt: ^alicorn.Runtime) { _ = alicorn.text_engine_load_default_fonts(rt) }
win32_chrome_test_pointer :: proc(data: rawptr, _rt: ^alicorn.Runtime, _event: alicorn.Pointer_Event, _target: alicorn.Node_ID) {
	state := cast(^Win32_Chrome_Test_State)data
	state.pointer_events += 1
}

@(test)
test_win32_integrated_chrome_routes_app_regions_and_drag_regions :: proc(t: ^testing.T) {
	sync.mutex_lock(&win32_menu_test_mutex)
	defer sync.mutex_unlock(&win32_menu_test_mutex)
	if !sdl3.Init({.VIDEO}) { testing.expect(t, false, "SDL video should initialize"); return }
	defer sdl3.Quit()
	title, title_error := strings.clone_to_cstring("alicorn-hosted-chrome-test", context.temp_allocator)
	if title_error != nil { testing.expect(t, false, "title should allocate"); return }
	window := sdl3.CreateWindow(title, 480, 320, {.HIDDEN, .RESIZABLE})
	if window == nil { testing.expect(t, false, "hidden window should be created"); return }
	defer sdl3.DestroyWindow(window)
	menus := [?]alicorn.Menu{{label="File"}}
	service: Menu_Service
	menu_service_init(&service, menus[:], .Labels, nil, nil)
	adapter: Native_Menu_Adapter
	chrome := Menu_Chrome_Config{
		decorations=.Integrated_Title_Bar,
		title="Header",
		chrome_height=32,
		menu_presentation=.Labels,
		metrics=win32_chrome_test_metrics,
		layout=win32_chrome_test_layout,
	}
	test_state := Win32_Chrome_Test_State{}
	chrome.callback_state = rawptr(&test_state)
	if !native_menu_adapter_prepare(&adapter, window, &service, chrome) {
		testing.expect(t, false, "integrated adapter should prepare"); return
	}
	defer native_menu_adapter_destroy(&adapter)
	hosted: alicorn.Hosted_Runtime
	if alicorn.hosted_runtime_init(&hosted, alicorn.Hosted_Runtime_Config{
		state=rawptr(&test_state), logical_width=480, logical_height=320,
		pixel_width=480, pixel_height=320, dpi_scale=1,
		render=win32_chrome_test_render,
		post_wake_data=rawptr(&test_state), post_wake=win32_chrome_test_post,
		on_initialize=win32_chrome_test_init,
		on_pointer=win32_chrome_test_pointer,
		window_decorations=.Integrated_Title_Bar,
		window_chrome_height=32,
		window_chrome_metrics=win32_chrome_test_metrics,
		window_chrome_layout=win32_chrome_test_layout,
	}) != .Ok { testing.expect(t, false, "hosted runtime should initialize"); return }
	defer alicorn.hosted_runtime_destroy(&hosted)
	adapter.hosted = &hosted
	if !native_menu_adapter_activate_chrome(&adapter) {
		testing.expect(t, false, "integrated chrome should activate"); return
	}
	_ = alicorn.hosted_runtime_step(&hosted, 1)
	native_menu_adapter_sync_chrome(&adapter)
	if test_state.metrics_count == 0 || test_state.metrics.header.h <= 0 {
		testing.expect(t, false, "chrome metrics should be delivered to the application"); return
	}
	inset, _ := alicorn.hosted_runtime_content_inset(&hosted)
	testing.expect(t, inset == 0,
		"an application-owned header removes the host content inset")

	props := sdl3.GetWindowProperties(window)
	hwnd := cast(win.HWND)sdl3.GetPointerProperty(props, "SDL.window.win32.hwnd", nil)
	client_origin := win.POINT{}
	if !win.ClientToScreen(hwnd, &client_origin) { testing.expect(t, false, "client origin unavailable"); return }
	screen_point :: proc(origin: win.POINT, x, y: i32) -> win.LPARAM {
		return win.LPARAM(uintptr(u16(origin.x+x)) | (uintptr(u16(origin.y+y)) << 16))
	}
	tabs_hit := win.SendMessageW(hwnd, win.WM_NCHITTEST, 0, screen_point(client_origin, 120, 16))
	testing.expect(t, tabs_hit == win.LRESULT(win.HTCLIENT),
		"an interactive app chrome region must forward input to the application as HTCLIENT")
	blank_hit := win.SendMessageW(hwnd, win.WM_NCHITTEST, 0, screen_point(client_origin, 300, 16))
	testing.expect(t, blank_hit == win.LRESULT(win.HTCAPTION),
		"an explicit window-drag region must return HTCAPTION")
	body_hit := win.SendMessageW(hwnd, win.WM_NCHITTEST, 0, screen_point(client_origin, 120, 120))
	testing.expect(t, body_hit == win.LRESULT(win.HTCLIENT),
		"ordinary body pixels remain client input")
	paint := native_menu_adapter_chrome_paint(&adapter, 480, 320)
	has_text := false
	for command in paint {
		if alicorn.paint_command_is_text(command) { has_text = true }
	}
	testing.expect(t, len(paint) > 0 && has_text,
		"host chrome paints menu labels and caption controls into the authored band")
}

@(test)
test_win32_host_owned_chrome_reserves_content_inset :: proc(t: ^testing.T) {
	sync.mutex_lock(&win32_menu_test_mutex)
	defer sync.mutex_unlock(&win32_menu_test_mutex)
	if !sdl3.Init({.VIDEO}) { testing.expect(t, false, "SDL video should initialize"); return }
	defer sdl3.Quit()
	title, title_error := strings.clone_to_cstring("alicorn-hosted-chrome-inset-test", context.temp_allocator)
	if title_error != nil { testing.expect(t, false, "title should allocate"); return }
	window := sdl3.CreateWindow(title, 480, 320, {.HIDDEN, .RESIZABLE})
	if window == nil { testing.expect(t, false, "hidden window should be created"); return }
	defer sdl3.DestroyWindow(window)
	menus := [?]alicorn.Menu{{label="File"}}
	service: Menu_Service
	menu_service_init(&service, menus[:], .Labels, nil, nil)
	adapter: Native_Menu_Adapter
	chrome := Menu_Chrome_Config{
		decorations=.Integrated_Title_Bar,
		title="Alicorn",
		chrome_height=0,
		menu_presentation=.Labels,
	}
	test_state := Win32_Chrome_Test_State{}
	chrome.callback_state = rawptr(&test_state)
	if !native_menu_adapter_prepare(&adapter, window, &service, chrome) {
		testing.expect(t, false, "integrated adapter should prepare"); return
	}
	defer native_menu_adapter_destroy(&adapter)
	hosted: alicorn.Hosted_Runtime
	if alicorn.hosted_runtime_init(&hosted, alicorn.Hosted_Runtime_Config{
		state=rawptr(&test_state), logical_width=480, logical_height=320,
		pixel_width=480, pixel_height=320, dpi_scale=1,
		render=win32_chrome_test_render,
		post_wake_data=rawptr(&test_state), post_wake=win32_chrome_test_post,
		on_initialize=win32_chrome_test_init, on_pointer=win32_chrome_test_pointer,
		window_decorations=.Integrated_Title_Bar,
	}) != .Ok { testing.expect(t, false, "hosted runtime should initialize"); return }
	defer alicorn.hosted_runtime_destroy(&hosted)
	adapter.hosted = &hosted
	if !native_menu_adapter_activate_chrome(&adapter) {
		testing.expect(t, false, "host-owned chrome should activate"); return
	}
	_ = alicorn.hosted_runtime_step(&hosted, 1)
	native_menu_adapter_sync_chrome(&adapter)
	inset, _ := alicorn.hosted_runtime_content_inset(&hosted)
	testing.expect(t, inset >= 30,
		"host-owned chrome reserves its measured band above application content")
	rt, _ := alicorn.hosted_runtime_borrow(&hosted)
	testing.expect_value(t, rt.viewport.h, f32(320-inset))
	_, _ = alicorn.hosted_runtime_pointer(&hosted, alicorn.Pointer_Event{kind=.Move, x=20, y=4})
	testing.expect(t, test_state.pointer_events == 0,
		"pointer input over host-owned chrome is withheld from the application")
}

@(test)
test_win32_adapter_attaches_menu_and_refreshes_borrowed_state :: proc(t: ^testing.T) {
	sync.mutex_lock(&win32_menu_test_mutex)
	defer sync.mutex_unlock(&win32_menu_test_mutex)
	if !sdl3.Init({.VIDEO}) {
		testing.expect(t, false, "SDL video subsystem should initialize for the Win32 menu adapter test")
		return
	}
	defer sdl3.Quit()
	title, title_error := strings.clone_to_cstring("alicorn-hosted-menu-test", context.temp_allocator)
	if title_error != nil {
		testing.expect(t, false, "test window title should allocate")
		return
	}
	window := sdl3.CreateWindow(title, 320, 200, {.HIDDEN})
	if window == nil {
		testing.expect(t, false, "SDL should create a hidden window for the Win32 menu adapter test")
		return
	}
	defer sdl3.DestroyWindow(window)

	items := [?]alicorn.Menu_Item{
		{kind=.Command, command=alicorn.Action_ID(1), label="New", state=alicorn.Action_State{enabled=true}, shortcut=alicorn.Menu_Shortcut{'N', {.Primary}}},
		{kind=.Command, command=alicorn.Action_ID(2), label="Open", state=alicorn.Action_State{enabled=true}},
		{kind=.Separator},
		{kind=.Command, command=alicorn.Action_ID(3), label="Save", state=alicorn.Action_State{enabled=false}, shortcut=alicorn.Menu_Shortcut{'S', {.Primary}}},
	}
	menus := [?]alicorn.Menu{
		{label="File", items=items[:]},
		{label="Sync", command=alicorn.Action_ID(4), state=alicorn.Action_State{enabled=true}},
	}
	service: Menu_Service
	menu_service_init(&service, menus[:], .Hidden, nil, nil)
	adapter: Native_Menu_Adapter
	if !native_menu_adapter_prepare(&adapter, window, &service) {
		testing.expect(t, false, "the Win32 menu adapter should attach a system menu bar")
		return
	}
	defer native_menu_adapter_destroy(&adapter)

	props := sdl3.GetWindowProperties(window)
	hwnd := cast(win.HWND)sdl3.GetPointerProperty(props, "SDL.window.win32.hwnd", nil)
	root := win.GetMenu(hwnd)
	testing.expect(t, root != nil, "preparing the adapter should attach an HMENU to the SDL window")
	testing.expect(t, GetMenuItemCount(root) == 2, "all top-level menus should be present")

	file_popup := GetSubMenu(root, 0)
	testing.expect(t, file_popup != nil, "the File menu should be a popup")
	testing.expect(t, GetMenuItemCount(file_popup) == len(items), "the File popup should retain every item")
	// New(0), Open(1), Separator(2), Save(3).
	disabled_flags := GetMenuState(file_popup, 3, WIN32_MF_BYPOSITION)
	testing.expect(t, disabled_flags & WIN32_MF_GRAYED_MASK != 0,
		"a disabled borrowed item should start grayed")

	items[3].state.enabled = true
	native_menu_adapter_refresh(&adapter)
	enabled_flags := GetMenuState(file_popup, 3, WIN32_MF_BYPOSITION)
	testing.expect(t, enabled_flags & WIN32_MF_GRAYED_MASK == 0,
		"refresh must read the borrowed item state rather than a startup copy")

	native_menu_adapter_queue(&adapter, alicorn.Action_ID(3))
	command, pending := native_menu_adapter_take_pending(&adapter)
	testing.expect(t, pending && command == alicorn.Action_ID(3),
		"native menu selections should queue the semantic command for safe-point dispatch")
	_, pending = native_menu_adapter_take_pending(&adapter)
	testing.expect(t, !pending, "consuming a pending command should clear the queue")
}

@(test)
test_win32_adapter_requires_a_live_window :: proc(t: ^testing.T) {
	service: Menu_Service
	menu_service_init(&service, nil, .Labels, nil, nil)
	adapter: Native_Menu_Adapter
	testing.expect(t, !native_menu_adapter_prepare(&adapter, nil, &service),
		"the adapter requires a live SDL window")
}
