package alicorn_sdl_gpu

// Accepts issue #200: bounded filled-rectangle batches. This exercises the
// production SDL_GPU surface renderer with a 1,024-rectangle payload, compares
// the readback against an independent CPU compositor and a wxWidgets GDI
// capture, proves the shared vertex budget rejects overflow atomically, and
// measures batched versus retained-node repaint cost.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import alicorn "../../runtime"
import "vendor:sdl3"

RECTANGLE_VALIDATION_WIDTH :: 1280
RECTANGLE_VALIDATION_HEIGHT :: 160
RECTANGLE_VALIDATION_SAMPLES :: 64
RECTANGLE_VALIDATION_BACKGROUND :: [3]u8{199, 209, 229}
RECTANGLE_VALIDATION_PALETTE := [10][3]f32{
	{0.24, 0.45, 0.72}, {0.86, 0.42, 0.31}, {0.30, 0.68, 0.42},
	{0.62, 0.38, 0.76}, {0.93, 0.72, 0.22}, {0.18, 0.62, 0.74},
	{0.72, 0.24, 0.44}, {0.38, 0.54, 0.86}, {0.55, 0.75, 0.30},
	{0.90, 0.55, 0.68},
}

Rectangle_Validation_Scene :: struct {
	rectangles: [dynamic]alicorn.GPU_Surface_Filled_Rectangle,
	// Painter-order check: this index paints last and must win at its center.
	last_index: int,
}

rectangle_validation_rng :: proc(state: ^u64) -> u32 {
	value := state^ * 6364136223846793005 + 1442695040888963407
	state^ = value
	return u32(value >> 32)
}

// rectangle_validation_scene builds the coalesced column band, a set of wide
// overlapping fills, and rects clipped by all four surface edges. `alpha`
// lowers the opacity of the fill groups so stacking can be compared against
// the CPU compositor.
rectangle_validation_scene :: proc(alpha: bool) -> Rectangle_Validation_Scene {
	scene := Rectangle_Validation_Scene{
		rectangles=make([dynamic]alicorn.GPU_Surface_Filled_Rectangle, 0, 1026),
	}
	state := u64(0x9E3779B97F4A7C15)
	color_count := u32(len(RECTANGLE_VALIDATION_PALETTE))
	// 640 two-pixel envelope columns, matching the coalesced waveform
	// background Acetate sends.
	for index in 0..<640 {
		height := f32(20+rectangle_validation_rng(&state)%100)
		y := 80-height/2
		color := RECTANGLE_VALIDATION_PALETTE[rectangle_validation_rng(&state)%color_count]
		append(&scene.rectangles, alicorn.GPU_Surface_Filled_Rectangle{
			bounds={f32(index*2), y, 2, height},
			color={color[0], color[1], color[2], 0.55 if alpha else 1},
		})
	}
	// 320 wider coalesced fills painted over the columns.
	for index in 0..<320 {
		width := f32(4+rectangle_validation_rng(&state)%12)
		x := f32((index*4)%(RECTANGLE_VALIDATION_WIDTH-16))
		height := f32(24+rectangle_validation_rng(&state)%96)
		y := 80-height/2
		color := RECTANGLE_VALIDATION_PALETTE[rectangle_validation_rng(&state)%color_count]
		append(&scene.rectangles, alicorn.GPU_Surface_Filled_Rectangle{
			bounds={x, y, width, height},
			color={color[0], color[1], color[2], 0.45 if alpha else 1},
		})
	}
	// 32 selection-like fills spanning many columns.
	for index in 0..<32 {
		width := f32(40+rectangle_validation_rng(&state)%80)
		x := f32(rectangle_validation_rng(&state)%u32(RECTANGLE_VALIDATION_WIDTH-100))
		y := f32(8+rectangle_validation_rng(&state)%40)
		height := f32(40+rectangle_validation_rng(&state)%100)
		color := RECTANGLE_VALIDATION_PALETTE[rectangle_validation_rng(&state)%color_count]
		append(&scene.rectangles, alicorn.GPU_Surface_Filled_Rectangle{
			bounds={x, y, width, height},
			color={color[0], color[1], color[2], 0.5 if alpha else 1},
		})
	}
	// Channel-order key: one uniquely colored rect in an otherwise free band.
	append(&scene.rectangles, alicorn.GPU_Surface_Filled_Rectangle{
		bounds={100, 12, 32, 24}, color={0.90, 0.10, 0.50, 1},
	})
	// 32 boundary-clipped rects: eight per edge.
	for index in 0..<8 {
		y := f32(10+index*17)
		append(&scene.rectangles, alicorn.GPU_Surface_Filled_Rectangle{
			bounds={-10, y, 16, 12}, color={0.95, 0.95, 0.95, 1},
		})
		append(&scene.rectangles, alicorn.GPU_Surface_Filled_Rectangle{
			bounds={f32(RECTANGLE_VALIDATION_WIDTH-6), y, 16, 12}, color={0.10, 0.10, 0.10, 1},
		})
		append(&scene.rectangles, alicorn.GPU_Surface_Filled_Rectangle{
			bounds={f32(20+index*30), -6, 18, 14}, color={0.85, 0.20, 0.20, 1},
		})
		append(&scene.rectangles, alicorn.GPU_Surface_Filled_Rectangle{
			bounds={f32(20+index*30), f32(RECTANGLE_VALIDATION_HEIGHT-6), 18, 14}, color={0.20, 0.20, 0.85, 1},
		})
	}
	// The last rect is opaque and painted last; its center must show its color.
	append(&scene.rectangles, alicorn.GPU_Surface_Filled_Rectangle{
		bounds={600, 60, 24, 24}, color={1, 1, 1, 1},
	})
	scene.last_index = len(scene.rectangles)-1
	return scene
}

