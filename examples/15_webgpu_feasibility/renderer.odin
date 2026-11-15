package webgpu_feasibility

import "core:fmt"
import "core:math"
import alicorn "../../runtime"
import "vendor:wgpu"
import runa "../../third_party/Runa"
import webgpu_renderer "../../renderer/webgpu"

FONT_DATA :: #load("../../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")
SCENE_TEXT :: "One renderer. Native SDL3 + browser WebGPU."

WGSL :: `
struct VertexInput {
	@location(0) position: vec2<f32>,
	@location(1) uv: vec2<f32>,
	@location(2) color: vec4<f32>,
	@location(3) kind: u32,
};
struct VertexOutput {
	@builtin(position) position: vec4<f32>,
	@location(0) uv: vec2<f32>,
	@location(1) color: vec4<f32>,
	@interpolate(flat) @location(2) kind: u32,
};
@group(0) @binding(0) var image_sampler: sampler;
@group(0) @binding(1) var image_texture: texture_2d<f32>;
@group(0) @binding(2) var glyph_texture: texture_2d<f32>;
struct ProbeUniform {
	color: vec4<f32>,
};
@group(0) @binding(3) var<uniform> probe: ProbeUniform;
@vertex fn vs_main(input: VertexInput) -> VertexOutput {
	var out: VertexOutput;
	out.position=vec4<f32>(input.position,0.0,1.0);
	out.uv=input.uv; out.color=input.color; out.kind=input.kind;
	return out;
}
@fragment fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
	if input.kind==1u { return textureSampleLevel(image_texture,image_sampler,input.uv,0.0)*input.color; }
	if input.kind==2u {
		let coverage=textureSampleLevel(glyph_texture,image_sampler,input.uv,0.0).r;
		return vec4<f32>(input.color.rgb,input.color.a*coverage);
	}
	if input.kind==3u { return probe.color; }
	return input.color;
}
`

create_resources :: proc() {
	state.vertex_capacity=VERTEX_CAPACITY
	state.vertex_buffer=wgpu.DeviceCreateBuffer(state.device,&wgpu.BufferDescriptor{
		label="retained vertex upload",usage={.Vertex,.CopyDst},size=state.vertex_capacity,
	})
	state.probe_uniform_buffer=wgpu.DeviceCreateBuffer(state.device,&wgpu.BufferDescriptor{
		label="WGSL uniform layout probe",usage={.Uniform,.CopyDst},size=u64(size_of([4]f32)),
	})
	attrs:=[4]wgpu.VertexAttribute{
		{format=.Float32x2,offset=0,shaderLocation=0},
		{format=.Float32x2,offset=8,shaderLocation=1},
		{format=.Float32x4,offset=16,shaderLocation=2},
		{format=.Uint32,offset=32,shaderLocation=3},
	}
	vertex_layout:=wgpu.VertexBufferLayout{stepMode=.Vertex,arrayStride=u64(size_of(Vertex)),attributeCount=uint(len(attrs)),attributes=&attrs[0]}
	bgl_entries:=[4]wgpu.BindGroupLayoutEntry{
		{binding=0,visibility={.Fragment},sampler={type=.Filtering}},
		{binding=1,visibility={.Fragment},texture={sampleType=.Float,viewDimension=._2D}},
		{binding=2,visibility={.Fragment},texture={sampleType=.Float,viewDimension=._2D}},
		{binding=3,visibility={.Fragment},buffer={type=.Uniform,minBindingSize=u64(size_of([4]f32))}},
	}
	state.bind_group_layout=wgpu.DeviceCreateBindGroupLayout(state.device,&wgpu.BindGroupLayoutDescriptor{
		label="image and Runa atlas",entryCount=uint(len(bgl_entries)),entries=&bgl_entries[0],
	})
	state.shader=wgpu.DeviceCreateShaderModule(state.device,&{nextInChain=&wgpu.ShaderSourceWGSL{sType=.ShaderSourceWGSL,code=WGSL}})
	state.pipeline_layout=wgpu.DeviceCreatePipelineLayout(state.device,&wgpu.PipelineLayoutDescriptor{
		bindGroupLayoutCount=1,bindGroupLayouts=&state.bind_group_layout,
	})
	state.pipeline=create_pipeline(state.config.format, &vertex_layout, "surface WGSL feasibility pipeline")
	state.offscreen_pipeline=create_pipeline(.RGBA8Unorm, &vertex_layout, "RGBA8 offscreen feasibility pipeline")
	create_image_texture()
	create_runa_atlas()
	create_bind_group()
}

