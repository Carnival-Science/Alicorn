#+build !js

package sdl3_host

import "core:c"
import "core:fmt"
import "core:os"
import "core:sort"
import "core:strconv"
import "core:strings"
import "base:runtime"
import alicorn "alicorn:runtime"
import presentation_host "alicorn:host/presentation"
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

SDL3_WEBGPU_DEVICE_LOSS_POLL_INTERVAL_NS :: u64(250_000_000)
SDL3_WEBGPU_DEVICE_REQUEST_DIAGNOSTIC_NS :: u64(5_000_000_000)

SDL3_WebGPU_Run_State :: struct {
	instance: wgpu.Instance,
	surface: wgpu.Surface,
	adapter: wgpu.Adapter,
	device: wgpu.Device,
	queue: wgpu.Queue,
	configuration: wgpu.SurfaceConfiguration,
	recovery_policy: presentation_host.WebGPU_Recovery_Policy,
	requested_backend: wgpu.BackendType,
	application: ^SDL3_WebGPU_Application,
	windows: ^SDL3_WebGPU_Window_Manager,
	adapter_complete: bool,
	device_complete: bool,
	adapter_pending: bool,
	device_pending: bool,
	device_request_future: wgpu.Future,
	device_request_started_ns: u64,
	device_request_slow_reported: bool,
	device_lost_callback_pending: bool,
	failed: bool,
	closing: bool,
	device_lost: bool,
	device_loss_reported: bool,
	recovery_active: bool,
	recovery_draining: bool,
	recovery_terminal_failure: bool,
	last_now_ns: u64,
	adapter_status: wgpu.RequestAdapterStatus,
	device_status: wgpu.RequestDeviceStatus,
	device_loss_reason: wgpu.DeviceLostReason,
	width_px: u32,
	height_px: u32,
	next_wgpu_poll_ns: u64,
}

@(private)
sdl3_webgpu_run_adapter_callback :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	state := cast(^SDL3_WebGPU_Run_State)userdata1
	if state == nil { return }
	context = runtime.default_context()
	state.adapter_pending = false
	state.adapter_complete = true
	state.adapter_status = status
	if status != .Success || adapter == nil {
		fmt.printf("[alicorn-webgpu] adapter callback status=%v adapter_present=%v message=%s\n", status, adapter != nil, message)
		if adapter != nil { wgpu.AdapterRelease(adapter) }
		state.failed = true
		return
	}
	state.adapter = adapter
	if state.windows != nil { state.windows.adapter = adapter }

	caps, caps_status := wgpu.SurfaceGetCapabilities(state.surface, adapter)
	if caps_status != .Success || caps.formatCount == 0 || caps.alphaModeCount == 0 {
		fmt.printf("[alicorn-webgpu] surface capabilities failed status=%v formats=%d alpha_modes=%d\n",
			caps_status, caps.formatCount, caps.alphaModeCount)
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

	sdl3_webgpu_run_request_device(state)
}

@(private)
sdl3_webgpu_run_request_device :: proc(state: ^SDL3_WebGPU_Run_State) {
	if state == nil || state.adapter == nil { return }
	state.device_complete = false
	state.device_pending = true
	state.device_lost_callback_pending = true
	state.device_request_started_ns = u64(sdl3.GetTicksNS())
	state.device_request_slow_reported = false
	device_descriptor := wgpu.DeviceDescriptor{
		label = "Alicorn native WebGPU device",
		deviceLostCallbackInfo = {
			mode = .AllowProcessEvents,
			callback = sdl3_webgpu_run_device_lost_callback,
			userdata1 = rawptr(state),
		},
		uncapturedErrorCallbackInfo = {
			callback = sdl3_webgpu_run_uncaptured_error_callback,
			userdata1 = rawptr(state),
		},
	}
	fmt.println("[alicorn-webgpu] device request begin")
	state.device_request_future = wgpu.AdapterRequestDevice(state.adapter, &device_descriptor, {
		mode = .AllowProcessEvents,
		callback = sdl3_webgpu_run_device_callback,
		userdata1 = rawptr(state),
	})
	fmt.printf("[alicorn-webgpu] device request returned future=%d\n", state.device_request_future.id)
}