rectangle_validation_fail :: proc(message: string) -> ! {
	fmt.eprintln("issue_200_rectangle_validation", "FAIL", message, "SDL", sdl3.GetError())
	os.exit(1)
}

rectangle_validation_quantize :: proc(value: f32) -> u8 {
	bounded := value
	if bounded < 0 { bounded = 0 }
	if bounded > 1 { bounded = 1 }
	return u8(math.floor(bounded*255+0.5))
}

// rectangle_validation_cpu_render composites the payload independently. It
// applies the pipeline's pixel-center coverage rule for axis-aligned quads and
// source-over blending in the target's UNORM space.
rectangle_validation_cpu_render :: proc(
	rectangles: []alicorn.GPU_Surface_Filled_Rectangle,
	scale: f32,
	width, height: int,
	background: [3]u8,
	output: []u8,
) {
	for pixel in 0..<width*height {
		output[pixel*4+0] = background[0]
		output[pixel*4+1] = background[1]
		output[pixel*4+2] = background[2]
		output[pixel*4+3] = 255
	}
	for rectangle in rectangles {
		x0 := rectangle.bounds.x*scale
		x1 := (rectangle.bounds.x+rectangle.bounds.w)*scale
		y0 := rectangle.bounds.y*scale
		y1 := (rectangle.bounds.y+rectangle.bounds.h)*scale
		left := max(0, int(math.floor(x0-0.5)))
		right := min(width, int(math.ceil(x1+0.5)))
		top := max(0, int(math.floor(y0-0.5)))
		bottom := min(height, int(math.ceil(y1+0.5)))
		source_alpha := rectangle.color.a
		inverse := 1-source_alpha
		for y in top..<bottom {
			center_y := f32(y)+0.5
			if center_y < y0 || center_y >= y1 { continue }
			for x in left..<right {
				center_x := f32(x)+0.5
				if center_x < x0 || center_x >= x1 { continue }
				index := (y*width+x)*4
				output[index+0] = rectangle_validation_quantize(
					rectangle.color.r*source_alpha + f32(output[index+0])/255*inverse)
				output[index+1] = rectangle_validation_quantize(
					rectangle.color.g*source_alpha + f32(output[index+1])/255*inverse)
				output[index+2] = rectangle_validation_quantize(
					rectangle.color.b*source_alpha + f32(output[index+2])/255*inverse)
			}
		}
	}
}

Rectangle_Compare :: struct {
	mismatched: int, // exact pixel comparison failures
	edge_only:  int, // failures that match within `edge_radius` pixels
	compared:   int,
	max_delta:  int,
	mean_delta: f32,
}

// rectangle_validation_compare_pixels compares a BGRA/RGBA readback against an
// RGB24 reference. `channel_swap` selects the B/R order. `edge_radius > 0`
// additionally accepts a pixel whose color matches the reference within that
// distance: wx draws integer device rects, so a rect edge at a fractional
// logical coordinate can land one pixel away from the pixel-center rule the
// GPU uses. Such pixels are counted separately as edge-only differences.
rectangle_validation_compare_pixels :: proc(
	gpu: []u8,
	pixel_width, pixel_height: int,
	reference_rgb: []u8,
	channel_swap: bool,
	edge_radius: int = 0,
) -> Rectangle_Compare {
	result := Rectangle_Compare{}
	channel :: proc(gpu: []u8, base: int, channel_swap: bool, channel: int) -> int {
		if channel_swap { return int(gpu[base+(2-channel)]) }
		return int(gpu[base+channel])
	}
	for y in 0..<pixel_height {
		for x in 0..<pixel_width {
			index := (y*pixel_width+x)*4
			ref_index := (y*pixel_width+x)*3
			delta := (abs(channel(gpu, index, channel_swap, 0)-int(reference_rgb[ref_index+0])) +
				abs(channel(gpu, index, channel_swap, 1)-int(reference_rgb[ref_index+1])) +
				abs(channel(gpu, index, channel_swap, 2)-int(reference_rgb[ref_index+2])))/3
			result.compared += 1
			if delta <= 1 {
				result.mean_delta += f32(delta)
				continue
			}
			matched_edge := false
			if edge_radius > 0 {
				for dy in -edge_radius..=edge_radius {
					for dx in -edge_radius..=edge_radius {
						if dx == 0 && dy == 0 { continue }
						nx, ny := x+dx, y+dy
						if nx < 0 || ny < 0 || nx >= pixel_width || ny >= pixel_height { continue }
						n_ref := (ny*pixel_width+nx)*3
						neighbour := (abs(channel(gpu, index, channel_swap, 0)-int(reference_rgb[n_ref+0])) +
							abs(channel(gpu, index, channel_swap, 1)-int(reference_rgb[n_ref+1])) +
							abs(channel(gpu, index, channel_swap, 2)-int(reference_rgb[n_ref+2])))/3
						if neighbour <= 1 { matched_edge = true; break }
					}
					if matched_edge { break }
				}
			}
			if matched_edge {
				result.edge_only += 1
				continue
			}
			result.mismatched += 1
			result.max_delta = max(result.max_delta, delta)
			result.mean_delta += f32(delta)
		}
	}
	if result.compared > 0 { result.mean_delta /= f32(result.compared) }
	return result
}

