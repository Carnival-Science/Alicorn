package alicorn_sdl_gpu

// RunPresentationBoundaryValidation compares the ordinary SDL_GPU host path
// with the public host-owned presenter on the Windows SDL_GPU backend.

import "core:c"
import "core:fmt"
import "core:os"
import "core:time"
import alicorn "../../runtime"
import "vendor:sdl3"

PRESENTATION_VALIDATION_WIDTH :: sdl3.Uint32(480)
PRESENTATION_VALIDATION_HEIGHT :: sdl3.Uint32(300)
PRESENTATION_VALIDATION_IDLE_MS :: sdl3.Sint32(300)
PRESENTATION_VALIDATION_COST_SAMPLES :: 64
PRESENTATION_VALIDATION_LIFETIME_FRAMES :: 8

Presentation_Validation_App :: struct {
	value: [128]u8,
	value_length: int,
	field, button: alicorn.Node_ID,
	activations: int,
}

Presentation_Validation_Renderers :: struct {
	text: Native_Text_Renderer,
	surface: Native_Surface_Renderer,
	solid: Native_Solid_Renderer,
}

presentation_validation_fail :: proc(message: string) -> ! {
	fmt.eprintln("issue_162_validation", "FAIL", message, "SDL", sdl3.GetError())
	os.exit(1)
}

presentation_validation_value :: proc(app: ^Presentation_Validation_App) -> string {
	return string(app.value[:app.value_length])
}

presentation_validation_set_value :: proc(app: ^Presentation_Validation_App, value: string) {
	if app == nil || len(value) > len(app.value) { presentation_validation_fail("fixture text exceeded its bounded buffer") }
	copy(app.value[:len(value)], value)
	app.value_length = len(value)
}

presentation_validation_render :: proc(app: ^Presentation_Validation_App, ui: ^alicorn.UI) {
	alicorn.container_begin(ui, .Container, label="comparison panel", key=alicorn.key_string("issue-162.panel"),
		style=alicorn.layout_style(.Column, grow=1, padding=16, gap=10, clip=true),
		color=alicorn.Color{0.12, 0.15, 0.20, 1})
	alicorn.text(ui, "Host-owned SDL_GPU frame boundary", key=alicorn.key_string("issue-162.title"), style=alicorn.layout_style(height=28))
	alicorn.text(ui, "Flat surface, retained text, pointer focus, and text input.", key=alicorn.key_string("issue-162.description"), style=alicorn.layout_style(height=24))
	app.field = alicorn.text_field(ui, presentation_validation_value(app), key=alicorn.key_string("issue-162.field"), style=alicorn.layout_style(height=38))
	if alicorn.button(ui, "Click to verify host input", key=alicorn.key_string("issue-162.button"), style=alicorn.layout_style(width=220, height=40)) {
		app.activations += 1
	}
	alicorn.text(ui, "Window, target, command buffer, and event loop belong to the host.", key=alicorn.key_string("issue-162.footer"), style=alicorn.layout_style(height=24))
	alicorn.container_end(ui)
}

presentation_validation_build :: proc(rt: ^alicorn.Runtime, app: ^Presentation_Validation_App) -> bool {
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return false }
	alicorn.container_begin(&ui, .Root, label="ui-root", key=alicorn.key_string("alicorn.hosted.root"), style=alicorn.layout_style(.Column, grow=1))
	presentation_validation_render(app, &ui)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	app.button, _ = alicorn.node_by_key(rt, alicorn.key_string("issue-162.button"), .Button)
	return true
}

presentation_validation_renderers_make :: proc(device: ^sdl3.GPUDevice, format: sdl3.GPUTextureFormat, rt: ^alicorn.Runtime) -> (r: Presentation_Validation_Renderers, ok: bool) {
	r.text, ok = native_text_make(device, format, rt)
	if !ok { return }
	r.surface, ok = native_surface_make(device, format, rt)
	if !ok { native_text_destroy(&r.text); return }
	r.solid, ok = native_solid_make(device, format, rt)
	if !ok { native_surface_destroy(&r.surface); native_text_destroy(&r.text); return }
	return r, true
}

