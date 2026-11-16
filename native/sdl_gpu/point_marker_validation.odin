package alicorn_sdl_gpu

// Focused GPU readback and cost validation for issue #201's compact retained
// point markers. This exercises Alicorn's production SDL_GPU surface renderer.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import alicorn "../../runtime"
import "vendor:sdl3"

POINT_MARKER_VALIDATION_HEIGHT :: 40
POINT_MARKER_VALIDATION_SAMPLES :: 64
POINT_MARKER_VALIDATION_ORACLE_GRID :: 8

Point_Marker_Validation_Size :: enum { Three, Four }
Point_Marker_Validation_Renderers :: struct {
	text: Native_Text_Renderer,
	geometry: Native_Surface_Renderer,
	solid: Native_Solid_Renderer,
}

point_marker_validation_fail :: proc(message: string) -> ! {
	fmt.eprintln("issue_201_point_marker_validation", "FAIL", message, "SDL", sdl3.GetError())
	os.exit(1)
}

point_marker_validation_trace :: proc(enabled: bool, stage: string) {
	if enabled { fmt.println("issue_201_trace", "stage", stage) }
}

point_marker_validation_percentile :: proc(values: []i64, percentile: f32) -> i64 {
	if len(values) == 0 { return 0 }
	sorted := make([]i64, len(values), allocator=context.temp_allocator)
	copy(sorted, values)
	for i in 1..<len(sorted) {
		value := sorted[i]
		j := i-1
		for j >= 0 && sorted[j] > value {
			sorted[j+1] = sorted[j]
			j -= 1
		}
		sorted[j+1] = value
	}
	index := int(math.ceil(f32(len(sorted))*percentile))-1
	return sorted[clamp(index, 0, len(sorted)-1)]
}

point_marker_validation_renderers_make :: proc(
	device: ^sdl3.GPUDevice,
	format: sdl3.GPUTextureFormat,
	rt: ^alicorn.Runtime,
) -> (renderers: Point_Marker_Validation_Renderers, ok: bool) {
	renderers.text, ok = native_text_make(device, format, rt)
	if !ok { return }
	renderers.geometry, ok = native_surface_make(device, format, rt)
	if !ok { native_text_destroy(&renderers.text); return }
	renderers.solid, ok = native_solid_make(device, format, rt)
	if !ok {
		native_surface_destroy(&renderers.geometry)
		native_text_destroy(&renderers.text)
		return renderers, false
	}
	return renderers, true
}

point_marker_validation_renderers_destroy :: proc(renderers: ^Point_Marker_Validation_Renderers) {
	if renderers == nil { return }
	native_solid_destroy(&renderers.solid)
	native_surface_destroy(&renderers.geometry)
	native_text_destroy(&renderers.text)
	renderers^ = {}
}

