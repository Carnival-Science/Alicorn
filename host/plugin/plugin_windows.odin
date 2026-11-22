#+build windows

package plugin_host

import "base:runtime"
import "core:fmt"
import "core:time"
import alicorn "alicorn:runtime"
import presentation_host "alicorn:host/presentation"
import win "core:sys/windows"
import "vendor:wgpu"

PLUGIN_WAKE_MESSAGE :: win.UINT(win.WM_APP + 0x1211)
PLUGIN_CLASS_NAME :: "AlicornPluginEditor"
PLUGIN_DEVICE_REQUEST_TIMEOUT_NS :: u64(5_000_000_000)
PLUGIN_RECOVERY_TIMEOUT_NS :: u64(5_000_000_000)
PLUGIN_RETRY_DELAY_NS :: u64(2_000_000)
PLUGIN_ARROW_CURSOR :: proc() -> win.HCURSOR {
	return win.LoadCursorW(nil, cstring16(win.MAKEINTRESOURCEW(32512)))
}

Plugin_Host_Impl :: struct {
	initialized:       bool,
	instance:          wgpu.Instance,
	adapter:           wgpu.Adapter,
	device:            wgpu.Device,
	queue:             wgpu.Queue,
	editors:           [dynamic]^Plugin_Editor,
	device_lost:       bool,
	device_loss_reason: wgpu.DeviceLostReason,
	recovering:        bool,
	recovery_attempts: int,
	next_wake_ns:      u64,
	class_registered:  bool,
	instance_module:   win.HINSTANCE,
}

Plugin_Editor_Impl :: struct {
	instance:              win.HINSTANCE,
	parent:                win.HWND,
	surface:               wgpu.Surface,
	format:                wgpu.TextureFormat,
	alpha_mode:            wgpu.CompositeAlphaMode,
	presenter:             presentation_host.Hosted_Surface_Presenter,
	presenter_attached:    bool,
	accessibility_attached: bool,
	config:                Plugin_Editor_Config,
	logical_width:         int,
	logical_height:        int,
	pixel_width:           int,
	pixel_height:          int,
	dpi_scale:             f32,
	visible:               bool,
	attached:              bool,
	renderable:            bool,
	steps:                 u64,
	presentations:         u64,
	last_presentation_us:  u64,
	next_wake_ns:          u64,
	capture_active:        bool,
	resizing:              bool,
	pending_high_surrogate: u16,
	destroying:            bool,
	closed:                bool,
}

@(private)
plugin_hinstance :: proc(parent: Plugin_Native_Parent) -> win.HINSTANCE {
	if parent.display != nil { return win.HINSTANCE(parent.display) }
	return win.HINSTANCE(win.GetModuleHandleW(nil))
}

@(private)
plugin_register_class :: proc(host: ^Plugin_Host) -> bool {
	impl := host.impl
	if impl.class_registered { return true }
	if impl.instance_module == nil { impl.instance_module = win.HINSTANCE(win.GetModuleHandleW(nil)) }
	class_name := win.utf8_to_utf16(PLUGIN_CLASS_NAME, context.temp_allocator)
	if class_name == nil { return false }
	wc := win.WNDCLASSEXW{
		cbSize=u32(size_of(win.WNDCLASSEXW)),
		style=win.CS_DBLCLKS | win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc=plugin_editor_wndproc,
		hInstance=impl.instance_module,
		hCursor=PLUGIN_ARROW_CURSOR(),
		lpszClassName=cstring16(&class_name[0]),
	}
	if win.RegisterClassExW(&wc) == 0 {
		// A duplicate registration from another host instance in this process
		// is benign: the class already has our window procedure.
		if win.GetLastError() != 0x582 { return false }
	}
	impl.class_registered = true
	return true
}

@(private)
plugin_create_instance :: proc(host: ^Plugin_Host) -> Plugin_Status {
	impl := host.impl
	if impl.instance != nil { return .Ok }
	impl.instance = wgpu.CreateInstance(nil)
	if impl.instance == nil { return .Device_Unavailable }
	return .Ok
}

@(private)
plugin_create_surface :: proc(host: ^Plugin_Host, editor: ^Plugin_Editor) -> Plugin_Status {
	impl := host.impl
	editor_impl := editor.impl
	if impl.instance == nil { return .Device_Unavailable }
	if editor_impl.surface != nil { return .Ok }
	source := wgpu.SurfaceSourceWindowsHWND{
		chain=wgpu.ChainedStruct{sType=.SurfaceSourceWindowsHWND},
		hinstance=rawptr(editor_impl.instance),
		hwnd=editor.window,
	}
	surface := wgpu.InstanceCreateSurface(
		impl.instance,
		&wgpu.SurfaceDescriptor{
			label=editor_impl.config.debug_name,
			nextInChain=&source,
		},
	)
	if surface == nil { return .Surface_Unavailable }
	editor_impl.surface = surface
	return .Ok
}

@(private)
Plugin_Adapter_Request :: struct {
	complete: bool,
	status:   wgpu.RequestAdapterStatus,
	adapter:  wgpu.Adapter,
	message:  wgpu.StringView,
}

