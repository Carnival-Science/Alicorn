package alicorn_sdl_gpu

// RunPresentationBoundaryValidation compares the ordinary SDL_GPU host path
// with the public host-owned presenter on the active SDL_GPU backend.

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
	query: alicorn.Text_Field_Buffer,
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

presentation_validation_fail_204 :: proc(message: string) -> ! {
	fmt.eprintln("issue_204_validation", "FAIL", message, "SDL", sdl3.GetError())
	os.exit(1)
}

presentation_validation_value :: proc(app: ^Presentation_Validation_App) -> string {
	if app == nil { return "" }
	return app.query.text
}

presentation_validation_set_value :: proc(app: ^Presentation_Validation_App, value: string) {
	if app == nil || !alicorn.text_field_buffer_set(&app.query, value) {
		presentation_validation_fail("fixture controlled query could not be updated")
	}
}

presentation_validation_render :: proc(app: ^Presentation_Validation_App, ui: ^alicorn.UI) {
	alicorn.container_begin(ui, .Container, label="comparison panel", key=alicorn.key_string("issue-162.panel"),
		style=alicorn.layout_style(.Column, grow=1, padding=16, gap=10, clip=true),
		color=alicorn.Color{0.12, 0.15, 0.20, 1})
	alicorn.text(ui, "Host-owned SDL_GPU frame boundary", key=alicorn.key_string("issue-162.title"), style=alicorn.layout_style(height=28))
	alicorn.text(ui, "Flat surface, retained text, pointer focus, and text input.", key=alicorn.key_string("issue-162.description"), style=alicorn.layout_style(height=24))
	app.field = alicorn.text_field_controlled(
		ui, &app.query,
		key=alicorn.key_string("issue-162.field"),
		style=alicorn.layout_style(height=38),
	).node
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

presentation_validation_bright_text_pixels :: proc(
	pixels: []u8,
	width, height: int,
	bounds: alicorn.Rect,
	scale: f32,
) -> int {
	if len(pixels) < width*height*4 || width <= 0 || height <= 0 || scale <= 0 { return 0 }
	x0 := clamp(int(bounds.x*scale), 0, width)
	y0 := clamp(int(bounds.y*scale), 0, height)
	x1 := clamp(int((bounds.x+bounds.w)*scale+1), x0, width)
	y1 := clamp(int((bounds.y+bounds.h)*scale+1), y0, height)
	count := 0
	for y in y0..<y1 {
		for x in x0..<x1 {
			i := (y*width+x)*4
			if pixels[i] > 120 && pixels[i+1] > 120 && pixels[i+2] > 120 { count += 1 }
		}
	}
	return count
}

presentation_validation_changed_pixels_in_rect :: proc(
	before, after: []u8,
	width, height: int,
	bounds: alicorn.Rect,
	scale: f32,
) -> int {
	if len(before) < width*height*4 || len(after) < width*height*4 || width <= 0 || height <= 0 || scale <= 0 { return 0 }
	x0 := clamp(int(bounds.x*scale), 0, width)
	y0 := clamp(int(bounds.y*scale), 0, height)
	x1 := clamp(int((bounds.x+bounds.w)*scale+1), x0, width)
	y1 := clamp(int((bounds.y+bounds.h)*scale+1), y0, height)
	count := 0
	for y in y0..<y1 {
		for x in x0..<x1 {
			i := (y*width+x)*4
			if before[i] != after[i] || before[i+1] != after[i+1] ||
			   before[i+2] != after[i+2] || before[i+3] != after[i+3] {
				count += 1
			}
		}
	}
	return count
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
	scale_x: f32 = 1,
	scale_y: f32 = 1,
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
		if !Sdl_GPU_Presenter_Encode(presenter, command, target, width, height, scale_x, scale_y, clear_background=true) { return 0, false }
	} else {
		view, view_ok := alicorn.paint_display_list(rt)
		if !view_ok || r == nil || !draw_display_list(command, target, width, height, &r.text, &r.surface, &r.solid, view.commands, scale_x, scale_y, clear_background=true) {
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

presentation_validation_read_texture :: proc(
	device: ^sdl3.GPUDevice,
	target: ^sdl3.GPUTexture,
	width, height: sdl3.Uint32,
	download: ^sdl3.GPUTransferBuffer,
	pixels: []u8,
) -> bool {
	byte_count := int(width*height*4)
	if device == nil || target == nil || download == nil || width == 0 || height == 0 || len(pixels) < byte_count {
		return false
	}
	command := sdl3.AcquireGPUCommandBuffer(device)
	if command == nil { return false }
	submitted := false
	defer if !submitted { _ = sdl3.CancelGPUCommandBuffer(command) }
	copy_pass := sdl3.BeginGPUCopyPass(command)
	if copy_pass == nil { return false }
	sdl3.DownloadFromGPUTexture(
		copy_pass,
		sdl3.GPUTextureRegion{texture=target, w=width, h=height, d=1},
		sdl3.GPUTextureTransferInfo{transfer_buffer=download, pixels_per_row=width, rows_per_layer=height},
	)
	sdl3.EndGPUCopyPass(copy_pass)
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	submitted = true
	if fence == nil { return false }
	fences := [1]^sdl3.GPUFence{fence}
	ok := sdl3.WaitForGPUFences(device, true, &fences[0], 1)
	sdl3.ReleaseGPUFence(device, fence)
	if !ok { return false }
	mapped := sdl3.MapGPUTransferBuffer(device, download, false)
	if mapped == nil { return false }
	copy(pixels[:byte_count], (cast([^]u8)mapped)[:byte_count])
	sdl3.UnmapGPUTransferBuffer(device, download)
	return true
}

presentation_validation_mark_pending :: proc(
	rt: ^alicorn.Runtime,
	app: ^Presentation_Validation_App,
) {
	alicorn.invalidate_root(rt, "issue-204 failure-injection retry")
	if !presentation_validation_build(rt, app) || !alicorn.frame_needs_submission(rt) {
		presentation_validation_fail_204("fixture did not create a pending Runtime revision")
	}
}

presentation_validation_submit_window_frame :: proc(
	presenter: ^Sdl_GPU_Presenter,
	device: ^sdl3.GPUDevice,
	window: ^sdl3.Window,
	scale_x, scale_y: f32,
) {
	command := sdl3.AcquireGPUCommandBuffer(device)
	if command == nil { presentation_validation_fail_204("window command-buffer acquisition failed") }
	if !Sdl_GPU_Presenter_Encode_Window(presenter, command, window, scale_x, scale_y) {
		state := sdl_gpu_presenter_state(presenter)
		if state != nil && state.swapchain_acquired {
			// Never cancel here: SDL forbids cancellation after swapchain acquire.
			presentation_validation_fail_204("window encoding failed after acquiring the swapchain target")
		}
		command_canceled := sdl3.CancelGPUCommandBuffer(command)
		frame_canceled := Sdl_GPU_Presenter_Cancel_Frame(presenter)
		if !command_canceled || !frame_canceled {
			presentation_validation_fail_204("pre-acquisition window failure could not be canceled")
		}
		presentation_validation_fail_204("window frame preparation or swapchain acquisition failed")
	}
	state := sdl_gpu_presenter_state(presenter)
	if state == nil || !state.swapchain_acquired {
		presentation_validation_fail_204("successful window encoding did not record swapchain ownership")
	}
	if Sdl_GPU_Presenter_Cancel_Frame(presenter) {
		presentation_validation_fail_204("presenter allowed cancellation after swapchain acquisition")
	}
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	if fence == nil {
		// The command has acquired the swapchain. There is no safe cancel path.
		presentation_validation_fail_204("window command-buffer submission failed after swapchain acquisition")
	}
	submission, accepted := Sdl_GPU_Presenter_Submission_Succeeded(presenter, fence)
	if !accepted {
		fences := [1]^sdl3.GPUFence{fence}
		_ = sdl3.WaitForGPUFences(device, true, &fences[0], 1)
		sdl3.ReleaseGPUFence(device, fence)
		presentation_validation_fail_204("presenter rejected the submitted window frame")
	}
	if !Sdl_GPU_Presenter_Wait(presenter, submission) {
		presentation_validation_fail_204("window frame fence did not retire")
	}
}

Presentation_Validation_Resource_Snapshot :: struct {
	text_vertex_capacity: int,
	text_atlas_pages: int,
	solid_vertex_capacity: int,
	icon_vertex_capacity: int,
	image_vertex_capacity: int,
	image_texture_count: int,
	surface_resource_creations: u64,
}

presentation_validation_resource_snapshot :: proc(
	state: ^sdl_gpu_presenter_internal_state,
) -> Presentation_Validation_Resource_Snapshot {
	return Presentation_Validation_Resource_Snapshot{
		text_vertex_capacity=state.text.vertex_capacity,
		text_atlas_pages=len(state.text.pages),
		solid_vertex_capacity=state.solid.vertex_capacity,
		icon_vertex_capacity=state.solid.icons.vertex_capacity,
		image_vertex_capacity=state.solid.images.vertex_capacity,
		image_texture_count=len(state.solid.images.images),
		surface_resource_creations=state.surface.resource_creations,
	}
}

presentation_validation_failure_case :: proc(
	presenter: ^Sdl_GPU_Presenter,
	rt: ^alicorn.Runtime,
	app: ^Presentation_Validation_App,
	device: ^sdl3.GPUDevice,
	target: ^sdl3.GPUTexture,
	width, height: sdl3.Uint32,
	scale_x, scale_y: f32,
	download: ^sdl3.GPUTransferBuffer,
	failure_point: presenter_encode_failure_point,
	case_name: string,
	window: ^sdl3.Window = nil,
) {
	byte_count := int(width*height*4)
	previous := make([]u8, byte_count)
	after_failure := make([]u8, byte_count)
	if previous == nil || after_failure == nil ||
		!presentation_validation_read_texture(device, target, width, height, download, previous) {
		presentation_validation_fail_204("could not capture the previous target contents")
	}
	presentation_validation_mark_pending(rt, app)
	state := sdl_gpu_presenter_state(presenter)
	in_flight_before := len(state.in_flight)
	resources_before := presentation_validation_resource_snapshot(state)
	command := sdl3.AcquireGPUCommandBuffer(device)
	if command == nil { presentation_validation_fail_204("failure-injection command-buffer acquisition failed") }
	encoded := false
	if window == nil {
		encoded = sdl_gpu_presenter_encode_with_failure(
			presenter, command, target, width, height, scale_x, scale_y, true, failure_point,
		)
	} else {
		encoded = sdl_gpu_presenter_encode_window_with_failure(
			presenter, command, window, scale_x, scale_y, failure_point,
		)
	}
	if encoded { presentation_validation_fail_204("injected encode failure unexpectedly succeeded") }
	if state.swapchain_acquired {
		// Keep this branch fatal without calling SDL_CancelGPUCommandBuffer.
		presentation_validation_fail_204("injected pre-acquisition failure acquired a swapchain target")
	}
	if !state.frame_pending || !alicorn.frame_needs_submission(rt) {
		presentation_validation_fail_204("failed frame was acknowledged or lost its pending presenter state")
	}
	if !sdl3.CancelGPUCommandBuffer(command) || !Sdl_GPU_Presenter_Cancel_Frame(presenter) {
		presentation_validation_fail_204("offscreen failed frame could not be rolled back")
	}
	if !alicorn.frame_needs_submission(rt) || state.frame_pending || state.swapchain_acquired || len(state.in_flight) != in_flight_before {
		presentation_validation_fail_204("rollback changed Runtime acknowledgement or presenter fence state")
	}
	if presentation_validation_resource_snapshot(state) != resources_before {
		presentation_validation_fail_204("failed encoding changed presenter resource capacities or registrations")
	}
	if !presentation_validation_read_texture(device, target, width, height, download, after_failure) {
		presentation_validation_fail_204("could not read the target after canceling the failed frame")
	}
	different, max_delta := presentation_validation_compare(previous, after_failure)
	if different != 0 {
		presentation_validation_fail_204("canceling a partial frame changed the previous target contents")
	}
	if window == nil {
		_, ok := presentation_validation_frame(rt, nil, presenter, device, target, width, height)
		if !ok { presentation_validation_fail_204("offscreen retry did not submit successfully") }
	} else {
		presentation_validation_submit_window_frame(presenter, device, window, scale_x, scale_y)
	}
	if alicorn.frame_needs_submission(rt) || state.frame_pending || state.swapchain_acquired {
		presentation_validation_fail_204("valid retry did not consume the pending Runtime revision")
	}
	if presentation_validation_resource_snapshot(state) != resources_before {
		presentation_validation_fail_204("valid retry grew presenter resources after the fixture was warmed")
	}
	fmt.println("issue_204_failure", "case", case_name, "failure_point", failure_point,
		"target_bytes_changed", different, "max_delta", max_delta,
		"fences_after_failure", in_flight_before, "resources_stable", true, "retry", "PASS")
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
	if !sdl3.ShowWindow(window) { presentation_validation_fail_204("window could not be shown for swapchain-path validation") }
	window_pixel_width, window_pixel_height: c.int
	if !sdl3.GetWindowSizeInPixels(window, &window_pixel_width, &window_pixel_height) ||
		window_pixel_width <= 0 || window_pixel_height <= 0 {
		presentation_validation_fail_204("shown validation window has no drawable pixel size")
	}
	window_width, window_height := sdl3.Uint32(window_pixel_width), sdl3.Uint32(window_pixel_height)
	w, h := PRESENTATION_VALIDATION_WIDTH, PRESENTATION_VALIDATION_HEIGHT
	target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{type=.D2, format=format, usage={.COLOR_TARGET}, width=w, height=h, layer_count_or_depth=1, num_levels=1, sample_count=._1})
	if target == nil { presentation_validation_fail("standalone target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, target)
	host_target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{type=.D2, format=format, usage={.COLOR_TARGET}, width=w, height=h, layer_count_or_depth=1, num_levels=1, sample_count=._1})
	if host_target == nil { presentation_validation_fail("host-owned target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, host_target)
	scaled_width, scaled_height := sdl3.Uint32(w*5/4), sdl3.Uint32(h*5/4)
	scaled_target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{type=.D2, format=format, usage={.COLOR_TARGET}, width=scaled_width, height=scaled_height, layer_count_or_depth=1, num_levels=1, sample_count=._1})
	if scaled_target == nil { presentation_validation_fail("fractional-scale standalone target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, scaled_target)
	scaled_host_target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{type=.D2, format=format, usage={.COLOR_TARGET}, width=scaled_width, height=scaled_height, layer_count_or_depth=1, num_levels=1, sample_count=._1})
	if scaled_host_target == nil { presentation_validation_fail("fractional-scale host-owned target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, scaled_host_target)
	download_size := max(u32(scaled_width*scaled_height*4), u32(window_width*window_height*4))
	download := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{usage=.DOWNLOAD, size=download_size})
	if download == nil { presentation_validation_fail("pixel readback buffer creation failed") }
	defer sdl3.ReleaseGPUTransferBuffer(device, download)

	app := Presentation_Validation_App{}
	app_query, app_query_ok := alicorn.text_field_buffer_init("editable input", context.allocator)
	if !app_query_ok { presentation_validation_fail("standalone controlled query initialization failed") }
	app.query = app_query
	defer alicorn.text_field_buffer_destroy(&app.query)
	host_app := Presentation_Validation_App{}
	host_query, host_query_ok := alicorn.text_field_buffer_init("editable input", context.allocator)
	if !host_query_ok { presentation_validation_fail("host-owned controlled query initialization failed") }
	host_app.query = host_query
	defer alicorn.text_field_buffer_destroy(&host_app.query)
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
	scaled_pixel_count := int(scaled_width*scaled_height*4)
	scaled_standalone_pixels := make([]u8, scaled_pixel_count)
	scaled_host_pixels := make([]u8, scaled_pixel_count)
	empty_standalone_pixels := make([]u8, scaled_pixel_count)
	empty_host_pixels := make([]u8, scaled_pixel_count)
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

	// Exercise the window-present path on a drawable window. Once a non-nil
	// swapchain target has been acquired, cancellation is rejected by the
	// presenter and the caller must submit the command buffer.
	window_scale_x, window_scale_y := f32(window_width)/f32(w), f32(window_height)/f32(h)
	presentation_validation_mark_pending(&host_rt, &host_app)
	presentation_validation_submit_window_frame(&presenter, device, window, window_scale_x, window_scale_y)
	window_state := sdl_gpu_presenter_state(&presenter)
	if window_state == nil || window_state.window_target == nil ||
		window_state.window_target_width != window_width || window_state.window_target_height != window_height {
		presentation_validation_fail_204("window frame did not create its expected intermediate target")
	}
	window_byte_count := int(window_width*window_height*4)
	window_pixels := make([]u8, window_byte_count)
	if window_pixels == nil || !presentation_validation_read_texture(
		device, window_state.window_target, window_width, window_height, download, window_pixels,
	) {
		presentation_validation_fail_204("window intermediate target readback failed")
	}
	fmt.println("issue_204_window", "swapchain_acquired", "true", "target", window_width, "x", window_height,
		"prior_frame_hash", presentation_validation_hash(window_pixels), "status", "PASS")

	// A failure before renderer work and a failure after background-clear
	// commands have been recorded must both be cancellable before swapchain
	// acquisition. Verify target preservation and then retry each revision.
	presentation_validation_failure_case(
		&presenter, &host_rt, &host_app, device, host_target, w, h, 1, 1,
		download, .Before_Render, "offscreen-before-render",
	)
	presentation_validation_failure_case(
		&presenter, &host_rt, &host_app, device, host_target, w, h, 1, 1,
		download, .After_Background_Clear, "offscreen-after-clear",
	)
	presentation_validation_failure_case(
		&presenter, &host_rt, &host_app, device, window_state.window_target,
		window_width, window_height, window_scale_x, window_scale_y,
		download, .Before_Render, "window-before-render", window=window,
	)
	presentation_validation_failure_case(
		&presenter, &host_rt, &host_app, device, window_state.window_target,
		window_width, window_height, window_scale_x, window_scale_y,
		download, .After_Background_Clear, "window-after-clear", window=window,
	)

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
	alicorn.text_change_destroy(&rt, &change)
	alicorn.text_change_destroy(&host_rt, &host_change)
	if !presentation_validation_build(&rt, &app) || !presentation_validation_build(&host_rt, &host_app) { presentation_validation_fail("Runtime did not rebuild after committed text input") }
	value, value_ok := alicorn.text_field_value(&rt, app.field)
	host_value, host_value_ok := alicorn.text_field_value(&host_rt, host_app.field)
	if !value_ok || value != "e-hostditable input" || presentation_validation_value(&app) != value {
		presentation_validation_fail("controlled text input was not adopted at the selected caret position")
	}
	interaction, interaction_ok := alicorn.text_field_interaction(&rt, app.field)
	host_interaction, host_interaction_ok := alicorn.text_field_interaction(&host_rt, host_app.field)
	if !host_value_ok || value != host_value || presentation_validation_value(&host_app) != host_value ||
		!interaction_ok || !host_interaction_ok || interaction.caret != host_interaction.caret ||
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

	// Exercise the controlled-field cache path that exposed the missing-glyph
	// defect. Read both an empty field and the same field after a committed edit
	// through SDL_GPU at 1.25x, then require visible glyph pixels in its bounds.
	presentation_validation_set_value(&app, "")
	presentation_validation_set_value(&host_app, "")
	alicorn.invalidate_root(&rt, "controlled query empty-field pixel baseline")
	alicorn.invalidate_root(&host_rt, "controlled query empty-field pixel baseline")
	if !presentation_validation_build(&rt, &app) || !presentation_validation_build(&host_rt, &host_app) {
		presentation_validation_fail("empty controlled-field baseline did not rebuild")
	}
	_ = alicorn.set_text_caret(&rt, app.field, 0)
	_ = alicorn.set_text_caret(&host_rt, host_app.field, 0)
	_, standalone_ok = presentation_validation_frame(
		&rt, &renderers, nil, device, scaled_target, scaled_width, scaled_height,
		download, empty_standalone_pixels, scale_x=1.25, scale_y=1.25,
	)
	_, hosted_ok = presentation_validation_frame(
		&host_rt, nil, &presenter, device, scaled_host_target, scaled_width, scaled_height,
		download, empty_host_pixels, scale_x=1.25, scale_y=1.25,
	)
	if !standalone_ok || !hosted_ok { presentation_validation_fail("fractional-scale empty-field readback failed") }
	different, _ = presentation_validation_compare(empty_standalone_pixels, empty_host_pixels)
	if different != 0 { presentation_validation_fail("fractional-scale empty-field host pixels differ") }
	query_change := alicorn.process_text_input(&rt, app.field, "browse")
	host_query_change := alicorn.process_text_input(&host_rt, host_app.field, "browse")
	alicorn.text_change_destroy(&rt, &query_change)
	alicorn.text_change_destroy(&host_rt, &host_query_change)
	if !presentation_validation_build(&rt, &app) || !presentation_validation_build(&host_rt, &host_app) {
		presentation_validation_fail("committed controlled query did not rebuild")
	}
	query_value, query_value_ok := alicorn.text_field_value(&rt, app.field)
	host_query_value, host_query_value_ok := alicorn.text_field_value(&host_rt, host_app.field)
	if !query_value_ok || !host_query_value_ok || query_value != "browse" || host_query_value != query_value ||
	   presentation_validation_value(&app) != query_value || presentation_validation_value(&host_app) != query_value {
		presentation_validation_fail("controlled query value was not adopted before pixel readback")
	}
	_, standalone_ok = presentation_validation_frame(
		&rt, &renderers, nil, device, scaled_target, scaled_width, scaled_height,
		download, scaled_standalone_pixels, scale_x=1.25, scale_y=1.25,
	)
	_, hosted_ok = presentation_validation_frame(
		&host_rt, nil, &presenter, device, scaled_host_target, scaled_width, scaled_height,
		download, scaled_host_pixels, scale_x=1.25, scale_y=1.25,
	)
	if !standalone_ok || !hosted_ok { presentation_validation_fail("fractional-scale edited-field readback failed") }
	different, max_delta = presentation_validation_compare(scaled_standalone_pixels, scaled_host_pixels)
	if different != 0 { presentation_validation_fail("fractional-scale edited-field host pixels differ") }
	query_node, query_node_ok := alicorn.node_info(&rt, app.field)
	visible_text_pixels := presentation_validation_bright_text_pixels(
		scaled_standalone_pixels, int(scaled_width), int(scaled_height), query_node.bounds, 1.25,
	)
	changed_field_pixels := presentation_validation_changed_pixels_in_rect(
		empty_standalone_pixels, scaled_standalone_pixels,
		int(scaled_width), int(scaled_height), query_node.bounds, 1.25,
	)
	if !query_node_ok || visible_text_pixels < 40 || changed_field_pixels < 40 {
		presentation_validation_fail("committed controlled query has no visible glyph pixels at 1.25x")
	}
	fmt.println("controlled_text_sdl_gpu_readback", "query", query_value, "scale", "1.25x",
		"visible_text_pixels", visible_text_pixels, "changed_field_pixels", changed_field_pixels,
		"standalone_host_byte_difference", different, "status", "PASS")

	// Compare warmed encoding work and GPU submits with alternating path order.
	standalone_allocations_before_samples := allocations.persistent_alloc_calls
	hosted_allocations_before_samples := host_allocations.persistent_alloc_calls
	standalone_frees_before_samples := allocations.persistent_free_calls
	hosted_frees_before_samples := host_allocations.persistent_free_calls
	standalone_live_bytes_before_samples := allocations.persistent_requested_bytes_live
	hosted_live_bytes_before_samples := host_allocations.persistent_requested_bytes_live
	standalone_submits_before_samples := rt.stats.gpu_submits
	hosted_submits_before_samples := host_rt.stats.gpu_submits
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
	standalone_sample_submits := stats.gpu_submits - standalone_submits_before_samples
	hosted_sample_submits := host_stats.gpu_submits - hosted_submits_before_samples
	if standalone_sample_submits != hosted_sample_submits { presentation_validation_fail("standalone and hosted GPU submission deltas differ") }
	fmt.println("issue_162_cost", "samples", PRESENTATION_VALIDATION_COST_SAMPLES,
		"standalone_encode_mean_ns", standalone_ns_total/PRESENTATION_VALIDATION_COST_SAMPLES,
		"hosted_encode_mean_ns", hosted_ns_total/PRESENTATION_VALIDATION_COST_SAMPLES,
		"standalone_gpu_submits", standalone_sample_submits, "hosted_gpu_submits", hosted_sample_submits,
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
	fmt.println("issue_162_validation", "RESULT", "PASS", "backend", sdl3.GetGPUDeviceDriver(device), "host=SDL_GPU")
	fmt.println("issue_204_validation", "RESULT", "PASS", "backend", sdl3.GetGPUDeviceDriver(device),
		"swapchain_safe_failure_rollback", "PASS", "valid_retry", "PASS")
}
