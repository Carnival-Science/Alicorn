package alicorn_sdl_gpu

// Issue #164: compare ordinary retained geometry surfaces with a private,
// host-owned custom-pass prototype using the Punks waveform composition.
// This is validation code only; it does not expose raw SDL_GPU objects to apps.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import alicorn "../../runtime"
import "vendor:sdl3"

GPU_CANVAS_VALIDATION_LOGICAL_WIDTH :: 640
GPU_CANVAS_VALIDATION_LOGICAL_HEIGHT :: 400
GPU_CANVAS_VALIDATION_GRAPHS :: 2
GPU_CANVAS_VALIDATION_PEAK_COLUMNS :: 512
GPU_CANVAS_VALIDATION_PEAK_SEGMENTS :: GPU_CANVAS_VALIDATION_PEAK_COLUMNS + 2
GPU_CANVAS_VALIDATION_HEAD_SEGMENTS :: 6
GPU_CANVAS_VALIDATION_CIRCLE_VERTICES :: alicorn.GPU_SURFACE_CIRCLE_SEGMENTS * 3
GPU_CANVAS_VALIDATION_SAMPLES :: 64
GPU_CANVAS_VALIDATION_RAPID_UPDATES :: 128
GPU_Canvas_Validation_Case :: struct { scale: f32, width, height: int }

GPU_Canvas_Validation_Graph :: struct {
	peak_node, head_node, seek_node: alicorn.Node_ID,
	position: f32,
	peak_segments: []alicorn.GPU_Surface_Line_Segment,
	head_segments: []alicorn.GPU_Surface_Line_Segment,
	head_segment_count: int,
	head_circles: []alicorn.GPU_Surface_Filled_Circle,
	head_focused: bool,
	peak_vertices: [dynamic]Native_Text_Vertex,
	peak_vertex_buffer: ^sdl3.GPUBuffer,
	peak_upload_buffer: ^sdl3.GPUTransferBuffer,
	peak_vertex_count: int,
	peak_gpu_bytes: u64,
}

GPU_Canvas_Validation_App :: struct {
	runtime: ^alicorn.Runtime,
	graphs: [GPU_CANVAS_VALIDATION_GRAPHS]GPU_Canvas_Validation_Graph,
	dpi_scale: f32,
	custom: bool,
	custom_passes: int,
	custom_vertex_bytes: u64,
	custom_uploads: u64,
	custom_static_uploads: u64,
	custom_static_upload_bytes: u64,
}

GPU_Canvas_Validation_Samples :: struct {
	update_ns: []i64,
	encode_ns: []i64,
	submit_to_fence_ns: []i64,
	vertex_bytes: []u64,
	vertex_uploads: []u64,
	geometry_passes: []u64,
}

gpu_canvas_validation_fail :: proc(message: string) -> ! {
	fmt.eprintln("issue_164_validation", "FAIL", message, "SDL", sdl3.GetError())
	os.exit(1)
}

gpu_canvas_validation_init_graph :: proc(graph: ^GPU_Canvas_Validation_Graph, position: f32) {
	graph.position = position
	graph.peak_segments = make([]alicorn.GPU_Surface_Line_Segment, GPU_CANVAS_VALIDATION_PEAK_SEGMENTS)
	graph.head_segments = make([]alicorn.GPU_Surface_Line_Segment, GPU_CANVAS_VALIDATION_HEAD_SEGMENTS)
	graph.head_circles = make([]alicorn.GPU_Surface_Filled_Circle, 1)
}

gpu_canvas_validation_destroy_app :: proc(app: ^GPU_Canvas_Validation_App, device: ^sdl3.GPUDevice) {
	if app == nil { return }
	for graph in app.graphs {
		if graph.peak_upload_buffer != nil { sdl3.ReleaseGPUTransferBuffer(device, graph.peak_upload_buffer) }
		if graph.peak_vertex_buffer != nil { sdl3.ReleaseGPUBuffer(device, graph.peak_vertex_buffer) }
		if len(graph.peak_segments) > 0 { delete(graph.peak_segments) }
		if len(graph.head_segments) > 0 { delete(graph.head_segments) }
		if len(graph.head_circles) > 0 { delete(graph.head_circles) }
		delete(graph.peak_vertices)
	}
	app^ = {}
}

gpu_canvas_validation_describe :: proc(app: ^GPU_Canvas_Validation_App) -> bool {
	rt := app.runtime
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return true }
	alicorn.container_begin(&ui, .Root, key=alicorn.key_string("issue-164.root"),
		style=alicorn.layout_style(.Column, padding=12, gap=8, clip=true))
	columns := [1]alicorn.Grid_Track{alicorn.grid_fraction(1)}
	rows := [2]alicorn.Grid_Track{alicorn.grid_fraction(1), alicorn.grid_fraction(1)}
	outer := alicorn.grid_begin(&ui, alicorn.key_string("issue-164.graphs"), columns[:], rows[:],
		style=alicorn.layout_style(.Column, grow=1, clip=true), gap_y=8, label="waveform canvases")
	if outer == 0 { return false }
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		graph_key := fmt.tprintf("issue-164.graph.%d", i)
		inner_rows := [1]alicorn.Grid_Track{alicorn.grid_fraction(1)}
		inner := alicorn.grid_begin(&ui, alicorn.key_string(graph_key), columns[:], inner_rows[:],
			style=alicorn.layout_style(.Column, grow=1, clip=true), label="waveform timeline")
		if inner == 0 { return false }
		owner := alicorn.container_begin(&ui, .Container, key=alicorn.key_string(fmt.tprintf("issue-164.seek-owner.%d", i)),
			style=alicorn.layout_style(.Column, grow=1, clip=true))
		seek_key := alicorn.key_string(fmt.tprintf("issue-164.seek.%d", i))
		seek := alicorn.slider_f32(&ui,
			fmt.tprintf("Waveform position %d", i+1),
			app.graphs[i].position, 0, 1, 0.01,
			key=seek_key,
			style=alicorn.layout_style(.Column, grow=1, clip=true),
		)
		app.graphs[i].position = seek.value
		alicorn.container_end(&ui)
		_ = alicorn.grid_cell(&ui, owner, 0, 0)
		app.graphs[i].peak_node = alicorn.gpu_geometry_surface(&ui,
			fmt.tprintf("issue-164.peaks.%d", i), alicorn.layout_style(.Column, grow=1, clip=true), app.dpi_scale)
		_ = alicorn.grid_cell(&ui, app.graphs[i].peak_node, 0, 0)
		app.graphs[i].head_node = alicorn.gpu_geometry_surface(&ui,
			fmt.tprintf("issue-164.playhead.%d", i), alicorn.layout_style(.Column, grow=1, clip=true), app.dpi_scale)
		_ = alicorn.grid_cell(&ui, app.graphs[i].head_node, 0, 0)
		alicorn.grid_end(&ui)
		_ = alicorn.grid_cell(&ui, inner, i, 0)
	}
	alicorn.grid_end(&ui)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		app.graphs[i].seek_node, _ = alicorn.node_by_key(rt,
			alicorn.key_string(fmt.tprintf("issue-164.seek.%d", i)), .Slider)
		app.graphs[i].head_focused = alicorn.focused_node(rt) == app.graphs[i].seek_node
	}
	return true
}

gpu_canvas_validation_build :: proc(app: ^GPU_Canvas_Validation_App, reason := "issue-164 initial fixture") -> bool {
	alicorn.invalidate_root(app.runtime, reason)
	return gpu_canvas_validation_describe(app)
}