point_marker_validation_create_runtime :: proc(
	rt: ^alicorn.Runtime,
	logical_width: int,
	marker_size: Point_Marker_Validation_Size,
	trace: bool,
) -> (surface: alicorn.Node_ID, ok: bool) {
	if rt == nil { return 0, false }
	point_marker_validation_trace(trace, "fonts-load")
	if !alicorn.text_engine_load_default_fonts(rt) { return 0, false }
	point_marker_validation_trace(trace, "fonts-ready")
	alicorn.invalidate_root(rt, "issue #201 dense marker readback")
	point_marker_validation_trace(trace, "root-invalidated")
	ui, build := alicorn.begin_frame(rt)
	if !build { return 0, false }
	point_marker_validation_trace(trace, "frame-begun")
	alicorn.container_begin(&ui, .Root, label="issue-201-root", key=alicorn.key_string("issue-201-root"),
		style=alicorn.layout_style(.Column, width=f32(logical_width), height=POINT_MARKER_VALIDATION_HEIGHT))
	surface = alicorn.gpu_geometry_surface(&ui, "issue-201-markers",
		alicorn.layout_style(width=f32(logical_width), height=POINT_MARKER_VALIDATION_HEIGHT), 1)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	point_marker_validation_trace(trace, "description-finished")

	count := (logical_width-1)/3 + 1
	segments := make([]alicorn.GPU_Surface_Line_Segment, count-1, allocator=context.temp_allocator)
	markers := make([]alicorn.GPU_Surface_Point_Marker, count+2, allocator=context.temp_allocator)
	for i in 0..<len(segments) {
		segments[i] = alicorn.GPU_Surface_Line_Segment{
			start={f32(i*3), 33}, end={f32((i+1)*3), 33}, thickness=1,
			color={0.2, 0.75, 0.95, 1},
		}
	}
	for i in 0..<count {
		diameter := f32(3) if marker_size == .Three else f32(4)
		markers[i] = alicorn.GPU_Surface_Point_Marker{
			center={f32(i*3), 16}, diameter=diameter, color={1, 1, 1, 1},
		}
	}
	// Two extra samples exercise surface clipping at both horizontal edges.
	markers[count+0] = {center={-1, 1}, diameter=4, color={1, 1, 1, 1}}
	markers[count+1] = {center={f32(logical_width+1), 1}, diameter=4, color={1, 1, 1, 1}}
	if !alicorn.gpu_surface_update_geometry_with_markers(rt, surface, segments, nil, markers) {
		return surface, false
	}
	point_marker_validation_trace(trace, "payload-retained")
	return surface, true
}

point_marker_validation_frame :: proc(
	rt: ^alicorn.Runtime,
	renderers: ^Point_Marker_Validation_Renderers,
	device: ^sdl3.GPUDevice,
	target: ^sdl3.GPUTexture,
	width, height: sdl3.Uint32,
	scale: f32,
	download: ^sdl3.GPUTransferBuffer = nil,
	pixels: []u8 = nil,
) -> (encode_ns, submit_wait_ns: i64, ok: bool) {
	command := sdl3.AcquireGPUCommandBuffer(device)
	if command == nil { return 0, 0, false }
	submitted := false
	defer if !submitted { _ = sdl3.CancelGPUCommandBuffer(command) }
	started := time.now()
	view, view_ok := alicorn.paint_display_list(rt)
	clear := make_color_target(target, sdl3.FColor{0, 0, 0, 0}, false)
	clear_pass := sdl3.BeginGPURenderPass(command, &clear, 1, nil)
	if clear_pass == nil { return 0, 0, false }
	sdl3.EndGPURenderPass(clear_pass)
	if !view_ok || !draw_display_list(command, target, width, height,
		&renderers.text, &renderers.geometry, &renderers.solid, view.commands,
		scale, scale, clear_background=false) {
		return 0, 0, false
	}
	encode_ns = time.duration_nanoseconds(time.since(started))
	if download != nil {
		copy_pass := sdl3.BeginGPUCopyPass(command)
		if copy_pass == nil { return encode_ns, 0, false }
		sdl3.DownloadFromGPUTexture(copy_pass,
			{texture=target, w=width, h=height, d=1},
			{transfer_buffer=download, pixels_per_row=width, rows_per_layer=height})
		sdl3.EndGPUCopyPass(copy_pass)
	}
	submit_started := time.now()
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	submitted = true
	if fence == nil { return encode_ns, 0, false }
	defer sdl3.ReleaseGPUFence(device, fence)
	native_text_commit_submission(&renderers.text)
	native_surface_commit_submission(&renderers.geometry)
	native_solid_commit_submission(&renderers.solid)
	fences := [1]^sdl3.GPUFence{fence}
	if !sdl3.WaitForGPUFences(device, true, &fences[0], 1) { return encode_ns, 0, false }
	submit_wait_ns = time.duration_nanoseconds(time.since(submit_started))
	alicorn.gpu_surface_frame_consumed(rt)
	alicorn.frame_submission_succeeded(rt)
	rt.stats.gpu_submits += 1
	if download != nil {
		mapped := sdl3.MapGPUTransferBuffer(device, download, false)
		if mapped == nil { return encode_ns, submit_wait_ns, false }
		copy(pixels, (cast([^]u8)mapped)[:len(pixels)])
		sdl3.UnmapGPUTransferBuffer(device, download)
	}
	return encode_ns, submit_wait_ns, true
}

