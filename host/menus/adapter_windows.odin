#+build windows

package host_menus

import "base:runtime"
import "core:fmt"
import "core:mem"
import win "core:sys/windows"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

// The shared Win32 menu adapter builds one HMENU tree from borrowed menu
// descriptions and attaches it to an SDL3 window. Menu labels, structure, and
// accelerator text are snapshotted here; EnableMenuItem/CheckMenuItem refresh
// reads the borrowed Action_State whenever a popup opens. Selection is queued
// from the window subclass so the host dispatches it at a safe point.
//
// Integrated title bars use the same state and subclass: top-level labels move
// into the authored band, caption controls and chrome regions are hit-tested
// there, and DWM extends over a client-area frame. host/menus therefore owns a
// single Win32 construction path for both presentations.

foreign import comctl32 "system:Comctl32.lib"
foreign comctl32 {
	RemoveWindowSubclass :: proc "system" (hwnd: win.HWND, callback: win.SUBCLASSPROC, subclass_id: win.UINT_PTR) -> win.BOOL ---
}

foreign import user32 "system:User32.lib"
foreign user32 {
	DrawMenuBar :: proc "system" (hwnd: win.HWND) -> win.BOOL ---
	CheckMenuItem :: proc "system" (menu: win.HMENU, item: win.UINT, check: win.UINT) -> win.UINT ---
}

MENU_ADAPTER_SUBCLASS_ID :: win.UINT_PTR(0x414C49434D454E55) // "ALICMENU"

WIN32_MF_GRAYED    :: win.UINT(0x00000001)
WIN32_MF_POPUP     :: win.UINT(0x00000010)
WIN32_MF_SEPARATOR :: win.UINT(0x00000800)
WIN32_MF_CHECKED   :: win.UINT(0x00000008)
WIN32_MF_BYPOSITION :: win.UINT(0x00000400)

Win32_Menu_Binding :: struct {
	menu:       win.HMENU,
	position:   win.UINT,
	item:       ^alicorn.Menu_Item,
	top_menu:   ^alicorn.Menu,
	is_command: bool,
}

Win32_Menu_State :: struct {
	adapter:   ^Native_Menu_Adapter,
	hwnd:      win.HWND,
	allocator: mem.Allocator,
	root:      win.HMENU,
	commands:  [dynamic]alicorn.Action_ID,
	bindings:  [dynamic]Win32_Menu_Binding,
	installed: bool,
	attached:  bool,
	chrome:    Win32_Chrome_State,
}

win32_menu_state :: proc(data: win.DWORD_PTR) -> ^Win32_Menu_State {
	return cast(^Win32_Menu_State)uintptr(data)
}

win32_menu_wide :: proc(state: ^Win32_Menu_State, value: string) -> []u16 {
	return win.utf8_to_utf16(value, state.allocator)
}

win32_menu_build_items :: proc(
	state: ^Win32_Menu_State,
	menu: win.HMENU,
	items: []alicorn.Menu_Item,
) -> bool {
	for position in 0..<len(items) {
		item := &items[position]
		switch item.kind {
		case .Separator:
			if !win.AppendMenuW(menu, WIN32_MF_SEPARATOR, 0, nil) { return false }
		case .Submenu:
			popup := win.CreatePopupMenu()
			if popup == nil { return false }
			if !win32_menu_build_items(state, popup, item.items) {
				win.DestroyMenu(popup)
				return false
			}
			wide := win32_menu_wide(state, item.label)
			if wide == nil {
				win.DestroyMenu(popup)
				return false
			}
			flags := WIN32_MF_POPUP
			if !item.state.enabled { flags |= WIN32_MF_GRAYED }
			ok := win.AppendMenuW(menu, flags, win.UINT_PTR(uintptr(popup)), win.LPCWSTR(&wide[0]))
			delete(wide, state.allocator)
			if !ok {
				win.DestroyMenu(popup)
				return false
			}
			append(&state.bindings, Win32_Menu_Binding{
				menu=menu, position=win.UINT(position), item=item,
			})
		case .Command:
			if len(state.commands) >= 0x10000 { return false }
			native_id := win.UINT(len(state.commands))
			append(&state.commands, item.command)
			flags := win.UINT(0)
			if !item.state.enabled { flags |= WIN32_MF_GRAYED }
			if item.state.checked { flags |= WIN32_MF_CHECKED }
			label := item.label
			if item.shortcut.key != 0 {
				label = fmt.tprintf("%s\t%s", item.label, alicorn.menu_shortcut_label(item.shortcut))
			}
			wide := win32_menu_wide(state, label)
			if wide == nil { return false }
			ok := win.AppendMenuW(menu, flags, win.UINT_PTR(native_id), win.LPCWSTR(&wide[0]))
			delete(wide, state.allocator)
			if !ok { return false }
			append(&state.bindings, Win32_Menu_Binding{
				menu=menu, position=win.UINT(position), item=item, is_command=true,
			})
		}
	}
	return true
}

