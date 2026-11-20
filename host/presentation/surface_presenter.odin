package presentation_host

import "core:mem"
import "base:runtime"
import "core:fmt"
import "core:time"
import alicorn "alicorn:runtime"
import "vendor:wgpu"
import webgpu_renderer "alicorn:renderer/webgpu"

HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY :: 256

// Timings cover CPU wall time in the host/presenter path. They do not measure
// GPU execution, display scanout, or photon-visible latency.
Hosted_Surface_Timing_Sample :: struct {
	display_revision: u64,
	submission_serial: u64,
	runtime_step_ns: u64,
	surface_acquire_ns: u64,
	renderer_encode_ns: u64,
	queue_submit_ns: u64,
	surface_present_ns: u64,
	step_to_present_ns: u64,
	input_to_submit_ns: u64,
}

@(private)
hosted_surface_timing_buffer :: struct {
	samples: [HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY]Hosted_Surface_Timing_Sample,
	first: int,
	count: int,
	overwritten: u64,
	pending_input_since: time.Tick,
	pending_input_revision: u64,
	pending_input: bool,
}

@(private)
hosted_surface_timing_elapsed_ns :: proc(start: time.Tick) -> u64 {
	ns := time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))
	if ns <= 0 { return 0 }
	return u64(ns)
}

@(private)
hosted_surface_timing_record :: proc(buffer: ^hosted_surface_timing_buffer, sample: Hosted_Surface_Timing_Sample) {
	if buffer == nil { return }
	if buffer.count < HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY {
		index := (buffer.first + buffer.count) % HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY
		buffer.samples[index] = sample
		buffer.count += 1
		return
	}
	buffer.samples[buffer.first] = sample
	buffer.first = (buffer.first + 1) % HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY
	buffer.overwritten += 1
}

@(private)
hosted_surface_timing_take :: proc(
	buffer: ^hosted_surface_timing_buffer,
	output: []Hosted_Surface_Timing_Sample,
) -> int {
	if buffer == nil || len(output) == 0 { return 0 }
	taken := min(buffer.count, len(output))
	for i in 0..<taken {
		index := (buffer.first + i) % HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY
		output[i] = buffer.samples[index]
	}
	buffer.first = (buffer.first + taken) % HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY
	buffer.count -= taken
	return taken
}

Hosted_Surface_Result :: enum {
	Ok,
	No_Frame,
	Suspended,
	Retry_Later,
	Reconfigure_Required,
	Hidden,
	Invalid_Input,
	Resource_Failure,
	Render_Failure,
	Surface_Acquire_Failure,
	Present_Failure,
}

Hosted_Surface_Wake_Proc :: proc(data: rawptr)
// Hosted_Surface_Pre_Present_Proc runs on the owner thread after the Runtime
// step and before frame encoding. Hosts use it to refresh host-owned chrome
// geometry/paint against the freshly described tree in the same frame.
Hosted_Surface_Pre_Present_Proc :: proc(data: rawptr)

// Hosted_Surface_Presenter binds one Hosted_Runtime to a host-created WebGPU
// surface. The embedding host still owns adapter/device/queue/surface creation,
// platform sizing, and demand scheduling. It must keep this value, Runtime, and
// WGPU objects alive until destroy returns true. All methods run on the platform's
// owner thread; queue completion is delivered asynchronously by WebGPU.
Hosted_Surface_Presenter :: struct {
	state: rawptr,
}

@(private)
hosted_surface_presenter_state :: struct {
	allocator: mem.Allocator,
	hosted: ^alicorn.Hosted_Runtime,
	runtime: ^alicorn.Runtime,
	device: wgpu.Device,
	queue: wgpu.Queue,
	surface: wgpu.Surface,
	configuration: wgpu.SurfaceConfiguration,
	renderer: webgpu_renderer.WebGPU_Presenter,
	logical_width, logical_height: int,
	scale_x, scale_y: f32,
	visible: bool,
	drawable: bool,
	clear_color: wgpu.Color,
	wake_data: rawptr,
	wake: Hosted_Surface_Wake_Proc,
	pending_completions: u64,
	completion_failed: bool,
	presentation_failed: bool,
	device_lost: bool,
	timing_enabled: bool,
	timing: ^hosted_surface_timing_buffer,
	// overlay_redraw requests one host-owned overlay frame (diagnostics HUD or
	// retained-bounds inspection) without mutating the application Runtime or
	// acknowledging a new application presentation.
	overlay_redraw: bool,
	// fail_next_encode is a host test seam: the next presentation attempt
	// reports Render_Failure before encoding so the diagnostics failure-capture
	// path can be validated against a real host-loop failure branch.
	fail_next_encode: bool,
}

