#+build !js

package sdl3_host

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"
import "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

SDL3_WebGPU_Run_Result :: enum {
	Ok,
	Invalid_Input,
	SDL_Failure,
	WebGPU_Failure,
	Runtime_Failure,
	Presenter_Failure,
	Event_Failure,
	Device_Lost,
	Smoke_Timeout,
}

SDL3_WebGPU_Run_State :: struct {
	instance: wgpu.Instance,
	surface: wgpu.Surface,
	adapter: wgpu.Adapter,
	device: wgpu.Device,
	queue: wgpu.Queue,
	configuration: wgpu.SurfaceConfiguration,
	adapter_complete: bool,
	device_complete: bool,
	failed: bool,
	closing: bool,
	device_lost: bool,
	device_loss_reported: bool,
	adapter_status: wgpu.RequestAdapterStatus,
	device_status: wgpu.RequestDeviceStatus,
	device_loss_reason: wgpu.DeviceLostReason,
	width_px: u32,
	height_px: u32,
}

@(private)
sdl3_webgpu_run_adapter_callback :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	state := cast(^SDL3_WebGPU_Run_State)userdata1
	if state == nil { return }
	state.adapter_complete = true
	state.adapter_status = status
	if status != .Success || adapter == nil {
		state.failed = true
		return
	}
	state.adapter = adapter

	caps, caps_status := wgpu.SurfaceGetCapabilities(state.surface, adapter)
	if caps_status != .Success || caps.formatCount == 0 || caps.alphaModeCount == 0 {
		if caps_status == .Success { wgpu.SurfaceCapabilitiesFreeMembers(caps) }
		state.failed = true
		return
	}
	state.configuration.format = caps.formats[0]
	for i in 0..<int(caps.formatCount) {
		format := caps.formats[i]
		if format == .BGRA8UnormSrgb {
			state.configuration.format = format
			break
		}
		if format == .BGRA8Unorm { state.configuration.format = format }
	}
	state.configuration.alphaMode = caps.alphaModes[0]
	for i in 0..<int(caps.alphaModeCount) {
		if caps.alphaModes[i] == .Opaque {
			state.configuration.alphaMode = .Opaque
			break
		}
	}
	wgpu.SurfaceCapabilitiesFreeMembers(caps)

	device_descriptor := wgpu.DeviceDescriptor{
		label = "Alicorn native WebGPU device",
		deviceLostCallbackInfo = {
			mode = .AllowProcessEvents,
			callback = sdl3_webgpu_run_device_lost_callback,
			userdata1 = rawptr(state),
		},
	}
	_ = wgpu.AdapterRequestDevice(adapter, &device_descriptor, {
		mode = .AllowProcessEvents,
		callback = sdl3_webgpu_run_device_callback,
		userdata1 = rawptr(state),
	})
}

@(private)
sdl3_webgpu_run_device_callback :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	state := cast(^SDL3_WebGPU_Run_State)userdata1
	if state == nil { return }
	state.device_complete = true
	state.device_status = status
	if status != .Success || device == nil {
		state.failed = true
		return
	}
	state.device = device
	state.queue = wgpu.DeviceGetQueue(device)
	if state.queue == nil {
		state.failed = true
		return
	}
	state.configuration.device = device
}

@(private)
sdl3_webgpu_run_device_lost_callback :: proc "c" (
	_device: ^wgpu.Device,
	reason: wgpu.DeviceLostReason,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	state := cast(^SDL3_WebGPU_Run_State)userdata1
	if state == nil || state.closing { return }
	state.device_lost = true
	state.device_loss_reported = true
	state.device_loss_reason = reason
}

@(private)
sdl3_webgpu_run_requested_backend :: proc() -> (backend: wgpu.BackendType, valid: bool) {
	for argument in os.args {
		if argument == "--backend=vulkan" { return .Vulkan, true }
		if argument == "--backend=d3d12" { return .D3D12, true }
		if strings.has_prefix(argument, "--backend=") { return .Undefined, false }
	}
	return .Undefined, true
}

