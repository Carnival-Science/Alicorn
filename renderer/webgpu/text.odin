package webgpu_renderer

import "core:math/bits"
import "core:mem"
import alicorn "../../runtime"
import cpu_renderer "../cpu"
import runa "../../third_party/Runa"
import "vendor:wgpu"

TEXT_INITIAL_VERTEX_CAPACITY :: 8192
TEXT_INITIAL_TRANSLATION_CAPACITY :: 32

TEXT_WGSL :: #load("shaders/text.wgsl", string)

Text_Result :: enum {
	Ok,
	Invalid_Input,
	Resource_Failure,
}

Text_Vertex :: struct {
	position: [3]f32,
	color: [4]f32,
	uv: [2]f32,
	command_index: u32,
	color_glyph: u32,
}

Text_Draw :: struct {
	first_vertex: u32,
	vertex_count: u32,
	command_index: int,
	page_index: u16,
	is_color: bool,
}

Text_Atlas_Page :: struct {
	page_index: u16,
	is_color: bool,
	width, height: u16,
	texture: wgpu.Texture,
	view: wgpu.TextureView,
	bind_group: wgpu.BindGroup,
	initialized: bool,
}

// Text_Renderer is a renderer-owned WebGPU resource set for exactly one live
// Runtime. Hosts may share a device across windows, but create one text
// renderer per Runtime and destroy it before its Runtime. It consumes borrowed
// finalized paint data synchronously during Prepare. The
// caller owns the render pass and invokes Draw_Command at the matching point
// in paint order. Commit_Submission acknowledges atlas writes only after the
// host has submitted its encoder. Device, queue, target and surface lifecycle
// remain owned by the host, so the same renderer module serves SDL and WASM.
Text_Renderer :: struct {
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
	shader: wgpu.ShaderModule,
	view_layout: wgpu.BindGroupLayout,
	atlas_layout: wgpu.BindGroupLayout,
	pipeline_layout: wgpu.PipelineLayout,
	pipeline: wgpu.RenderPipeline,
	sampler: wgpu.Sampler,
	view_buffer: wgpu.Buffer,
	translation_buffer: wgpu.Buffer,
	view_bind_group: wgpu.BindGroup,
	translation_capacity: int,
	vertex_buffer: wgpu.Buffer,
	vertex_capacity: int,
	vertices: [dynamic]Text_Vertex,
	draws: [dynamic]Text_Draw,
	translations: [dynamic][2]f32,
	atlas_pages: [dynamic]Text_Atlas_Page,
	pending_dirty: [dynamic]runa.Atlas_Dirty_View,
	mesh_valid: bool,
	mesh_runtime: ^alicorn.Runtime,
	mesh_fingerprint: u64,
	mesh_width, mesh_height: u32,
	mesh_scale_x, mesh_scale_y: f32,
	translation_fingerprint: u64,
	translation_valid: bool,
	viewport_width, viewport_height: u32,
	viewport_valid: bool,
	mesh_rebuild_count, vertex_upload_count, atlas_upload_count: u64,
	vertex_upload_bytes, atlas_upload_bytes: u64,
	translation_upload_count, viewport_upload_count: u64,
	atlas_page_create_count: u64,
	prepare_buffer_create_count: u64,
}