rectangle_validation_wx_scene :: proc(scene: ^Rectangle_Validation_Scene, scale: f32) -> string {
	builder := strings.builder_make(context.temp_allocator)
	wx_reference_scene_header(&builder, RECTANGLE_VALIDATION_WIDTH, RECTANGLE_VALIDATION_HEIGHT, scale,
		RECTANGLE_VALIDATION_BACKGROUND)
	for rectangle in scene.rectangles {
		wx_reference_scene_rect(&builder, rectangle.bounds.x, rectangle.bounds.y,
			rectangle.bounds.w, rectangle.bounds.h,
			{rectangle.color.r, rectangle.color.g, rectangle.color.b, rectangle.color.a})
	}
	return strings.to_string(builder)
}

rectangle_validation_describe :: proc(ui: ^alicorn.UI, scale: f32) {
	alicorn.container_begin(ui, .Root, label="issue-200-root", key=alicorn.key_string("issue-200-root"),
		style=alicorn.layout_style(.Column, width=RECTANGLE_VALIDATION_WIDTH, height=RECTANGLE_VALIDATION_HEIGHT))
	_ = alicorn.gpu_geometry_surface(ui, "issue-200-rectangles",
		alicorn.layout_style(width=RECTANGLE_VALIDATION_WIDTH, height=RECTANGLE_VALIDATION_HEIGHT), scale)
	alicorn.container_end(ui)
}

rectangle_validation_create_runtime :: proc(rt: ^alicorn.Runtime, scale: f32) -> (surface: alicorn.Node_ID, ok: bool) {
	if !alicorn.text_engine_load_default_fonts(rt) { return 0, false }
	alicorn.invalidate_root(rt, "issue #200 rectangle readback")
	ui, build := alicorn.begin_frame(rt)
	if !build { return 0, false }
	rectangle_validation_describe(&ui, scale)
	alicorn.end_frame(&ui)
	created_surface, found := rectangle_validation_surface_id(rt)
	return created_surface, found
}

rectangle_validation_surface_id :: proc(rt: ^alicorn.Runtime) -> (surface: alicorn.Node_ID, ok: bool) {
	for id, node in rt.nodes {
		if node != nil && node.active && node.kind == .Custom_Surface && node.surface_kind == .Geometry {
			return id, true
		}
	}
	return 0, false
}