@(private)
sdl3_webgpu_run_release_state :: proc(state: ^SDL3_WebGPU_Run_State) {
	if state == nil { return }
	state.closing = true
	if state.queue != nil {
		wgpu.QueueRelease(state.queue)
		state.queue = nil
	}
	if state.device != nil {
		wgpu.DeviceDestroy(state.device)
		_ = wgpu.DevicePoll(state.device, true)
		if state.instance != nil { wgpu.InstanceProcessEvents(state.instance) }
		wgpu.DeviceRelease(state.device)
		state.device = nil
	}
	if state.adapter != nil {
		wgpu.AdapterRelease(state.adapter)
		state.adapter = nil
	}
	if state.surface != nil {
		wgpu.SurfaceUnconfigure(state.surface)
		wgpu.SurfaceRelease(state.surface)
		state.surface = nil
	}
	if state.instance != nil {
		wgpu.InstanceRelease(state.instance)
		state.instance = nil
	}
}

@(private)
sdl3_webgpu_run_destroy_application :: proc(
	application: ^SDL3_WebGPU_Application,
	state: ^SDL3_WebGPU_Run_State,
) {
	if application == nil || !application.initialized { return }
	for !sdl3_webgpu_application_destroy(application) {
		if sdl3_webgpu_application_has_in_flight(application) && state.device != nil {
			// Blocking is restricted to shutdown, after new submissions stop, so
			// the nonblocking presenter can retire its final queue serial safely.
			_ = wgpu.DevicePoll(state.device, true)
			if state.instance != nil { wgpu.InstanceProcessEvents(state.instance) }
		} else {
			event: sdl3.Event
			_ = sdl3.WaitEventTimeout(&event, 1)
		}
	}
}