Text_Create :: proc(device: wgpu.Device, queue: wgpu.Queue, format: wgpu.TextureFormat) -> (renderer: Text_Renderer, ok: bool) {
	if device == nil || queue == nil { return }
	renderer.device, renderer.queue, renderer.format = device, queue, format
	renderer.translation_capacity = TEXT_INITIAL_TRANSLATION_CAPACITY
	renderer.vertex_capacity = TEXT_INITIAL_VERTEX_CAPACITY
	renderer.vertices = make([dynamic]Text_Vertex, 0, TEXT_INITIAL_VERTEX_CAPACITY)
	renderer.draws = make([dynamic]Text_Draw, 0, 512)
	renderer.translations = make([dynamic][2]f32, 0, TEXT_INITIAL_TRANSLATION_CAPACITY)
	renderer.atlas_pages = make([dynamic]Text_Atlas_Page, 0, 4)
	renderer.pending_dirty = make([dynamic]runa.Atlas_Dirty_View, 0, 4)
	defer if !ok { Text_Destroy(&renderer) }

	renderer.view_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU text viewport",
		usage={.Uniform, .CopyDst},
		size=VIEW_UNIFORM_BUFFER_BYTES,
	})
	if renderer.view_buffer == nil { return }
	renderer.translation_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU text translations",
		usage={.Storage, .CopyDst},
		size=u64(renderer.translation_capacity*size_of([2]f32)),
	})
	if renderer.translation_buffer == nil { return }
	view_entries := [2]wgpu.BindGroupLayoutEntry{
		{binding=0, visibility={.Vertex}, buffer={type=.Uniform, hasDynamicOffset=true, minBindingSize=VIEW_UNIFORM_BYTES}},
		{binding=1, visibility={.Vertex}, buffer={type=.ReadOnlyStorage, minBindingSize=u64(size_of([2]f32))}},
	}
	renderer.view_layout = wgpu.DeviceCreateBindGroupLayout(device, &wgpu.BindGroupLayoutDescriptor{
		label="Alicorn WebGPU text frame layout",
		entryCount=uint(len(view_entries)),
		entries=&view_entries[0],
	})
	if renderer.view_layout == nil { return }
	atlas_entries := [2]wgpu.BindGroupLayoutEntry{
		{binding=0, visibility={.Fragment}, texture={sampleType=.Float, viewDimension=._2D}},
		{binding=1, visibility={.Fragment}, sampler={type=.Filtering}},
	}
	renderer.atlas_layout = wgpu.DeviceCreateBindGroupLayout(device, &wgpu.BindGroupLayoutDescriptor{
		label="Alicorn WebGPU text atlas layout",
		entryCount=uint(len(atlas_entries)),
		entries=&atlas_entries[0],
	})
	if renderer.atlas_layout == nil { return }
	if !text_view_bind_group_rebuild(&renderer) { return }

	renderer.sampler = wgpu.DeviceCreateSampler(device, &wgpu.SamplerDescriptor{
		addressModeU=.ClampToEdge,
		addressModeV=.ClampToEdge,
		addressModeW=.ClampToEdge,
		magFilter=.Linear,
		minFilter=.Linear,
		mipmapFilter=.Nearest,
		lodMinClamp=0,
		lodMaxClamp=1,
		maxAnisotropy=1,
	})
	if renderer.sampler == nil { return }
	bind_layouts := [2]wgpu.BindGroupLayout{renderer.view_layout, renderer.atlas_layout}
	renderer.pipeline_layout = wgpu.DeviceCreatePipelineLayout(device, &wgpu.PipelineLayoutDescriptor{
		label="Alicorn WebGPU text pipeline layout",
		bindGroupLayoutCount=uint(len(bind_layouts)),
		bindGroupLayouts=&bind_layouts[0],
	})
	if renderer.pipeline_layout == nil { return }
	renderer.shader = wgpu.DeviceCreateShaderModule(device, &wgpu.ShaderModuleDescriptor{
		label="Alicorn WebGPU text WGSL",
		nextInChain=&wgpu.ShaderSourceWGSL{sType=.ShaderSourceWGSL, code=TEXT_WGSL},
	})
	if renderer.shader == nil { return }
	attrs := [5]wgpu.VertexAttribute{
		{format=.Float32x3, offset=u64(offset_of(Text_Vertex, position)), shaderLocation=0},
		{format=.Float32x4, offset=u64(offset_of(Text_Vertex, color)), shaderLocation=1},
		{format=.Float32x2, offset=u64(offset_of(Text_Vertex, uv)), shaderLocation=2},
		{format=.Uint32, offset=u64(offset_of(Text_Vertex, command_index)), shaderLocation=3},
		{format=.Uint32, offset=u64(offset_of(Text_Vertex, color_glyph)), shaderLocation=4},
	}
	vertex_layout := wgpu.VertexBufferLayout{
		stepMode=.Vertex,
		arrayStride=u64(size_of(Text_Vertex)),
		attributeCount=uint(len(attrs)),
		attributes=&attrs[0],
	}
	blend := wgpu.BlendState{
		color={operation=.Add, srcFactor=.SrcAlpha, dstFactor=.OneMinusSrcAlpha},
		alpha={operation=.Add, srcFactor=.One, dstFactor=.OneMinusSrcAlpha},
	}
	target := wgpu.ColorTargetState{format=format, blend=&blend, writeMask=wgpu.ColorWriteMaskFlags_All}
	fragment := wgpu.FragmentState{module=renderer.shader, entryPoint="fs_main", targetCount=1, targets=&target}
	renderer.pipeline = wgpu.DeviceCreateRenderPipeline(device, &wgpu.RenderPipelineDescriptor{
		label="Alicorn WebGPU text pipeline",
		layout=renderer.pipeline_layout,
		vertex={
			module=renderer.shader,
			entryPoint="vs_main",
			bufferCount=1,
			buffers=&vertex_layout,
		},
		primitive={topology=.TriangleList, frontFace=.CCW, cullMode=.None},
		multisample={count=1, mask=0xFFFFFFFF},
		fragment=&fragment,
	})
	if renderer.pipeline == nil { return }
	renderer.vertex_buffer = wgpu.DeviceCreateBuffer(device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU text vertices",
		usage={.Vertex, .CopyDst},
		size=u64(renderer.vertex_capacity*size_of(Text_Vertex)),
	})
	if renderer.vertex_buffer == nil { return }
	ok = true
	return
}

