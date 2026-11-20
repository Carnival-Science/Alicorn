package alicorn_sdl_gpu

import alicorn "../../runtime"
import "core:c"
import "core:mem"
import "core:sync"
import "vendor:sdl3"

// SDL_GPU_PRESENTER_MAX_FRAMES_IN_FLIGHT bounds renderer resource reuse while
// allowing hosts to submit a small queue of frames without an immediate wait.
SDL_GPU_PRESENTER_MAX_FRAMES_IN_FLIGHT :: 3
sdl_gpu_presenter_generation_counter: u64

// Sdl_GPU_Presenter owns Alicorn's SDL_GPU renderer resources for one Runtime
// and one GPU device. The device and Runtime are borrowed and must outlive the
// presenter. Create, encode, submit, poll, wait, and destroy it on the Runtime's
// owning host thread. Treat this value as move-only; do not copy it after creation.
//
// The opaque state keeps renderer resources and GPU fences out of the host API.
Sdl_GPU_Presenter :: struct {
	state: rawptr,
}

// Sdl_GPU_Submission identifies a successfully submitted frame. serial is the
// presenter's fence generation; display_revision identifies the retained
// display list consumed synchronously by encode. Tokens are meaningful only
// with the presenter that returned them.
Sdl_GPU_Submission :: struct {
	presenter_generation: u64,
	serial:          u64,
	display_revision: u64,
}

presenter_encode_failure_point :: enum {
	None,
	Before_Render,
	After_Background_Clear,
}

sdl_gpu_presenter_internal_state :: struct {
	allocator:       mem.Allocator,
	device:          ^sdl3.GPUDevice,
	runtime:         ^alicorn.Runtime,
	target_format:        sdl3.GPUTextureFormat,
	window_target:        ^sdl3.GPUTexture,
	window_target_width:  sdl3.Uint32,
	window_target_height: sdl3.Uint32,
	generation:      u64,
	text:            Native_Text_Renderer,
	surface:         Native_Surface_Renderer,
	solid:           Native_Solid_Renderer,
	in_flight:       [dynamic; SDL_GPU_PRESENTER_MAX_FRAMES_IN_FLIGHT]Native_In_Flight,
	last_submitted:  u64,
	completed:       u64,
	pending_revision: u64,
	frame_pending:   bool,
	swapchain_acquired: bool,
	surface_mask_was_initialized:   bool,
	solid_white_was_initialized:   bool,
}

sdl_gpu_presenter_state :: proc(presenter: ^Sdl_GPU_Presenter) -> ^sdl_gpu_presenter_internal_state {
	if presenter == nil || presenter.state == nil { return nil }
	return cast(^sdl_gpu_presenter_internal_state)presenter.state
}

sdl_gpu_presenter_release_renderers :: proc(state: ^sdl_gpu_presenter_internal_state) {
	if state == nil { return }
	if state.window_target != nil {
		sdl3.ReleaseGPUTexture(state.device, state.window_target)
		state.window_target = nil
		state.window_target_width = 0
		state.window_target_height = 0
	}
	native_solid_destroy(&state.solid)
	native_surface_destroy(&state.surface)
	native_text_destroy(&state.text)
}

// Create an SDL_GPU presenter around a host-owned device and Runtime. The host
// remains responsible for SDL initialization, windows, command buffers,
// targets, event dispatch, and the application event loop.
Sdl_GPU_Presenter_Create :: proc(
	device: ^sdl3.GPUDevice,
	target_format: sdl3.GPUTextureFormat,
	runtime: ^alicorn.Runtime,
) -> (presenter: Sdl_GPU_Presenter, ok: bool) {
	if device == nil || runtime == nil { return }
	state_allocator := context.allocator
	state := new(sdl_gpu_presenter_internal_state, allocator=state_allocator)
	if state == nil { return }
	state.allocator = state_allocator
	state.device = device
	state.runtime = runtime
	state.target_format = target_format
	state.generation = sync.atomic_add(&sdl_gpu_presenter_generation_counter, 1) + 1
	if state.generation == 0 {
		state.generation = sync.atomic_add(&sdl_gpu_presenter_generation_counter, 1) + 1
	}

	made: bool
	state.text, made = native_text_make(device, target_format, runtime)
	if !made {
		sdl_gpu_presenter_release_renderers(state)
		free(state, allocator=state.allocator)
		return
	}
	state.surface, made = native_surface_make(device, target_format, runtime)
	if !made {
		sdl_gpu_presenter_release_renderers(state)
		free(state, allocator=state.allocator)
		return
	}
	state.solid, made = native_solid_make(device, target_format, runtime)
	if !made {
		sdl_gpu_presenter_release_renderers(state)
		free(state, allocator=state.allocator)
		return
	}
	presenter.state = rawptr(state)
	return presenter, true
}