@(private)
plugin_adapter_callback :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	context = runtime.default_context()
	request := cast(^Plugin_Adapter_Request)userdata1
	if request == nil { return }
	request.complete = true
	request.status = status
	request.message = message
	if adapter != nil { request.adapter = adapter }
}

@(private)
Plugin_Device_Request :: struct {
	complete: bool,
	status:   wgpu.RequestDeviceStatus,
	device:   wgpu.Device,
	message:  wgpu.StringView,
}

@(private)
plugin_device_callback :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	context = runtime.default_context()
	request := cast(^Plugin_Device_Request)userdata1
	if request == nil { return }
	request.complete = true
	request.status = status
	request.message = message
	if device != nil { request.device = device }
}

@(private)
plugin_device_lost_callback :: proc "c" (
	_device: ^wgpu.Device,
	reason: wgpu.DeviceLostReason,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	context = runtime.default_context()
	host := cast(^Plugin_Host)userdata1
	if host == nil || host.impl == nil { return }
	host.impl.device_lost = true
	host.impl.device_loss_reason = reason
	if host.impl.device != nil {
		for editor in host.impl.editors {
			if editor != nil && editor.impl != nil && editor.impl.presenter_attached {
				presentation_host.hosted_surface_presenter_mark_device_lost(&editor.impl.presenter)
			}
		}
	}
}

@(private)
plugin_uncaptured_error_callback :: proc "c" (
	_device: ^wgpu.Device,
	_type: wgpu.ErrorType,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	context = runtime.default_context()
	host := cast(^Plugin_Host)userdata1
	if host == nil { return }
	fmt.eprintln("[alicorn-plugin] uncaptured WebGPU device error")
}

@(private)
plugin_wait_for_adapter_and_device :: proc(host: ^Plugin_Host) -> Plugin_Status {
	impl := host.impl
	if impl.instance == nil { return .Device_Unavailable }
	if len(impl.editors) == 0 { return .Invalid_Argument }
	first := impl.editors[0]
	if first == nil || first.impl == nil || first.impl.surface == nil { return .Surface_Unavailable }

	adapter_request := Plugin_Adapter_Request{}
	_ = wgpu.InstanceRequestAdapter(
		impl.instance,
		&wgpu.RequestAdapterOptions{
			compatibleSurface=first.impl.surface,
			powerPreference=wgpu.PowerPreference(host.config.power_preference),
			backendType=wgpu.BackendType(host.config.backend),
		},
		{
			mode=.AllowProcessEvents,
			callback=plugin_adapter_callback,
			userdata1=rawptr(&adapter_request),
		},
	)
	deadline := plugin_monotonic_now_ns() + PLUGIN_DEVICE_REQUEST_TIMEOUT_NS
	for !adapter_request.complete {
		wgpu.InstanceProcessEvents(impl.instance)
		if plugin_monotonic_now_ns() >= deadline { return .Timeout }
		time.sleep(time.Millisecond)
	}
	if adapter_request.status != .Success || adapter_request.adapter == nil {
		fmt.eprintln("[alicorn-plugin] adapter request failed", adapter_request.status)
		if adapter_request.adapter != nil { wgpu.AdapterRelease(adapter_request.adapter) }
		return .Device_Unavailable
	}
	impl.adapter = adapter_request.adapter

	label := host.config.debug_device_label
	if len(label) == 0 { label = "Alicorn plugin host device" }
	device_request := Plugin_Device_Request{}
	_ = wgpu.AdapterRequestDevice(
		impl.adapter,
		&wgpu.DeviceDescriptor{
			label=label,
			deviceLostCallbackInfo={
				mode=.AllowProcessEvents,
				callback=plugin_device_lost_callback,
				userdata1=rawptr(host),
			},
			uncapturedErrorCallbackInfo={
				callback=plugin_uncaptured_error_callback,
				userdata1=rawptr(host),
			},
		},
		{
			mode=.AllowProcessEvents,
			callback=plugin_device_callback,
			userdata1=rawptr(&device_request),
		},
	)
	for !device_request.complete {
		wgpu.InstanceProcessEvents(impl.instance)
		if plugin_monotonic_now_ns() >= deadline { return .Timeout }
		time.sleep(time.Millisecond)
	}
	if device_request.status != .Success || device_request.device == nil {
		fmt.eprintln("[alicorn-plugin] device request failed", device_request.status)
		if device_request.device != nil { wgpu.DeviceRelease(device_request.device) }
		return .Device_Unavailable
	}
	impl.device = device_request.device
	impl.queue = wgpu.DeviceGetQueue(impl.device)
	if impl.queue == nil { return .Device_Unavailable }
	impl.device_lost = false
	impl.device_loss_reason = {}
	return .Ok
}