create_pipeline :: proc(format: wgpu.TextureFormat, vertex_layout: ^wgpu.VertexBufferLayout, label: string) -> wgpu.RenderPipeline {
	blend:=wgpu.BlendState{
		color={operation=.Add,srcFactor=.SrcAlpha,dstFactor=.OneMinusSrcAlpha},
		alpha={operation=.Add,srcFactor=.One,dstFactor=.OneMinusSrcAlpha},
	}
	target:=wgpu.ColorTargetState{format=format,blend=&blend,writeMask=wgpu.ColorWriteMaskFlags_All}
	fragment:=wgpu.FragmentState{module=state.shader,entryPoint="fs_main",targetCount=1,targets=&target}
	return wgpu.DeviceCreateRenderPipeline(state.device,&wgpu.RenderPipelineDescriptor{
		label=label,layout=state.pipeline_layout,
		vertex={module=state.shader,entryPoint="vs_main",bufferCount=1,buffers=vertex_layout},
		primitive={topology=.TriangleList,frontFace=.CCW,cullMode=.None},
		multisample={count=1,mask=0xFFFFFFFF},fragment=&fragment,
	})
}

create_image_texture :: proc() {
	WIDTH :: 32
	HEIGHT :: 32
	pixels:=make([]u8,WIDTH*HEIGHT*4)
	defer delete(pixels)
	for y in 0..<HEIGHT {
		for x in 0..<WIDTH {
			i:=(y*WIDTH+x)*4
			if ((x/8)+(y/8))%2==0 {
				pixels[i],pixels[i+1],pixels[i+2],pixels[i+3]=232,166,86,255
			} else {
				pixels[i],pixels[i+1],pixels[i+2],pixels[i+3]=36,126,148,255
			}
		}
	}
	state.image_texture=wgpu.DeviceCreateTexture(state.device,&wgpu.TextureDescriptor{
		label="generated checker",usage={.TextureBinding,.CopyDst},dimension=._2D,
		size={width=WIDTH,height=HEIGHT,depthOrArrayLayers=1},format=.RGBA8Unorm,mipLevelCount=1,sampleCount=1,
	})
	layout:=wgpu.TexelCopyBufferLayout{bytesPerRow=WIDTH*4,rowsPerImage=HEIGHT}
	extent:=wgpu.Extent3D{width=WIDTH,height=HEIGHT,depthOrArrayLayers=1}
	destination:=wgpu.TexelCopyTextureInfo{texture=state.image_texture,aspect=.All}
	wgpu.QueueWriteTexture(state.queue,&destination,raw_data(pixels),uint(len(pixels)),&layout,&extent)
	PATCH_SIZE :: 8
	patch:=make([]u8,PATCH_SIZE*PATCH_SIZE*4)
	defer delete(patch)
	for y in 0..<PATCH_SIZE {
		for x in 0..<PATCH_SIZE {
			i:=(y*PATCH_SIZE+x)*4
			patch[i],patch[i+1],patch[i+2],patch[i+3]=72,206,166,255
		}
	}
	patch_layout:=wgpu.TexelCopyBufferLayout{bytesPerRow=PATCH_SIZE*4,rowsPerImage=PATCH_SIZE}
	patch_destination:=wgpu.TexelCopyTextureInfo{texture=state.image_texture,origin={x=8,y=8,z=0},aspect=.All}
	patch_extent:=wgpu.Extent3D{width=PATCH_SIZE,height=PATCH_SIZE,depthOrArrayLayers=1}
	wgpu.QueueWriteTexture(state.queue,&patch_destination,raw_data(patch),uint(len(patch)),&patch_layout,&patch_extent)
	state.image_view=wgpu.TextureCreateView(state.image_texture)
}

create_runa_atlas :: proc() {
	font,err:=runa.font_load(FONT_DATA)
state.font=font
	if err!=.None { fmt.panicf("Runa font load failed: %v",err) }
	state.atlas=runa.atlas_make(512,512)
	shaped:[dynamic]runa.Shaped_Glyph
	runa.shape_text(&state.font,SCENE_TEXT,22,&shaped)
	defer delete(shaped)
	pen_x:=f32(0)
	for glyph in shaped {
		slot,raster_err:=runa.raster_glyph(&state.font,glyph.glyph_id,22,0,&state.atlas)
		if raster_err!=.None { fmt.panicf("Runa raster failed: %v",raster_err) }
		view:=runa.atlas_slot_view(slot)
		if view.Px_Size[0]>0 && view.Px_Size[1]>0 {
			append(&state.glyph_quads,Glyph_Quad{
				x0=pen_x+glyph.x_offset+view.Bearing[0],
				y0=glyph.y_offset+view.Bearing[1],
				x1=pen_x+glyph.x_offset+view.Bearing[0]+f32(view.Px_Size[0]),
				y1=glyph.y_offset+view.Bearing[1]+f32(view.Px_Size[1]),
				uv=view.UV_Rect,
			})
		}
		pen_x+=glyph.x_advance
	}
	page,ok:=runa.atlas_page_view(&state.atlas,0,false)
	if !ok || page.Format!=.Alpha8 { fmt.panicf("Runa alpha atlas missing") }
	state.glyph_texture=wgpu.DeviceCreateTexture(state.device,&wgpu.TextureDescriptor{
		label="Runa glyph atlas",usage={.TextureBinding,.CopyDst},dimension=._2D,
		size={width=u32(page.Width),height=u32(page.Height),depthOrArrayLayers=1},
		format=.R8Unorm,mipLevelCount=1,sampleCount=1,
	})
	layout:=wgpu.TexelCopyBufferLayout{bytesPerRow=u32(page.Width),rowsPerImage=u32(page.Height)}
	extent:=wgpu.Extent3D{width=u32(page.Width),height=u32(page.Height),depthOrArrayLayers=1}
	destination:=wgpu.TexelCopyTextureInfo{texture=state.glyph_texture,aspect=.All}
	wgpu.QueueWriteTexture(state.queue,&destination,raw_data(page.Pixels),uint(len(page.Pixels)),&layout,&extent)
	state.glyph_view=wgpu.TextureCreateView(state.glyph_texture)
}