@(private)
hosted_surface_completion :: struct {
	allocator: mem.Allocator,
	state: ^hosted_surface_presenter_state,
	submission: webgpu_renderer.WebGPU_Submission,
}

@(private)
hosted_surface_state :: proc(presenter: ^Hosted_Surface_Presenter) -> ^hosted_surface_presenter_state {
	if presenter == nil || presenter.state == nil { return nil }
	return cast(^hosted_surface_presenter_state)presenter.state
}

// Initialize presentation for a WebGPU surface already created by the host.
// The supplied format, present mode, and alpha mode must come from that
// surface's capabilities. Configuration usage is narrowed to render output.
hosted_surface_presenter_init :: proc(
	presenter: ^Hosted_Surface_Presenter,
	hosted: ^alicorn.Hosted_Runtime,
	surface: wgpu.Surface,
	device: wgpu.Device,
	queue: wgpu.Queue,
	configuration: wgpu.SurfaceConfiguration,
	logical_width, logical_height: int,
	dpi_scale: f32,
	wake_data: rawptr,
	wake: Hosted_Surface_Wake_Proc,
	clear_color: wgpu.Color = {0.04, 0.06, 0.08, 1},
) -> Hosted_Surface_Result {
	if presenter == nil || presenter.state != nil || hosted == nil || surface == nil ||
	   device == nil || queue == nil || wake == nil || logical_width <= 0 || logical_height <= 0 ||
	   configuration.width == 0 || configuration.height == 0 || configuration.format == .Undefined {
		return .Invalid_Input
	}
	runtime, borrow_status := alicorn.hosted_runtime_borrow(hosted)
	if borrow_status != .Ok || runtime == nil { return .Invalid_Input }
	state := new(hosted_surface_presenter_state, allocator=context.allocator)
	if state == nil { return .Resource_Failure }
	state.allocator = context.allocator
	state.hosted, state.runtime = hosted, runtime
	state.device, state.queue, state.surface = device, queue, surface
	state.configuration = configuration
	state.configuration.device = device
	state.configuration.usage = {.RenderAttachment}
	state.configuration.width = configuration.width
	state.configuration.height = configuration.height
	state.logical_width, state.logical_height = logical_width, logical_height
	state.scale_x = f32(configuration.width) / f32(logical_width)
	state.scale_y = f32(configuration.height) / f32(logical_height)
	state.visible, state.drawable = true, true
	state.clear_color = clear_color
	state.wake_data, state.wake = wake_data, wake
	renderer, renderer_ok := webgpu_renderer.WebGPU_Presenter_Create(
		device, queue, configuration.format, runtime,
	)
	if !renderer_ok {
		free(state, allocator=state.allocator)
		return .Resource_Failure
	}
	state.renderer = renderer
	if status := alicorn.hosted_runtime_resize(
		hosted, logical_width, logical_height,
		int(configuration.width), int(configuration.height), dpi_scale,
	); status != .Ok {
		_ = webgpu_renderer.WebGPU_Presenter_Destroy(&state.renderer)
		free(state, allocator=state.allocator)
		return .Invalid_Input
	}
	wgpu.SurfaceConfigure(surface, &state.configuration)
	presenter.state = rawptr(state)
	if status := alicorn.hosted_runtime_request_presentation(hosted, "WebGPU presenter attached"); status != .Ok {
		_ = hosted_surface_presenter_destroy(presenter)
		return .Invalid_Input
	}
	return .Ok
}

