package webgpu_feasibility

import "core:fmt"
import "core:math"
import alicorn "../../runtime"
import cpu_renderer "../../renderer/cpu"
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
	when FEASIBILITY_TEST_WEB_CANVAS_PRESENTER || FEASIBILITY_TEST_SURFACE_PRESENTER {
		if state.surface_presenter_completion_pending { return }
	}
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
	when FEASIBILITY_TEST_WEB_CANVAS_PRESENTER {
		display, display_status := alicorn.paint_display_list_for_output(&state.surface_runtime, state.surface_output)
		if display_status != .Ok { fmt.panicf("Alicorn browser canvas output display list unavailable: %v", display_status) }
		snapshot, snapshot_status := alicorn.presentation_output_snapshot(&state.surface_runtime, state.surface_output)
		if snapshot_status != .Ok || !snapshot.pending || snapshot.root != state.surface_runtime_root ||
		   snapshot.revision != display.revision {
			fmt.panicf("Alicorn browser canvas output view does not match its pending revision: status=%v view=%d snapshot=%d",
				snapshot_status, display.revision, snapshot.revision)
		}
		encoder := wgpu.DeviceCreateCommandEncoder(state.device)
		if encoder == nil { fmt.panicf("browser canvas command encoder creation failed") }
		defer wgpu.CommandEncoderRelease(encoder)
		scale := min(
			f32(state.config.width)/f32(SURFACE_PRESENTER_LOGICAL_WIDTH),
			f32(state.config.height)/f32(SURFACE_PRESENTER_LOGICAL_HEIGHT),
		)
		if result := webgpu_renderer.WebGPU_Presenter_Encode(
			&state.surface_presenter, display, encoder, view,
			state.config.width, state.config.height, scale, scale,
			true, wgpu.Color{0.04, 0.06, 0.08, 1}, state.surface_output,
		); result != .Ok {
			fmt.panicf("Alicorn browser canvas WebGPU encode failed: %v", result)
		}
		command := wgpu.CommandEncoderFinish(encoder)
		if command == nil {
			_ = webgpu_renderer.WebGPU_Presenter_Cancel_Frame(&state.surface_presenter)
			fmt.panicf("browser canvas command buffer finish failed")
		}
		defer wgpu.CommandBufferRelease(command)
		wgpu.QueueSubmit(state.queue, {command})
		submission, submitted := webgpu_renderer.WebGPU_Presenter_Submission_Succeeded(&state.surface_presenter)
		if !submitted { fmt.panicf("browser canvas presenter submission commit failed") }
		state.surface_presenter_submission = submission
		acknowledged, ack_status := alicorn.presentation_output_snapshot(&state.surface_runtime, state.surface_output)
		state.surface_output_acknowledged = ack_status == .Ok && submission.output_bound &&
			submission.output_id.runtime_identity == state.surface_output.runtime_identity &&
			submission.output_id.sequence == state.surface_output.sequence &&
			acknowledged.acknowledged_revision == submission.display_revision && !acknowledged.pending
		if !state.surface_output_acknowledged {
			fmt.panicf("Alicorn browser canvas output acknowledgement mismatch: status=%v revision=%d token=%d",
				ack_status, acknowledged.acknowledged_revision, submission.display_revision)
		}
		state.surface_presenter_completion_pending = true
		wgpu.QueueOnSubmittedWorkDone(state.queue, {mode=.AllowProcessEvents, callback=on_surface_presenter_queue_done})
		wgpu.SurfacePresent(state.surface)
		state.surface_present_count += 1
		fmt.printf("[webgpu-feasibility] Alicorn retained display presented to browser canvas revision=%d size=%dx%d scale=%.3f\n",
			submission.display_revision, state.config.width, state.config.height, scale)
		fmt.printf("[webgpu-feasibility] browser Runtime output acknowledgement PASS sequence=%d revision=%d\n",
			submission.output_id.sequence, acknowledged.acknowledged_revision)
	} else when FEASIBILITY_TEST_SURFACE_PRESENTER {
		display, display_status := alicorn.paint_display_list_for_output(&state.surface_runtime, state.surface_output)
		if display_status != .Ok { fmt.panicf("Alicorn SDL surface output display list unavailable: %v", display_status) }
		snapshot, snapshot_status := alicorn.presentation_output_snapshot(&state.surface_runtime, state.surface_output)
		if snapshot_status != .Ok || !snapshot.pending || snapshot.root != state.surface_runtime_root {
			fmt.panicf("Alicorn SDL surface output is not bound and pending: %v", snapshot_status)
		}
		if display.revision != snapshot.revision {
			fmt.panicf("Alicorn SDL surface display revision %d does not match output revision %d",
				display.revision, snapshot.revision)
		}
		encoder := wgpu.DeviceCreateCommandEncoder(state.device)
		if encoder == nil { fmt.panicf("SDL surface command encoder creation failed") }
		defer wgpu.CommandEncoderRelease(encoder)
		scale := min(
			f32(state.config.width)/f32(SURFACE_PRESENTER_LOGICAL_WIDTH),
			f32(state.config.height)/f32(SURFACE_PRESENTER_LOGICAL_HEIGHT),
		)
		if result := webgpu_renderer.WebGPU_Presenter_Encode(
			&state.surface_presenter, display, encoder, view,
			state.config.width, state.config.height, scale, scale,
			true, wgpu.Color{0.04, 0.06, 0.08, 1}, state.surface_output,
		); result != .Ok {
			fmt.panicf("Alicorn SDL surface WebGPU encode failed: %v", result)
		}
		command := wgpu.CommandEncoderFinish(encoder)
		if command == nil {
			_ = webgpu_renderer.WebGPU_Presenter_Cancel_Frame(&state.surface_presenter)
			fmt.panicf("SDL surface command buffer finish failed")
		}
		defer wgpu.CommandBufferRelease(command)
		wgpu.QueueSubmit(state.queue, {command})
		submission, submitted := webgpu_renderer.WebGPU_Presenter_Submission_Succeeded(&state.surface_presenter)
		if !submitted { fmt.panicf("Alicorn SDL surface submission commit failed") }
		state.surface_presenter_submission = submission
		acknowledged, ack_status := alicorn.presentation_output_snapshot(&state.surface_runtime, state.surface_output)
		state.surface_output_acknowledged = ack_status == .Ok && submission.output_bound &&
			submission.output_id.runtime_identity == state.surface_output.runtime_identity &&
			submission.output_id.sequence == state.surface_output.sequence &&
			acknowledged.acknowledged_revision == submission.display_revision && !acknowledged.pending
		if !state.surface_output_acknowledged {
			fmt.panicf("Alicorn SDL surface output acknowledgement mismatch: status=%v snapshot=%d acknowledged=%d pending=%v token_revision=%d token_output=%d/%d expected_output=%d/%d bound=%v",
				ack_status, acknowledged.revision, acknowledged.acknowledged_revision, acknowledged.pending, submission.display_revision,
				submission.output_id.runtime_identity, submission.output_id.sequence,
				state.surface_output.runtime_identity, state.surface_output.sequence, submission.output_bound)
		}
		state.surface_presenter_completion_pending = true
		wgpu.QueueOnSubmittedWorkDone(state.queue, {mode=.AllowProcessEvents, callback=on_surface_presenter_queue_done})
		wgpu.SurfacePresent(state.surface)
		state.surface_present_count += 1
		state.animation_seconds = ANIMATION_SECONDS
		fmt.printf("[webgpu-feasibility] Alicorn retained display presented to SDL WebGPU surface output_revision=%d size=%dx%d scale=%.3f\n",
			submission.display_revision, state.config.width, state.config.height, scale)
		fmt.printf("[webgpu-feasibility] Runtime output acknowledgement PASS sequence=%d revision=%d; output unregisters before Runtime teardown\n",
			submission.output_id.sequence, acknowledged.acknowledged_revision)
	} else {
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
	state.text_offscreen_texture=wgpu.DeviceCreateTexture(state.device,&wgpu.TextureDescriptor{
		label="Alicorn text display-list readback target",usage={.RenderAttachment,.CopySrc},dimension=._2D,
		size={width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1},format=.RGBA8Unorm,mipLevelCount=1,sampleCount=1,
	})
	state.text_offscreen_view=wgpu.TextureCreateView(state.text_offscreen_texture)
	state.composite_offscreen_texture=wgpu.DeviceCreateTexture(state.device,&wgpu.TextureDescriptor{
		label="Alicorn mixed paint-order compositor readback target",usage={.RenderAttachment,.CopySrc},dimension=._2D,
		size={width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1},format=.RGBA8Unorm,mipLevelCount=1,sampleCount=1,
	})
	state.composite_offscreen_view=wgpu.TextureCreateView(state.composite_offscreen_texture)
	when FEASIBILITY_TEST_WEBGPU_PRESENTER {
		state.presenter_offscreen_texture=wgpu.DeviceCreateTexture(state.device,&wgpu.TextureDescriptor{
			label="host-owned WebGPU presenter parity target",usage={.RenderAttachment,.CopySrc},dimension=._2D,
			size={width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1},format=.RGBA8Unorm,mipLevelCount=1,sampleCount=1,
		})
		state.presenter_offscreen_view=wgpu.TextureCreateView(state.presenter_offscreen_texture)
		if state.presenter_offscreen_texture == nil || state.presenter_offscreen_view == nil {
			fmt.panicf("host-owned WebGPU presenter parity target creation failed")
		}
	}
	state.backdrop_offscreen_texture=wgpu.DeviceCreateTexture(state.device,&wgpu.TextureDescriptor{
		label="Alicorn backdrop effect paint-order readback target",usage={.RenderAttachment,.CopySrc},dimension=._2D,
		size={width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1},format=.RGBA8Unorm,mipLevelCount=1,sampleCount=1,
	})
	state.backdrop_offscreen_view=wgpu.TextureCreateView(state.backdrop_offscreen_texture)
	state.capture_offscreen_texture=wgpu.DeviceCreateTexture(state.device,&wgpu.TextureDescriptor{
		label="Alicorn cropped compositor capture target",usage={.RenderAttachment,.CopySrc},dimension=._2D,
		size={width=CAPTURE_WIDTH,height=CAPTURE_HEIGHT,depthOrArrayLayers=1},format=.RGBA8Unorm,mipLevelCount=1,sampleCount=1,
	})
	state.capture_offscreen_view=wgpu.TextureCreateView(state.capture_offscreen_texture)
	state.readback_buffer=wgpu.DeviceCreateBuffer(state.device,&wgpu.BufferDescriptor{
		label="mapped readback staging",usage={.CopyDst,.MapRead},size=READBACK_TOTAL_BYTES,
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
	translation_uploads := state.solid_renderer.translation_upload_count
	viewport_uploads := state.solid_renderer.viewport_upload_count
	if mesh_rebuilds != 1 || vertex_uploads != 1 || translation_uploads != 1 || viewport_uploads != 1 {
		fmt.panicf("initial Alicorn solid encode expected one mesh, vertex, transform, and viewport upload")
	}
	if result := webgpu_renderer.Solid_Encode(
		&state.solid_renderer, &state.solid_runtime, display, state.solid_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
	); result != .Ok {
		fmt.panicf("Alicorn WebGPU cached solid display-list encoding failed: %v", result)
	}
	if state.solid_renderer.mesh_rebuild_count != mesh_rebuilds ||
		state.solid_renderer.vertex_upload_count != vertex_uploads ||
		state.solid_renderer.translation_upload_count != translation_uploads ||
		state.solid_renderer.viewport_upload_count != viewport_uploads {
		fmt.panicf("unchanged Alicorn paint re-encoded mesh or viewport data")
	}
	fmt.printf("[webgpu-feasibility] retained solid cache PASS mesh_rebuilds=%d vertex_uploads=%d vertex_bytes=%d transform_uploads=%d transform_bytes=%d viewport_uploads=%d unchanged_repeat=true\n",
		state.solid_renderer.mesh_rebuild_count,state.solid_renderer.vertex_upload_count,
		state.solid_renderer.vertex_upload_bytes,state.solid_renderer.translation_upload_count,
		state.solid_renderer.translation_upload_bytes,state.solid_renderer.viewport_upload_count)
	text_display, text_display_ok := alicorn.paint_display_list(&state.text_runtime)
	if !text_display_ok { fmt.panicf("Alicorn text fixture display list unavailable") }
	if result := webgpu_renderer.Text_Prepare(
		&state.text_renderer, &state.text_runtime, text_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("Alicorn WebGPU text preparation failed: %v", result)
	}
	text_mesh_rebuilds := state.text_renderer.mesh_rebuild_count
	text_vertex_uploads := state.text_renderer.vertex_upload_count
	text_atlas_uploads := state.text_renderer.atlas_upload_count
	text_translation_uploads := state.text_renderer.translation_upload_count
	text_viewport_uploads := state.text_renderer.viewport_upload_count
	text_atlas_page_creates := state.text_renderer.atlas_page_create_count
	text_prepare_buffer_creates := state.text_renderer.prepare_buffer_create_count
	if text_mesh_rebuilds != 1 || text_vertex_uploads != 1 || text_atlas_uploads == 0 {
		fmt.panicf("initial Alicorn text prepare expected one mesh/vertex upload and a glyph atlas upload")
	}
	text_attachment := wgpu.RenderPassColorAttachment{
		view=state.text_offscreen_view,
		depthSlice=wgpu.DEPTH_SLICE_UNDEFINED,
		loadOp=.Clear,
		storeOp=.Store,
		clearValue={0.04, 0.08, 0.12, 1},
	}
	text_pass := wgpu.CommandEncoderBeginRenderPass(encoder, &wgpu.RenderPassDescriptor{
		colorAttachmentCount=1,
		colorAttachments=&text_attachment,
	})
	if text_pass == nil { fmt.panicf("Alicorn WebGPU text fixture pass unavailable") }
	for command, command_index in text_display.commands {
		if result := webgpu_renderer.Text_Draw_Command(
			&state.text_renderer, text_pass, command_index, command,
			READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
		); result != .Ok {
			fmt.panicf("Alicorn WebGPU text command encoding failed: %v", result)
		}
	}
	wgpu.RenderPassEncoderEnd(text_pass)
	wgpu.RenderPassEncoderRelease(text_pass)
	// The synthetic list exercises renderer interleaving: an
	// underlay, retained text, an opaque surface over that text, and a second
	// text copy offset below, a one-pixel scissor sentinel, and a clipped tinted
	// icon from each immutable atlas page, analytic material surfaces, and two
	// Runtime images. The first icon must restore the target scissor after the
	// sentinel, and encoding switches atlas bindings.
	mixed_text_command: alicorn.Paint_Command
	mixed_text_found := false
	for command in text_display.commands {
		if alicorn.paint_command_is_text(command) {
			mixed_text_command = command
			mixed_text_found = true
			break
		}
	}
	if !mixed_text_found { fmt.panicf("Alicorn mixed compositor fixture did not find retained text") }
	composite_clip := alicorn.Rect{0, 0, f32(READBACK_WIDTH), f32(READBACK_HEIGHT)}
	mixed_commands := make([dynamic]alicorn.Paint_Command, 0, 16, allocator=context.temp_allocator)
	append(&mixed_commands, alicorn.paint_surface_command(
		0, composite_clip, composite_clip, alicorn.Color{0.08, 0.12, 0.18, 1},
	))
	append(&mixed_commands, mixed_text_command)
	append(&mixed_commands, alicorn.paint_surface_command(
		0, {0, 0, f32(READBACK_WIDTH), 24}, composite_clip, alicorn.Color{0.8, 0.1, 0.1, 1},
	))
	offset_mixed_text := mixed_text_command
	offset_mixed_text.bounds.y += 28
	offset_mixed_text.clip.y += 28
	append(&mixed_commands, offset_mixed_text)
	for command in text_display.commands {
		if !alicorn.paint_command_is_surface(command) { continue }
		for surface_id in state.compositor_material_surface_ids {
			if command.owner == surface_id {
				append(&mixed_commands, command)
				break
			}
		}
	}
	geometry_command, geometry_found := fixture_custom_geometry_command(
		text_display, state.compositor_custom_surface_ids[0],
		{22, 44, 20, 18}, {22, 44, 20, 18},
	)
	if !geometry_found { fmt.panicf("Alicorn custom geometry fixture did not retain its Geometry_Paint command") }
	append(&mixed_commands, geometry_command)
	waveform_command, waveform_found := fixture_custom_geometry_command(
		text_display, state.compositor_custom_surface_ids[1],
		{44, 44, 18, 18}, {44, 44, 18, 18},
	)
	if !waveform_found { fmt.panicf("Alicorn waveform fixture did not retain its Geometry_Paint command") }
	append(&mixed_commands, waveform_command)
	append(&mixed_commands, alicorn.paint_surface_command(
		0, {0, 0, f32(READBACK_WIDTH), f32(READBACK_HEIGHT)}, {62, 63, 1, 1}, alicorn.Color{0.08, 0.12, 0.18, 1},
	))
	append(&mixed_commands, alicorn.paint_icon_command(
		0, {0, 24, 48, 48}, {18, 46, 12, 12}, .Folder_Closed, alicorn.Color{0.96, 0.45, 0.08, 1},
	))
	append(&mixed_commands, alicorn.paint_icon_command(
		0, {40, 43, 18, 18}, {45, 48, 12, 10}, .Search, alicorn.Color{0.12, 0.34, 0.96, 1},
	))
	append(&mixed_commands, alicorn.paint_image_command(
		0, {0, 44, 10, 14}, composite_clip, state.compositor_image_a,
	))
	append(&mixed_commands, alicorn.paint_image_command(
		0, {6, 48, 12, 12}, {6, 48, 10, 12}, state.compositor_image_b,
	))
	mixed_display := alicorn.Paint_Display_List_View{commands=mixed_commands[:], revision=text_display.revision}
	when FEASIBILITY_TEST_COMPOSITOR_RECREATION {
		state.compositor_recreation_commands = make([]alicorn.Paint_Command, len(mixed_commands), allocator=context.allocator)
		copy(state.compositor_recreation_commands, mixed_commands[:])
		state.compositor_recreation_revision = mixed_display.revision
	}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, mixed_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("Alicorn mixed WebGPU compositor preparation failed: %v", result)
	}
	if result := webgpu_renderer.Compositor_Encode(
		&state.compositor, &state.text_runtime, mixed_display, state.composite_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
	); result != .Ok {
		fmt.panicf("Alicorn mixed WebGPU compositor encoding failed: %v", result)
	}
	when FEASIBILITY_TEST_WEBGPU_PRESENTER {
		if result := webgpu_renderer.WebGPU_Presenter_Encode(
			&state.presenter, mixed_display, encoder, state.presenter_offscreen_view,
			READBACK_WIDTH, READBACK_HEIGHT, 1, 1, true, wgpu.Color{0.04, 0.08, 0.12, 1},
		); result != .Ok {
			fmt.panicf("host-owned WebGPU presenter encoding failed: %v", result)
		}
		presenter_layout := wgpu.TexelCopyBufferLayout{
			bytesPerRow=READBACK_BYTES_PER_ROW, rowsPerImage=READBACK_HEIGHT,
			offset=14*READBACK_BUFFER_BYTES,
		}
		presenter_source := wgpu.TexelCopyTextureInfo{texture=state.presenter_offscreen_texture,aspect=.All}
		presenter_destination := wgpu.TexelCopyBufferInfo{layout=presenter_layout,buffer=state.readback_buffer}
		wgpu.CommandEncoderCopyTextureToBuffer(encoder,&presenter_source,&presenter_destination,
			&wgpu.Extent3D{width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1})
	}
	if result := webgpu_renderer.Compositor_Encode(
		&state.compositor, &state.text_runtime, mixed_display, state.capture_offscreen_view,
		CAPTURE_WIDTH, CAPTURE_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
		true, [2]int{CAPTURE_ORIGIN_X, CAPTURE_ORIGIN_Y}, 1,
	); result != .Ok {
		fmt.panicf("Alicorn cropped WebGPU compositor capture failed: %v", result)
	}
	capture_layout := wgpu.TexelCopyBufferLayout{
		bytesPerRow=READBACK_BYTES_PER_ROW,
		rowsPerImage=CAPTURE_HEIGHT,
		offset=5*READBACK_BUFFER_BYTES,
	}
	capture_source := wgpu.TexelCopyTextureInfo{texture=state.capture_offscreen_texture,aspect=.All}
	capture_destination := wgpu.TexelCopyBufferInfo{layout=capture_layout,buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(encoder,&capture_source,&capture_destination,
		&wgpu.Extent3D{width=CAPTURE_WIDTH,height=CAPTURE_HEIGHT,depthOrArrayLayers=1})
	if result := webgpu_renderer.Compositor_Encode(
		&state.compositor, &state.text_runtime, mixed_display, state.capture_offscreen_view,
		CAPTURE_WIDTH, CAPTURE_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
		true, [2]int{}, 2,
	); result != .Ok {
		fmt.panicf("Alicorn second cropped WebGPU compositor capture failed: %v", result)
	}
	capture_layout.offset = 6*READBACK_BUFFER_BYTES
	capture_destination.layout = capture_layout
	wgpu.CommandEncoderCopyTextureToBuffer(encoder,&capture_source,&capture_destination,
		&wgpu.Extent3D{width=CAPTURE_WIDTH,height=CAPTURE_HEIGHT,depthOrArrayLayers=1})
	composite_solid_meshes := state.compositor.solid.mesh_rebuild_count
	composite_solid_uploads := state.compositor.solid.vertex_upload_count
	composite_text_meshes := state.compositor.text.mesh_rebuild_count
	composite_text_uploads := state.compositor.text.vertex_upload_count
	composite_atlas_uploads := state.compositor.text.atlas_upload_count
	composite_text_translation_uploads := state.compositor.text.translation_upload_count
	composite_icon_meshes := state.compositor.icons.mesh_rebuild_count
	composite_icon_uploads := state.compositor.icons.vertex_upload_count
	composite_icon_atlas_uploads := state.compositor.icons.atlas_page_upload_count
	composite_icon_cache_hits := state.compositor.icons.mesh_cache_hits
	composite_image_meshes := state.compositor.images.mesh_rebuild_count
	composite_image_uploads := state.compositor.images.vertex_upload_count
	composite_image_texture_uploads := state.compositor.images.texture_upload_count
	composite_image_texture_bytes := state.compositor.images.texture_upload_bytes
	composite_surface_meshes := state.compositor.surfaces.mesh_rebuild_count
	composite_surface_uploads := state.compositor.surfaces.vertex_upload_count
	composite_surface_cache_hits := state.compositor.surfaces.mesh_cache_hits
	composite_surface_instance_uploads := state.compositor.surfaces.instance_upload_count
	surface_vertices := 0
	for draw in state.compositor.surfaces.draws { surface_vertices += int(draw.vertex_count) }
	// The mixed scene uses icons from every compiled atlas page, so one initial
	// upload of each page must total the generated atlas size. Derive it instead
	// of pinning a byte count: adding a built-in icon can grow the last page.
	expected_icon_atlas_bytes := u64(0)
	for page in alicorn.ICON_ATLAS_PAGES { expected_icon_atlas_bytes += u64(len(page.pixels)) }
	if composite_solid_meshes != 1 || composite_solid_uploads != 1 ||
	   composite_text_meshes != 1 || composite_text_uploads != 1 || composite_atlas_uploads == 0 ||
	   composite_icon_meshes != 1 || composite_icon_uploads != 1 || composite_icon_atlas_uploads != 2 ||
	   state.compositor.icons.atlas_upload_bytes != expected_icon_atlas_bytes ||
	   composite_image_meshes != 1 || composite_image_uploads != 1 || composite_image_texture_uploads != 2 ||
	   composite_image_texture_bytes != 2*4*4*4 || state.compositor.images.resident_bytes != 2*4*4*4 ||
	   composite_surface_meshes != 2 || composite_surface_uploads != 2 || surface_vertices != 72 ||
	   composite_surface_instance_uploads != 1 || len(state.compositor.surfaces.draws) != 2 {
		fmt.panicf("initial mixed composition expected retained solid/text/icon/image/custom-surface meshes and uploads: solid=%d/%d text=%d/%d atlas=%d icon=%d/%d ia=%d iab=%d image=%d/%d it=%d itb=%d rb=%d surf=%d/%d sv=%d si=%d draws=%d",
			composite_solid_meshes, composite_solid_uploads,
			composite_text_meshes, composite_text_uploads, composite_atlas_uploads,
			composite_icon_meshes, composite_icon_uploads, composite_icon_atlas_uploads,
			state.compositor.icons.atlas_upload_bytes,
			composite_image_meshes, composite_image_uploads, composite_image_texture_uploads,
			composite_image_texture_bytes, state.compositor.images.resident_bytes,
			composite_surface_meshes, composite_surface_uploads, surface_vertices,
			composite_surface_instance_uploads, len(state.compositor.surfaces.draws))
	}
	fmt.printf("[webgpu-feasibility] mixed paint-order compositor PASS commands=%d solid_meshes=%d text_meshes=%d icon_meshes=%d icon_vertex_uploads=%d icon_atlas_pages=%d icon_atlas_bytes=%d image_meshes=%d image_vertex_uploads=%d image_texture_uploads=%d image_texture_bytes=%d custom_surface_meshes=%d custom_surface_vertex_uploads=%d custom_surface_vertices=%d instance_uploads=%d\n",
		len(mixed_display.commands), composite_solid_meshes, composite_text_meshes, composite_icon_meshes,
		composite_icon_uploads, composite_icon_atlas_uploads, state.compositor.icons.atlas_upload_bytes,
		composite_image_meshes, composite_image_uploads, composite_image_texture_uploads, composite_image_texture_bytes,
		composite_surface_meshes, composite_surface_uploads, surface_vertices, composite_surface_instance_uploads)
	controlled_text_readback_encode(encoder)
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
	text_layout := layout
	text_layout.offset = 2*READBACK_BUFFER_BYTES
	text_source := wgpu.TexelCopyTextureInfo{texture=state.text_offscreen_texture,aspect=.All}
	text_destination := wgpu.TexelCopyBufferInfo{layout=text_layout,buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(encoder,&text_source,&text_destination,&wgpu.Extent3D{width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1})
	composite_layout := layout
	composite_layout.offset = 3*READBACK_BUFFER_BYTES
	composite_source := wgpu.TexelCopyTextureInfo{texture=state.composite_offscreen_texture,aspect=.All}
	composite_destination := wgpu.TexelCopyBufferInfo{layout=composite_layout,buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(encoder,&composite_source,&composite_destination,&wgpu.Extent3D{width=READBACK_WIDTH,height=READBACK_HEIGHT,depthOrArrayLayers=1})
	controlled_text_layout := layout
	controlled_text_layout.offset = 16*READBACK_BUFFER_BYTES
	controlled_text_source := wgpu.TexelCopyTextureInfo{texture=state.controlled_text_readback.texture,aspect=.All}
	controlled_text_destination := wgpu.TexelCopyBufferInfo{layout=controlled_text_layout,buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(
		encoder, &controlled_text_source, &controlled_text_destination,
		&wgpu.Extent3D{width=READBACK_WIDTH, height=READBACK_HEIGHT, depthOrArrayLayers=1},
	)
	command:=wgpu.CommandEncoderFinish(encoder); wgpu.CommandEncoderRelease(encoder)
	wgpu.QueueSubmit(state.queue,{command}); wgpu.CommandBufferRelease(command)
	when FEASIBILITY_TEST_WEBGPU_PRESENTER {
		presenter_submission, presenter_submitted := webgpu_renderer.WebGPU_Presenter_Submission_Succeeded(&state.presenter)
		if !presenter_submitted { fmt.panicf("host-owned WebGPU presenter submission commit failed") }
		state.presenter_submission = presenter_submission
		fmt.printf("[webgpu-feasibility] host-owned presenter frame submitted serial=%d revision=%d readback_slot=14\n",
			state.presenter_submission.serial, state.presenter_submission.display_revision)
	}
	webgpu_renderer.Text_Commit_Submission(&state.text_renderer, &state.text_runtime)
	webgpu_renderer.Text_Commit_Submission(
		&state.controlled_text_readback.renderer, &state.controlled_text_readback.runtime,
	)
	state.compositor_completion_serial = webgpu_renderer.Compositor_Commit_Submission(&state.compositor, &state.text_runtime)
	if state.compositor_completion_serial == 0 { fmt.panicf("mixed compositor submission did not receive a completion serial") }
	if result := webgpu_renderer.Solid_Prepare(
		&state.solid_renderer, &state.solid_runtime, display, READBACK_WIDTH-1, READBACK_HEIGHT-1, 1, 1,
	); result != .Ok {
		fmt.panicf("resized solid renderer preparation failed: %v", result)
	}
	if result := webgpu_renderer.Solid_Prepare(
		&state.solid_renderer, &state.solid_runtime, display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("restored solid renderer preparation failed: %v", result)
	}
	if state.solid_renderer.mesh_rebuild_count != mesh_rebuilds ||
		state.solid_renderer.vertex_upload_count != vertex_uploads ||
		state.solid_renderer.translation_upload_count != translation_uploads ||
		state.solid_renderer.viewport_upload_count != viewport_uploads+2 {
		fmt.panicf("target resizing should update only the viewport while retaining solid geometry")
	}
	fmt.println("[webgpu-feasibility] solid target resize cache PASS mesh_rebuilds=0 vertex_uploads=0 transform_uploads=0 viewport_uploads=2")
	solid_motion_commands := make([]alicorn.Paint_Command, len(display.commands), allocator=context.temp_allocator)
	copy(solid_motion_commands, display.commands)
	solid_motion_found := false
	for &command in solid_motion_commands {
		surface, is_surface := command.payload.(alicorn.Surface_Paint)
		if !is_surface || surface.fill.b < 0.9 || surface.fill.r > 0.1 { continue }
		command.translation = {5, 5}
		command.clip = {5, 5, 20, 20}
		solid_motion_found = true
		break
	}
	if !solid_motion_found { fmt.panicf("solid motion fixture did not find its clipped blue surface") }
	solid_motion_display := display
	solid_motion_display.commands = solid_motion_commands
	solid_motion_display.revision += 1
	if result := webgpu_renderer.Solid_Prepare(
		&state.solid_renderer, &state.solid_runtime, solid_motion_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("translated solid surface preparation failed: %v", result)
	}
	if state.solid_renderer.mesh_rebuild_count != mesh_rebuilds ||
		state.solid_renderer.vertex_upload_count != vertex_uploads ||
		state.solid_renderer.translation_upload_count != translation_uploads+1 {
		fmt.panicf("surface translation and clip changes should update only the solid transform buffer")
	}
	fmt.printf("[webgpu-feasibility] solid translation cache PASS mesh_rebuilds=0 vertex_uploads=0 transform_uploads=1 transform_bytes=%d\n",
		len(state.solid_renderer.translations)*size_of([2]f32))
	solid_motion_encoder := wgpu.DeviceCreateCommandEncoder(state.device)
	if solid_motion_encoder == nil { fmt.panicf("solid motion command encoder creation failed") }
	if result := webgpu_renderer.Solid_Encode(
		&state.solid_renderer, &state.solid_runtime, solid_motion_display, state.solid_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, solid_motion_encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
	); result != .Ok {
		fmt.panicf("translated solid surface encoding failed: %v", result)
	}
	solid_motion_layout := wgpu.TexelCopyBufferLayout{
		bytesPerRow=READBACK_BYTES_PER_ROW, rowsPerImage=READBACK_HEIGHT,
		offset=15*READBACK_BUFFER_BYTES,
	}
	solid_motion_source := wgpu.TexelCopyTextureInfo{texture=state.solid_offscreen_texture, aspect=.All}
	solid_motion_destination := wgpu.TexelCopyBufferInfo{layout=solid_motion_layout, buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(solid_motion_encoder, &solid_motion_source, &solid_motion_destination,
		&wgpu.Extent3D{width=READBACK_WIDTH, height=READBACK_HEIGHT, depthOrArrayLayers=1})
	solid_motion_command := wgpu.CommandEncoderFinish(solid_motion_encoder)
	wgpu.CommandEncoderRelease(solid_motion_encoder)
	wgpu.QueueSubmit(state.queue, {solid_motion_command})
	wgpu.CommandBufferRelease(solid_motion_command)
	fmt.println("[webgpu-feasibility] solid instance transform submitted PASS translation=5,5 clip=5,5,20,20 readback_slot=15")
	run_backdrop_effect_probe()
	if result := webgpu_renderer.Text_Prepare(
		&state.text_renderer, &state.text_runtime, text_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("unchanged Alicorn text prepare failed: %v", result)
	}
	if state.text_renderer.mesh_rebuild_count != text_mesh_rebuilds ||
		state.text_renderer.vertex_upload_count != text_vertex_uploads ||
		state.text_renderer.atlas_upload_count != text_atlas_uploads ||
		state.text_renderer.translation_upload_count != text_translation_uploads ||
		state.text_renderer.viewport_upload_count != text_viewport_uploads ||
		state.text_renderer.atlas_page_create_count != text_atlas_page_creates ||
		state.text_renderer.prepare_buffer_create_count != text_prepare_buffer_creates {
		fmt.panicf("unchanged Alicorn text rebuilt or uploaded retained products")
	}
	motion_commands := make([]alicorn.Paint_Command, len(text_display.commands), allocator=context.temp_allocator)
	copy(motion_commands, text_display.commands)
	text_command_found := false
	for &command, command_index in motion_commands {
		_, is_text := command.payload.(alicorn.Text_Paint)
		if !is_text { continue }
		command.translation = [2]f32{3, 2}
		text_command_found = true
		break
	}
	if !text_command_found { fmt.panicf("Alicorn text fixture did not contain a text paint command") }
	motion_display := text_display
	motion_display.commands = motion_commands
	if result := webgpu_renderer.Text_Prepare(
		&state.text_renderer, &state.text_runtime, motion_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("translated Alicorn text prepare failed: %v", result)
	}
	if state.text_renderer.mesh_rebuild_count != text_mesh_rebuilds ||
		state.text_renderer.vertex_upload_count != text_vertex_uploads ||
		state.text_renderer.atlas_upload_count != text_atlas_uploads ||
		state.text_renderer.atlas_page_create_count != text_atlas_page_creates ||
		state.text_renderer.translation_upload_count != text_translation_uploads+1 ||
		state.text_renderer.viewport_upload_count != text_viewport_uploads ||
		state.text_renderer.prepare_buffer_create_count != text_prepare_buffer_creates {
		fmt.panicf("text-only motion rebuilt glyph geometry or atlas resources")
	}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, mixed_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("unchanged mixed compositor preparation failed: %v", result)
	}
	if state.compositor.solid.mesh_rebuild_count != composite_solid_meshes ||
	   state.compositor.solid.vertex_upload_count != composite_solid_uploads ||
	   state.compositor.text.mesh_rebuild_count != composite_text_meshes ||
	   state.compositor.text.vertex_upload_count != composite_text_uploads ||
	   state.compositor.text.atlas_upload_count != composite_atlas_uploads ||
	   state.compositor.icons.mesh_rebuild_count != composite_icon_meshes ||
	   state.compositor.icons.vertex_upload_count != composite_icon_uploads ||
	   state.compositor.icons.atlas_page_upload_count != composite_icon_atlas_uploads ||
	   state.compositor.icons.mesh_cache_hits != composite_icon_cache_hits+1 ||
	   state.compositor.images.mesh_rebuild_count != composite_image_meshes ||
	   state.compositor.images.vertex_upload_count != composite_image_uploads ||
	   state.compositor.images.texture_upload_count != composite_image_texture_uploads ||
	   state.compositor.images.texture_upload_bytes != composite_image_texture_bytes ||
	   state.compositor.images.mesh_cache_hits != 1 ||
	   state.compositor.surfaces.mesh_rebuild_count != composite_surface_meshes ||
	   state.compositor.surfaces.vertex_upload_count != composite_surface_uploads ||
	   state.compositor.surfaces.mesh_cache_hits != composite_surface_cache_hits+2 ||
	   state.compositor.surfaces.instance_upload_count != composite_surface_instance_uploads ||
	   state.compositor.surfaces.instance_cache_hits != 1 {
		fmt.panicf("unchanged mixed paint rebuilt or uploaded retained renderer products")
	}
	text_revision_commands := make(
		[dynamic]alicorn.Paint_Command,
		len(mixed_display.commands),
		allocator=context.temp_allocator,
	)
	copy(text_revision_commands[:], mixed_display.commands)
	text_revision_found := false
	for &command in text_revision_commands {
		text, is_text := command.payload.(alicorn.Text_Paint)
		if !is_text { continue }
		command.translation[0] += 2
		command.payload = text
		text_revision_found = true
		break
	}
	if !text_revision_found { fmt.panicf("mixed compositor fixture did not contain text for revision-only update") }
	text_revision_display := mixed_display
	text_revision_display.commands = text_revision_commands[:]
	text_revision_display.revision += 1
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, text_revision_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("text-only revision compositor preparation failed: %v", result)
	}
	if state.compositor.solid.mesh_rebuild_count != composite_solid_meshes ||
		state.compositor.solid.vertex_upload_count != composite_solid_uploads ||
		state.compositor.text.mesh_rebuild_count != composite_text_meshes ||
		state.compositor.text.vertex_upload_count != composite_text_uploads ||
		state.compositor.text.atlas_upload_count != composite_atlas_uploads ||
		state.compositor.text.translation_upload_count != composite_text_translation_uploads+1 {
		fmt.panicf("text-only paint revision should retain solid and glyph geometry and update only text translation")
	}
	fmt.println("[webgpu-feasibility] text-only revision retained solid geometry PASS")
	geometry_motion_commands := make([dynamic]alicorn.Paint_Command, len(mixed_display.commands), allocator=context.temp_allocator)
	copy(geometry_motion_commands[:], mixed_display.commands)
	geometry_motion_found := false
	for &command in geometry_motion_commands {
		if !alicorn.paint_command_is_geometry(command) { continue }
		command.translation[0] += 3
		command.opacity = 0.5
		geometry_motion_found = true
		break
	}
	if !geometry_motion_found { fmt.panicf("custom geometry motion fixture did not contain a geometry command") }
	geometry_motion_display := mixed_display
	geometry_motion_display.commands = geometry_motion_commands[:]
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, geometry_motion_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("moved custom geometry preparation failed: %v", result)
	}
	if state.compositor.surfaces.mesh_rebuild_count != composite_surface_meshes ||
		state.compositor.surfaces.vertex_upload_count != composite_surface_uploads ||
		state.compositor.surfaces.mesh_cache_hits != composite_surface_cache_hits+6 ||
		state.compositor.surfaces.instance_upload_count != composite_surface_instance_uploads+1 {
		fmt.panicf("geometry movement and opacity changes should update instances without rebuilding meshes")
	}
	motion_encoder := wgpu.DeviceCreateCommandEncoder(state.device)
	if motion_encoder == nil { fmt.panicf("custom geometry motion encoder creation failed") }
	if result := webgpu_renderer.Compositor_Encode(
		&state.compositor, &state.text_runtime, geometry_motion_display, state.composite_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, motion_encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
	); result != .Ok {
		fmt.panicf("moved custom geometry encoding failed: %v", result)
	}
	motion_layout := wgpu.TexelCopyBufferLayout{bytesPerRow=READBACK_BYTES_PER_ROW, rowsPerImage=READBACK_HEIGHT, offset=4*READBACK_BUFFER_BYTES}
	motion_source := wgpu.TexelCopyTextureInfo{texture=state.composite_offscreen_texture, aspect=.All}
	motion_destination := wgpu.TexelCopyBufferInfo{layout=motion_layout, buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(motion_encoder, &motion_source, &motion_destination,
		&wgpu.Extent3D{width=READBACK_WIDTH, height=READBACK_HEIGHT, depthOrArrayLayers=1})
	motion_command := wgpu.CommandEncoderFinish(motion_encoder)
	wgpu.CommandEncoderRelease(motion_encoder)
	wgpu.QueueSubmit(state.queue, {motion_command})
	wgpu.CommandBufferRelease(motion_command)
	state.compositor_completion_serial = webgpu_renderer.Compositor_Commit_Submission(&state.compositor, &state.text_runtime)
	if state.compositor_completion_serial != 2 { fmt.panicf("custom geometry motion frame did not receive shared submission serial 2") }
	fmt.println("[webgpu-feasibility] custom geometry motion readback submitted instance_translation=true opacity=0.5 readback_slot=4")
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, mixed_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("restored custom geometry preparation failed: %v", result)
	}
	if state.compositor.surfaces.mesh_rebuild_count != composite_surface_meshes ||
		state.compositor.surfaces.vertex_upload_count != composite_surface_uploads ||
		state.compositor.surfaces.instance_upload_count != composite_surface_instance_uploads+2 {
		fmt.panicf("restoring custom geometry placement should reuse meshes and restore only instance data")
	}
	fmt.println("[webgpu-feasibility] custom geometry instance cache PASS translation_and_opacity_changes=1 mesh_rebuilds=0 vertex_uploads=0")
	surface_meshes_before_growth := state.compositor.surfaces.mesh_rebuild_count
	surface_uploads_before_growth := state.compositor.surfaces.vertex_upload_count
	surface_cache_hits_before_growth := state.compositor.surfaces.mesh_cache_hits
	surface_instance_uploads_before_growth := state.compositor.surfaces.instance_upload_count

	// Grow the live waveform payload after serial 1 was submitted. The retained
	// geometry cache replaces only that resource's buffer and holds its old
	// buffer until the submitted frame's queue-completion notification arrives.
	waveform_growth := [20]f32{0, 0.2, 0.4, 0.6, 0.8, 1, 0.8, 0.6, 0.4, 0.2,
		0, 0.2, 0.4, 0.6, 0.8, 1, 0.8, 0.6, 0.4, 0.2}
	if !alicorn.gpu_surface_update(&state.text_runtime, state.compositor_custom_surface_ids[1], waveform_growth[:]) {
		fmt.panicf("Alicorn waveform growth update was rejected")
	}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, mixed_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("grown waveform compositor preparation failed: %v", result)
	}
	if state.compositor.surfaces.mesh_rebuild_count != surface_meshes_before_growth+1 ||
		state.compositor.surfaces.vertex_upload_count != surface_uploads_before_growth+1 ||
		state.compositor.surfaces.mesh_cache_hits != surface_cache_hits_before_growth+1 ||
		state.compositor.surfaces.instance_upload_count != surface_instance_uploads_before_growth ||
		len(state.compositor.surfaces.retired) != 1 ||
		state.compositor.surfaces.retired[0].retire_after_serial != state.compositor_completion_serial ||
		state.compositor.surfaces.resource_retirement_count != 1 {
		fmt.panicf("waveform update should rebuild only its resource and retire the in-flight buffer by serial")
	}
	fmt.printf("[webgpu-feasibility] per-resource geometry cache PASS static_mesh_reused=true waveform_rebuilt=true instance_uploads_unchanged=true old_buffer_retired_after=%d\n",
		state.compositor.surfaces.retired[0].retire_after_serial)
	moved_image_commands := make([dynamic]alicorn.Paint_Command, len(mixed_display.commands), allocator=context.temp_allocator)
	copy(moved_image_commands[:], mixed_display.commands)
	for &command in moved_image_commands {
		if paint, is_image := command.payload.(alicorn.Image_Paint); is_image && paint.image == state.compositor_image_a {
			command.bounds.x += 1
			break
		}
	}
	moved_image_display := mixed_display
	moved_image_display.commands = moved_image_commands[:]
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, moved_image_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("moved image preparation failed: %v", result)
	}
	if state.compositor.images.mesh_rebuild_count != composite_image_meshes+1 ||
		state.compositor.images.vertex_upload_count != composite_image_uploads+1 ||
		state.compositor.images.texture_upload_count != composite_image_texture_uploads {
		fmt.panicf("image geometry change should upload its mesh without re-uploading unchanged image pixels")
	}
fmt.printf("[webgpu-feasibility] retained text cache PASS mesh_rebuilds=%d vertex_uploads=%d atlas_uploads=%d atlas_bytes=%d atlas_page_creates=%d prepare_buffer_creates=%d translation_uploads=%d viewport_uploads=%d unchanged_repeat=true\n",
		state.text_renderer.mesh_rebuild_count, state.text_renderer.vertex_upload_count,
		state.text_renderer.atlas_upload_count, state.text_renderer.atlas_upload_bytes,
		state.text_renderer.atlas_page_create_count, state.text_renderer.prepare_buffer_create_count,
		state.text_renderer.translation_upload_count,
		state.text_renderer.viewport_upload_count)
	fmt.println("[webgpu-feasibility] text motion cache PASS translated_command_only=true glyph_mesh_uploads=0 atlas_uploads=0 atlas_page_creates=0")
	if !alicorn.image_release(&state.text_runtime, state.compositor_image_b) {
		fmt.panicf("blue compositor image did not release from its Runtime")
	}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, mixed_display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("stale image compositor preparation failed: %v", result)
	}
	if len(state.compositor.images.retired) != 1 || state.compositor.images.resident_bytes != 2*4*4*4 ||
		state.compositor.images.texture_upload_count != composite_image_texture_uploads ||
		state.compositor.images.mesh_rebuild_count != composite_image_meshes+2 {
		fmt.panicf("released in-flight image should remain retired until completion while its new mesh omits it")
	}
	if webgpu_renderer.Compositor_Complete_Submission(
		&state.compositor, state.compositor_completion_serial+1,
	) || state.compositor.images.completed_serial != 0 || len(state.compositor.images.retired) != 1 ||
		state.compositor.surfaces.completed_serial != 0 || len(state.compositor.surfaces.retired) != 1 {
		fmt.panicf("completion beyond the last submitted serial must not retire GPU resources")
	}
	fmt.println("[webgpu-feasibility] image retained cache PASS unchanged_texture_uploads=0 geometry_edit_reuses_pixels=true released_inflight=true stale_draw_removed=true retirement_waits_for_queue=true")
	state.queue_work_done_pending = true
	wgpu.QueueOnSubmittedWorkDone(state.queue,{mode=.AllowProcessEvents,callback=on_queue_work_done})
	state.readback_pending=true
	wgpu.BufferMapAsync(state.readback_buffer,{.Read},0,READBACK_TOTAL_BYTES,{mode=.AllowProcessEvents,callback=on_readback})
}