// Text_Prepare builds retained glyph geometry only when paint/font/scale/size
// inputs change, rasterizes missing glyphs into Runtime's CPU atlas, uploads
// only dirty atlas rectangles, and updates physical translations separately.
// Non-text commands are ignored here; the host interleaves Draw_Command calls
// with other renderer primitives in the original paint-command order.
Text_Prepare :: proc(
	renderer: ^Text_Renderer,
	rt: ^alicorn.Runtime,
	display: alicorn.Paint_Display_List_View,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
	scratch_allocator := context.temp_allocator,
) -> Text_Result {
	if renderer == nil || rt == nil || renderer.device == nil || renderer.queue == nil ||
	   target_width == 0 || target_height == 0 ||
	   u64(target_width) > u64(bits.INT_MAX) || u64(target_height) > u64(bits.INT_MAX) ||
	   !alicorn.number_is_finite(scale_x) || !alicorn.number_is_finite(scale_y) || scale_x <= 0 || scale_y <= 0 {
		return .Invalid_Input
	}
	if renderer.mesh_runtime != nil && renderer.mesh_runtime != rt { return .Invalid_Input }
	clear(&renderer.pending_dirty)
	fingerprint := text_mesh_fingerprint(renderer, rt, display.commands, target_width, target_height, scale_x, scale_y)
	mesh_changed := !renderer.mesh_valid || renderer.mesh_runtime != rt || renderer.mesh_fingerprint != fingerprint
	if mesh_changed {
		renderer.mesh_valid = false
		clear(&renderer.vertices)
		clear(&renderer.draws)
		text_command_count := 0
		for command in display.commands { if alicorn.paint_command_is_text(command) { text_command_count += 1 } }
		if text_command_count > 0 {
			text_vertex_reserve_shaped(renderer, rt, display.commands, scale_x, scale_y, scratch_allocator)
		}
		for command, command_index in display.commands {
			paint, is_text := command.payload.(alicorn.Text_Paint)
			if !is_text || !cpu_renderer.Text_Command_Intersects_Clip(command) { continue }
			run, found := alicorn.paint_text_run_resolve(rt, paint.run)
			if !found || run == nil { continue }
			span_strategy, single_span_index, starts_sorted := cpu_renderer.Span_Strategy(len(run.value), paint.spans)
			clusters_ordered := cpu_renderer.Glyph_Clusters_Are_Ordered(run.glyphs[:])
			winners: []int
			if span_strategy == .Segment_Tree || (span_strategy == .Sorted_Non_Overlapping && !clusters_ordered && !starts_sorted) {
				winners = cpu_renderer.Span_Winners(run.value, paint.spans, scratch_allocator)
			}
			span_cursor := 0
			for glyph in run.glyphs {
				if glyph.control_advance || !cpu_renderer.Glyph_May_Intersect_Clip(glyph, run.size, command, scale_x, scale_y) { continue }
				physical_x := (command.bounds.x + glyph.x) * scale_x
				_, subpixel_bucket := cpu_renderer.Snap_Text_X(physical_x)
				slot, drawable, glyph_ok := alicorn.text_engine_glyph(
					&rt.text_engine, glyph.glyph_id, run.size*scale_y, subpixel_bucket,
					scratch_allocator=scratch_allocator, font_role=run.font, font_source=glyph.font_source,
					font_weight=glyph.font_weight, italic=glyph.italic, face_id=glyph.font_face,
				)
				if !glyph_ok || !drawable { continue }
				slot_view := runa.atlas_slot_view(slot)
				glyph_color := Text_Resolved_Glyph_Color(
					len(run.value), paint.spans, span_strategy, single_span_index, starts_sorted,
					clusters_ordered, &span_cursor, winners, glyph, paint.color,
				)
				mesh := cpu_renderer.Build_Text_Glyph_Mesh(
					glyph, command, slot_view.Bearing, slot_view.Px_Size, slot_view.UV_Rect,
					glyph_color, slot_view.Is_Color, scale_x, scale_y,
				)
				if !mesh.visible { continue }
				if len(renderer.vertices) > bits.INT_MAX-6 { if len(winners)>0 { delete(winners,scratch_allocator) }; return .Resource_Failure }
				first := len(renderer.vertices)
				for vertex in mesh.vertices {
					append(&renderer.vertices, Text_Vertex{
						position=vertex.position,
						color=vertex.color,
						uv=vertex.uv,
						command_index=u32(command_index),
						color_glyph=1 if slot_view.Is_Color else 0,
					})
				}
				text_draw_append(renderer, command_index, slot_view.Page_Index, slot_view.Is_Color, first)
			}
			if len(winners) > 0 { delete(winners, scratch_allocator) }
		}
		if !text_vertex_buffer_ensure(renderer, len(renderer.vertices)) { return .Resource_Failure }
		if len(renderer.vertices) > 0 {
			upload_bytes := len(renderer.vertices)*size_of(Text_Vertex)
			wgpu.QueueWriteBuffer(renderer.queue, renderer.vertex_buffer, 0, raw_data(renderer.vertices[:]), uint(upload_bytes))
			renderer.vertex_upload_count += 1
			renderer.vertex_upload_bytes += u64(upload_bytes)
		}
		renderer.mesh_runtime = rt
		renderer.mesh_fingerprint = fingerprint
		renderer.mesh_width, renderer.mesh_height = target_width, target_height
		renderer.mesh_scale_x, renderer.mesh_scale_y = scale_x, scale_y
		renderer.mesh_valid = true
		renderer.mesh_rebuild_count += 1
	}
	if !text_translation_buffer_ensure(renderer, len(display.commands)) { return .Resource_Failure }
	translation_hash := u64(1469598103934665603)
	clear(&renderer.translations)
	for command, command_index in display.commands {
		translation := [2]f32{command.translation[0]*scale_x, command.translation[1]*scale_y}
		append(&renderer.translations, translation)
		translation_hash = alicorn.hash_mix(translation_hash, u64(command_index))
		translation_hash = alicorn.hash_mix(translation_hash, u64(transmute(u32)translation[0]))
		translation_hash = alicorn.hash_mix(translation_hash, u64(transmute(u32)translation[1]))
	}
	if !renderer.translation_valid || renderer.translation_fingerprint != translation_hash {
		if len(renderer.translations) > 0 {
			wgpu.QueueWriteBuffer(renderer.queue, renderer.translation_buffer, 0, raw_data(renderer.translations[:]), uint(len(renderer.translations)*size_of([2]f32)))
			renderer.translation_upload_count += 1
		}
		renderer.translation_fingerprint = translation_hash
		renderer.translation_valid = true
	}
	if !renderer.viewport_valid || renderer.viewport_width != target_width || renderer.viewport_height != target_height {
		if !webgpu_view_uniform_write(renderer.queue, renderer.view_buffer, target_width, target_height) {
			return .Resource_Failure
		}
		renderer.viewport_width, renderer.viewport_height = target_width, target_height
		renderer.viewport_valid = true
		renderer.viewport_upload_count += 1
	}
	if !text_atlas_sync_draw_pages(renderer, &rt.text_engine.atlas, scratch_allocator) { return .Resource_Failure }
	return .Ok
}