rectangle_validation_run_case :: proc(
	device: ^sdl3.GPUDevice,
	format: sdl3.GPUTextureFormat,
	scale: f32,
	alpha: bool,
	emit_dir, wx_dir, dump_dir: string,
) {
	pixel_width := int(f32(RECTANGLE_VALIDATION_WIDTH)*scale)
	pixel_height := int(f32(RECTANGLE_VALIDATION_HEIGHT)*scale)
	scene := rectangle_validation_scene(alpha)
	defer delete(scene.rectangles)
	name := fmt.tprintf("%dx%d@%.2fx-%s", RECTANGLE_VALIDATION_WIDTH, RECTANGLE_VALIDATION_HEIGHT, scale,
		"alpha" if alpha else "opaque")
	stem := fmt.tprintf("rects-%s", name)

	allocations := alicorn.Runtime_Allocation_Stats{}
	rt := alicorn.new_runtime(
		alicorn.Rect{0, 0, RECTANGLE_VALIDATION_WIDTH, RECTANGLE_VALIDATION_HEIGHT},
		config=alicorn.Runtime_Config{allocation_stats=&allocations},
	)
	defer alicorn.destroy_runtime(&rt)
	surface, runtime_ok := rectangle_validation_create_runtime(&rt, scale)
	if !runtime_ok { rectangle_validation_fail("runtime fixture could not retain the rectangle surface") }
	if !alicorn.gpu_surface_update_geometry_with_rectangles(&rt, surface, scene.rectangles[:], nil, nil) {
		rectangle_validation_fail("bounded rectangle payload was rejected")
	}

	renderers, renderer_ok := native_validation_renderers_make(device, format, &rt)
	if !renderer_ok { rectangle_validation_fail("production surface renderer initialization failed") }
	defer if renderers.text.device != nil { native_validation_renderers_destroy(&renderers) }
	target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{
		type=.D2, format=format, usage={.COLOR_TARGET}, width=sdl3.Uint32(pixel_width),
		height=sdl3.Uint32(pixel_height), layer_count_or_depth=1, num_levels=1, sample_count=._1,
	})
	if target == nil { rectangle_validation_fail("offscreen rectangle target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, target)
	download := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{
		usage=.DOWNLOAD, size=sdl3.Uint32(pixel_width*pixel_height*4),
	})
	if download == nil { rectangle_validation_fail("rectangle readback buffer creation failed") }
	defer sdl3.ReleaseGPUTransferBuffer(device, download)
	pixels := make([]u8, pixel_width*pixel_height*4)
	defer delete(pixels)
	_, _, initial_ok := native_validation_frame(&rt, &renderers, device, target,
		sdl3.Uint32(pixel_width), sdl3.Uint32(pixel_height), scale, download, pixels)
	if !initial_ok { rectangle_validation_fail("first rectangle readback frame failed") }

	// Batching must engage: one retained geometry draw covering every rect.
	command, found := native_surface_test_geometry_command(&rt, surface)
	if !found || !native_surface_rebuild_mesh(&renderers.geometry, command, scale, scale) {
		rectangle_validation_fail("retained rectangle mesh rebuild failed")
	}
	expected_vertices := len(scene.rectangles)*alicorn.GPU_SURFACE_RECTANGLE_VERTICES
	if len(renderers.geometry.vertices) != expected_vertices || expected_vertices > alicorn.GPU_SURFACE_MAX_VERTICES {
		rectangle_validation_fail("batched mesh vertex count did not match the bounded rectangle payload")
	}
	geometry_commands := 0
	for display_command in rt.display {
		if alicorn.paint_command_is_geometry(display_command) { geometry_commands += 1 }
	}

	// Painter order: the final opaque rectangle covers earlier fills.
	last := scene.rectangles[scene.last_index]
	last_x := int((last.bounds.x+last.bounds.w/2)*scale)
	last_y := int((last.bounds.y+last.bounds.h/2)*scale)
	last_index := (last_y*pixel_width+last_x)*4
	last_red := pixels[last_index+0]
	last_green := pixels[last_index+1]
	last_blue := pixels[last_index+2]
	if !(last_red == last_green && last_green == last_blue && last_red >= 250) {
		rectangle_validation_fail("painter order did not leave the final opaque rectangle on top")
	}

	// Independent CPU composite at the same scale.
	reference := make([]u8, pixel_width*pixel_height*4)
	defer delete(reference)
	rectangle_validation_cpu_render(scene.rectangles[:], scale, pixel_width, pixel_height,
		RECTANGLE_VALIDATION_BACKGROUND, reference)
	reference_rgb := make([]u8, pixel_width*pixel_height*3)
	defer delete(reference_rgb)
	for pixel in 0..<pixel_width*pixel_height {
		reference_rgb[pixel*3+0] = reference[pixel*4+0]
		reference_rgb[pixel*3+1] = reference[pixel*4+1]
		reference_rgb[pixel*3+2] = reference[pixel*4+2]
	}
	// The channel key rect is opaque and unobstructed, so its sampled pixel
	// fixes the readback order once for the whole case.
	key_x := int((100+16)*scale)
	key_y := int((12+12)*scale)
	key_index := (key_y*pixel_width+key_x)*4
	channel_swap := abs(int(pixels[key_index+2])-230) < abs(int(pixels[key_index+0])-230)
	// The fixture depends on the runtime's default root backdrop, so verify the
	// uncovered top-left pixel instead of silently comparing two backgrounds.
	corner := [3]u8{
		pixels[0+(2 if channel_swap else 0)], pixels[1], pixels[0+(0 if channel_swap else 2)],
	}
	if corner != RECTANGLE_VALIDATION_BACKGROUND {
		rectangle_validation_fail("the runtime root backdrop changed; update the fixture background constant")
	}
	cpu_compare := rectangle_validation_compare_pixels(pixels, pixel_width, pixel_height, reference_rgb, channel_swap)
	if dump_dir != "" {
		gpu_rgb := make([]u8, pixel_width*pixel_height*3)
		defer delete(gpu_rgb)
		for pixel in 0..<pixel_width*pixel_height {
			gpu_rgb[pixel*3+0] = pixels[pixel*4+(2 if channel_swap else 0)]
			gpu_rgb[pixel*3+1] = pixels[pixel*4+1]
			gpu_rgb[pixel*3+2] = pixels[pixel*4+(0 if channel_swap else 2)]
		}
		_ = os.write_entire_file(fmt.tprintf("%s/%s-gpu.rgb", dump_dir, stem), gpu_rgb)
		_ = os.write_entire_file(fmt.tprintf("%s/%s-cpu.rgb", dump_dir, stem), reference_rgb)
	}
	fmt.println("issue_200_background", "gpu", pixels[0+(2 if channel_swap else 0)], pixels[1],
		pixels[0+(0 if channel_swap else 2)], "reference", corner[0], corner[1], corner[2],
		"pixel_format", "BGRA" if channel_swap else "RGBA")
	if !alpha {
		// Opaque geometry is expected to match the CPU compositor exactly at
		// integer scale and within edge rounding at fractional scale.
		allowed_mismatches := 0 if scale == 1 else int(f32(pixel_width*pixel_height)*0.002)
		if cpu_compare.mismatched > allowed_mismatches || cpu_compare.max_delta > 4 {
			rectangle_validation_fail(fmt.tprintf(
				"rectangle readback disagreed with the CPU composite: mismatched=%d max_delta=%d",
				cpu_compare.mismatched, cpu_compare.max_delta))
		}
	} else {
		if cpu_compare.max_delta > 12 || cpu_compare.mean_delta > 2.5 {
			rectangle_validation_fail(fmt.tprintf(
				"translucent rectangle stacking disagreed with the CPU composite: max_delta=%d mean=%.2f",
				cpu_compare.max_delta, cpu_compare.mean_delta))
		}
	}
	fmt.println("issue_200_cpu_readback", "case", name, "rectangles", len(scene.rectangles),
		"vertices", expected_vertices, "geometry_commands", geometry_commands,
		"channel_swap", channel_swap, "mismatched_pixels", cpu_compare.mismatched,
		"max_delta", cpu_compare.max_delta, "mean_delta", cpu_compare.mean_delta,
		"status", "PASS")

	if emit_dir != "" {
		if !wx_reference_scene_write(emit_dir, stem, rectangle_validation_wx_scene(&scene, scale)) {
			rectangle_validation_fail("could not write the wx rectangle scene")
		}
	}
	if wx_dir != "" && !alpha {
		reference_wx, wx_ok := wx_reference_load(wx_dir, stem)
		if !wx_ok { rectangle_validation_fail("wx reference capture is missing for the rectangle case") }
		wx_compare := rectangle_validation_compare_pixels(pixels, pixel_width, pixel_height,
			reference_wx.rgb, channel_swap, 1)
		allowed_exact := 64 // focused pixel (e.g. clipped corner) differences
		allowed_edge := int(f32(pixel_width*pixel_height)*(0.01 if scale == 1 else 0.03))
		wx_ok_result := wx_compare.mismatched <= allowed_exact && wx_compare.edge_only <= allowed_edge
		fmt.println("issue_200_wx_readback", "case", name,
			"mismatched_pixels", wx_compare.mismatched, "edge_only_pixels", wx_compare.edge_only,
			"edge_allowance", allowed_edge, "max_delta", wx_compare.max_delta,
			"mean_delta", wx_compare.mean_delta, "status", "PASS" if wx_ok_result else "FAIL")
		if !wx_ok_result { rectangle_validation_fail("native rectangle readback disagreed with the wxWidgets reference") }
	}
}

