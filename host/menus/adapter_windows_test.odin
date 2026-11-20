#+build windows

package host_menus

import "core:strings"
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

@(test)
test_win32_adapter_attaches_menu_and_refreshes_borrowed_state :: proc(t: ^testing.T) {
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