gpu_canvas_validation_prepare_data :: proc(app: ^GPU_Canvas_Validation_App) -> bool {
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		graph := &app.graphs[i]
		ctx, ok := alicorn.gpu_surface_context(app.runtime, graph.peak_node)
		head_ctx, head_ok := alicorn.gpu_surface_context(app.runtime, graph.head_node)
		if !ok || !head_ok || ctx.logical_bounds != head_ctx.logical_bounds || ctx.clip != head_ctx.clip { return false }
		bounds := ctx.logical_bounds
		if bounds.w < 80 || bounds.h < 40 { return false }
		background := alicorn.Color{0.12, 0.16, 0.20, 1}
		accent := alicorn.Color{0.22, 0.71, 0.84, 1}
		peak_accent := alicorn.Color{0.39, 0.79, 0.84, 1}
		baseline := accent
		baseline.a = 0.2
		graph.peak_segments[0] = {start={2, bounds.h/2}, end={bounds.w-2, bounds.h/2}, thickness=bounds.h-4, color=background}
		graph.peak_segments[1] = {start={8, bounds.h/2}, end={bounds.w-8, bounds.h/2}, thickness=1, color=baseline}
		for column in 0..<GPU_CANVAS_VALIDATION_PEAK_COLUMNS {
			// Deterministic signed min/max-like envelope. The two panes have
			// different signals, like independent tracks in a listening deck.
			x := 8+(f32(column)+0.5)*(bounds.w-16)/f32(GPU_CANVAS_VALIDATION_PEAK_COLUMNS)
			phase := f32(column)*0.071 + f32(i)*1.1
			amplitude := 0.18 + 0.72*(0.5+0.5*math.sin(phase*0.43))*(0.35+0.65*math.abs(math.sin(phase)))
			half := bounds.h*0.5-8
			top, bottom := bounds.h*0.5-amplitude*half, bounds.h*0.5+amplitude*half
			graph.peak_segments[column+2] = {start={x, top}, end={x, max(top+1, bottom)}, thickness=1.25, color=peak_accent}
		}
		gpu_canvas_validation_head_update(graph, bounds)
		if !app.custom {
			if !alicorn.gpu_surface_update_geometry(app.runtime, graph.peak_node, graph.peak_segments, nil) { return false }
			if !alicorn.gpu_surface_update_geometry(app.runtime, graph.head_node,
				graph.head_segments[:graph.head_segment_count], graph.head_circles) { return false }
		}
	}
	return true
}

gpu_canvas_validation_head_update :: proc(graph: ^GPU_Canvas_Validation_Graph, bounds: alicorn.Rect) {
	position := graph.position
	x := 8+position*(bounds.w-16)
	graph.head_segment_count = 0
	progress := alicorn.Color{0.22, 0.71, 0.84, 0.12}
	if x > 8 {
		graph.head_segments[graph.head_segment_count] = {
			start={8, bounds.h/2}, end={x, bounds.h/2}, thickness=bounds.h-8, color=progress,
		}
		graph.head_segment_count += 1
	}
	head_color := alicorn.Color{1, 0.73, 0.26, 1}
	graph.head_segments[graph.head_segment_count] = {
		start={x, 4}, end={x, bounds.h-4}, thickness=2, color=head_color,
	}
	graph.head_segment_count += 1
	if graph.head_focused {
		graph.head_segments[graph.head_segment_count] = {start={1, 1}, end={bounds.w-1, 1}, thickness=1, color={0.22, 0.71, 0.84, 1}}
		graph.head_segment_count += 1
		graph.head_segments[graph.head_segment_count] = {start={1, bounds.h-1}, end={bounds.w-1, bounds.h-1}, thickness=1, color={0.22, 0.71, 0.84, 1}}
		graph.head_segment_count += 1
		graph.head_segments[graph.head_segment_count] = {start={1, 1}, end={1, bounds.h-1}, thickness=1, color={0.22, 0.71, 0.84, 1}}
		graph.head_segment_count += 1
		graph.head_segments[graph.head_segment_count] = {start={bounds.w-1, 1}, end={bounds.w-1, bounds.h-1}, thickness=1, color={0.22, 0.71, 0.84, 1}}
		graph.head_segment_count += 1
	}
	graph.head_circles[0] = {center={x, 5}, radius=3, color=head_color}
}

gpu_canvas_validation_update_public :: proc(app: ^GPU_Canvas_Validation_App, positions: [GPU_CANVAS_VALIDATION_GRAPHS]f32) -> bool {
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		graph := &app.graphs[i]
		graph.position = alicorn.clampf(positions[i], 0, 1)
		ctx, ok := alicorn.gpu_surface_context(app.runtime, graph.head_node)
		if !ok { return false }
		gpu_canvas_validation_head_update(graph, ctx.logical_bounds)
		if !alicorn.gpu_surface_update_geometry(app.runtime, graph.head_node,
			graph.head_segments[:graph.head_segment_count], graph.head_circles) { return false }
	}
	return true
}

gpu_canvas_validation_custom_update :: proc(app: ^GPU_Canvas_Validation_App, positions: [GPU_CANVAS_VALIDATION_GRAPHS]f32) {
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		graph := &app.graphs[i]
		graph.position = alicorn.clampf(positions[i], 0, 1)
		ctx, ok := alicorn.gpu_surface_context(app.runtime, graph.head_node)
		if ok { gpu_canvas_validation_head_update(graph, ctx.logical_bounds) }
	}
}

gpu_canvas_validation_scissor :: proc(bounds, clip: alicorn.Rect, scale_x, scale_y: f32, target_w, target_h: sdl3.Uint32) -> (scissor: sdl3.Rect, visible: bool) {
	left := max(bounds.x, clip.x)
	top := max(bounds.y, clip.y)
	right := min(bounds.x+bounds.w, clip.x+clip.w)
	bottom := min(bounds.y+bounds.h, clip.y+clip.h)
	if right <= left || bottom <= top { return }
	x0, y0, x1, y1 := logical_to_pixel_bounds(alicorn.Rect{left, top, right-left, bottom-top}, scale_x, scale_y)
	x0 = max(x0, 0); y0 = max(y0, 0)
	x1 = min(x1, int(target_w)); y1 = min(y1, int(target_h))
	if x1 <= x0 || y1 <= y0 { return }
	scissor = sdl3.Rect{x=c.int(x0), y=c.int(y0), w=c.int(x1-x0), h=c.int(y1-y0)}
	return scissor, true
}

