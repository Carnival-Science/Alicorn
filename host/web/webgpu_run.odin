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
	Recovery_Draining,
	Recovery_Waiting,
	Recovery_Adapter_Pending,
	Recovery_Device_Pending,
	Recovery_Failed,
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

BROWSER_WEBGPU_RECOVERY_MAX_ATTEMPTS :: 3
BROWSER_WEBGPU_RECOVERY_BACKOFF_NS :: [3]u64{250_000_000, 1_000_000_000, 2_000_000_000}

// Browser_WebGPU_Run owns browser WebGPU bootstrap and the resulting
// Browser_Application. It is a single-owner-thread object. Keep it alive until
// browser_webgpu_run_destroy returns true, including while adapter/device
// callbacks, the device-lost callback, or submitted-frame callbacks are pending.
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
	recovery_attempts: int,
	recovery_retry_at_ns: u64,
	last_now_ns: u64,
	adapter_pending: bool,
	device_pending: bool,
	device_lost_callback_pending: bool,
	recovery_active: bool,
	device_is_lost: bool,
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
	browser_webgpu_run_request_adapter(host, false)
	return .Ok
}

@(private)
browser_webgpu_run_wake :: proc(host: ^Browser_WebGPU_Run) {
	if host != nil && host.wake != nil { host.wake(host.wake_data) }
}

@(private)
browser_webgpu_run_request_adapter :: proc(host: ^Browser_WebGPU_Run, recovery: bool) {
	if host == nil || host.destroy_requested || host.instance == nil || host.surface == nil { return }
	options := wgpu.RequestAdapterOptions{
		powerPreference=.HighPerformance,
		compatibleSurface=host.surface,
	}
	host.adapter_pending = true
	if recovery {
		host.recovery_attempts += 1
		host.status = .Recovery_Adapter_Pending
	} else {
		host.status = .Adapter_Pending
	}
	wgpu.InstanceRequestAdapter(host.instance, &options, {
		mode=.AllowSpontaneos,
		callback=browser_webgpu_run_adapter_callback,
		userdata1=rawptr(host),
	})
}

@(private)
browser_webgpu_run_recovery_attempt_failed :: proc(host: ^Browser_WebGPU_Run) {
	browser_webgpu_run_release_device_handles(host, false)
	if host.recovery_attempts >= BROWSER_WEBGPU_RECOVERY_MAX_ATTEMPTS {
		host.status = .Recovery_Failed
		host.recovery_retry_at_ns = 0
	} else {
		backoff := BROWSER_WEBGPU_RECOVERY_BACKOFF_NS
		backoff_index := clamp(host.recovery_attempts-1, 0, len(BROWSER_WEBGPU_RECOVERY_BACKOFF_NS)-1)
		host.recovery_retry_at_ns = host.last_now_ns + backoff[backoff_index]
		host.status = .Recovery_Waiting
	}
	browser_webgpu_run_wake(host)
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
		if host.recovery_active {
			browser_webgpu_run_recovery_attempt_failed(host)
		} else {
			host.status = .Failed
			browser_webgpu_run_wake(host)
		}
		return
	}
	host.adapter = adapter
	caps, cap_status := wgpu.SurfaceGetCapabilities(host.surface, adapter)
	if cap_status != .Success || caps.formatCount == 0 || caps.alphaModeCount == 0 || caps.presentModeCount == 0 {
		if cap_status == .Success { wgpu.SurfaceCapabilitiesFreeMembers(caps) }
		wgpu.AdapterRelease(host.adapter)
		host.adapter = nil
		if host.recovery_active {
			browser_webgpu_run_recovery_attempt_failed(host)
		} else {
			host.status = .Failed
			browser_webgpu_run_wake(host)
		}
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
	if host.recovery_active {
		host.status = .Recovery_Device_Pending
	} else {
		host.status = .Device_Pending
	}
	host.device_pending = true
	device_descriptor := wgpu.DeviceDescriptor{
		label="Alicorn browser WebGPU device",
		deviceLostCallbackInfo={
			mode=.AllowSpontaneos,
			callback=browser_webgpu_run_device_lost,
			userdata1=rawptr(host),
		},
	}
	host.device_lost_callback_pending = true
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
			if !host.device_is_lost { wgpu.DeviceDestroy(device) }
			wgpu.DeviceRelease(device)
		} else {
			host.device_lost_callback_pending = false
		}
		browser_webgpu_run_release_handles(host)
		if host.device_lost_callback_pending { host.status = .Destroying }
		else { host.status = .Destroyed; host.initialized = false }
		browser_webgpu_run_wake(host)
		return
	}
	if status != .Success || device == nil {
		if device != nil {
			// A failed request that nevertheless returned a device is unusual.
			// Keep it owned until shutdown so its lost callback context remains
			// valid instead of retrying around an outstanding callback.
			host.device = device
			host.status = .Recovery_Failed
			browser_webgpu_run_wake(host)
			return
		}
		host.device_lost_callback_pending = false
		if host.recovery_active {
			browser_webgpu_run_recovery_attempt_failed(host)
		} else {
			host.status = .Failed
			browser_webgpu_run_wake(host)
		}
		return
	}
	host.device = device
	host.queue = wgpu.DeviceGetQueue(device)
	if host.queue == nil {
		if host.recovery_active {
			host.status = .Recovery_Failed
			browser_webgpu_run_wake(host)
		} else {
			host.status = .Failed
			browser_webgpu_run_wake(host)
		}
		return
	}
	if host.device_is_lost {
		if host.recovery_active { host.status = .Recovery_Draining }
		else { host.status = .Device_Lost }
		browser_webgpu_run_wake(host)
		return
	}
	app_result: Browser_Application_Result
	if host.application.initialized {
		app_result = browser_application_attach_presenter(
			&host.application, host.surface, host.device, host.queue, host.configuration,
		)
	} else {
		app_result = browser_application_init(
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
		)
	}
	if app_result != .Ok {
		if host.recovery_active {
			host.status = .Recovery_Failed
			browser_webgpu_run_wake(host)
		} else {
			host.status = .Failed
			browser_webgpu_run_wake(host)
		}
		return
	}
	if host.device_is_lost {
		browser_application_mark_device_lost(&host.application)
		if host.recovery_active { host.status = .Recovery_Draining }
		else { host.status = .Device_Lost }
		browser_webgpu_run_wake(host)
		return
	}
	host.status = .Ready
	host.recovery_active = false
	host.recovery_attempts = 0
	host.recovery_retry_at_ns = 0
	browser_webgpu_run_wake(host)
}