// Text_Draw_Command draws only the text glyphs belonging to one original
// paint command. This lets a host compositor preserve surface/text/image order
// inside its own render pass rather than sorting by renderer type.
Text_Draw_Command :: proc(
	renderer: ^Text_Renderer,
	pass: wgpu.RenderPassEncoder,
	command_index: int,
	command: alicorn.Paint_Command,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
	view_slot: u32 = 0,
	capture_origin_px: [2]int = {},
	prepared_width: u32 = 0,
	prepared_height: u32 = 0,
) -> Text_Result {
	if renderer == nil || pass == nil || renderer.pipeline == nil || renderer.vertex_buffer == nil ||
	   command_index < 0 || target_width == 0 || target_height == 0 || scale_x <= 0 || scale_y <= 0 {
		return .Invalid_Input
	}
	if !alicorn.paint_command_is_text(command) { return .Ok }
	mesh_width, mesh_height := prepared_width, prepared_height
	if mesh_width == 0 { mesh_width = target_width }
	if mesh_height == 0 { mesh_height = target_height }
	if !renderer.mesh_valid || renderer.mesh_width != mesh_width || renderer.mesh_height != mesh_height ||
	   renderer.mesh_scale_x != scale_x || renderer.mesh_scale_y != scale_y {
		return .Invalid_Input
	}
	if len(renderer.vertices) == 0 { return .Ok }
	x0, y0, x1, y1 := cpu_renderer.Logical_To_Pixel_Bounds(command.clip, scale_x, scale_y)
	if x0 < 0 { x0 = 0 }; if y0 < 0 { y0 = 0 }
	if x1 > int(mesh_width) { x1 = int(mesh_width) }; if y1 > int(mesh_height) { y1 = int(mesh_height) }
	if view_slot != 0 {
		localized := cpu_renderer.Pixel_Rect_Translate_Clip(
			cpu_renderer.Pixel_Rect{x0, y0, x1-x0, y1-y0},
			capture_origin_px[0], capture_origin_px[1], int(target_width), int(target_height),
		)
		x0, y0, x1, y1 = localized.x, localized.y, localized.x+localized.w, localized.y+localized.h
	} else {
		if x1 > int(target_width) { x1 = int(target_width) }; if y1 > int(target_height) { y1 = int(target_height) }
	}
	if x1 <= x0 || y1 <= y0 { return .Ok }
	wgpu.RenderPassEncoderSetPipeline(pass, renderer.pipeline)
	if !webgpu_view_bind_group_set(pass, 0, renderer.view_bind_group, view_slot) { return .Invalid_Input }
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.vertex_buffer, 0, u64(len(renderer.vertices)*size_of(Text_Vertex)))
	wgpu.RenderPassEncoderSetScissorRect(pass, u32(x0), u32(y0), u32(x1-x0), u32(y1-y0))
	for draw in renderer.draws {
		if draw.command_index != command_index { continue }
		page := text_atlas_page(renderer, draw.page_index, draw.is_color)
		if page == nil || page.bind_group == nil { return .Resource_Failure }
		wgpu.RenderPassEncoderSetBindGroup(pass, 1, page.bind_group)
		wgpu.RenderPassEncoderDraw(pass, draw.vertex_count, 1, draw.first_vertex, 0)
	}
	return .Ok
}

