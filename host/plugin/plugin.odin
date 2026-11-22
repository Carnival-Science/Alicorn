// Embeddable editor surfaces for native plugin hosts.
//
// A plugin host (CLAP, VST3, an application with its own window and event
// loop) owns the outer native window. This package creates one child native
// window per editor, binds one Hosted_Runtime to it, and presents that runtime
// through the shared WebGPU surface presenter. It never creates a top-level
// window, never owns the application's message loop, and never touches an
// audio thread.
//
// The Windows implementation is the Phase B proof of concept. Other platforms
// report a typed unsupported result: the caller is expected to use a floating
// editor window there instead of inventing an embedded child surface.
package plugin_host

import "core:mem"
import alicorn "alicorn:runtime"

// Plugin_Parent_Kind names the native parent/child surface contract a host
// wants to use. Only Windows_HWND is implemented in Phase B. The other values
// exist so a cross-platform plugin wrapper can report the requested contract
// and receive a specific refusal instead of silently creating a top-level
// window.
Plugin_Parent_Kind :: enum {
	Windows_HWND,
	Cocoa_NSView,
	X11_Window,
	Wayland_Surface,
}

Plugin_Native_Parent :: struct {
	kind: Plugin_Parent_Kind,
	// window is an HWND on Windows, an NSView* on Cocoa, an X11 Window on
	// Xlib/XCB, or a wl_surface* on Wayland. It is borrowed for the editor
	// lifetime and must stay alive until plugin_host_destroy_editor returns.
	window: rawptr,
	// display is optional HINSTANCE/Display*/wl_display* context for platforms
	// that need it. Windows may leave it nil (GetModuleHandleW is used).
	display: rawptr,
}

Plugin_Status :: enum {
	Ok,
	Already_Initialized,
	Not_Initialized,
	Closed,
	Invalid_Argument,
	Unsupported_Platform,
	Unsupported_Wayland,
	Unsupported_Parent,
	Device_Unavailable,
	Surface_Unavailable,
	Presenter_Failure,
	Runtime_Failure,
	Device_Lost,
	Wrong_Thread,
	Resource_Failure,
	Timeout,
}

// Plugin_Host_Capabilities describes what the compiled platform can actually
// do. The fixture and a plugin wrapper read this before deciding between an
// embedded editor and a floating fallback.
Plugin_Host_Capabilities :: struct {
	platform:               Plugin_Parent_Kind,
	embedded_surface:       bool,
	surface_from_hwnd:      bool,
	child_window:           bool,
	ime_composition:        bool,
	native_accessibility:   bool,
	device_recovery:        bool,
	scoped_input:           bool,
	floating_fallback_only: bool,
}

// Plugin_Accessibility is an optional, host-owned native accessibility
// adapter. The core package does not link AccessKit. A host that wants
// per-editor semantics wires alicorn:host/plugin/accessibility (Windows) or
// its own adapter here. Every callback runs on the editor's owner thread.
Plugin_Accessibility :: struct {
	data: rawptr,
	// attach binds the adapter to the editor's native child window. Returning
	// false leaves the editor usable without native semantics.
	attach: proc(data: rawptr, kind: Plugin_Parent_Kind, native_window: rawptr) -> bool,
	// sync projects the current retained semantics after a description.
	sync: proc(
		data: rawptr,
		rt: ^alicorn.Runtime,
		content_inset_top, scale_x, scale_y: f32,
	),
	// drain releases native actions into the hosted runtime's semantic queue.
	drain: proc(data: rawptr, hosted: ^alicorn.Hosted_Runtime),
	focus_changed: proc(data: rawptr, focused: bool),
	destroy: proc(data: rawptr),
}

Plugin_Editor_Metrics :: struct {
	logical_width, logical_height: int,
	pixel_width, pixel_height: int,
	dpi_scale: f32,
	visible: bool,
	attached: bool,
	renderable: bool,
	accessibility_attached: bool,
	device_lost: bool,
	steps: u64,
	presentations: u64,
	last_presentation_us: u64,
	configure_count: u64,
	configure_total_ns: u64,
	configure_last_ns: u64,
	frames_built: u64,
	descriptions_reused: u64,
}

// Plugin_Editor_Timing_Summary is a bounded snapshot of the presenter's
// step-to-successful-submit samples for this editor. It is CPU wall time, not
// GPU execution or scanout latency.
Plugin_Editor_Timing_Summary :: struct {
	samples: int,
	p50_ns:  u64,
	p95_ns:  u64,
	max_ns:  u64,
}

Plugin_Step_Result :: struct {
	status: Plugin_Status,
	steps: int,
	presentations: int,
	has_more_work: bool,
	next_wake_ns: u64,
}

// Plugin_Editor is one embedded child surface. Treat it as opaque; only the
// plugin_editor_* functions and the host fixture inspect its public metrics.
Plugin_Editor :: struct {
	host: ^Plugin_Host,
	window: rawptr,
	hosted: alicorn.Hosted_Runtime,
	// The implementation adds platform/presenter state in plugin_windows.odin.
	impl: ^Plugin_Editor_Impl,
}

// Plugin_Host owns the shared WebGPU device and the set of live editors. One
// device is shared deliberately: an audio-plugin host normally provides one
// GPU context, and per-editor runtimes still retain independent descriptions,
// motion deadlines, accessibility projections, and surfaces.
Plugin_Host :: struct {
	config: Plugin_Host_Config,
	// The implementation adds device and editor storage in plugin_windows.odin.
	impl: ^Plugin_Host_Impl,
}

// Plugin_Backend selects the wgpu adapter backend. Default lets wgpu choose.
Plugin_Backend :: enum i32 {
	Default         = 0,
	D3D11           = 3,
	D3D12           = 4,
	Metal           = 5,
	Vulkan          = 6,
	OpenGL          = 7,
}