// sdl3_webgpu_run owns the ordinary SDL3 window and WebGPU bootstrap while
// reusing the same Hosted_Runtime coordinator and WebGPU surface presenter as
// the feasibility fixture. It is an opt-in migration path; ui.run remains on
// the reference SDL_GPU backend until native acceptance is complete.
sdl3_webgpu_run :: proc(
	hosted_config: alicorn.Hosted_Runtime_Config,
	title: string = "Alicorn",
	width: int = 720,
	height: int = 480,
	smoke: bool = false,
	clear_color: wgpu.Color = {0.04, 0.06, 0.08, 1},
) -> SDL3_WebGPU_Run_Result {
	if hosted_config.render == nil || width <= 0 || height <= 0 { return .Invalid_Input }
	requested_backend, backend_valid := sdl3_webgpu_run_requested_backend()
	if !backend_valid { return .Invalid_Input }
	if !sdl3.SetHint(sdl3.HINT_IME_IMPLEMENTED_UI, "composition") { return .SDL_Failure }
	when ODIN_OS == .Darwin {
		if !sdl3.SetHint(sdl3.HINT_MAC_SCROLL_MOMENTUM, "1") &&
		   sdl3.GetHint(sdl3.HINT_MAC_SCROLL_MOMENTUM) == nil {
			return .SDL_Failure
		}
	}
	if !sdl3.Init({.VIDEO}) { return .SDL_Failure }
	defer sdl3.Quit()

	title_cstring, title_error := strings.clone_to_cstring(title, context.temp_allocator)
	if title_error != nil { return .Invalid_Input }
	window := sdl3.CreateWindow(
		title_cstring,
		c.int(width),
		c.int(height),
		{.HIDDEN, .RESIZABLE, .HIGH_PIXEL_DENSITY},
	)
	if window == nil { return .SDL_Failure }
	defer sdl3.DestroyWindow(window)

	state: SDL3_WebGPU_Run_State
	defer sdl3_webgpu_run_release_state(&state)
	state.instance = wgpu.CreateInstance(nil)
	if state.instance == nil { return .WebGPU_Failure }
	state.surface = sdl3glue.GetSurface(state.instance, window)
	if state.surface == nil { return .WebGPU_Failure }

	logical_width, logical_height, pixel_width, pixel_height, metrics_ok :=
		sdl3_webgpu_application_window_metrics(window)
	if !metrics_ok || logical_width <= 0 || logical_height <= 0 || pixel_width <= 0 || pixel_height <= 0 {
		return .SDL_Failure
	}
	state.width_px = u32(pixel_width)
	state.height_px = u32(pixel_height)
	state.configuration = wgpu.SurfaceConfiguration{
		usage = {.RenderAttachment},
		width = state.width_px,
		height = state.height_px,
		presentMode = .Fifo,
	}

	_ = wgpu.InstanceRequestAdapter(state.instance, &wgpu.RequestAdapterOptions{
		compatibleSurface = state.surface,
		powerPreference = .HighPerformance,
		backendType = requested_backend,
	}, {
		mode = .AllowProcessEvents,
		callback = sdl3_webgpu_run_adapter_callback,
		userdata1 = rawptr(&state),
	})
	for !state.adapter_complete || (state.adapter != nil && !state.device_complete) {
		wgpu.InstanceProcessEvents(state.instance)
		if state.device != nil { _ = wgpu.DevicePoll(state.device, false) }
	if state.failed {
		fmt.eprintln("[alicorn-webgpu] adapter/device initialization failed", state.adapter_status, state.device_status)
		return .WebGPU_Failure
	}
		event: sdl3.Event
		if sdl3.WaitEventTimeout(&event, 10) {
			if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
				state.closing = true
			}
		}
	}
	if state.failed || state.adapter == nil || state.device == nil || state.queue == nil {
		return .WebGPU_Failure
	}
	if state.device_lost { return .Device_Lost }
	if info, info_status := wgpu.AdapterGetInfo(state.adapter); info_status == .Success {
		fmt.printf(
			"[alicorn-webgpu] adapter backend=%v type=%v vendor=%s architecture=%s device=%s description=%s\n",
			info.backendType,
			info.adapterType,
			info.vendor,
			info.architecture,
			info.device,
			info.description,
		)
		wgpu.AdapterInfoFreeMembers(info)
	} else {
		fmt.printf("[alicorn-webgpu] adapter details unavailable status=%v\n", info_status)
	}

	application: SDL3_WebGPU_Application
	if result := sdl3_webgpu_application_init(
		&application,
		hosted_config,
		window,
		state.surface,
		state.device,
		state.queue,
		state.configuration,
		clear_color,
	); result != .Ok {
		if result == .Runtime_Failure { return .Runtime_Failure }
		return .Presenter_Failure
	}
	defer sdl3_webgpu_run_destroy_application(&application, &state)
	if state.closing { return .Ok }
	if !sdl3.ShowWindow(window) { return .SDL_Failure }

	started_ns := u64(sdl3.GetTicksNS())
	did_present := false
	for {
		now_ns := u64(sdl3.GetTicksNS())
		step := sdl3_webgpu_application_step(&application, now_ns)
		if step.status != .Ok { return .Runtime_Failure }
		#partial switch step.presentation {
		case .Ok:
			did_present = true
		case .Invalid_Input, .Resource_Failure, .Render_Failure,
		     .Surface_Acquire_Failure, .Present_Failure:
			return .Presenter_Failure
		case .Suspended, .Retry_Later, .No_Frame, .Reconfigure_Required, .Hidden:
			// A minimized surface or temporary acquisition failure is retried
			// under the coordinator's bounded deadline.
		}

		if state.device_lost {
			fmt.eprintln("[alicorn-webgpu] WebGPU device lost", state.device_loss_reason)
			return .Device_Lost
		}
		if smoke && did_present && !sdl3_webgpu_application_has_in_flight(&application) {
			return .Ok
		}
		if smoke && now_ns-started_ns > 15_000_000_000 { return .Smoke_Timeout }

		event: sdl3.Event
		for sdl3.PollEvent(&event) {
			result := sdl3_webgpu_application_handle_event(&application, event)
			switch result {
			case .Close_Requested:
				return .Ok
			case .Failure:
				return .Event_Failure
			case .Ignored, .Handled, .Wake:
			}
		}

		in_flight := sdl3_webgpu_application_has_in_flight(&application)
		if in_flight {
			// wgpu-native delivers completion callbacks through explicit polling.
			// Poll only while presenter submissions are outstanding.
			_ = wgpu.DevicePoll(state.device, false)
			wgpu.InstanceProcessEvents(state.instance)
		}
		if state.device_lost { return .Device_Lost }

		timeout_ms := -1
		if step.has_more_work {
			timeout_ms = 0
		} else if step.next_wake_ns != 0 {
			if step.next_wake_ns <= now_ns {
				timeout_ms = 0
			} else {
				timeout_ms = int(min(u64(1000), (step.next_wake_ns-now_ns+999_999)/1_000_000))
			}
		}
		if in_flight && (timeout_ms < 0 || timeout_ms > 16) { timeout_ms = 16 }
		if timeout_ms == 0 { continue }
		if timeout_ms < 0 {
			_ = sdl3.WaitEvent(&event)
		} else if sdl3.WaitEventTimeout(&event, sdl3.Sint32(timeout_ms)) {
			result := sdl3_webgpu_application_handle_event(&application, event)
			switch result {
			case .Close_Requested:
				return .Ok
			case .Failure:
				return .Event_Failure
			case .Ignored, .Handled, .Wake:
			}
		}
	}
}