// Text_Commit_Submission acknowledges only the exact dirty atlas generations
// whose QueueWriteTexture operations were emitted by the prepared frame. Call
// after queue submission; on abandoned frames, leave the atlas dirty to retry.
Text_Commit_Submission :: proc(renderer: ^Text_Renderer, rt: ^alicorn.Runtime) {
	if renderer == nil || rt == nil || renderer.mesh_runtime != rt { return }
	if len(renderer.pending_dirty) > 0 {
		runa.atlas_dirty_ack(&rt.text_engine.atlas, renderer.pending_dirty[:])
		clear(&renderer.pending_dirty)
	}
}

Text_Destroy :: proc(renderer: ^Text_Renderer) {
	if renderer == nil { return }
	for &page in renderer.atlas_pages {
		if page.bind_group != nil { wgpu.BindGroupRelease(page.bind_group) }
		if page.view != nil { wgpu.TextureViewRelease(page.view) }
		if page.texture != nil { wgpu.TextureRelease(page.texture) }
	}
	if renderer.vertex_buffer != nil { wgpu.BufferRelease(renderer.vertex_buffer) }
	if renderer.pipeline != nil { wgpu.RenderPipelineRelease(renderer.pipeline) }
	if renderer.shader != nil { wgpu.ShaderModuleRelease(renderer.shader) }
	if renderer.pipeline_layout != nil { wgpu.PipelineLayoutRelease(renderer.pipeline_layout) }
	if renderer.atlas_layout != nil { wgpu.BindGroupLayoutRelease(renderer.atlas_layout) }
	if renderer.view_bind_group != nil { wgpu.BindGroupRelease(renderer.view_bind_group) }
	if renderer.view_layout != nil { wgpu.BindGroupLayoutRelease(renderer.view_layout) }
	if renderer.view_buffer != nil { wgpu.BufferRelease(renderer.view_buffer) }
	if renderer.translation_buffer != nil { wgpu.BufferRelease(renderer.translation_buffer) }
	if renderer.sampler != nil { wgpu.SamplerRelease(renderer.sampler) }
	delete(renderer.vertices)
	delete(renderer.draws)
	delete(renderer.translations)
	delete(renderer.atlas_pages)
	delete(renderer.pending_dirty)
	renderer^ = {}
}