gpu_canvas_validation_custom_pass :: proc(
	data: rawptr,
	renderer: ^Native_Surface_Renderer,
	command: ^sdl3.GPUCommandBuffer,
	paint: alicorn.Paint_Command,
	target: ^sdl3.GPUTexture,
	target_w, target_h: sdl3.Uint32,
	scale_x, scale_y: f32,
) -> bool {
	app := cast(^GPU_Canvas_Validation_App)data
	graph_index := -1
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		if app.graphs[i].peak_node == paint.owner { graph_index = i; break }
	}
	if graph_index < 0 { return false }
	graph := &app.graphs[graph_index]
	peak_ctx, peak_ok := alicorn.gpu_surface_context(app.runtime, graph.peak_node)
	head_ctx, head_ok := alicorn.gpu_surface_context(app.runtime, graph.head_node)
	if !peak_ok || !head_ok || peak_ctx.logical_bounds != head_ctx.logical_bounds || peak_ctx.clip != head_ctx.clip { return false }
	if !native_surface_marker_mask_prepare(renderer, command) { return false }
	clear(&renderer.vertices)
	if !native_surface_append_geometry(&renderer.vertices, head_ctx.logical_bounds, scale_x, scale_y,
		nil, graph.head_segments[:graph.head_segment_count], graph.head_circles, nil, paint.opacity) { return false }
	if len(renderer.vertices) == 0 { return true }
	renderer.vertex_upload_pending = true
	if !native_surface_upload_vertices(renderer, command) { return false }
	uniforms := Native_Text_Uniforms{
		proj_view = [4][4]f32{
			{2/f32(target_w), 0, 0, 0}, {0, -2/f32(target_h), 0, 0},
			{0, 0, 1, 0}, {-1, 1, 0, 1},
		},
		model = [4][4]f32{{1,0,0,0},{0,1,0,0},{0,0,1,0},{0,0,0,1}},
	}
	sdl3.PushGPUVertexUniformData(command, 0, &uniforms, sdl3.Uint32(size_of(Native_Text_Uniforms)))
	target_info := sdl3.GPUColorTargetInfo{texture=target, load_op=.LOAD, store_op=.STORE}
	pass := sdl3.BeginGPURenderPass(command, &target_info, 1, nil)
	if pass == nil { return false }
	sdl3.BindGPUGraphicsPipeline(pass, renderer.pipeline)
	sdl3.SetGPUViewport(pass, sdl3.GPUViewport{0, 0, f32(target_w), f32(target_h), 0, 1})
	if scissor, visible := gpu_canvas_validation_scissor(peak_ctx.logical_bounds, peak_ctx.clip,
		scale_x, scale_y, target_w, target_h); visible {
		sdl3.SetGPUScissor(pass, scissor)
		binding := sdl3.GPUBufferBinding{buffer=graph.peak_vertex_buffer, offset=0}
		sdl3.BindGPUVertexBuffers(pass, 0, &binding, 1)
		mask_binding := sdl3.GPUTextureSamplerBinding{texture=renderer.shape_mask_texture, sampler=renderer.sampler}
		sdl3.BindGPUFragmentSamplers(pass, 0, &mask_binding, 1)
		sdl3.DrawGPUPrimitives(pass, sdl3.Uint32(graph.peak_vertex_count), 1, 0, 0)
		dynamic_binding := sdl3.GPUBufferBinding{buffer=renderer.vertex_buffer, offset=0}
		sdl3.BindGPUVertexBuffers(pass, 0, &dynamic_binding, 1)
		sdl3.DrawGPUPrimitives(pass, sdl3.Uint32(len(renderer.vertices)), 1, 0, 0)
	}
	sdl3.EndGPURenderPass(pass)
	renderer.encodes += 1
	app.custom_passes += 1
	app.custom_uploads += 1
	app.custom_vertex_bytes += u64(len(renderer.vertices)*size_of(Native_Text_Vertex))
	return true
}

gpu_canvas_validation_custom_static_upload :: proc(
	app: ^GPU_Canvas_Validation_App,
	graph: ^GPU_Canvas_Validation_Graph,
	renderer: ^Native_Surface_Renderer,
	command: ^sdl3.GPUCommandBuffer,
	graph_index: int,
) -> bool {
	ctx, ok := alicorn.gpu_surface_context(app.runtime, graph.peak_node)
	if !ok { return false }
	clear(&graph.peak_vertices)
	if !native_surface_append_geometry(&graph.peak_vertices, ctx.logical_bounds, app.dpi_scale, app.dpi_scale,
		nil, graph.peak_segments, nil, nil) { return false }
	if len(graph.peak_vertices) == 0 || len(graph.peak_vertices)+GPU_CANVAS_VALIDATION_HEAD_SEGMENTS*6+GPU_CANVAS_VALIDATION_CIRCLE_VERTICES > alicorn.GPU_SURFACE_MAX_VERTICES { return false }
	graph.peak_vertex_count = len(graph.peak_vertices)
	bytes := len(graph.peak_vertices)*size_of(Native_Text_Vertex)
	graph.peak_vertex_buffer = sdl3.CreateGPUBuffer(renderer.device, sdl3.GPUBufferCreateInfo{
		usage={.VERTEX}, size=sdl3.Uint32(bytes),
	})
	graph.peak_upload_buffer = sdl3.CreateGPUTransferBuffer(renderer.device, sdl3.GPUTransferBufferCreateInfo{
		usage=.UPLOAD, size=sdl3.Uint32(bytes),
	})
	if graph.peak_vertex_buffer == nil || graph.peak_upload_buffer == nil { return false }
	mapped := sdl3.MapGPUTransferBuffer(renderer.device, graph.peak_upload_buffer, true)
	if mapped == nil { return false }
	copy((cast([^]Native_Text_Vertex)mapped)[:len(graph.peak_vertices)], graph.peak_vertices[:])
	sdl3.UnmapGPUTransferBuffer(renderer.device, graph.peak_upload_buffer)
	copy_pass := sdl3.BeginGPUCopyPass(command)
	if copy_pass == nil { return false }
	sdl3.UploadToGPUBuffer(copy_pass,
		sdl3.GPUTransferBufferLocation{transfer_buffer=graph.peak_upload_buffer, offset=0},
		sdl3.GPUBufferRegion{buffer=graph.peak_vertex_buffer, offset=0, size=sdl3.Uint32(bytes)}, true)
	sdl3.EndGPUCopyPass(copy_pass)
	graph.peak_gpu_bytes = u64(bytes)
	app.custom_static_uploads += 1
	app.custom_static_upload_bytes += u64(bytes)
	_ = graph_index
	return true
}

gpu_canvas_validation_create_static_peaks :: proc(app: ^GPU_Canvas_Validation_App, renderer: ^Native_Surface_Renderer) -> bool {
	command := sdl3.AcquireGPUCommandBuffer(renderer.device)
	if command == nil { return false }
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		if !gpu_canvas_validation_custom_static_upload(app, &app.graphs[i], renderer, command, i) {
			_ = sdl3.CancelGPUCommandBuffer(command)
			return false
		}
	}
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	if fence == nil { return false }
	fences := [1]^sdl3.GPUFence{fence}
	ok := sdl3.WaitForGPUFences(renderer.device, true, &fences[0], 1)
	sdl3.ReleaseGPUFence(renderer.device, fence)
	if !ok { return false }
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		graph := &app.graphs[i]
		if graph.peak_upload_buffer != nil {
			sdl3.ReleaseGPUTransferBuffer(renderer.device, graph.peak_upload_buffer)
			graph.peak_upload_buffer = nil
		}
	}
	return true
}

