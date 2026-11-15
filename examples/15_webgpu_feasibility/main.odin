package webgpu_feasibility

import "base:runtime"
import "core:fmt"
import "vendor:wgpu"
import runa "../../third_party/Runa"

ANIMATION_SECONDS :: 1.8
VERTEX_CAPACITY :: 256 * 1024
READBACK_WIDTH :: 63
READBACK_HEIGHT :: 64
READBACK_BYTES_PER_PIXEL :: 4
READBACK_BYTES_PER_ROW :: 256
READBACK_BUFFER_BYTES :: READBACK_BYTES_PER_ROW * READBACK_HEIGHT
FEASIBILITY_TEST_DEVICE_LOSS :: #config(FEASIBILITY_TEST_DEVICE_LOSS, false)
FEASIBILITY_TEST_DEVICE_LOSS_EARLY :: #config(FEASIBILITY_TEST_DEVICE_LOSS_EARLY, false)
FEASIBILITY_TEST_DEVICE_LOSS_SPONTANEOUS :: #config(FEASIBILITY_TEST_DEVICE_LOSS_SPONTANEOUS, false)
FEASIBILITY_TEST_DEVICE_LOSS_RELEASE_BEFORE_POLL :: #config(FEASIBILITY_TEST_DEVICE_LOSS_RELEASE_BEFORE_POLL, false)
FEASIBILITY_TEST_QUIT_AFTER_READBACK :: #config(FEASIBILITY_TEST_QUIT_AFTER_READBACK, false)
FEASIBILITY_TEST_RESIZE :: #config(FEASIBILITY_TEST_RESIZE, false)

Vertex :: struct {
	position: [2]f32,
	uv: [2]f32,
	color: [4]f32,
	kind: u32,
}
Glyph_Quad :: struct { x0, y0, x1, y1: f32, uv: [4]f32 }
Draw_Command :: struct { first, count: u32, scissor: [4]u32 }

state: struct {
	ctx: runtime.Context,
	os: OS,
	instance: wgpu.Instance,
	surface: wgpu.Surface,
	adapter: wgpu.Adapter,
	device: wgpu.Device,
	queue: wgpu.Queue,
	config: wgpu.SurfaceConfiguration,
	pipeline: wgpu.RenderPipeline,
	offscreen_pipeline: wgpu.RenderPipeline,
	pipeline_layout: wgpu.PipelineLayout,
	shader: wgpu.ShaderModule,
	bind_group_layout: wgpu.BindGroupLayout,
	bind_group: wgpu.BindGroup,
	sampler: wgpu.Sampler,
	vertex_buffer: wgpu.Buffer,
	probe_uniform_buffer: wgpu.Buffer,
	vertex_capacity: u64,
	image_texture, glyph_texture: wgpu.Texture,
	image_view, glyph_view: wgpu.TextureView,
	font: runa.Font,
	atlas: runa.Atlas,
	glyph_quads: [dynamic]Glyph_Quad,
	vertices: [dynamic]Vertex,
	draws: [dynamic]Draw_Command,
	offscreen_texture: wgpu.Texture,
	offscreen_view: wgpu.TextureView,
	readback_buffer: wgpu.Buffer,
	readback_pending, readback_done: bool,
	queue_work_done_pending, queue_work_done, queue_work_done_ok: bool,
	test_resize_pre_requested, test_resize_pre_applied, test_resize_pre_frame: bool,
	test_resize_post_requested, test_resize_post_applied, test_resize_post_frame: bool,
	test_resize_post_delay: f32,
	test_resize_pre_present_before, test_resize_post_present_before, surface_present_count: u64,
	width, height: u32,
	animation_seconds: f32,
	ready, dirty, quit, device_lost: bool,
	test_device_loss_pending: bool,
	test_device_loss_triggered: bool,
	native_loss_wait_probed: bool,
}

main :: proc() {
	state.ctx = context
	state.vertices = make([dynamic]Vertex, 0, 4096)
	state.draws = make([dynamic]Draw_Command, 0, 32)
	state.glyph_quads = make([dynamic]Glyph_Quad, 0, 96)
	os_init()
	state.instance = wgpu.CreateInstance(nil)
	if state.instance == nil { fmt.panicf("WebGPU instance creation failed") }
	state.surface = os_get_surface(state.instance)
	if state.surface == nil { fmt.panicf("WebGPU surface creation failed") }
	wgpu.InstanceRequestAdapter(state.instance, &wgpu.RequestAdapterOptions{
		compatibleSurface = state.surface,
		powerPreference = .HighPerformance,
	}, {callback = on_adapter})
	os_run()
	when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
		if !state.readback_done || !state.queue_work_done || !state.queue_work_done_ok {
			os_exit_failure()
		}
		when FEASIBILITY_TEST_RESIZE {
			if !state.test_resize_pre_applied || !state.test_resize_pre_frame ||
				!state.test_resize_post_applied || !state.test_resize_post_frame {
				os_exit_failure()
			}
		}
	}
}