// rectangle_validation_overflow proves the shared vertex budget rejects an
// oversized rectangle payload atomically and keeps the accepted revision.
rectangle_validation_overflow :: proc(rt: ^alicorn.Runtime, surface: alicorn.Node_ID) {
	revision_before := rt.nodes[surface].surface_payload_revision
	count_before := len(rt.nodes[surface].surface_rectangles)
	rejections_before := rt.stats.surface_geometry_overflow_rejections
	too_many := make([]alicorn.GPU_Surface_Filled_Rectangle, alicorn.GPU_SURFACE_MAX_VERTICES/alicorn.GPU_SURFACE_RECTANGLE_VERTICES+1)
	defer delete(too_many)
	for index in 0..<len(too_many) {
		too_many[index] = {bounds={f32(index%RECTANGLE_VALIDATION_WIDTH), 0, 4, 4}, color={1, 0, 0, 1}}
	}
	if alicorn.gpu_surface_update_geometry_with_rectangles(rt, surface, too_many, nil, nil) {
		rectangle_validation_fail("an over-budget rectangle payload was accepted")
	}
	if rt.nodes[surface].surface_payload_revision != revision_before ||
		len(rt.nodes[surface].surface_rectangles) != count_before ||
		rt.stats.surface_geometry_overflow_rejections != rejections_before+1 {
		rectangle_validation_fail("rectangle overflow rejection did not preserve the retained payload")
	}
	exact := make([]alicorn.GPU_Surface_Filled_Rectangle, alicorn.GPU_SURFACE_MAX_VERTICES/alicorn.GPU_SURFACE_RECTANGLE_VERTICES)
	defer delete(exact)
	for index in 0..<len(exact) {
		exact[index] = {bounds={f32(index%RECTANGLE_VALIDATION_WIDTH), 0, 4, 2}, color={0.2, 0.4, 0.6, 1}}
	}
	if !alicorn.gpu_surface_update_geometry_with_rectangles(rt, surface, exact, nil, nil) {
		rectangle_validation_fail("the exact vertex-budget rectangle payload was rejected")
	}
	fmt.println("issue_200_overflow", "count_rejected", len(too_many), "count_accepted", len(exact),
		"vertices_accepted", len(exact)*alicorn.GPU_SURFACE_RECTANGLE_VERTICES,
		"budget", alicorn.GPU_SURFACE_MAX_VERTICES, "retained_payload", "preserved", "status", "PASS")
}

Rectangle_Repaint_Sample :: struct {
	describe_ns: i64,
	update_ns:   i64,
	display:     int,
}