point_marker_validation_pixel_alpha :: proc(pixels: []u8, width, x, y: int) -> u8 {
	return pixels[(y*width+x)*4+3]
}

point_marker_validation_debug_pixels :: proc(pixels: []u8, width, height, center_x, center_y: int) {
	for y in max(0, center_y-3)..<min(height, center_y+4) {
		for x in max(0, center_x-3)..<min(width, center_x+4) {
			i := (y*width+x)*4
			fmt.println("[DEBUG-201-RB]", "x", x, "y", y,
				"rgba", pixels[i], pixels[i+1], pixels[i+2], pixels[i+3])
		}
	}
}

point_marker_validation_reference_coverage :: proc(
	markers: []alicorn.GPU_Surface_Point_Marker,
	logical_bounds: alicorn.Rect,
	scale: f32,
	pixel_x, pixel_y: int,
) -> f32 {
	coverage_left := f32(1)
	for marker in markers {
		cx := (logical_bounds.x+marker.center.x)*scale
		cy := (logical_bounds.y+marker.center.y)*scale
		radius := marker.diameter*scale*0.5
		if abs(f32(pixel_x)+0.5-cx) > radius+1 || abs(f32(pixel_y)+0.5-cy) > radius+1 { continue }
		inside := 0
		for sy in 0..<POINT_MARKER_VALIDATION_ORACLE_GRID {
			py := f32(pixel_y)+(f32(sy)+0.5)/f32(POINT_MARKER_VALIDATION_ORACLE_GRID)
			for sx in 0..<POINT_MARKER_VALIDATION_ORACLE_GRID {
				px := f32(pixel_x)+(f32(sx)+0.5)/f32(POINT_MARKER_VALIDATION_ORACLE_GRID)
				dx, dy := px-cx, py-cy
				if dx*dx+dy*dy <= radius*radius { inside += 1 }
			}
		}
		coverage := f32(inside)/f32(POINT_MARKER_VALIDATION_ORACLE_GRID*POINT_MARKER_VALIDATION_ORACLE_GRID)
		coverage_left *= 1-coverage
	}
	return 1-coverage_left
}

point_marker_validation_compare_readback :: proc(
	name: string,
	markers: []alicorn.GPU_Surface_Point_Marker,
	logical_bounds: alicorn.Rect,
	logical_width, pixel_width, pixel_height: int,
	scale: f32,
	pixels: []u8,
) -> bool {
	anchors := [6]int{0, 1, (logical_width-1)/6, (logical_width-1)/3, (logical_width-1)/3+1, len(markers)-1}
	max_delta, sum_delta, compared := 0, 0, 0
	aa_samples, covered_samples := 0, 0
	for marker_index in anchors {
		if marker_index < 0 || marker_index >= len(markers) { continue }
		marker := markers[marker_index]
		cx := (logical_bounds.x+marker.center.x)*scale
		cy := (logical_bounds.y+marker.center.y)*scale
		radius := marker.diameter*scale*0.5
		x0 := max(0, int(math.floor(cx-radius-1)))
		x1 := min(pixel_width, int(math.ceil(cx+radius+1)))
		y0 := max(0, int(math.floor(cy-radius-1)))
		y1 := min(pixel_height, int(math.ceil(cy+radius+1)))
		for y in y0..<y1 {
			for x in x0..<x1 {
				actual := int(point_marker_validation_pixel_alpha(pixels, pixel_width, x, y))
				expected := int(math.round(point_marker_validation_reference_coverage(markers, logical_bounds, scale, x, y)*255))
				delta := abs(actual-expected)
				max_delta = max(max_delta, delta)
				sum_delta += delta
				compared += 1
				if actual > 0 { covered_samples += 1 }
				if actual > 0 && actual < 255 { aa_samples += 1 }
			}
		}
	}
	mean_delta := 0 if compared == 0 else sum_delta/compared
	// The analytic area oracle is independent of the 32x32 sampled mask. Keep
	// a modest tolerance for rasterizer-specific coverage quantization while
	// requiring visible antialiasing and a close mean match.
	ok := compared > 0 && mean_delta <= 28 && aa_samples > 0 && covered_samples > 0
	fmt.println("issue_201_readback", "case", name, "scale", scale, "pixels_compared", compared,
		"mean_alpha_delta", mean_delta, "max_alpha_delta", max_delta,
		"antialiased_pixels", aa_samples, "covered_pixels", covered_samples, "status", "PASS" if ok else "FAIL")
	return ok
}