backdrop_probe_entry :: proc(owner: alicorn.Node_ID = alicorn.Node_ID(2)) -> ^webgpu_renderer.Backdrop_Effect_Entry {
	for &entry in state.backdrop_compositor.backdrops {
		if entry.runtime == &state.text_runtime && entry.owner == owner { return &entry }
	}
	return nil
}

run_backdrop_effect_probe :: proc() {
	viewport := alicorn.Rect{0, 0, f32(READBACK_WIDTH), f32(READBACK_HEIGHT)}
	region := alicorn.Rect{20, 20, 24, 24}
	clip := alicorn.Rect{24, 20, 16, 24}
	commands := make([dynamic]alicorn.Paint_Command, 0, 5, allocator=context.temp_allocator)
	append(&commands,
		alicorn.paint_surface_command(1, viewport, viewport, alicorn.Color{0.04, 0.06, 0.08, 1}),
		alicorn.paint_surface_command(1, {16, 12, 12, 40}, viewport, alicorn.Color{1, 0, 0, 1}),
		alicorn.paint_surface_command(1, {32, 12, 12, 40}, viewport, alicorn.Color{0, 0, 1, 1}),
		alicorn.paint_backdrop_effect_command(alicorn.Node_ID(2), region, clip, alicorn.backdrop_blur(2)),
		alicorn.paint_surface_command(2, region, clip, alicorn.Color{1, 1, 1, 0.12}),
	)
	display := alicorn.Paint_Display_List_View{commands=commands[:], revision=1}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.backdrop_compositor, &state.text_runtime, display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("Alicorn backdrop effect compositor preparation failed: %v", result)
	}
	backdrop_entry := backdrop_probe_entry()
	if backdrop_entry == nil || !backdrop_entry.ready || backdrop_entry.plan.width != 36 ||
	   backdrop_entry.plan.height != 36 {
		fmt.panicf("Alicorn backdrop effect plan did not include the expected six-pixel Gaussian halo")
	}
	encoder := wgpu.DeviceCreateCommandEncoder(state.device)
	if encoder == nil { fmt.panicf("Alicorn backdrop effect command encoder creation failed") }
	if result := webgpu_renderer.Compositor_Encode(
		&state.backdrop_compositor, &state.text_runtime, display, state.backdrop_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.06, 0.08, 1},
	); result != .Ok {
		fmt.panicf("Alicorn backdrop effect compositor encoding failed: %v", result)
	}
	layout := wgpu.TexelCopyBufferLayout{
		bytesPerRow=READBACK_BYTES_PER_ROW,
		rowsPerImage=READBACK_HEIGHT,
		offset=7*READBACK_BUFFER_BYTES,
	}
	source := wgpu.TexelCopyTextureInfo{texture=state.backdrop_offscreen_texture, aspect=.All}
	destination := wgpu.TexelCopyBufferInfo{layout=layout, buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(encoder, &source, &destination,
		&wgpu.Extent3D{width=READBACK_WIDTH, height=READBACK_HEIGHT, depthOrArrayLayers=1})
	command := wgpu.CommandEncoderFinish(encoder)
	wgpu.CommandEncoderRelease(encoder)
	if command == nil { webgpu_renderer.Compositor_Abort_Submission(&state.backdrop_compositor); fmt.panicf("Alicorn backdrop effect command finish failed") }
	wgpu.QueueSubmit(state.queue, {command})
	wgpu.CommandBufferRelease(command)
	state.backdrop_completion_serial = webgpu_renderer.Compositor_Commit_Submission(&state.backdrop_compositor, &state.text_runtime)
	if state.backdrop_completion_serial == 0 { fmt.panicf("backdrop effect frame did not receive a completion serial") }
	fmt.printf("[webgpu-feasibility] backdrop initial frame capture=%d filters=%d/%d composite=%d texture_bytes=%d cache_budget=%d\n",
		backdrop_entry.renderer.capture_count,
		backdrop_entry.renderer.horizontal_pass_count,
		backdrop_entry.renderer.vertical_pass_count,
		backdrop_entry.renderer.composite_count,
		backdrop_entry.renderer.resident_bytes,
		webgpu_renderer.WEBGPU_BACKDROP_EFFECT_RESIDENT_BUDGET_BYTES)
	if result := webgpu_renderer.Compositor_Prepare(
		&state.backdrop_compositor, &state.text_runtime, display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("unchanged backdrop prefix preparation failed: %v", result)
	}
	backdrop_entry = backdrop_probe_entry()
	if backdrop_entry == nil || backdrop_entry.renderer.cache_hits != 1 || backdrop_entry.renderer.capture_count != 1 ||
	   backdrop_entry.renderer.horizontal_pass_count != 1 || backdrop_entry.renderer.vertical_pass_count != 1 {
		fmt.panicf("unchanged backdrop prefix did not reuse its completed output")
	}
	backdrop_probe_submit(display, 7)
	initial_prefix_generation := backdrop_entry.plan.source_generation
	commands[2] = alicorn.paint_surface_command(1, {32, 12, 12, 40}, viewport, alicorn.Color{0, 1, 0, 1})
	display.revision += 1
	if result := webgpu_renderer.Compositor_Prepare(
		&state.backdrop_compositor, &state.text_runtime, display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("changed backdrop prefix preparation failed: %v", result)
	}
	backdrop_entry = backdrop_probe_entry()
	if backdrop_entry == nil || backdrop_entry.renderer.cache_hits != 1 ||
	   backdrop_entry.plan.source_generation == initial_prefix_generation ||
	   backdrop_entry.renderer.mesh_rebuild_count != 1 {
		fmt.panicf("changed backdrop prefix counters differ: cache=%d capture=%d horizontal=%d vertical=%d mesh=%d",
			backdrop_entry.renderer.cache_hits,
			backdrop_entry.renderer.capture_count,
			backdrop_entry.renderer.horizontal_pass_count,
			backdrop_entry.renderer.vertical_pass_count,
			backdrop_entry.renderer.mesh_rebuild_count)
	}
	backdrop_probe_submit(display, 8)
	backdrop_entry = backdrop_probe_entry()
	if backdrop_entry.renderer.capture_count != 2 ||
	   backdrop_entry.renderer.horizontal_pass_count != 2 || backdrop_entry.renderer.vertical_pass_count != 2 ||
	   backdrop_entry.renderer.composite_count != 3 {
		fmt.panicf("changed backdrop prefix did not encode a new capture/filter result")
	}
	retirement_serial := state.backdrop_completion_serial
	old_width, old_height := backdrop_entry.renderer.set.width, backdrop_entry.renderer.set.height
	if backdrop_entry.renderer.completed_serial >= retirement_serial {
		fmt.panicf("backdrop resize fixture must keep the prior texture set in flight")
	}
	resized_region := alicorn.Rect{18, 18, 28, 28}
	commands[3] = alicorn.paint_backdrop_effect_command(alicorn.Node_ID(2), resized_region, clip, alicorn.backdrop_blur(2))
	commands[4] = alicorn.paint_surface_command(2, resized_region, clip, alicorn.Color{1, 1, 1, 0.12})
	display.revision += 1
	if result := webgpu_renderer.Compositor_Prepare(
		&state.backdrop_compositor, &state.text_runtime, display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("resized backdrop preparation failed: %v", result)
	}
	backdrop_entry = backdrop_probe_entry()
	backdrop := &backdrop_entry.renderer
	if !backdrop_entry.ready || backdrop.set.width == old_width && backdrop.set.height == old_height ||
	   len(backdrop.retired) != 1 || backdrop.retired[0].retire_after_serial != retirement_serial ||
	   backdrop.resident_bytes <= backdrop.set.bytes {
		fmt.panicf("resized backdrop textures were not retained behind the prior completion serial")
	}
	retired_bytes := backdrop.retired[0].set.bytes
	backdrop_probe_submit(display, 9)
	fmt.printf("[webgpu-feasibility] backdrop resize retirement queued old=%dx%d old_bytes=%d new=%dx%d retired=%d retire_after=%d\n",
		old_width, old_height, retired_bytes, backdrop.set.width, backdrop.set.height,
		len(backdrop.retired), backdrop.retired[0].retire_after_serial)

	// The second marker's captured prefix must contain the first marker's
	// composite. Compare against the same paint list with only the first marker
	// removed; pixels inside the second effect's clip should then differ.
	multi_commands := make([dynamic]alicorn.Paint_Command, len(commands)+2, allocator=context.temp_allocator)
	copy(multi_commands[:], commands[:])
	second_region := alicorn.Rect{28, 20, 24, 24}
	append(&multi_commands,
		alicorn.paint_backdrop_effect_command(alicorn.Node_ID(3), second_region, second_region, alicorn.backdrop_blur(2)),
		alicorn.paint_surface_command(3, second_region, second_region, alicorn.Color{1, 1, 1, 0.12}),
	)
	multi_display := alicorn.Paint_Display_List_View{commands=multi_commands[:], revision=display.revision+1}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.backdrop_compositor, &state.text_runtime, multi_display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("two-marker backdrop preparation failed: %v", result)
	}
	first_entry := backdrop_probe_entry(alicorn.Node_ID(2))
	second_entry := backdrop_probe_entry(alicorn.Node_ID(3))
	if first_entry == nil || second_entry == nil || !first_entry.ready || !second_entry.ready ||
	   len(state.backdrop_compositor.backdrops) != 2 ||
	   first_entry.renderer.resident_bytes+second_entry.renderer.resident_bytes > webgpu_renderer.WEBGPU_BACKDROP_EFFECT_RESIDENT_BUDGET_BYTES {
		fmt.panicf("two-marker backdrop cache did not stay ready within its aggregate byte budget")
	}
	first_composites_before := first_entry.renderer.composite_count
	second_composites_before := second_entry.renderer.composite_count
	backdrop_probe_submit(multi_display, 12)
	first_entry = backdrop_probe_entry(alicorn.Node_ID(2))
	second_entry = backdrop_probe_entry(alicorn.Node_ID(3))
	if first_entry.renderer.composite_count != first_composites_before+2 ||
	   second_entry.renderer.composite_count != second_composites_before+1 {
		fmt.panicf("two-marker backdrop prefix did not composite each earlier effect in retained order")
	}
	without_first_marker := make([dynamic]alicorn.Paint_Command, 0, len(multi_commands)-1, allocator=context.temp_allocator)
	for command, index in multi_commands {
		if index != 3 { append(&without_first_marker, command) }
	}
	without_first_display := alicorn.Paint_Display_List_View{
		commands=without_first_marker[:], revision=multi_display.revision+1,
	}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.backdrop_compositor, &state.text_runtime, without_first_display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("two-marker no-first-effect comparison preparation failed: %v", result)
	}
	second_entry = backdrop_probe_entry(alicorn.Node_ID(3))
	if second_entry == nil || !second_entry.ready { fmt.panicf("later backdrop effect should remain enabled without an earlier effect") }
	backdrop_probe_submit(without_first_display, 13)
	fmt.println("[webgpu-feasibility] multiple backdrop markers encoded in retained paint order; pixel comparison queued")

	// A valid plan whose three textures exceed the renderer budget must skip
	// only the effect marker; ordinary paint after it must match paint with no
	// marker exactly. The source and target here remain within GPU dimensions.
	huge_region := alicorn.Rect{0, 0, 1600, 1600}
	fallback_generation := cpu_renderer.Backdrop_Effect_Prefix_Generation_For_Runtime(
		&state.text_runtime, commands[:3], huge_region, viewport, 1, 1, 2,
	)
	fallback_plan, fallback_plan_ok := cpu_renderer.Backdrop_Effect_Plan_Make(cpu_renderer.Backdrop_Effect_Request{
		enabled=true, key=u64(alicorn.Node_ID(2)), source_generation=fallback_generation,
		region=huge_region, clip=viewport, scale=1, sigma=2, depth=1,
	})
	fallback_bytes := u64(fallback_plan.width)*u64(fallback_plan.height)*20 + webgpu_renderer.WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES
	if !fallback_plan_ok || !fallback_plan.active || fallback_bytes <= webgpu_renderer.WEBGPU_BACKDROP_EFFECT_RESIDENT_BUDGET_BYTES {
		fmt.panicf("budget fallback fixture must produce a valid plan above the renderer's bounded texture budget")
	}
	commands[3] = alicorn.paint_backdrop_effect_command(alicorn.Node_ID(2), huge_region, viewport, alicorn.backdrop_blur(2))
	commands[4] = alicorn.paint_surface_command(2, huge_region, viewport, alicorn.Color{1, 1, 1, 0.12})
	display.revision += 1
	resident_before_fallback := backdrop.resident_bytes
	if result := webgpu_renderer.Compositor_Prepare(
		&state.backdrop_compositor, &state.text_runtime, display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("over-budget backdrop fallback preparation failed: %v", result)
	}
	backdrop_entry = backdrop_probe_entry()
	if backdrop_entry.ready || backdrop.resident_bytes != resident_before_fallback ||
	   len(backdrop.retired) != 1 {
		fmt.panicf("over-budget backdrop should preserve existing resources and skip only the effect marker")
	}
	backdrop_probe_submit(display, 10)
	fallback_commands := make([dynamic]alicorn.Paint_Command, 0, 4, allocator=context.temp_allocator)
	for command, index in commands {
		if index != 3 { append(&fallback_commands, command) }
	}
	// The display sequence changed when the marker was omitted, so give the
	// renderer a distinct revision and rebuild command-indexed draw records.
	fallback_display := alicorn.Paint_Display_List_View{commands=fallback_commands[:], revision=display.revision+1}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.backdrop_compositor, &state.text_runtime, fallback_display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.panicf("ordinary backdrop fallback comparison preparation failed: %v", result)
	}
	backdrop_probe_submit(fallback_display, 11)
	fmt.printf("[webgpu-feasibility] backdrop WebGPU prefix cache PASS capture=%d filters=%d/%d composite=%d cache_hits=%d mesh_rebuilds=%d texture_bytes=%d cache_budget=%d resize_retired=%d budget_fallback_bytes=%d\n",
		backdrop_entry.renderer.capture_count,
		backdrop_entry.renderer.horizontal_pass_count,
		backdrop_entry.renderer.vertical_pass_count,
		backdrop_entry.renderer.composite_count,
		backdrop_entry.renderer.cache_hits,
		backdrop_entry.renderer.mesh_rebuild_count,
		backdrop_entry.renderer.resident_bytes,
		webgpu_renderer.WEBGPU_BACKDROP_EFFECT_RESIDENT_BUDGET_BYTES,
		len(backdrop_entry.renderer.retired), fallback_bytes)
}