gpu_canvas_validation_render :: proc(
	app: ^GPU_Canvas_Validation_App,
	renderer: ^Native_Surface_Renderer,
	target: ^sdl3.GPUTexture,
	target_w, target_h: sdl3.Uint32,
	scale_x, scale_y: f32,
	pixels: []u8 = nil,
	download: ^sdl3.GPUTransferBuffer = nil,
) -> (encode_ns: i64, bytes: u64, uploads, geometry_passes: u64, fence_ns: i64, ok: bool) {
	command := sdl3.AcquireGPUCommandBuffer(renderer.device)
	if command == nil { return }
	started := time.now()
	clear_info := make_color_target(target, sdl3.FColor{0.04, 0.05, 0.07, 1}, false)
	clear_pass := sdl3.BeginGPURenderPass(command, &clear_info, 1, nil)
	if clear_pass == nil { _ = sdl3.CancelGPUCommandBuffer(command); return }
	sdl3.EndGPURenderPass(clear_pass)
	vertex_uploads_before := renderer.vertex_uploads
	geometry_passes_before := renderer.encodes
	if !app.custom {
		for paint in app.runtime.display {
			if !alicorn.paint_command_is_geometry(paint) { continue }
			before := renderer.vertex_uploads
			if !native_surface_render_command(renderer, command, paint, target, target_w, target_h, scale_x, scale_y) {
				_ = sdl3.CancelGPUCommandBuffer(command)
				native_surface_cancel_unsubmitted_mask_upload(renderer, renderer.shape_mask_initialized)
				return
			}
			if renderer.vertex_uploads != before {
				bytes += u64(len(renderer.vertices)*size_of(Native_Text_Vertex))
				uploads += 1
			}
		}
	} else {
		for paint in app.runtime.display {
			if !alicorn.paint_command_is_geometry(paint) { continue }
			head_owner := false
			for graph in app.graphs { if graph.head_node == paint.owner { head_owner = true; break } }
			if head_owner { continue }
			before := renderer.vertex_uploads
			if !gpu_canvas_validation_custom_pass(app, renderer, command, paint, target, target_w, target_h, scale_x, scale_y) {
				_ = sdl3.CancelGPUCommandBuffer(command)
				native_surface_cancel_unsubmitted_mask_upload(renderer, renderer.shape_mask_initialized)
				return
			}
			if renderer.vertex_uploads != before {
				uploads += 1
				bytes += u64(len(renderer.vertices)*size_of(Native_Text_Vertex))
			}
		}
	}
	if download != nil {
		copy_pass := sdl3.BeginGPUCopyPass(command)
		if copy_pass == nil { _ = sdl3.CancelGPUCommandBuffer(command); return }
		sdl3.DownloadFromGPUTexture(copy_pass,
			sdl3.GPUTextureRegion{texture=target, w=target_w, h=target_h, d=1},
			sdl3.GPUTextureTransferInfo{transfer_buffer=download, pixels_per_row=target_w, rows_per_layer=target_h})
		sdl3.EndGPUCopyPass(copy_pass)
	}
	encode_ns = time.duration_nanoseconds(time.since(started))
	uploads = renderer.vertex_uploads-vertex_uploads_before
	geometry_passes = renderer.encodes-geometry_passes_before
	fence_started := time.now()
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	if fence == nil {
		native_surface_cancel_unsubmitted_mask_upload(renderer, renderer.shape_mask_initialized)
		return encode_ns, bytes, uploads, geometry_passes, 0, false
	}
	native_surface_commit_submission(renderer)
	fences := [1]^sdl3.GPUFence{fence}
	ok = sdl3.WaitForGPUFences(renderer.device, true, &fences[0], 1)
	fence_ns = time.duration_nanoseconds(time.since(fence_started))
	sdl3.ReleaseGPUFence(renderer.device, fence)
	if !ok { return encode_ns, bytes, uploads, geometry_passes, fence_ns, false }
	if download != nil && len(pixels) > 0 {
		mapped := sdl3.MapGPUTransferBuffer(renderer.device, download, false)
		if mapped == nil { return encode_ns, bytes, uploads, geometry_passes, fence_ns, false }
		copy(pixels, (cast([^]u8)mapped)[:len(pixels)])
		sdl3.UnmapGPUTransferBuffer(renderer.device, download)
	}
	alicorn.gpu_surface_frame_consumed(app.runtime)
	alicorn.frame_submission_succeeded(app.runtime)
	return encode_ns, bytes, uploads, geometry_passes, fence_ns, true
}

gpu_canvas_validation_make_target :: proc(device: ^sdl3.GPUDevice, format: sdl3.GPUTextureFormat, width, height: u32) -> ^sdl3.GPUTexture {
	return sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{
		type=.D2, format=format, usage={.COLOR_TARGET},
		width=sdl3.Uint32(width), height=sdl3.Uint32(height), layer_count_or_depth=1, num_levels=1, sample_count=._1,
	})
}

gpu_canvas_validation_effect_side :: proc(
	app: ^GPU_Canvas_Validation_App,
	renderer: ^Native_Surface_Renderer,
	cache: ^Native_Effect_Cache,
	plan: Native_Effect_Plan,
	target: ^sdl3.GPUTexture,
	target_w, target_h: sdl3.Uint32,
	download: ^sdl3.GPUTransferBuffer,
	pixels: []u8,
) -> bool {
	if native_effect_prepare(cache, plan) != .Render { return false }
	command := sdl3.AcquireGPUCommandBuffer(renderer.device)
	if command == nil { native_effect_abort(cache); return false }
	submitted := false
	defer if !submitted {
		_ = sdl3.CancelGPUCommandBuffer(command)
		native_effect_abort(cache)
	}
	if !native_effect_capture_clear(command, cache.source) { return false }
	if app.custom {
		for paint in app.runtime.display {
			if !alicorn.paint_command_is_geometry(paint) { continue }
			draw := paint.payload.(alicorn.Geometry_Paint)
			if draw.geometry.resource == 0 { return false }
			head_owner := false
			for graph in app.graphs { if graph.head_node == paint.owner { head_owner = true; break } }
			if head_owner { continue }
			if !gpu_canvas_validation_custom_pass(app, renderer, command, paint, cache.source,
				plan.width, plan.height, plan.scale, plan.scale) { return false }
		}
	} else {
		local := native_effect_local_prefix(app.runtime.display[:], plan.source_bounds, context.temp_allocator)
		if local == nil && len(app.runtime.display) > 0 { return false }
		for paint in local {
			if !alicorn.paint_command_is_geometry(paint) { continue }
			if !native_surface_render_command(renderer, command, paint, cache.source,
				plan.width, plan.height, plan.scale, plan.scale) { return false }
		}
	}
	output_clear := make_color_target(target, sdl3.FColor{0.04, 0.05, 0.07, 1}, false)
	clear_pass := sdl3.BeginGPURenderPass(command, &output_clear, 1, nil)
	if clear_pass == nil { return false }
	sdl3.EndGPURenderPass(clear_pass)
	if !native_effect_encode(cache, command) || !native_effect_composite(cache, command, target, target_w, target_h) { return false }
	copy_pass := sdl3.BeginGPUCopyPass(command)
	if copy_pass == nil { return false }
	sdl3.DownloadFromGPUTexture(copy_pass,
		sdl3.GPUTextureRegion{texture=target, w=target_w, h=target_h, d=1},
		sdl3.GPUTextureTransferInfo{transfer_buffer=download, pixels_per_row=target_w, rows_per_layer=target_h})
	sdl3.EndGPUCopyPass(copy_pass)
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	submitted = true
	if fence == nil { native_effect_abort(cache); return false }
	native_surface_commit_submission(renderer)
	native_effect_commit(cache)
	fences := [1]^sdl3.GPUFence{fence}
	ok := sdl3.WaitForGPUFences(renderer.device, true, &fences[0], 1)
	sdl3.ReleaseGPUFence(renderer.device, fence)
	if !ok { return false }
	mapped := sdl3.MapGPUTransferBuffer(renderer.device, download, false)
	if mapped == nil { return false }
	copy(pixels, (cast([^]u8)mapped)[:len(pixels)])
	sdl3.UnmapGPUTransferBuffer(renderer.device, download)
	return true
}

gpu_canvas_validation_release_static_peaks :: proc(app: ^GPU_Canvas_Validation_App, device: ^sdl3.GPUDevice) {
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		graph := &app.graphs[i]
		if graph.peak_upload_buffer != nil { sdl3.ReleaseGPUTransferBuffer(device, graph.peak_upload_buffer) }
		if graph.peak_vertex_buffer != nil { sdl3.ReleaseGPUBuffer(device, graph.peak_vertex_buffer) }
		graph.peak_upload_buffer = nil
		graph.peak_vertex_buffer = nil
		graph.peak_vertex_count = 0
		graph.peak_gpu_bytes = 0
	}
}

gpu_canvas_validation_runtime_make :: proc(rt: ^alicorn.Runtime, width, height: f32, app: ^GPU_Canvas_Validation_App, stats: ^alicorn.Runtime_Allocation_Stats) -> bool {
	rt^ = alicorn.new_runtime(alicorn.Rect{0, 0, width, height}, config=alicorn.Runtime_Config{allocation_stats=stats})
	if !alicorn.text_engine_load_default_fonts(rt) { return false }
	app.runtime = rt
	if !gpu_canvas_validation_build(app) { return false }
	if !gpu_canvas_validation_prepare_data(app) { return false }
	return true
}