text_view_bind_group_rebuild :: proc(renderer: ^Text_Renderer) -> bool {
	if renderer == nil || renderer.view_layout == nil || renderer.view_buffer == nil || renderer.translation_buffer == nil { return false }
	entries := [2]wgpu.BindGroupEntry{
		{binding=0, buffer=renderer.view_buffer, size=VIEW_UNIFORM_BYTES},
		{binding=1, buffer=renderer.translation_buffer, size=u64(renderer.translation_capacity*size_of([2]f32))},
	}
	group := wgpu.DeviceCreateBindGroup(renderer.device, &wgpu.BindGroupDescriptor{
		label="Alicorn WebGPU text frame bindings",
		layout=renderer.view_layout,
		entryCount=uint(len(entries)),
		entries=&entries[0],
	})
	if group == nil { return false }
	if renderer.view_bind_group != nil { wgpu.BindGroupRelease(renderer.view_bind_group) }
	renderer.view_bind_group = group
	return true
}

text_translation_buffer_ensure :: proc(renderer: ^Text_Renderer, required: int) -> bool {
	if required <= renderer.translation_capacity { return true }
	if required < 0 || required > bits.INT_MAX/size_of([2]f32) { return false }
	capacity := max(renderer.translation_capacity, TEXT_INITIAL_TRANSLATION_CAPACITY)
	for capacity < required {
		if capacity > bits.INT_MAX/2 { capacity = required; break }
		capacity *= 2
	}
	buffer := wgpu.DeviceCreateBuffer(renderer.device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU text translations",
		usage={.Storage, .CopyDst},
		size=u64(capacity*size_of([2]f32)),
	})
	if buffer == nil { return false }
	old_buffer, old_capacity := renderer.translation_buffer, renderer.translation_capacity
	renderer.translation_buffer, renderer.translation_capacity = buffer, capacity
	renderer.prepare_buffer_create_count += 1
	if !text_view_bind_group_rebuild(renderer) {
		renderer.translation_buffer, renderer.translation_capacity = old_buffer, old_capacity
		wgpu.BufferRelease(buffer)
		return false
	}
	if old_buffer != nil { wgpu.BufferRelease(old_buffer) }
	renderer.translation_valid = false
	return true
}

text_vertex_buffer_ensure :: proc(renderer: ^Text_Renderer, required: int) -> bool {
	if required <= renderer.vertex_capacity && renderer.vertex_buffer != nil { return true }
	if required < 0 || required > bits.INT_MAX/size_of(Text_Vertex) { return false }
	capacity := max(renderer.vertex_capacity, TEXT_INITIAL_VERTEX_CAPACITY)
	for capacity < required {
		if capacity > bits.INT_MAX/2 { capacity = required; break }
		capacity *= 2
	}
	buffer := wgpu.DeviceCreateBuffer(renderer.device, &wgpu.BufferDescriptor{
		label="Alicorn WebGPU text vertices",
		usage={.Vertex, .CopyDst},
		size=u64(capacity*size_of(Text_Vertex)),
	})
	if buffer == nil { return false }
	old := renderer.vertex_buffer
	renderer.vertex_buffer, renderer.vertex_capacity = buffer, capacity
	renderer.prepare_buffer_create_count += 1
	if old != nil { wgpu.BufferRelease(old) }
	return true
}

text_mesh_fingerprint :: proc(
	renderer: ^Text_Renderer,
	rt: ^alicorn.Runtime,
	commands: []alicorn.Paint_Command,
	target_width, target_height: u32,
	scale_x, scale_y: f32,
) -> u64 {
	h := u64(1469598103934665603)
	h = alicorn.hash_mix(h, u64(target_width))
	h = alicorn.hash_mix(h, u64(target_height))
	h = alicorn.hash_mix(h, u64(transmute(u32)scale_x))
	h = alicorn.hash_mix(h, u64(transmute(u32)scale_y))
	h = alicorn.hash_mix(h, rt.text_engine.font_generation)
	text_index: u64 = 0
	for command, command_index in commands {
		paint, is_text := command.payload.(alicorn.Text_Paint)
		if !is_text { continue }
		h = alicorn.hash_mix(h, u64(command_index))
		h = alicorn.hash_mix(h, text_index)
		text_index += 1
		h = alicorn.hash_mix(h, u64(paint.run.source))
		h = alicorn.hash_mix(h, paint.run.resource)
		h = alicorn.hash_mix(h, paint.run.generation)
		h = cpu_renderer.Hash_Rect(h, command.bounds)
		h = cpu_renderer.Hash_Rect(h, command.clip)
		h = alicorn.hash_mix(h, u64(transmute(u32)command.opacity))
		h = cpu_renderer.Hash_Color(h, paint.color)
		h = cpu_renderer.Hash_Text_Spans(h, paint.spans)
		run, found := alicorn.paint_text_run_resolve(rt, paint.run)
		if !found || run == nil { continue }
		h = alicorn.hash_mix(h, alicorn.hash_string(run.value))
		h = alicorn.hash_mix(h, u64(run.font))
		h = alicorn.hash_mix(h, u64(run.font_source))
		h = alicorn.hash_mix(h, u64(transmute(u32)run.size))
		h = alicorn.hash_mix(h, u64(transmute(u32)run.font_weight))
		h = alicorn.hash_mix(h, run.style_hash)
	}
	return alicorn.hash_mix(h, text_index)
}