// Resize the retained Runtime and configure the surface as one owner-thread
// operation. A zero drawable size suspends presentation without configuring an
// invalid 0x0 WebGPU surface; restoring a nonzero size schedules the Runtime's
// retained display through hosted_runtime_resize and wakes the host scheduler.
hosted_surface_presenter_resize :: proc(
	presenter: ^Hosted_Surface_Presenter,
	logical_width, logical_height, pixel_width, pixel_height: int,
	dpi_scale: f32,
) -> Hosted_Surface_Result {
	state := hosted_surface_state(presenter)
	if state == nil || logical_width < 0 || logical_height < 0 || pixel_width < 0 || pixel_height < 0 {
		return .Invalid_Input
	}
	if status := alicorn.hosted_runtime_resize(
		state.hosted, logical_width, logical_height, pixel_width, pixel_height, dpi_scale,
	); status != .Ok {
		return .Invalid_Input
	}
	state.logical_width, state.logical_height = logical_width, logical_height
	if pixel_width == 0 || pixel_height == 0 || logical_width == 0 || logical_height == 0 {
		state.drawable = false
		if status := alicorn.hosted_runtime_set_renderable(state.hosted, false); status != .Ok {
			return .Invalid_Input
		}
		return .Suspended
	}
	state.drawable = true
	state.configuration.width = u32(pixel_width)
	state.configuration.height = u32(pixel_height)
	state.scale_x = f32(pixel_width) / f32(logical_width)
	state.scale_y = f32(pixel_height) / f32(logical_height)
	// A resize racing a backend removal must not configure a surface against
	// the lost parent device; recovery recreates the surface instead.
	if state.device_lost { return .Ok }
	wgpu.SurfaceConfigure(state.surface, &state.configuration)
	if status := alicorn.hosted_runtime_set_renderable(state.hosted, state.visible); status != .Ok {
		return .Invalid_Input
	}
	if state.visible && state.wake != nil { state.wake(state.wake_data) }
	return .Ok
}

// Suspend or resume retained presentation when the host's visibility changes.
// Drawable size and visibility are tracked independently so a resize while
// hidden cannot accidentally re-enable frame scheduling.
hosted_surface_presenter_set_visible :: proc(
	presenter: ^Hosted_Surface_Presenter,
	visible: bool,
) -> Hosted_Surface_Result {
	state := hosted_surface_state(presenter)
	if state == nil { return .Invalid_Input }
	if state.visible == visible { return .Ok }
	state.visible = visible
	if status := alicorn.hosted_runtime_set_renderable(
		state.hosted, state.visible && state.drawable,
	); status != .Ok {
		return .Invalid_Input
	}
	if visible && state.drawable && state.wake != nil { state.wake(state.wake_data) }
	return .Ok
}

// Host callback adapter for visibility changes. Pass a stable presenter
// pointer as callback data when a host coordinates visibility and scheduling.
hosted_surface_visibility_changed :: proc(data: rawptr, visible: bool) {
	presenter := cast(^Hosted_Surface_Presenter)data
	_ = hosted_surface_presenter_set_visible(presenter, visible)
}

// hosted_surface_presenter_request_overlay_redraw asks the next step to
// composite the current retained display plus host overlays even when the
// application has no pending presentation. It never mutates the Runtime, so a
// HUD-only redraw cannot look like application work in counters or captures.
hosted_surface_presenter_request_overlay_redraw :: proc(presenter: ^Hosted_Surface_Presenter) {
	state := hosted_surface_state(presenter)
	if state == nil || state.device_lost { return }
	state.overlay_redraw = true
	if state.wake != nil { state.wake(state.wake_data) }
}

hosted_surface_presenter_overlay_redraw_pending :: proc(presenter: ^Hosted_Surface_Presenter) -> bool {
	state := hosted_surface_state(presenter)
	return state != nil && state.overlay_redraw
}

// hosted_surface_presenter_fail_next_encode_for_test injects one deterministic
// encode failure at the presentation boundary. It exists so a host can prove
// that diagnostics capture still produces its bundle when presentation fails.
hosted_surface_presenter_fail_next_encode_for_test :: proc(presenter: ^Hosted_Surface_Presenter) {
	state := hosted_surface_state(presenter)
	if state != nil { state.fail_next_encode = true }
}