backdrop_probe_submit :: proc(display: alicorn.Paint_Display_List_View, readback_slot: int) {
	if readback_slot < 0 || readback_slot >= READBACK_TARGET_COUNT { fmt.panicf("backdrop probe readback slot is out of range") }
	encoder := wgpu.DeviceCreateCommandEncoder(state.device)
	if encoder == nil { fmt.panicf("Alicorn backdrop effect command encoder creation failed") }
	if result := webgpu_renderer.Compositor_Encode(
		&state.backdrop_compositor, &state.text_runtime, display, state.backdrop_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.06, 0.08, 1},
	); result != .Ok {
		wgpu.CommandEncoderRelease(encoder)
		webgpu_renderer.Compositor_Abort_Submission(&state.backdrop_compositor)
		fmt.panicf("Alicorn backdrop effect compositor encoding failed: %v", result)
	}
	layout := wgpu.TexelCopyBufferLayout{
		bytesPerRow=READBACK_BYTES_PER_ROW,
		rowsPerImage=READBACK_HEIGHT,
		offset=u64(readback_slot)*READBACK_BUFFER_BYTES,
	}
	source := wgpu.TexelCopyTextureInfo{texture=state.backdrop_offscreen_texture, aspect=.All}
	destination := wgpu.TexelCopyBufferInfo{layout=layout, buffer=state.readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(encoder, &source, &destination,
		&wgpu.Extent3D{width=READBACK_WIDTH, height=READBACK_HEIGHT, depthOrArrayLayers=1})
	command := wgpu.CommandEncoderFinish(encoder)
	wgpu.CommandEncoderRelease(encoder)
	if command == nil {
		webgpu_renderer.Compositor_Abort_Submission(&state.backdrop_compositor)
		fmt.panicf("backdrop effect command finish failed")
	}
	wgpu.QueueSubmit(state.queue, {command})
	wgpu.CommandBufferRelease(command)
	serial := webgpu_renderer.Compositor_Commit_Submission(&state.backdrop_compositor, &state.text_runtime)
	if serial == 0 { fmt.panicf("backdrop effect frame did not receive a completion serial") }
	state.backdrop_completion_serial = serial
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

// A real runtime Text_Paint command exercises Alicorn's shaped glyphs, Runa
// atlas residency, shared CPU glyph geometry, WebGPU WGSL sampling, and retained
// cache. It intentionally has a separate readback target while the composed
// renderer API is being assembled; no app-owned text geometry is used here.
build_text_runtime :: proc() {
	state.text_runtime = alicorn.new_runtime(alicorn.Rect{0, 0, f32(READBACK_WIDTH), f32(READBACK_HEIGHT)})
	state.text_runtime_ready = true
	if !alicorn.text_engine_load_font_role(&state.text_runtime.text_engine, .UI, FONT_DATA) {
		fmt.panicf("Alicorn text fixture could not load the bundled UI font")
	}
	alicorn.invalidate_root(&state.text_runtime, "WebGPU text renderer feasibility fixture")
	ui, should_build := alicorn.begin_frame(&state.text_runtime)
	if !should_build { fmt.panicf("Alicorn text fixture runtime did not accept its initial description") }
	alicorn.container_begin(
		&ui, .Root, label="webgpu-text-root",
		style=alicorn.layout_style(.Column, width=f32(READBACK_WIDTH), height=f32(READBACK_HEIGHT), clip=true),
	)
	alicorn.text(
		&ui, "WebGPU text", key=alicorn.key_string("webgpu-text-sample"),
		style=alicorn.layout_style(width=f32(READBACK_WIDTH-2), height=24),
		text_style=alicorn.Text_Style{font_size=18, overflow=.Clip},
		color=alicorn.Color{0.95, 0.88, 0.70, 1},
	)
	// These surfaces exercise the existing CPU material tessellator through
	// the shared solid WGSL path, including semantic gradient resolution.
	probe_material := alicorn.style_material_register(&state.text_runtime, alicorn.Style_Material{
		kind=.Analytic_Relief,
		bevel_width=2,
		bevel_strength=0.8,
		inner_shadow_strength=0.5,
	})
	if probe_material == alicorn.MATERIAL_FLAT { fmt.panicf("Alicorn material fixture could not register analytic relief") }
	accessibility_probe_material := alicorn.style_material_register(&state.text_runtime, alicorn.Style_Material{
		kind=.Analytic_Relief,
		bevel_width=0.5,
		bevel_strength=0.2,
		inner_shadow_strength=0.2,
		outer_shadow_strength=0.4,
		outer_shadow_radius=2,
	})
	if accessibility_probe_material == alicorn.MATERIAL_FLAT {
		fmt.panicf("Alicorn material fixture could not register the accessibility variant source")
	}
	alicorn.container_begin(
		&ui, .Container, label="webgpu-material-probes",
		style=alicorn.layout_style(.Row, width=f32(READBACK_WIDTH), height=18, gap=1),
	)
	state.compositor_material_surface_ids[0] = alicorn.surface_begin(
		&ui, alicorn.surface_core_color_role(.Surface),
		key=alicorn.key_string("webgpu-material-gradient"), label="webgpu-material-gradient",
		style=alicorn.layout_style(width=20, height=18),
		fill=alicorn.Color{0.9, 0.1, 0.1, 1},
		gradient=alicorn.surface_gradient_to(alicorn.surface_core_color_role(.Accent), .Horizontal),
	)
	alicorn.surface_end(&ui)
	state.compositor_material_surface_ids[1] = alicorn.surface_begin(
		&ui, alicorn.surface_core_color_role(.Surface),
		key=alicorn.key_string("webgpu-material-raised"), label="webgpu-material-raised",
		style=alicorn.layout_style(width=14, height=18),
		material=probe_material, physical_height=1,
		fill=alicorn.Color{0.4, 0.4, 0.4, 1},
	)
	alicorn.surface_end(&ui)
	state.compositor_material_surface_ids[2] = alicorn.surface_begin(
		&ui, alicorn.surface_core_color_role(.Surface),
		key=alicorn.key_string("webgpu-material-recessed"), label="webgpu-material-recessed",
		style=alicorn.layout_style(width=13, height=18),
		material=probe_material, physical_height=-1,
		fill=alicorn.Color{0.4, 0.4, 0.4, 1},
	)
	alicorn.surface_end(&ui)
	accessibility_scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{
		accessibility=alicorn.Accessibility_Appearance_Preferences{
			increased_contrast=true,
			reduce_transparency=true,
		},
		accessibility_set=true,
	})
	state.compositor_material_surface_ids[3] = alicorn.surface_begin(
		&ui, alicorn.surface_core_color_role(.Surface),
		key=alicorn.key_string("webgpu-material-accessibility-rounded"), label="webgpu-material-accessibility-rounded",
		style=alicorn.layout_style(width=13, height=18),
		shape=alicorn.surface_shape_rounded_corners(alicorn.Surface_Corner_Radii{5, 1, 5, 1}),
		material=accessibility_probe_material, physical_height=1,
		fill=alicorn.Color{0.4, 0.4, 0.4, 1},
	)
	alicorn.surface_end(&ui)
	alicorn.style_environment_pop(&ui, accessibility_scope)
	alicorn.container_end(&ui)
	alicorn.container_begin(
		&ui, .Container, label="webgpu-custom-surface-probes",
		style=alicorn.layout_style(.Row, width=f32(READBACK_WIDTH), height=18, gap=1),
	)
	state.compositor_custom_surface_ids[0] = alicorn.gpu_geometry_surface(
		&ui, "webgpu-custom-geometry", alicorn.layout_style(width=20, height=18),
	)
	state.compositor_custom_surface_ids[1] = alicorn.gpu_surface(
		&ui, "webgpu-custom-waveform", alicorn.Rect{0, 0, 18, 18}, 18, 18, 1,
	)
	alicorn.container_end(&ui)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	for index in 0..<len(state.compositor_material_surface_ids) {
		surface_id := state.compositor_material_surface_ids[index]
		node, found := state.text_runtime.nodes[surface_id]
		if !found || node == nil || surface_id == 0 {
			fmt.panicf("Alicorn material fixture surface %d was not retained", index)
		}
		state.compositor_material_surface_bounds[index] = node.bounds
	}
	accessibility_surface := state.text_runtime.semantic_surfaces[state.compositor_material_surface_ids[3]]
	resolved_accessibility_material, accessibility_material_ok := alicorn.style_material_resolve(
		&state.text_runtime, accessibility_surface.material,
	)
	state.material_accessibility_variant_passed = accessibility_material_ok &&
		resolved_accessibility_material.bevel_width >= 1.5 &&
		resolved_accessibility_material.bevel_strength >= 0.75 &&
		resolved_accessibility_material.outer_shadow_strength == 0
	if !state.material_accessibility_variant_passed {
		fmt.panicf("increased contrast/reduced transparency did not resolve the expected rounded material variant: %v", resolved_accessibility_material)
	}
	geometry_rectangles := [1]alicorn.GPU_Surface_Filled_Rectangle{{
		bounds={9, 10, 4, 5}, color={1, 0.1, 0.05, 1},
	}}
	geometry_segments := [1]alicorn.GPU_Surface_Line_Segment{{
		start={8, 3}, end={14, 3}, thickness=2, color={0.1, 0.9, 0.2, 1},
	}}
	geometry_circles := [1]alicorn.GPU_Surface_Filled_Circle{{
		center={15, 5}, radius=3, color={0.1, 0.2, 0.95, 1},
	}}
	geometry_markers := [1]alicorn.GPU_Surface_Point_Marker{{
		center={19, 13}, diameter=6, color={0.95, 0.65, 0.1, 1},
	}}
	if !alicorn.gpu_surface_update_geometry_with_rectangles_and_markers(
		&state.text_runtime, state.compositor_custom_surface_ids[0],
		geometry_rectangles[:], geometry_segments[:], geometry_circles[:], geometry_markers[:],
	) { fmt.panicf("Alicorn custom geometry fixture payload was rejected") }
	waveform_samples := [2]f32{0, 1}
	if !alicorn.gpu_surface_update(&state.text_runtime, state.compositor_custom_surface_ids[1], waveform_samples[:]) {
		fmt.panicf("Alicorn waveform fixture payload was rejected")
	}
	display, display_ok := alicorn.paint_display_list(&state.text_runtime)
	if !display_ok || len(display.commands) == 0 {
		fmt.panicf("Alicorn text fixture expected retained text paint commands")
	}
}