@(private)
plugin_configure_surface :: proc(host: ^Plugin_Host, editor: ^Plugin_Editor) -> Plugin_Status {
	impl := host.impl
	editor_impl := editor.impl
	if impl.adapter == nil || editor_impl.surface == nil { return .Device_Unavailable }
	caps, status := wgpu.SurfaceGetCapabilities(editor_impl.surface, impl.adapter)
	if status != .Success || caps.formatCount == 0 || caps.alphaModeCount == 0 {
		if status == .Success { wgpu.SurfaceCapabilitiesFreeMembers(caps) }
		return .Surface_Unavailable
	}
	defer wgpu.SurfaceCapabilitiesFreeMembers(caps)
	format := caps.formats[0]
	if selected, ok := presentation_host.hosted_presentation_format(caps.formats[:caps.formatCount]); ok {
		format = selected
	}
	alpha := caps.alphaModes[0]
	for i in 0..<int(caps.alphaModeCount) {
		if caps.alphaModes[i] == .Opaque { alpha = .Opaque; break }
	}
	editor_impl.format = format
	editor_impl.alpha_mode = alpha
	return .Ok
}

@(private)
plugin_attach_presenter :: proc(host: ^Plugin_Host, editor: ^Plugin_Editor) -> Plugin_Status {
	impl := host.impl
	editor_impl := editor.impl
	if impl.device == nil || impl.queue == nil || editor_impl.surface == nil { return .Device_Unavailable }
	if editor_impl.presenter_attached { return .Ok }
	pixel_width := max(1, editor_impl.pixel_width)
	pixel_height := max(1, editor_impl.pixel_height)
	clear := wgpu.Color{
		f64(editor_impl.config.clear_color[0]),
		f64(editor_impl.config.clear_color[1]),
		f64(editor_impl.config.clear_color[2]),
		f64(editor_impl.config.clear_color[3]),
	}
	configuration := wgpu.SurfaceConfiguration{
		device=impl.device,
		format=editor_impl.format,
		usage={.RenderAttachment},
		width=u32(pixel_width),
		height=u32(pixel_height),
		presentMode=.Fifo,
		alphaMode=editor_impl.alpha_mode,
	}
	result := presentation_host.hosted_surface_presenter_init(
		&editor_impl.presenter,
		&editor.hosted,
		editor_impl.surface,
		impl.device,
		impl.queue,
		configuration,
		editor_impl.logical_width,
		editor_impl.logical_height,
		editor_impl.dpi_scale,
		rawptr(editor.window),
		plugin_editor_presenter_wake,
		clear,
	)
	if result != .Ok {
		fmt.eprintln("[alicorn-plugin] presenter attach failed", result)
		return .Presenter_Failure
	}
	editor_impl.presenter_attached = true
	editor_impl.renderable = editor_impl.visible
	if !editor_impl.visible {
		_ = presentation_host.hosted_surface_presenter_set_visible(&editor_impl.presenter, false)
	}
	_ = presentation_host.hosted_surface_presenter_set_timing_enabled(&editor_impl.presenter, true)
	return .Ok
}

@(private)
plugin_editor_presenter_wake :: proc(data: rawptr) {
	if data == nil { return }
	_ = win.PostMessageW(win.HWND(data), PLUGIN_WAKE_MESSAGE, 0, 0)
}

@(private)
plugin_editor_post_wake :: proc(data: rawptr) -> bool {
	if data == nil { return false }
	return win.PostMessageW(win.HWND(data), PLUGIN_WAKE_MESSAGE, 0, 0) != false
}

@(private)
plugin_clock_origin := time.tick_now()

// plugin_platform_monotonic_now_ns is the one monotonic nanosecond domain this host passes to
// hosted_runtime_step, pointer timestamps, and deadline comparisons. It is
// deliberately independent of SDL and of wall-clock adjustments.
@(private)
plugin_platform_monotonic_now_ns :: proc() -> u64 {
	ns := time.duration_nanoseconds(time.tick_since(plugin_clock_origin))
	if ns <= 0 { return 0 }
	return u64(ns)
}

@(private)
plugin_now_ns :: proc(_data: rawptr) -> u64 {
	return plugin_monotonic_now_ns()
}

// alicorn_now_ns publishes the one monotonic clock the host passes to
// hosted_runtime_step and pointer timestamps. Using time.tick_now keeps the
// plugin host independent of SDL and consistent with the shared presenter.
@(private)
alicorn_now_ns :: proc() -> u64 {
	return plugin_monotonic_now_ns()
}

plugin_host_init :: proc(host: ^Plugin_Host, config: Plugin_Host_Config) -> Plugin_Status {
	if host == nil { return .Invalid_Argument }
	if host.impl != nil { return .Already_Initialized }
	impl := new(Plugin_Host_Impl)
	if impl == nil { return .Resource_Failure }
	impl.editors = make([dynamic]^Plugin_Editor)
	host.config = config
	host.impl = impl
	impl.initialized = true
	if !plugin_register_class(host) {
		plugin_host_destroy(host)
		return .Unsupported_Platform
	}
	return .Ok
}

