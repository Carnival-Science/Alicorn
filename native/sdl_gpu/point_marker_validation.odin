package alicorn_sdl_gpu

// Focused GPU readback and cost validation for issue #201's compact retained
// point markers. This exercises Alicorn's production SDL_GPU surface renderer.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import alicorn "../../runtime"
import "vendor:sdl3"

POINT_MARKER_VALIDATION_HEIGHT :: 40
POINT_MARKER_VALIDATION_SAMPLES :: 64
POINT_MARKER_VALIDATION_ORACLE_GRID :: 8
// The runtime's default root backdrop. The wx capture is filled with the same
// color so coverage normalization compares marker ink rather than theme color.
POINT_MARKER_VALIDATION_WX_BACKGROUND :: [3]u8{199, 209, 229}

Point_Marker_Validation_Size :: enum { Three, Four }
Native_Validation_Renderers :: struct {
	text: Native_Text_Renderer,
	geometry: Native_Surface_Renderer,
	solid: Native_Solid_Renderer,
}

point_marker_validation_sample_center :: proc(index: int, marker_size: Point_Marker_Validation_Size) -> alicorn.GPU_Surface_Point {
	// Audacity's WaveformView draws each marker as `dc.DrawEllipse(wxRect)`
	// with `pr.x = xpos - tickSize/2` for an integer sample position. Windows
	// GDI fills that wxRect over `tickSize` pixels, so the rendered center is
	// `rect.x + tickSize/2 - 0.5`. Keep the wxRect authoritative here: the same
	// rects are written to the wx reference scene, so neither side can drift.
	x, y, w, h := point_marker_validation_marker_rect(index, marker_size)
	return point_marker_validation_rect_center(x, y, w, h)
}

point_marker_validation_marker_rect :: proc(index: int, marker_size: Point_Marker_Validation_Size) -> (x, y, w, h: int) {
	tick := 3 if marker_size == .Three else 4
	return index*3 - tick/2, 16 - tick/2, tick, tick
}

point_marker_validation_rect_center :: proc(x, y, w, h: int) -> alicorn.GPU_Surface_Point {
	return {f32(x) + f32(w)/2 - 0.5, f32(y) + f32(h)/2 - 0.5}
}

point_marker_validation_wx_stem :: proc(logical_width: int, scale: f32, marker_size: Point_Marker_Validation_Size) -> string {
	tick := 3 if marker_size == .Three else 4
	return fmt.tprintf("markers-%dx%d@%.2fx-%d", logical_width, POINT_MARKER_VALIDATION_HEIGHT, scale, tick)
}

// point_marker_validation_wx_scene describes the same marker set Audacity's
// WaveformView draws: integer wxRects from `sample - tickSize/2`, plus the two
// out-of-bounds probes the native fixture adds at each surface edge.
point_marker_validation_wx_scene :: proc(logical_width: int, scale: f32, marker_size: Point_Marker_Validation_Size) -> string {
	builder := strings.builder_make(context.temp_allocator)
	wx_reference_scene_header(&builder, logical_width, POINT_MARKER_VALIDATION_HEIGHT, scale,
		POINT_MARKER_VALIDATION_WX_BACKGROUND)
	count := (logical_width-1)/3 + 1
	for index in 0..<count {
		x, y, w, h := point_marker_validation_marker_rect(index, marker_size)
		wx_reference_scene_ellipse(&builder, x, y, w, h, {255, 255, 255})
	}
	wx_reference_scene_ellipse(&builder, -3, -1, 4, 4, {255, 255, 255})
	wx_reference_scene_ellipse(&builder, logical_width-1, -1, 4, 4, {255, 255, 255})
	return strings.to_string(builder)
}