presentation_validation_renderers_destroy :: proc(r: ^Presentation_Validation_Renderers) {
	if r == nil { return }
	native_solid_destroy(&r.solid)
	native_surface_destroy(&r.surface)
	native_text_destroy(&r.text)
	r^ = {}
}

presentation_validation_hash :: proc(pixels: []u8) -> u64 {
	h := u64(1469598103934665603)
	for b in pixels { h = h * u64(1099511628211) + u64(b) }
	return h
}

presentation_validation_compare :: proc(a, b: []u8) -> (different, max_delta: int) {
	if len(a) != len(b) { return max(len(a), len(b)), 255 }
	for i in 0..<len(a) {
		if a[i] != b[i] {
			different += 1
			max_delta = max(max_delta, abs(int(a[i])-int(b[i])))
		}
	}
	return different, max_delta
}

presentation_validation_frame :: proc(
	rt: ^alicorn.Runtime,
	r: ^Presentation_Validation_Renderers,
	presenter: ^Sdl_GPU_Presenter,
	device: ^sdl3.GPUDevice,
	target: ^sdl3.GPUTexture,
	width, height: sdl3.Uint32,
	download: ^sdl3.GPUTransferBuffer = nil,
	pixels: []u8 = nil,
) -> (encode_ns: i64, ok: bool) {
	command := sdl3.AcquireGPUCommandBuffer(device)
	if command == nil { return 0, false }
	submitted := false
	defer if !submitted {
		_ = sdl3.CancelGPUCommandBuffer(command)
		if presenter != nil { _ = Sdl_GPU_Presenter_Cancel_Frame(presenter) }
	}
	started := time.now()
	if presenter != nil {
		if !Sdl_GPU_Presenter_Encode(presenter, command, target, width, height, 1, 1, clear_background=true) { return 0, false }
	} else {
		view, view_ok := alicorn.paint_display_list(rt)
		if !view_ok || r == nil || !draw_display_list(command, target, width, height, &r.text, &r.surface, &r.solid, view.commands, 1, 1, clear_background=true) {
			return 0, false
		}
	}
	encode_ns = time.duration_nanoseconds(time.since(started))
	if download != nil {
		copy_pass := sdl3.BeginGPUCopyPass(command)
		if copy_pass == nil { return 0, false }
		source := sdl3.GPUTextureRegion{texture=target, w=width, h=height, d=1}
		destination := sdl3.GPUTextureTransferInfo{transfer_buffer=download, pixels_per_row=width, rows_per_layer=height}
		sdl3.DownloadFromGPUTexture(copy_pass, source, destination)
		sdl3.EndGPUCopyPass(copy_pass)
	}
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	submitted = true
	if fence == nil {
		if presenter != nil && sdl3.WaitForGPUIdle(device) { _ = Sdl_GPU_Presenter_Cancel_Frame(presenter) }
		return encode_ns, false
	}
	if presenter != nil {
		submission, accepted := Sdl_GPU_Presenter_Submission_Succeeded(presenter, fence)
		if !accepted {
			fences := [1]^sdl3.GPUFence{fence}
			_ = sdl3.WaitForGPUFences(device, true, &fences[0], 1)
			sdl3.ReleaseGPUFence(device, fence)
			_ = Sdl_GPU_Presenter_Cancel_Frame(presenter)
			return encode_ns, false
		}
		ok = Sdl_GPU_Presenter_Wait(presenter, submission)
	} else {
		native_text_commit_submission(&r.text)
		native_surface_commit_submission(&r.surface)
		native_solid_commit_submission(&r.solid)
		fences := [1]^sdl3.GPUFence{fence}
		ok = sdl3.WaitForGPUFences(device, true, &fences[0], 1)
		sdl3.ReleaseGPUFence(device, fence)
		if ok {
			alicorn.gpu_surface_frame_consumed(rt)
			alicorn.frame_submission_succeeded(rt)
			rt.stats.gpu_submits += 1
		}
	}
	if !ok || download == nil { return }
	mapped := sdl3.MapGPUTransferBuffer(device, download, false)
	if mapped == nil { return 0, false }
	copy(pixels, (cast([^]u8)mapped)[:len(pixels)])
	sdl3.UnmapGPUTransferBuffer(device, download)
	return encode_ns, true
}

