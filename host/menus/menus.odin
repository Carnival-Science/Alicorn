// Package host_menus is the renderer-agnostic native-menu service shared by the
// reference SDL_GPU host and the hosted SDL3/WebGPU host.
//
// The shared model, accelerator matching, enabled gate, and shortcut label live
// in alicorn:runtime (runtime/menus.odin) so there is exactly one definition.
// This package adds the per-surface service and the SDL3 platform adapters that
// present an application menu on Windows (Win32 menu bar) and macOS (NSMenu).
// Linux keeps menu descriptions as semantic accelerator metadata only, matching
// the native host.
package host_menus

import alicorn "alicorn:runtime"
import "vendor:sdl3"

// Menu_Command_Proc receives one command that already passed the shared
// enabled gate. A host adapter must deliver it under its native-command cause
// (the SDL3/WebGPU host calls hosted_runtime_menu_command; the SDL_GPU host
// begins a .Native_Command cause and invalidates the description).
Menu_Command_Proc :: proc(data: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID)

// Menu_Service owns one surface's borrowed menu descriptions. Labels and
// structure are snapshotted by a Native_Menu_Adapter at prepare time; menu
// item state is read from this borrowed slice whenever a shortcut is matched,
// a native menu opens, or a command is dispatched.
Menu_Service :: struct {
	menus:        []alicorn.Menu,
	presentation: alicorn.Menu_Presentation,
	data:         rawptr,
	command:      Menu_Command_Proc,
}

menu_service_init :: proc(
	service: ^Menu_Service,
	menus: []alicorn.Menu,
	presentation: alicorn.Menu_Presentation,
	data: rawptr,
	command: Menu_Command_Proc,
) {
	if service == nil { return }
	service^ = Menu_Service{
		menus=menus,
		presentation=presentation,
		data=data,
		command=command,
	}
}

// menu_service_update replaces the borrowed menu descriptions. An application
// that remaps a shortcut mutates the same borrowed storage and then calls this
// (or simply calls native_menu_adapter_rebuild) so the native menu presentation
// and accelerator table stay synchronized with dispatch.
menu_service_update :: proc(
	service: ^Menu_Service,
	menus: []alicorn.Menu,
	presentation: alicorn.Menu_Presentation,
) {
	if service == nil { return }
	service.menus = menus
	service.presentation = presentation
}

menu_service_match_shortcut :: proc(
	service: ^Menu_Service,
	key: rune,
	modifiers: alicorn.Menu_Modifiers,
) -> (command: alicorn.Action_ID, found: bool) {
	if service == nil { return {}, false }
	return alicorn.menu_match_shortcut(service.menus, key, modifiers)
}

// menu_service_dispatch_command applies the shared enabled gate and then hands
// the command to the host callback. Disabled commands produce no callback and
// no runtime trace.
menu_service_dispatch_command :: proc(
	service: ^Menu_Service,
	rt: ^alicorn.Runtime,
	command: alicorn.Action_ID,
) -> bool {
	if service == nil || service.command == nil { return false }
	if !alicorn.menu_command_enabled(service.menus, rt, command) { return false }
	service.command(service.data, rt, command)
	return true
}

// menu_service_try_shortcut matches one keyboard transition against the menu
// shortcut table. Repeating key transitions are consumed without dispatching,
// matching the native host: a held accelerator must not fire repeatedly.
menu_service_try_shortcut :: proc(
	service: ^Menu_Service,
	rt: ^alicorn.Runtime,
	key: rune,
	modifiers: alicorn.Menu_Modifiers,
	repeat: bool,
) -> bool {
	if service == nil || service.command == nil { return false }
	command, found := menu_service_match_shortcut(service, key, modifiers)
	if !found { return false }
	if !repeat { _ = menu_service_dispatch_command(service, rt, command) }
	return true
}