plugin_host_destroy :: proc(host: ^Plugin_Host) -> Plugin_Status {
	if host == nil { return .Invalid_Argument }
	impl := host.impl
	if impl == nil { return .Ok }
	status := Plugin_Status.Ok
	for len(impl.editors) > 0 {
		editor := impl.editors[len(impl.editors)-1]
		result := plugin_host_destroy_editor(host, editor)
		if result != .Ok && status == .Ok { status = result }
	}
	if impl.queue != nil { wgpu.QueueRelease(impl.queue); impl.queue = nil }
	if impl.device != nil {
		if !impl.device_lost {
			_ = wgpu.DevicePoll(impl.device, true)
			if impl.instance != nil { wgpu.InstanceProcessEvents(impl.instance) }
		}
		wgpu.DeviceRelease(impl.device)
		impl.device = nil
	}
	if impl.adapter != nil { wgpu.AdapterRelease(impl.adapter); impl.adapter = nil }
	if impl.instance != nil { wgpu.InstanceRelease(impl.instance); impl.instance = nil }
	delete(impl.editors)
	free(impl)
	host.impl = nil
	return status
}

plugin_host_create_editor :: proc(
	host: ^Plugin_Host,
	editor: ^Plugin_Editor,
	config: Plugin_Editor_Config,
) -> Plugin_Status {
	if host == nil || editor == nil { return .Invalid_Argument }
	if host.impl == nil || !host.impl.initialized { return .Not_Initialized }
	if editor.impl != nil { return .Already_Initialized }
	if status := plugin_status_for_parent(config.parent); status != .Ok { return status }
	if config.hosted.render == nil { return .Invalid_Argument }
	if config.logical_width <= 0 || config.logical_height <= 0 { return .Invalid_Argument }
	if config.dpi_scale <= 0 { return .Invalid_Argument }
	if !plugin_register_class(host) { return .Unsupported_Platform }

	impl := host.impl
	parent_hwnd := win.HWND(config.parent.window)
	if win.IsWindow(parent_hwnd) == false { return .Invalid_Argument }
	hinstance := plugin_hinstance(config.parent)

	editor_impl := new(Plugin_Editor_Impl)
	if editor_impl == nil { return .Resource_Failure }
	editor_impl.config = config
	editor_impl.instance = hinstance
	editor_impl.parent = parent_hwnd
	editor_impl.logical_width = config.logical_width
	editor_impl.logical_height = config.logical_height
	editor_impl.pixel_width = max(1, int(f32(config.logical_width)*config.dpi_scale + 0.5))
	editor_impl.pixel_height = max(1, int(f32(config.logical_height)*config.dpi_scale + 0.5))
	editor_impl.dpi_scale = config.dpi_scale
	editor_impl.visible = config.visible
	editor_impl.attached = true

	class_name := win.utf8_to_utf16(PLUGIN_CLASS_NAME, context.temp_allocator)
	title := win.utf8_to_utf16("Alicorn plugin editor", context.temp_allocator)
	if class_name == nil || title == nil {
		free(editor_impl)
		return .Resource_Failure
	}
	style := win.WS_CHILD | win.WS_CLIPSIBLINGS | win.WS_CLIPCHILDREN
	if config.visible { style |= win.WS_VISIBLE }
	hwnd := win.CreateWindowExW(
		0,
		cstring16(&class_name[0]),
		cstring16(&title[0]),
		style,
		0, 0,
		win.INT(editor_impl.pixel_width),
		win.INT(editor_impl.pixel_height),
		parent_hwnd,
		nil,
		hinstance,
		nil,
	)
	if hwnd == nil {
		free(editor_impl)
		return .Unsupported_Parent
	}
	editor.window = rawptr(hwnd)
	editor.host = host
	editor.impl = editor_impl
	win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, win.LONG_PTR(uintptr(rawptr(editor))))

	if status := plugin_create_instance(host); status != .Ok {
		plugin_host_destroy_editor(host, editor)
		return status
	}
	append(&impl.editors, editor)
	if status := plugin_create_surface(host, editor); status != .Ok {
		plugin_host_destroy_editor(host, editor)
		return status
	}

	if impl.device == nil {
		if status := plugin_wait_for_adapter_and_device(host); status != .Ok {
			plugin_host_destroy_editor(host, editor)
			return status
		}
	}
	for candidate in impl.editors {
		if status := plugin_configure_surface(host, candidate); status != .Ok {
			plugin_host_destroy_editor(host, editor)
			return status
		}
	}

	// The embedded Hosted_Runtime owns one retained Runtime and posts worker
	// wakes to this child HWND. Its dimensions and clock are host-owned.
	hosted_config := config.hosted
	hosted_config.state = config.hosted.state
	hosted_config.logical_width = editor_impl.logical_width
	hosted_config.logical_height = editor_impl.logical_height
	hosted_config.pixel_width = editor_impl.pixel_width
	hosted_config.pixel_height = editor_impl.pixel_height
	hosted_config.dpi_scale = editor_impl.dpi_scale
	hosted_config.post_wake_data = rawptr(hwnd)
	hosted_config.post_wake = plugin_editor_post_wake
	hosted_config.monotonic_now = plugin_now_ns
	hosted_config.monotonic_now_data = nil
	if status := alicorn.hosted_runtime_init(&editor.hosted, hosted_config); status != .Ok {
		fmt.eprintln("[alicorn-plugin] hosted runtime init failed", status)
		plugin_host_destroy_editor(host, editor)
		return .Runtime_Failure
	}

	if status := plugin_attach_presenter(host, editor); status != .Ok {
		plugin_host_destroy_editor(host, editor)
		return status
	}
	editor_impl.renderable = true

	if config.accessibility.attach != nil {
		if config.accessibility.attach(
			config.accessibility.data,
			config.parent.kind,
			editor.window,
		) {
			editor_impl.accessibility_attached = true
		} else if config.accessibility.destroy != nil {
			// A failed attach must not leak the host's mutex, projection, or
			// adapter staging state.
			config.accessibility.destroy(config.accessibility.data)
		}
	}

	win.SetWindowPos(
		hwnd, nil, 0, 0,
		win.INT(editor_impl.pixel_width),
		win.INT(editor_impl.pixel_height),
		win.SWP_NOZORDER | win.SWP_NOACTIVATE,
	)
	_ = plugin_editor_request_presentation(editor)
	return .Ok
}