controlled_text_readback_describe :: proc() -> alicorn.Node_ID {
	fixture := &state.controlled_text_readback
	ui, should_build := alicorn.begin_frame(&fixture.runtime)
	if !should_build { fmt.panicf("controlled WebGPU text fixture did not accept its description") }
	alicorn.container_begin(
		&ui, .Root, label="controlled-webgpu-text-root",
		key=alicorn.key_string("controlled-webgpu-text-root"),
		style=alicorn.layout_style(.Column, width=50, height=48, clip=true),
	)
	field := alicorn.text_field_controlled(
		&ui, &fixture.query,
		key=alicorn.key_string("controlled-webgpu-text-field"),
		style=alicorn.layout_style(.Row, width=50, height=32),
		text_style=alicorn.Text_Style{font_size=14, overflow=.Clip},
	)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return field.node
}

// This is an end-to-end regression for the retained controlled-field path:
// start empty, commit text through Runtime input, let the public controlled
// API adopt it on the next description, then render its real text paint to
// WebGPU at 1.25x for asynchronous pixel readback.
build_controlled_text_readback :: proc() {
	fixture := &state.controlled_text_readback
	fixture.runtime = alicorn.new_runtime(alicorn.Rect{0, 0, 50, 48})
	fixture.runtime_ready = true
	if !alicorn.text_engine_load_font_role(&fixture.runtime.text_engine, .UI, FONT_DATA) {
		fmt.panicf("controlled WebGPU text fixture could not load the bundled UI font")
	}
	query, query_ok := alicorn.text_field_buffer_init("", context.allocator)
	if !query_ok { fmt.panicf("controlled WebGPU text fixture could not initialize its query buffer") }
	fixture.query = query
	renderer, renderer_ok := webgpu_renderer.Text_Create(state.device, state.queue, .RGBA8Unorm)
	if !renderer_ok { fmt.panicf("controlled WebGPU text renderer initialization failed") }
	fixture.renderer = renderer
	alicorn.invalidate_root(&fixture.runtime, "controlled WebGPU query field initial description")
	fixture.field = controlled_text_readback_describe()
	if fixture.field == 0 { fmt.panicf("controlled WebGPU text fixture did not retain its field") }
	if !alicorn.focus(&fixture.runtime, fixture.field) {
		fmt.panicf("controlled WebGPU text fixture could not focus its field")
	}
	change := alicorn.process_text_input(&fixture.runtime, fixture.field, "browse")
	alicorn.text_change_destroy(&fixture.runtime, &change)
	alicorn.invalidate_root(&fixture.runtime, "controlled WebGPU query committed input")
	updated_field := controlled_text_readback_describe()
	value, value_ok := alicorn.text_field_value(&fixture.runtime, updated_field)
	retained, retained_ok := fixture.runtime.nodes[updated_field]
	if updated_field != fixture.field || !value_ok || value != "browse" || fixture.query.text != value ||
	   !retained_ok || !retained.text_run_valid || retained.text_run.value != value {
		fmt.panicf("controlled WebGPU committed text did not reach a current retained glyph run")
	}
	fixture.texture = wgpu.DeviceCreateTexture(state.device, &wgpu.TextureDescriptor{
		label="controlled text field 1.25x RGBA8 readback target",
		usage={.RenderAttachment, .CopySrc}, dimension=._2D,
		size={width=READBACK_WIDTH, height=READBACK_HEIGHT, depthOrArrayLayers=1},
		format=.RGBA8Unorm, mipLevelCount=1, sampleCount=1,
	})
	fixture.view = wgpu.TextureCreateView(fixture.texture)
	if fixture.texture == nil || fixture.view == nil {
		fmt.panicf("controlled WebGPU text field readback target creation failed")
	}
}