gpu_canvas_validation_semantics :: proc(app: ^GPU_Canvas_Validation_App) -> bool {
	for graph in app.graphs {
		semantic, found := alicorn.semantic_node_lookup(app.runtime, alicorn.semantic_visual_id(graph.seek_node))
		if !found || semantic.role != .Slider || !semantic.has_numeric_value ||
			semantic.numeric_minimum != 0 || semantic.numeric_maximum != 1 || math.abs(semantic.numeric_step-0.01) > 0.00001 {
			return false
		}
	}
	return true
}

gpu_canvas_validation_input :: proc(app: ^GPU_Canvas_Validation_App, target_fraction: f32) -> (elapsed_ns: i64, ok: bool) {
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		info, found := alicorn.node_info(app.runtime, app.graphs[i].seek_node)
		if !found || info.bounds.w <= 0 { return 0, false }
		before := app.graphs[i].position
		started := time.now()
		_ = alicorn.process_pointer(app.runtime, alicorn.Pointer_Event{kind=.Down,
			x=info.bounds.x+info.bounds.w*target_fraction, y=info.bounds.y+info.bounds.h*0.5, button=alicorn.POINTER_BUTTON_PRIMARY})
		_ = alicorn.process_pointer(app.runtime, alicorn.Pointer_Event{kind=.Up,
			x=info.bounds.x+info.bounds.w*target_fraction, y=info.bounds.y+info.bounds.h*0.5, button=alicorn.POINTER_BUTTON_PRIMARY})
		if !gpu_canvas_validation_describe(app) { return 0, false }
		if math.abs(app.graphs[i].position-before) < 0.001 { return 0, false }
		elapsed_ns += time.duration_nanoseconds(time.since(started))
	}
	if !gpu_canvas_validation_prepare_data(app) { return elapsed_ns, false }
	return elapsed_ns, gpu_canvas_validation_semantics(app)
}

gpu_canvas_validation_compare_pixels :: proc(a, b: []u8) -> (different, max_delta: int) {
	if len(a) != len(b) { return max(len(a), len(b)), 255 }
	for i in 0..<len(a) {
		if a[i] != b[i] { different += 1; max_delta = max(max_delta, abs(int(a[i])-int(b[i]))) }
	}
	return
}

gpu_canvas_validation_percentile :: proc(values: []i64, percentile: f32) -> i64 {
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
	index := int(f32(len(sorted)-1)*percentile+0.999)
	return sorted[min(index, len(sorted)-1)]
}