create_bind_group :: proc() {
	sampler_desc:=wgpu.SamplerDescriptor{
		addressModeU=.ClampToEdge,addressModeV=.ClampToEdge,addressModeW=.ClampToEdge,
		magFilter=.Linear,minFilter=.Linear,mipmapFilter=.Nearest,
		lodMinClamp=0,lodMaxClamp=1,maxAnisotropy=1,
	}
	state.sampler=wgpu.DeviceCreateSampler(state.device,&sampler_desc)
	entries:=[4]wgpu.BindGroupEntry{
		{binding=0,sampler=state.sampler},
		{binding=1,textureView=state.image_view},
		{binding=2,textureView=state.glyph_view},
		{binding=3,buffer=state.probe_uniform_buffer,offset=0,size=u64(size_of([4]f32))},
	}
	state.bind_group=wgpu.DeviceCreateBindGroup(state.device,&wgpu.BindGroupDescriptor{
		label="sampled test resources",layout=state.bind_group_layout,
		entryCount=uint(len(entries)),entries=&entries[0],
	})
}

render_surface_frame :: proc() {
	surface_texture:=wgpu.SurfaceGetCurrentTexture(state.surface)
	switch surface_texture.status {
	case .SuccessOptimal,.SuccessSuboptimal:
	case .Timeout,.Outdated,.Lost:
		if surface_texture.texture!=nil { wgpu.TextureRelease(surface_texture.texture) }
		resize(); return
	case .Occluded: return
	case .Error: fmt.panicf("surface acquisition failed: %v",surface_texture.status)
	}
	defer wgpu.TextureRelease(surface_texture.texture)
	view:=wgpu.TextureCreateView(surface_texture.texture)
	defer wgpu.TextureViewRelease(view)
	build_scene()
	if len(state.vertices)==0 { return }
	upload_size:=u64(len(state.vertices)*size_of(Vertex))
	if upload_size>state.vertex_capacity { fmt.panicf("vertex capacity exceeded: %d",upload_size) }
	wgpu.QueueWriteBuffer(state.queue,state.vertex_buffer,0,raw_data(state.vertices),uint(upload_size))
	encoder:=wgpu.DeviceCreateCommandEncoder(state.device)
	defer wgpu.CommandEncoderRelease(encoder)
	attachment:=wgpu.RenderPassColorAttachment{
		view=view,depthSlice=wgpu.DEPTH_SLICE_UNDEFINED,loadOp=.Clear,storeOp=.Store,
		clearValue={0.055,0.065,0.08,1},
	}
	pass:=wgpu.CommandEncoderBeginRenderPass(encoder,&wgpu.RenderPassDescriptor{colorAttachmentCount=1,colorAttachments=&attachment})
	wgpu.RenderPassEncoderSetPipeline(pass,state.pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass,0,state.bind_group)
	wgpu.RenderPassEncoderSetVertexBuffer(pass,0,state.vertex_buffer,0,state.vertex_capacity)
	for draw in state.draws {
		wgpu.RenderPassEncoderSetScissorRect(pass,draw.scissor[0],draw.scissor[1],draw.scissor[2],draw.scissor[3])
		wgpu.RenderPassEncoderDraw(pass,draw.count,1,draw.first,0)
	}
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
	command:=wgpu.CommandEncoderFinish(encoder)
	defer wgpu.CommandBufferRelease(command)
	wgpu.QueueSubmit(state.queue,{command})
	wgpu.SurfacePresent(state.surface)
	state.surface_present_count+=1
}

build_scene :: proc() {
	clear(&state.vertices); clear(&state.draws)
	if state.width==0 || state.height==0 { return }
	add_rounded_rect(24,24,720,250,20,[4]f32{0.12,0.15,0.19,1})
	add_rect(40,40,7,214,[4]f32{0.93,0.61,0.26,1})
	add_rounded_rect(42,106,248,136,12,[4]f32{0.20,0.26,0.30,1})
	add_textured_rect(42,106,248,136,[4]f32{1,1,1,0.98},106,176,136,136)
	add_glyph_text(322,94,[4]f32{0.93,0.94,0.91,1})
	start:=len(state.vertices)
	bar_count:=96
	wave_x,wave_y,wave_w:=f32(42),f32(334),f32(700)
	gap:=f32(2)
	bar_w:=(wave_w-f32(bar_count-1)*gap)/f32(bar_count)
	for i in 0..<bar_count {
		a:=f32((i*37+11)%29)/29
		b:=f32((i*13+7)%17)/17
		h:=15+a*54+b*21
		x:=wave_x+f32(i)*(bar_w+gap)
		add_quad_logical(x,wave_y+78-h,x+bar_w,wave_y+78,[4]f32{0.88,0.58,0.28,0.9},0)
	}
	add_draw(start,len(state.vertices),0,0,state.width,state.height)
	progress:=min(state.animation_seconds/ANIMATION_SECONDS,1)
	add_rounded_rect(42+progress*680,293,18,18,9,[4]f32{0.38,0.81,0.72,1})
}