point_marker_validation_run_case :: proc(
	device: ^sdl3.GPUDevice,
	format: sdl3.GPUTextureFormat,
	logical_width: int,
	scale: f32,
	marker_size: Point_Marker_Validation_Size,
	benchmark: bool,
) {
	marker_name := "3x3" if marker_size == .Three else "4x4"
	trace := logical_width == 1280 && scale == 1 && marker_size == .Three
	point_marker_validation_trace(trace, "case-start")
	pixel_width := int(f32(logical_width)*scale)
	pixel_height := int(f32(POINT_MARKER_VALIDATION_HEIGHT)*scale)
	marker_count := (logical_width-1)/3+1
	allocations := alicorn.Runtime_Allocation_Stats{}
	rt := alicorn.new_runtime(
		alicorn.Rect{0, 0, f32(logical_width), POINT_MARKER_VALIDATION_HEIGHT},
		config=alicorn.Runtime_Config{allocation_stats=&allocations},
	)
	point_marker_validation_trace(trace, "runtime-create")
	surface, runtime_ok := point_marker_validation_create_runtime(&rt, logical_width, marker_size, trace)
	point_marker_validation_trace(trace, "runtime-ready")
	if !runtime_ok { point_marker_validation_fail("runtime fixture could not retain dense markers and lines") }
	defer if rt.persistent_allocator_state != nil { alicorn.destroy_runtime(&rt) }
	point_marker_validation_trace(trace, "renderer-create")
	renderers, renderer_ok := point_marker_validation_renderers_make(device, format, &rt)
	point_marker_validation_trace(trace, "renderer-ready")
	if !renderer_ok { point_marker_validation_fail("production surface renderer initialization failed") }
	defer if renderers.text.device != nil { point_marker_validation_renderers_destroy(&renderers) }
	point_marker_validation_trace(trace, "target-create")
	target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{
		type=.D2, format=format, usage={.COLOR_TARGET}, width=sdl3.Uint32(pixel_width),
		height=sdl3.Uint32(pixel_height), layer_count_or_depth=1, num_levels=1, sample_count=._1,
	})
	point_marker_validation_trace(trace, "target-ready")
	if target == nil { point_marker_validation_fail("offscreen marker target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, target)
	download := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{
		usage=.DOWNLOAD, size=sdl3.Uint32(pixel_width*pixel_height*4),
	})
	point_marker_validation_trace(trace, "readback-ready")
	if download == nil { point_marker_validation_fail("GPU readback buffer creation failed") }
	defer sdl3.ReleaseGPUTransferBuffer(device, download)
	pixels := make([]u8, pixel_width*pixel_height*4)
	defer delete(pixels)
	point_marker_validation_trace(trace, "first-frame-submit")
	_, _, initial_ok := point_marker_validation_frame(&rt, &renderers, device, target,
		sdl3.Uint32(pixel_width), sdl3.Uint32(pixel_height), scale, download, pixels)
	point_marker_validation_trace(trace, "first-frame-ready")
	if !initial_ok { point_marker_validation_fail("first marker readback frame failed") }
	command, found := native_surface_test_geometry_command(&rt, surface)
	if !found || !native_surface_rebuild_mesh(&renderers.geometry, command, scale, scale) {
		point_marker_validation_fail("retained mesh rebuild failed after readback")
	}
	point_marker_validation_trace(trace, "mesh-ready")
	expected_vertices := (marker_count+2 + marker_count-1)*6
	if len(renderers.geometry.vertices) != expected_vertices || expected_vertices > alicorn.GPU_SURFACE_MAX_VERTICES {
		point_marker_validation_fail("native dense marker and line mesh exceeded the bounded vertex expectation")
	}
	markers := make([]alicorn.GPU_Surface_Point_Marker, marker_count+2, allocator=context.temp_allocator)
	for i in 0..<marker_count {
		diameter := f32(3) if marker_size == .Three else f32(4)
		markers[i] = {center={f32(i*3), 16}, diameter=diameter, color={1, 1, 1, 1}}
	}
	markers[marker_count+0] = {center={-1, 1}, diameter=4, color={1, 1, 1, 1}}
	markers[marker_count+1] = {center={f32(logical_width+1), 1}, diameter=4, color={1, 1, 1, 1}}
	info, info_ok := alicorn.node_info(&rt, surface)
	point_marker_validation_trace(trace, "readback-compare")
	if trace { point_marker_validation_debug_pixels(pixels, pixel_width, pixel_height, 3, 16) }
	if !info_ok || !point_marker_validation_compare_readback(
		fmt.tprintf("%dpx-%s", logical_width, marker_name), markers,
		info.bounds, logical_width, pixel_width, pixel_height, scale, pixels,
	) { point_marker_validation_fail("native readback did not match the analytic wx-ellipse coverage reference") }
	point_marker_validation_trace(trace, "readback-passed")
	// The viewport's edge scissor must clip the auxiliary circles whose centers
	// are outside the retained geometry surface.
	if point_marker_validation_pixel_alpha(pixels, pixel_width, pixel_width-1, 0) == 0 {
		point_marker_validation_fail("right-edge sample marker was not clipped/rendered at the surface boundary")
	}
	fmt.println("issue_201_geometry", "logical_width", logical_width, "samples", marker_count,
		"connected_segments", marker_count-1, "markers", marker_count+2,
		"vertices", expected_vertices, "budget", alicorn.GPU_SURFACE_MAX_VERTICES,
		"dpi_scale", scale, "marker", marker_name)

	if !benchmark { return }
	update_ns := make([]i64, POINT_MARKER_VALIDATION_SAMPLES, allocator=context.temp_allocator)
	encode_ns := make([]i64, POINT_MARKER_VALIDATION_SAMPLES, allocator=context.temp_allocator)
	submit_wait_ns := make([]i64, POINT_MARKER_VALIDATION_SAMPLES, allocator=context.temp_allocator)
	bench_segments := make_dense_marker_segments(marker_count)
	bench_markers := make([]alicorn.GPU_Surface_Point_Marker, marker_count, allocator=context.temp_allocator)
	for i in 0..<marker_count {
		bench_markers[i] = {
			center={f32(i*3), 16}, diameter=f32(3) if marker_size == .Three else f32(4),
			color={1, 1, 1, 1},
		}
	}
	vertex_upload_counts := renderers.geometry.vertex_uploads
	allocation_calls_before := allocations.persistent_alloc_calls
	for sample in 0..<POINT_MARKER_VALIDATION_SAMPLES {
		started := time.now()
		if !alicorn.gpu_surface_update_geometry_with_markers(&rt, surface,
			bench_segments, nil, bench_markers) {
			point_marker_validation_fail("repeat payload update rejected during benchmark")
		}
		update_ns[sample] = time.duration_nanoseconds(time.since(started))
		encode_ns[sample], submit_wait_ns[sample], initial_ok = point_marker_validation_frame(
			&rt, &renderers, device, target, sdl3.Uint32(pixel_width),
			sdl3.Uint32(pixel_height), scale,
		)
		if !initial_ok { point_marker_validation_fail("benchmark marker frame failed") }
	}
	allocation_calls := allocations.persistent_alloc_calls-allocation_calls_before
	uploads := renderers.geometry.vertex_uploads-vertex_upload_counts
	if uploads != POINT_MARKER_VALIDATION_SAMPLES {
		point_marker_validation_fail("every changed marker revision should upload one complete retained mesh")
	}
	fmt.println("issue_201_cost", "logical_width", logical_width, "marker", marker_name,
		"dpi_scale", scale, "samples", POINT_MARKER_VALIDATION_SAMPLES,
		"markers", marker_count, "connected_segments", marker_count-1,
		"update_p95_ns", point_marker_validation_percentile(update_ns, 0.95),
		"encode_p95_ns", point_marker_validation_percentile(encode_ns, 0.95),
		"submit_to_fence_p95_ns", point_marker_validation_percentile(submit_wait_ns, 0.95),
		"vertex_bytes_per_upload", u64((marker_count+marker_count-1)*6*size_of(Native_Text_Vertex)),
		"vertex_uploads", uploads, "persistent_alloc_calls_for_updates", allocation_calls,
		"idle_submission_pending", alicorn.frame_needs_submission(&rt),
		"idle_surface_pending", alicorn.gpu_surface_needs_frame(&rt))
	if alicorn.frame_needs_submission(&rt) || alicorn.gpu_surface_needs_frame(&rt) {
		point_marker_validation_fail("settled marker workload continued requesting idle work")
	}
}