plugin_host_destroy_editor :: proc(host: ^Plugin_Host, editor: ^Plugin_Editor) -> Plugin_Status {
	if host == nil || editor == nil || editor.impl == nil { return .Invalid_Argument }
	impl := host.impl
	editor_impl := editor.impl
	editor_impl.destroying = true
	status := Plugin_Status.Ok

	if editor_impl.presenter_attached {
		deadline := plugin_monotonic_now_ns() + PLUGIN_RECOVERY_TIMEOUT_NS
		for {
			destroyed: bool
			if impl != nil && impl.device_lost {
				destroyed = presentation_host.hosted_surface_presenter_destroy_after_device_loss(&editor_impl.presenter)
			} else {
				destroyed = presentation_host.hosted_surface_presenter_destroy(&editor_impl.presenter)
			}
			if destroyed { break }
			if impl != nil && impl.device != nil {
				_ = wgpu.DevicePoll(impl.device, true)
				if impl.instance != nil { wgpu.InstanceProcessEvents(impl.instance) }
			}
			if plugin_monotonic_now_ns() >= deadline {
				status = .Timeout
				break
			}
			time.sleep(time.Millisecond)
		}
		editor_impl.presenter_attached = false
	}
	if editor_impl.accessibility_attached {
		editor_impl.config.accessibility.destroy(editor_impl.config.accessibility.data)
		editor_impl.accessibility_attached = false
	}
	if editor_impl.surface != nil {
		wgpu.SurfaceRelease(editor_impl.surface)
		editor_impl.surface = nil
	}
	if editor.hosted.state != nil {
		if result := alicorn.hosted_runtime_destroy(&editor.hosted); result != .Ok && status == .Ok {
			status = .Runtime_Failure
		}
	}
	if editor.window != nil {
		win.SetWindowLongPtrW(win.HWND(editor.window), win.GWLP_USERDATA, 0)
		_ = win.DestroyWindow(win.HWND(editor.window))
		editor.window = nil
	}
	if impl != nil {
		for candidate, index in impl.editors {
			if candidate == editor {
				ordered_remove(&impl.editors, index)
				break
			}
		}
	}
	editor_impl.closed = true
	free(editor_impl)
	editor^ = {}
	return status
}

plugin_host_step :: proc(host: ^Plugin_Host, now_ns: u64) -> Plugin_Step_Result {
	if host == nil { return {status=.Invalid_Argument} }
	impl := host.impl
	if impl == nil || !impl.initialized { return {status=.Not_Initialized} }
	if impl.device_lost && !impl.recovering { return {status=.Device_Lost} }
	result := Plugin_Step_Result{status=.Ok}
	next_wake := u64(0)
	for editor in impl.editors {
		if editor == nil || editor.impl == nil || editor.impl.destroying { continue }
		editor_impl := editor.impl
		editor_impl.steps += 1
		step, presentation := presentation_host.hosted_surface_presenter_step(
			&editor_impl.presenter,
			now_ns,
		)
		result.steps += 1
		if step.status != .Ok {
			result.status = .Runtime_Failure
			continue
		}
		editor_impl.next_wake_ns = step.next_wake_ns
		retry_ns := u64(0)
		switch presentation {
		case .Ok:
			editor_impl.presentations += 1
			result.presentations += 1
			if sample, ok := presentation_host.hosted_surface_presenter_last_timing(&editor_impl.presenter); ok {
				editor_impl.last_presentation_us = sample.step_to_present_ns / 1_000
			}
		case .No_Frame, .Suspended:
		case .Retry_Later:
			retry_ns = now_ns + PLUGIN_RETRY_DELAY_NS
		case .Reconfigure_Required:
			retry_ns = now_ns + PLUGIN_RETRY_DELAY_NS
		case .Hidden:
			// Occluded surfaces have no visible work. Do not poll: the host
			// requests a presentation when the native window is restored.
		case .Invalid_Input, .Resource_Failure, .Render_Failure,
		     .Surface_Acquire_Failure, .Present_Failure:
			if impl.device_lost {
				result.status = .Device_Lost
			} else if result.status == .Ok {
				result.status = .Presenter_Failure
			}
		}
		deadline := step.next_wake_ns
		if retry_ns != 0 && (deadline == 0 || retry_ns < deadline) { deadline = retry_ns }
		if deadline != 0 && (next_wake == 0 || deadline < next_wake) { next_wake = deadline }
		if editor_impl.visible && editor_impl.renderable {
			if step.has_more_work { result.has_more_work = true }
			if retry_ns != 0 { result.has_more_work = true }
		}
		if editor_impl.accessibility_attached {
			if rt, rt_status := alicorn.hosted_runtime_borrow(&editor.hosted); rt_status == .Ok {
				scale_x := f32(editor_impl.pixel_width) / f32(max(1, editor_impl.logical_width))
				scale_y := f32(editor_impl.pixel_height) / f32(max(1, editor_impl.logical_height))
				editor_impl.config.accessibility.sync(
					editor_impl.config.accessibility.data,
					rt,
					0,
					scale_x,
					scale_y,
				)
				editor_impl.config.accessibility.drain(
					editor_impl.config.accessibility.data,
					&editor.hosted,
				)
			}
		}
	}
	impl.next_wake_ns = next_wake
	if impl.device_lost { result.status = .Device_Lost }
	return result
}