point_marker_validation_fail :: proc(message: string) -> ! {
	fmt.eprintln("issue_201_point_marker_validation", "FAIL", message, "SDL", sdl3.GetError())
	os.exit(1)
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

native_validation_renderers_make :: proc(
	device: ^sdl3.GPUDevice,
	format: sdl3.GPUTextureFormat,
	rt: ^alicorn.Runtime,
) -> (renderers: Native_Validation_Renderers, ok: bool) {
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

native_validation_renderers_destroy :: proc(renderers: ^Native_Validation_Renderers) {
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
) -> (surface: alicorn.Node_ID, ok: bool) {
	if rt == nil { return 0, false }
	if !alicorn.text_engine_load_default_fonts(rt) { return 0, false }
	alicorn.invalidate_root(rt, "issue #201 dense marker readback")
	ui, build := alicorn.begin_frame(rt)
	if !build { return 0, false }
	alicorn.container_begin(&ui, .Root, label="issue-201-root", key=alicorn.key_string("issue-201-root"),
		style=alicorn.layout_style(.Column, width=f32(logical_width), height=POINT_MARKER_VALIDATION_HEIGHT))
	surface = alicorn.gpu_geometry_surface(&ui, "issue-201-markers",
		alicorn.layout_style(width=f32(logical_width), height=POINT_MARKER_VALIDATION_HEIGHT), 1)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)

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
			center=point_marker_validation_sample_center(i, marker_size),
			diameter=diameter, color={1, 1, 1, 1},
		}
	}
	// Two extra samples exercise surface clipping at both horizontal edges.
	markers[count+0] = {center={-1, 1}, diameter=4, color={1, 1, 1, 1}}
	markers[count+1] = {center={f32(logical_width+1), 1}, diameter=4, color={1, 1, 1, 1}}
	if !alicorn.gpu_surface_update_geometry_with_markers(rt, surface, segments, nil, markers) {
		return surface, false
	}
	return surface, true
}

native_validation_frame :: proc(
	rt: ^alicorn.Runtime,
	renderers: ^Native_Validation_Renderers,
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

point_marker_validation_pixel_rgb_mean :: proc(pixels: []u8, width, x, y: int) -> int {
	i := (y*width+x)*4
	// The native swapchain format can order color channels differently across
	// backends. A channel mean is invariant to RGBA/BGRA ordering; markers use
	// white ink on the sampled fixture backdrop.
	return (int(pixels[i])+int(pixels[i+1])+int(pixels[i+2]))/3
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
	background := point_marker_validation_pixel_rgb_mean(pixels, pixel_width, pixel_width/2, pixel_height-1)
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
				actual := point_marker_validation_pixel_rgb_mean(pixels, pixel_width, x, y)
				coverage := point_marker_validation_reference_coverage(markers, logical_bounds, scale, x, y)
				expected := int(math.round(f32(background)+(255-f32(background))*coverage))
				delta := abs(actual-expected)
				max_delta = max(max_delta, delta)
				sum_delta += delta
				compared += 1
				if actual > background+2 { covered_samples += 1 }
				if actual > background+2 && actual < 253 { aa_samples += 1 }
			}
		}
	}
	mean_delta := 0 if compared == 0 else sum_delta/compared
	// The analytic area oracle is independent of the 32x32 sampled mask. Compare
	// blended luminance against the fixture's opaque root backdrop, not target
	// alpha: the application's root surface intentionally makes alpha opaque.
	// A 4px marker at integer scale can place every output pixel center either
	// fully inside or outside the circle, so the readback may contain no
	// partially covered pixel even though the sampled mask is antialiased. Keep
	// requiring visible edge coverage for the 3px and fractional-DPI cases.
	integer_aligned_four_pixel_marker := scale == 1 && len(markers) > 0 && markers[0].diameter == 4
	ok := compared > 0 && mean_delta <= 28 && (aa_samples > 0 || integer_aligned_four_pixel_marker) && covered_samples > 0
	fmt.println("issue_201_readback", "case", name, "scale", scale, "pixels_compared", compared,
		"background_rgb_mean", background, "mean_rgb_delta", mean_delta, "max_rgb_delta", max_delta,
		"antialiased_pixels", aa_samples, "marker_pixels", covered_samples,
		"status", "PASS" if ok else "FAIL")
	return ok
}