make_dense_marker_segments :: proc(count: int) -> []alicorn.GPU_Surface_Line_Segment {
	segments := make([]alicorn.GPU_Surface_Line_Segment, count-1, allocator=context.temp_allocator)
	for i in 0..<len(segments) {
		segments[i] = {start={f32(i*3), 33}, end={f32((i+1)*3), 33}, thickness=1, color={0.2, 0.75, 0.95, 1}}
	}
	return segments
}

RunPointMarkerValidation :: proc() {
	driver: cstring = nil
	when ODIN_OS == .Darwin { driver = "metal" }
	when ODIN_OS == .Windows { driver = "direct3d12" }
	when ODIN_OS == .Linux { driver = "vulkan" }
	for arg in os.args[1:] {
		switch arg {
		case "--driver=metal": driver = "metal"
		case "--driver=vulkan": driver = "vulkan"
		case "--driver=direct3d12": driver = "direct3d12"
		case: point_marker_validation_fail("unknown point-marker validation argument")
		}
	}
	if !sdl3.Init(sdl3.INIT_VIDEO) { point_marker_validation_fail("SDL video initialization failed") }
	defer sdl3.Quit()
	window := sdl3.CreateWindow("Alicorn #201 point-marker validation", 640, 160, {.HIDDEN, .HIGH_PIXEL_DENSITY})
	if window == nil { point_marker_validation_fail("hidden validation window creation failed") }
	defer sdl3.DestroyWindow(window)
	device := sdl3.CreateGPUDevice({.DXIL, .MSL, .SPIRV}, true, driver)
	if device == nil || !sdl3.ClaimWindowForGPUDevice(device, window) {
		point_marker_validation_fail("SDL_GPU device creation or window claim failed")
	}
	defer {
		_ = sdl3.WaitForGPUIdle(device)
		sdl3.ReleaseWindowFromGPUDevice(device, window)
		sdl3.DestroyGPUDevice(device)
	}
	format := sdl3.GetGPUSwapchainTextureFormat(device, window)
	if !sdl3.GPUTextureSupportsFormat(device, format, .D2, {.COLOR_TARGET}) {
		point_marker_validation_fail("swapchain format is not supported for offscreen readback")
	}
	fmt.println("issue_201_backend", "driver", sdl3.GetGPUDeviceDriver(device), "format", format,
		"gpu_timestamps", "not exposed by current SDL3 binding")
	widths := [2]int{1280, 1920}
	marker_sizes := [2]Point_Marker_Validation_Size{.Three, .Four}
	cases := [4]f32{1, 1.25, 1.5, 2}
	for width in widths {
		for scale in cases {
			for marker_size in marker_sizes {
				point_marker_validation_run_case(device, format, width, scale, marker_size,
					benchmark=(width == 1920 && scale == 1 && marker_size == .Four))
			}
		}
	}
	fmt.println("issue_201_validation", "status", "PASS", "readback", "analytic 3x3/4x4 ellipse coverage",
		"native_wx_bitmap_reference", "not available in Alicorn-only host")
}
