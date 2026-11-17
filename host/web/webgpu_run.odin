#+build js wasm32, js wasm64p32

package web_host

import "base:runtime"
import "core:fmt"
import alicorn "alicorn:runtime"
import "vendor:wgpu"

Browser_WebGPU_Run_Status :: enum {
	Uninitialized,
	Adapter_Pending,
	Device_Pending,
	Ready,
	Device_Lost,
	Failed,
	Destroying,
	Destroyed,
}

Browser_WebGPU_Run_Result :: enum {
	Ok,
	Invalid_Input,
	Resource_Failure,
	Presenter_Failure,
	Input_Failure,
}

// Browser_WebGPU_Run owns browser WebGPU bootstrap and the resulting
// Browser_Application. It is a single-owner-thread object. Keep it alive until
// browser_webgpu_run_destroy returns true, including while adapter/device
// callbacks or submitted frames are pending.
Browser_WebGPU_Run :: struct {
	ctx: runtime.Context,
	instance: wgpu.Instance,
	surface: wgpu.Surface,
	adapter: wgpu.Adapter,
	device: wgpu.Device,
	queue: wgpu.Queue,
	configuration: wgpu.SurfaceConfiguration,
	application: Browser_Application,
	hosted_config: alicorn.Hosted_Runtime_Config,
	canvas_id: string,
	text_input_id: string,
	accessibility_root_id: string,
	platform: Browser_Platform,
	wake_data: rawptr,
	wake: Browser_Application_Wake_Proc,
	clear_color: wgpu.Color,
	status: Browser_WebGPU_Run_Status,
	adapter_pending: bool,
	device_pending: bool,
	destroy_requested: bool,
	initialized: bool,
}

browser_webgpu_run_start :: proc(
	host: ^Browser_WebGPU_Run,
	hosted_config: alicorn.Hosted_Runtime_Config,
	canvas_id: string,
	platform: Browser_Platform,
	wake_data: rawptr,
	wake: Browser_Application_Wake_Proc,
	text_input_id: string = "",
	accessibility_root_id: string = "",
	clear_color: wgpu.Color = {0.04, 0.06, 0.08, 1},
) -> Browser_WebGPU_Run_Result {
	if host == nil || host.initialized || hosted_config.render == nil || wake == nil ||
	   !browser_application_id_is_safe(canvas_id) ||
	   (text_input_id != "" && (!browser_application_id_is_safe(text_input_id) || text_input_id == canvas_id)) ||
	   (accessibility_root_id != "" && (!browser_application_id_is_safe(accessibility_root_id) ||
	    accessibility_root_id == canvas_id || accessibility_root_id == text_input_id)) {
		return .Invalid_Input
	}
	host^ = Browser_WebGPU_Run{
		ctx=context,
		hosted_config=hosted_config,
		canvas_id=canvas_id,
		text_input_id=text_input_id,
		accessibility_root_id=accessibility_root_id,
		platform=platform,
		wake_data=wake_data,
		wake=wake,
		clear_color=clear_color,
		status=.Adapter_Pending,
		initialized=true,
	}
	host.instance = wgpu.CreateInstance(nil)
	if host.instance == nil {
		host.status = .Failed
		return .Resource_Failure
	}
	surface_source := wgpu.SurfaceSourceCanvasHTMLSelector{
		chain={sType=.SurfaceSourceCanvasHTMLSelector},
		selector=fmt.tprintf("#%s", canvas_id),
	}
	surface_descriptor := wgpu.SurfaceDescriptor{
		nextInChain=&surface_source.chain,
		label="Alicorn WebGPU canvas surface",
	}
	host.surface = wgpu.InstanceCreateSurface(host.instance, &surface_descriptor)
	if host.surface == nil {
		browser_webgpu_run_release_handles(host)
		host.status = .Failed
		return .Resource_Failure
	}
	options := wgpu.RequestAdapterOptions{
		powerPreference=.HighPerformance,
		compatibleSurface=host.surface,
	}
	host.adapter_pending = true
	wgpu.InstanceRequestAdapter(host.instance, &options, {
		mode=.AllowSpontaneos,
		callback=browser_webgpu_run_adapter_callback,
		userdata1=rawptr(host),
	})
	return .Ok
}

@(private)
browser_webgpu_run_wake :: proc(host: ^Browser_WebGPU_Run) {
	if host != nil && host.wake != nil { host.wake(host.wake_data) }
}

