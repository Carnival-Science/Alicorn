package webgpu_renderer

import "core:mem"
import "core:sync"
import alicorn "../../runtime"
import "vendor:wgpu"

WEBGPU_PRESENTER_DEFAULT_MAX_FRAMES_IN_FLIGHT :: 3
WEBGPU_PRESENTER_MAX_FRAMES_IN_FLIGHT :: 8

WebGPU_Presenter_Result :: enum {
	Ok,
	Invalid_Input,
	Backpressure,
	Output_Not_Pending,
	Stale_Display,
	Unsupported_Command,
	Resource_Failure,
}

// WebGPU_Presenter owns renderer resources for one Runtime. The device, queue,
// and Runtime are borrowed and must outlive it. Hosts own command encoders,
// target views, queue submission, callback scheduling, and event loops. Keep
// this value move-only and call its methods on the Runtime's owning thread.
WebGPU_Presenter :: struct {
	state: rawptr,
}

// A submission token contains no GPU handle. A queue-work-done callback for a
// token's serial allows the host to retire the presenter's bounded resources.
WebGPU_Submission :: struct {
	presenter_generation: u64,
	serial: u64,
	display_revision: u64,
	output_id: alicorn.Presentation_Output_ID,
	output_bound: bool,
}

webgpu_presenter_generation_counter: u64

webgpu_presenter_internal_state :: struct {
	allocator: mem.Allocator,
	device: wgpu.Device,
	queue: wgpu.Queue,
	runtime: ^alicorn.Runtime,
	format: wgpu.TextureFormat,
	generation: u64,
	max_frames_in_flight: u64,
	compositor: WebGPU_Compositor,
	last_submitted: u64,
	completed: u64,
	pending_revision: u64,
	pending_output_id: alicorn.Presentation_Output_ID,
	pending_output_bound: bool,
	frame_pending: bool,
	failed: bool,
}

webgpu_presenter_state :: proc(presenter: ^WebGPU_Presenter) -> ^webgpu_presenter_internal_state {
	if presenter == nil || presenter.state == nil { return nil }
	return cast(^webgpu_presenter_internal_state)presenter.state
}

webgpu_presenter_capacity_available :: proc(last_submitted, completed, capacity: u64) -> bool {
	return capacity > 0 && last_submitted >= completed && last_submitted-completed < capacity
}

webgpu_presenter_token_is_valid :: proc(
	generation, last_submitted: u64,
	submission: WebGPU_Submission,
) -> bool {
	return generation != 0 && submission.presenter_generation == generation &&
		submission.serial > 0 && submission.serial <= last_submitted
}

webgpu_presenter_output_id_is_well_formed :: proc(output: alicorn.Presentation_Output_ID) -> bool {
	return (output.runtime_identity == 0 && output.sequence == 0) ||
		(output.runtime_identity != 0 && output.sequence != 0)
}

webgpu_presenter_view_matches_output :: proc(
	view_output, output: alicorn.Presentation_Output_ID,
) -> bool {
	view_is_scoped := view_output.runtime_identity != 0 || view_output.sequence != 0
	if !view_is_scoped { return true }
	return output.runtime_identity != 0 &&
		view_output.runtime_identity == output.runtime_identity &&
		view_output.sequence == output.sequence
}

webgpu_presenter_ack_submission :: proc(
	runtime: ^alicorn.Runtime,
	output: alicorn.Presentation_Output_ID,
	output_bound: bool,
	revision: u64,
) -> bool {
	if runtime == nil { return false }
	if output_bound {
		return alicorn.presentation_output_frame_submission_succeeded(runtime, output, revision) == .Ok
	}
	if runtime.presentation_revision != revision { return false }
	alicorn.gpu_surface_frame_consumed(runtime)
	alicorn.frame_submission_succeeded(runtime)
	return true
}