plugin_host_next_wake_ns :: proc(host: ^Plugin_Host) -> u64 {
	if host == nil || host.impl == nil { return 0 }
	return host.impl.next_wake_ns
}

plugin_host_has_in_flight :: proc(host: ^Plugin_Host) -> bool {
	if host == nil || host.impl == nil { return false }
	for editor in host.impl.editors {
		if editor != nil && editor.impl != nil && editor.impl.presenter_attached &&
		   presentation_host.hosted_surface_presenter_has_in_flight(&editor.impl.presenter) {
			return true
		}
	}
	return false
}

plugin_host_device_lost :: proc(host: ^Plugin_Host) -> bool {
	return host != nil && host.impl != nil && host.impl.device_lost
}

plugin_host_poll :: proc(host: ^Plugin_Host) {
	if host == nil || host.impl == nil { return }
	plugin_host_pump_device(host, false)
}

@(private)
plugin_host_pump_device :: proc(host: ^Plugin_Host, wait: bool) {
	impl := host.impl
	if impl == nil { return }
	if impl.device != nil { _ = wgpu.DevicePoll(impl.device, b32(wait)) }
	if impl.instance != nil { wgpu.InstanceProcessEvents(impl.instance) }
}

plugin_host_simulate_device_loss :: proc(host: ^Plugin_Host) -> Plugin_Status {
	if host == nil || host.impl == nil { return .Invalid_Argument }
	impl := host.impl
	if impl.device_lost { return .Device_Lost }
	impl.device_lost = true
	impl.device_loss_reason = .Unknown
	for editor in impl.editors {
		if editor != nil && editor.impl != nil && editor.impl.presenter_attached {
			presentation_host.hosted_surface_presenter_mark_device_lost(&editor.impl.presenter)
		}
	}
	fmt.println("[alicorn-plugin] test injection: simulated unexpected device loss")
	return .Ok
}

@(private)
plugin_host_release_gpu :: proc(host: ^Plugin_Host) {
	impl := host.impl
	if impl == nil { return }
	if impl.queue != nil { wgpu.QueueRelease(impl.queue); impl.queue = nil }
	if impl.device != nil {
		if !impl.device_lost {
			_ = wgpu.DevicePoll(impl.device, true)
			if impl.instance != nil { wgpu.InstanceProcessEvents(impl.instance) }
		}
		wgpu.DeviceRelease(impl.device)
		impl.device = nil
	}
	if impl.adapter != nil { wgpu.AdapterRelease(impl.adapter); impl.adapter = nil }
	if impl.instance != nil { wgpu.InstanceRelease(impl.instance); impl.instance = nil }
}