smoke_complete :: proc() -> bool {
	if !state.readback_done || !state.queue_work_done || !state.queue_work_done_ok { return false }
	when FEASIBILITY_TEST_RESIZE {
		if !state.test_resize_pre_applied || !state.test_resize_pre_frame ||
			!state.test_resize_post_applied || !state.test_resize_post_frame { return false }
	}
	return true
}

on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, userdata1, userdata2: rawptr) {
	context = state.ctx
	if status != .Success || adapter == nil { fmt.panicf("adapter request failed: %v %s", status, message) }
	state.adapter = adapter
	adapter_info, info_status := wgpu.AdapterGetInfo(adapter)
	if info_status == .Success {
		fmt.printf("[webgpu-feasibility] adapter info backend=%v type=%v vendor=%s architecture=%s device=%s description=%s\n",
			adapter_info.backendType,
			adapter_info.adapterType,
			adapter_info.vendor,
			adapter_info.architecture,
			adapter_info.device,
			adapter_info.description,
		)
		wgpu.AdapterInfoFreeMembers(adapter_info)
	} else {
		fmt.printf("[webgpu-feasibility] adapter info unavailable status=%v\n",info_status)
	}
	caps, cap_status := wgpu.SurfaceGetCapabilities(state.surface, adapter)
	if cap_status != .Success || caps.formatCount == 0 || caps.alphaModeCount == 0 {
		fmt.panicf("surface capabilities unavailable: %v", cap_status)
	}
	state.config.format = caps.formats[0]
	for i in 0..<int(caps.formatCount) {
		format := caps.formats[i]
		if format == .BGRA8UnormSrgb { state.config.format = format; break }
		if format == .BGRA8Unorm { state.config.format = format }
	}
	state.config.alphaMode = caps.alphaModes[0]
	for i in 0..<int(caps.alphaModeCount) {
		if caps.alphaModes[i] == .Opaque { state.config.alphaMode = .Opaque; break }
	}
	wgpu.SurfaceCapabilitiesFreeMembers(caps)
	loss_callback_mode := wgpu.CallbackMode.AllowProcessEvents
	when FEASIBILITY_TEST_DEVICE_LOSS_SPONTANEOUS {
		loss_callback_mode = .AllowSpontaneos
	}
	device_desc:=wgpu.DeviceDescriptor{
		label="Alicorn WebGPU feasibility device",
		deviceLostCallbackInfo={mode=loss_callback_mode,callback=on_device_lost},
	}
	wgpu.AdapterRequestDevice(adapter, &device_desc, {callback = on_device})
}

on_device_lost :: proc "c" (device:^wgpu.Device, reason:wgpu.DeviceLostReason, message:wgpu.StringView, userdata1,userdata2:rawptr) {
	context=state.ctx
	state.device_lost=true
	state.ready=false
	device_handle_present := device != nil && device^ != nil
	fmt.printf("[webgpu-feasibility] device loss notification reason=%v device_handle_present=%v message=%s\n",reason,device_handle_present,message)
	when FEASIBILITY_TEST_DEVICE_LOSS {
		state.quit = true
	}
}

on_queue_work_done :: proc "c" (status:wgpu.QueueWorkDoneStatus, message:wgpu.StringView, userdata1,userdata2:rawptr) {
	context = state.ctx
	state.queue_work_done_pending = false
	state.queue_work_done = true
	state.queue_work_done_ok = status == .Success
	fmt.printf("[webgpu-feasibility] queue work done status=%v message=%s\n", status, message)
	when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
		if !state.readback_pending && (!FEASIBILITY_TEST_RESIZE || state.test_resize_post_frame) {
			state.quit = true
		}
	}
}

on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, userdata1, userdata2: rawptr) {
	context = state.ctx
	if status != .Success || device == nil { fmt.panicf("device request failed: %v %s", status, message) }
	state.device = device
	state.queue = wgpu.DeviceGetQueue(device)
	when FEASIBILITY_TEST_DEVICE_LOSS_EARLY {
		fmt.println("[webgpu-feasibility] early device-destroy probe: no GPU resources or submissions")
		state.test_device_loss_pending=true
		return
	}
	create_resources()
	state.width, state.height = os_get_framebuffer_size()
	os_set_surface_size(state.width, state.height)
	state.config.device = device
	state.config.usage = {.RenderAttachment}
	state.config.width, state.config.height = max(state.width, 1), max(state.height, 1)
	state.config.presentMode = .Fifo
	wgpu.SurfaceConfigure(state.surface, &state.config)
	state.ready, state.dirty = true, true
	start_offscreen_readback()
}