// point_marker_validation_wx_compare measures the five acceptance dimensions
// (size, antialiasing, overlap, clipping, fractional DPI) against the wx
// capture: coverage area and centroid for size/alignment, partially covered
// pixel counts for antialiasing, shared boundary coverage for overlap, and the
// out-of-bounds probes for clipping. It is a coverage comparison, not a claim
// of byte-identical rasterization: wxMSW's GDI ellipses are hard-edged while
// Alicorn's shared mask is supersampled.
point_marker_validation_wx_compare :: proc(
	name: string,
	markers: []alicorn.GPU_Surface_Point_Marker,
	logical_bounds: alicorn.Rect,
	logical_width, pixel_width, pixel_height: int,
	scale: f32,
	pixels: []u8,
	reference: ^Wx_Reference,
) -> bool {
	// Interior anchors carry the size, alignment, and antialiasing comparison.
	// Edge probes are compared for clipping only: their visible footprint
	// depends on how each rasterizer rounds a rect that starts outside the
	// surface, so a hard area-ratio equality would be meaningless there.
	sample_count := len(markers)-2
	interior := [6]int{0, 1, (sample_count-1)/6, (sample_count-1)/3, (sample_count-1)/3+1, sample_count-1}
	probes := [2]int{len(markers)-2, len(markers)-1}
	gpu_background := f32((int(pixels[((pixel_height-1)*pixel_width+pixel_width/2)*4]) +
		int(pixels[((pixel_height-1)*pixel_width+pixel_width/2)*4+1]) +
		int(pixels[((pixel_height-1)*pixel_width+pixel_width/2)*4+2])))/3
	min_ratio, max_ratio := f32(1e9), f32(0)
	worst_centroid, worst_mean, worst_max := f32(0), f32(0), f32(0)
	wx_antialiased, gpu_antialiased := 0, 0
	missing := 0
	for marker_index in interior {
		if marker_index < 0 || marker_index >= len(markers) { continue }
		marker := markers[marker_index]
		center_x := (logical_bounds.x+marker.center.x)*scale
		center_y := (logical_bounds.y+marker.center.y)*scale
		radius := marker.diameter*scale*0.5
		metrics, metrics_ok := wx_anchor_metrics(reference, pixels, pixel_width, pixel_height,
			gpu_background, center_x, center_y, radius)
		if !metrics_ok { missing += 1; continue }
		if metrics.wx_area < 0.5 || metrics.gpu_area < 0.5 { missing += 1; continue }
		min_ratio = min(min_ratio, metrics.area_ratio)
		max_ratio = max(max_ratio, metrics.area_ratio)
		worst_centroid = max(worst_centroid, metrics.centroid_delta)
		worst_mean = max(worst_mean, metrics.mean_delta)
		worst_max = max(worst_max, metrics.max_delta)
		wx_antialiased += metrics.wx_antialiased
		gpu_antialiased += metrics.gpu_antialiased
	}
	probe_wx_area, probe_gpu_area := f32(0), f32(0)
	probe_ok := true
	for marker_index in probes {
		if marker_index < 0 || marker_index >= len(markers) { continue }
		marker := markers[marker_index]
		center_x := (logical_bounds.x+marker.center.x)*scale
		center_y := (logical_bounds.y+marker.center.y)*scale
		metrics, metrics_ok := wx_anchor_metrics(reference, pixels, pixel_width, pixel_height,
			gpu_background, center_x, center_y, marker.diameter*scale*0.5)
		if !metrics_ok || metrics.wx_area < 0.25 || metrics.gpu_area < 0.25 { probe_ok = false; continue }
		probe_wx_area += metrics.wx_area
		probe_gpu_area += metrics.gpu_area
	}
	// Overlap: 4px markers sit on a 3px sample grid, so neighbors share one
	// column. Both renders must cover the shared boundary pixel.
	overlap_coverage := f32(0)
	if markers[0].diameter == 4 {
		x := int(math.round(4*scale))
		y := int(math.round(16*scale))
		if x >= 0 && x < pixel_width && y >= 0 && y < pixel_height {
			wx_coverage := wx_reference_coverage_of(int(wx_reference_pixel(reference, x, y)[0]),
				int(wx_reference_pixel(reference, x, y)[1]), int(wx_reference_pixel(reference, x, y)[2]),
				f32(int(reference.bg[0])+int(reference.bg[1])+int(reference.bg[2]))/3)
			index := (y*pixel_width+x)*4
			gpu_coverage := wx_reference_coverage_of(int(pixels[index+0]), int(pixels[index+1]),
				int(pixels[index+2]), gpu_background)
			overlap_coverage = min(wx_coverage, gpu_coverage)
		}
	}
	// Tolerances reflect the hard-edged GDI reference versus the supersampled
	// marker mask and wx's device-space rect rounding at fractional scales.
	// The 1.75 px centroid allowance is the measured worst case at 1.5x: a host
	// that needs byte-level wx alignment must round the marker rect in device
	// space before deriving center and diameter from it.
	ok := missing == 0 && probe_ok && min_ratio >= 0.55 && max_ratio <= 1.80 &&
		worst_centroid <= 1.75 && worst_mean <= 0.32 &&
		(markers[0].diameter != 4 || overlap_coverage >= 0.30)
	fmt.println("issue_201_wx", "case", name, "scale", scale, "anchors", len(interior),
		"area_ratio_min", min_ratio, "area_ratio_max", max_ratio,
		"centroid_delta_max", worst_centroid, "mean_coverage_delta_max", worst_mean,
		"max_coverage_delta", worst_max, "probe_wx_area", probe_wx_area, "probe_gpu_area", probe_gpu_area,
		"overlap_coverage", overlap_coverage,
		"wx_antialiased_pixels", wx_antialiased, "gpu_antialiased_pixels", gpu_antialiased,
		"missing", missing, "status", "PASS" if ok else "FAIL")
	return ok
}