add_glyph_text :: proc(x,baseline:f32,color:[4]f32) {
	start:=len(state.vertices)
	sx,sy:=f32(state.width)/960,f32(state.height)/540
	for glyph in state.glyph_quads {
		add_quad_px(&state.vertices,(x+glyph.x0)*sx,(baseline+glyph.y0)*sy,(x+glyph.x1)*sx,(baseline+glyph.y1)*sy,glyph.uv,color,2)
	}
	add_draw(start,len(state.vertices),0,0,state.width,state.height)
}
add_rect :: proc(x,y,w,h:f32,color:[4]f32) {
	start:=len(state.vertices)
	sx,sy:=f32(state.width)/960,f32(state.height)/540
	add_quad_px(&state.vertices,x*sx,y*sy,(x+w)*sx,(y+h)*sy,[4]f32{0,0,1,1},color,0)
	add_draw(start,len(state.vertices),0,0,state.width,state.height)
}
add_textured_rect :: proc(x,y,w,h:f32,color:[4]f32,cx,cy,cw,ch:f32) {
	start:=len(state.vertices)
	sx,sy:=f32(state.width)/960,f32(state.height)/540
	add_quad_px(&state.vertices,x*sx,y*sy,(x+w)*sx,(y+h)*sy,[4]f32{0,0,1,1},color,1)
	add_draw(start,len(state.vertices),u32(cx*sx),u32(cy*sy),u32(cw*sx),u32(ch*sy))
}
add_quad_logical :: proc(x0,y0,x1,y1:f32,color:[4]f32,kind:u32) {
	sx,sy:=f32(state.width)/960,f32(state.height)/540
	add_quad_px(&state.vertices,x0*sx,y0*sy,x1*sx,y1*sy,[4]f32{0,0,1,1},color,kind)
}
add_rounded_rect :: proc(x,y,w,h,radius:f32,color:[4]f32) {
	sx,sy:=f32(state.width)/960,f32(state.height)/540
	left,top,right,bottom:=x*sx,y*sy,(x+w)*sx,(y+h)*sy
	r:=min(radius*sx,min((right-left)/2,(bottom-top)/2))
	center:=[2]f32{(left+right)/2,(top+bottom)/2}
	start:=len(state.vertices)
	corners:=[4][3]f32{{left+r,top+r,3.14159265},{right-r,top+r,4.71238898},{right-r,bottom-r,0},{left+r,bottom-r,1.57079633}}
	previous,first:[2]f32
	have_previous:=false
	for corner in corners {
		for segment in 0..<7 {
			angle:=corner[2]+f32(segment)*1.57079633/6
			point:=[2]f32{corner[0]+r*f32(math.cos(f64(angle))),corner[1]+r*f32(math.sin(f64(angle)))}
			if have_previous {
				append(&state.vertices,make_vertex(center[0],center[1],[2]f32{0,0},color,0))
				append(&state.vertices,make_vertex(previous[0],previous[1],[2]f32{0,0},color,0))
				append(&state.vertices,make_vertex(point[0],point[1],[2]f32{0,0},color,0))
			} else { first=point }
			previous=point; have_previous=true
		}
	}
	if have_previous {
		append(&state.vertices,make_vertex(center[0],center[1],[2]f32{0,0},color,0))
		append(&state.vertices,make_vertex(previous[0],previous[1],[2]f32{0,0},color,0))
		append(&state.vertices,make_vertex(first[0],first[1],[2]f32{0,0},color,0))
	}
	add_draw(start,len(state.vertices),0,0,state.width,state.height)
}
add_quad_px :: proc(out:^[dynamic]Vertex,x0,y0,x1,y1:f32,uv:[4]f32,color:[4]f32,kind:u32) {
	p00:=make_vertex(x0,y0,[2]f32{uv[0],uv[1]},color,kind)
	p10:=make_vertex(x1,y0,[2]f32{uv[2],uv[1]},color,kind)
	p11:=make_vertex(x1,y1,[2]f32{uv[2],uv[3]},color,kind)
	p01:=make_vertex(x0,y1,[2]f32{uv[0],uv[3]},color,kind)
	append(out,p00,p10,p11,p00,p11,p01)
}
make_vertex :: proc(x,y:f32,uv:[2]f32,color:[4]f32,kind:u32)->Vertex {
	w,h:=max(f32(state.width),1),max(f32(state.height),1)
	return Vertex{[2]f32{2*x/w-1,1-2*y/h},uv,color,kind}
}
add_draw :: proc(start,end:int,x,y,w,h:u32) {
	if end<=start || w==0 || h==0 || x>=state.width || y>=state.height { return }
	append(&state.draws,Draw_Command{u32(start),u32(end-start),[4]u32{x,y,min(w,state.width-x),min(h,state.height-y)}})
}