@(private)
sdl3_webgpu_run_request_adapter :: proc(state: ^SDL3_WebGPU_Run_State, recovery: bool) -> bool {
	if state == nil || state.instance == nil || state.surface == nil || state.adapter_pending || state.device_pending {
		return false
	}
	if recovery && !presentation_host.webgpu_recovery_attempt_begin(&state.recovery_policy, state.last_now_ns) {
		return false
	}
	state.failed = false
	state.adapter_complete = false
	state.device_complete = false
	state.adapter_pending = true
	_ = wgpu.InstanceRequestAdapter(state.instance, &wgpu.RequestAdapterOptions{
		compatibleSurface = state.surface,
		powerPreference = .HighPerformance,
		backendType = state.requested_backend,
	}, {
		mode = .AllowProcessEvents,
		callback = sdl3_webgpu_run_adapter_callback,
		userdata1 = rawptr(state),
	})
	return true
}

@(private)
sdl3_webgpu_run_device_callback :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	state := cast(^SDL3_WebGPU_Run_State)userdata1
	if state == nil { return }
	context = runtime.default_context()
	state.device_pending = false
	state.device_complete = true
	state.device_status = status
	fmt.printf("[alicorn-webgpu] device callback status=%v device_present=%v message=%s\n", status, device != nil, message)
	if status != .Success || device == nil {
		if device != nil {
			state.device = device
			state.recovery_terminal_failure = true
		} else {
			state.device_lost_callback_pending = false
		}
		state.failed = true
		return
	}
	state.device = device
	state.queue = wgpu.DeviceGetQueue(device)
	if state.queue == nil {
		state.failed = true
		state.recovery_terminal_failure = true
		return
	}
	state.configuration.device = device
	if state.windows != nil {
		state.windows.device = device
		state.windows.queue = state.queue
	}
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
	context = runtime.default_context()
	sdl3_webgpu_run_test_trace_loss(reason, _message)
	state.device_lost = true
	state.device_loss_reported = true
	state.device_loss_reason = reason
	state.device_lost_callback_pending = false
	if state.application != nil {
		sdl3_webgpu_application_mark_device_lost(state.application)
	}
	sdl3_webgpu_window_mark_device_lost(state.windows)
	if !presentation_host.webgpu_device_loss_should_recover(reason) {
		if !state.closing { state.recovery_terminal_failure = true }
		return
	}
	if !state.recovery_active {
		presentation_host.webgpu_recovery_begin(&state.recovery_policy, state.last_now_ns)
	}
	state.recovery_active = true
	state.recovery_draining = true
}