point_marker_validation_run_case :: proc(
	device: ^sdl3.GPUDevice,
	format: sdl3.GPUTextureFormat,
	logical_width: int,
	scale: f32,
	marker_size: Point_Marker_Validation_Size,
	benchmark: bool,
	emit_dir: string = "",
	wx_dir: string = "",
) {
	marker_name := "3x3" if marker_size == .Three else "4x4"
	pixel_width := int(f32(logical_width)*scale)
	pixel_height := int(f32(POINT_MARKER_VALIDATION_HEIGHT)*scale)
	marker_count := (logical_width-1)/3+1
	allocations := alicorn.Runtime_Allocation_Stats{}
	rt := alicorn.new_runtime(
		alicorn.Rect{0, 0, f32(logical_width), POINT_MARKER_VALIDATION_HEIGHT},
		config=alicorn.Runtime_Config{allocation_stats=&allocations},
	)
	surface, runtime_ok := point_marker_validation_create_runtime(&rt, logical_width, marker_size)
	if !runtime_ok { point_marker_validation_fail("runtime fixture could not retain dense markers and lines") }
	defer if rt.persistent_allocator_state != nil { alicorn.destroy_runtime(&rt) }
	renderers, renderer_ok := native_validation_renderers_make(device, format, &rt)
	if !renderer_ok { point_marker_validation_fail("production surface renderer initialization failed") }
	defer if renderers.text.device != nil { native_validation_renderers_destroy(&renderers) }
	target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{
		type=.D2, format=format, usage={.COLOR_TARGET}, width=sdl3.Uint32(pixel_width),
		height=sdl3.Uint32(pixel_height), layer_count_or_depth=1, num_levels=1, sample_count=._1,
	})
	if target == nil { point_marker_validation_fail("offscreen marker target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, target)
	download := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{
		usage=.DOWNLOAD, size=sdl3.Uint32(pixel_width*pixel_height*4),
	})
	if download == nil { point_marker_validation_fail("GPU readback buffer creation failed") }
	defer sdl3.ReleaseGPUTransferBuffer(device, download)
	pixels := make([]u8, pixel_width*pixel_height*4)
	defer delete(pixels)
	_, _, initial_ok := native_validation_frame(&rt, &renderers, device, target,
		sdl3.Uint32(pixel_width), sdl3.Uint32(pixel_height), scale, download, pixels)
	if !initial_ok { point_marker_validation_fail("first marker readback frame failed") }
	command, found := native_surface_test_geometry_command(&rt, surface)
	if !found || !native_surface_rebuild_mesh(&renderers.geometry, command, scale, scale) {
		point_marker_validation_fail("retained mesh rebuild failed after readback")
	}
	expected_vertices := (marker_count+2 + marker_count-1)*6
	if len(renderers.geometry.vertices) != expected_vertices || expected_vertices > alicorn.GPU_SURFACE_MAX_VERTICES {
		point_marker_validation_fail("native dense marker and line mesh exceeded the bounded vertex expectation")
	}
	markers := make([]alicorn.GPU_Surface_Point_Marker, marker_count+2, allocator=context.temp_allocator)
	for i in 0..<marker_count {
		diameter := f32(3) if marker_size == .Three else f32(4)
		markers[i] = {
			center=point_marker_validation_sample_center(i, marker_size),
			diameter=diameter, color={1, 1, 1, 1},
		}
	}
	markers[marker_count+0] = {center={-1, 1}, diameter=4, color={1, 1, 1, 1}}
	markers[marker_count+1] = {center={f32(logical_width+1), 1}, diameter=4, color={1, 1, 1, 1}}
	info, info_ok := alicorn.node_info(&rt, surface)
	if !info_ok || !point_marker_validation_compare_readback(
		fmt.tprintf("%dpx-%s", logical_width, marker_name), markers,
		info.bounds, logical_width, pixel_width, pixel_height, scale, pixels,
	) { point_marker_validation_fail("native readback did not match the analytic ellipse coverage reference") }
	// The viewport's edge scissor must clip the auxiliary circles whose centers
	// are outside the retained geometry surface.
	background := point_marker_validation_pixel_rgb_mean(pixels, pixel_width, pixel_width/2, pixel_height-1)
	if point_marker_validation_pixel_rgb_mean(pixels, pixel_width, 0, 0) <= background+2 {
		point_marker_validation_fail("left-edge sample marker was not clipped/rendered at the surface boundary")
	}
	if point_marker_validation_pixel_rgb_mean(pixels, pixel_width, pixel_width-1, 0) <= background+2 {
		point_marker_validation_fail("right-edge sample marker was not clipped/rendered at the surface boundary")
	}
	fmt.println("issue_201_geometry", "logical_width", logical_width, "samples", marker_count,
		"connected_segments", marker_count-1, "markers", marker_count+2,
		"vertices", expected_vertices, "budget", alicorn.GPU_SURFACE_MAX_VERTICES,
		"dpi_scale", scale, "marker", marker_name)

	stem := point_marker_validation_wx_stem(logical_width, scale, marker_size)
	if emit_dir != "" {
		if !wx_reference_scene_write(emit_dir, stem, point_marker_validation_wx_scene(logical_width, scale, marker_size)) {
			point_marker_validation_fail("could not write the wx reference scene")
		}
	}
	if wx_dir != "" {
		reference, reference_ok := wx_reference_load(wx_dir, stem)
		if !reference_ok {
			point_marker_validation_fail("wx reference capture is missing for the marker case")
		}
		if !point_marker_validation_wx_compare(
			fmt.tprintf("%dpx-%s", logical_width, marker_name), markers, info.bounds,
			logical_width, pixel_width, pixel_height, scale, pixels, &reference,
		) {
			point_marker_validation_fail("native marker readback disagreed with the wxWidgets reference")
		}
	}

	if !benchmark { return }
	update_ns := make([]i64, POINT_MARKER_VALIDATION_SAMPLES, allocator=context.temp_allocator)
	encode_ns := make([]i64, POINT_MARKER_VALIDATION_SAMPLES, allocator=context.temp_allocator)
	submit_wait_ns := make([]i64, POINT_MARKER_VALIDATION_SAMPLES, allocator=context.temp_allocator)
	bench_segments := make_dense_marker_segments(marker_count)
	bench_markers := make([]alicorn.GPU_Surface_Point_Marker, marker_count, allocator=context.temp_allocator)
	for i in 0..<marker_count {
		bench_markers[i] = {
			center=point_marker_validation_sample_center(i, marker_size),
			diameter=f32(3) if marker_size == .Three else f32(4),
			color={1, 1, 1, 1},
		}
	}
	vertex_upload_counts := renderers.geometry.vertex_uploads
	allocation_calls_before := allocations.persistent_alloc_calls
	update_allocations: u64 = 0
	for sample in 0..<POINT_MARKER_VALIDATION_SAMPLES {
		calls_before_update := allocations.persistent_alloc_calls
		started := time.now()
		if !alicorn.gpu_surface_update_geometry_with_markers(&rt, surface,
			bench_segments, nil, bench_markers) {
			point_marker_validation_fail("repeat payload update rejected during benchmark")
		}
		update_ns[sample] = time.duration_nanoseconds(time.since(started))
		update_allocations += allocations.persistent_alloc_calls-calls_before_update
		encode_ns[sample], submit_wait_ns[sample], initial_ok = native_validation_frame(
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
		"vertex_uploads", uploads, "persistent_alloc_calls_for_updates", update_allocations,
		"persistent_alloc_calls_update_and_frames", allocation_calls,
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

// point_marker_validation_marker_cost_sweep isolates marker rendering from the
// connected waveform lines and sweeps the retained marker count up to the
// shared 8,192-vertex budget. It also proves the over-budget cases (10k/100k
// markers) are rejected atomically instead of silently falling back.
point_marker_validation_marker_cost_sweep :: proc(device: ^sdl3.GPUDevice, format: sdl3.GPUTextureFormat) {
	counts := [4]int{128, 512, 1024, 1365}
	iterations :: 64
	for count in counts {
		logical_width := count+2
		pixel_width := logical_width
		pixel_height := POINT_MARKER_VALIDATION_HEIGHT
		allocations := alicorn.Runtime_Allocation_Stats{}
		rt := alicorn.new_runtime(
			alicorn.Rect{0, 0, f32(logical_width), POINT_MARKER_VALIDATION_HEIGHT},
			config=alicorn.Runtime_Config{allocation_stats=&allocations},
		)
		surface, ok := point_marker_validation_create_runtime(&rt, logical_width, .Three)
		if !ok {
			alicorn.destroy_runtime(&rt)
			point_marker_validation_fail("marker sweep fixture failed")
		}
		renderers, renderer_ok := native_validation_renderers_make(device, format, &rt)
		if !renderer_ok {
			alicorn.destroy_runtime(&rt)
			point_marker_validation_fail("marker sweep renderer initialization failed")
		}
		target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{
			type=.D2, format=format, usage={.COLOR_TARGET}, width=sdl3.Uint32(pixel_width),
			height=sdl3.Uint32(pixel_height), layer_count_or_depth=1, num_levels=1, sample_count=._1,
		})
		if target == nil {
			native_validation_renderers_destroy(&renderers)
			alicorn.destroy_runtime(&rt)
			point_marker_validation_fail("marker sweep target creation failed")
		}
		markers := make([]alicorn.GPU_Surface_Point_Marker, count, allocator=context.temp_allocator)
		for i in 0..<count {
			markers[i] = {center={f32(i+1), 16}, diameter=3, color={1, 1, 1, 1}}
		}
		update_ns := make([]i64, iterations, allocator=context.temp_allocator)
		encode_ns := make([]i64, iterations, allocator=context.temp_allocator)
		submit_ns := make([]i64, iterations, allocator=context.temp_allocator)
		uploads_before := renderers.geometry.vertex_uploads
		bytes_before := renderers.geometry.vertex_upload_bytes
		update_allocations: u64 = 0
		for sample in 0..<iterations {
			calls_before := allocations.persistent_alloc_calls
			started := time.now()
			if !alicorn.gpu_surface_update_geometry_with_markers(&rt, surface, nil, nil, markers) {
				point_marker_validation_fail("marker sweep payload rejected")
			}
			update_ns[sample] = time.duration_nanoseconds(time.since(started))
			update_allocations += allocations.persistent_alloc_calls-calls_before
			encode_ns[sample], submit_ns[sample], ok = native_validation_frame(
				&rt, &renderers, device, target, sdl3.Uint32(pixel_width),
				sdl3.Uint32(pixel_height), 1,
			)
			if !ok { point_marker_validation_fail("marker sweep frame failed") }
		}
		uploads := renderers.geometry.vertex_uploads-uploads_before
		upload_bytes := renderers.geometry.vertex_upload_bytes-bytes_before
		fmt.println("issue_201_sweep", "markers", count, "vertices", count*alicorn.GPU_SURFACE_POINT_MARKER_VERTICES,
			"budget", alicorn.GPU_SURFACE_MAX_VERTICES, "samples", iterations,
			"update_p95_ns", point_marker_validation_percentile(update_ns, 0.95),
			"encode_p95_ns", point_marker_validation_percentile(encode_ns, 0.95),
			"submit_to_fence_p95_ns", point_marker_validation_percentile(submit_ns, 0.95),
			"vertex_bytes_per_upload", upload_bytes/uploads, "vertex_uploads", uploads,
			"persistent_alloc_calls_for_updates", update_allocations,
			"idle_submission_pending", alicorn.frame_needs_submission(&rt),
			"idle_surface_pending", alicorn.gpu_surface_needs_frame(&rt))
		if alicorn.frame_needs_submission(&rt) || alicorn.gpu_surface_needs_frame(&rt) {
			point_marker_validation_fail("settled marker sweep continued requesting idle work")
		}
		sdl3.ReleaseGPUTexture(device, target)
		native_validation_renderers_destroy(&renderers)
		alicorn.destroy_runtime(&rt)
	}

	// Budget boundary: 1,365 markers fit; 1,366 and the requested 10k/100k
	// probes are rejected and leave the retained payload alone.
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 2048, POINT_MARKER_VALIDATION_HEIGHT})
	defer alicorn.destroy_runtime(&rt)
	surface, ok := point_marker_validation_create_runtime(&rt, 1366, .Three)
	if !ok { point_marker_validation_fail("marker budget fixture failed") }
	// Fill the accepted payload to the exact budget, then probe overflow.
	accepted := make([]alicorn.GPU_Surface_Point_Marker, 1365, allocator=context.temp_allocator)
	for i in 0..<len(accepted) {
		accepted[i] = {center={f32(i), 16}, diameter=3, color={1, 1, 1, 1}}
	}
	if !alicorn.gpu_surface_update_geometry_with_markers(&rt, surface, nil, nil, accepted) {
		point_marker_validation_fail("the exact marker budget was rejected")
	}
	accepted_revision := rt.nodes[surface].surface_payload_revision
	rejections_before := rt.stats.surface_geometry_overflow_rejections
	for probe in ([3]int{1366, 10000, 100000}) {
		too_many := make([]alicorn.GPU_Surface_Point_Marker, probe, allocator=context.temp_allocator)
		for i in 0..<probe {
			too_many[i] = {center={f32(i), 16}, diameter=3, color={1, 1, 1, 1}}
		}
		if alicorn.gpu_surface_update_geometry_with_markers(&rt, surface, nil, nil, too_many) {
			point_marker_validation_fail("an over-budget marker batch was accepted")
		}
		if rt.nodes[surface].surface_payload_revision != accepted_revision {
			point_marker_validation_fail("marker overflow rejection did not preserve the retained payload revision")
		}
	}
	if rt.stats.surface_geometry_overflow_rejections != rejections_before+3 {
		point_marker_validation_fail("marker overflow rejections were not counted")
	}
	fmt.println("issue_201_budget", "accepted_markers", len(accepted),
		"vertices", len(accepted)*alicorn.GPU_SURFACE_POINT_MARKER_VERTICES,
		"budget", alicorn.GPU_SURFACE_MAX_VERTICES,
		"rejected", "1366,10000,100000", "retained_payload", "preserved", "status", "PASS")
}