start_offscreen_readback :: proc() {
	state.offscreen_texture=wgpu.DeviceCreateTexture(state.device,&wgpu.TextureDescriptor{
		label="offscreen readback target",usage={.RenderAttachment,.CopySrc},dimension=._2D,
		size={width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1},format=.RGBA8Unorm,mipLevelCount=1,sampleCount=1,
	})
	state.offscreen_view=wgpu.TextureCreateView(state.offscreen_texture)
	state.solid_offscreen_texture=wgpu.DeviceCreateTexture(state.device,&wgpu.TextureDescriptor{
		label="Alicorn solid display-list readback target",usage={.RenderAttachment,.CopySrc},dimension=._2D,
		size={width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1},format=.RGBA8Unorm,mipLevelCount=1,sampleCount=1,
	})
	state.solid_offscreen_view=wgpu.TextureCreateView(state.solid_offscreen_texture)
	state.readback_buffer=wgpu.DeviceCreateBuffer(state.device,&wgpu.BufferDescriptor{
		label="mapped readback staging",usage={.CopyDst,.MapRead},size=2*READBACK_BUFFER_BYTES,
	})
	partial_upload_vertex_start := build_offscreen_probe_scene()
	upload_size:=u64(len(state.vertices)*size_of(Vertex))
	wgpu.QueueWriteBuffer(state.queue,state.vertex_buffer,0,raw_data(state.vertices),uint(upload_size))
	probe_color := [4]f32{0.25,0.5,0.75,1}
	wgpu.QueueWriteBuffer(state.queue,state.probe_uniform_buffer,0,raw_data(probe_color[:]),uint(size_of(probe_color)))
	// Re-upload one quad at a nonzero offset to prove partial vertex-buffer
	// writes are visible to the following render submission.
	partial_vertices: [6]Vertex
	for i in 0..<len(partial_vertices) {
		partial_vertices[i] = state.vertices[partial_upload_vertex_start+i]
		partial_vertices[i].color = [4]f32{0.25,0.75,0.5,1}
	}
	partial_upload_offset := u64(partial_upload_vertex_start*size_of(Vertex))
	wgpu.QueueWriteBuffer(state.queue,state.vertex_buffer,partial_upload_offset,raw_data(partial_vertices[:]),uint(size_of(partial_vertices)))
	encoder:=wgpu.DeviceCreateCommandEncoder(state.device)
	attachment:=wgpu.RenderPassColorAttachment{view=state.offscreen_view,depthSlice=wgpu.DEPTH_SLICE_UNDEFINED,loadOp=.Clear,storeOp=.Store,clearValue={0.04,0.08,0.12,1}}
	pass:=wgpu.CommandEncoderBeginRenderPass(encoder,&wgpu.RenderPassDescriptor{colorAttachmentCount=1,colorAttachments=&attachment})
	wgpu.RenderPassEncoderSetPipeline(pass,state.offscreen_pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass,0,state.bind_group)
	wgpu.RenderPassEncoderSetVertexBuffer(pass,0,state.vertex_buffer,0,state.vertex_capacity)
	for draw in state.draws {
		wgpu.RenderPassEncoderSetScissorRect(pass,draw.scissor[0],draw.scissor[1],draw.scissor[2],draw.scissor[3])
		wgpu.RenderPassEncoderDraw(pass,draw.count,1,draw.first,0)
	}
	wgpu.RenderPassEncoderEnd(pass); wgpu.RenderPassEncoderRelease(pass)
	display, display_ok := alicorn.paint_display_list(&state.solid_runtime)
	if !display_ok { fmt.panicf("Alicorn solid fixture display list unavailable") }
	if result := webgpu_renderer.Solid_Encode(
		&state.solid_renderer, &state.solid_runtime, display, state.solid_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
	); result != .Ok {
		fmt.panicf("Alicorn WebGPU solid display-list encoding failed: %v", result)
	}
	mesh_rebuilds := state.solid_renderer.mesh_rebuild_count
	vertex_uploads := state.solid_renderer.vertex_upload_count
	viewport_uploads := state.solid_renderer.viewport_upload_count
	if mesh_rebuilds != 1 || vertex_uploads != 1 || viewport_uploads != 1 {
		fmt.panicf("initial Alicorn solid encode expected one mesh and one vertex/viewport upload")
	}
	if result := webgpu_renderer.Solid_Encode(
		&state.solid_renderer, &state.solid_runtime, display, state.solid_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
	); result != .Ok {
		fmt.panicf("Alicorn WebGPU cached solid display-list encoding failed: %v", result)
	}
	if state.solid_renderer.mesh_rebuild_count != mesh_rebuilds ||
		state.solid_renderer.vertex_upload_count != vertex_uploads ||
		state.solid_renderer.viewport_upload_count != viewport_uploads {
		fmt.panicf("unchanged Alicorn paint re-encoded mesh or viewport data")
	}
	fmt.printf("[webgpu-feasibility] retained solid cache PASS mesh_rebuilds=%d vertex_uploads=%d vertex_bytes=%d viewport_uploads=%d unchanged_repeat=true\n",
		state.solid_renderer.mesh_rebuild_count,state.solid_renderer.vertex_upload_count,
		state.solid_renderer.vertex_upload_bytes,state.solid_renderer.viewport_upload_count)
	// 63 RGBA8 texels use 252 bytes; the 256-byte row pitch exercises the
	// required four-byte per-row padding in both native and browser readback.
	layout:=wgpu.TexelCopyBufferLayout{bytesPerRow=READBACK_BYTES_PER_ROW,rowsPerImage=READBACK_HEIGHT}
	source:=wgpu.TexelCopyTextureInfo{texture=state.offscreen_texture,aspect=.All}
	destination:=wgpu.TexelCopyBufferInfo{layout=layout,buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(encoder,&source,&destination,&wgpu.Extent3D{width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1})
	solid_layout := layout
	solid_layout.offset = READBACK_BUFFER_BYTES
	solid_source := wgpu.TexelCopyTextureInfo{texture=state.solid_offscreen_texture,aspect=.All}
	solid_destination := wgpu.TexelCopyBufferInfo{layout=solid_layout,buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(encoder,&solid_source,&solid_destination,&wgpu.Extent3D{width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1})
	command:=wgpu.CommandEncoderFinish(encoder); wgpu.CommandEncoderRelease(encoder)
	wgpu.QueueSubmit(state.queue,{command}); wgpu.CommandBufferRelease(command)
	state.queue_work_done_pending = true
	wgpu.QueueOnSubmittedWorkDone(state.queue,{mode=.AllowProcessEvents,callback=on_queue_work_done})
	state.readback_pending=true
	wgpu.BufferMapAsync(state.readback_buffer,{.Read},0,2*READBACK_BUFFER_BYTES,{mode=.AllowProcessEvents,callback=on_readback})
}

// Build a real retained paint list for the first production WebGPU slice. The
// nested blue surface intentionally exceeds its clipped red parent, so pixels
// outside that parent verify that shared CPU geometry and GPU scissor agree.
build_solid_runtime :: proc() {
	state.solid_runtime = alicorn.new_runtime(alicorn.Rect{0, 0, f32(READBACK_WIDTH), f32(READBACK_HEIGHT)})
	state.solid_runtime_ready = true
	alicorn.invalidate_root(&state.solid_runtime, "WebGPU solid renderer feasibility fixture")
	ui, should_build := alicorn.begin_frame(&state.solid_runtime)
	if !should_build { fmt.panicf("Alicorn solid fixture runtime did not accept its initial description") }
	alicorn.container_begin(
		&ui, .Root, label="webgpu-solid-root",
		style=alicorn.layout_style(.Column, width=f32(READBACK_WIDTH), height=f32(READBACK_HEIGHT)),
		color=alicorn.Color{0.04, 0.08, 0.12, 1},
	)
	alicorn.container_begin(
		&ui, .Container, label="webgpu-solid-clipped-parent",
		style=alicorn.layout_style(width=36, height=36, clip=true),
		color=alicorn.Color{1, 0, 0, 0.5},
	)
	alicorn.container_begin(
		&ui, .Container, label="webgpu-solid-overlapping-child",
		style=alicorn.layout_style(width=48, height=48),
		color=alicorn.Color{0, 0, 1, 0.5},
	)
	alicorn.container_end(&ui)
	alicorn.container_end(&ui)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	view, view_ok := alicorn.paint_display_list(&state.solid_runtime)
	if !view_ok || len(view.commands) != 3 {
		fmt.panicf("Alicorn solid fixture expected three retained surface commands, got %d", len(view.commands))
	}
}

build_offscreen_probe_scene :: proc() -> int {
	previous_width,previous_height:=state.width,state.height
	state.width,state.height=READBACK_WIDTH,READBACK_HEIGHT
	clear(&state.vertices); clear(&state.draws)
	start:=len(state.vertices)
	// The center sample preserves the original exact solid-color probe.
	add_quad_px(&state.vertices,24,16,40,42,{0,0,1,1},{0.95,0.25,0.15,1},0)
	// A centered checker texel and the partially uploaded teal patch.
	add_quad_px(&state.vertices,2,2,18,18,{0,0,0.25,0.25},{1,1,1,1},1)
	add_quad_px(&state.vertices,2,20,18,36,{0.25,0.25,0.5,0.5},{1,1,1,1},1)
	// Source-over blend over a known opaque base.
	add_quad_px(&state.vertices,44,4,60,20,{0,0,1,1},{0.1,0.2,0.3,1},0)
	add_quad_px(&state.vertices,48,8,56,16,{0,0,1,1},{0.9,0.4,0.1,0.5},0)
	// Runa's first rasterized glyph is sampled at its most covered atlas texel.
	glyph_uv,glyph_ok:=offscreen_glyph_probe_uv()
	if glyph_ok { add_quad_px(&state.vertices,44,28,60,44,glyph_uv,{0.8,0.6,0.4,1},2) }
	add_draw(start,len(state.vertices),0,0,READBACK_WIDTH,READBACK_HEIGHT)
	// A wide primitive is clipped to an 8x8 scissor; a second sample checks
	// that the pixels beyond that clip remain at the clear color.
	start=len(state.vertices)
	add_quad_px(&state.vertices,0,28,20,44,{0,0,1,1},{0.1,0.8,0.2,1},0)
	add_draw(start,len(state.vertices),4,32,8,8)
	// This helper takes 960x540 logical coordinates, so inverse-scale the
	// 16x16 physical test shape into the offscreen target.
	add_rounded_rect(24*15,44*8.4375,16*15,16*8.4375,6*15,{0.6,0.3,0.9,1})
	partial_upload_vertex_start := len(state.vertices)
	add_quad_px(&state.vertices,2,48,12,58,{0,0,1,1},{0.9,0.1,0.1,1},0)
	add_draw(partial_upload_vertex_start,len(state.vertices),0,0,READBACK_WIDTH,READBACK_HEIGHT)
	uniform_vertex_start := len(state.vertices)
	add_quad_px(&state.vertices,44,48,60,60,{0,0,1,1},{1,1,1,1},3)
	add_draw(uniform_vertex_start,len(state.vertices),0,0,READBACK_WIDTH,READBACK_HEIGHT)
	state.width,state.height=previous_width,previous_height
	return partial_upload_vertex_start
}

offscreen_glyph_probe_uv :: proc() -> (uv:[4]f32,ok:bool) {
	if len(state.glyph_quads)==0 { return }
	page,page_ok:=runa.atlas_page_view(&state.atlas,0,false)
	if !page_ok || page.Width==0 || page.Height==0 { return }
	glyph:=state.glyph_quads[0]
	x0:=clamp(int(glyph.uv[0]*f32(page.Width)),0,int(page.Width)-1)
	y0:=clamp(int(glyph.uv[1]*f32(page.Height)),0,int(page.Height)-1)
	x1:=clamp(int(math.ceil(f64(glyph.uv[2]*f32(page.Width)))),x0+1,int(page.Width))
	y1:=clamp(int(math.ceil(f64(glyph.uv[3]*f32(page.Height)))),y0+1,int(page.Height))
	best_x,best_y:int
	best_coverage:u8=0
	for y in y0..<y1 {
		for x in x0..<x1 {
			coverage:=page.Pixels[y*int(page.Width)+x]
			if coverage>best_coverage { best_x,best_y,best_coverage=x,y,coverage }
		}
	}
	if best_coverage==0 { return }
	u:=(f32(best_x)+0.5)/f32(page.Width)
	v:=(f32(best_y)+0.5)/f32(page.Height)
	return [4]f32{u,v,u,v},true
}

on_readback :: proc "c" (status:wgpu.MapAsyncStatus,message:string,userdata1,userdata2:rawptr) {
	context=state.ctx; state.readback_pending=false
	if status!=.Success {
		fmt.printf("[webgpu-feasibility] readback failed: %v %s\n",status,message)
		when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
			if state.queue_work_done { state.quit = true }
		}
		return
	}
	pixels:=wgpu.BufferGetMappedRangeSlice(state.readback_buffer,0,u8,2*READBACK_BUFFER_BYTES)
	valid_range:=len(pixels)==2*READBACK_BUFFER_BYTES
	ok:=valid_range
	if valid_range {
		clear_pixel:=offscreen_pixel(pixels,20,10)
		solid_pixel:=offscreen_pixel(pixels,32,32)
		checker_pixel:=offscreen_pixel(pixels,10,10)
		patch_pixel:=offscreen_pixel(pixels,10,28)
		blend_pixel:=offscreen_pixel(pixels,52,12)
		glyph_pixel:=offscreen_pixel(pixels,52,36)
		clip_pixel:=offscreen_pixel(pixels,8,36)
		outside_clip_pixel:=offscreen_pixel(pixels,18,36)
		rounded_pixel:=offscreen_pixel(pixels,32,52)
		rounded_corner_pixel:=offscreen_pixel(pixels,24,44)
		last_row_pixel:=offscreen_pixel(pixels,62,63)
		partial_buffer_pixel:=offscreen_pixel(pixels,6,52)
		uniform_pixel:=offscreen_pixel(pixels,52,54)
		display_blend_pixel:=offscreen_pixel(pixels,24,24,READBACK_BUFFER_BYTES)
		display_clip_x_pixel:=offscreen_pixel(pixels,40,24,READBACK_BUFFER_BYTES)
		display_clip_y_pixel:=offscreen_pixel(pixels,24,40,READBACK_BUFFER_BYTES)
		clear_expected:=[4]u8{10,20,31,255}
		solid_expected:=[4]u8{242,64,38,255}
		checker_expected:=[4]u8{232,166,86,255}
		patch_expected:=[4]u8{72,206,166,255}
		blend_expected:=[4]u8{128,77,51,255}
		glyph_expected:=[4]u8{204,153,102,255}
		clip_expected:=[4]u8{26,204,51,255}
		rounded_expected:=[4]u8{153,77,230,255}
		clear_ok:=offscreen_pixel_near(clear_pixel,clear_expected)
		solid_ok:=offscreen_pixel_near(solid_pixel,solid_expected)
		checker_ok:=offscreen_pixel_near(checker_pixel,checker_expected)
		patch_ok:=offscreen_pixel_near(patch_pixel,patch_expected)
		blend_ok:=offscreen_pixel_near(blend_pixel,blend_expected)
		glyph_ok:=offscreen_pixel_near(glyph_pixel,glyph_expected)
		clip_ok:=offscreen_pixel_near(clip_pixel,clip_expected)
		outside_clip_ok:=offscreen_pixel_near(outside_clip_pixel,clear_expected)
		rounded_ok:=offscreen_pixel_near(rounded_pixel,rounded_expected)
		rounded_corner_ok:=offscreen_pixel_near(rounded_corner_pixel,clear_expected)
		last_row_ok:=offscreen_pixel_near(last_row_pixel,clear_expected)
		partial_buffer_ok:=offscreen_pixel_near(partial_buffer_pixel,[4]u8{64,191,128,255})
		uniform_ok:=offscreen_pixel_near(uniform_pixel,[4]u8{64,128,191,255})
		display_blend_ok:=offscreen_pixel_near(display_blend_pixel,[4]u8{66,5,136,255},4)
		display_clip_x_ok:=offscreen_pixel_near(display_clip_x_pixel,clear_expected)
		display_clip_y_ok:=offscreen_pixel_near(display_clip_y_pixel,clear_expected)
		ok=clear_ok && solid_ok && checker_ok && patch_ok && blend_ok && glyph_ok && clip_ok && outside_clip_ok && rounded_ok && rounded_corner_ok && last_row_ok && partial_buffer_ok && uniform_ok && display_blend_ok && display_clip_x_ok && display_clip_y_ok
		fmt.printf("[webgpu-feasibility] async RGBA8 readback %s texture=%dx%d row_pitch=%d padding_per_row=%d bytes=%d clear=%v solid=%v checker=%v partial_texture=%v partial_buffer=%v uniform=%v blend=%v glyph=%v clip=%v outside_clip=%v rounded=%v rounded_corner=%v last_row=%v runtime_display_blend=%v runtime_clip_x=%v runtime_clip_y=%v\n",
			"PASS" if ok else "FAIL",READBACK_WIDTH,READBACK_HEIGHT,READBACK_BYTES_PER_ROW,READBACK_BYTES_PER_ROW-READBACK_WIDTH*READBACK_BYTES_PER_PIXEL,len(pixels),clear_ok,solid_ok,checker_ok,patch_ok,partial_buffer_ok,uniform_ok,blend_ok,glyph_ok,clip_ok,outside_clip_ok,rounded_ok,rounded_corner_ok,last_row_ok,display_blend_ok,display_clip_x_ok,display_clip_y_ok)
	} else {
		fmt.printf("[webgpu-feasibility] async RGBA8 readback FAIL bytes=%d expected=%d\n",len(pixels),2*READBACK_BUFFER_BYTES)
	}
	wgpu.BufferUnmap(state.readback_buffer); state.readback_done=ok
	when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
		if state.queue_work_done && (!FEASIBILITY_TEST_RESIZE || state.test_resize_post_frame) {
			state.quit=true
		}
	}
	when FEASIBILITY_TEST_DEVICE_LOSS {
		if ok {
			// Defer destroy until the host has returned from this callback. In
			// particular, native wgpuDevicePoll must not be re-entered by destroying
			// the device from one of the callbacks it is currently dispatching.
			state.test_device_loss_pending=true
		}
	}
}