controlled_text_readback_encode :: proc(encoder: wgpu.CommandEncoder) {
	fixture := &state.controlled_text_readback
	display, display_ok := alicorn.paint_display_list(&fixture.runtime)
	if !display_ok { fmt.panicf("controlled WebGPU query display list is unavailable") }
	if result := webgpu_renderer.Text_Prepare(
		&fixture.renderer, &fixture.runtime, display,
		READBACK_WIDTH, READBACK_HEIGHT, 1.25, 1.25,
	); result != .Ok {
		fmt.panicf("controlled WebGPU query text preparation failed: %v", result)
	}
	attachment := wgpu.RenderPassColorAttachment{
		view=fixture.view, depthSlice=wgpu.DEPTH_SLICE_UNDEFINED,
		loadOp=.Clear, storeOp=.Store, clearValue={0.04, 0.08, 0.12, 1},
	}
	pass := wgpu.CommandEncoderBeginRenderPass(encoder, &wgpu.RenderPassDescriptor{
		colorAttachmentCount=1, colorAttachments=&attachment,
	})
	if pass == nil { fmt.panicf("controlled WebGPU query text pass is unavailable") }
	for command, command_index in display.commands {
		if result := webgpu_renderer.Text_Draw_Command(
			&fixture.renderer, pass, command_index, command,
			READBACK_WIDTH, READBACK_HEIGHT, 1.25, 1.25,
		); result != .Ok {
			fmt.panicf("controlled WebGPU query text command encoding failed: %v", result)
		}
	}
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
}

build_surface_runtime :: proc() {
	state.surface_runtime = alicorn.new_runtime(alicorn.Rect{
		0, 0, f32(SURFACE_PRESENTER_LOGICAL_WIDTH), f32(SURFACE_PRESENTER_LOGICAL_HEIGHT),
	})
	state.surface_runtime_ready = true
	if !alicorn.text_engine_load_font_role(&state.surface_runtime.text_engine, .UI, FONT_DATA) {
		fmt.panicf("Alicorn shared surface fixture could not load the bundled UI font")
	}
	if status := alicorn.motion_clock_set_time(&state.surface_runtime, alicorn.Motion_Time(0)); status != .Ok {
		fmt.panicf("Alicorn shared surface fixture could not initialize retained motion time: %v", status)
	}
	image_pixels := make([]u8, 16*16*4, context.allocator)
	for y in 0..<16 {
		for x in 0..<16 {
			offset := (y*16+x)*4
			if (x/4+y/4)%2 == 0 {
				image_pixels[offset+0], image_pixels[offset+1], image_pixels[offset+2], image_pixels[offset+3] = 238, 155, 81, 255
			} else {
				image_pixels[offset+0], image_pixels[offset+1], image_pixels[offset+2], image_pixels[offset+3] = 73, 168, 174, 255
			}
		}
	}
	decoded := alicorn.Image_Decoded{width=16, height=16, rgba8=image_pixels, allocator=context.allocator}
	image, image_error := alicorn.image_adopt_decoded(&state.surface_runtime, &decoded)
	if image_error != .None || len(decoded.rgba8) != 0 {
		fmt.panicf("Alicorn shared surface fixture could not adopt its retained image: %v", image_error)
	}
	state.surface_runtime_image = image
	alicorn.invalidate_root(&state.surface_runtime, "WebGPU shared retained surface fixture")
	when FEASIBILITY_TEST_SURFACE_PRESENTER || FEASIBILITY_TEST_WEB_CANVAS_PRESENTER {
		output, output_status := alicorn.presentation_output_register(&state.surface_runtime)
		if output_status != .Ok { fmt.panicf("WebGPU surface output registration failed: %v", output_status) }
		state.surface_output = output
		state.surface_output_registered = true
	}
	ui, should_build := alicorn.begin_frame(&state.surface_runtime)
	if !should_build { fmt.panicf("SDL WebGPU surface Runtime rejected its initial description") }
	state.surface_runtime_root = alicorn.container_begin(
		&ui, .Root, label="webgpu-surface-root",
		style=alicorn.layout_style(.Column,
			width=f32(SURFACE_PRESENTER_LOGICAL_WIDTH),
			height=f32(SURFACE_PRESENTER_LOGICAL_HEIGHT),
			padding=32, gap=12, clip=true),
	)
	when FEASIBILITY_TEST_SURFACE_PRESENTER || FEASIBILITY_TEST_WEB_CANVAS_PRESENTER {
		if status := alicorn.presentation_output_bind_root(
			&state.surface_runtime, state.surface_output, state.surface_runtime_root,
		); status != .Ok {
			fmt.panicf("WebGPU surface output root binding failed: %v", status)
		}
	}
	card := alicorn.surface_begin(
		&ui, alicorn.surface_core_color_role(.Surface),
		key=alicorn.key_string("webgpu-surface-panel"),
		style=alicorn.layout_style(.Row, width=896, height=208, padding=20, gap=18, align=.Center, clip=true),
		shape=alicorn.surface_shape_rounded_corners(alicorn.Surface_Corner_Radii{18, 18, 18, 18}),
		fill=alicorn.Color{0.10, 0.14, 0.19, 1},
		label="Shared retained renderer fixture",
	)
	if card == 0 { fmt.panicf("shared WebGPU surface card was not retained") }
	target := alicorn.Motion_Target{
		translation=alicorn.Motion_Vector2{0, 0},
		clip_policy=.Follow_Visual, has_translation=true,
	}
	if status := alicorn.motion_intent_queue(
		&state.surface_runtime, card, target, .Reveal, alicorn.Motion_Vector2{0, 18},
	); status != .Ok {
		fmt.panicf("shared WebGPU surface reveal declaration failed: %v", status)
	}
	alicorn.image(
		&ui, state.surface_runtime_image, "Retained checker image",
		key=alicorn.key_string("webgpu-surface-image"),
		style=alicorn.layout_style(width=68, height=68),
	)
	alicorn.container_begin(
		&ui, .Container, label="webgpu-surface-copy",
		style=alicorn.layout_style(.Column, width=420, height=112, gap=10),
	)
	alicorn.container_begin(
		&ui, .Container, label="webgpu-surface-heading-row",
		style=alicorn.layout_style(.Row, width=420, height=38, gap=10, align=.Center),
	)
	alicorn.surface_begin(
		&ui, alicorn.surface_core_color_role(.Surface),
		key=alicorn.key_string("webgpu-surface-alpha-swatch"),
		style=alicorn.layout_style(width=18, height=18),
		shape=alicorn.surface_shape_rounded_corners(alicorn.Surface_Corner_Radii{6, 6, 6, 6}),
		fill=alicorn.Color{0.94, 0.48, 0.18, 0.72},
	)
	alicorn.surface_end(&ui)
	alicorn.text(
		&ui, "One retained renderer, both hosts",
		key=alicorn.key_string("webgpu-surface-title"),
		style=alicorn.layout_style(width=392, height=38, padding=2),
		text_style=alicorn.Text_Style{font_size=24, overflow=.Clip},
		color=alicorn.Color{0.94, 0.91, 0.82, 1},
	)
	alicorn.container_end(&ui)
	alicorn.text(
		&ui, "Runa text, rounded clipping, alpha blending, an adopted image, and resident waveform geometry.",
		key=alicorn.key_string("webgpu-surface-description"),
		style=alicorn.layout_style(width=420, height=58, padding=2),
		text_style=alicorn.Text_Style{font_size=16, overflow=.Wrap},
		color=alicorn.Color{0.72, 0.78, 0.81, 1},
	)
	alicorn.container_end(&ui)
	alicorn.surface_begin(
		&ui, alicorn.surface_core_color_role(.Surface),
		key=alicorn.key_string("webgpu-surface-waveform-tray"),
		style=alicorn.layout_style(width=280, height=116, padding=10, clip=true),
		shape=alicorn.surface_shape_rounded_corners(alicorn.Surface_Corner_Radii{10, 10, 10, 10}),
		fill=alicorn.Color{0.055, 0.075, 0.10, 1},
	)
	state.surface_runtime_waveform = alicorn.gpu_surface(
		&ui, "retained-waveform", alicorn.Rect{0, 0, 260, 96}, 260, 96, 1,
	)
	alicorn.surface_end(&ui)
	alicorn.surface_end(&ui)
	alicorn.text(
		&ui, "The host owns the surface and frame schedule. Alicorn owns retained paint and renderer composition.",
		key=alicorn.key_string("webgpu-surface-footer"),
		style=alicorn.layout_style(width=896, height=36),
		text_style=alicorn.Text_Style{font_size=18, overflow=.Clip},
		color=alicorn.Color{0.16, 0.20, 0.27, 1},
	)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	if state.surface_runtime_waveform == 0 { fmt.panicf("shared retained waveform surface was not declared") }
	waveform_samples: [96]f32
	for index in 0..<len(waveform_samples) {
		peak := (index*29+11)%83
		waveform_samples[index] = 0.12 + f32(peak)/100.0
	}
	if !alicorn.gpu_surface_update(&state.surface_runtime, state.surface_runtime_waveform, waveform_samples[:]) {
		fmt.panicf("shared retained waveform payload was rejected")
	}
	state.surface_motion_active = true
	state.surface_motion_settled = false
	state.surface_motion_elapsed_ns = 0
	state.dirty = true
	display, display_ok := alicorn.paint_display_list(&state.surface_runtime)
	if !display_ok || len(display.commands) == 0 {
		fmt.panicf("shared WebGPU surface Runtime did not publish its first retained display revision")
	}
	when FEASIBILITY_TEST_SURFACE_PRESENTER || FEASIBILITY_TEST_WEB_CANVAS_PRESENTER {
		snapshot, snapshot_status := alicorn.presentation_output_snapshot(&state.surface_runtime, state.surface_output)
		output_display, output_display_status := alicorn.paint_display_list_for_output(&state.surface_runtime, state.surface_output)
		if snapshot_status != .Ok || output_display_status != .Ok || !snapshot.pending ||
		   snapshot.root != state.surface_runtime_root || snapshot.revision != display.revision ||
		   output_display.revision != snapshot.revision || output_display.output != state.surface_output {
			fmt.panicf("WebGPU surface Runtime output was not published with its scoped first display revision")
		}
	}
}