// Step once after a bounded input batch or scheduled wake. At most one Runtime
// description and one surface submission are performed. The host scheduler
// should use step.next_wake_ns, keep running when has_more_work is true, wait
// for Hosted_Surface_Wake_Proc after asynchronous queue completion, and retry
// Retry_Later with a bounded timer rather than a busy loop.
hosted_surface_presenter_step :: proc(
	presenter: ^Hosted_Surface_Presenter,
	now_ns: u64,
) -> (step: alicorn.Hosted_Step_Result, presentation: Hosted_Surface_Result) {
	return hosted_surface_presenter_step_with_hook(presenter, now_ns, nil, nil)
}

// hosted_surface_presenter_step_with_hook is step plus a pre-present callback.
// The hook runs before encoding so hosted chrome (menu labels, caption state,
// app-declared hit regions) reflects the current description. It may request a
// presentation; render_required is re-evaluated after it returns.
hosted_surface_presenter_step_with_hook :: proc(
	presenter: ^Hosted_Surface_Presenter,
	now_ns: u64,
	hook_data: rawptr,
	hook: Hosted_Surface_Pre_Present_Proc,
) -> (step: alicorn.Hosted_Step_Result, presentation: Hosted_Surface_Result) {
	state := hosted_surface_state(presenter)
	if state == nil { return alicorn.Hosted_Step_Result{status=.Closed}, .Invalid_Input }
	timing_start: time.Tick
	if state.timing_enabled { timing_start = time.tick_now() }
	step = alicorn.hosted_runtime_step(state.hosted, now_ns)
	if step.status != .Ok { return step, .Invalid_Input }
	if hook != nil {
		hook(hook_data)
	}
	app_frame_required := alicorn.frame_needs_submission(state.runtime)
	step.render_required = state.visible && state.drawable && (app_frame_required || state.overlay_redraw)
	if state.overlay_redraw && !app_frame_required {
		// The application has no pending presentation. This frame exists only to
		// composite host overlays, so it must not advertise application work.
		step.has_more_work = false
	}
	if !step.render_required {
		// An input event that produced no requested presentation has no visible
		// response to time. Do not carry its marker into an unrelated later frame.
		if state.timing != nil { state.timing.pending_input = false }
		return step, .No_Frame
	}
	if state.timing != nil && state.timing.pending_input &&
	   state.timing.pending_input_revision == state.runtime.presentation_revision {
		// The Runtime did submit work, but the input did not change the retained
		// presentation. Keep unrelated animation or maintenance frames out of the
		// input-to-submit distribution.
		state.timing.pending_input = false
	}
	timing_sample: Hosted_Surface_Timing_Sample
	if state.timing_enabled {
		timing_sample.runtime_step_ns = hosted_surface_timing_elapsed_ns(timing_start)
	}
	presentation = hosted_surface_present_pending(presenter, &timing_sample)
	if presentation == .Ok || presentation == .No_Frame { state.overlay_redraw = false }
	if state.timing_enabled && timing_sample.submission_serial != 0 {
		timing_sample.step_to_present_ns = hosted_surface_timing_elapsed_ns(timing_start)
		hosted_surface_timing_record(state.timing, timing_sample)
	}
	return
}

// Enable bounded CPU timing samples for this presenter. Timing is disabled by
// default; changing the setting clears prior samples and pending input markers.
hosted_surface_presenter_set_timing_enabled :: proc(
	presenter: ^Hosted_Surface_Presenter,
	enabled: bool,
) -> bool {
	state := hosted_surface_state(presenter)
	if state == nil { return false }
	if state.timing_enabled == enabled { return true }
	if !enabled {
		if state.timing != nil { free(state.timing, allocator=state.allocator) }
		state.timing = nil
		state.timing_enabled = false
		return true
	}
	state.timing = new(hosted_surface_timing_buffer, allocator=state.allocator)
	if state.timing == nil { return false }
	state.timing_enabled = true
	return true
}