@(private)
browser_webgpu_run_device_lost :: proc "c" (
	_device: ^wgpu.Device,
	reason: wgpu.DeviceLostReason,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	host := cast(^Browser_WebGPU_Run)userdata1
	if host == nil { return }
	context = host.ctx
	host.device_lost_callback_pending = false
	host.device_is_lost = true
	if host.destroy_requested {
		browser_webgpu_run_wake(host)
		return
	}
	if host.application.initialized { browser_application_mark_device_lost(&host.application) }
	if reason == .Destroyed || reason == .CallbackCancelled {
		host.status = .Device_Lost
	} else {
		if !host.recovery_active { host.recovery_attempts = 0 }
		host.recovery_active = true
		host.recovery_retry_at_ns = 0
		host.status = .Recovery_Draining
	}
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
	if host == nil { return 0 }
	if host.status == .Recovery_Waiting { return host.recovery_retry_at_ns }
	if host.status != .Ready { return 0 }
	return host.application.next_wake_ns
}

// Advance only host lifecycle work. It never describes the UI or submits a
// frame. Queue callbacks wake this path while draining; bounded deadlines
// retry adapter/device requests without a perpetual animation-frame loop.
browser_webgpu_run_recovery_step :: proc(host: ^Browser_WebGPU_Run, now_ns: u64) -> bool {
	if host == nil || host.destroy_requested || !host.recovery_active { return false }
	host.last_now_ns = now_ns
	if host.status == .Recovery_Draining {
		if host.application.initialized && !browser_application_detach_lost_presenter(&host.application) {
			return false
		}
		browser_webgpu_run_release_device_handles(host, false)
		host.status = .Recovery_Waiting
		host.recovery_retry_at_ns = now_ns
	}
	if host.status == .Recovery_Waiting && now_ns >= host.recovery_retry_at_ns {
		if host.recovery_attempts >= BROWSER_WEBGPU_RECOVERY_MAX_ATTEMPTS {
			host.status = .Recovery_Failed
			host.recovery_retry_at_ns = 0
			browser_webgpu_run_wake(host)
			return false
		}
		browser_webgpu_run_request_adapter(host, true)
	}
	return false
}

browser_webgpu_run_resize :: proc(host: ^Browser_WebGPU_Run) -> Browser_Surface_Result {
	if host == nil || host.status != .Ready { return .Invalid_Input }
	context = host.ctx
	return browser_application_resize(&host.application)
}

// Request nonblocking shutdown. While adapter/device setup, the device-lost
// callback, or queued frames are pending, keep the host and callback state live
// until a callback wakes the embedder and a later call returns true.
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
	if host.device_lost_callback_pending { return false }
	host.status = .Destroyed
	host.initialized = false
	return true
}

@(private)
browser_webgpu_run_release_handles :: proc(host: ^Browser_WebGPU_Run) {
	browser_webgpu_run_release_device_handles(host, !host.device_is_lost)
	if host.surface != nil { wgpu.SurfaceRelease(host.surface); host.surface = nil }
	if host.instance != nil { wgpu.InstanceRelease(host.instance); host.instance = nil }
}

@(private)
browser_webgpu_run_release_device_handles :: proc(host: ^Browser_WebGPU_Run, destroy_device: bool) {
	if host.queue != nil { wgpu.QueueRelease(host.queue); host.queue = nil }
	if host.device != nil {
		if destroy_device && !host.device_is_lost { wgpu.DeviceDestroy(host.device) }
		wgpu.DeviceRelease(host.device)
		host.device = nil
	}
	if host.adapter != nil { wgpu.AdapterRelease(host.adapter); host.adapter = nil }
	host.device_is_lost = false
}