surface_runtime_motion_tick :: proc(dt: f32) -> bool {
	if !state.surface_runtime_ready || !state.surface_motion_active { return false }
	bounded_dt := dt
	if bounded_dt < 0 { bounded_dt = 0 }
	if bounded_dt > 0.05 { bounded_dt = 0.05 }
	state.surface_motion_elapsed_ns += i64(f64(bounded_dt)*1_000_000_000)
	result := alicorn.motion_tick(&state.surface_runtime, alicorn.Motion_Time(state.surface_motion_elapsed_ns))
	if result.status != .Ok { fmt.panicf("shared surface retained motion tick failed: %v", result.status) }
	if result.changed_owners > 0 {
		ui, ready := alicorn.begin_presentation_frame(&state.surface_runtime)
		if !ready { fmt.panicf("shared surface retained motion could not open its presentation-only frame") }
		alicorn.end_presentation_frame(&ui)
		state.dirty = true
	}
	if result.active_properties == 0 {
		state.surface_motion_active = false
		state.surface_motion_settled = true
		fmt.println("[webgpu-feasibility] shared Runtime reveal settled; motion scheduler is idle")
	}
	return state.surface_motion_active
}

build_compositor_images :: proc() {
	// A solid opaque red image and a half-alpha blue image make source-over
	// ordering, alpha interpretation, clipping, and texture switching visible
	// in the shared compositor readback.
	red_pixels := make([]u8, 4*4*4, context.allocator)
	for i := 0; i < len(red_pixels); i += 4 {
		red_pixels[i+0], red_pixels[i+1], red_pixels[i+2], red_pixels[i+3] = 255, 0, 0, 255
	}
	red_decoded := alicorn.Image_Decoded{width=4, height=4, rgba8=red_pixels, allocator=context.allocator}
	red_handle, red_error := alicorn.image_adopt_decoded(&state.text_runtime, &red_decoded)
	if red_error != .None || len(red_decoded.rgba8) != 0 { fmt.panicf("could not adopt red compositor image: %v", red_error) }
	blue_pixels := make([]u8, 4*4*4, context.allocator)
	for i := 0; i < len(blue_pixels); i += 4 {
		blue_pixels[i+0], blue_pixels[i+1], blue_pixels[i+2], blue_pixels[i+3] = 0, 0, 255, 128
	}
	blue_decoded := alicorn.Image_Decoded{width=4, height=4, rgba8=blue_pixels, allocator=context.allocator}
	blue_handle, blue_error := alicorn.image_adopt_decoded(&state.text_runtime, &blue_decoded)
	if blue_error != .None || len(blue_decoded.rgba8) != 0 { fmt.panicf("could not adopt blue compositor image: %v", blue_error) }
	state.compositor_image_a, state.compositor_image_b = red_handle, blue_handle
}

fixture_custom_geometry_command :: proc(
	display: alicorn.Paint_Display_List_View,
	owner: alicorn.Node_ID,
	bounds, clip: alicorn.Rect,
) -> (command: alicorn.Paint_Command, found: bool) {
	for candidate in display.commands {
		if candidate.owner != owner || !alicorn.paint_command_is_geometry(candidate) { continue }
		command = candidate
		command.bounds, command.clip = bounds, clip
		return command, true
	}
	return
}

surface_cache_pressure_build_commands :: proc(first_width: int) -> (
	commands: [dynamic]alicorn.Paint_Command,
	revision: u64,
	ok: bool,
) {
	context = state.ctx
	base_display, display_ok := alicorn.paint_display_list(&state.text_runtime)
	if !display_ok { return }
	base_command, command_found := fixture_custom_geometry_command(
		base_display, state.compositor_custom_surface_ids[1],
		{0, 0, f32(first_width), f32(SURFACE_CACHE_PRESSURE_HEIGHT)}, {0, 0, 1, 1},
	)
	if !command_found { return }
	commands = make([dynamic]alicorn.Paint_Command, 0, SURFACE_CACHE_PRESSURE_BATCH_COUNT, allocator=context.allocator)
	defer if !ok { delete(commands) }
	for index in 0..<SURFACE_CACHE_PRESSURE_BATCH_COUNT {
		command := base_command
		command.bounds = {0, 0, f32(first_width+index), f32(SURFACE_CACHE_PRESSURE_HEIGHT)}
		command.clip = {0, 0, 1, 1}
		command.translation = {}
		command.opacity = 1
		append(&commands, command)
	}
	revision = base_display.revision
	ok = true
	return
}

surface_cache_pressure_submit_batch :: proc(first_width: int, expected_serial: u64) -> bool {
	commands, revision, commands_ok := surface_cache_pressure_build_commands(first_width)
	if !commands_ok { return false }
	defer delete(commands)
	display := alicorn.Paint_Display_List_View{commands=commands[:], revision=revision}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.printf("[webgpu-feasibility] cache pressure batch prepare failed first_width=%d result=%v\n", first_width, result)
		return false
	}
	encoder := wgpu.DeviceCreateCommandEncoder(state.device)
	if encoder == nil { return false }
	defer wgpu.CommandEncoderRelease(encoder)
	if result := webgpu_renderer.Compositor_Encode(
		&state.compositor, &state.text_runtime, display, state.composite_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
	); result != .Ok {
		fmt.printf("[webgpu-feasibility] cache pressure batch encode failed first_width=%d result=%v\n", first_width, result)
		return false
	}
	command_buffer := wgpu.CommandEncoderFinish(encoder)
	if command_buffer == nil { return false }
	wgpu.QueueSubmit(state.queue, {command_buffer})
	wgpu.CommandBufferRelease(command_buffer)
	serial := webgpu_renderer.Compositor_Commit_Submission(&state.compositor, &state.text_runtime)
	fmt.printf("[webgpu-feasibility] cache pressure batch submitted first_width=%d count=%d serial=%d\n",
		first_width, SURFACE_CACHE_PRESSURE_BATCH_COUNT, serial)
	return serial == expected_serial
}

start_surface_cache_pressure_test :: proc() {
	context = state.ctx
	waveform_samples: [alicorn.GPU_SURFACE_MAX_WAVEFORM_SAMPLES]f32
	for index in 0..<len(waveform_samples) {
		waveform_samples[index] = 0.15 if index%2 == 0 else 0.95
	}
	if !alicorn.gpu_surface_update(
		&state.text_runtime, state.compositor_custom_surface_ids[1], waveform_samples[:],
	) {
		fmt.println("[webgpu-feasibility] cache pressure waveform update FAIL")
		state.quit = true
		return
	}
	if !surface_cache_pressure_submit_batch(SURFACE_CACHE_PRESSURE_FIRST_WIDTH, 3) {
		fmt.println("[webgpu-feasibility] cache pressure first batch submit FAIL")
		state.quit = true
		return
	}
	state.surface_cache_pressure_serial = 3
	state.compositor_completion_serial = 3
	state.surface_cache_pressure_evictions_before_probe = state.compositor.surfaces.resource_eviction_count
	probe_commands, revision, commands_ok := surface_cache_pressure_build_commands(SURFACE_CACHE_PRESSURE_SECOND_WIDTH)
	probe_result := webgpu_renderer.Compositor_Result.Resource_Failure
	if commands_ok {
		probe_display := alicorn.Paint_Display_List_View{commands=probe_commands[:], revision=revision}
		probe_result = webgpu_renderer.Compositor_Prepare(
			&state.compositor, &state.text_runtime, probe_display, READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
		)
		delete(probe_commands)
	}
	first_batch_count := surface_cache_pressure_resource_count(
		SURFACE_CACHE_PRESSURE_FIRST_WIDTH, SURFACE_CACHE_PRESSURE_BATCH_COUNT,
	)
	first_batch_serials_valid := surface_cache_pressure_resources_have_serial(
		SURFACE_CACHE_PRESSURE_FIRST_WIDTH, SURFACE_CACHE_PRESSURE_BATCH_COUNT, state.surface_cache_pressure_serial,
	)
	partial_second_batch_count := surface_cache_pressure_resource_count(
		SURFACE_CACHE_PRESSURE_SECOND_WIDTH, SURFACE_CACHE_PRESSURE_BATCH_COUNT,
	)
	state.surface_cache_pressure_inflight_passed = commands_ok &&
		probe_result == .Resource_Failure && partial_second_batch_count > 0 &&
		partial_second_batch_count < SURFACE_CACHE_PRESSURE_BATCH_COUNT &&
		first_batch_count == SURFACE_CACHE_PRESSURE_BATCH_COUNT && first_batch_serials_valid &&
		state.compositor.surfaces.resource_eviction_count == state.surface_cache_pressure_evictions_before_probe &&
		state.compositor.surfaces.resident_bytes <= webgpu_renderer.SURFACE_GPU_CACHE_BUDGET_BYTES
	fmt.printf("[webgpu-feasibility] cache pressure in-flight protection %s result=%v first_batch_resources=%d first_batch_serials=%v partial_second_resources=%d evictions_before=%d evictions_after=%d resident_bytes=%d budget_bytes=%d\n",
		"PASS" if state.surface_cache_pressure_inflight_passed else "FAIL", probe_result,
		first_batch_count, first_batch_serials_valid, partial_second_batch_count,
		state.surface_cache_pressure_evictions_before_probe, state.compositor.surfaces.resource_eviction_count,
		state.compositor.surfaces.resident_bytes, webgpu_renderer.SURFACE_GPU_CACHE_BUDGET_BYTES)
	state.queue_work_done = false
	state.queue_work_done_ok = false
	state.queue_work_done_pending = true
	wgpu.QueueOnSubmittedWorkDone(state.queue, {mode=.AllowProcessEvents, callback=on_surface_cache_pressure_batch_a})
}

surface_cache_pressure_resource_count :: proc(first_width, count: int) -> int {
	handle, handle_ok := surface_cache_pressure_geometry_handle()
	if !handle_ok { return 0 }
	first := f32(first_width)
	last := f32(first_width+count)
	matched := 0
	for resource in state.compositor.surfaces.resources {
		if resource.runtime == &state.text_runtime && resource.handle.resource == handle.resource &&
		   resource.handle.generation == handle.generation && resource.mesh_height == f32(SURFACE_CACHE_PRESSURE_HEIGHT) &&
		   resource.mesh_width >= first && resource.mesh_width < last {
			matched += 1
		}
	}
	return matched
}

surface_cache_pressure_resource_present :: proc(width: int) -> bool {
	handle, handle_ok := surface_cache_pressure_geometry_handle()
	if !handle_ok { return false }
	for resource in state.compositor.surfaces.resources {
		if resource.runtime == &state.text_runtime && resource.handle.resource == handle.resource &&
		   resource.handle.generation == handle.generation && resource.mesh_width == f32(width) &&
		   resource.mesh_height == f32(SURFACE_CACHE_PRESSURE_HEIGHT) {
			return true
		}
	}
	return false
}

surface_cache_pressure_resources_have_serial :: proc(first_width, count: int, serial: u64) -> bool {
	handle, handle_ok := surface_cache_pressure_geometry_handle()
	if !handle_ok { return false }
	first := f32(first_width)
	last := f32(first_width+count)
	matched := 0
	for resource in state.compositor.surfaces.resources {
		if resource.runtime != &state.text_runtime || resource.handle.resource != handle.resource ||
		   resource.handle.generation != handle.generation || resource.mesh_height != f32(SURFACE_CACHE_PRESSURE_HEIGHT) ||
		   resource.mesh_width < first || resource.mesh_width >= last {
			continue
		}
		if resource.last_use_serial != serial { return false }
		matched += 1
	}
	return matched == count
}

surface_cache_pressure_geometry_handle :: proc() -> (handle: alicorn.Geometry_Handle, ok: bool) {
	context = state.ctx
	display, display_ok := alicorn.paint_display_list(&state.text_runtime)
	if !display_ok { return }
	command, found := fixture_custom_geometry_command(
		display, state.compositor_custom_surface_ids[1],
		{0, 0, 1, f32(SURFACE_CACHE_PRESSURE_HEIGHT)}, {0, 0, 1, 1},
	)
	if !found { return }
	geometry, valid := command.payload.(alicorn.Geometry_Paint)
	if !valid { return }
	return geometry.geometry, true
}