@(private)
browser_webgpu_run_adapter_callback :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	_message: string,
	userdata1, _userdata2: rawptr,
) {
	host := cast(^Browser_WebGPU_Run)userdata1
	if host == nil { return }
	context = host.ctx
	host.adapter_pending = false
	if host.destroy_requested {
		if adapter != nil { wgpu.AdapterRelease(adapter) }
		browser_webgpu_run_release_handles(host)
		host.status = .Destroyed
		browser_webgpu_run_wake(host)
		return
	}
	if status != .Success || adapter == nil {
		host.status = .Failed
		browser_webgpu_run_wake(host)
		return
	}
	host.adapter = adapter
	caps, cap_status := wgpu.SurfaceGetCapabilities(host.surface, adapter)
	if cap_status != .Success || caps.formatCount == 0 || caps.alphaModeCount == 0 || caps.presentModeCount == 0 {
		if cap_status == .Success { wgpu.SurfaceCapabilitiesFreeMembers(caps) }
		host.status = .Failed
		browser_webgpu_run_wake(host)
		return
	}
	format := caps.formats[0]
	for i in 0..<int(caps.formatCount) {
		candidate := caps.formats[i]
		if candidate == .BGRA8UnormSrgb { format = candidate; break }
		if candidate == .BGRA8Unorm { format = candidate }
	}
	alpha_mode := caps.alphaModes[0]
	for i in 0..<int(caps.alphaModeCount) {
		if caps.alphaModes[i] == .Opaque { alpha_mode = .Opaque; break }
	}
	present_mode := caps.presentModes[0]
	for i in 0..<int(caps.presentModeCount) {
		if caps.presentModes[i] == .Fifo { present_mode = .Fifo; break }
	}
	wgpu.SurfaceCapabilitiesFreeMembers(caps)
	host.configuration = wgpu.SurfaceConfiguration{
		format=format,
		usage={.RenderAttachment},
		alphaMode=alpha_mode,
		presentMode=present_mode,
	}
	host.status = .Device_Pending
	host.device_pending = true
	device_descriptor := wgpu.DeviceDescriptor{
		label="Alicorn browser WebGPU device",
		deviceLostCallbackInfo={
			mode=.AllowSpontaneos,
			callback=browser_webgpu_run_device_lost,
			userdata1=rawptr(host),
		},
	}
	wgpu.AdapterRequestDevice(host.adapter, &device_descriptor, {
		mode=.AllowSpontaneos,
		callback=browser_webgpu_run_device_callback,
		userdata1=rawptr(host),
	})
}

@(private)
browser_webgpu_run_device_callback :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	_message: string,
	userdata1, _userdata2: rawptr,
) {
	host := cast(^Browser_WebGPU_Run)userdata1
	if host == nil { return }
	context = host.ctx
	host.device_pending = false
	if host.destroy_requested {
		if device != nil {
			wgpu.DeviceDestroy(device)
			wgpu.DeviceRelease(device)
		}
		browser_webgpu_run_release_handles(host)
		host.status = .Destroyed
		browser_webgpu_run_wake(host)
		return
	}
	if status != .Success || device == nil {
		host.status = .Failed
		browser_webgpu_run_wake(host)
		return
	}
	host.device = device
	host.queue = wgpu.DeviceGetQueue(device)
	if host.queue == nil {
		host.status = .Failed
		browser_webgpu_run_wake(host)
		return
	}
	if result := browser_application_init(
		&host.application,
		host.hosted_config,
		host.surface,
		host.device,
		host.queue,
		host.configuration,
		host.canvas_id,
		host.platform,
		rawptr(host),
		browser_webgpu_run_application_wake,
		host.text_input_id,
		host.clear_color,
		host.accessibility_root_id,
	); result != .Ok {
		host.status = .Failed
		browser_webgpu_run_wake(host)
		return
	}
	host.status = .Ready
	browser_webgpu_run_wake(host)
}

@(private)
browser_webgpu_run_device_lost :: proc "c" (
	_device: ^wgpu.Device,
	_reason: wgpu.DeviceLostReason,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	host := cast(^Browser_WebGPU_Run)userdata1
	if host == nil || host.destroy_requested { return }
	context = host.ctx
	host.status = .Device_Lost
	browser_webgpu_run_wake(host)
}

@(private)
browser_webgpu_run_application_wake :: proc(data: rawptr) {
	host := cast(^Browser_WebGPU_Run)data
	if host != nil { browser_webgpu_run_wake(host) }
}

browser_webgpu_run_status :: proc(host: ^Browser_WebGPU_Run) -> Browser_WebGPU_Run_Status {
	if host == nil { return .Failed }
	return host.status
}

browser_webgpu_run_step :: proc(host: ^Browser_WebGPU_Run, now_ns: u64) -> Browser_Application_Step {
	if host == nil || host.status != .Ready {
		return Browser_Application_Step{status=.Closed, presentation=.Invalid_Input}
	}
	context = host.ctx
	return browser_application_step(&host.application, now_ns)
}

browser_webgpu_run_next_wake_ns :: proc(host: ^Browser_WebGPU_Run) -> u64 {
	if host == nil || host.status != .Ready { return 0 }
	return host.application.next_wake_ns
}

browser_webgpu_run_resize :: proc(host: ^Browser_WebGPU_Run) -> Browser_Surface_Result {
	if host == nil || host.status != .Ready { return .Invalid_Input }
	context = host.ctx
	return browser_application_resize(&host.application)
}

// Request nonblocking shutdown. While adapter/device setup or queued frames are
// pending, the host object and all callback state remain live until a callback
// wakes the embedder and a later call returns true.
browser_webgpu_run_destroy :: proc(host: ^Browser_WebGPU_Run) -> bool {
	if host == nil { return false }
	context = host.ctx
	if host.status == .Destroyed {
		host.initialized = false
		return true
	}
	if !host.initialized { return true }
	host.destroy_requested = true
	host.status = .Destroying
	if host.application.initialized && !browser_application_destroy(&host.application) { return false }
	if host.adapter_pending || host.device_pending { return false }
	browser_webgpu_run_release_handles(host)
	host.status = .Destroyed
	host.initialized = false
	return true
}

@(private)
browser_webgpu_run_release_handles :: proc(host: ^Browser_WebGPU_Run) {
	if host.queue != nil { wgpu.QueueRelease(host.queue); host.queue = nil }
	if host.device != nil {
		wgpu.DeviceDestroy(host.device)
		wgpu.DeviceRelease(host.device)
		host.device = nil
	}
	if host.adapter != nil { wgpu.AdapterRelease(host.adapter); host.adapter = nil }
	if host.surface != nil { wgpu.SurfaceRelease(host.surface); host.surface = nil }
	if host.instance != nil { wgpu.InstanceRelease(host.instance); host.instance = nil }
}