win32_menu_refresh_state :: proc(state: ^Win32_Menu_State) {
	if state == nil { return }
	for binding in state.bindings {
		flags := WIN32_MF_BYPOSITION
		item_state :=
			binding.item.state if binding.item != nil else binding.top_menu.state
		if !item_state.enabled { flags |= WIN32_MF_GRAYED }
		_ = win.EnableMenuItem(binding.menu, binding.position, flags)
		if binding.is_command {
			check := WIN32_MF_BYPOSITION
			if item_state.checked { check |= WIN32_MF_CHECKED }
			_ = CheckMenuItem(binding.menu, binding.position, check)
		}
	}
}

win32_menu_subclass :: proc "system" (
	hwnd: win.HWND,
	message: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
	subclass_id: win.UINT_PTR,
	ref_data: win.DWORD_PTR,
) -> win.LRESULT {
	context = runtime.default_context()
	state := win32_menu_state(ref_data)
	if state == nil { return win.DefSubclassProc(hwnd, message, wparam, lparam) }
	state.hwnd = hwnd
	state.chrome.hwnd = hwnd
	integrated := state.chrome.frame_enabled
	dwm_result: win.LRESULT
	dwm_handled := false
	if message == win.WM_NCHITTEST || message == win.WM_NCMOUSEMOVE || message == win.WM_NCMOUSELEAVE ||
		message == win.WM_NCLBUTTONDOWN || message == win.WM_NCLBUTTONUP || message == win.WM_NCLBUTTONDBLCLK ||
		message == win.WM_NCRBUTTONDOWN || message == win.WM_NCRBUTTONUP || message == win.WM_NCRBUTTONDBLCLK {
		dwm_handled = DwmDefWindowProc(hwnd, message, wparam, lparam, &dwm_result) != false
	}
	if integrated {
		if result, handled := win32_chrome_handle_message(
			&state.chrome, message, wparam, lparam, dwm_handled, dwm_result,
		); handled {
			return result
		}
	}
	if dwm_handled { return dwm_result }
	if message == win.WM_COMMAND {
		command_id := u32(uintptr(wparam) & 0xffff)
		if command_id > 0 && int(command_id) < len(state.commands) {
			native_menu_adapter_queue(state.adapter, state.commands[command_id])
			win32_chrome_exit_mode(&state.chrome, -1)
			return 0
		}
	}
	if message == win.WM_INITMENUPOPUP { win32_menu_refresh_state(state) }
	result := win.DefSubclassProc(hwnd, message, wparam, lparam)
	win32_chrome_post_message(&state.chrome, message, wparam, lparam)
	return result
}

@(private)
win32_menu_state_destroy :: proc(state: ^Win32_Menu_State) {
	if state.installed { _ = RemoveWindowSubclass(state.hwnd, win32_menu_subclass, MENU_ADAPTER_SUBCLASS_ID) }
	if state.root != nil {
		if state.attached { _ = win.SetMenu(state.hwnd, nil) }
		_ = win.DestroyMenu(state.root)
	}
	win32_chrome_destroy_masks(&state.chrome)
	if state.adapter != nil && state.adapter.hosted != nil {
		if rt, status := alicorn.hosted_runtime_borrow(state.adapter.hosted); status == .Ok {
			alicorn.runtime_host_text_run_release(rt, u64(WIN32_CHROME_TITLE_NODE))
			alicorn.runtime_host_text_run_release(rt, u64(WIN32_CHROME_ELLIPSIS_NODE))
			for i in 0..<len(state.chrome.labels) {
				alicorn.runtime_host_text_run_release(rt, u64(WIN32_CHROME_LABEL_NODE_BASE+alicorn.Node_ID(i)))
			}
		}
	}
	if state.commands != nil { delete(state.commands) }
	if state.bindings != nil { delete(state.bindings) }
	if state.chrome.labels != nil { delete(state.chrome.labels) }
	allocator := state.allocator
	free(state, allocator=allocator)
}