Plugin_Power_Preference :: enum i32 {
	Default          = 0,
	Low_Power        = 1,
	High_Performance = 2,
}

Plugin_Host_Config :: struct {
	// backend is passed to RequestAdapterOptions. Default lets wgpu choose
	// (D3D12 on this Windows build).
	backend: Plugin_Backend,
	// power_preference selects the adapter power class.
	power_preference: Plugin_Power_Preference,
	// debug_device_label is reported to wgpu for diagnostics.
	debug_device_label: string,
}

Plugin_Editor_Config :: struct {
	parent: Plugin_Native_Parent,
	// logical_width/height are in display-independent logical units.
	logical_width, logical_height: int,
	// dpi_scale is the host display scale (96 DPI = 1.0), not the
	// drawable-to-logical ratio.
	dpi_scale: f32,
	// visible starts the editor shown. A hidden editor still owns its Runtime
	// and receives model work, but presents no frames.
	visible: bool,
	clear_color: [4]f32,
	// hosted carries the application render callback, lifecycle callbacks,
	// host services, menus, bindings, and diagnostics paint. The plugin fills
	// dimensions, dpi_scale, the wake callback, and monotonic_now.
	hosted: alicorn.Hosted_Runtime_Config,
	accessibility: Plugin_Accessibility,
	debug_name: string,
}

PLUGIN_DEFAULT_CLEAR_COLOR :: [4]f32{0.047, 0.055, 0.071, 1}

// plugin_status_string is used by fixtures and host logs. Unsupported values
// state the floating fallback explicitly rather than failing opaquely.
plugin_status_string :: proc(status: Plugin_Status) -> string {
	switch status {
	case .Ok: return "ok"
	case .Already_Initialized: return "already initialized"
	case .Not_Initialized: return "not initialized"
	case .Closed: return "closed"
	case .Invalid_Argument: return "invalid argument"
	case .Unsupported_Platform: return "unsupported platform: use a floating editor window"
	case .Unsupported_Wayland: return "Wayland has no embeddable child-window contract here: use a floating editor window"
	case .Unsupported_Parent: return "unsupported native parent kind"
	case .Device_Unavailable: return "WebGPU device unavailable"
	case .Surface_Unavailable: return "WebGPU surface could not be created from the native window"
	case .Presenter_Failure: return "WebGPU presenter failed"
	case .Runtime_Failure: return "hosted Runtime failed"
	case .Device_Lost: return "WebGPU device lost"
	case .Wrong_Thread: return "called from a thread that does not own the editor"
	case .Resource_Failure: return "resource allocation failed"
	case .Timeout: return "bounded operation timed out"
	}
	return "unknown plugin host status"
}

plugin_parent_is_supported :: proc(parent: Plugin_Native_Parent) -> bool {
	when ODIN_OS == .Windows {
		return parent.kind == .Windows_HWND && parent.window != nil
	} else {
		return false
	}
}

plugin_capabilities :: proc() -> Plugin_Host_Capabilities {
	when ODIN_OS == .Windows {
		return {
			platform=.Windows_HWND,
			embedded_surface=true,
			surface_from_hwnd=true,
			child_window=true,
			ime_composition=false,
			native_accessibility=false,
			device_recovery=true,
			scoped_input=true,
		}
	} else {
		platform := Plugin_Parent_Kind.Wayland_Surface
		when ODIN_OS == .Darwin { platform = .Cocoa_NSView }
		when ODIN_OS == .Linux {
			platform = .X11_Window
			if plugin_process_looks_like_wayland() { platform = .Wayland_Surface }
		}
		return {
			platform=platform,
			floating_fallback_only=true,
		}
	}
}

// plugin_status_for_parent validates the requested parent contract without
// creating a window. This is the explicit refusal path Wayland callers use.
plugin_status_for_parent :: proc(parent: Plugin_Native_Parent) -> Plugin_Status {
	when ODIN_OS == .Windows {
		if parent.kind != .Windows_HWND { return .Unsupported_Parent }
		if parent.window == nil { return .Invalid_Argument }
		return .Ok
	} else {
		if parent.kind == .Wayland_Surface { return .Unsupported_Wayland }
		return .Unsupported_Platform
	}
}

// plugin_host_config_clear is a convenience for callers that want explicit
// defaults. It uses high-performance adapter selection and the D3D12 backend on
// Windows, matching the hosted WebGPU validation host.
plugin_host_config_clear :: proc() -> Plugin_Host_Config {
	config := Plugin_Host_Config{
		power_preference=.High_Performance,
		debug_device_label="Alicorn plugin host device",
	}
	return config
}

// plugin_monotonic_now_ns is the one monotonic clock the plugin host uses for
// hosted_runtime_step, pointer timestamps, and scheduler deadlines. Fixtures
// and plugin wrappers must pass this value to plugin_host_step so deadlines
// and input timestamps share one domain.
plugin_monotonic_now_ns :: proc() -> u64 {
	return plugin_platform_monotonic_now_ns()
}

plugin_editor_config_clear :: proc() -> Plugin_Editor_Config {
	return Plugin_Editor_Config{
		dpi_scale=1,
		visible=true,
		clear_color=PLUGIN_DEFAULT_CLEAR_COLOR,
	}
}

// Plugin_Wake_Allocator documents the allocator requirement: retained wakers
// may be released by worker threads. Odin's default heap allocator is
// thread-safe, so callers may leave Hosted_Runtime_Config.wake_allocator zero.
@(private)
plugin_default_wake_allocator :: proc() -> mem.Allocator {
	return context.allocator
}