// Create a host-owned frame presenter for one Runtime. It creates only renderer
// resources; it does not create a surface, submit work, or retain paint-list
// memory. At most eight frames may be outstanding; three is the default.
WebGPU_Presenter_Create :: proc(
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
	runtime: ^alicorn.Runtime,
	max_frames_in_flight: u64 = WEBGPU_PRESENTER_DEFAULT_MAX_FRAMES_IN_FLIGHT,
) -> (presenter: WebGPU_Presenter, ok: bool) {
	if device == nil || queue == nil || runtime == nil ||
	   max_frames_in_flight == 0 || max_frames_in_flight > WEBGPU_PRESENTER_MAX_FRAMES_IN_FLIGHT {
		return
	}
	state_allocator := context.allocator
	state := new(webgpu_presenter_internal_state, allocator=state_allocator)
	if state == nil { return }
	state.allocator = state_allocator
	state.device, state.queue, state.runtime = device, queue, runtime
	state.format = format
	state.max_frames_in_flight = max_frames_in_flight
	state.generation = sync.atomic_add(&webgpu_presenter_generation_counter, 1) + 1
	if state.generation == 0 {
		state.generation = sync.atomic_add(&webgpu_presenter_generation_counter, 1) + 1
	}
	state.compositor, ok = Compositor_Create(device, queue, format)
	if !ok {
		free(state, allocator=state_allocator)
		return
	}
	presenter.state = rawptr(state)
	return presenter, true
}

// Encode a borrowed, finalized display list into the host's encoder and target.
// The view and Runtime sidecars are consumed synchronously. This method never
// submits the queue or retains a pointer into the view.
//
// For Runtime multi-output presentation, pass the selected output ID and a
// display view from paint_display_list_for_output. A manually routed view is
// also accepted when it carries that output snapshot's exact revision. The
// submission acknowledges only that output. Omitting output preserves the
// whole-Runtime compatibility path for hosts that render the complete display.
//
// Backpressure is explicit: when the configured number of queue submissions
// remains incomplete, the host should wait for its asynchronous completion
// callback and retry instead of forcing a blocking GPU wait.
WebGPU_Presenter_Encode :: proc(
	presenter: ^WebGPU_Presenter,
	display: alicorn.Paint_Display_List_View,
	encoder: wgpu.CommandEncoder,
	target: wgpu.TextureView,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
	clear_target := false,
	clear_color: wgpu.Color = {0.04, 0.06, 0.08, 1},
	output: alicorn.Presentation_Output_ID = {},
) -> WebGPU_Presenter_Result {
	state := webgpu_presenter_state(presenter)
	if state == nil || state.failed || state.runtime == nil || encoder == nil || target == nil ||
	   target_width == 0 || target_height == 0 ||
	   !alicorn.number_is_finite(scale_x) || !alicorn.number_is_finite(scale_y) ||
	   scale_x <= 0 || scale_y <= 0 || state.frame_pending ||
	   !webgpu_presenter_output_id_is_well_formed(output) {
		return .Invalid_Input
	}
	output_bound := output.runtime_identity != 0
	if !webgpu_presenter_view_matches_output(display.output, output) {
		return .Invalid_Input
	}
	if output_bound {
		snapshot, snapshot_status := alicorn.presentation_output_snapshot(state.runtime, output)
		if snapshot_status != .Ok || snapshot.root == 0 || !snapshot.visible { return .Invalid_Input }
		if !snapshot.pending { return .Output_Not_Pending }
		// Output snapshots carry their own revision. Hosts that route the
		// Runtime's combined borrowed stream into an output-specific view must
		// stamp that view with this exact revision before encoding it.
		if display.revision != snapshot.revision { return .Stale_Display }
	}
	if !webgpu_presenter_capacity_available(state.last_submitted, state.completed, state.max_frames_in_flight) {
		return .Backpressure
	}
	if result := Compositor_Prepare(
		&state.compositor, state.runtime, display, target_width, target_height, scale_x, scale_y,
	); result != .Ok {
		Compositor_Abort_Submission(&state.compositor)
		return webgpu_presenter_result_from_compositor(result)
	}
	if result := Compositor_Encode(
		&state.compositor, state.runtime, display, target,
		target_width, target_height, scale_x, scale_y,
		encoder, clear_target, clear_color,
	); result != .Ok {
		Compositor_Abort_Submission(&state.compositor)
		// Compositor_Encode may already have recorded part of a pass. The host
		// must discard this encoder; the presenter has not retained it.
		return webgpu_presenter_result_from_compositor(result)
	}
	state.pending_revision = display.revision
	state.pending_output_id = output
	state.pending_output_bound = output_bound
	state.frame_pending = true
	return .Ok
}

// Cancel after the host abandons the containing encoder without queue submit.
// This resets speculative compositor state but does not attempt to undo
// QueueWriteBuffer operations already enqueued during preparation.
WebGPU_Presenter_Cancel_Frame :: proc(presenter: ^WebGPU_Presenter) -> bool {
	state := webgpu_presenter_state(presenter)
	if state == nil || state.failed || !state.frame_pending { return false }
	Compositor_Abort_Submission(&state.compositor)
	state.pending_revision = 0
	state.pending_output_id = {}
	state.pending_output_bound = false
	state.frame_pending = false
	return true
}