presentation_validation_pointer_pair :: proc(rt: ^alicorn.Runtime, x, y: f32) {
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{kind=.Down, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY})
	_ = alicorn.process_pointer(rt, alicorn.Pointer_Event{kind=.Up, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY})
}

RunPresentationBoundaryValidation :: proc() {
	if !sdl3.Init(sdl3.INIT_VIDEO) { presentation_validation_fail("SDL initialization failed") }
	defer sdl3.Quit()
	window := sdl3.CreateWindow("Alicorn #162 validation", c.int(PRESENTATION_VALIDATION_WIDTH), c.int(PRESENTATION_VALIDATION_HEIGHT), sdl3.WindowFlags{.HIDDEN, .HIGH_PIXEL_DENSITY})
	if window == nil { presentation_validation_fail("hidden SDL window creation failed") }
	defer sdl3.DestroyWindow(window)
	device := sdl3.CreateGPUDevice(sdl3.GPUShaderFormat{.SPIRV, .DXIL, .MSL}, false, nil)
	if device == nil || !sdl3.ClaimWindowForGPUDevice(device, window) { presentation_validation_fail("SDL_GPU device creation or window claim failed") }
	defer {
		_ = sdl3.WaitForGPUIdle(device)
		sdl3.ReleaseWindowFromGPUDevice(device, window)
		sdl3.DestroyGPUDevice(device)
	}
	format := sdl3.GetGPUSwapchainTextureFormat(device, window)
	if !sdl3.GPUTextureSupportsFormat(device, format, .D2, {.COLOR_TARGET}) { presentation_validation_fail("swapchain format is not an offscreen color target") }
	w, h := PRESENTATION_VALIDATION_WIDTH, PRESENTATION_VALIDATION_HEIGHT
	target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{type=.D2, format=format, usage={.COLOR_TARGET}, width=w, height=h, layer_count_or_depth=1, num_levels=1, sample_count=._1})
	if target == nil { presentation_validation_fail("standalone target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, target)
	host_target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{type=.D2, format=format, usage={.COLOR_TARGET}, width=w, height=h, layer_count_or_depth=1, num_levels=1, sample_count=._1})
	if host_target == nil { presentation_validation_fail("host-owned target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, host_target)
	download := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{usage=.DOWNLOAD, size=w*h*4})
	if download == nil { presentation_validation_fail("pixel readback buffer creation failed") }
	defer sdl3.ReleaseGPUTransferBuffer(device, download)

	app := Presentation_Validation_App{}
	presentation_validation_set_value(&app, "editable input")
	host_app := Presentation_Validation_App{}
	presentation_validation_set_value(&host_app, "editable input")
	allocations := alicorn.Runtime_Allocation_Stats{}
	host_allocations := alicorn.Runtime_Allocation_Stats{}
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, f32(w), f32(h)}, config=alicorn.Runtime_Config{allocation_stats=&allocations})
	if !alicorn.text_engine_load_default_fonts(&rt) || !presentation_validation_build(&rt, &app) { presentation_validation_fail("standalone Runtime initialization failed") }
	defer if rt.persistent_allocator_state != nil { alicorn.destroy_runtime(&rt) }
	host_rt := alicorn.new_runtime(alicorn.Rect{0, 0, f32(w), f32(h)}, config=alicorn.Runtime_Config{allocation_stats=&host_allocations})
	if !alicorn.text_engine_load_default_fonts(&host_rt) || !presentation_validation_build(&host_rt, &host_app) { presentation_validation_fail("host-owned Runtime initialization failed") }
	defer if host_rt.persistent_allocator_state != nil { alicorn.destroy_runtime(&host_rt) }
	renderers, renderers_ok := presentation_validation_renderers_make(device, format, &rt)
	if !renderers_ok { presentation_validation_fail("standalone renderer creation failed") }
	defer if renderers.text.device != nil { presentation_validation_renderers_destroy(&renderers) }
	presenter, presenter_ok := Sdl_GPU_Presenter_Create(device, format, &host_rt)
	if !presenter_ok { presentation_validation_fail("host-owned presenter creation failed") }
	defer if presenter.state != nil { _ = Sdl_GPU_Presenter_Destroy(&presenter) }

	pixel_count := int(w*h*4)
	standalone_pixels := make([]u8, pixel_count)
	host_pixels := make([]u8, pixel_count)
	// The host must cancel an encoded frame only after canceling its command
	// buffer. Cancellation must leave the Runtime's display pending for retry.
	cancel_command := sdl3.AcquireGPUCommandBuffer(device)
	if cancel_command == nil || !Sdl_GPU_Presenter_Encode(&presenter, cancel_command, host_target, w, h, 1, 1, clear_background=true) {
		if cancel_command != nil { _ = sdl3.CancelGPUCommandBuffer(cancel_command) }
		presentation_validation_fail("presenter cancellation setup failed")
	}
	if !sdl3.CancelGPUCommandBuffer(cancel_command) || !Sdl_GPU_Presenter_Cancel_Frame(&presenter) || !alicorn.frame_needs_submission(&host_rt) {
		presentation_validation_fail("canceled host frame did not remain retryable")
	}
	fmt.println("issue_162_cancel", "command_buffer", "canceled", "runtime_frame", "retryable", "status", "PASS")

	_, standalone_ok := presentation_validation_frame(&rt, &renderers, nil, device, target, w, h, download, standalone_pixels)
	_, hosted_ok := presentation_validation_frame(&host_rt, nil, &presenter, device, host_target, w, h, download, host_pixels)
	if !standalone_ok || !hosted_ok { presentation_validation_fail("initial pixel readback failed") }
	different, max_delta := presentation_validation_compare(standalone_pixels, host_pixels)
	if different != 0 { presentation_validation_fail("initial compositor pixels differ") }
	fmt.println("issue_162_pixels", "state=initial", "size", w, "x", h, "different_bytes", different, "max_delta", max_delta,
		"standalone_hash", presentation_validation_hash(standalone_pixels), "hosted_hash", presentation_validation_hash(host_pixels))

	// Apply identical native-normalized input directly to the same public
	// Runtime input contract that an embedding event loop calls.
	button, button_ok := alicorn.node_info(&rt, app.button)
	host_button, host_button_ok := alicorn.node_info(&host_rt, host_app.button)
	if !button_ok || !host_button_ok || button.bounds != host_button.bounds {
		fmt.println("issue_162_input_geometry", "button_ok", button_ok, host_button_ok,
			"standalone", button.bounds, "hosted", host_button.bounds, "node_ids", app.button, host_app.button)
		presentation_validation_fail("standalone/host button geometry differs")
	}
	presentation_validation_pointer_pair(&rt, button.bounds.x+button.bounds.w*0.5, button.bounds.y+button.bounds.h*0.5)
	presentation_validation_pointer_pair(&host_rt, host_button.bounds.x+host_button.bounds.w*0.5, host_button.bounds.y+host_button.bounds.h*0.5)
	if !presentation_validation_build(&rt, &app) || !presentation_validation_build(&host_rt, &host_app) || app.activations != 1 || host_app.activations != 1 { presentation_validation_fail("pointer activation differed between hosts") }
	field, field_ok := alicorn.node_info(&rt, app.field)
	host_field, host_field_ok := alicorn.node_info(&host_rt, host_app.field)
	if !field_ok || !host_field_ok || field.bounds != host_field.bounds { presentation_validation_fail("text-field geometry differs between hosts") }
	presentation_validation_pointer_pair(&rt, field.bounds.x+8, field.bounds.y+field.bounds.h*0.5)
	presentation_validation_pointer_pair(&host_rt, host_field.bounds.x+8, host_field.bounds.y+host_field.bounds.h*0.5)
	if !presentation_validation_build(&rt, &app) || !presentation_validation_build(&host_rt, &host_app) ||
		alicorn.focused_node(&rt) != app.field || alicorn.focused_node(&host_rt) != host_app.field { presentation_validation_fail("pointer focus did not reach the text field") }
	before, before_ok := alicorn.text_field_interaction(&rt, app.field)
	host_before, host_before_ok := alicorn.text_field_interaction(&host_rt, host_app.field)
	if !before_ok || !host_before_ok || before.caret != host_before.caret { presentation_validation_fail("focused caret state differs between hosts") }
	key_change := alicorn.process_text_command(&rt, app.field, .Move_Right)
	host_key_change := alicorn.process_text_command(&host_rt, host_app.field, .Move_Right)
	alicorn.text_change_destroy(&rt, &key_change)
	alicorn.text_change_destroy(&host_rt, &host_key_change)
	after, after_ok := alicorn.text_field_interaction(&rt, app.field)
	host_after, host_after_ok := alicorn.text_field_interaction(&host_rt, host_app.field)
	if !after_ok || !host_after_ok || after.caret != host_after.caret || after.caret == before.caret { presentation_validation_fail("keyboard navigation differed or did not move the caret") }
	change := alicorn.process_text_input(&rt, app.field, "-host")
	host_change := alicorn.process_text_input(&host_rt, host_app.field, "-host")
	presentation_validation_set_value(&app, change.text)
	presentation_validation_set_value(&host_app, host_change.text)
	alicorn.text_change_destroy(&rt, &change)
	alicorn.text_change_destroy(&host_rt, &host_change)
	if !presentation_validation_build(&rt, &app) || !presentation_validation_build(&host_rt, &host_app) { presentation_validation_fail("Runtime did not rebuild after committed text input") }
	value, value_ok := alicorn.text_field_value(&rt, app.field)
	host_value, host_value_ok := alicorn.text_field_value(&host_rt, host_app.field)
	if !value_ok || value != "e-hostditable input" { presentation_validation_fail("text input was not preserved at the selected caret position") }
	interaction, interaction_ok := alicorn.text_field_interaction(&rt, app.field)
	host_interaction, host_interaction_ok := alicorn.text_field_interaction(&host_rt, host_app.field)
	if !host_value_ok || value != host_value || !interaction_ok || !host_interaction_ok || interaction.caret != host_interaction.caret ||
		interaction.caret != after.caret+len("-host") { presentation_validation_fail("text-input caret/source byte positions differed between hosts") }
	fmt.println("issue_162_input", "button_activations", app.activations, "focused", "issue-162.field",
		"caret_before_right", before.caret, "caret_after_right", after.caret,
		"caret_after_input", interaction.caret, "value", value, "status", "PASS")

	_, standalone_ok = presentation_validation_frame(&rt, &renderers, nil, device, target, w, h, download, standalone_pixels)
	_, hosted_ok = presentation_validation_frame(&host_rt, nil, &presenter, device, host_target, w, h, download, host_pixels)
	if !standalone_ok || !hosted_ok { presentation_validation_fail("post-input pixel readback failed") }
	different, max_delta = presentation_validation_compare(standalone_pixels, host_pixels)
	if different != 0 { presentation_validation_fail("post-input compositor pixels differ") }
	fmt.println("issue_162_pixels", "state=post-input", "different_bytes", different, "max_delta", max_delta,
		"standalone_hash", presentation_validation_hash(standalone_pixels), "hosted_hash", presentation_validation_hash(host_pixels))

	// Compare warmed encoding work and GPU submits with alternating path order.
	standalone_allocations_before_samples := allocations.persistent_alloc_calls
	hosted_allocations_before_samples := host_allocations.persistent_alloc_calls
	standalone_frees_before_samples := allocations.persistent_free_calls
	hosted_frees_before_samples := host_allocations.persistent_free_calls
	standalone_live_bytes_before_samples := allocations.persistent_requested_bytes_live
	hosted_live_bytes_before_samples := host_allocations.persistent_requested_bytes_live
	standalone_ns_total, hosted_ns_total: i64
	for sample in 0..<PRESENTATION_VALIDATION_COST_SAMPLES {
		if sample%2 == 0 {
			a, a_ok := presentation_validation_frame(&rt, &renderers, nil, device, target, w, h)
			b, b_ok := presentation_validation_frame(&host_rt, nil, &presenter, device, host_target, w, h)
			if !a_ok || !b_ok { presentation_validation_fail("matched frame sample failed") }
			standalone_ns_total += a
			hosted_ns_total += b
		} else {
			b, b_ok := presentation_validation_frame(&host_rt, nil, &presenter, device, host_target, w, h)
			a, a_ok := presentation_validation_frame(&rt, &renderers, nil, device, target, w, h)
			if !a_ok || !b_ok { presentation_validation_fail("matched frame sample failed") }
			standalone_ns_total += a
			hosted_ns_total += b
		}
	}
	stats := alicorn.frame_stats_snapshot(&rt)
	host_stats := alicorn.frame_stats_snapshot(&host_rt)
	if stats.gpu_submits != host_stats.gpu_submits { presentation_validation_fail("standalone and hosted GPU submission counts differ") }
	fmt.println("issue_162_cost", "samples", PRESENTATION_VALIDATION_COST_SAMPLES,
		"standalone_encode_mean_ns", standalone_ns_total/PRESENTATION_VALIDATION_COST_SAMPLES,
		"hosted_encode_mean_ns", hosted_ns_total/PRESENTATION_VALIDATION_COST_SAMPLES,
		"standalone_gpu_submits", stats.gpu_submits, "hosted_gpu_submits", host_stats.gpu_submits,
		"standalone_runtime_allocs_total", allocations.persistent_alloc_calls,
		"hosted_runtime_allocs_total", host_allocations.persistent_alloc_calls,
		"standalone_runtime_allocs_during_samples", allocations.persistent_alloc_calls-standalone_allocations_before_samples,
		"hosted_runtime_allocs_during_samples", host_allocations.persistent_alloc_calls-hosted_allocations_before_samples,
		"standalone_runtime_frees_during_samples", allocations.persistent_free_calls-standalone_frees_before_samples,
		"hosted_runtime_frees_during_samples", host_allocations.persistent_free_calls-hosted_frees_before_samples,
		"standalone_live_bytes_delta", allocations.persistent_requested_bytes_live-standalone_live_bytes_before_samples,
		"hosted_live_bytes_delta", host_allocations.persistent_requested_bytes_live-hosted_live_bytes_before_samples)

	// A host waits on native events while the settled UI remains clean.
	allocations_before_idle := allocations.persistent_alloc_calls
	host_allocations_before_idle := host_allocations.persistent_alloc_calls
	submits_before_idle := rt.stats.gpu_submits
	host_submits_before_idle := host_rt.stats.gpu_submits
	if alicorn.frame_needs_submission(&rt) || alicorn.frame_needs_submission(&host_rt) { presentation_validation_fail("settled display still needs a GPU submission") }
	sdl3.FlushEvents(sdl3.EventType.FIRST, sdl3.EventType.LAST)
	idle_events := 0
	idle_start := time.now()
	event: sdl3.Event
	if sdl3.WaitEventTimeout(&event, PRESENTATION_VALIDATION_IDLE_MS) { idle_events += 1 }
	idle_ms := time.duration_milliseconds(time.since(idle_start))
	if rt.stats.gpu_submits != submits_before_idle || host_rt.stats.gpu_submits != host_submits_before_idle ||
		allocations.persistent_alloc_calls != allocations_before_idle || host_allocations.persistent_alloc_calls != host_allocations_before_idle ||
		alicorn.frame_needs_submission(&rt) || alicorn.frame_needs_submission(&host_rt) {
		presentation_validation_fail("idle wait allocated, invalidated, or submitted another frame")
	}
	fmt.println("issue_162_idle", "wait_ms", idle_ms, "events", idle_events, "submits_delta", rt.stats.gpu_submits-submits_before_idle,
		"standalone_allocs_delta", allocations.persistent_alloc_calls-allocations_before_idle,
		"hosted_allocs_delta", host_allocations.persistent_alloc_calls-host_allocations_before_idle, "status", "PASS")

	// Destroy with queued submissions before releasing the borrowed Runtime or
	// device. The API itself retires every still-owned fence.
	for _ in 0..<PRESENTATION_VALIDATION_LIFETIME_FRAMES {
		command := sdl3.AcquireGPUCommandBuffer(device)
		if command == nil { presentation_validation_fail("lifetime command buffer acquisition failed") }
		if !Sdl_GPU_Presenter_Encode(&presenter, command, host_target, w, h, 1, 1, clear_background=true) {
			_ = sdl3.CancelGPUCommandBuffer(command)
			_ = Sdl_GPU_Presenter_Cancel_Frame(&presenter)
			presentation_validation_fail("lifetime frame encoding failed")
		}
		fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
		if fence == nil { presentation_validation_fail("lifetime submission failed") }
		if _, accepted := Sdl_GPU_Presenter_Submission_Succeeded(&presenter, fence); !accepted {
			fences := [1]^sdl3.GPUFence{fence}
			_ = sdl3.WaitForGPUFences(device, true, &fences[0], 1)
			sdl3.ReleaseGPUFence(device, fence)
			presentation_validation_fail("presenter rejected a submitted lifetime frame")
		}
	}
	state := sdl_gpu_presenter_state(&presenter)
	pending_before_destroy := len(state.in_flight)
	if !Sdl_GPU_Presenter_Destroy(&presenter) || presenter.state != nil { presentation_validation_fail("presenter did not retire resources on Destroy") }
	if !sdl3.WaitForGPUIdle(device) { presentation_validation_fail("GPU did not idle after presenter Destroy") }
	presenter = {}
	fmt.println("issue_162_lifetime", "queued_frames", PRESENTATION_VALIDATION_LIFETIME_FRAMES, "fences_pending_before_destroy", pending_before_destroy,
		"presenter_state_after_destroy", "nil", "gpu_idle", "PASS")

	// The standalone host waits for its fence before destroying renderers.
	command := sdl3.AcquireGPUCommandBuffer(device)
	if command == nil { presentation_validation_fail("standalone teardown command acquisition failed") }
	view, view_ok := alicorn.paint_display_list(&rt)
	if !view_ok || !draw_display_list(command, target, w, h, &renderers.text, &renderers.surface, &renderers.solid, view.commands, 1, 1, clear_background=true) {
		_ = sdl3.CancelGPUCommandBuffer(command)
		presentation_validation_fail("standalone teardown draw failed")
	}
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	if fence == nil { presentation_validation_fail("standalone teardown submit failed") }
	native_text_commit_submission(&renderers.text)
	native_surface_commit_submission(&renderers.surface)
	native_solid_commit_submission(&renderers.solid)
	fences := [1]^sdl3.GPUFence{fence}
	if !sdl3.WaitForGPUFences(device, true, &fences[0], 1) { presentation_validation_fail("standalone host did not wait before teardown") }
	sdl3.ReleaseGPUFence(device, fence)
	presentation_validation_renderers_destroy(&renderers)
	alicorn.destroy_runtime(&host_rt)
	alicorn.destroy_runtime(&rt)
	if !sdl3.WaitForGPUIdle(device) { presentation_validation_fail("GPU did not idle after standalone teardown") }
	fmt.println("issue_162_resource_order", "presenter_then_runtime_then_device", "PASS", "standalone_wait_then_renderer_then_runtime_then_device", "PASS")
	fmt.println("issue_162_validation", "RESULT", "PASS", "backend", sdl3.GetGPUDeviceDriver(device), "host=Windows")
}