@(private)
sdl3_webgpu_run_uncaptured_error_callback :: proc "c" (
	_device: ^wgpu.Device,
	error_type: wgpu.ErrorType,
	message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	state := cast(^SDL3_WebGPU_Run_State)userdata1
	if state == nil { return }
	context = runtime.default_context()
	// The DeviceLost callback owns recovery. This callback replaces wgpu-native's
	// default panic handler while preserving an actionable diagnostic.
	fmt.printf("[alicorn-webgpu] uncaptured device error type=%v message=%s\n", error_type, message)
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
sdl3_webgpu_run_timing_requested :: proc() -> bool {
	for argument in os.args {
		if argument == "--timings" { return true }
	}
	return false
}

// sdl3_webgpu_run_smoke_hold_ns reads an optional idle hold for bounded smoke
// runs. When nonzero, --smoke exits only after the last presented frame has
// been idle for that long, so a benchmark can observe an idle window instead of
// stopping on the first presented frame.
@(private)
sdl3_webgpu_run_smoke_hold_ns :: proc() -> u64 {
	for argument in os.args {
		if !strings.has_prefix(argument, "--smoke-hold-ms=") { continue }
		value := strings.trim_prefix(argument, "--smoke-hold-ms=")
		milliseconds, ok := strconv.parse_u64(value)
		if !ok || milliseconds > 60_000 { return 0 }
		return milliseconds * 1_000_000
	}
	return 0
}

@(private)
sdl3_webgpu_run_loss_injection_requested :: proc() -> bool {
	for argument in os.args {
		if argument == "--test-simulate-unexpected-device-loss" { return true }
	}
	return false
}

@(private)
sdl3_webgpu_run_timing_percentiles :: proc(samples: []u64) -> (p50, p95, p99: u64) {
	if len(samples) == 0 { return }
	sort.quick_sort(samples)
	return samples[int(0.50*f64(len(samples)-1))],
		samples[int(0.95*f64(len(samples)-1))],
		samples[int(0.99*f64(len(samples)-1))]
}

@(private)
sdl3_webgpu_run_report_timing :: proc(application: ^SDL3_WebGPU_Application) {
	if application == nil { return }
	samples: [presentation_host.HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY]presentation_host.Hosted_Surface_Timing_Sample
	count := presentation_host.hosted_surface_presenter_take_timing_samples(
		&application.presenter, samples[:],
	)
	overwritten := presentation_host.hosted_surface_presenter_timing_overwritten(&application.presenter)
	runtime_step, acquire, encode, submit, present, step_to_present: [presentation_host.HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY]u64
	input_to_submit: [presentation_host.HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY]u64
	input_count := 0
	for i in 0..<count {
		sample := samples[i]
		runtime_step[i] = sample.runtime_step_ns
		acquire[i] = sample.surface_acquire_ns
		encode[i] = sample.renderer_encode_ns
		submit[i] = sample.queue_submit_ns
		present[i] = sample.surface_present_ns
		step_to_present[i] = sample.step_to_present_ns
		if sample.input_to_submit_ns != 0 {
			input_to_submit[input_count] = sample.input_to_submit_ns
			input_count += 1
		}
	}
	runtime_p50, runtime_p95, runtime_p99 := sdl3_webgpu_run_timing_percentiles(runtime_step[:count])
	acquire_p50, acquire_p95, acquire_p99 := sdl3_webgpu_run_timing_percentiles(acquire[:count])
	encode_p50, encode_p95, encode_p99 := sdl3_webgpu_run_timing_percentiles(encode[:count])
	submit_p50, submit_p95, submit_p99 := sdl3_webgpu_run_timing_percentiles(submit[:count])
	present_p50, present_p95, present_p99 := sdl3_webgpu_run_timing_percentiles(present[:count])
	whole_p50, whole_p95, whole_p99 := sdl3_webgpu_run_timing_percentiles(step_to_present[:count])
	input_p50, input_p95, input_p99 := sdl3_webgpu_run_timing_percentiles(input_to_submit[:input_count])
	fmt.printf("[alicorn-webgpu-timing] samples=%d overwritten=%d metric=CPU_wall_time_not_GPU_execution_or_scanout\n", count, overwritten)
	fmt.printf("[alicorn-webgpu-timing] runtime_step_ns_p50=%d runtime_step_ns_p95=%d runtime_step_ns_p99=%d surface_acquire_ns_p50=%d surface_acquire_ns_p95=%d surface_acquire_ns_p99=%d renderer_encode_ns_p50=%d renderer_encode_ns_p95=%d renderer_encode_ns_p99=%d\n",
		runtime_p50, runtime_p95, runtime_p99, acquire_p50, acquire_p95, acquire_p99,
		encode_p50, encode_p95, encode_p99)
	fmt.printf("[alicorn-webgpu-timing] queue_submit_ns_p50=%d queue_submit_ns_p95=%d queue_submit_ns_p99=%d surface_present_call_ns_p50=%d surface_present_call_ns_p95=%d surface_present_call_ns_p99=%d step_to_present_ns_p50=%d step_to_present_ns_p95=%d step_to_present_ns_p99=%d input_samples=%d input_to_submit_ns_p50=%d input_to_submit_ns_p95=%d input_to_submit_ns_p99=%d\n",
		submit_p50, submit_p95, submit_p99, present_p50, present_p95, present_p99,
		whole_p50, whole_p95, whole_p99, input_count, input_p50, input_p95, input_p99)
}

// sdl3_webgpu_run_report_workload prints retained-work counters and host loop
// activity once at exit. The renderer snapshot is read after the last
// submission, so it adds no work to the measured frame path.
@(private)
sdl3_webgpu_run_report_workload :: proc(
	application: ^SDL3_WebGPU_Application,
	presentations, wake_events, steps, no_frame_steps, zero_timeout_iterations: u64,
	idle_after_last_present_ns: u64,
) {
	if application == nil { return }
	fmt.printf(
		"[alicorn-webgpu-workload] frames_presented=%d wake_events=%d steps=%d no_frame_steps=%d zero_timeout_iterations=%d idle_after_last_present_ns=%d\n",
		presentations, wake_events, steps, no_frame_steps, zero_timeout_iterations,
		idle_after_last_present_ns,
	)
	stats, ok := presentation_host.hosted_surface_presenter_renderer_stats(&application.presenter)
	if !ok { return }
	fmt.printf(
		"[alicorn-webgpu-workload] prepared_commands=%d solid_mesh_rebuilds=%d solid_vertex_uploads=%d solid_vertex_upload_bytes=%d solid_transform_uploads=%d solid_transform_upload_bytes=%d solid_viewport_uploads=%d\n",
		stats.prepared_commands,
		stats.solid.mesh_rebuilds, stats.solid.vertex_uploads, stats.solid.vertex_upload_bytes,
		stats.solid.transform_uploads, stats.solid.transform_upload_bytes, stats.solid.viewport_uploads,
	)
	fmt.printf(
		"[alicorn-webgpu-workload] text_mesh_rebuilds=%d text_vertex_uploads=%d text_vertex_upload_bytes=%d text_transform_uploads=%d text_viewport_uploads=%d text_atlas_uploads=%d text_atlas_upload_bytes=%d\n",
		stats.text.mesh_rebuilds, stats.text.vertex_uploads, stats.text.vertex_upload_bytes,
		stats.text.transform_uploads, stats.text.viewport_uploads,
		stats.text.atlas_uploads, stats.text.atlas_upload_bytes,
	)
	fmt.printf(
		"[alicorn-webgpu-workload] icon_mesh_rebuilds=%d icon_mesh_cache_hits=%d icon_vertex_uploads=%d icon_vertex_upload_bytes=%d icon_atlas_uploads=%d icon_atlas_upload_bytes=%d image_mesh_rebuilds=%d image_vertex_uploads=%d image_texture_uploads=%d image_texture_upload_bytes=%d\n",
		stats.icons.mesh_rebuilds, stats.icons.mesh_cache_hits, stats.icons.vertex_uploads,
		stats.icons.vertex_upload_bytes, stats.icons.atlas_uploads, stats.icons.atlas_upload_bytes,
		stats.images.mesh_rebuilds, stats.images.vertex_uploads,
		stats.images.texture_uploads, stats.images.texture_upload_bytes,
	)
	fmt.printf(
		"[alicorn-webgpu-workload] surface_mesh_rebuilds=%d surface_mesh_cache_hits=%d surface_vertex_uploads=%d surface_vertex_upload_bytes=%d surface_instance_uploads=%d surface_instance_cache_hits=%d surface_viewport_uploads=%d\n",
		stats.surfaces.mesh_rebuilds, stats.surfaces.mesh_cache_hits,
		stats.surfaces.vertex_uploads, stats.surfaces.vertex_upload_bytes,
		stats.surfaces.instance_uploads, stats.surfaces.instance_cache_hits,
		stats.surfaces.viewport_uploads,
	)
}

@(private)
sdl3_webgpu_run_dispatch_event :: proc(
	application: ^SDL3_WebGPU_Application,
	event: sdl3.Event,
) -> SDL3_WebGPU_Application_Event_Result {
	if application == nil { return .Failure }
	input_event := false
	#partial switch event.type {
	case .KEY_DOWN, .TEXT_INPUT, .TEXT_EDITING, .MOUSE_MOTION,
	     .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_WHEEL:
		input_event = true
	case:
	}
	result := sdl3_webgpu_application_handle_event(application, event)
	if input_event && result == .Handled {
		presentation_host.hosted_surface_presenter_note_input(&application.presenter)
	}
	return result
}