plugin_host_recover :: proc(host: ^Plugin_Host, now_ns: u64) -> Plugin_Status {
	if host == nil || host.impl == nil { return .Invalid_Argument }
	impl := host.impl
	if !impl.device_lost { return .Ok }
	if impl.recovering { return .Ok }
	impl.recovering = true
	defer impl.recovering = false
	impl.recovery_attempts += 1

	if len(impl.editors) == 0 {
		plugin_host_release_gpu(host)
		impl.device_lost = false
		impl.device_loss_reason = {}
		return .Ok
	}

	// Drain completion callbacks owned by the lost device. Presenters refuse
	// destruction until their pending submissions have arrived.
	deadline := plugin_monotonic_now_ns() + PLUGIN_RECOVERY_TIMEOUT_NS
	for {
		all_destroyed := true
		for editor in impl.editors {
			if editor == nil || editor.impl == nil || !editor.impl.presenter_attached { continue }
			if !presentation_host.hosted_surface_presenter_destroy_after_device_loss(&editor.impl.presenter) {
				all_destroyed = false
			} else {
				editor.impl.presenter_attached = false
			}
		}
		if all_destroyed { break }
		plugin_host_pump_device(host, false)
		if plugin_monotonic_now_ns() >= deadline {
			fmt.eprintln("[alicorn-plugin] device-loss drain timed out")
			return .Timeout
		}
		time.sleep(time.Millisecond)
	}
	for editor in impl.editors {
		if editor != nil && editor.impl != nil && editor.impl.surface != nil {
			wgpu.SurfaceRelease(editor.impl.surface)
			editor.impl.surface = nil
		}
	}
	plugin_host_release_gpu(host)

	if status := plugin_create_instance(host); status != .Ok { return status }
	for editor in impl.editors {
		if editor == nil || editor.impl == nil { continue }
		if status := plugin_create_surface(host, editor); status != .Ok { return status }
	}
	if status := plugin_wait_for_adapter_and_device(host); status != .Ok { return status }
	for editor in impl.editors {
		if editor == nil || editor.impl == nil { continue }
		if status := plugin_configure_surface(host, editor); status != .Ok { return status }
		if status := plugin_attach_presenter(host, editor); status != .Ok { return status }
		if status := plugin_editor_request_presentation(editor); status != .Ok { return status }
	}
	impl.device_lost = false
	impl.device_loss_reason = {}
	impl.next_wake_ns = now_ns
	fmt.println("[alicorn-plugin] WebGPU device recovered; retained editor state preserved")
	return .Ok
}

plugin_editor_attach :: proc(editor: ^Plugin_Editor, parent: Plugin_Native_Parent) -> Plugin_Status {
	if editor == nil || editor.impl == nil { return .Invalid_Argument }
	if status := plugin_status_for_parent(parent); status != .Ok { return status }
	hwnd := win.HWND(parent.window)
	if win.IsWindow(hwnd) == false { return .Invalid_Argument }
	previous := win.SetParent(win.HWND(editor.window), hwnd)
	if previous == nil && win.GetLastError() != win.ERROR_SUCCESS { return .Unsupported_Parent }
	editor.impl.parent = hwnd
	editor.impl.attached = true
	editor.impl.config.parent = parent
	return .Ok
}

plugin_editor_show :: proc(editor: ^Plugin_Editor) -> Plugin_Status {
	if editor == nil || editor.impl == nil { return .Invalid_Argument }
	editor_impl := editor.impl
	if editor_impl.closed { return .Closed }
	editor_impl.visible = true
	editor_impl.renderable = true
	if editor_impl.presenter_attached {
		if result := presentation_host.hosted_surface_presenter_set_visible(&editor_impl.presenter, true); result != .Ok {
			return .Presenter_Failure
		}
	}
	_ = win.ShowWindow(win.HWND(editor.window), win.SW_SHOW)
	_ = win.SetFocus(win.HWND(editor.window))
	return plugin_editor_request_presentation(editor)
}

plugin_editor_hide :: proc(editor: ^Plugin_Editor) -> Plugin_Status {
	if editor == nil || editor.impl == nil { return .Invalid_Argument }
	editor_impl := editor.impl
	if editor_impl.closed { return .Closed }
	editor_impl.visible = false
	editor_impl.renderable = false
	if editor_impl.presenter_attached {
		if result := presentation_host.hosted_surface_presenter_set_visible(&editor_impl.presenter, false); result != .Ok {
			return .Presenter_Failure
		}
	}
	_ = win.ShowWindow(win.HWND(editor.window), win.SW_HIDE)
	return .Ok
}