// rectangle_validation_repaint_cost compares the batched payload with the
// retained-node path the issue describes: one Surface_Paint node per
// rectangle. Both scenes describe the same column band.
rectangle_validation_repaint_cost :: proc(device: ^sdl3.GPUDevice, format: sdl3.GPUTextureFormat) {
	scene := rectangle_validation_scene(false)
	defer delete(scene.rectangles)
	iterations :: 32
	batched := make([]Rectangle_Repaint_Sample, iterations)
	full := make([]Rectangle_Repaint_Sample, iterations)
	partial := make([]Rectangle_Repaint_Sample, iterations)

	// Batched: payload commit followed by an ordinary frame.
	{
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, RECTANGLE_VALIDATION_WIDTH, RECTANGLE_VALIDATION_HEIGHT})
		defer alicorn.destroy_runtime(&rt)
		_ = alicorn.text_engine_load_default_fonts(&rt)
		surface, ok := rectangle_validation_create_runtime(&rt, 1)
		if !ok { rectangle_validation_fail("batched repaint fixture failed") }
		for sample in 0..<iterations {
			started := time.now()
			if !alicorn.gpu_surface_update_geometry_with_rectangles(&rt, surface, scene.rectangles[:], nil, nil) {
				rectangle_validation_fail("batched repaint payload was rejected")
			}
			batched[sample].update_ns = time.duration_nanoseconds(time.since(started))
			batched[sample].display = len(rt.display)
			started = time.now()
			alicorn.invalidate_root(&rt, "batched repaint benchmark")
			ui, build := alicorn.begin_frame(&rt)
			if !build { rectangle_validation_fail("batched repaint frame was not built") }
			rectangle_validation_describe(&ui, 1)
			alicorn.end_frame(&ui)
			batched[sample].describe_ns = time.duration_nanoseconds(time.since(started))
			batched[sample].display = len(rt.display)
		}
	}

	// Retained nodes: one Surface_Paint rectangle per column, keyed so the
	// retained tree updates in place.
	{
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, RECTANGLE_VALIDATION_WIDTH, RECTANGLE_VALIDATION_HEIGHT})
		defer alicorn.destroy_runtime(&rt)
		_ = alicorn.text_engine_load_default_fonts(&rt)
		colors := make([]alicorn.Color, len(scene.rectangles))
		defer delete(colors)
		for rectangle, index in scene.rectangles {
			colors[index] = alicorn.Color{rectangle.color.r, rectangle.color.g, rectangle.color.b, 1}
		}
		for mode in 0..<2 {
			for sample in 0..<iterations {
				if mode == 0 {
					// Full repaint: every column color changes.
					for index in 0..<len(colors) {
						shade := f32((sample*7+index)%23)/23
						colors[index] = alicorn.Color{shade, 1-shade, f32((index%11))/11, 1}
					}
				} else {
					// Partial repaint: 32 of 1,024 columns change.
					for change in 0..<32 {
						index := (change*29+sample) % len(colors)
						colors[index] = alicorn.Color{1, f32(change)/32, 0.25, 1}
					}
				}
				started := time.now()
				alicorn.invalidate_root(&rt, "retained rectangle repaint benchmark")
				ui, build := alicorn.begin_frame(&rt)
				if !build { rectangle_validation_fail("retained rectangle frame was not built") }
				if alicorn.container_begin(&ui, .Root, label="issue-200-nodes-root",
					key=alicorn.key_string("issue-200-nodes-root"),
					style=alicorn.layout_style(.Column, width=RECTANGLE_VALIDATION_WIDTH,
						height=RECTANGLE_VALIDATION_HEIGHT)) != 0 {
					_ = alicorn.container_begin(&ui, .Container, label="issue-200-nodes-row",
						key=alicorn.key_string("issue-200-nodes-row"),
						style=alicorn.layout_style(.Row, width=RECTANGLE_VALIDATION_WIDTH,
							height=RECTANGLE_VALIDATION_HEIGHT, align=.Center))
					for rectangle, index in scene.rectangles {
						_ = alicorn.container_begin(&ui, .Container, label="issue-200-column",
							key=alicorn.key_u64(u64(index)),
							style=alicorn.layout_style(.Column,
								width=f32(RECTANGLE_VALIDATION_WIDTH)/f32(len(scene.rectangles)),
								height=rectangle.bounds.h),
							color=colors[index])
						alicorn.container_end(&ui)
					}
					alicorn.container_end(&ui)
					alicorn.container_end(&ui)
				}
				alicorn.end_frame(&ui)
				sample_data := Rectangle_Repaint_Sample{
					describe_ns=time.duration_nanoseconds(time.since(started)),
					display=len(rt.display),
				}
				if mode == 0 { full[sample] = sample_data } else { partial[sample] = sample_data }
			}
		}
	}

	describe_ns := make([]i64, iterations, context.temp_allocator)
	update_ns := make([]i64, iterations, context.temp_allocator)
	full_ns := make([]i64, iterations, context.temp_allocator)
	partial_ns := make([]i64, iterations, context.temp_allocator)
	for index in 0..<iterations {
		describe_ns[index] = batched[index].describe_ns
		update_ns[index] = batched[index].update_ns
		full_ns[index] = full[index].describe_ns
		partial_ns[index] = partial[index].describe_ns
	}
	fmt.println("issue_200_repaint", "rectangles", len(scene.rectangles), "samples", iterations,
		"batched_update_p95_ns", point_marker_validation_percentile(update_ns, 0.95),
		"batched_describe_p95_ns", point_marker_validation_percentile(describe_ns, 0.95),
		"batched_display_commands", batched[iterations-1].display,
		"retained_full_describe_p95_ns", point_marker_validation_percentile(full_ns, 0.95),
		"retained_partial_describe_p95_ns", point_marker_validation_percentile(partial_ns, 0.95),
		"retained_display_commands", full[iterations-1].display)

	// The payload update path must not re-describe or re-layout the tree.
	{
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, RECTANGLE_VALIDATION_WIDTH, RECTANGLE_VALIDATION_HEIGHT})
		defer alicorn.destroy_runtime(&rt)
		_ = alicorn.text_engine_load_default_fonts(&rt)
		surface, ok := rectangle_validation_create_runtime(&rt, 1)
		if !ok { rectangle_validation_fail("idle rectangle fixture failed") }
		_ = alicorn.gpu_surface_update_geometry_with_rectangles(&rt, surface, scene.rectangles[:], nil, nil)
		before := rt.stats
		if !alicorn.gpu_surface_update_geometry_with_rectangles(&rt, surface, scene.rectangles[:], nil, nil) {
			rectangle_validation_fail("identical rectangle payload was rejected")
		}
		if rt.stats.layout_nodes_visited != before.layout_nodes_visited ||
			rt.stats.paint_nodes_visited != before.paint_nodes_visited ||
			rt.stats.text_shape_requests != before.text_shape_requests ||
			rt.stats.display_commands_finalized != before.display_commands_finalized {
			rectangle_validation_fail("rectangle payload update re-entered description, layout, paint, or text shaping")
		}
		// A committed payload is pending exactly once; consuming the frame
		// clears it and leaves no idle work.
		if !alicorn.gpu_surface_needs_frame(&rt) || !alicorn.frame_needs_submission(&rt) {
			rectangle_validation_fail("rectangle payload commit did not request exactly one frame")
		}
		alicorn.gpu_surface_frame_consumed(&rt)
		alicorn.frame_submission_succeeded(&rt)
		if alicorn.gpu_surface_needs_frame(&rt) || alicorn.frame_needs_submission(&rt) {
			rectangle_validation_fail("settled rectangle surface continued requesting idle work")
		}
		fmt.println("issue_200_idle", "payload_updates", 2, "layout_visits", rt.stats.layout_nodes_visited-before.layout_nodes_visited,
			"paint_visits", rt.stats.paint_nodes_visited-before.paint_nodes_visited,
			"text_shape_requests", rt.stats.text_shape_requests-before.text_shape_requests,
			"idle_submission_pending", alicorn.frame_needs_submission(&rt),
			"idle_surface_pending", alicorn.gpu_surface_needs_frame(&rt), "status", "PASS")
	}
}