gpu_canvas_validation_run_scale_case :: proc(
	device: ^sdl3.GPUDevice,
	format: sdl3.GPUTextureFormat,
	scale: f32,
	logical_width, logical_height: int,
	benchmark := false,
	) {
	width, height := sdl3.Uint32(f32(logical_width)*scale), sdl3.Uint32(f32(logical_height)*scale)
	public_app := GPU_Canvas_Validation_App{dpi_scale=scale}
	custom_app := GPU_Canvas_Validation_App{dpi_scale=scale, custom=true}
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		gpu_canvas_validation_init_graph(&public_app.graphs[i], 0.2+f32(i)*0.55)
		gpu_canvas_validation_init_graph(&custom_app.graphs[i], public_app.graphs[i].position)
	}
	defer {
		gpu_canvas_validation_destroy_app(&public_app, device)
		gpu_canvas_validation_destroy_app(&custom_app, device)
	}
	public_allocations := alicorn.Runtime_Allocation_Stats{}
	custom_allocations := alicorn.Runtime_Allocation_Stats{}
	public_rt: alicorn.Runtime
	public_ok := gpu_canvas_validation_runtime_make(&public_rt, f32(logical_width), f32(logical_height), &public_app, &public_allocations)
	if !public_ok { gpu_canvas_validation_fail("retained-surface Runtime fixture could not initialize") }
	defer if public_rt.persistent_allocator_state != nil { alicorn.destroy_runtime(&public_rt) }
	custom_rt: alicorn.Runtime
	custom_ok := gpu_canvas_validation_runtime_make(&custom_rt, f32(logical_width), f32(logical_height), &custom_app, &custom_allocations)
	if !custom_ok { gpu_canvas_validation_fail("custom-pass Runtime fixture could not initialize") }
	defer if custom_rt.persistent_allocator_state != nil { alicorn.destroy_runtime(&custom_rt) }
	public_renderer, public_renderer_ok := native_surface_make(device, format, &public_rt)
	if !public_renderer_ok { gpu_canvas_validation_fail("retained-surface renderer initialization failed") }
	defer if public_renderer.device != nil { native_surface_destroy(&public_renderer) }
	custom_renderer, custom_renderer_ok := native_surface_make(device, format, &custom_rt)
	if !custom_renderer_ok { gpu_canvas_validation_fail("custom-pass renderer initialization failed") }
	defer if custom_renderer.device != nil { native_surface_destroy(&custom_renderer) }
	public_target := gpu_canvas_validation_make_target(device, format, u32(width), u32(height))
	if public_target == nil { gpu_canvas_validation_fail("retained-surface render target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, public_target)
	custom_target := gpu_canvas_validation_make_target(device, format, u32(width), u32(height))
	if custom_target == nil { gpu_canvas_validation_fail("custom-pass render target creation failed") }
	defer sdl3.ReleaseGPUTexture(device, custom_target)
	public_download := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{usage=.DOWNLOAD, size=width*height*4})
	custom_download := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{usage=.DOWNLOAD, size=width*height*4})
	if public_download == nil || custom_download == nil { gpu_canvas_validation_fail("pixel readback buffer creation failed") }
	defer sdl3.ReleaseGPUTransferBuffer(device, public_download)
	defer sdl3.ReleaseGPUTransferBuffer(device, custom_download)
	pixel_count := int(width*height*4)
	public_pixels := make([]u8, pixel_count)
	custom_pixels := make([]u8, pixel_count)
	defer delete(public_pixels)
	defer delete(custom_pixels)
	if !gpu_canvas_validation_create_static_peaks(&custom_app, &custom_renderer) { gpu_canvas_validation_fail("custom-pass static GPU peak uploads failed") }
	// Both paths use the exact same paint geometry and offscreen RGBA target.
	// Warm once so static marker-mask creation is not mixed into steady samples.
	_, _, _, _, _, public_ok = gpu_canvas_validation_render(&public_app, &public_renderer, public_target, width, height, scale, scale)
	_, _, _, _, _, custom_ok = gpu_canvas_validation_render(&custom_app, &custom_renderer, custom_target, width, height, scale, scale)
	if !public_ok || !custom_ok { gpu_canvas_validation_fail("warm GPU canvas render failed") }
	public_bytes: u64
	public_uploads, public_passes: u64
	custom_bytes: u64
	custom_uploads, custom_passes: u64
	_, public_bytes, public_uploads, public_passes, _, public_ok = gpu_canvas_validation_render(&public_app, &public_renderer,
		public_target, width, height, scale, scale, public_pixels, public_download)
	_, custom_bytes, custom_uploads, custom_passes, _, custom_ok = gpu_canvas_validation_render(&custom_app, &custom_renderer,
		custom_target, width, height, scale, scale, custom_pixels, custom_download)
	if !public_ok || !custom_ok { gpu_canvas_validation_fail("initial pixel comparison render failed") }
	different, max_delta := gpu_canvas_validation_compare_pixels(public_pixels, custom_pixels)
	if different != 0 { gpu_canvas_validation_fail(fmt.tprintf("public/custom pixels differ: %d bytes, maximum channel delta %d", different, max_delta)) }
	for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
		peak, peak_ok := alicorn.gpu_surface_context(&public_rt, public_app.graphs[i].peak_node)
		head, head_ok := alicorn.gpu_surface_context(&public_rt, public_app.graphs[i].head_node)
		if !peak_ok || !head_ok || peak.logical_bounds != head.logical_bounds || peak.clip != head.clip ||
			peak.pixel_width != int(peak.logical_bounds.w*scale+0.5) || peak.pixel_height != int(peak.logical_bounds.h*scale+0.5) {
			gpu_canvas_validation_fail("layout/DPI context did not preserve overlay bounds, clip, or physical dimensions")
		}
	}
	if !gpu_canvas_validation_semantics(&public_app) || !gpu_canvas_validation_semantics(&custom_app) {
		gpu_canvas_validation_fail("ordinary slider accessibility fallback did not retain range semantics")
	}
	if benchmark {
		// Exercise the existing retained backdrop/effect path around the same
		// waveform pixels. The callback remains host-owned and writes only to
		// the effect source target supplied for this frame.
		effect_region := alicorn.Rect{12, 12, f32(logical_width)-24, f32(logical_height)-24}
		effect_plan, effect_plan_ok := native_effect_plan(Native_Effect_Request{
			enabled=true, key=1, source_generation=1, region=effect_region, clip=effect_region,
			scale=scale, sigma=4, depth=1,
		})
		if !effect_plan_ok || effect_plan.source_bounds != (alicorn.Rect{0, 0, f32(logical_width), f32(logical_height)}) {
			gpu_canvas_validation_fail("render-target effect plan did not preserve the waveform source bounds")
		}
		public_effect := native_effect_make(device, effect_plan.bytes, format)
		custom_effect := native_effect_make(device, effect_plan.bytes, format)
		defer native_effect_reset(&public_effect)
		defer native_effect_reset(&custom_effect)
		if !gpu_canvas_validation_effect_side(&public_app, &public_renderer, &public_effect, effect_plan,
			public_target, width, height, public_download, public_pixels) ||
			!gpu_canvas_validation_effect_side(&custom_app, &custom_renderer, &custom_effect, effect_plan,
				custom_target, width, height, custom_download, custom_pixels) {
			gpu_canvas_validation_fail("retained backdrop effect could not composite both canvas implementations")
		}
		effect_different, effect_max_delta := gpu_canvas_validation_compare_pixels(public_pixels, custom_pixels)
		if effect_different != 0 {
			gpu_canvas_validation_fail(fmt.tprintf("render-target effect pixels differ: %d bytes, maximum channel delta %d", effect_different, effect_max_delta))
		}
		fmt.println("issue_164_effect", "retained_render_target_blur", true,
			"custom_pass_host_composited", true, "different_bytes", effect_different,
			"max_delta", effect_max_delta, "new_effect_api", "none")
	}
	fmt.println("issue_164_pixels", "scale", scale, "logical", logical_width, "x", logical_height,
		"physical", width, "x", height, "different_bytes", different, "max_delta", max_delta,
		"public_passes", public_passes, "callback_passes", custom_passes,
		"public_upload_bytes", public_bytes, "callback_upload_bytes", custom_bytes)
	if public_uploads == 0 || custom_uploads == 0 { gpu_canvas_validation_fail("warm geometry did not upload vertex data") }
	if !benchmark { return }
	// The GUI tree remains unchanged during these producer updates. Public
	// surfaces receive bounded payload revisions; callback data remains app-owned.
	public_peaks_before, _ := alicorn.gpu_surface_context(&public_rt, public_app.graphs[0].peak_node)
	public_head_before, _ := alicorn.gpu_surface_context(&public_rt, public_app.graphs[0].head_node)
	for update in 0..<GPU_CANVAS_VALIDATION_RAPID_UPDATES {
		positions := [GPU_CANVAS_VALIDATION_GRAPHS]f32{
			f32((update*17)%97)/96,
			f32((update*31+13)%97)/96,
		}
		if !gpu_canvas_validation_update_public(&public_app, positions) { gpu_canvas_validation_fail("rapid retained-surface update rejected") }
		gpu_canvas_validation_custom_update(&custom_app, positions)
	}
	public_peaks_after, _ := alicorn.gpu_surface_context(&public_rt, public_app.graphs[0].peak_node)
	public_head_after, _ := alicorn.gpu_surface_context(&public_rt, public_app.graphs[0].head_node)
	if public_peaks_before.payload_revision != public_peaks_after.payload_revision ||
		u64(public_head_after.payload_revision) != u64(public_head_before.payload_revision)+GPU_CANVAS_VALIDATION_RAPID_UPDATES {
		gpu_canvas_validation_fail("rapid updates changed static peaks or lost latest-wins playhead revisions")
	}
	_, _, _, _, _, public_ok = gpu_canvas_validation_render(&public_app, &public_renderer, public_target, width, height, scale, scale, public_pixels, public_download)
	_, _, _, _, _, custom_ok = gpu_canvas_validation_render(&custom_app, &custom_renderer, custom_target, width, height, scale, scale, custom_pixels, custom_download)
	if !public_ok || !custom_ok { gpu_canvas_validation_fail("rapid-update final frame could not render") }
	different, max_delta = gpu_canvas_validation_compare_pixels(public_pixels, custom_pixels)
	if different != 0 { gpu_canvas_validation_fail("latest rapid-update output differs between retained and custom paths") }
	_, public_build_requested := alicorn.begin_frame(&public_rt)
	_, custom_build_requested := alicorn.begin_frame(&custom_rt)
	if public_build_requested || custom_build_requested { gpu_canvas_validation_fail("surface data updates unexpectedly requested UI description") }
	fmt.println("issue_164_rapid_updates", "count", GPU_CANVAS_VALIDATION_RAPID_UPDATES,
		"static_peak_revision_stable", true, "final_pixels_equal", true,
		"public_description_requested", public_build_requested, "callback_description_requested", custom_build_requested)
	if alicorn.frame_needs_submission(&public_rt) || alicorn.frame_needs_submission(&custom_rt) {
		gpu_canvas_validation_fail("static composition remained scheduled after submission acknowledgement")
	}
	// Hidden-window idle: wait on the SDL event queue and verify neither path
	// manufactures a timer wake, Runtime description, or presentation request.
	idle_event: sdl3.Event
	idle_allocations_before := public_allocations.persistent_alloc_calls+custom_allocations.persistent_alloc_calls
	idle_callbacks_before := custom_app.custom_passes
	_ = sdl3.WaitEventTimeout(&idle_event, 250)
	idle_allocations := public_allocations.persistent_alloc_calls+custom_allocations.persistent_alloc_calls-idle_allocations_before
	idle_callbacks := custom_app.custom_passes-idle_callbacks_before
	if alicorn.frame_needs_submission(&public_rt) || alicorn.frame_needs_submission(&custom_rt) ||
		idle_allocations != 0 || idle_callbacks != 0 {
		gpu_canvas_validation_fail("hidden static idle performed runtime allocation or requested a frame")
	}
	fmt.println("issue_164_idle", "hidden_wait_ms", 250, "persistent_allocation_delta", idle_allocations,
		"runtime_frame_needed", false, "callback_invocation_delta", idle_callbacks, "status", "PASS")

	public_input_samples := [GPU_CANVAS_VALIDATION_SAMPLES]i64{}
	custom_input_samples := [GPU_CANVAS_VALIDATION_SAMPLES]i64{}
	for sample in 0..<GPU_CANVAS_VALIDATION_SAMPLES {
		fraction := f32(0.31) if sample%2 == 0 else f32(0.79)
		input_ns, input_ok := gpu_canvas_validation_input(&public_app, fraction)
		custom_input_ns, custom_input_ok := gpu_canvas_validation_input(&custom_app, fraction)
		if !input_ok || !custom_input_ok { gpu_canvas_validation_fail("pointer input or semantic fallback failed") }
		for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS {
			if math.abs(public_app.graphs[i].position-custom_app.graphs[i].position) > 0.00001 {
				gpu_canvas_validation_fail("standard slider input produced different values between canvas paths")
			}
		}
		public_input_samples[sample], custom_input_samples[sample] = input_ns, custom_input_ns
	}
	fmt.println("issue_164_input", "synthetic_event_to_app_value_samples", GPU_CANVAS_VALIDATION_SAMPLES,
		"public_p95_ns", gpu_canvas_validation_percentile(public_input_samples[:], 0.95),
		"public_p99_ns", gpu_canvas_validation_percentile(public_input_samples[:], 0.99),
		"callback_p95_ns", gpu_canvas_validation_percentile(custom_input_samples[:], 0.95),
		"callback_p99_ns", gpu_canvas_validation_percentile(custom_input_samples[:], 0.99),
		"accessible_slider_range", true, "input_owner", "ordinary_Alicorn_Slider")
	_, _, _, _, _, public_ok = gpu_canvas_validation_render(&public_app, &public_renderer, public_target, width, height, scale, scale, public_pixels, public_download)
	_, _, _, _, _, custom_ok = gpu_canvas_validation_render(&custom_app, &custom_renderer, custom_target, width, height, scale, scale, custom_pixels, custom_download)
	if !public_ok || !custom_ok { gpu_canvas_validation_fail("post-input composition render failed") }
	different, max_delta = gpu_canvas_validation_compare_pixels(public_pixels, custom_pixels)
	if different != 0 { gpu_canvas_validation_fail("post-input custom pass changed waveform pixels") }
	if benchmark {
		public_samples := GPU_Canvas_Validation_Samples{
			update_ns=make([]i64, GPU_CANVAS_VALIDATION_SAMPLES), encode_ns=make([]i64, GPU_CANVAS_VALIDATION_SAMPLES),
			submit_to_fence_ns=make([]i64, GPU_CANVAS_VALIDATION_SAMPLES), vertex_bytes=make([]u64, GPU_CANVAS_VALIDATION_SAMPLES),
			vertex_uploads=make([]u64, GPU_CANVAS_VALIDATION_SAMPLES), geometry_passes=make([]u64, GPU_CANVAS_VALIDATION_SAMPLES),
		}
		custom_samples := GPU_Canvas_Validation_Samples{
			update_ns=make([]i64, GPU_CANVAS_VALIDATION_SAMPLES), encode_ns=make([]i64, GPU_CANVAS_VALIDATION_SAMPLES),
			submit_to_fence_ns=make([]i64, GPU_CANVAS_VALIDATION_SAMPLES), vertex_bytes=make([]u64, GPU_CANVAS_VALIDATION_SAMPLES),
			vertex_uploads=make([]u64, GPU_CANVAS_VALIDATION_SAMPLES), geometry_passes=make([]u64, GPU_CANVAS_VALIDATION_SAMPLES),
		}
		defer {
			delete(public_samples.update_ns); delete(public_samples.encode_ns); delete(public_samples.submit_to_fence_ns)
			delete(public_samples.vertex_bytes); delete(public_samples.vertex_uploads); delete(public_samples.geometry_passes)
			delete(custom_samples.update_ns); delete(custom_samples.encode_ns); delete(custom_samples.submit_to_fence_ns)
			delete(custom_samples.vertex_bytes); delete(custom_samples.vertex_uploads); delete(custom_samples.geometry_passes)
		}
		for sample in 0..<GPU_CANVAS_VALIDATION_SAMPLES {
			positions := [GPU_CANVAS_VALIDATION_GRAPHS]f32{
				f32((sample*13+5)%97)/96,
				f32((sample*29+19)%97)/96,
			}
			update_started := time.now()
			if !gpu_canvas_validation_update_public(&public_app, positions) { gpu_canvas_validation_fail("benchmark retained update rejected") }
			public_samples.update_ns[sample] = time.duration_nanoseconds(time.since(update_started))
			if sample%2 == 0 {
				public_samples.encode_ns[sample], public_samples.vertex_bytes[sample], public_samples.vertex_uploads[sample], public_samples.geometry_passes[sample], public_samples.submit_to_fence_ns[sample], public_ok = gpu_canvas_validation_render(&public_app, &public_renderer, public_target, width, height, scale, scale)
				if !public_ok { gpu_canvas_validation_fail("retained benchmark frame failed") }
				update_started = time.now()
				gpu_canvas_validation_custom_update(&custom_app, positions)
				custom_samples.update_ns[sample] = time.duration_nanoseconds(time.since(update_started))
				custom_samples.encode_ns[sample], custom_samples.vertex_bytes[sample], custom_samples.vertex_uploads[sample], custom_samples.geometry_passes[sample], custom_samples.submit_to_fence_ns[sample], custom_ok = gpu_canvas_validation_render(&custom_app, &custom_renderer, custom_target, width, height, scale, scale)
			} else {
				update_started = time.now()
				gpu_canvas_validation_custom_update(&custom_app, positions)
				custom_samples.update_ns[sample] = time.duration_nanoseconds(time.since(update_started))
				custom_samples.encode_ns[sample], custom_samples.vertex_bytes[sample], custom_samples.vertex_uploads[sample], custom_samples.geometry_passes[sample], custom_samples.submit_to_fence_ns[sample], custom_ok = gpu_canvas_validation_render(&custom_app, &custom_renderer, custom_target, width, height, scale, scale)
				if !custom_ok { gpu_canvas_validation_fail("custom benchmark frame failed") }
				update_started = time.now()
				if !gpu_canvas_validation_update_public(&public_app, positions) { gpu_canvas_validation_fail("benchmark retained update rejected") }
				public_samples.update_ns[sample] = time.duration_nanoseconds(time.since(update_started))
				public_samples.encode_ns[sample], public_samples.vertex_bytes[sample], public_samples.vertex_uploads[sample], public_samples.geometry_passes[sample], public_samples.submit_to_fence_ns[sample], public_ok = gpu_canvas_validation_render(&public_app, &public_renderer, public_target, width, height, scale, scale)
			}
			if !public_ok || !custom_ok { gpu_canvas_validation_fail("paired benchmark sample failed") }
		}
		gpu_canvas_validation_report_samples("retained", public_samples)
		gpu_canvas_validation_report_samples("callback_cached_peaks", custom_samples)
		fmt.println("issue_164_resource_cost", "extra_peak_gpu_buffer_bytes", custom_app.graphs[0].peak_gpu_bytes+custom_app.graphs[1].peak_gpu_bytes,
			"callback_static_peak_uploads", custom_app.custom_static_uploads,
			"callback_static_upload_bytes", custom_app.custom_static_upload_bytes,
			"app_api", "no new public API")
	}
	// Keep three frames queued, then prove teardown follows fence retirement.
	fences: [3]^sdl3.GPUFence
	for frame in 0..<len(fences) {
		positions := [GPU_CANVAS_VALIDATION_GRAPHS]f32{f32(frame+1)/5, f32(frame+2)/6}
		gpu_canvas_validation_custom_update(&custom_app, positions)
		command := sdl3.AcquireGPUCommandBuffer(device)
		if command == nil { gpu_canvas_validation_fail("in-flight shutdown command acquisition failed") }
		clear_info := make_color_target(custom_target, sdl3.FColor{0.04, 0.05, 0.07, 1}, false)
		clear_pass := sdl3.BeginGPURenderPass(command, &clear_info, 1, nil)
		if clear_pass == nil { gpu_canvas_validation_fail("in-flight shutdown target clear failed") }
		sdl3.EndGPURenderPass(clear_pass)
		for paint in custom_rt.display {
			if !alicorn.paint_command_is_geometry(paint) || paint.owner != custom_app.graphs[0].peak_node { continue }
			if !gpu_canvas_validation_custom_pass(&custom_app, &custom_renderer, command, paint, custom_target, width, height, scale, scale) {
				gpu_canvas_validation_fail("in-flight shutdown callback encode failed")
			}
		}
		fences[frame] = sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
		if fences[frame] == nil { gpu_canvas_validation_fail("in-flight shutdown submission failed") }
		native_surface_commit_submission(&custom_renderer)
	}
	for fence in fences {
		queue := [1]^sdl3.GPUFence{fence}
		if !sdl3.WaitForGPUFences(device, true, &queue[0], 1) { gpu_canvas_validation_fail("in-flight GPU work did not retire") }
		sdl3.ReleaseGPUFence(device, fence)
	}
	fmt.println("issue_164_lifetime", "queued_frames_before_wait", len(fences), "buffers_released_after_fences", true, "status", "PASS")
	if benchmark {
		gpu_canvas_validation_release_static_peaks(&custom_app, device)
		resize_width, resize_height := 720, 440
		resize_scale := f32(1.25)
		resize_positions := [GPU_CANVAS_VALIDATION_GRAPHS]f32{0.42, 0.68}
		for app in ([2]^GPU_Canvas_Validation_App{&public_app, &custom_app}) {
			app.dpi_scale = resize_scale
			for i in 0..<GPU_CANVAS_VALIDATION_GRAPHS { app.graphs[i].position = resize_positions[i] }
			if !alicorn.runtime_set_viewport(app.runtime, alicorn.Rect{0, 0, f32(resize_width), f32(resize_height)}) {
				gpu_canvas_validation_fail("same-runtime resize viewport was rejected")
			}
			_ = alicorn.set_presentation_scale(app.runtime, resize_scale, resize_scale)
			if !gpu_canvas_validation_build(app, "issue-164 retained runtime resize") || !gpu_canvas_validation_prepare_data(app) {
				gpu_canvas_validation_fail("same-runtime resize did not rebuild canvas placement")
			}
		}
		if !gpu_canvas_validation_create_static_peaks(&custom_app, &custom_renderer) {
			gpu_canvas_validation_fail("custom cached peaks did not recreate after DPI resize")
		}
		resize_w, resize_h := sdl3.Uint32(f32(resize_width)*resize_scale), sdl3.Uint32(f32(resize_height)*resize_scale)
		resize_public_target := gpu_canvas_validation_make_target(device, format, u32(resize_w), u32(resize_h))
		resize_custom_target := gpu_canvas_validation_make_target(device, format, u32(resize_w), u32(resize_h))
		if resize_public_target == nil || resize_custom_target == nil { gpu_canvas_validation_fail("resized output targets could not be created") }
		defer sdl3.ReleaseGPUTexture(device, resize_public_target)
		defer sdl3.ReleaseGPUTexture(device, resize_custom_target)
		resize_public_download := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{usage=.DOWNLOAD, size=resize_w*resize_h*4})
		resize_custom_download := sdl3.CreateGPUTransferBuffer(device, sdl3.GPUTransferBufferCreateInfo{usage=.DOWNLOAD, size=resize_w*resize_h*4})
		if resize_public_download == nil || resize_custom_download == nil { gpu_canvas_validation_fail("resized pixel readback buffers could not be created") }
		defer sdl3.ReleaseGPUTransferBuffer(device, resize_public_download)
		defer sdl3.ReleaseGPUTransferBuffer(device, resize_custom_download)
		resize_pixel_count := int(resize_w*resize_h*4)
		resize_public_pixels := make([]u8, resize_pixel_count)
		resize_custom_pixels := make([]u8, resize_pixel_count)
		defer delete(resize_public_pixels)
		defer delete(resize_custom_pixels)
		_, _, _, _, _, public_ok = gpu_canvas_validation_render(&public_app, &public_renderer,
			resize_public_target, resize_w, resize_h, resize_scale, resize_scale, resize_public_pixels, resize_public_download)
		_, _, _, _, _, custom_ok = gpu_canvas_validation_render(&custom_app, &custom_renderer,
			resize_custom_target, resize_w, resize_h, resize_scale, resize_scale, resize_custom_pixels, resize_custom_download)
		if !public_ok || !custom_ok { gpu_canvas_validation_fail("resized same-runtime canvas could not render") }
		resize_different, resize_max_delta := gpu_canvas_validation_compare_pixels(resize_public_pixels, resize_custom_pixels)
		resize_public_semantics := gpu_canvas_validation_semantics(&public_app)
		resize_custom_semantics := gpu_canvas_validation_semantics(&custom_app)
		if resize_different != 0 || !resize_public_semantics || !resize_custom_semantics {
			gpu_canvas_validation_fail("resized canvas lost pixel parity or semantic slider bounds")
		}
		fmt.println("issue_164_resize", "same_runtime_resize", true, "logical", resize_width, "x", resize_height,
			"dpi_scale", resize_scale, "physical", resize_w, "x", resize_h,
			"different_bytes", resize_different, "max_delta", resize_max_delta, "slider_semantics", true)
	}
}