RunPointMarkerValidation :: proc() {
	driver: cstring = nil
	when ODIN_OS == .Darwin { driver = "metal" }
	when ODIN_OS == .Windows { driver = "direct3d12" }
	when ODIN_OS == .Linux { driver = "vulkan" }
	emit_dir, wx_dir: string
	for arg in os.args[1:] {
		switch arg {
		case "--driver=metal": driver = "metal"
		case "--driver=vulkan": driver = "vulkan"
		case "--driver=direct3d12": driver = "direct3d12"
		case:
			if strings.has_prefix(arg, "--emit-wx-scenes=") {
				emit_dir = arg[len("--emit-wx-scenes="):]
			} else if strings.has_prefix(arg, "--wx-reference=") {
				wx_dir = arg[len("--wx-reference="):]
			} else {
				point_marker_validation_fail("unknown point-marker validation argument")
			}
		}
	}
	if emit_dir != "" {
		dir_err := os.mkdir(emit_dir)
		_ = dir_err
	}
	fmt.println("issue_201_wx_reference", "directory", wx_dir if wx_dir != "" else "not supplied",
		"emit_scenes", emit_dir if emit_dir != "" else "not supplied")
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
					benchmark=(width == 1920 && scale == 1 && marker_size == .Four),
					emit_dir=emit_dir, wx_dir=wx_dir)
			}
		}
	}
	fmt.println("issue_201_validation", "status", "PASS", "readback", "analytic 3x3/4x4 ellipse coverage",
		"native_wx_bitmap_reference", "compared" if wx_dir != "" else "not supplied")
	point_marker_validation_marker_cost_sweep(device, format)
}