native_menu_adapter_prepare :: proc(
	adapter: ^Native_Menu_Adapter,
	window: ^sdl3.Window,
	service: ^Menu_Service,
	chrome_config: Menu_Chrome_Config = {},
) -> bool {
	if adapter == nil || window == nil || service == nil { return false }
	if adapter.prepared { return true }
	adapter.window = window
	adapter.service = service
	adapter.chrome = chrome_config
	// Content_Title_Bar is the macOS full-size-content mode. On Windows the
	// native host keeps system decorations instead of creating a chrome-less
	// window; the hosted host mirrors that fallback.
	decorations := chrome_config.decorations
	if decorations == .Content_Title_Bar { decorations = .System }
	if len(service.menus) == 0 && decorations == .System {
		adapter.prepared = true
		return true
	}
	props := sdl3.GetWindowProperties(window)
	hwnd := cast(win.HWND)sdl3.GetPointerProperty(props, "SDL.window.win32.hwnd", nil)
	if hwnd == nil { return false }
	state := new(Win32_Menu_State)
	if state == nil { return false }
	state.adapter = adapter
	state.hwnd = hwnd
	state.allocator = context.allocator
	state.commands = make([dynamic]alicorn.Action_ID, 1, len(service.menus)+1, allocator=state.allocator)
	if state.commands == nil {
		free(state, allocator=state.allocator)
		return false
	}
	state.chrome = Win32_Chrome_State{
		adapter=adapter, menu_state=state, hwnd=hwnd, window=window, allocator=state.allocator,
		active=true, windows_11=win32_caption_windows_11(),
		hovered=-1, active_menu=-1, caption_hovered=-1, caption_pressed=-1,
		frame_enabled=decorations == .Integrated_Title_Bar,
		last_inset=-1,
	}
	state.root = win.CreateMenu()
	if state.root == nil {
		win32_menu_state_destroy(state)
		return false
	}
	if decorations != .System {
		state.chrome.labels = make([]Win32_Chrome_Label, len(service.menus), allocator=state.allocator)
		if len(service.menus) > 0 && state.chrome.labels == nil {
			win32_menu_state_destroy(state)
			return false
		}
		for &label, i in state.chrome.labels { label.host_node = WIN32_CHROME_LABEL_NODE_BASE+alicorn.Node_ID(i) }
	}
	state.chrome.title.host_node = WIN32_CHROME_TITLE_NODE
	state.chrome.ellipsis.host_node = WIN32_CHROME_ELLIPSIS_NODE
	for &description, index in service.menus {
		popup: win.HMENU
		flags := win.UINT(WIN32_MF_POPUP)
		native_id := win.UINT_PTR(0)
		if description.command != alicorn.Action_ID(0) {
			if len(state.commands) >= 0x10000 { win32_menu_state_destroy(state); return false }
			native_id = win.UINT_PTR(uintptr(len(state.commands)))
			append(&state.commands, description.command)
			flags = 0
			if !description.state.enabled { flags |= WIN32_MF_GRAYED }
			if description.state.checked { flags |= WIN32_MF_CHECKED }
		} else {
			popup = win.CreatePopupMenu()
			if popup == nil || !win32_menu_build_items(state, popup, description.items) {
				if popup != nil { win.DestroyMenu(popup) }
				win32_menu_state_destroy(state)
				return false
			}
			native_id = win.UINT_PTR(uintptr(popup))
		}
		// HMENU exposes the first label character as its Alt key. The borrowed
		// application label itself stays untouched.
		wide := win32_menu_wide(state, fmt.tprintf("&%s", description.label))
		if wide == nil {
			if popup != nil { win.DestroyMenu(popup) }
			win32_menu_state_destroy(state)
			return false
		}
		attached := win.AppendMenuW(state.root, flags, native_id, win.LPCWSTR(&wide[0]))
		delete(wide, state.allocator)
		if !attached {
			if popup != nil { win.DestroyMenu(popup) }
			win32_menu_state_destroy(state)
			return false
		}
		if decorations != .System {
			label := &state.chrome.labels[index]
			label.text = description.label
			label.popup = popup
			if description.command != alicorn.Action_ID(0) { label.direct_menu = &description }
		}
		if description.command != alicorn.Action_ID(0) {
			append(&state.bindings, Win32_Menu_Binding{
				menu=state.root, position=win.UINT(index), top_menu=&description, is_command=true,
			})
		}
	}
	win.SetWindowSubclass(hwnd, win32_menu_subclass, MENU_ADAPTER_SUBCLASS_ID, win.DWORD_PTR(uintptr(state)))
	state.installed = true
	if decorations == .System {
		if !win.SetMenu(hwnd, state.root) {
			win32_menu_state_destroy(state)
			return false
		}
		state.attached = true
		_ = DrawMenuBar(hwnd)
	} else if state.chrome.frame_enabled {
		if !win32_chrome_reapply_frame(&state.chrome) {
			win32_menu_state_destroy(state)
			return false
		}
	}
	adapter.platform_data = rawptr(state)
	adapter.prepared = true
	return true
}

native_menu_adapter_refresh :: proc(adapter: ^Native_Menu_Adapter) {
	if adapter == nil || adapter.platform_data == nil { return }
	win32_menu_refresh_state(cast(^Win32_Menu_State)adapter.platform_data)
}

native_menu_adapter_destroy :: proc(adapter: ^Native_Menu_Adapter) {
	if adapter == nil { return }
	if adapter.platform_data != nil {
		win32_menu_state_destroy(cast(^Win32_Menu_State)adapter.platform_data)
	}
	adapter.platform_data = nil
	adapter.chrome_active = false
	adapter.prepared = false
	adapter.has_pending = false
	adapter.pending_command = {}
}

native_menu_adapter_activate_chrome :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	return win32_chrome_activate(adapter)
}

native_menu_adapter_sync_chrome :: proc(adapter: ^Native_Menu_Adapter) {
	_ = win32_chrome_sync(adapter)
}

native_menu_adapter_chrome_paint :: proc(
	adapter: ^Native_Menu_Adapter,
	width, height: f32,
	allocator := context.temp_allocator,
) -> []alicorn.Paint_Command {
	return win32_chrome_paint(adapter, width, height, allocator)
}

native_menu_adapter_handle_keydown :: proc(
	adapter: ^Native_Menu_Adapter,
	keycode: int,
	modifiers: sdl3.Keymod,
) -> bool {
	return win32_chrome_handle_keydown(adapter, keycode, modifiers)
}