// Call only after the host successfully submits the encoder on the presenter's
// queue. This commits atlas generations and associates resource use with a
// completion serial. The host should register QueueOnSubmittedWorkDone and pass
// the returned token to WebGPU_Presenter_Complete_Submission in its callback.
WebGPU_Presenter_Submission_Succeeded :: proc(
	presenter: ^WebGPU_Presenter,
) -> (submission: WebGPU_Submission, ok: bool) {
	state := webgpu_presenter_state(presenter)
	if state == nil || state.failed || !state.frame_pending { return }
	serial := Compositor_Commit_Submission(&state.compositor, state.runtime)
	if serial == 0 || serial != state.last_submitted+1 {
		state.failed = true
		state.frame_pending = false
		return
	}
	state.last_submitted = serial
	submission = WebGPU_Submission{
		presenter_generation=state.generation,
		serial=serial,
		display_revision=state.pending_revision,
		output_id=state.pending_output_id,
		output_bound=state.pending_output_bound,
	}
	state.pending_revision = 0
	state.pending_output_id = {}
	state.pending_output_bound = false
	state.frame_pending = false
	// A Runtime mutation between encode and submit belongs to a later frame.
	if webgpu_presenter_ack_submission(
		state.runtime, submission.output_id, submission.output_bound, submission.display_revision,
	) {
		state.runtime.stats.gpu_submits += 1
	}
	return submission, true
}

// Record queue completion from the host's asynchronous callback. Queue order
// means completion of a later token also retires all earlier uses.
WebGPU_Presenter_Complete_Submission :: proc(
	presenter: ^WebGPU_Presenter,
	submission: WebGPU_Submission,
) -> bool {
	state := webgpu_presenter_state(presenter)
	if state == nil || state.failed ||
	   !webgpu_presenter_token_is_valid(state.generation, state.last_submitted, submission) {
		return false
	}
	if submission.serial <= state.completed { return true }
	if !Compositor_Complete_Submission(&state.compositor, submission.serial) { return false }
	state.completed = submission.serial
	return true
}

WebGPU_Presenter_In_Flight :: proc(presenter: ^WebGPU_Presenter) -> u64 {
	state := webgpu_presenter_state(presenter)
	if state == nil || state.last_submitted < state.completed { return 0 }
	return state.last_submitted - state.completed
}

WebGPU_Presenter_Can_Encode :: proc(presenter: ^WebGPU_Presenter) -> bool {
	state := webgpu_presenter_state(presenter)
	return state != nil && !state.failed && !state.frame_pending &&
		webgpu_presenter_capacity_available(state.last_submitted, state.completed, state.max_frames_in_flight)
}

// Destroy is nonblocking. The host must first cancel an unsubmitted frame and
// report completion for every submitted token; device and Runtime stay alive
// until this returns true.
WebGPU_Presenter_Destroy :: proc(presenter: ^WebGPU_Presenter) -> bool {
	state := webgpu_presenter_state(presenter)
	if presenter == nil { return false }
	if state == nil { return true }
	if state.frame_pending || state.failed || state.completed != state.last_submitted { return false }
	state_allocator := state.allocator
	Compositor_Destroy(&state.compositor)
	free(state, allocator=state_allocator)
	presenter^ = {}
	return true
}

// WebGPU_Presenter_Destroy_After_Device_Loss releases CPU and GPU-side
// renderer ownership after the host has observed device loss and drained every
// callback that can reference this presenter. Submitted work cannot complete
// normally on a lost device, so the ordinary fence-gated destroy path is not
// applicable. The host must stop encoding and guarantee callback quiescence.
WebGPU_Presenter_Destroy_After_Device_Loss :: proc(presenter: ^WebGPU_Presenter) -> bool {
	state := webgpu_presenter_state(presenter)
	if presenter == nil { return false }
	if state == nil { return true }
	if state.frame_pending { return false }
	state_allocator := state.allocator
	Compositor_Destroy(&state.compositor)
	free(state, allocator=state_allocator)
	presenter^ = {}
	return true
}

webgpu_presenter_result_from_compositor :: proc(result: Compositor_Result) -> WebGPU_Presenter_Result {
	switch result {
	case .Ok: return .Ok
	case .Invalid_Input: return .Invalid_Input
	case .Unsupported_Command: return .Unsupported_Command
	case .Resource_Failure: return .Resource_Failure
	}
	return .Resource_Failure
}