// Return false when this display contains an effect or command kind the public
// presenter does not implement. This avoids silently dropping paint that the
// full native host can render with host-only services.
sdl_gpu_presenter_display_supported :: proc(commands: []alicorn.Paint_Command) -> bool {
	for command in commands {
		if alicorn.paint_command_is_backdrop_effect(command) { return false }
		if alicorn.paint_command_is_surface(command) ||
			alicorn.paint_command_is_text(command) ||
			alicorn.paint_command_is_icon(command) ||
			alicorn.paint_command_is_image(command) ||
			alicorn.paint_command_is_geometry(command) {
			continue
		}
		return false
	}
	return true
}

sdl_gpu_presenter_wait_oldest :: proc(state: ^sdl_gpu_presenter_internal_state) -> bool {
	query_before_wait_true, query_after_wait_true, wait_count := 0, 0, 0
	return wait_and_retire_oldest(
		state.device,
		&state.in_flight,
		&query_before_wait_true,
		&query_after_wait_true,
		&wait_count,
		completed_serial=&state.completed,
	)
}

sdl_gpu_presenter_wait_all :: proc(state: ^sdl_gpu_presenter_internal_state) -> bool {
	if state == nil { return false }
	for len(state.in_flight) > 0 {
		if !sdl_gpu_presenter_wait_oldest(state) { return false }
	}
	return true
}

sdl_gpu_presenter_ensure_window_target :: proc(
	state: ^sdl_gpu_presenter_internal_state,
	width, height: sdl3.Uint32,
) -> bool {
	if state == nil || width == 0 || height == 0 { return false }
	if state.window_target != nil && state.window_target_width == width &&
		state.window_target_height == height {
		return true
	}
	usage := sdl3.GPUTextureUsageFlags{.COLOR_TARGET, .SAMPLER}
	if !sdl3.GPUTextureSupportsFormat(state.device, state.target_format, .D2, usage) {
		return false
	}
	replacement := sdl3.CreateGPUTexture(state.device, sdl3.GPUTextureCreateInfo{
		type=.D2,
		format=state.target_format,
		usage=usage,
		width=width,
		height=height,
		layer_count_or_depth=1,
		num_levels=1,
		sample_count=._1,
	})
	if replacement == nil { return false }
	// The old target may still be read by an earlier submitted blit. Allocate
	// first so a failed replacement leaves the current presenter usable, then
	// retire all prior uses before releasing the old texture.
	if !sdl_gpu_presenter_wait_all(state) {
		sdl3.ReleaseGPUTexture(state.device, replacement)
		return false
	}
	if state.window_target != nil { sdl3.ReleaseGPUTexture(state.device, state.window_target) }
	state.window_target = replacement
	state.window_target_width = width
	state.window_target_height = height
	return true
}

// Encode the current completed Runtime display into a host-owned offscreen SDL_GPU
// target. The borrowed display list and all Runtime sidecars are consumed
// synchronously; no Runtime memory or command-buffer pointer is retained by the
// presenter. Use Sdl_GPU_Presenter_Encode_Window for swapchain presentation. A
// false result after encoding begins means the caller must cancel its command
// buffer, then call Sdl_GPU_Presenter_Cancel_Frame.
//
// clear_background defaults to false because the host owns target clearing. If
// enabled, the standard Alicorn dark background is cleared before paint.
Sdl_GPU_Presenter_Encode :: proc(
	presenter: ^Sdl_GPU_Presenter,
	command: ^sdl3.GPUCommandBuffer,
	target: ^sdl3.GPUTexture,
	width, height: sdl3.Uint32,
	scale_x, scale_y: f32,
	clear_background := false,
) -> bool {
	return sdl_gpu_presenter_encode_with_failure(
		presenter, command, target, width, height, scale_x, scale_y,
		clear_background, .None,
	)
}