text_vertex_reserve_shaped :: proc(
	renderer: ^Text_Renderer,
	rt: ^alicorn.Runtime,
	commands: []alicorn.Paint_Command,
	scale_x, scale_y: f32,
	scratch_allocator: mem.Allocator,
) {
	visible_glyphs := 0
	for command in commands {
		paint, is_text := command.payload.(alicorn.Text_Paint)
		if !is_text || !cpu_renderer.Text_Command_Intersects_Clip(command) { continue }
		run, found := alicorn.paint_text_run_resolve(rt, paint.run)
		if !found || run == nil { continue }
		for glyph in run.glyphs {
			if glyph.control_advance || !cpu_renderer.Glyph_May_Intersect_Clip(glyph, run.size, command, scale_x, scale_y) { continue }
			visible_glyphs += 1
		}
	}
	if visible_glyphs <= bits.INT_MAX/6 { reserve(&renderer.vertices, visible_glyphs*6) }
}

text_draw_append :: proc(renderer: ^Text_Renderer, command_index: int, page_index: u16, is_color: bool, first_vertex: int) {
	if len(renderer.draws) > 0 {
		last := &renderer.draws[len(renderer.draws)-1]
		if last.command_index == command_index && last.page_index == page_index && last.is_color == is_color &&
		   u64(last.first_vertex)+u64(last.vertex_count) == u64(first_vertex) {
			last.vertex_count += 6
			return
		}
	}
	append(&renderer.draws, Text_Draw{u32(first_vertex), 6, command_index, page_index, is_color})
}

text_atlas_page :: proc(renderer: ^Text_Renderer, page_index: u16, is_color: bool) -> ^Text_Atlas_Page {
	for &page in renderer.atlas_pages {
		if page.page_index == page_index && page.is_color == is_color { return &page }
	}
	return nil
}

text_atlas_sync_draw_pages :: proc(renderer: ^Text_Renderer, atlas: ^runa.Atlas, scratch_allocator: mem.Allocator) -> bool {
	snapshot := runa.atlas_dirty_snapshot(atlas, scratch_allocator)
	defer delete(snapshot, scratch_allocator)
	for draw in renderer.draws {
		page := text_atlas_page(renderer, draw.page_index, draw.is_color)
		if page == nil {
			view, view_ok := runa.atlas_page_view(atlas, draw.page_index, draw.is_color)
			if !view_ok { return false }
			format: wgpu.TextureFormat = .R8Unorm
			if draw.is_color { format = .RGBA8Unorm }
			texture := wgpu.DeviceCreateTexture(renderer.device, &wgpu.TextureDescriptor{
				label="Alicorn WebGPU Runa glyph atlas",
				usage={.TextureBinding, .CopyDst},
				dimension=._2D,
				size={width=u32(view.Width), height=u32(view.Height), depthOrArrayLayers=1},
				format=format,
				mipLevelCount=1,
				sampleCount=1,
			})
			if texture == nil { return false }
			texture_view := wgpu.TextureCreateView(texture)
			if texture_view == nil { wgpu.TextureRelease(texture); return false }
			entries := [2]wgpu.BindGroupEntry{
				{binding=0, textureView=texture_view},
				{binding=1, sampler=renderer.sampler},
			}
			bind_group := wgpu.DeviceCreateBindGroup(renderer.device, &wgpu.BindGroupDescriptor{
				label="Alicorn WebGPU glyph atlas page",
				layout=renderer.atlas_layout,
				entryCount=uint(len(entries)),
				entries=&entries[0],
			})
			if bind_group == nil { wgpu.TextureViewRelease(texture_view); wgpu.TextureRelease(texture); return false }
			append(&renderer.atlas_pages, Text_Atlas_Page{
				page_index=draw.page_index,
				is_color=draw.is_color,
				width=view.Width,
				height=view.Height,
				texture=texture,
				view=texture_view,
				bind_group=bind_group,
			})
			renderer.atlas_page_create_count += 1
			page = &renderer.atlas_pages[len(renderer.atlas_pages)-1]
		}
		dirty: ^runa.Atlas_Dirty_View
		for &candidate in snapshot {
			if candidate.Page_Index == draw.page_index && candidate.Is_Color == draw.is_color { dirty = &candidate; break }
		}
		if !page.initialized || dirty != nil {
			view, view_ok := runa.atlas_page_view(atlas, draw.page_index, draw.is_color)
			if !view_ok || !text_atlas_upload_page(renderer, page, view, dirty, scratch_allocator) { return false }
			page.initialized = true
			if dirty != nil { append(&renderer.pending_dirty, dirty^) }
			if dirty == nil {
				// No dirty generation was outstanding. The whole-page initialization
				// still makes the texture valid for this renderer's first use.
			}
		}
	}
	return true
}

