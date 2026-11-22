#+build linux

package host_menus

import alicorn "alicorn:runtime"
import "vendor:sdl3"

// Linux keeps system decorations and uses the menu descriptions only as
// semantic accelerator metadata. It does not create a native application menu,
// matching the reference SDL_GPU host.
native_menu_adapter_prepare :: proc(
	adapter: ^Native_Menu_Adapter,
	window: ^sdl3.Window,
	service: ^Menu_Service,
	chrome: Menu_Chrome_Config = {},
) -> bool {
	if adapter == nil || window == nil || service == nil { return false }
	adapter.window = window
	adapter.service = service
	adapter.chrome = chrome
	adapter.prepared = true
	return true
}

native_menu_adapter_refresh :: proc(adapter: ^Native_Menu_Adapter) {
	_ = adapter
}

// Linux keeps menu descriptions as semantic accelerator metadata only; there
// is no native menu to rebuild or relabel.
native_menu_adapter_refresh_accelerators :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	_ = adapter
	return true
}

native_menu_adapter_activate_chrome :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	if adapter == nil { return false }
	adapter.chrome_active = false
	return true
}

native_menu_adapter_sync_chrome :: proc(adapter: ^Native_Menu_Adapter) {
	_ = adapter
}

native_menu_adapter_chrome_paint :: proc(
	adapter: ^Native_Menu_Adapter,
	width, height: f32,
	allocator := context.temp_allocator,
) -> []alicorn.Paint_Command {
	return nil
}

native_menu_adapter_handle_keydown :: proc(
	adapter: ^Native_Menu_Adapter,
	keycode: int,
	modifiers: sdl3.Keymod,
) -> bool {
	return false
}

native_menu_adapter_translate_pointer :: proc(
	adapter: ^Native_Menu_Adapter,
	pointer: alicorn.Pointer_Event,
	event: sdl3.Event,
) -> alicorn.Pointer_Event {
	return pointer
}

native_menu_adapter_note_window_hit_test :: proc(adapter: ^Native_Menu_Adapter) {}

native_menu_adapter_destroy :: proc(adapter: ^Native_Menu_Adapter) {
	if adapter == nil { return }
	adapter.window = nil
	adapter.service = nil
	adapter.platform_data = nil
	adapter.pending_command = {}
	adapter.has_pending = false
	adapter.prepared = false
	adapter.menu_open = false
	adapter.rebuild_pending = false
}
