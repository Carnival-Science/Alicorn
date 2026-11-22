#+build !windows

package plugin_host

import "core:os"

// Non-Windows Phase B implementation.
//
// The public shape exists so a cross-platform plugin wrapper can compile and
// ask for a parent contract. Attachment is refused with Unsupported_Platform
// (or Unsupported_Wayland) and the caller is directed to a floating editor
// window. This is deliberate: an X11 XEmbed child, a Cocoa NSView, or a
// Wayland subsurface each need their own surface/event/DPI validation and must
// not be faked through a hidden top-level SDL window.

Plugin_Host_Impl :: struct {
	initialized: bool,
}

Plugin_Editor_Impl :: struct {
	attached: bool,
}

@(private)
plugin_process_looks_like_wayland :: proc() -> bool {
	when ODIN_OS == .Linux {
		if value, ok := os.lookup_env_alloc("XDG_SESSION_TYPE", context.temp_allocator); ok && value == "wayland" { return true }
		if _, ok := os.lookup_env_alloc("WAYLAND_DISPLAY", context.temp_allocator); ok { return true }
	}
	return false
}

@(private)
plugin_platform_monotonic_now_ns :: proc() -> u64 {
	return 0
}

plugin_host_init :: proc(host: ^Plugin_Host, config: Plugin_Host_Config) -> Plugin_Status {
	if host == nil { return .Invalid_Argument }
	if host.impl != nil { return .Already_Initialized }
	host.config = config
	host.impl = new(Plugin_Host_Impl)
	if host.impl == nil { return .Resource_Failure }
	host.impl.initialized = true
	return .Ok
}

plugin_host_destroy :: proc(host: ^Plugin_Host) -> Plugin_Status {
	if host == nil { return .Invalid_Argument }
	if host.impl != nil { free(host.impl) }
	host^ = {}
	return .Ok
}

plugin_host_create_editor :: proc(
	host: ^Plugin_Host,
	editor: ^Plugin_Editor,
	config: Plugin_Editor_Config,
) -> Plugin_Status {
	if host == nil || editor == nil { return .Invalid_Argument }
	if host.impl == nil || !host.impl.initialized { return .Not_Initialized }
	if editor.impl != nil { return .Already_Initialized }
	return plugin_status_for_parent(config.parent)
}

plugin_host_destroy_editor :: proc(host: ^Plugin_Host, editor: ^Plugin_Editor) -> Plugin_Status {
	if host == nil || editor == nil { return .Invalid_Argument }
	return .Ok
}

plugin_host_step :: proc(host: ^Plugin_Host, now_ns: u64) -> Plugin_Step_Result {
	return {status=.Unsupported_Platform}
}

plugin_host_next_wake_ns :: proc(host: ^Plugin_Host) -> u64 {
	return 0
}

plugin_host_has_in_flight :: proc(host: ^Plugin_Host) -> bool {
	return false
}

plugin_host_poll :: proc(host: ^Plugin_Host) {
}

plugin_host_device_lost :: proc(host: ^Plugin_Host) -> bool {
	return false
}

plugin_host_simulate_device_loss :: proc(host: ^Plugin_Host) -> Plugin_Status {
	return .Unsupported_Platform
}

plugin_host_recover :: proc(host: ^Plugin_Host, now_ns: u64) -> Plugin_Status {
	return .Unsupported_Platform
}

plugin_editor_attach :: proc(editor: ^Plugin_Editor, parent: Plugin_Native_Parent) -> Plugin_Status {
	if editor == nil { return .Invalid_Argument }
	return plugin_status_for_parent(parent)
}

plugin_editor_show :: proc(editor: ^Plugin_Editor) -> Plugin_Status {
	return .Unsupported_Platform
}

plugin_editor_hide :: proc(editor: ^Plugin_Editor) -> Plugin_Status {
	return .Unsupported_Platform
}

plugin_editor_resize :: proc(
	editor: ^Plugin_Editor,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> Plugin_Status {
	return .Unsupported_Platform
}

plugin_editor_resize_pixels :: proc(
	editor: ^Plugin_Editor,
	pixel_width, pixel_height: int,
	dpi_scale: f32,
) -> Plugin_Status {
	return .Unsupported_Platform
}

plugin_editor_request_presentation :: proc(editor: ^Plugin_Editor) -> Plugin_Status {
	return .Unsupported_Platform
}

plugin_editor_native_window :: proc(editor: ^Plugin_Editor) -> rawptr {
	return nil
}

plugin_editor_metrics :: proc(editor: ^Plugin_Editor) -> (Plugin_Editor_Metrics, bool) {
	return {}, false
}

plugin_editor_timing_summary :: proc(editor: ^Plugin_Editor) -> (Plugin_Editor_Timing_Summary, bool) {
	return {}, false
}