surface_cache_pressure_active_bytes :: proc() -> u64 {
	bytes := state.compositor.surfaces.instance_buffer_bytes
	for resource in state.compositor.surfaces.resources { bytes += resource.byte_size }
	return bytes
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
	context=state.ctx; state.readback_pending=false; state.readback_callback_received=true
	if status!=.Success {
		fmt.printf("[webgpu-feasibility] readback failed: %v %s\n",status,message)
		when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
			if state.queue_work_done { state.quit = true }
		}
		return
	}
	pixels:=wgpu.BufferGetMappedRangeSlice(state.readback_buffer,0,u8,READBACK_TOTAL_BYTES)
	valid_range:=len(pixels)==READBACK_TOTAL_BYTES
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
		solid_motion_parent_pixel := offscreen_pixel(pixels, 2, 2, 15*READBACK_BUFFER_BYTES)
		solid_motion_child_pixel := offscreen_pixel(pixels, 10, 10, 15*READBACK_BUFFER_BYTES)
		solid_motion_clip_pixel := offscreen_pixel(pixels, 30, 30, 15*READBACK_BUFFER_BYTES)
		text_visible := false
		for y in 0..<READBACK_HEIGHT {
			for x in 0..<READBACK_WIDTH {
				pixel := offscreen_pixel(pixels, x, y, 2*READBACK_BUFFER_BYTES)
				if pixel[0] > 100 && pixel[1] > 100 && pixel[2] > 70 { text_visible = true; break }
			}
			if text_visible { break }
		}
		controlled_text_visible_pixels := 0
		controlled_field, controlled_field_ok := alicorn.node_info(
			&state.controlled_text_readback.runtime, state.controlled_text_readback.field,
		)
		if controlled_field_ok {
			x0 := clamp(int((controlled_field.bounds.x+5)*1.25), 0, READBACK_WIDTH)
			y0 := clamp(int((controlled_field.bounds.y+3)*1.25), 0, READBACK_HEIGHT)
			x1 := clamp(int((controlled_field.bounds.x+controlled_field.bounds.w-5)*1.25), x0, READBACK_WIDTH)
			y1 := clamp(int((controlled_field.bounds.y+controlled_field.bounds.h-3)*1.25), y0, READBACK_HEIGHT)
			for y in y0..<y1 {
				for x in x0..<x1 {
					pixel := offscreen_pixel(pixels, x, y, 16*READBACK_BUFFER_BYTES)
					if pixel[0] > 120 && pixel[1] > 120 && pixel[2] > 120 { controlled_text_visible_pixels += 1 }
				}
			}
		}
		controlled_text_readback_ok := controlled_field_ok &&
			state.controlled_text_readback.query.text == "browse" && controlled_text_visible_pixels >= 24
		composite_overlay_pixel := offscreen_pixel(pixels, 2, 2, 3*READBACK_BUFFER_BYTES)
		composite_image_red_pixel := offscreen_pixel(pixels, 3, 52, 3*READBACK_BUFFER_BYTES)
		composite_image_blend_pixel := offscreen_pixel(pixels, 8, 52, 3*READBACK_BUFFER_BYTES)
		composite_image_blue_pixel := offscreen_pixel(pixels, 13, 52, 3*READBACK_BUFFER_BYTES)
		composite_image_clip_pixel := offscreen_pixel(pixels, 17, 52, 3*READBACK_BUFFER_BYTES)
		backdrop_center_pixel := offscreen_pixel(pixels, 30, 32, 7*READBACK_BUFFER_BYTES)
		backdrop_outside_clip_pixel := offscreen_pixel(pixels, 22, 32, 7*READBACK_BUFFER_BYTES)
		backdrop_changed_center_pixel := offscreen_pixel(pixels, 30, 32, 8*READBACK_BUFFER_BYTES)
		backdrop_changed_outside_clip_pixel := offscreen_pixel(pixels, 22, 32, 8*READBACK_BUFFER_BYTES)
		backdrop_resized_center_pixel := offscreen_pixel(pixels, 30, 32, 9*READBACK_BUFFER_BYTES)
		backdrop_resized_outside_clip_pixel := offscreen_pixel(pixels, 22, 32, 9*READBACK_BUFFER_BYTES)
		backdrop_fallback_matches_normal := true
		backdrop_fallback_mismatch_x, backdrop_fallback_mismatch_y := -1, -1
		backdrop_fallback_pixel, backdrop_normal_pixel: [4]u8
		for y in 0..<READBACK_HEIGHT {
			for x in 0..<READBACK_WIDTH {
				fallback_pixel := offscreen_pixel(pixels, x, y, 10*READBACK_BUFFER_BYTES)
				normal_pixel := offscreen_pixel(pixels, x, y, 11*READBACK_BUFFER_BYTES)
				if fallback_pixel != normal_pixel {
					backdrop_fallback_matches_normal = false
					backdrop_fallback_mismatch_x, backdrop_fallback_mismatch_y = x, y
					backdrop_fallback_pixel, backdrop_normal_pixel = fallback_pixel, normal_pixel
					break
				}
			}
			if !backdrop_fallback_matches_normal { break }
		}
		multi_backdrop_diff_pixels := 0
		for y in 20..<44 {
			for x in 28..<40 {
				with_first := offscreen_pixel(pixels, x, y, 12*READBACK_BUFFER_BYTES)
				without_first := offscreen_pixel(pixels, x, y, 13*READBACK_BUFFER_BYTES)
				if with_first != without_first { multi_backdrop_diff_pixels += 1 }
			}
		}
		state.multiple_backdrop_pixel_passed = multi_backdrop_diff_pixels > 0
		when FEASIBILITY_TEST_WEBGPU_PRESENTER {
			state.presenter_pixel_parity_passed = true
			presenter_mismatch_x, presenter_mismatch_y := -1, -1
			compositor_pixel, presenter_pixel: [4]u8
			for y in 0..<READBACK_HEIGHT {
				for x in 0..<READBACK_WIDTH {
					expected := offscreen_pixel(pixels, x, y, 3*READBACK_BUFFER_BYTES)
					actual := offscreen_pixel(pixels, x, y, 14*READBACK_BUFFER_BYTES)
					if expected != actual {
						state.presenter_pixel_parity_passed = false
						presenter_mismatch_x, presenter_mismatch_y = x, y
						compositor_pixel, presenter_pixel = expected, actual
						break
					}
				}
				if !state.presenter_pixel_parity_passed { break }
			}
			fmt.printf("[webgpu-feasibility] host-owned presenter pixel parity %s size=%dx%d mismatch=(%d,%d) compositor=%v presenter=%v\n",
				"PASS" if state.presenter_pixel_parity_passed else "FAIL", READBACK_WIDTH, READBACK_HEIGHT,
				presenter_mismatch_x, presenter_mismatch_y, compositor_pixel, presenter_pixel)
			if !state.presenter_pixel_parity_passed { ok = false }
		}
		cropped_capture_matches := true
		second_cropped_capture_matches := true
		for y in 0..<CAPTURE_HEIGHT {
			for x in 0..<CAPTURE_WIDTH {
				full_pixel := offscreen_pixel(pixels, x+CAPTURE_ORIGIN_X, y+CAPTURE_ORIGIN_Y, 3*READBACK_BUFFER_BYTES)
				capture_pixel := offscreen_pixel(pixels, x, y, 5*READBACK_BUFFER_BYTES)
				if full_pixel != capture_pixel {
					cropped_capture_matches = false
					break
				}
			}
			if !cropped_capture_matches { break }
		}
		for y in 0..<CAPTURE_HEIGHT {
			for x in 0..<CAPTURE_WIDTH {
				full_pixel := offscreen_pixel(pixels, x, y, 3*READBACK_BUFFER_BYTES)
				capture_pixel := offscreen_pixel(pixels, x, y, 6*READBACK_BUFFER_BYTES)
				if full_pixel != capture_pixel {
					second_cropped_capture_matches = false
					break
				}
			}
			if !second_cropped_capture_matches { break }
		}
		custom_geometry_rectangle_pixel := offscreen_pixel(pixels, 33, 56, 3*READBACK_BUFFER_BYTES)
		custom_geometry_segment_pixel := offscreen_pixel(pixels, 33, 47, 3*READBACK_BUFFER_BYTES)
		custom_geometry_circle_pixel := offscreen_pixel(pixels, 37, 49, 3*READBACK_BUFFER_BYTES)
		custom_geometry_marker_pixel := offscreen_pixel(pixels, 40, 57, 3*READBACK_BUFFER_BYTES)
		custom_geometry_clip_pixel := offscreen_pixel(pixels, 43, 57, 3*READBACK_BUFFER_BYTES)
		custom_waveform_pixel := offscreen_pixel(pixels, 60, 46, 3*READBACK_BUFFER_BYTES)
		motion_geometry_moved_pixel := offscreen_pixel(pixels, 36, 56, 4*READBACK_BUFFER_BYTES)
		motion_geometry_origin_pixel := offscreen_pixel(pixels, 33, 56, 4*READBACK_BUFFER_BYTES)
		gradient_bounds := state.compositor_material_surface_bounds[0]
		raised_bounds := state.compositor_material_surface_bounds[1]
		recessed_bounds := state.compositor_material_surface_bounds[2]
		accessibility_bounds := state.compositor_material_surface_bounds[3]
		gradient_y := clamp(int(gradient_bounds.y+gradient_bounds.h*0.5), 0, READBACK_HEIGHT-1)
		gradient_left_x := clamp(int(gradient_bounds.x)+4, 0, READBACK_WIDTH-1)
		gradient_right_x := clamp(int(gradient_bounds.x)+16, 0, READBACK_WIDTH-1)
		raised_center_x := clamp(int(raised_bounds.x+raised_bounds.w*0.5), 0, READBACK_WIDTH-1)
		raised_center_y := clamp(int(raised_bounds.y+raised_bounds.h*0.5), 0, READBACK_HEIGHT-1)
		raised_top_y := clamp(int(raised_bounds.y)+1, 0, READBACK_HEIGHT-1)
		recessed_center_x := clamp(int(recessed_bounds.x+recessed_bounds.w*0.5), 0, READBACK_WIDTH-1)
		recessed_center_y := clamp(int(recessed_bounds.y+recessed_bounds.h*0.5), 0, READBACK_HEIGHT-1)
		recessed_top_y := clamp(int(recessed_bounds.y)+1, 0, READBACK_HEIGHT-1)
		accessibility_center_x := clamp(int(accessibility_bounds.x+accessibility_bounds.w*0.5), 0, READBACK_WIDTH-1)
		accessibility_center_y := clamp(int(accessibility_bounds.y+accessibility_bounds.h*0.5), 0, READBACK_HEIGHT-1)
		// Sample the outer bevel band itself. The next pixel inward overlaps the
		// separately rendered inner-shadow band and can partially cancel it.
		accessibility_top_y := clamp(int(accessibility_bounds.y), 0, READBACK_HEIGHT-1)
		accessibility_corner_x := clamp(int(accessibility_bounds.x), 0, READBACK_WIDTH-1)
		accessibility_corner_y := clamp(int(accessibility_bounds.y), 0, READBACK_HEIGHT-1)
		accessibility_shadow_x := clamp(int(accessibility_bounds.x+accessibility_bounds.w*0.5), 0, READBACK_WIDTH-1)
		accessibility_shadow_y := clamp(int(accessibility_bounds.y)-2, 0, READBACK_HEIGHT-1)
		material_gradient_left_pixel := offscreen_pixel(pixels, gradient_left_x, gradient_y, 3*READBACK_BUFFER_BYTES)
		material_gradient_right_pixel := offscreen_pixel(pixels, gradient_right_x, gradient_y, 3*READBACK_BUFFER_BYTES)
		material_raised_interior_pixel := offscreen_pixel(pixels, raised_center_x, raised_center_y, 3*READBACK_BUFFER_BYTES)
		material_raised_top_pixel := offscreen_pixel(pixels, raised_center_x, raised_top_y, 3*READBACK_BUFFER_BYTES)
		material_recessed_interior_pixel := offscreen_pixel(pixels, recessed_center_x, recessed_center_y, 3*READBACK_BUFFER_BYTES)
		material_recessed_top_pixel := offscreen_pixel(pixels, recessed_center_x, recessed_top_y, 3*READBACK_BUFFER_BYTES)
		material_accessibility_interior_pixel := offscreen_pixel(
			pixels, accessibility_center_x, accessibility_center_y, 3*READBACK_BUFFER_BYTES,
		)
		material_accessibility_bevel_pixel := offscreen_pixel(
			pixels, accessibility_center_x, accessibility_top_y, 3*READBACK_BUFFER_BYTES,
		)
		material_accessibility_corner_pixel := offscreen_pixel(
			pixels, accessibility_corner_x, accessibility_corner_y, 3*READBACK_BUFFER_BYTES,
		)
		material_accessibility_shadow_pixel := offscreen_pixel(
			pixels, accessibility_shadow_x, accessibility_shadow_y, 3*READBACK_BUFFER_BYTES,
		)
		composite_overlay_uniform := true
		// Rounded fills intentionally extend their antialias fringe by 0.75 px;
		// the material row begins at y=24, so y=23 is part of that fringe.
		for y in 0..<23 {
			for x in 0..<READBACK_WIDTH {
				pixel := offscreen_pixel(pixels, x, y, 3*READBACK_BUFFER_BYTES)
				if !offscreen_pixel_near(pixel, [4]u8{204, 26, 26, 255}, 1) {
					composite_overlay_uniform = false
					break
				}
			}
			if !composite_overlay_uniform { break }
		}
		composite_text_visible := false
		for y in 28..<READBACK_HEIGHT {
			for x in 0..<READBACK_WIDTH {
				pixel := offscreen_pixel(pixels, x, y, 3*READBACK_BUFFER_BYTES)
				if pixel[0] > 100 && pixel[1] > 100 && pixel[2] > 70 { composite_text_visible = true; break }
			}
			if composite_text_visible { break }
		}
		composite_icon_visible := false
		composite_icon_clip := true
		for y in 43..<61 {
			for x in 40..<58 {
				pixel := offscreen_pixel(pixels, x, y, 3*READBACK_BUFFER_BYTES)
				is_icon_tint := int(pixel[2]) > int(pixel[0])+40 && int(pixel[2]) > int(pixel[1])+40
				if !is_icon_tint { continue }
				if x >= 45 && x < 57 && y >= 48 && y < 58 {
					composite_icon_visible = true
				} else {
					composite_icon_clip = false
				}
			}
		}
		composite_second_icon_visible := false
		for y in 46..<58 {
			for x in 18..<30 {
				pixel := offscreen_pixel(pixels, x, y, 3*READBACK_BUFFER_BYTES)
				if int(pixel[0]) > int(pixel[1])+35 && int(pixel[0]) > int(pixel[2])+35 {
					composite_second_icon_visible = true
					break
				}
			}
			if composite_second_icon_visible { break }
		}
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
		solid_motion_ok := offscreen_pixel_near(solid_motion_parent_pixel, [4]u8{133, 10, 15, 255}, 2) &&
			offscreen_pixel_near(solid_motion_child_pixel, [4]u8{66, 5, 135, 255}, 3) &&
			offscreen_pixel_near(solid_motion_clip_pixel, [4]u8{133, 10, 15, 255}, 2)
		composite_overlay_ok := offscreen_pixel_near(composite_overlay_pixel, [4]u8{204, 26, 26, 255}, 1) && composite_overlay_uniform
		image_red_ok := offscreen_pixel_near(composite_image_red_pixel, [4]u8{255, 0, 0, 255})
		image_blend_ok := offscreen_pixel_near(composite_image_blend_pixel, [4]u8{127, 0, 128, 255}, 3)
		image_blue_ok := offscreen_pixel_near(composite_image_blue_pixel, [4]u8{10, 15, 151, 255}, 3)
		image_clip_ok := offscreen_pixel_near(composite_image_clip_pixel, [4]u8{20, 31, 46, 255}, 3)
		backdrop_blur_mixed_ok := backdrop_center_pixel[0] > 20 && backdrop_center_pixel[2] > 20 && backdrop_center_pixel[3] == 255
		backdrop_clip_ok := offscreen_pixel_near(backdrop_outside_clip_pixel, [4]u8{255, 0, 0, 255}, 2)
		backdrop_prefix_change_ok := backdrop_changed_center_pixel[0] > 20 && backdrop_changed_center_pixel[1] > 20 && backdrop_changed_center_pixel[3] == 255
		backdrop_changed_clip_ok := offscreen_pixel_near(backdrop_changed_outside_clip_pixel, [4]u8{255, 0, 0, 255}, 2)
		backdrop_resized_pixel_ok := backdrop_resized_center_pixel[0] > 20 && backdrop_resized_center_pixel[1] > 20 &&
			offscreen_pixel_near(backdrop_resized_outside_clip_pixel, [4]u8{255, 0, 0, 255}, 2)
		state.backdrop_effect_pixel_passed = backdrop_blur_mixed_ok && backdrop_clip_ok && backdrop_prefix_change_ok &&
			backdrop_changed_clip_ok && backdrop_resized_pixel_ok
		state.backdrop_fallback_pixel_passed = backdrop_fallback_matches_normal
		fmt.printf("[webgpu-feasibility] multiple backdrop prefix pixels %s differing_inside_later_clip=%d\n",
			"PASS" if state.multiple_backdrop_pixel_passed else "FAIL", multi_backdrop_diff_pixels)
		if backdrop_fallback_matches_normal {
			fmt.println("[webgpu-feasibility] backdrop over-budget fallback PASS every RGBA pixel matches plain paint")
		} else {
			fmt.printf("[webgpu-feasibility] backdrop over-budget fallback FAIL mismatch=(%d,%d) fallback=%v plain=%v\n",
				backdrop_fallback_mismatch_x, backdrop_fallback_mismatch_y, backdrop_fallback_pixel, backdrop_normal_pixel)
		}
		custom_geometry_rectangle_ok := offscreen_pixel_near(custom_geometry_rectangle_pixel, [4]u8{255, 26, 13, 255}, 2)
		custom_geometry_segment_ok := offscreen_pixel_near(custom_geometry_segment_pixel, [4]u8{26, 230, 51, 255}, 2)
		custom_geometry_circle_ok := offscreen_pixel_near(custom_geometry_circle_pixel, [4]u8{26, 51, 242, 255}, 2)
		custom_geometry_marker_ok := offscreen_pixel_near(custom_geometry_marker_pixel, [4]u8{242, 166, 26, 255}, 4)
		custom_geometry_clip_ok := offscreen_pixel_near(custom_geometry_clip_pixel, [4]u8{20, 31, 46, 255}, 3)
		custom_waveform_ok := offscreen_pixel_near(custom_waveform_pixel, [4]u8{77, 224, 245, 255}, 3)
		motion_geometry_ok := offscreen_pixel_near(motion_geometry_moved_pixel, [4]u8{137, 28, 30, 255}, 3) &&
			offscreen_pixel_near(motion_geometry_origin_pixel, [4]u8{20, 31, 46, 255}, 2)
		material_gradient_left_ok := offscreen_pixel_near(material_gradient_left_pixel, [4]u8{193, 47, 60, 255}, 5)
		material_gradient_right_ok := offscreen_pixel_near(material_gradient_right_pixel, [4]u8{97, 105, 152, 255}, 5)
		material_raised_interior_ok := offscreen_pixel_near(material_raised_interior_pixel, [4]u8{102, 102, 102, 255}, 2)
		material_raised_top_ok := offscreen_pixel_near(material_raised_top_pixel, [4]u8{112, 112, 112, 255}, 4)
		material_recessed_interior_ok := offscreen_pixel_near(material_recessed_interior_pixel, [4]u8{102, 102, 102, 255}, 2)
		material_recessed_top_ok := offscreen_pixel_near(material_recessed_top_pixel, [4]u8{96, 96, 96, 255}, 4)
		material_accessibility_interior_ok := offscreen_pixel_near(
			material_accessibility_interior_pixel, [4]u8{102, 102, 102, 255}, 2,
		)
		material_accessibility_bevel_ok := int(material_accessibility_bevel_pixel[0]) > int(material_accessibility_interior_pixel[0])+4
		material_accessibility_corner_ok := offscreen_pixel_near(material_accessibility_corner_pixel, [4]u8{20, 31, 46, 255}, 2)
		material_accessibility_shadow_suppressed := offscreen_pixel_near(material_accessibility_shadow_pixel, [4]u8{204, 26, 26, 255}, 1)
		material_accessibility_ok := state.material_accessibility_variant_passed && material_accessibility_interior_ok &&
			material_accessibility_bevel_ok && material_accessibility_corner_ok && material_accessibility_shadow_suppressed
		material_ok := material_gradient_left_ok && material_gradient_right_ok && material_raised_interior_ok &&
			material_raised_top_ok && material_recessed_interior_ok && material_recessed_top_ok && material_accessibility_ok
		core_readback_ok := clear_ok && solid_ok && checker_ok && patch_ok && partial_buffer_ok && uniform_ok && blend_ok &&
			glyph_ok && clip_ok && outside_clip_ok && rounded_ok && rounded_corner_ok && last_row_ok
		compositor_readback_ok := display_blend_ok && display_clip_x_ok && display_clip_y_ok && text_visible &&
			composite_overlay_ok && composite_text_visible && composite_icon_visible && composite_icon_clip &&
			composite_second_icon_visible && image_red_ok && image_blend_ok && image_blue_ok && image_clip_ok && solid_motion_ok &&
			cropped_capture_matches && second_cropped_capture_matches
		effects_readback_ok := backdrop_blur_mixed_ok && backdrop_clip_ok && backdrop_prefix_change_ok &&
			backdrop_changed_clip_ok && backdrop_resized_pixel_ok && backdrop_fallback_matches_normal &&
			state.multiple_backdrop_pixel_passed && custom_geometry_rectangle_ok && custom_geometry_segment_ok &&
			custom_geometry_circle_ok && custom_geometry_marker_ok && custom_geometry_clip_ok && custom_waveform_ok &&
			motion_geometry_ok && material_ok
		ok=core_readback_ok && compositor_readback_ok && effects_readback_ok && controlled_text_readback_ok
		fmt.printf("[webgpu-feasibility] async RGBA8 readback core %s texture=%dx%d row_pitch=%d padding_per_row=%d bytes=%d clear=%v solid=%v checker=%v partial_texture=%v partial_buffer=%v uniform=%v blend=%v glyph=%v clip=%v outside_clip=%v rounded=%v rounded_corner=%v last_row=%v\n",
			"PASS" if core_readback_ok else "FAIL", READBACK_WIDTH, READBACK_HEIGHT, READBACK_BYTES_PER_ROW,
			READBACK_BYTES_PER_ROW-READBACK_WIDTH*READBACK_BYTES_PER_PIXEL, len(pixels),
			clear_ok, solid_ok, checker_ok, patch_ok, partial_buffer_ok, uniform_ok, blend_ok, glyph_ok,
			clip_ok, outside_clip_ok, rounded_ok, rounded_corner_ok, last_row_ok)
		fmt.printf("[webgpu-feasibility] async RGBA8 readback compositor %s display_blend=%v clip_x=%v clip_y=%v text=%v overlay_order=%v offset_text=%v icon=%v icon_clip=%v atlas_switch=%v image_red=%v image_alpha=%v image_blue=%v image_clip=%v solid_motion=%v crop_a=%v crop_b=%v\n",
			"PASS" if compositor_readback_ok else "FAIL", display_blend_ok, display_clip_x_ok, display_clip_y_ok, text_visible, composite_overlay_ok,
			composite_text_visible, composite_icon_visible, composite_icon_clip, composite_second_icon_visible,
			image_red_ok, image_blend_ok, image_blue_ok, image_clip_ok, solid_motion_ok, cropped_capture_matches,
			second_cropped_capture_matches)
		fmt.printf("[webgpu-feasibility] async RGBA8 readback effects %s backdrop=%v backdrop_clip=%v prefix_reuse=%v prefix_invalidation=%v resized=%v fallback=%v geometry_rect=%v segment=%v circle=%v marker=%v geometry_clip=%v waveform=%v gradient=%v raised=%v raised_bevel=%v recessed=%v recessed_bevel=%v\n",
			"PASS" if effects_readback_ok else "FAIL", backdrop_blur_mixed_ok, backdrop_clip_ok, backdrop_prefix_change_ok, backdrop_changed_clip_ok,
			backdrop_resized_pixel_ok, backdrop_fallback_matches_normal, custom_geometry_rectangle_ok,
			custom_geometry_segment_ok, custom_geometry_circle_ok, custom_geometry_marker_ok,
			custom_geometry_clip_ok, custom_waveform_ok, material_gradient_left_ok && material_gradient_right_ok,
			material_raised_interior_ok, material_raised_top_ok, material_recessed_interior_ok,
			material_recessed_top_ok)
		fmt.printf("[webgpu-feasibility] rounded accessibility-material readback %s variant=%v face=%v bevel=%v corner=%v reduced_transparency_shadow=%v\n",
			"PASS" if material_accessibility_ok else "FAIL", state.material_accessibility_variant_passed,
			material_accessibility_interior_ok, material_accessibility_bevel_ok,
			material_accessibility_corner_ok, material_accessibility_shadow_suppressed)
		fmt.printf("[webgpu-feasibility] controlled text field GPU readback %s query=%s scale=1.25 visible_glyph_pixels=%d\n",
			"PASS" if controlled_text_readback_ok else "FAIL",
			state.controlled_text_readback.query.text, controlled_text_visible_pixels)
		fmt.printf("[webgpu-feasibility] custom geometry translation/opacity pixel %s moved_pixel=%v original_pixel=%v\n",
			"PASS" if motion_geometry_ok else "FAIL", motion_geometry_moved_pixel, motion_geometry_origin_pixel)
	} else {
		fmt.printf("[webgpu-feasibility] async RGBA8 readback FAIL bytes=%d expected=%d\n",len(pixels),READBACK_TOTAL_BYTES)
	}
	wgpu.BufferUnmap(state.readback_buffer); state.readback_done=ok
	when FEASIBILITY_TEST_COMPOSITOR_RECREATION {
		compositor_recreation_maybe_start()
	}
	when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
		if state.queue_work_done && state.surface_cache_pressure_serial >= 4 && smoke_resize_complete() {
			state.quit=true
		}
	}
	when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
		if ok {
			// Defer destroy until the host has returned from this callback. In
			// particular, native wgpuDevicePoll must not be re-entered by destroying
			// the device from one of the callbacks it is currently dispatching.
			state.test_explicit_destroy_pending=true
		}
	}
}

