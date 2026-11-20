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
) -> bool {
	if adapter == nil || window == nil || service == nil { return false }
	adapter.window = window
	adapter.service = service
	adapter.prepared = true
	return true
}

native_menu_adapter_refresh :: proc(adapter: ^Native_Menu_Adapter) {
	_ = adapter
}

native_menu_adapter_destroy :: proc(adapter: ^Native_Menu_Adapter) {
	if adapter == nil { return }
	adapter.window = nil
	adapter.service = nil
	adapter.platform_data = nil
	adapter.pending_command = {}
	adapter.has_pending = false
	adapter.prepared = false
}