sdl_gpu_presenter_encode_with_failure :: proc(
	presenter: ^Sdl_GPU_Presenter,
	command: ^sdl3.GPUCommandBuffer,
	target: ^sdl3.GPUTexture,
	width, height: sdl3.Uint32,
	scale_x, scale_y: f32,
	clear_background: bool,
	failure_point: presenter_encode_failure_point,
) -> bool {
	state := sdl_gpu_presenter_state(presenter)
	if state == nil || command == nil || target == nil || width == 0 || height == 0 ||
		scale_x <= 0 || scale_y <= 0 || scale_x != scale_x || scale_y != scale_y ||
		state.frame_pending || state.swapchain_acquired {
		return false
	}

	_ = native_poll_completed_fences(state.device, &state.in_flight, &state.completed)
	if len(state.in_flight) >= SDL_GPU_PRESENTER_MAX_FRAMES_IN_FLIGHT &&
		!sdl_gpu_presenter_wait_oldest(state) {
		return false
	}

	view, view_ok := alicorn.paint_display_list(state.runtime)
	if !view_ok || !sdl_gpu_presenter_display_supported(view.commands) { return false }
	state.pending_revision = view.revision
	state.surface_mask_was_initialized = state.surface.shape_mask_initialized
	state.solid_white_was_initialized = state.solid.white_initialized
	state.frame_pending = true
	if failure_point == .Before_Render { return false }
	return draw_display_list(
		command,
		target,
		width,
		height,
		&state.text,
		&state.surface,
		&state.solid,
		view.commands,
		scale_x,
		scale_y,
		clear_background=clear_background,
		validation_fail_after_background_clear=failure_point == .After_Background_Clear,
	)
}

// Encode and present a frame to a host-owned SDL window without exposing the
// acquired swapchain texture to fallible renderer work. Alicorn first renders
// synchronously into a presenter-owned texture. Only after that succeeds does
// this procedure acquire the swapchain texture and issue a single SDL blit.
// Thus every false return occurs before a drawable swapchain texture is held,
// and the caller may cancel the command buffer before Cancel_Frame. A true
// return means a non-nil swapchain texture was acquired; the command buffer
// must be submitted and cannot be canceled.
//
// The window must already be claimed by the presenter's device. Its current
// drawable pixel dimensions and swapchain format are queried before rendering;
// if the acquired dimensions change in the meantime, the final blit scales the
// completed image to the actual swapchain size. The standard Alicorn background
// is always cleared so newly allocated or resized targets are fully defined.
Sdl_GPU_Presenter_Encode_Window :: proc(
	presenter: ^Sdl_GPU_Presenter,
	command: ^sdl3.GPUCommandBuffer,
	window: ^sdl3.Window,
	logical_to_pixel_x, logical_to_pixel_y: f32,
) -> bool {
	return sdl_gpu_presenter_encode_window_with_failure(
		presenter, command, window, logical_to_pixel_x, logical_to_pixel_y, .None,
	)
}

sdl_gpu_presenter_encode_window_with_failure :: proc(
	presenter: ^Sdl_GPU_Presenter,
	command: ^sdl3.GPUCommandBuffer,
	window: ^sdl3.Window,
	logical_to_pixel_x, logical_to_pixel_y: f32,
	failure_point: presenter_encode_failure_point,
) -> bool {
	state := sdl_gpu_presenter_state(presenter)
	if state == nil || command == nil || window == nil || state.frame_pending || state.swapchain_acquired ||
		logical_to_pixel_x <= 0 || logical_to_pixel_y <= 0 ||
		logical_to_pixel_x != logical_to_pixel_x || logical_to_pixel_y != logical_to_pixel_y {
		return false
	}
	if sdl3.GetGPUSwapchainTextureFormat(state.device, window) != state.target_format { return false }
	pixel_width, pixel_height: c.int
	if !sdl3.GetWindowSizeInPixels(window, &pixel_width, &pixel_height) || pixel_width <= 0 || pixel_height <= 0 {
		return false
	}
	width, height := sdl3.Uint32(pixel_width), sdl3.Uint32(pixel_height)
	if !sdl_gpu_presenter_ensure_window_target(state, width, height) { return false }
	if !sdl_gpu_presenter_encode_with_failure(
		presenter,
		command,
		state.window_target,
		state.window_target_width,
		state.window_target_height,
		logical_to_pixel_x,
		logical_to_pixel_y,
		true,
		failure_point,
	) {
		return false
	}

	swapchain: ^sdl3.GPUTexture
	swapchain_width, swapchain_height: sdl3.Uint32
	if !sdl3.WaitAndAcquireGPUSwapchainTexture(
		command, window, &swapchain, &swapchain_width, &swapchain_height,
	) {
		return false
	}
	// SDL may report success with a nil swapchain texture for a minimized
	// window. In that case no target was acquired and cancellation remains safe.
	if swapchain == nil { return false }

	// SDL_BlitGPUTexture returns void. Keep this as the only operation after a
	// non-nil swapchain target is acquired; no renderer preparation or error path
	// follows it.
	state.swapchain_acquired = true
	sdl3.BlitGPUTexture(command, sdl3.GPUBlitInfo{
		source=sdl3.GPUBlitRegion{
			texture=state.window_target,
			w=state.window_target_width,
			h=state.window_target_height,
		},
		destination=sdl3.GPUBlitRegion{
			texture=swapchain,
			w=swapchain_width,
			h=swapchain_height,
		},
		load_op=.DONT_CARE,
		flip_mode=.NONE,
		filter=.LINEAR,
	})
	return true
}