compositor_recreation_maybe_start :: proc() {
	when !FEASIBILITY_TEST_COMPOSITOR_RECREATION { return }
	if state.compositor_recreation_started || !state.readback_done ||
	   !state.queue_work_done || !state.queue_work_done_ok ||
	   !state.image_retirement_passed || !state.surface_resource_retirement_passed ||
	   !state.surface_cache_pressure_passed || !state.surface_cache_pressure_inflight_passed ||
	   !state.backdrop_fallback_pixel_passed || !state.backdrop_resize_retirement_passed ||
	   !state.multiple_backdrop_pixel_passed ||
	   len(state.compositor_recreation_commands) == 0 {
		return
	}
	state.compositor_recreation_started = true
	if state.compositor.encode_pending ||
	   state.compositor.images.submitted_serial != state.compositor.images.completed_serial ||
	   state.compositor.surfaces.submitted_serial != state.compositor.surfaces.completed_serial ||
	   len(state.compositor.images.retired) != 0 || len(state.compositor.surfaces.retired) != 0 {
		fmt.println("[webgpu-feasibility] compositor reconstruction precondition FAIL: old compositor still has in-flight work")
		state.compositor_recreation_queue_done = true
		state.compositor_recreation_queue_ok = false
		state.compositor_recreation_readback_done = true
		state.compositor_recreation_readback_ok = false
		state.quit = true
		return
	}
	if !compositor_recreation_submit_render(false) { compositor_recreation_abort("baseline render submission") }
}

compositor_recreation_submit_render :: proc(after_rebuild: bool) -> bool {
	if after_rebuild {
		fmt.println("[webgpu-feasibility] compositor reconstruction: rebuilding GPU renderer resources from retained CPU display products")
		webgpu_renderer.Compositor_Destroy(&state.compositor)
		compositor, create_ok := webgpu_renderer.Compositor_Create(state.device, state.queue, .RGBA8Unorm)
		if !create_ok { return false }
		state.compositor = compositor
	}
	display := alicorn.Paint_Display_List_View{
		commands=state.compositor_recreation_commands,
		revision=state.compositor_recreation_revision,
	}
	if result := webgpu_renderer.Compositor_Prepare(
		&state.compositor, &state.text_runtime, display,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1,
	); result != .Ok {
		fmt.printf("[webgpu-feasibility] compositor reconstruction prepare FAIL after_rebuild=%v result=%v\n", after_rebuild, result)
		return false
	}
	if after_rebuild {
		state.compositor_recreation_products_rebuilt =
			state.compositor.solid.mesh_rebuild_count > 0 &&
			state.compositor.text.mesh_rebuild_count > 0 &&
			state.compositor.icons.mesh_rebuild_count > 0 &&
			state.compositor.images.mesh_rebuild_count > 0 &&
			state.compositor.images.texture_upload_count > 0 &&
			state.compositor.surfaces.mesh_rebuild_count > 0
		if !state.compositor_recreation_products_rebuilt {
			fmt.println("[webgpu-feasibility] compositor reconstruction CPU-product rebuild FAIL")
			webgpu_renderer.Compositor_Abort_Submission(&state.compositor)
			return false
		}
	}
	if state.compositor_recreation_readback_buffer == nil {
		state.compositor_recreation_readback_buffer = wgpu.DeviceCreateBuffer(state.device, &wgpu.BufferDescriptor{
			label="compositor reconstruction readback staging",
			usage={.CopyDst, .MapRead},
			size=READBACK_BUFFER_BYTES,
		})
		if state.compositor_recreation_readback_buffer == nil {
			fmt.println("[webgpu-feasibility] compositor reconstruction staging allocation FAIL")
			webgpu_renderer.Compositor_Abort_Submission(&state.compositor)
			return false
		}
	}
	encoder := wgpu.DeviceCreateCommandEncoder(state.device)
	if encoder == nil {
		webgpu_renderer.Compositor_Abort_Submission(&state.compositor)
		return false
	}
	if result := webgpu_renderer.Compositor_Encode(
		&state.compositor, &state.text_runtime, display, state.composite_offscreen_view,
		READBACK_WIDTH, READBACK_HEIGHT, 1, 1, encoder, true, wgpu.Color{0.04, 0.08, 0.12, 1},
	); result != .Ok {
		wgpu.CommandEncoderRelease(encoder)
		fmt.printf("[webgpu-feasibility] compositor reconstruction encode FAIL after_rebuild=%v result=%v\n", after_rebuild, result)
		webgpu_renderer.Compositor_Abort_Submission(&state.compositor)
		return false
	}
	layout := wgpu.TexelCopyBufferLayout{
		bytesPerRow=READBACK_BYTES_PER_ROW,
		rowsPerImage=READBACK_HEIGHT,
	}
	source := wgpu.TexelCopyTextureInfo{texture=state.composite_offscreen_texture, aspect=.All}
	destination := wgpu.TexelCopyBufferInfo{layout=layout, buffer=state.compositor_recreation_readback_buffer}
	wgpu.CommandEncoderCopyTextureToBuffer(encoder, &source, &destination,
		&wgpu.Extent3D{width=READBACK_WIDTH, height=READBACK_HEIGHT, depthOrArrayLayers=1})
	command := wgpu.CommandEncoderFinish(encoder)
	wgpu.CommandEncoderRelease(encoder)
	if command == nil {
		webgpu_renderer.Compositor_Abort_Submission(&state.compositor)
		return false
	}
	wgpu.QueueSubmit(state.queue, {command})
	wgpu.CommandBufferRelease(command)
	state.compositor_recreation_serial = webgpu_renderer.Compositor_Commit_Submission(
		&state.compositor, &state.text_runtime,
	)
	if state.compositor_recreation_serial == 0 {
		fmt.println("[webgpu-feasibility] compositor reconstruction submission commit FAIL")
		return false
	}
	state.compositor_recreation_after_rebuild = after_rebuild
	state.compositor_recreation_queue_done = false
	state.compositor_recreation_queue_ok = false
	state.compositor_recreation_readback_done = false
	state.compositor_recreation_readback_ok = false
	state.compositor_recreation_pixels_match = false
	state.queue_work_done_pending = true
	state.compositor_recreation_readback_pending = true
	wgpu.QueueOnSubmittedWorkDone(state.queue, {mode=.AllowProcessEvents, callback=on_compositor_recreation_queue_done})
	wgpu.BufferMapAsync(
		state.compositor_recreation_readback_buffer, {.Read}, 0, READBACK_BUFFER_BYTES,
		{mode=.AllowProcessEvents, callback=on_compositor_recreation_readback},
	)
	return true
}

compositor_recreation_abort :: proc(reason: string) {
	fmt.printf("[webgpu-feasibility] compositor reconstruction FAIL: %s\n", reason)
	state.compositor_recreation_queue_done = true
	state.compositor_recreation_queue_ok = false
	state.compositor_recreation_readback_done = true
	state.compositor_recreation_readback_ok = false
	state.quit = true
}

compositor_recreation_finish_if_ready :: proc() {
	when !FEASIBILITY_TEST_COMPOSITOR_RECREATION { return }
	if !state.compositor_recreation_started || !state.compositor_recreation_queue_done ||
	   !state.compositor_recreation_readback_done { return }
	if !state.compositor_recreation_queue_ok || !state.compositor_recreation_readback_ok {
		compositor_recreation_abort("queue completion or mapped readback failed")
		return
	}
	if !state.compositor_recreation_after_rebuild {
		if !compositor_recreation_submit_render(true) {
			compositor_recreation_abort("recreated compositor render submission")
		}
		return
	}
	state.compositor_recreation_passed = state.compositor_recreation_queue_ok &&
		state.compositor_recreation_pixels_match && state.compositor_recreation_products_rebuilt
	fmt.printf("[webgpu-feasibility] compositor reconstruction %s queue_completed=%v pixel_identical=%v cpu_products_rebuilt=%v\n",
		"PASS" if state.compositor_recreation_passed else "FAIL",
		state.compositor_recreation_queue_ok,
		state.compositor_recreation_pixels_match,
		state.compositor_recreation_products_rebuilt)
	if !state.compositor_recreation_passed || smoke_complete() { state.quit = true }
}

on_compositor_recreation_queue_done :: proc "c" (
	status: wgpu.QueueWorkDoneStatus,
	message: wgpu.StringView,
	userdata1, userdata2: rawptr,
) {
	context = state.ctx
	state.queue_work_done_pending = false
	state.compositor_recreation_queue_done = true
	state.compositor_recreation_queue_ok = status == .Success &&
		webgpu_renderer.Compositor_Complete_Submission(&state.compositor, state.compositor_recreation_serial)
	if !state.compositor_recreation_queue_ok {
		fmt.printf("[webgpu-feasibility] compositor reconstruction queue completion FAIL status=%v message=%s serial=%d\n",
			status, message, state.compositor_recreation_serial)
	}
	compositor_recreation_finish_if_ready()
}

on_compositor_recreation_readback :: proc "c" (
	status: wgpu.MapAsyncStatus,
	message: wgpu.StringView,
	userdata1, userdata2: rawptr,
) {
	context = state.ctx
	state.compositor_recreation_readback_pending = false
	state.compositor_recreation_readback_done = true
	if status != .Success {
		fmt.printf("[webgpu-feasibility] compositor reconstruction map FAIL status=%v message=%s\n", status, message)
		state.compositor_recreation_readback_ok = false
		compositor_recreation_finish_if_ready()
		return
	}
	pixels := wgpu.BufferGetMappedRangeSlice(state.compositor_recreation_readback_buffer, 0, u8, READBACK_BUFFER_BYTES)
	row_bytes := READBACK_WIDTH * READBACK_BYTES_PER_PIXEL
	state.compositor_recreation_readback_ok = len(pixels) == READBACK_BUFFER_BYTES
	if !state.compositor_recreation_after_rebuild && state.compositor_recreation_readback_ok {
		state.compositor_recreation_reference = make([]u8, row_bytes*READBACK_HEIGHT, allocator=context.allocator)
		for y in 0..<READBACK_HEIGHT {
			copy(
				state.compositor_recreation_reference[y*row_bytes:(y+1)*row_bytes],
				pixels[y*READBACK_BYTES_PER_ROW:y*READBACK_BYTES_PER_ROW+row_bytes],
			)
		}
	} else {
		state.compositor_recreation_pixels_match = state.compositor_recreation_readback_ok &&
			len(state.compositor_recreation_reference) == row_bytes*READBACK_HEIGHT
	}
	if state.compositor_recreation_after_rebuild && state.compositor_recreation_pixels_match {
		for y in 0..<READBACK_HEIGHT {
			for x in 0..<row_bytes {
				actual := pixels[y*READBACK_BYTES_PER_ROW+x]
				expected := state.compositor_recreation_reference[y*row_bytes+x]
				if actual != expected {
					state.compositor_recreation_pixels_match = false
					fmt.printf("[webgpu-feasibility] compositor reconstruction pixel mismatch at (%d,%d) channel=%d expected=%d actual=%d\n",
						x/READBACK_BYTES_PER_PIXEL, y, x%READBACK_BYTES_PER_PIXEL, expected, actual)
					break
				}
			}
			if !state.compositor_recreation_pixels_match { break }
		}
	}
	wgpu.BufferUnmap(state.compositor_recreation_readback_buffer)
	compositor_recreation_finish_if_ready()
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

begin_test_explicit_device_destroy :: proc() {
	when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
		if state.test_explicit_destroy_pending && !state.test_explicit_destroy_triggered {
			state.test_explicit_destroy_pending=false
			state.test_explicit_destroy_triggered=true
			state.ready=false
			when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_RELEASE_BEFORE_POLL {
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
			when FEASIBILITY_TEST_WGPU_NATIVE_POST_DESTROY_ERRORS {
				commands := [1]wgpu.CommandBuffer{state.test_post_destroy_command}
				wgpu.QueueSubmit(state.queue, commands[:])
				state.test_post_destroy_queue_returned = true
				wgpu.CommandBufferRelease(state.test_post_destroy_command)
				state.test_post_destroy_command = nil
				fmt.println("[webgpu-feasibility] QueueSubmit returned after explicit device destroy")

				surface_texture := wgpu.SurfaceGetCurrentTexture(state.surface)
				state.test_post_destroy_surface_error = surface_texture.status == .Error
				if surface_texture.texture != nil { wgpu.TextureRelease(surface_texture.texture) }
				fmt.printf("[webgpu-feasibility] SurfaceGetCurrentTexture after destroy status=%v expected=Error\n",
					surface_texture.status)
			}
		}
	}
}