// Mark the start of an input-to-submit sample. Multiple inputs before the next
// successful frame retain the earliest timestamp, matching event-to-frame
// latency semantics.
hosted_surface_presenter_note_input :: proc(presenter: ^Hosted_Surface_Presenter) {
	state := hosted_surface_state(presenter)
	if state == nil || !state.timing_enabled || state.timing == nil || state.timing.pending_input { return }
	state.timing.pending_input_since = time.tick_now()
	state.timing.pending_input_revision = state.runtime.presentation_revision
	state.timing.pending_input = true
}

// Drain oldest-first timing samples into caller-owned storage.
hosted_surface_presenter_take_timing_samples :: proc(
	presenter: ^Hosted_Surface_Presenter,
	output: []Hosted_Surface_Timing_Sample,
) -> int {
	state := hosted_surface_state(presenter)
	if state == nil || !state.timing_enabled || state.timing == nil { return 0 }
	return hosted_surface_timing_take(state.timing, output)
}

// Copy oldest-first timing samples without consuming them. Diagnostics capture
// uses this so an investigation does not disturb the --timings report.
hosted_surface_presenter_copy_timing_samples :: proc(
	presenter: ^Hosted_Surface_Presenter,
	output: []Hosted_Surface_Timing_Sample,
) -> int {
	state := hosted_surface_state(presenter)
	if state == nil || !state.timing_enabled || state.timing == nil || len(output) == 0 { return 0 }
	buffer := state.timing
	taken := min(buffer.count, len(output))
	for i in 0..<taken {
		index := (buffer.first+i) % HOSTED_SURFACE_TIMING_SAMPLE_CAPACITY
		output[i] = buffer.samples[index]
	}
	return taken
}

// hosted_surface_presenter_timing_total returns retained and overwritten sample
// counts without draining.
hosted_surface_presenter_timing_counts :: proc(presenter: ^Hosted_Surface_Presenter) -> (retained: int, overwritten: u64, ok: bool) {
	state := hosted_surface_state(presenter)
	if state == nil || !state.timing_enabled || state.timing == nil { return 0, 0, false }
	return state.timing.count, state.timing.overwritten, true
}

hosted_surface_presenter_timing_overwritten :: proc(presenter: ^Hosted_Surface_Presenter) -> u64 {
	state := hosted_surface_state(presenter)
	if state == nil || !state.timing_enabled || state.timing == nil { return 0 }
	return state.timing.overwritten
}

// Hosted_Surface_Renderer_Stats is the shared presenter's retained-work
// snapshot for the compositor passes. Counters are cumulative and are read
// between frames, outside the measured encode/submit stages.
Hosted_Surface_Renderer_Stats :: webgpu_renderer.WebGPU_Renderer_Stats

// hosted_surface_presenter_renderer_stats samples the presenter's renderer
// counters without touching the borrowed device, surface, or Runtime.
hosted_surface_presenter_renderer_stats :: proc(
	presenter: ^Hosted_Surface_Presenter,
) -> (stats: Hosted_Surface_Renderer_Stats, ok: bool) {
	state := hosted_surface_state(presenter)
	if state == nil { return }
	return webgpu_renderer.WebGPU_Presenter_Stats(&state.renderer)
}

@(private)
hosted_surface_timing_buffer_destroy :: proc(state: ^hosted_surface_presenter_state) {
	if state == nil || state.timing == nil { return }
	free(state.timing, allocator=state.allocator)
	state.timing = nil
}

// hosted_surface_presenter_has_in_flight reports whether the host must keep
// pumping WebGPU completion callbacks before blocking indefinitely for input.
hosted_surface_presenter_has_in_flight :: proc(presenter: ^Hosted_Surface_Presenter) -> bool {
	state := hosted_surface_state(presenter)
	return state != nil && webgpu_renderer.WebGPU_Presenter_In_Flight(&state.renderer) > 0
}