gpu_canvas_validation_report_samples :: proc(name: string, samples: GPU_Canvas_Validation_Samples) {
	fmt.println("issue_164_benchmark", "strategy", name, "samples", len(samples.encode_ns),
		"update_p95_ns", gpu_canvas_validation_percentile(samples.update_ns, 0.95),
		"update_p99_ns", gpu_canvas_validation_percentile(samples.update_ns, 0.99),
		"encode_p95_ns", gpu_canvas_validation_percentile(samples.encode_ns, 0.95),
		"encode_p99_ns", gpu_canvas_validation_percentile(samples.encode_ns, 0.99),
		"submit_to_fence_p95_ns", gpu_canvas_validation_percentile(samples.submit_to_fence_ns, 0.95),
		"submit_to_fence_p99_ns", gpu_canvas_validation_percentile(samples.submit_to_fence_ns, 0.99),
		"upload_bytes_per_frame", samples.vertex_bytes[0], "uploads_per_frame", samples.vertex_uploads[0],
		"geometry_passes_per_frame", samples.geometry_passes[0])
}

RunGPUCanvasValidation :: proc() {
	if !sdl3.Init(sdl3.INIT_VIDEO) { gpu_canvas_validation_fail("SDL video initialization failed") }
	defer sdl3.Quit()
	logical_w := sdl3.Sint32(GPU_CANVAS_VALIDATION_LOGICAL_WIDTH)
	logical_h := sdl3.Sint32(GPU_CANVAS_VALIDATION_LOGICAL_HEIGHT)
	window := sdl3.CreateWindow("Alicorn GPU canvas validation", logical_w, logical_h, {.HIDDEN, .HIGH_PIXEL_DENSITY})
	if window == nil { gpu_canvas_validation_fail("hidden GPU canvas window creation failed") }
	defer sdl3.DestroyWindow(window)
	device := sdl3.CreateGPUDevice(sdl3.GPUShaderFormat{.SPIRV, .DXIL, .MSL}, false, nil)
	if device == nil || !sdl3.ClaimWindowForGPUDevice(device, window) { gpu_canvas_validation_fail("SDL_GPU device creation/window claim failed") }
	defer {
		_ = sdl3.WaitForGPUIdle(device)
		sdl3.ReleaseWindowFromGPUDevice(device, window)
		sdl3.DestroyGPUDevice(device)
	}
	format := sdl3.GetGPUSwapchainTextureFormat(device, window)
	if !sdl3.GPUTextureSupportsFormat(device, format, .D2, {.COLOR_TARGET}) { gpu_canvas_validation_fail("swapchain format cannot be used for offscreen canvas validation") }
	fmt.println("issue_164_backend", "driver", sdl3.GetGPUDeviceDriver(device), "format", format,
		"gpu_timestamps", "not exposed by current SDL3 Odin binding")
	cases := [4]GPU_Canvas_Validation_Case{
		{1.0, 640, 400}, {1.25, 720, 440}, {1.5, 800, 480}, {2.0, 640, 400},
	}
	for test_case in cases {
		gpu_canvas_validation_run_scale_case(device, format, test_case.scale, test_case.width, test_case.height,
			benchmark=(test_case.scale == 1.0))
	}
	fmt.println("issue_164_validation", "status", "PASS", "new_public_api", "none")
}