@(private)
sdl3_webgpu_run_release_state :: proc(state: ^SDL3_WebGPU_Run_State) {
	if state == nil { return }
	state.closing = true
	if state.surface != nil {
		wgpu.SurfaceUnconfigure(state.surface)
		wgpu.SurfaceRelease(state.surface)
		state.surface = nil
	}
	sdl3_webgpu_run_release_device_handles(state, !state.device_lost)
	if state.instance != nil {
		wgpu.InstanceRelease(state.instance)
		state.instance = nil
	}
}

@(private)
sdl3_webgpu_run_destroy_windows :: proc(data: rawptr) {
	state := cast(^SDL3_WebGPU_Run_State)data
	if state == nil || state.windows == nil { return }
	sdl3_webgpu_window_manager_destroy(
		state.windows, state.instance, state.device, state.device_lost,
	)
}

@(private)
sdl3_webgpu_run_release_device_handles :: proc(state: ^SDL3_WebGPU_Run_State, destroy_device: bool) {
	if state == nil { return }
	if state.queue != nil {
		wgpu.QueueRelease(state.queue)
		state.queue = nil
	}
	if state.device != nil {
		if destroy_device && !state.device_lost { wgpu.DeviceDestroy(state.device) }
		if !state.device_lost {
			_ = wgpu.DevicePoll(state.device, true)
			if state.instance != nil { wgpu.InstanceProcessEvents(state.instance) }
		}
		wgpu.DeviceRelease(state.device)
		state.device = nil
	}
	if state.adapter != nil {
		wgpu.AdapterRelease(state.adapter)
		state.adapter = nil
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

@(private)
sdl3_webgpu_run_recovery_step :: proc(
	state: ^SDL3_WebGPU_Run_State,
	application: ^SDL3_WebGPU_Application,
	now_ns: u64,
) -> bool {
	if state == nil || !state.recovery_active { return false }
	state.last_now_ns = now_ns
	if state.recovery_terminal_failure { return true }

	if state.recovery_draining {
		// Do not retire the old device or start another request while a bootstrap
		// callback or submitted-frame completion still refers to the old state.
		if state.adapter_pending || state.device_pending { return false }
		if application != nil && application.initialized && application.presenter_device_lost &&
		   !sdl3_webgpu_application_detach_lost_presenter(application) {
			return false
		}
		if !sdl3_webgpu_window_detach_lost_presenter(state.windows) { return false }
		// Surface configurations are device-bound. Recreate native WebGPU
		// surfaces as well as presenters so a replacement device cannot acquire
		// a stale swapchain texture owned by the lost device.
		if state.surface != nil {
			wgpu.SurfaceUnconfigure(state.surface)
			wgpu.SurfaceRelease(state.surface)
			state.surface = nil
		}
		if state.windows == nil || state.windows.primary_window == nil || state.instance == nil {
			state.recovery_terminal_failure = true
			return true
		}
		state.surface = sdl3glue.GetSurface(state.instance, state.windows.primary_window)
		if state.surface == nil || !sdl3_webgpu_window_recreate_surface_after_device_loss(state.windows) {
			state.recovery_terminal_failure = true
			return true
		}
		sdl3_webgpu_run_release_device_handles(state, false)
		state.device_lost = false
		state.device_loss_reason = {}
		state.recovery_draining = false
		if state.recovery_policy.attempt_pending {
			if !presentation_host.webgpu_recovery_attempt_failed(&state.recovery_policy, now_ns) {
				state.recovery_active = false
				return true
			}
		} else {
			state.recovery_policy.retry_at_ns = now_ns
		}
	}

	if state.failed {
		if state.recovery_terminal_failure { return true }
		sdl3_webgpu_run_release_device_handles(state, !state.device_lost)
		state.failed = false
		if !presentation_host.webgpu_recovery_attempt_failed(&state.recovery_policy, now_ns) {
			state.recovery_active = false
			return true
		}
		return false
	}

	if state.device != nil && state.queue != nil && !state.adapter_pending && !state.device_pending {
		if state.device_lost {
			state.recovery_draining = true
			return false
		}
		if application == nil || !application.initialized {
			state.recovery_terminal_failure = true
			return true
		}
		if result := sdl3_webgpu_application_attach_presenter(
			application,
			state.surface,
			state.device,
			state.queue,
			state.configuration,
		); result != .Ok {
			fmt.eprintln("[alicorn-webgpu] presenter reattach failed", result)
			state.recovery_terminal_failure = true
			return true
		}
		if state.windows != nil {
			state.windows.device = state.device
			state.windows.queue = state.queue
			if !sdl3_webgpu_window_attach_presenter(state.windows, state.configuration) {
				fmt.eprintln("[alicorn-webgpu] secondary presenter reattach failed")
				state.recovery_terminal_failure = true
				return true
			}
		}
		state.recovery_active = false
		state.device_lost = false
		presentation_host.webgpu_recovery_succeed(&state.recovery_policy)
		sdl3_webgpu_run_test_trace("replacement device and presenters reattached")
		fmt.println("[alicorn-webgpu] WebGPU device recovered; retained application state preserved")
		return false
	}

	if presentation_host.webgpu_recovery_attempt_due(&state.recovery_policy, now_ns) {
		if !sdl3_webgpu_run_request_adapter(state, true) {
			state.recovery_terminal_failure = true
			return true
		}
		fmt.printf("[alicorn-webgpu] recovery attempt %d/%d started\n",
			state.recovery_policy.attempts,
			presentation_host.WEBGPU_RECOVERY_MAX_ATTEMPTS,
		)
	}
	return false
}

@(private)
sdl3_webgpu_run_request_quit :: proc(data: rawptr) {
	if data != nil { (cast(^bool)data)^ = true }
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
	if !sdl3_webgpu_prepare_accessibility_platform() { return .SDL_Failure }

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

	quit_requested := false
	state: SDL3_WebGPU_Run_State
	defer sdl3_webgpu_run_release_state(&state)
	window_manager: SDL3_WebGPU_Window_Manager
	window_manager.primary_window = window
	state.windows = &window_manager
	state.instance = wgpu.CreateInstance(nil)
	if state.instance == nil { return .WebGPU_Failure }
	window_manager.instance = state.instance
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
	state.requested_backend = requested_backend
	state.last_now_ns = u64(sdl3.GetTicksNS())
	if !sdl3_webgpu_run_request_adapter(&state, false) { return .WebGPU_Failure }
	for !state.adapter_complete || (state.adapter != nil && !state.device_complete) {
		wgpu.InstanceProcessEvents(state.instance)
		if state.device != nil { _ = wgpu.DevicePoll(state.device, false) }
		if state.device_pending && !state.device_request_slow_reported {
			elapsed_ns := u64(sdl3.GetTicksNS()) - state.device_request_started_ns
			if elapsed_ns >= SDL3_WEBGPU_DEVICE_REQUEST_DIAGNOSTIC_NS {
				fmt.printf("[alicorn-webgpu] device request still pending elapsed_ms=%d future=%d; continuing event processing\n",
					elapsed_ns / 1_000_000, state.device_request_future.id)
				state.device_request_slow_reported = true
			}
		}
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
	application_config := hosted_config
	application_config.host_services.windows = sdl3_webgpu_window_service(&window_manager)
	application_config.host_services.quit = alicorn.Hosted_Quit_Service{
		data=rawptr(&quit_requested),
		request=sdl3_webgpu_run_request_quit,
	}
	if result := sdl3_webgpu_application_init(
		&application,
		application_config,
		window,
		state.surface,
		state.device,
		state.queue,
		state.configuration,
		clear_color,
	); result != .Ok {
		sdl3_webgpu_window_manager_destroy(
			&window_manager, state.instance, state.device, state.device_lost,
		)
		if result == .Runtime_Failure { return .Runtime_Failure }
		return .Presenter_Failure
	}
	state.application = &application
	defer sdl3_webgpu_run_destroy_application(&application, &state)
	defer sdl3_webgpu_run_destroy_windows(rawptr(&state))
	timing_enabled := sdl3_webgpu_run_timing_requested()
	smoke_hold_ns := sdl3_webgpu_run_smoke_hold_ns()
	if timing_enabled {
		if !presentation_host.hosted_surface_presenter_set_timing_enabled(&application.presenter, true) {
			return .Presenter_Failure
		}
	}
	presentations: u64 = 0
	wake_events: u64 = 0
	steps: u64 = 0
	no_frame_steps: u64 = 0
	zero_timeout_iterations: u64 = 0
	last_present_ns: u64 = 0
	defer {
		if timing_enabled {
			exit_ns := u64(sdl3.GetTicksNS())
			idle_ns: u64
			if last_present_ns != 0 && exit_ns >= last_present_ns {
				idle_ns = exit_ns-last_present_ns
			}
			sdl3_webgpu_run_report_workload(
				&application, presentations, wake_events, steps, no_frame_steps,
				zero_timeout_iterations, idle_ns,
			)
		}
	}
	defer {
		if timing_enabled { sdl3_webgpu_run_report_timing(&application) }
	}
	if state.closing { return .Ok }
	if !sdl3.ShowWindow(window) { return .SDL_Failure }

	started_ns := u64(sdl3.GetTicksNS())
	did_present := false
	child_did_present := false
	inject_loss_after_present := sdl3_webgpu_run_loss_injection_requested()
	remove_d3d12_device_after_present := sdl3_webgpu_run_d3d12_removal_requested()
	expect_post_recovery_present := false
	for !quit_requested {
		now_ns := u64(sdl3.GetTicksNS())
		state.last_now_ns = now_ns
		if window_manager.pending && !state.device_lost && !state.recovery_active {
			if !sdl3_webgpu_window_create_pending(
				&window_manager, state.configuration, clear_color,
			) {
				fmt.eprintln("[alicorn-webgpu] secondary window setup failed")
			}
		}
		if window_manager.pending_close && window_manager.child != nil {
			_ = sdl3_webgpu_window_destroy(&window_manager)
		}
		if window_manager.child == nil { child_did_present = false }
		if state.device_lost && !state.recovery_active {
			fmt.eprintln("[alicorn-webgpu] WebGPU device lost without recovery", state.device_loss_reason)
			return .Device_Lost
		}
		if state.recovery_active && sdl3_webgpu_run_recovery_step(&state, &application, now_ns) {
			fmt.eprintln("[alicorn-webgpu] WebGPU device recovery failed")
			return .Device_Lost
		}
		step := sdl3_webgpu_application_step(&application, now_ns)
		if step.status != .Ok { return .Runtime_Failure }
		steps += 1
		if step.presentation == .No_Frame { no_frame_steps += 1 }
		child_step: SDL3_WebGPU_Application_Step
		child_stepped := window_manager.child != nil && !window_manager.pending_close
		if child_stepped {
			child_step = sdl3_webgpu_application_step(&window_manager.child.application, now_ns)
			if child_step.status != .Ok { return .Runtime_Failure }
			#partial switch child_step.presentation {
			case .Ok:
				child_did_present = true
			case .Invalid_Input, .Resource_Failure, .Render_Failure,
			     .Surface_Acquire_Failure, .Present_Failure:
				// A loss discovered inside the child step owns recovery; do not
				// turn the expected presentation fallout into a host failure.
				if !(state.device_lost && state.recovery_active) { return .Presenter_Failure }
			case .Suspended, .Retry_Later, .No_Frame, .Reconfigure_Required, .Hidden:
			}
		}
		sdl3_webgpu_application_dispatch_dialogs(&application)
		sdl3_webgpu_application_dispatch_menus(&application)
		if window_manager.child != nil {
			sdl3_webgpu_application_dispatch_dialogs(&window_manager.child.application)
			sdl3_webgpu_application_dispatch_menus(&window_manager.child.application)
		}
		if quit_requested { return .Ok }
		if window_manager.child != nil && window_manager.child.quit_requested {
			window_manager.pending_close = true
		}
		#partial switch step.presentation {
		case .Ok:
			did_present = true
			presentations += 1
			last_present_ns = now_ns
			if expect_post_recovery_present {
				expect_post_recovery_present = false
				sdl3_webgpu_run_test_trace("post-recovery frame presented")
			}
			if inject_loss_after_present {
				inject_loss_after_present = false
				did_present = false
				child_did_present = false
				fmt.println(
					"[alicorn-webgpu] test injection: simulating an unexpected Unknown device-loss callback; not hardware-loss evidence",
				)
				sdl3_webgpu_run_device_lost_callback(
					&state.device,
					.Unknown,
					{},
					rawptr(&state),
					nil,
				)
			}
			if remove_d3d12_device_after_present {
				remove_d3d12_device_after_present = false
				did_present = false
				child_did_present = false
				expect_post_recovery_present = true
				fmt.println(
					"[alicorn-webgpu] test injection: removing the live D3D12 backend device with ID3D12Device5::RemoveDevice; harness-induced backend removal, not an OS or driver-initiated loss",
				)
				sdl3_webgpu_run_test_mark_removal_request()
				if !sdl3_webgpu_run_remove_d3d12_device_for_testing(&state) {
					fmt.eprintln("[alicorn-webgpu] test injection: backend device removal failed")
					return .Device_Lost
				}
			}
		case .Invalid_Input, .Resource_Failure, .Render_Failure,
		     .Surface_Acquire_Failure, .Present_Failure:
			// Likewise for the primary presenter: if the backend loss surfaced
			// during this step, recovery (not the host loop) owns the outcome.
			if !(state.device_lost && state.recovery_active) { return .Presenter_Failure }
		case .Suspended, .Retry_Later, .No_Frame, .Reconfigure_Required, .Hidden:
			// A minimized surface or temporary acquisition failure is retried
			// under the coordinator's bounded deadline.
		}

		child_smoke_complete := window_manager.child == nil || (
			child_did_present && !sdl3_webgpu_window_has_in_flight(&window_manager)
		)
		smoke_hold_complete := smoke_hold_ns == 0 || (
			last_present_ns != 0 && now_ns >= last_present_ns && now_ns-last_present_ns >= smoke_hold_ns
		)
		if smoke && !state.recovery_active && !state.device_lost && did_present && child_smoke_complete &&
		   smoke_hold_complete && !sdl3_webgpu_application_has_in_flight(&application) {
			return .Ok
		}
		if smoke && now_ns-started_ns > 15_000_000_000 { return .Smoke_Timeout }

		event: sdl3.Event
		for sdl3.PollEvent(&event) {
			result := sdl3_webgpu_run_dispatch_event(&application, event)
			switch result {
			case .Close_Requested:
				return .Ok
			case .Close_Deferred, .Ignored, .Handled:
			case .Failure:
				return .Event_Failure
			case .Wake:
				wake_events += 1
			}
			if window_manager.child != nil {
				child_result := sdl3_webgpu_run_dispatch_event(&window_manager.child.application, event)
				switch child_result {
				case .Close_Requested:
					window_manager.pending_close = true
				case .Close_Deferred, .Ignored, .Handled:
				case .Failure:
					return .Event_Failure
				case .Wake:
					wake_events += 1
				}
			}
		}

		if window_manager.pending_close && window_manager.child != nil {
			_ = sdl3_webgpu_window_destroy(&window_manager)
		}
		in_flight := sdl3_webgpu_application_has_in_flight(&application) ||
			sdl3_webgpu_window_has_in_flight(&window_manager)
		next_wake_ns := step.next_wake_ns
		if child_stepped && child_step.next_wake_ns != 0 &&
		   (next_wake_ns == 0 || child_step.next_wake_ns < next_wake_ns) {
			next_wake_ns = child_step.next_wake_ns
		}
		maintenance_due := state.device_lost_callback_pending && now_ns >= state.next_wgpu_poll_ns
		if in_flight || state.adapter_pending || state.device_pending || maintenance_due {
			// Native completion and loss callbacks require explicit maintenance.
			// Keep queue polling tied to submissions; a bounded low-frequency wake
			// observes driver loss while an otherwise idle window is waiting.
			if state.device != nil { _ = wgpu.DevicePoll(state.device, false) }
			wgpu.InstanceProcessEvents(state.instance)
			if state.device_lost_callback_pending {
				state.next_wgpu_poll_ns = now_ns + SDL3_WEBGPU_DEVICE_LOSS_POLL_INTERVAL_NS
			}
		}
		if state.recovery_active && sdl3_webgpu_run_recovery_step(&state, &application, now_ns) {
			fmt.eprintln("[alicorn-webgpu] WebGPU device recovery failed")
			return .Device_Lost
		}
		if state.device_lost && !state.recovery_active { return .Device_Lost }

		timeout_ms := -1
		if state.recovery_active && !state.recovery_draining &&
		   !state.adapter_pending && !state.device_pending {
			if state.recovery_policy.retry_at_ns <= now_ns {
				timeout_ms = 0
			} else {
				timeout_ms = int(min(u64(1000), (state.recovery_policy.retry_at_ns-now_ns+999_999)/1_000_000))
			}
		} else if step.has_more_work || (child_stepped && child_step.has_more_work) {
			timeout_ms = 0
		} else if next_wake_ns != 0 {
			if next_wake_ns <= now_ns {
				timeout_ms = 0
			} else {
				timeout_ms = int(min(u64(1000), (next_wake_ns-now_ns+999_999)/1_000_000))
			}
		}
		if in_flight && (timeout_ms < 0 || timeout_ms > 16) { timeout_ms = 16 }
		if state.adapter_pending || state.device_pending {
			if timeout_ms < 0 || timeout_ms > 16 { timeout_ms = 16 }
		}
		if state.device_lost_callback_pending {
			until_poll := u64(0)
			if state.next_wgpu_poll_ns > now_ns { until_poll = state.next_wgpu_poll_ns - now_ns }
			poll_timeout := int(min(u64(1000), (until_poll+999_999)/1_000_000))
			if timeout_ms < 0 || poll_timeout < timeout_ms { timeout_ms = poll_timeout }
		}
		if smoke && smoke_hold_ns > 0 && last_present_ns != 0 && now_ns >= last_present_ns {
			remaining := smoke_hold_ns-(now_ns-last_present_ns)
			hold_timeout := int(min(u64(1000), (remaining+999_999)/1_000_000))
			if timeout_ms < 0 || hold_timeout < timeout_ms { timeout_ms = hold_timeout }
		}
		if timeout_ms == 0 { zero_timeout_iterations += 1; continue }
		if timeout_ms < 0 {
			_ = sdl3.WaitEvent(&event)
		} else if sdl3.WaitEventTimeout(&event, sdl3.Sint32(timeout_ms)) {
			result := sdl3_webgpu_run_dispatch_event(&application, event)
			switch result {
			case .Close_Requested:
				return .Ok
			case .Close_Deferred, .Ignored, .Handled:
			case .Failure:
				return .Event_Failure
			case .Wake:
				wake_events += 1
			}
			if window_manager.child != nil {
			child_result := sdl3_webgpu_run_dispatch_event(&window_manager.child.application, event)
				switch child_result {
				case .Close_Requested:
					window_manager.pending_close = true
				case .Close_Deferred, .Ignored, .Handled:
				case .Failure:
					return .Event_Failure
				case .Wake:
					wake_events += 1
				}
			}
		}
	}
	return .Ok
}