plugin_editor_resize :: proc(
	editor: ^Plugin_Editor,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> Plugin_Status {
	if editor == nil || editor.impl == nil { return .Invalid_Argument }
	if logical_width <= 0 || logical_height <= 0 || dpi_scale <= 0 { return .Invalid_Argument }
	pixel_width := max(1, int(f32(logical_width)*dpi_scale + 0.5))
	pixel_height := max(1, int(f32(logical_height)*dpi_scale + 0.5))
	return plugin_editor_resize_pixels(editor, pixel_width, pixel_height, dpi_scale)
}

plugin_editor_resize_pixels :: proc(
	editor: ^Plugin_Editor,
	pixel_width, pixel_height: int,
	dpi_scale: f32,
) -> Plugin_Status {
	if editor == nil || editor.impl == nil { return .Invalid_Argument }
	if pixel_width <= 0 || pixel_height <= 0 || dpi_scale <= 0 { return .Invalid_Argument }
	editor_impl := editor.impl
	if editor_impl.closed { return .Closed }
	if editor_impl.resizing { return .Ok }
	editor_impl.resizing = true
	defer editor_impl.resizing = false
	logical_width := max(1, int(f32(pixel_width)/dpi_scale + 0.5))
	logical_height := max(1, int(f32(pixel_height)/dpi_scale + 0.5))
	editor_impl.pixel_width = pixel_width
	editor_impl.pixel_height = pixel_height
	editor_impl.logical_width = logical_width
	editor_impl.logical_height = logical_height
	editor_impl.dpi_scale = dpi_scale
	hwnd := win.HWND(editor.window)
	if hwnd != nil {
		rect: win.RECT
		if win.GetClientRect(hwnd, &rect) != false {
			if int(rect.right-rect.left) != pixel_width || int(rect.bottom-rect.top) != pixel_height {
				_ = win.MoveWindow(hwnd, 0, 0, win.INT(pixel_width), win.INT(pixel_height), false)
			}
		}
	}
	if editor_impl.presenter_attached {
		result := presentation_host.hosted_surface_presenter_resize(
			&editor_impl.presenter,
			logical_width, logical_height,
			pixel_width, pixel_height,
			dpi_scale,
		)
		switch result {
		case .Ok, .Suspended:
			return .Ok
		case .Invalid_Input, .Resource_Failure, .Render_Failure,
		     .Surface_Acquire_Failure, .Present_Failure:
			return .Presenter_Failure
		case .No_Frame, .Retry_Later, .Reconfigure_Required, .Hidden:
			return .Ok
		}
	}
	return .Ok
}

plugin_editor_request_presentation :: proc(editor: ^Plugin_Editor) -> Plugin_Status {
	if editor == nil || editor.impl == nil { return .Invalid_Argument }
	editor_impl := editor.impl
	if editor_impl.closed { return .Closed }
	if !editor_impl.presenter_attached {
		if editor.hosted.state == nil { return .Ok }
		return .Presenter_Failure
	}
	// request_presentation on a hidden editor is allowed: the Runtime records
	// pending content and presents it when the host shows the child again.
	if status := alicorn.hosted_runtime_request_presentation(&editor.hosted, "plugin editor requested presentation"); status != .Ok {
		return .Runtime_Failure
	}
	return .Ok
}

plugin_editor_native_window :: proc(editor: ^Plugin_Editor) -> rawptr {
	if editor == nil { return nil }
	return editor.window
}

plugin_editor_metrics :: proc(editor: ^Plugin_Editor) -> (Plugin_Editor_Metrics, bool) {
	if editor == nil || editor.impl == nil { return {}, false }
	editor_impl := editor.impl
	metrics := Plugin_Editor_Metrics{
		logical_width=editor_impl.logical_width,
		logical_height=editor_impl.logical_height,
		pixel_width=editor_impl.pixel_width,
		pixel_height=editor_impl.pixel_height,
		dpi_scale=editor_impl.dpi_scale,
		visible=editor_impl.visible,
		attached=editor_impl.attached,
		renderable=editor_impl.renderable,
		accessibility_attached=editor_impl.accessibility_attached,
		device_lost=editor.host != nil && editor.host.impl != nil && editor.host.impl.device_lost,
		steps=editor_impl.steps,
		presentations=editor_impl.presentations,
		last_presentation_us=editor_impl.last_presentation_us,
	}
	if editor_impl.presenter_attached {
		if lw, lh, pw, ph, _sx, _sy, ok := presentation_host.hosted_surface_presenter_metrics(&editor_impl.presenter); ok {
			metrics.logical_width = lw
			metrics.logical_height = lh
			metrics.pixel_width = pw
			metrics.pixel_height = ph
		}
		if stats, ok := presentation_host.hosted_surface_presenter_configuration_stats(&editor_impl.presenter); ok {
			metrics.configure_count = stats.configures
			metrics.configure_total_ns = stats.total_ns
			metrics.configure_last_ns = stats.last_ns
		}
	}
	if rt, status := alicorn.hosted_runtime_borrow(&editor.hosted); status == .Ok {
		stats := alicorn.frame_stats_snapshot(rt)
		metrics.frames_built = stats.frames_built
		metrics.descriptions_reused = stats.descriptions_reused
	}
	return metrics, true
}

plugin_editor_timing_summary :: proc(editor: ^Plugin_Editor) -> (summary: Plugin_Editor_Timing_Summary, ok: bool) {
	if editor == nil || editor.impl == nil || !editor.impl.presenter_attached { return {}, false }
	samples: [presentation_host.HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY]presentation_host.Hosted_Surface_Timing_Sample
	count := presentation_host.hosted_surface_presenter_copy_timing_samples(&editor.impl.presenter, samples[:])
	if count <= 0 { return summary, true }
	values: [presentation_host.HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY]u64
	for i in 0..<count { values[i] = samples[i].step_to_present_ns }
	// Bounded insertion sort: at most 256 samples and this runs only when a
	// caller asks for acceptance metrics, never in the frame path.
	for i in 1..<count {
		value := values[i]
		j := i
		for j > 0 && values[j-1] > value {
			values[j] = values[j-1]
			j -= 1
		}
		values[j] = value
	}
	p50_index := max(0, (count-1)*50/100)
	p95_index := min(count-1, (count-1)*95/100)
	return {
		samples=count,
		p50_ns=values[p50_index],
		p95_ns=values[p95_index],
		max_ns=values[count-1],
	}, true
}