// rectangle_validation_gpu_cost measures the batched payload's production GPU
// path: retained payload update, frame encode, upload bytes, and idle state.
rectangle_validation_gpu_cost :: proc(device: ^sdl3.GPUDevice, format: sdl3.GPUTextureFormat) {
	iterations :: 64
	scene := rectangle_validation_scene(false)
	defer delete(scene.rectangles)
	scale := f32(1)
	pixel_width := RECTANGLE_VALIDATION_WIDTH
	pixel_height := RECTANGLE_VALIDATION_HEIGHT
	allocations := alicorn.Runtime_Allocation_Stats{}
	rt := alicorn.new_runtime(
		alicorn.Rect{0, 0, RECTANGLE_VALIDATION_WIDTH, RECTANGLE_VALIDATION_HEIGHT},
		config=alicorn.Runtime_Config{allocation_stats=&allocations},
	)
	defer alicorn.destroy_runtime(&rt)
	surface, ok := rectangle_validation_create_runtime(&rt, scale)
	if !ok { rectangle_validation_fail("GPU cost fixture failed") }
	renderers, renderer_ok := native_validation_renderers_make(device, format, &rt)
	if !renderer_ok { rectangle_validation_fail("GPU cost renderer initialization failed") }
	defer if renderers.text.device != nil { native_validation_renderers_destroy(&renderers) }
	target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{
		type=.D2, format=format, usage={.COLOR_TARGET}, width=sdl3.Uint32(pixel_width),
		height=sdl3.Uint32(pixel_height), layer_count_or_depth=1, num_levels=1, sample_count=._1,
	})
	if target == nil { rectangle_validation_fail("GPU cost target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, target)

	update_ns := make([]i64, iterations, context.temp_allocator)
	encode_ns := make([]i64, iterations, context.temp_allocator)
	submit_ns := make([]i64, iterations, context.temp_allocator)
	uploads_before := renderers.geometry.vertex_uploads
	bytes_before := renderers.geometry.vertex_upload_bytes
	allocations_before := allocations.persistent_alloc_calls
	update_allocations: u64 = 0
	for sample in 0..<iterations {
		calls_before_update := allocations.persistent_alloc_calls
		started := time.now()
		if !alicorn.gpu_surface_update_geometry_with_rectangles(&rt, surface, scene.rectangles[:], nil, nil) {
			rectangle_validation_fail("GPU cost payload was rejected")
		}
		update_ns[sample] = time.duration_nanoseconds(time.since(started))
		update_allocations += allocations.persistent_alloc_calls-calls_before_update
		encode_ns[sample], submit_ns[sample], ok = native_validation_frame(&rt, &renderers, device, target,
			sdl3.Uint32(pixel_width), sdl3.Uint32(pixel_height), scale)
		if !ok { rectangle_validation_fail("GPU cost frame failed") }
	}
	uploads := renderers.geometry.vertex_uploads-uploads_before
	upload_bytes := renderers.geometry.vertex_upload_bytes-bytes_before
	allocation_calls := allocations.persistent_alloc_calls-allocations_before
	if uploads != iterations {
		rectangle_validation_fail("every changed rectangle revision should upload one retained mesh")
	}
	fmt.println("issue_200_gpu_cost", "rectangles", len(scene.rectangles), "samples", iterations,
		"update_p95_ns", point_marker_validation_percentile(update_ns, 0.95),
		"encode_p95_ns", point_marker_validation_percentile(encode_ns, 0.95),
		"submit_to_fence_p95_ns", point_marker_validation_percentile(submit_ns, 0.95),
		"vertex_bytes_per_upload", upload_bytes/uploads, "vertex_uploads", uploads,
		"persistent_alloc_calls_for_updates", update_allocations,
		"persistent_alloc_calls_update_and_frames", allocation_calls,
		"idle_submission_pending", alicorn.frame_needs_submission(&rt),
		"idle_surface_pending", alicorn.gpu_surface_needs_frame(&rt))
	if alicorn.frame_needs_submission(&rt) || alicorn.gpu_surface_needs_frame(&rt) {
		rectangle_validation_fail("settled rectangle workload continued requesting idle work")
	}
}

RunRectangleValidation :: proc() {
	driver: cstring = nil
	when ODIN_OS == .Darwin { driver = "metal" }
	when ODIN_OS == .Windows { driver = "direct3d12" }
	when ODIN_OS == .Linux { driver = "vulkan" }
	emit_dir, wx_dir, dump_dir: string
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
			} else if strings.has_prefix(arg, "--dump=") {
				dump_dir = arg[len("--dump="):]
			} else {
				rectangle_validation_fail("unknown rectangle validation argument")
			}
		}
	}
	if !sdl3.Init(sdl3.INIT_VIDEO) { rectangle_validation_fail("SDL video initialization failed") }
	defer sdl3.Quit()
	window := sdl3.CreateWindow("Alicorn #200 rectangle validation", 640, 320, {.HIDDEN, .HIGH_PIXEL_DENSITY})
	if window == nil { rectangle_validation_fail("hidden validation window creation failed") }
	defer sdl3.DestroyWindow(window)
	device := sdl3.CreateGPUDevice({.DXIL, .MSL, .SPIRV}, true, driver)
	if device == nil || !sdl3.ClaimWindowForGPUDevice(device, window) {
		rectangle_validation_fail("SDL_GPU device creation or window claim failed")
	}
	defer {
		_ = sdl3.WaitForGPUIdle(device)
		sdl3.ReleaseWindowFromGPUDevice(device, window)
		sdl3.DestroyGPUDevice(device)
	}
	format := sdl3.GetGPUSwapchainTextureFormat(device, window)
	fmt.println("issue_200_backend", "driver", sdl3.GetGPUDeviceDriver(device), "format", format,
		"gpu_timestamps", "not exposed by current SDL3 binding")
	if emit_dir != "" { _ = os.mkdir(emit_dir) }

	for scale in ([2]f32{1, 1.5}) {
		rectangle_validation_run_case(device, format, scale, false, emit_dir, wx_dir, dump_dir)
	}
	rectangle_validation_run_case(device, format, 1, true, emit_dir, wx_dir, dump_dir)
	{
		rt := alicorn.new_runtime(alicorn.Rect{0, 0, RECTANGLE_VALIDATION_WIDTH, RECTANGLE_VALIDATION_HEIGHT})
		defer alicorn.destroy_runtime(&rt)
		_ = alicorn.text_engine_load_default_fonts(&rt)
		surface, ok := rectangle_validation_create_runtime(&rt, 1)
		if !ok { rectangle_validation_fail("overflow fixture failed") }
		scene := rectangle_validation_scene(false)
		defer delete(scene.rectangles)
		_ = alicorn.gpu_surface_update_geometry_with_rectangles(&rt, surface, scene.rectangles[:], nil, nil)
		rectangle_validation_overflow(&rt, surface)
	}
	rectangle_validation_repaint_cost(device, format)
	rectangle_validation_gpu_cost(device, format)
	fmt.println("issue_200_validation", "status", "PASS", "readback", "CPU composite",
		"native_wx_bitmap_reference", "compared" if wx_dir != "" else "not supplied")
}