// Menu_Chrome_Config carries the host's native chrome policy to the platform
// adapter. It is platform-neutral: Windows implements the integrated band,
// macOS coordinates full-size content, and Linux keeps system decorations.
// Callbacks borrow the application state for the adapter lifetime.
Menu_Chrome_Config :: struct {
	decorations:       alicorn.Window_Decoration_Mode,
	title:             string,
	chrome_height:     f32,
	menu_presentation: alicorn.Menu_Presentation,
	metrics:           alicorn.Window_Chrome_Metrics_Proc,
	layout:            alicorn.Window_Chrome_Layout_Proc,
	appearance:        alicorn.Window_Chrome_Appearance_Proc,
	callback_state:    rawptr,
	// request_redraw runs when host chrome paint or geometry changes outside
	// application invalidation (hover, active state, DPI measurement).
	request_redraw:      proc(data: rawptr),
	request_redraw_data: rawptr,
}

// Native_Menu_Adapter owns one platform menu representation for one window.
// platform_data is host-private (HWND/HMENU or NSMenu/selectors).
Native_Menu_Adapter :: struct {
	window:          ^sdl3.Window,
	service:         ^Menu_Service,
	hosted:          ^alicorn.Hosted_Runtime,
	chrome:          Menu_Chrome_Config,
	chrome_active:   bool,
	platform_data:   rawptr,
	pending_command: alicorn.Action_ID,
	has_pending:     bool,
	prepared:        bool,
	// menu_open is true while the platform menu loop owns input. A rebuild
	// requested in that window is deferred to close so the platform never has
	// its active menu destroyed underneath it.
	menu_open:       bool,
	rebuild_pending: bool,
}

// native_menu_adapter_take_pending consumes one command queued by a native
// menu callback. Hosts dispatch it at an event-loop safe point, never from
// inside the platform callback.
native_menu_adapter_take_pending :: proc(adapter: ^Native_Menu_Adapter) -> (alicorn.Action_ID, bool) {
	if adapter == nil || !adapter.has_pending { return {}, false }
	command := adapter.pending_command
	adapter.pending_command = {}
	adapter.has_pending = false
	return command, true
}

@(private="package")
native_menu_adapter_queue :: proc(adapter: ^Native_Menu_Adapter, command: alicorn.Action_ID) {
	if adapter == nil || command == alicorn.Action_ID(0) { return }
	adapter.pending_command = command
	adapter.has_pending = true
}

// native_menu_adapter_rebuild recreates the platform menu from the service's
// current borrowed descriptions. A host calls it after a runtime shortcut
// remap when labels, structure, or accelerator text changed. Windows defers the
// rebuild while a native menu loop owns input; the deferred request is drained
// when the loop closes or by native_menu_adapter_drain_rebuild from a host safe
// point.
native_menu_adapter_rebuild :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	if adapter == nil || !adapter.prepared { return false }
	if adapter.menu_open {
		adapter.rebuild_pending = true
		return true
	}
	adapter.rebuild_pending = false
	window := adapter.window
	service := adapter.service
	chrome := adapter.chrome
	native_menu_adapter_destroy(adapter)
	return native_menu_adapter_prepare(adapter, window, service, chrome)
}

// native_menu_adapter_drain_rebuild applies a rebuild deferred while the native
// menu was open. Hosts may call it at an event-loop safe point; the Windows
// adapter also drains it when the menu loop exits.
native_menu_adapter_drain_rebuild :: proc(adapter: ^Native_Menu_Adapter) -> bool {
	if adapter == nil || !adapter.rebuild_pending || adapter.menu_open { return false }
	return native_menu_adapter_rebuild(adapter)
}

// menu_presentation_labels_visible reports whether menu labels belong in the
// window chrome. Menu_Presentation.Hidden suppresses labels only for Windows
// integrated-title-bar chrome; a system menu bar and the macOS main menu always
// present labels. slice 3 passes integrated_titlebar=true once hosted titlebar
// chrome exists.
menu_presentation_labels_visible :: proc(
	presentation: alicorn.Menu_Presentation,
	integrated_titlebar: bool,
) -> bool {
	return presentation == .Labels || !integrated_titlebar
}