resize :: proc() {
	if !state.ready || state.surface == nil || state.device == nil { return }
	state.width, state.height = os_get_framebuffer_size()
	os_set_surface_size(state.width, state.height)
	state.config.width, state.config.height = max(state.width, 1), max(state.height, 1)
	wgpu.SurfaceConfigure(state.surface, &state.config)
	state.dirty = true
	when FEASIBILITY_TEST_RESIZE {
		if !state.test_resize_pre_applied && state.test_resize_pre_requested && state.animation_seconds<ANIMATION_SECONDS {
			state.test_resize_pre_applied=true
			fmt.printf("[webgpu-feasibility] resize during animation applied at %dx%d\n",state.config.width,state.config.height)
		} else if !state.test_resize_post_applied && state.test_resize_post_requested && state.animation_seconds>=ANIMATION_SECONDS {
			state.test_resize_post_applied=true
			fmt.printf("[webgpu-feasibility] resize after animation applied at %dx%d\n",state.config.width,state.config.height)
		}
	}
}

@(export)
webgpu_resize :: proc() {
	context = state.ctx
	resize()
}

@(export)
webgpu_restart :: proc() {
	context = state.ctx
	state.animation_seconds = 0
	state.dirty = true
}

@(private="file", export)
step :: proc(dt: f32) -> bool {
	context = state.ctx
	if state.device_lost { return false }
	begin_test_device_loss()
	if !state.ready { return true }
	if state.animation_seconds < ANIMATION_SECONDS {
		state.animation_seconds += dt
		state.dirty = true
	}
	if state.dirty {
		render_surface_frame()
		state.dirty = false
	}
	return state.animation_seconds < ANIMATION_SECONDS
}

finish :: proc() {
	if state.readback_buffer != nil { wgpu.BufferDestroy(state.readback_buffer); wgpu.BufferRelease(state.readback_buffer) }
	if state.offscreen_view != nil { wgpu.TextureViewRelease(state.offscreen_view) }
	if state.offscreen_texture != nil { wgpu.TextureDestroy(state.offscreen_texture); wgpu.TextureRelease(state.offscreen_texture) }
	if state.bind_group != nil { wgpu.BindGroupRelease(state.bind_group) }
	if state.bind_group_layout != nil { wgpu.BindGroupLayoutRelease(state.bind_group_layout) }
	if state.sampler != nil { wgpu.SamplerRelease(state.sampler) }
	if state.glyph_view != nil { wgpu.TextureViewRelease(state.glyph_view) }
	if state.glyph_texture != nil { wgpu.TextureDestroy(state.glyph_texture); wgpu.TextureRelease(state.glyph_texture) }
	if state.image_view != nil { wgpu.TextureViewRelease(state.image_view) }
	if state.image_texture != nil { wgpu.TextureDestroy(state.image_texture); wgpu.TextureRelease(state.image_texture) }
	if state.vertex_buffer != nil { wgpu.BufferDestroy(state.vertex_buffer); wgpu.BufferRelease(state.vertex_buffer) }
	if state.probe_uniform_buffer != nil { wgpu.BufferDestroy(state.probe_uniform_buffer); wgpu.BufferRelease(state.probe_uniform_buffer) }
	if state.pipeline != nil { wgpu.RenderPipelineRelease(state.pipeline) }
	if state.offscreen_pipeline != nil { wgpu.RenderPipelineRelease(state.offscreen_pipeline) }
	if state.pipeline_layout != nil { wgpu.PipelineLayoutRelease(state.pipeline_layout) }
	if state.shader != nil { wgpu.ShaderModuleRelease(state.shader) }
	if state.queue != nil { wgpu.QueueRelease(state.queue) }
	if state.device != nil { wgpu.DeviceDestroy(state.device); wgpu.DeviceRelease(state.device) }
	if state.adapter != nil { wgpu.AdapterRelease(state.adapter) }
	if state.surface != nil { wgpu.SurfaceUnconfigure(state.surface); wgpu.SurfaceRelease(state.surface) }
	if state.instance != nil { wgpu.InstanceRelease(state.instance) }
	if state.font._data != nil { runa.font_destroy(&state.font) }
	if state.atlas.page_w != 0 { runa.atlas_destroy(&state.atlas) }
	delete(state.vertices)
	delete(state.draws)
	delete(state.glyph_quads)
}