@(private)
hosted_surface_present_pending :: proc(
	presenter: ^Hosted_Surface_Presenter,
	timing_sample: ^Hosted_Surface_Timing_Sample,
) -> Hosted_Surface_Result {
	state := hosted_surface_state(presenter)
	if state == nil { return .Invalid_Input }
	if state.presentation_failed { return .Present_Failure }
	if state.completion_failed { return .Resource_Failure }
	if state.configuration.width == 0 || state.configuration.height == 0 { return .Suspended }
	if !webgpu_renderer.WebGPU_Presenter_Can_Encode(&state.renderer) { return .Retry_Later }
	display, display_status := alicorn.hosted_runtime_presentation_list(state.hosted, state.allocator)
	if display_status != .Ok { return .Invalid_Input }
	if display.revision == 0 { return .No_Frame }
	if state.fail_next_encode {
		state.fail_next_encode = false
		return .Render_Failure
	}

	acquire_start: time.Tick
	if state.timing_enabled { acquire_start = time.tick_now() }
	surface_texture := wgpu.SurfaceGetCurrentTexture(state.surface)
	if state.timing_enabled {
		timing_sample.surface_acquire_ns = hosted_surface_timing_elapsed_ns(acquire_start)
	}
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout:
		if surface_texture.texture != nil { wgpu.TextureRelease(surface_texture.texture) }
		return .Retry_Later
	case .Outdated, .Lost:
		if surface_texture.texture != nil { wgpu.TextureRelease(surface_texture.texture) }
		// Acquisition can be the operation that discovers a backend loss; the
		// DeviceLost callback has already marked this presenter. Reconfiguring
		// here would configure a surface against the lost parent device, so let
		// the host's recovery drain own it instead.
		if state.device_lost { return .Surface_Acquire_Failure }
		wgpu.SurfaceConfigure(state.surface, &state.configuration)
		if state.wake != nil { state.wake(state.wake_data) }
		return .Reconfigure_Required
	case .Occluded:
		if surface_texture.texture != nil { wgpu.TextureRelease(surface_texture.texture) }
		return .Hidden
	case .Error:
		if surface_texture.texture != nil { wgpu.TextureRelease(surface_texture.texture) }
		return .Surface_Acquire_Failure
	}
	if surface_texture.texture == nil { return .Present_Failure }
	defer wgpu.TextureRelease(surface_texture.texture)
	view := wgpu.TextureCreateView(surface_texture.texture)
	if view == nil { return .Resource_Failure }
	defer wgpu.TextureViewRelease(view)
	encode_start: time.Tick
	if state.timing_enabled { encode_start = time.tick_now() }
	encoder := wgpu.DeviceCreateCommandEncoder(state.device)
	if encoder == nil { return .Resource_Failure }
	defer wgpu.CommandEncoderRelease(encoder)
	if result := webgpu_renderer.WebGPU_Presenter_Encode(
		&state.renderer, display, encoder, view,
		state.configuration.width, state.configuration.height,
		state.scale_x, state.scale_y, true, state.clear_color,
	); result != .Ok {
		// Encode failures used to become a silent Render_Failure at the host's
		// presentation switch. Name the stage and the retained command count so a
		// content-specific renderer rejection is diagnosable from the console.
		fmt.eprintln(
			"[alicorn-webgpu] frame encode failed",
			"result", result,
			"commands", len(display.commands),
			"revision", display.revision,
		)
		return .Render_Failure
	}
	command := wgpu.CommandEncoderFinish(encoder)
	if state.timing_enabled {
		timing_sample.renderer_encode_ns = hosted_surface_timing_elapsed_ns(encode_start)
	}
	if command == nil {
		_ = webgpu_renderer.WebGPU_Presenter_Cancel_Frame(&state.renderer)
		return .Resource_Failure
	}
	defer wgpu.CommandBufferRelease(command)
	completion := new(hosted_surface_completion, allocator=state.allocator)
	if completion == nil {
		_ = webgpu_renderer.WebGPU_Presenter_Cancel_Frame(&state.renderer)
		return .Resource_Failure
	}
	completion.allocator = state.allocator
	completion.state = state
	submit_start: time.Tick
	if state.timing_enabled { submit_start = time.tick_now() }
	wgpu.QueueSubmit(state.queue, {command})
	submission, submitted := webgpu_renderer.WebGPU_Presenter_Submission_Succeeded(&state.renderer)
	if !submitted {
		free(completion, allocator=completion.allocator)
		state.completion_failed = true
		return .Resource_Failure
	}
	if state.timing_enabled {
		timing_sample.display_revision = submission.display_revision
		timing_sample.submission_serial = submission.serial
		timing_sample.queue_submit_ns = hosted_surface_timing_elapsed_ns(submit_start)
		if state.timing.pending_input {
			ns := time.duration_nanoseconds(time.tick_diff(state.timing.pending_input_since, time.tick_now()))
			if ns > 0 { timing_sample.input_to_submit_ns = u64(ns) }
			state.timing.pending_input = false
		}
	}
	completion.submission = submission
	state.pending_completions += 1
	wgpu.QueueOnSubmittedWorkDone(state.queue, {
		mode=.AllowProcessEvents,
		callback=hosted_surface_presenter_queue_done,
		userdata1=rawptr(completion),
	})
	present_start: time.Tick
	if state.timing_enabled { present_start = time.tick_now() }
	present_succeeded := hosted_surface_present_succeeded(state.surface)
	if state.timing_enabled {
		timing_sample.surface_present_ns = hosted_surface_timing_elapsed_ns(present_start)
	}
	if !present_succeeded {
		state.presentation_failed = true
		return .Present_Failure
	}
	return .Ok
}