text_atlas_upload_page :: proc(
	renderer: ^Text_Renderer,
	page: ^Text_Atlas_Page,
	view: runa.Atlas_Page_View,
	dirty: ^runa.Atlas_Dirty_View,
	scratch_allocator: mem.Allocator,
) -> bool {
	x, y, width, height := 0, 0, int(view.Width), int(view.Height)
	if page.initialized && dirty != nil {
		x, y, width, height = int(dirty.X), int(dirty.Y), int(dirty.W), int(dirty.H)
	}
	if width <= 0 || height <= 0 { return true }
	bpp := 1
	if page.is_color { bpp = 4 }
	if width > bits.INT_MAX/height || width*height > bits.INT_MAX/bpp { return false }
	bytes := make([]u8, width*height*bpp, allocator=scratch_allocator)
	defer delete(bytes, scratch_allocator)
	row_bytes := width*bpp
	for row in 0..<height {
		src_start := ((y+row)*int(view.Width)+x)*bpp
		dst_start := row*row_bytes
		if src_start < 0 || src_start+row_bytes > len(view.Pixels) { return false }
		copy(bytes[dst_start:dst_start+row_bytes], view.Pixels[src_start:src_start+row_bytes])
	}
	destination := wgpu.TexelCopyTextureInfo{texture=page.texture, origin={x=u32(x), y=u32(y), z=0}, aspect=.All}
	layout := wgpu.TexelCopyBufferLayout{bytesPerRow=u32(row_bytes), rowsPerImage=u32(height)}
	extent := wgpu.Extent3D{width=u32(width), height=u32(height), depthOrArrayLayers=1}
	wgpu.QueueWriteTexture(renderer.queue, &destination, raw_data(bytes), uint(len(bytes)), &layout, &extent)
	renderer.atlas_upload_count += 1
	renderer.atlas_upload_bytes += u64(len(bytes))
	return true
}

Text_Resolved_Glyph_Color :: proc(
	text_length: int,
	spans: []alicorn.Text_Paint_Span,
	strategy: cpu_renderer.Text_Span_Strategy,
	single_index: int,
	starts_sorted, clusters_ordered: bool,
	cursor: ^int,
	winners: []int,
	glyph: alicorn.Text_Glyph,
	fallback: alicorn.Color,
) -> alicorn.Color {
	switch strategy {
	case .Single:
		return cpu_renderer.Color_For_Single_Span(text_length, spans, single_index, glyph.cluster_start, glyph.cluster_end, fallback)
	case .Sorted_Non_Overlapping:
		if clusters_ordered { return cpu_renderer.Color_For_Sorted_Cluster(text_length, spans, cursor, glyph.cluster_start, glyph.cluster_end, fallback) }
		if starts_sorted { return cpu_renderer.Color_For_Sorted_Cluster_Binary(text_length, spans, glyph.cluster_start, glyph.cluster_end, fallback) }
		return cpu_renderer.Color_For_Cluster(spans, winners, glyph.cluster_start, glyph.cluster_end, fallback)
	case .Segment_Tree:
		return cpu_renderer.Color_For_Cluster(spans, winners, glyph.cluster_start, glyph.cluster_end, fallback)
	case .None:
	}
	return fallback
}