offscreen_pixel :: proc(pixels:[]u8,x,y:int,base_offset:int=0) -> [4]u8 {
	i:=base_offset+y*READBACK_BYTES_PER_ROW+x*READBACK_BYTES_PER_PIXEL
	return [4]u8{pixels[i],pixels[i+1],pixels[i+2],pixels[i+3]}
}

offscreen_pixel_near :: proc(actual,expected:[4]u8,tolerance:u8=3) -> bool {
	for channel in 0..<4 {
		delta:=i32(actual[channel])-i32(expected[channel])
		if delta<0 { delta=-delta }
		if delta>i32(tolerance) { return false }
	}
	return true
}

begin_test_device_loss :: proc() {
	when FEASIBILITY_TEST_DEVICE_LOSS {
		if state.test_device_loss_pending && !state.test_device_loss_triggered {
			state.test_device_loss_pending=false
			state.test_device_loss_triggered=true
			state.ready=false
			when FEASIBILITY_TEST_DEVICE_LOSS_RELEASE_BEFORE_POLL {
				device := state.device
				state.device = nil
				wgpu.DeviceDestroy(device)
				if state.queue != nil {
					wgpu.QueueRelease(state.queue)
					state.queue = nil
				}
				wgpu.DeviceRelease(device)
			} else {
				wgpu.DeviceDestroy(state.device)
			}
		}
	}
}