@(private)
hosted_surface_presenter_queue_done :: proc "c" (
	status: wgpu.QueueWorkDoneStatus,
	_message: wgpu.StringView,
	userdata1, _userdata2: rawptr,
) {
	context = runtime.default_context()
	completion := cast(^hosted_surface_completion)userdata1
	if completion == nil { return }
	state := completion.state
	if state != nil {
		if state.device_lost {
			// A lost device invalidates normal fence retirement. Keep the presenter
			// alive until this callback arrives, then let the host abandon its GPU
			// resources once all such callbacks have drained.
		} else {
			if !webgpu_renderer.WebGPU_Presenter_Complete_Submission(&state.renderer, completion.submission) {
				state.completion_failed = true
			}
			if status != .Success { state.completion_failed = true }
		}
		if state.pending_completions > 0 { state.pending_completions -= 1 }
		if state.wake != nil { state.wake(state.wake_data) }
	}
	free(completion, allocator=completion.allocator)
}

// Mark loss before the host begins recovery. This immediately prevents new
// presentation work from using resources belonging to the lost device.
hosted_surface_presenter_mark_device_lost :: proc(presenter: ^Hosted_Surface_Presenter) {
	state := hosted_surface_state(presenter)
	if state != nil { state.device_lost = true }
}

// Destroy is nonblocking. It returns false while GPU work is in flight; keep
// this value and the Hosted_Runtime alive, then retry after the completion wake.
// Surface, device, and queue handles are borrowed and remain host-owned.
hosted_surface_presenter_destroy :: proc(presenter: ^Hosted_Surface_Presenter) -> bool {
	state := hosted_surface_state(presenter)
	if presenter == nil { return false }
	if state == nil { return true }
	if !webgpu_renderer.WebGPU_Presenter_Destroy(&state.renderer) { return false }
	wgpu.SurfaceUnconfigure(state.surface)
	allocator := state.allocator
	hosted_surface_timing_buffer_destroy(state)
	free(state, allocator=allocator)
	presenter^ = {}
	return true
}

// Destroy a presenter after device loss. The host must keep it and its Runtime
// alive until all queue callbacks have arrived; this function enforces that
// callback-drain boundary before releasing renderer resources.
hosted_surface_presenter_destroy_after_device_loss :: proc(presenter: ^Hosted_Surface_Presenter) -> bool {
	state := hosted_surface_state(presenter)
	if presenter == nil { return false }
	if state == nil { return true }
	if !state.device_lost || state.pending_completions != 0 { return false }
	if !webgpu_renderer.WebGPU_Presenter_Destroy_After_Device_Loss(&state.renderer) { return false }
	allocator := state.allocator
	hosted_surface_timing_buffer_destroy(state)
	free(state, allocator=allocator)
	presenter^ = {}
	return true
}