// Cancel a frame only after the host has canceled a command buffer that has
// not acquired a non-nil swapchain texture. After Encode_Window returns true,
// the command buffer must be submitted and this procedure rejects cancellation.
// For an offscreen submit failure with ambiguous GPU ownership, wait for GPU
// idle before canceling. Pending glyph uploads remain dirty for retry;
// unsubmitted image uploads and speculative clear/mask state are rolled back.
Sdl_GPU_Presenter_Cancel_Frame :: proc(presenter: ^Sdl_GPU_Presenter) -> bool {
	state := sdl_gpu_presenter_state(presenter)
	if state == nil || !state.frame_pending || state.swapchain_acquired { return false }
	clear(&state.text.pending_dirty)
	native_image_release_unsubmitted(&state.solid.images)
	// This resets the recorded command only; the renderer keeps the transfer
	// buffer so the next encoded frame can retry the upload.
	native_surface_cancel_unsubmitted_mask_upload(&state.surface, state.surface_mask_was_initialized)
	if !state.solid_white_was_initialized { state.solid.white_initialized = false }
	state.pending_revision = 0
	state.frame_pending = false
	state.swapchain_acquired = false
	return true
}

// A successful host submission transfers ownership of its acquired fence from
// the same GPU device to the presenter. Renderer uploads and Runtime frame
// acknowledgement occur only here, after the actual submit. The returned token
// is a fence-backed lifetime handle that contains no raw GPU pointer.
Sdl_GPU_Presenter_Submission_Succeeded :: proc(
	presenter: ^Sdl_GPU_Presenter,
	fence: ^sdl3.GPUFence,
) -> (submission: Sdl_GPU_Submission, ok: bool) {
	state := sdl_gpu_presenter_state(presenter)
	if state == nil || fence == nil || !state.frame_pending ||
		len(state.in_flight) >= SDL_GPU_PRESENTER_MAX_FRAMES_IN_FLIGHT {
		return
	}
	state.last_submitted += 1
	if state.last_submitted == 0 { state.last_submitted = 1 }
	submission = Sdl_GPU_Submission{state.generation, state.last_submitted, state.pending_revision}
	append(&state.in_flight, Native_In_Flight{fence=fence, serial=state.last_submitted})

	native_text_commit_submission(&state.text)
	native_surface_commit_submission(&state.surface)
	native_solid_commit_submission(&state.solid)
	// A Runtime mutation between encode and submit is not part of this frame;
	// keep its newer revision pending for the host's next frame.
	if state.runtime.presentation_revision == state.pending_revision {
		alicorn.gpu_surface_frame_consumed(state.runtime)
		alicorn.frame_submission_succeeded(state.runtime)
		state.runtime.stats.gpu_submits += 1
	}
	state.pending_revision = 0
	state.frame_pending = false
	state.swapchain_acquired = false
	return submission, true
}

// Poll completed submissions and return the newest retired serial. Completion
// can also be observed by waiting on a token or implicitly during a later encode.
Sdl_GPU_Presenter_Poll :: proc(presenter: ^Sdl_GPU_Presenter) -> u64 {
	state := sdl_gpu_presenter_state(presenter)
	if state == nil { return 0 }
	_ = native_poll_completed_fences(state.device, &state.in_flight, &state.completed)
	return state.completed
}

// Wait until a token's submission fence has completed. This also releases all
// earlier presenter fences, which are ordered before the requested submission.
Sdl_GPU_Presenter_Wait :: proc(presenter: ^Sdl_GPU_Presenter, submission: Sdl_GPU_Submission) -> bool {
	state := sdl_gpu_presenter_state(presenter)
	if state == nil || submission.presenter_generation != state.generation ||
		submission.serial == 0 || submission.serial > state.last_submitted {
		return false
	}
	for state.completed < submission.serial {
		if !sdl_gpu_presenter_wait_oldest(state) { return false }
	}
	return true
}

// Destroy renderer resources after retiring every fence owned by the presenter.
// The Runtime and GPU device are borrowed, so keep them alive until this returns
// true. A pending frame must be canceled or successfully submitted first.
Sdl_GPU_Presenter_Destroy :: proc(presenter: ^Sdl_GPU_Presenter) -> bool {
	state := sdl_gpu_presenter_state(presenter)
	if presenter == nil { return false }
	if state == nil { return true }
	if state.frame_pending { return false }
	for len(state.in_flight) > 0 {
		if !sdl_gpu_presenter_wait_oldest(state) { return false }
	}
	state_allocator := state.allocator
	sdl_gpu_presenter_release_renderers(state)
	free(state, allocator=state_allocator)
	presenter^ = {}
	return true
}
