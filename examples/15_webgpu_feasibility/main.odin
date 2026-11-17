package webgpu_feasibility

import "base:runtime"
import "core:fmt"
import "core:sync"
import alicorn "../../runtime"
import "vendor:wgpu"
import runa "../../third_party/Runa"
import webgpu_renderer "../../renderer/webgpu"

ANIMATION_SECONDS :: 1.8
VERTEX_CAPACITY :: 256 * 1024
READBACK_WIDTH :: 63
READBACK_HEIGHT :: 64
CAPTURE_ORIGIN_X :: 18
CAPTURE_ORIGIN_Y :: 28
CAPTURE_WIDTH :: READBACK_WIDTH - CAPTURE_ORIGIN_X
CAPTURE_HEIGHT :: READBACK_HEIGHT - CAPTURE_ORIGIN_Y
READBACK_BYTES_PER_PIXEL :: 4
READBACK_BYTES_PER_ROW :: 256
READBACK_BUFFER_BYTES :: READBACK_BYTES_PER_ROW * READBACK_HEIGHT
READBACK_TARGET_COUNT :: 15
READBACK_TOTAL_BYTES :: READBACK_BUFFER_BYTES * READBACK_TARGET_COUNT
FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY :: #config(FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY, false)
FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY :: #config(FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY, false)
FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_SPONTANEOUS_CALLBACK :: #config(FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_SPONTANEOUS_CALLBACK, false)
FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_RELEASE_BEFORE_POLL :: #config(FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_RELEASE_BEFORE_POLL, false)
FEASIBILITY_TEST_QUIT_AFTER_READBACK :: #config(FEASIBILITY_TEST_QUIT_AFTER_READBACK, false)
FEASIBILITY_TEST_RESIZE :: #config(FEASIBILITY_TEST_RESIZE, false)
FEASIBILITY_TEST_COMPOSITOR_RECREATION :: #config(FEASIBILITY_TEST_COMPOSITOR_RECREATION, false)
FEASIBILITY_TEST_WEBGPU_PRESENTER :: #config(FEASIBILITY_TEST_WEBGPU_PRESENTER, false)
FEASIBILITY_TEST_SURFACE_PRESENTER :: #config(FEASIBILITY_TEST_SURFACE_PRESENTER, false)
FEASIBILITY_TEST_WEB_CANVAS_PRESENTER :: #config(FEASIBILITY_TEST_WEB_CANVAS_PRESENTER, false)
FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER :: #config(FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER, false)
FEASIBILITY_TEST_NATIVE_HOSTED_SMOKE :: #config(FEASIBILITY_TEST_NATIVE_HOSTED_SMOKE, false)
FEASIBILITY_TEST_NATIVE_MULTI_SURFACE :: #config(FEASIBILITY_TEST_NATIVE_MULTI_SURFACE, false)
SURFACE_CACHE_PRESSURE_BATCH_COUNT :: 120
SURFACE_CACHE_PRESSURE_FIRST_WIDTH :: 100
SURFACE_CACHE_PRESSURE_SECOND_WIDTH :: SURFACE_CACHE_PRESSURE_FIRST_WIDTH + SURFACE_CACHE_PRESSURE_BATCH_COUNT
SURFACE_CACHE_PRESSURE_HEIGHT :: 18
SURFACE_PRESENTER_LOGICAL_WIDTH :: 960
SURFACE_PRESENTER_LOGICAL_HEIGHT :: 540

Vertex :: struct {
	position: [2]f32,
	uv: [2]f32,
	color: [4]f32,
	kind: u32,
}
Glyph_Quad :: struct { x0, y0, x1, y1: f32, uv: [4]f32 }
Draw_Command :: struct { first, count: u32, scissor: [4]u32 }
Native_Hosted_Feasibility_App :: struct {
	click_count: int,
	text_key_count: int,
	text_key_passed: bool,
	generic_text_owner: alicorn.Node_ID,
	text_change_count: int,
	text_input_passed: bool,
}

state: struct {
	ctx: runtime.Context,
	os: OS,
	instance: wgpu.Instance,
	surface: wgpu.Surface,
	adapter: wgpu.Adapter,
	device: wgpu.Device,
	queue: wgpu.Queue,
	native_hosted_ready: bool,
	native_hosted_presented: bool,
	native_hosted_smoke_click_sent: bool,
	native_hosted_smoke_resize_requested: bool,
	native_hosted_resize_applied: bool,
	native_hosted_resize_presented: bool,
	native_hosted_present_count: u64,
	native_hosted_has_more_work: bool,
	native_hosted_next_wake_ns: u64,
	native_hosted_app: Native_Hosted_Feasibility_App,
	native_secondary_surface: wgpu.Surface,
	native_secondary_hosted_app: Native_Hosted_Feasibility_App,
	native_secondary_hosted_ready: bool,
	native_secondary_presented: bool,
	native_secondary_click_sent: bool,
	native_secondary_resize_requested: bool,
	native_secondary_resize_applied: bool,
	native_secondary_resize_presented: bool,
	native_secondary_shutdown_passed: bool,
	native_secondary_has_more_work: bool,
	native_secondary_next_wake_ns: u64,
	solid_runtime: alicorn.Runtime,
	solid_renderer: webgpu_renderer.Solid_Renderer,
	solid_runtime_ready: bool,
	text_runtime: alicorn.Runtime,
	text_renderer: webgpu_renderer.Text_Renderer,
	text_runtime_ready: bool,
	compositor: webgpu_renderer.WebGPU_Compositor,
	backdrop_compositor: webgpu_renderer.WebGPU_Compositor,
	presenter: webgpu_renderer.WebGPU_Presenter,
	presenter_created, presenter_destroyed, presenter_completion_passed, presenter_pixel_parity_passed: bool,
	presenter_submission: webgpu_renderer.WebGPU_Submission,
	surface_presenter: webgpu_renderer.WebGPU_Presenter,
	surface_presenter_created, surface_presenter_destroyed: bool,
	surface_presenter_completion_passed, surface_presenter_completion_pending: bool,
	surface_presenter_submission: webgpu_renderer.WebGPU_Submission,
	surface_output: alicorn.Presentation_Output_ID,
	surface_output_registered, surface_output_acknowledged: bool,
	surface_runtime: alicorn.Runtime,
	surface_runtime_ready: bool,
	surface_runtime_root: alicorn.Node_ID,
	surface_runtime_image: alicorn.Image_Handle,
	surface_runtime_waveform: alicorn.Node_ID,
	surface_motion_elapsed_ns: i64,
	surface_motion_active, surface_motion_settled: bool,
	compositor_image_a, compositor_image_b: alicorn.Image_Handle,
	compositor_material_surface_ids: [4]alicorn.Node_ID,
	compositor_material_surface_bounds: [4]alicorn.Rect,
	material_accessibility_variant_passed: bool,
	compositor_custom_surface_ids: [2]alicorn.Node_ID,
	compositor_completion_serial: u64,
	backdrop_completion_serial: u64,
	backdrop_effect_pixel_passed: bool,
	backdrop_fallback_pixel_passed: bool,
	backdrop_resize_retirement_passed: bool,
	multiple_backdrop_pixel_passed: bool,
	image_retirement_passed: bool,
	surface_resource_retirement_passed: bool,
	surface_cache_pressure_inflight_passed, surface_cache_pressure_passed: bool,
	surface_cache_pressure_serial: u64,
	surface_cache_pressure_evictions_before_probe: u64,
	composite_offscreen_texture: wgpu.Texture,
	composite_offscreen_view: wgpu.TextureView,
	presenter_offscreen_texture: wgpu.Texture,
	presenter_offscreen_view: wgpu.TextureView,
	backdrop_offscreen_texture: wgpu.Texture,
	backdrop_offscreen_view: wgpu.TextureView,
	capture_offscreen_texture: wgpu.Texture,
	capture_offscreen_view: wgpu.TextureView,
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
	solid_offscreen_texture: wgpu.Texture,
	solid_offscreen_view: wgpu.TextureView,
	text_offscreen_texture: wgpu.Texture,
	text_offscreen_view: wgpu.TextureView,
	readback_buffer: wgpu.Buffer,
	readback_pending, readback_done, readback_callback_received: bool,
	compositor_recreation_started, compositor_recreation_passed: bool,
	compositor_recreation_after_rebuild: bool,
	compositor_recreation_queue_done, compositor_recreation_queue_ok: bool,
	compositor_recreation_readback_pending, compositor_recreation_readback_done: bool,
	compositor_recreation_readback_ok: bool,
	compositor_recreation_pixels_match, compositor_recreation_products_rebuilt: bool,
	compositor_recreation_serial: u64,
	compositor_recreation_readback_buffer: wgpu.Buffer,
	compositor_recreation_reference: []u8,
	compositor_recreation_commands: []alicorn.Paint_Command,
	compositor_recreation_revision: u64,
	queue_work_done_pending, queue_work_done, queue_work_done_ok: bool,
	test_resize_pre_requested, test_resize_pre_applied, test_resize_pre_frame: bool,
	test_resize_post_requested, test_resize_post_applied, test_resize_post_frame: bool,
	test_resize_post_delay: f32,
	test_resize_pre_present_before, test_resize_post_present_before, surface_present_count: u64,
	width, height: u32,
	animation_seconds: f32,
	ready, dirty, quit, device_lost: bool,
	test_explicit_destroy_pending: bool,
	test_explicit_destroy_triggered: bool,
	test_explicit_destroy_callback_passed: bool,
	device_lost_callback_count: i64,
	device_loss_reason_raw: i64,
	native_destroy_wait_probed: bool,
}

main :: proc() {
	state.ctx = context
	state.vertices = make([dynamic]Vertex, 0, 4096)
	state.draws = make([dynamic]Draw_Command, 0, 32)
	state.glyph_quads = make([dynamic]Glyph_Quad, 0, 96)
	requested_backend, backend_valid := os_requested_backend()
	if !backend_valid {
		fmt.eprintln("[webgpu-feasibility] unsupported --backend selector (supported: vulkan, d3d12)")
		os_exit_failure()
	}
	fmt.printf("[webgpu-feasibility] requested backend=%v\n", requested_backend)
	os_init()
	state.instance = wgpu.CreateInstance(nil)
	if state.instance == nil { fmt.panicf("WebGPU instance creation failed") }
	state.surface = os_get_surface(state.instance)
	if state.surface == nil { fmt.panicf("WebGPU surface creation failed") }
	when FEASIBILITY_TEST_NATIVE_MULTI_SURFACE {
		state.native_secondary_surface = os_get_secondary_surface(state.instance)
		if state.native_secondary_surface == nil { fmt.panicf("secondary WebGPU surface creation failed") }
	}
	wgpu.InstanceRequestAdapter(state.instance, &wgpu.RequestAdapterOptions{
		compatibleSurface = state.surface,
		powerPreference = .HighPerformance,
		backendType = requested_backend,
	}, {callback = on_adapter})
	os_run()
	when FEASIBILITY_TEST_NATIVE_HOSTED_SMOKE {
		if !state.native_hosted_presented || state.native_hosted_ready ||
		   state.native_hosted_app.click_count != 1 || !state.native_hosted_resize_presented ||
		   state.native_hosted_app.text_key_count != 1 || !state.native_hosted_app.text_key_passed ||
		   state.native_hosted_app.text_change_count != 1 || !state.native_hosted_app.text_input_passed {
			fmt.eprintln("[webgpu-feasibility] native Hosted_Runtime presenter smoke FAIL",
				"presented", state.native_hosted_presented,
				"destroyed", !state.native_hosted_ready,
				"clicks", state.native_hosted_app.click_count,
				"text_keys", state.native_hosted_app.text_key_count,
				"text_key_passed", state.native_hosted_app.text_key_passed,
				"resize", state.native_hosted_resize_presented,
				"text_changes", state.native_hosted_app.text_change_count,
				"text_input", state.native_hosted_app.text_input_passed,
			)
			os_exit_failure()
		}
		fmt.println("[webgpu-feasibility] native Hosted_Runtime pointer, application text-key, text/IME routing, resize, and lifecycle smoke PASS")
	}
	when FEASIBILITY_TEST_NATIVE_MULTI_SURFACE {
		if !state.native_secondary_presented || !state.native_secondary_resize_applied ||
		   !state.native_secondary_resize_presented || state.native_secondary_hosted_ready ||
		   !state.native_secondary_shutdown_passed || state.native_secondary_hosted_app.click_count != 1 {
			fmt.eprintln("[webgpu-feasibility] two-surface lifecycle smoke FAIL",
				"initial_present", state.native_secondary_presented,
				"resize_applied", state.native_secondary_resize_applied,
				"resize_present", state.native_secondary_resize_presented,
				"shutdown", state.native_secondary_shutdown_passed,
				"secondary_clicks", state.native_secondary_hosted_app.click_count,
				"still_ready", state.native_secondary_hosted_ready,
			)
			os_exit_failure()
		}
		fmt.println("[webgpu-feasibility] shared-device two-surface presentation, resize, independent Runtime teardown PASS")
	}
	when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
		if !state.readback_done || !state.queue_work_done || !state.queue_work_done_ok {
			os_exit_failure()
		}
		if !state.image_retirement_passed || !state.surface_resource_retirement_passed ||
		   !state.surface_cache_pressure_inflight_passed || !state.surface_cache_pressure_passed ||
		   !state.backdrop_fallback_pixel_passed || !state.backdrop_resize_retirement_passed ||
		   !state.multiple_backdrop_pixel_passed { os_exit_failure() }
		when FEASIBILITY_TEST_COMPOSITOR_RECREATION {
			if !state.compositor_recreation_passed { os_exit_failure() }
		}
		when FEASIBILITY_TEST_WEBGPU_PRESENTER {
			if !state.presenter_created || !state.presenter_destroyed ||
			   !state.presenter_completion_passed || !state.presenter_pixel_parity_passed {
				os_exit_failure()
			}
		}
		when FEASIBILITY_TEST_SURFACE_PRESENTER {
			if !state.surface_presenter_created || !state.surface_presenter_destroyed ||
			   !state.surface_presenter_completion_passed || !state.surface_output_acknowledged ||
			   state.surface_output.runtime_identity == 0 || state.surface_output.sequence == 0 ||
			   !state.surface_motion_settled || state.dirty || state.surface_present_count < 2 {
				os_exit_failure()
			}
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
	if !state.image_retirement_passed || !state.surface_resource_retirement_passed { return false }
	if !state.surface_cache_pressure_inflight_passed || !state.surface_cache_pressure_passed { return false }
	if !state.backdrop_fallback_pixel_passed || !state.backdrop_resize_retirement_passed ||
	   !state.multiple_backdrop_pixel_passed { return false }
	when FEASIBILITY_TEST_COMPOSITOR_RECREATION {
		if !state.compositor_recreation_passed { return false }
	}
	when FEASIBILITY_TEST_WEBGPU_PRESENTER {
		if !state.presenter_created || !state.presenter_completion_passed || !state.presenter_pixel_parity_passed { return false }
	}
	when FEASIBILITY_TEST_SURFACE_PRESENTER {
		if !state.surface_presenter_created || !state.surface_presenter_completion_passed ||
		   state.surface_presenter_completion_pending || !state.surface_motion_settled ||
		   state.dirty || state.surface_present_count < 2 {
			return false
		}
	}
	when FEASIBILITY_TEST_RESIZE {
		if !state.test_resize_pre_applied || !state.test_resize_pre_frame ||
			!state.test_resize_post_applied || !state.test_resize_post_frame { return false }
	}
	return true
}

smoke_resize_complete :: proc() -> bool {
	when FEASIBILITY_TEST_RESIZE {
		return state.test_resize_pre_applied && state.test_resize_pre_frame &&
			state.test_resize_post_applied && state.test_resize_post_frame
	} else {
		return true
	}
}

on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, message: string, userdata1, userdata2: rawptr) {
	context = state.ctx
	fmt.printf("[webgpu-feasibility] adapter callback status=%v adapter_present=%v\n", status, adapter != nil)
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
	fmt.println("[webgpu-feasibility] surface capabilities query begin")
	caps, cap_status := wgpu.SurfaceGetCapabilities(state.surface, adapter)
	fmt.printf("[webgpu-feasibility] surface capabilities query status=%v formats=%d alpha_modes=%d\n", cap_status, caps.formatCount, caps.alphaModeCount)
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
	when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_SPONTANEOUS_CALLBACK {
		loss_callback_mode = .AllowSpontaneos
	}
	fmt.println("[webgpu-feasibility] device request submit")
	device_desc:=wgpu.DeviceDescriptor{
		label="Alicorn WebGPU feasibility device",
		deviceLostCallbackInfo={mode=loss_callback_mode,callback=on_device_lost},
	}
	wgpu.AdapterRequestDevice(adapter, &device_desc, {callback = on_device})
}

on_device_lost :: proc "c" (device:^wgpu.Device, reason:wgpu.DeviceLostReason, message:wgpu.StringView, userdata1,userdata2:rawptr) {
	context=state.ctx
	sync.atomic_store(&state.device_loss_reason_raw, i64(reason))
	sync.atomic_add(&state.device_lost_callback_count, 1)
	when !FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
		state.device_lost=true
		state.ready=false
	}
	device_handle_present := device != nil && device^ != nil
	fmt.printf("[webgpu-feasibility] device loss notification reason=%v device_handle_present=%v message=%s\n",reason,device_handle_present,message)
}

on_queue_work_done :: proc "c" (status:wgpu.QueueWorkDoneStatus, message:wgpu.StringView, userdata1,userdata2:rawptr) {
	context = state.ctx
	state.queue_work_done_pending = false
	state.queue_work_done = true
	state.queue_work_done_ok = status == .Success
	if state.backdrop_completion_serial > 0 && status == .Success {
		if !webgpu_renderer.Compositor_Complete_Submission(&state.backdrop_compositor, state.backdrop_completion_serial) {
			state.queue_work_done_ok = false
		} else {
			entry := backdrop_probe_entry(alicorn.Node_ID(2))
			if entry == nil { state.queue_work_done_ok = false; return }
			backdrop := &entry.renderer
			state.backdrop_resize_retirement_passed = len(backdrop.retired) == 0 &&
				backdrop.resident_bytes == backdrop.set.bytes+webgpu_renderer.WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES &&
				backdrop.completed_serial >= state.backdrop_completion_serial
			fmt.printf("[webgpu-feasibility] backdrop resized texture retirement %s submitted=%d completed=%d retired=%d resident=%d active=%d\n",
				"PASS" if state.backdrop_resize_retirement_passed else "FAIL", backdrop.set.last_use_serial,
				backdrop.completed_serial, len(backdrop.retired), backdrop.resident_bytes,
				backdrop.set.bytes+webgpu_renderer.WEBGPU_BACKDROP_EFFECT_VERTEX_BYTES)
			if !state.backdrop_resize_retirement_passed { state.queue_work_done_ok = false }
		}
	}
	if state.compositor_completion_serial > 0 && status == .Success {
		completion_ok := webgpu_renderer.Compositor_Complete_Submission(&state.compositor, state.compositor_completion_serial)
		state.image_retirement_passed = completion_ok && len(state.compositor.images.retired) == 0 &&
			state.compositor.images.resident_bytes == 64 && state.compositor.images.resource_release_count == 1
		fmt.printf("[webgpu-feasibility] image resource retirement %s submitted_serial=%d completed_serial=%d retired=%d resident_bytes=%d releases=%d\n",
			"PASS" if state.image_retirement_passed else "FAIL", state.compositor.images.submitted_serial,
			state.compositor.images.completed_serial, len(state.compositor.images.retired),
			state.compositor.images.resident_bytes, state.compositor.images.resource_release_count)
		surface_active_bytes := state.compositor.surfaces.instance_buffer_bytes
		for resource in state.compositor.surfaces.resources { surface_active_bytes += resource.byte_size }
		state.surface_resource_retirement_passed = completion_ok && len(state.compositor.surfaces.retired) == 0 &&
			state.compositor.surfaces.resident_bytes == surface_active_bytes &&
			state.compositor.surfaces.resource_retirement_count == 1 &&
			state.compositor.surfaces.resource_release_count == 1
		fmt.printf("[webgpu-feasibility] custom geometry buffer retirement %s submitted_serial=%d completed_serial=%d retired=%d active_bytes=%d resident_bytes=%d retirements=%d releases=%d\n",
			"PASS" if state.surface_resource_retirement_passed else "FAIL", state.compositor.surfaces.submitted_serial,
			state.compositor.surfaces.completed_serial, len(state.compositor.surfaces.retired), surface_active_bytes,
			state.compositor.surfaces.resident_bytes, state.compositor.surfaces.resource_retirement_count,
			state.compositor.surfaces.resource_release_count)
		when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
			if state.image_retirement_passed && state.surface_resource_retirement_passed {
				start_surface_cache_pressure_test()
			} else {
				state.quit = true
			}
		}
	}
	when FEASIBILITY_TEST_WEBGPU_PRESENTER {
		if state.presenter_submission.serial > 0 && status == .Success {
			state.presenter_completion_passed = webgpu_renderer.WebGPU_Presenter_Complete_Submission(
				&state.presenter, state.presenter_submission,
			)
			fmt.printf("[webgpu-feasibility] host-owned WebGPU presenter completion %s serial=%d in_flight=%d\n",
				"PASS" if state.presenter_completion_passed else "FAIL",
				state.presenter_submission.serial,
				webgpu_renderer.WebGPU_Presenter_In_Flight(&state.presenter))
			if !state.presenter_completion_passed { state.queue_work_done_ok = false }
		}
	}
	fmt.printf("[webgpu-feasibility] queue work done status=%v message=%s\n", status, message)
	when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
		compositor_recreation_maybe_start()
		if smoke_complete() { state.quit = true }
	}
}

on_surface_presenter_queue_done :: proc "c" (
	status: wgpu.QueueWorkDoneStatus,
	message: wgpu.StringView,
	userdata1, userdata2: rawptr,
) {
	context = state.ctx
	state.surface_presenter_completion_pending = false
	state.surface_presenter_completion_passed = status == .Success &&
		state.surface_presenter_submission.serial > 0 &&
		webgpu_renderer.WebGPU_Presenter_Complete_Submission(
			&state.surface_presenter, state.surface_presenter_submission,
		)
	fmt.printf("[webgpu-feasibility] host surface presenter queue completion %s serial=%d in_flight=%d status=%v message=%s\n",
		"PASS" if state.surface_presenter_completion_passed else "FAIL",
		state.surface_presenter_submission.serial,
		webgpu_renderer.WebGPU_Presenter_In_Flight(&state.surface_presenter),
		status, message,
	)
	if !state.surface_presenter_completion_passed { state.quit = true }
	when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
		if smoke_complete() { state.quit = true }
	}
}

on_surface_cache_pressure_batch_a :: proc "c" (status: wgpu.QueueWorkDoneStatus, message: wgpu.StringView, userdata1, userdata2: rawptr) {
	context = state.ctx
	state.queue_work_done_pending = false
	if status != .Success || !webgpu_renderer.Compositor_Complete_Submission(&state.compositor, state.surface_cache_pressure_serial) {
		fmt.printf("[webgpu-feasibility] cache pressure first batch completion FAIL status=%v message=%s serial=%d\n",
			status, message, state.surface_cache_pressure_serial)
		state.queue_work_done = true
		state.queue_work_done_ok = false
		state.quit = true
		return
	}
	fmt.printf("[webgpu-feasibility] cache pressure first batch completed serial=%d resident_bytes=%d\n",
		state.surface_cache_pressure_serial, state.compositor.surfaces.resident_bytes)
	if !surface_cache_pressure_submit_batch(SURFACE_CACHE_PRESSURE_SECOND_WIDTH, 4) {
		fmt.println("[webgpu-feasibility] cache pressure second batch after completion FAIL")
		state.queue_work_done = true
		state.queue_work_done_ok = false
		state.quit = true
		return
	}
	state.surface_cache_pressure_serial = 4
	state.queue_work_done = false
	state.queue_work_done_ok = false
	state.queue_work_done_pending = true
	wgpu.QueueOnSubmittedWorkDone(state.queue, {mode=.AllowProcessEvents, callback=on_surface_cache_pressure_batch_b})
}

on_surface_cache_pressure_batch_b :: proc "c" (status: wgpu.QueueWorkDoneStatus, message: wgpu.StringView, userdata1, userdata2: rawptr) {
	context = state.ctx
	state.queue_work_done_pending = false
	completion_ok := status == .Success && webgpu_renderer.Compositor_Complete_Submission(
		&state.compositor, state.surface_cache_pressure_serial,
	)
	resource_count := surface_cache_pressure_resource_count(
		SURFACE_CACHE_PRESSURE_SECOND_WIDTH, SURFACE_CACHE_PRESSURE_BATCH_COUNT,
	)
	oldest_first_resource_present := surface_cache_pressure_resource_present(SURFACE_CACHE_PRESSURE_FIRST_WIDTH)
	newest_first_resource_present := surface_cache_pressure_resource_present(
		SURFACE_CACHE_PRESSURE_FIRST_WIDTH + SURFACE_CACHE_PRESSURE_BATCH_COUNT - 1,
	)
	active_bytes := surface_cache_pressure_active_bytes()
	renderer := &state.compositor.surfaces
	state.surface_cache_pressure_passed = completion_ok && resource_count == SURFACE_CACHE_PRESSURE_BATCH_COUNT &&
		renderer.completed_serial == state.surface_cache_pressure_serial && len(renderer.retired) == 0 &&
		renderer.resident_bytes <= webgpu_renderer.SURFACE_GPU_CACHE_BUDGET_BYTES &&
		renderer.resident_bytes == active_bytes && renderer.resource_eviction_count > state.surface_cache_pressure_evictions_before_probe &&
		!oldest_first_resource_present && newest_first_resource_present
	state.queue_work_done = true
	state.queue_work_done_ok = status == .Success
	fmt.printf("[webgpu-feasibility] cache pressure bound/LRU %s status=%v message=%s submitted=%d completed=%d batch_resources=%d resident_bytes=%d budget_bytes=%d active_bytes=%d evictions=%d oldest_first_batch_evicted=%v newest_first_batch_retained=%v retired=%d\n",
		"PASS" if state.surface_cache_pressure_passed else "FAIL", status, message,
		renderer.submitted_serial, renderer.completed_serial, resource_count, renderer.resident_bytes,
		webgpu_renderer.SURFACE_GPU_CACHE_BUDGET_BYTES, active_bytes, renderer.resource_eviction_count,
		!oldest_first_resource_present, newest_first_resource_present, len(renderer.retired))
	when FEASIBILITY_TEST_COMPOSITOR_RECREATION {
		compositor_recreation_maybe_start()
	}
	when FEASIBILITY_TEST_SURFACE_PRESENTER {
		if smoke_complete() { state.quit = true }
	}
	when !FEASIBILITY_TEST_COMPOSITOR_RECREATION && !FEASIBILITY_TEST_SURFACE_PRESENTER {
		if smoke_complete() || (state.readback_callback_received && smoke_resize_complete()) { state.quit = true }
	}
	when FEASIBILITY_TEST_COMPOSITOR_RECREATION {
		if smoke_complete() { state.quit = true }
	}
}

on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, message: string, userdata1, userdata2: rawptr) {
	context = state.ctx
	fmt.printf("[webgpu-feasibility] device callback status=%v device_present=%v message=%s\n", status, device != nil, message)
	if status != .Success || device == nil { fmt.panicf("device request failed: %v %s", status, message) }
	state.device = device
	state.queue = wgpu.DeviceGetQueue(device)
	when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY {
		fmt.println("[webgpu-feasibility] early device-destroy probe: no GPU resources or submissions")
		state.test_explicit_destroy_pending=true
		return
	}
	create_resources()
	solid_renderer, solid_ok := webgpu_renderer.Solid_Create(state.device, state.queue, .RGBA8Unorm)
	if !solid_ok { fmt.panicf("Alicorn WebGPU solid renderer initialization failed") }
	state.solid_renderer = solid_renderer
	build_solid_runtime()
	text_renderer, text_ok := webgpu_renderer.Text_Create(state.device, state.queue, .RGBA8Unorm)
	if !text_ok { fmt.panicf("Alicorn WebGPU text renderer initialization failed") }
	state.text_renderer = text_renderer
	build_text_runtime()
	build_compositor_images()
	compositor, compositor_ok := webgpu_renderer.Compositor_Create(state.device, state.queue, .RGBA8Unorm)
	if !compositor_ok { fmt.panicf("Alicorn WebGPU compositor initialization failed") }
	state.compositor = compositor
	backdrop_compositor, backdrop_compositor_ok := webgpu_renderer.Compositor_Create(state.device, state.queue, .RGBA8Unorm)
	if !backdrop_compositor_ok { fmt.panicf("Alicorn WebGPU backdrop compositor initialization failed") }
	state.backdrop_compositor = backdrop_compositor
	when FEASIBILITY_TEST_WEBGPU_PRESENTER {
		presenter, presenter_ok := webgpu_renderer.WebGPU_Presenter_Create(
			state.device, state.queue, .RGBA8Unorm, &state.text_runtime,
		)
		if !presenter_ok { fmt.panicf("host-owned WebGPU presenter creation failed") }
		state.presenter = presenter
		state.presenter_created = true
	}
	when FEASIBILITY_TEST_SURFACE_PRESENTER {
		build_surface_runtime()
		surface_presenter, surface_presenter_ok := webgpu_renderer.WebGPU_Presenter_Create(
			state.device, state.queue, state.config.format, &state.surface_runtime,
		)
		if !surface_presenter_ok { fmt.panicf("host-owned surface presenter creation failed") }
		state.surface_presenter = surface_presenter
		state.surface_presenter_created = true
	}
	fmt.println("[webgpu-feasibility] text runtime built")
	state.width, state.height = os_get_framebuffer_size()
	os_set_surface_size(state.width, state.height)
	state.config.device = device
	state.config.usage = {.RenderAttachment}
	state.config.width, state.config.height = max(state.width, 1), max(state.height, 1)
	state.config.presentMode = .Fifo
	wgpu.SurfaceConfigure(state.surface, &state.config)
	state.ready, state.dirty = true, true
	when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
		native_hosted_init()
	}
	when FEASIBILITY_TEST_WEB_CANVAS_PRESENTER {
		browser_host_init()
	}
	start_offscreen_readback()
}

resize :: proc() {
	if !state.ready || state.surface == nil || state.device == nil { return }
	when FEASIBILITY_TEST_WEB_CANVAS_PRESENTER {
		browser_host_resize()
		return
	}
	when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
		native_hosted_resize()
		return
	}
	state.width, state.height = os_get_framebuffer_size()
	os_set_surface_size(state.width, state.height)
	state.config.width, state.config.height = max(state.width, 1), max(state.height, 1)
	wgpu.SurfaceConfigure(state.surface, &state.config)
	when FEASIBILITY_TEST_SURFACE_PRESENTER || FEASIBILITY_TEST_WEB_CANVAS_PRESENTER {
		// Surface reconfiguration can discard every pixel in the presentation
		// target even when Alicorn's retained display list has not changed. Ask
		// for a retained-only presentation frame so the output gets a fresh
		// submission revision without rerunning application description/layout.
		if state.surface_runtime_ready && state.surface_output_registered {
			before, before_status := alicorn.presentation_output_snapshot(&state.surface_runtime, state.surface_output)
			if before_status != .Ok { fmt.panicf("WebGPU surface resize could not query output before redraw: %v", before_status) }
			alicorn.request_presentation(&state.surface_runtime, "WebGPU surface reconfigured")
			ui, ready := alicorn.begin_presentation_frame(&state.surface_runtime)
			if !ready { fmt.panicf("WebGPU surface resize could not flush its retained redraw request") }
			alicorn.end_presentation_frame(&ui)
			after, after_status := alicorn.presentation_output_snapshot(&state.surface_runtime, state.surface_output)
			if after_status != .Ok || !after.pending || after.root != before.root || after.revision <= before.revision {
				fmt.panicf("WebGPU surface resize did not publish a pending retained redraw: status=%v before=%d after=%d pending=%v",
					after_status, before.revision, after.revision, after.pending)
			}
			fmt.printf("[webgpu-feasibility] surface resize retained redraw PASS revision=%d->%d\n",
				before.revision, after.revision)
		}
	}
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
	when FEASIBILITY_TEST_WEB_CANVAS_PRESENTER {
		browser_host_surface_wake(nil)
	} else {
		state.animation_seconds = 0
		state.dirty = true
	}
}

@(export)
webgpu_init_state :: proc() -> i32 {
	if state.ready { return 1 }
	if state.device_lost { return -1 }
	return 0
}

@(private="file", export)
step :: proc(dt: f32, now_ns: u64) -> bool {
	context = state.ctx
	if state.device_lost { return false }
	begin_test_explicit_device_destroy()
	if !state.ready { return false }
	when FEASIBILITY_TEST_WEB_CANVAS_PRESENTER {
		_ = dt
		return browser_host_step(now_ns)
	} else {
		_ = now_ns
		if state.animation_seconds < ANIMATION_SECONDS {
			state.animation_seconds += dt
			state.dirty = true
		}
		if state.dirty {
			state.dirty = false
			render_surface_frame()
		}
		return state.animation_seconds < ANIMATION_SECONDS || state.dirty
	}
}

finish :: proc() {
	when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
		when FEASIBILITY_TEST_NATIVE_MULTI_SURFACE {
			native_secondary_hosted_shutdown()
			if state.native_secondary_surface != nil {
				wgpu.SurfaceUnconfigure(state.native_secondary_surface)
				wgpu.SurfaceRelease(state.native_secondary_surface)
				state.native_secondary_surface = nil
			}
		}
		native_hosted_shutdown()
	}
	webgpu_renderer.Compositor_Destroy(&state.compositor)
	webgpu_renderer.Compositor_Destroy(&state.backdrop_compositor)
	if state.presenter_created {
		if !webgpu_renderer.WebGPU_Presenter_Destroy(&state.presenter) {
			fmt.println("[webgpu-feasibility] host-owned presenter still has pending frames at shutdown")
		} else {
			state.presenter_destroyed = true
		}
	}
	if state.surface_presenter_created {
		if !webgpu_renderer.WebGPU_Presenter_Destroy(&state.surface_presenter) {
			fmt.println("[webgpu-feasibility] SDL surface presenter still has pending frames at shutdown")
		} else {
			state.surface_presenter_destroyed = true
		}
	}
	webgpu_renderer.Text_Destroy(&state.text_renderer)
	webgpu_renderer.Solid_Destroy(&state.solid_renderer)
	if state.surface_runtime_ready {
		if state.surface_output_registered {
			if status := alicorn.presentation_output_unregister(&state.surface_runtime, state.surface_output); status != .Ok {
				fmt.printf("[webgpu-feasibility] SDL surface output unregister failed: %v\n", status)
			}
			state.surface_output_registered = false
		}
		alicorn.destroy_runtime(&state.surface_runtime)
		state.surface_runtime_ready = false
	}
	if state.text_runtime_ready {
		alicorn.destroy_runtime(&state.text_runtime)
		state.text_runtime_ready = false
	}
	if state.solid_runtime_ready {
		alicorn.destroy_runtime(&state.solid_runtime)
		state.solid_runtime_ready = false
	}
	if state.readback_buffer != nil { wgpu.BufferDestroy(state.readback_buffer); wgpu.BufferRelease(state.readback_buffer) }
	if state.compositor_recreation_readback_buffer != nil {
		wgpu.BufferDestroy(state.compositor_recreation_readback_buffer)
		wgpu.BufferRelease(state.compositor_recreation_readback_buffer)
	}
	if state.solid_offscreen_view != nil { wgpu.TextureViewRelease(state.solid_offscreen_view) }
	if state.solid_offscreen_texture != nil { wgpu.TextureDestroy(state.solid_offscreen_texture); wgpu.TextureRelease(state.solid_offscreen_texture) }
	if state.text_offscreen_view != nil { wgpu.TextureViewRelease(state.text_offscreen_view) }
	if state.text_offscreen_texture != nil { wgpu.TextureDestroy(state.text_offscreen_texture); wgpu.TextureRelease(state.text_offscreen_texture) }
	if state.composite_offscreen_view != nil { wgpu.TextureViewRelease(state.composite_offscreen_view) }
	if state.composite_offscreen_texture != nil { wgpu.TextureDestroy(state.composite_offscreen_texture); wgpu.TextureRelease(state.composite_offscreen_texture) }
	if state.presenter_offscreen_view != nil { wgpu.TextureViewRelease(state.presenter_offscreen_view) }
	if state.presenter_offscreen_texture != nil { wgpu.TextureDestroy(state.presenter_offscreen_texture); wgpu.TextureRelease(state.presenter_offscreen_texture) }
	if state.backdrop_offscreen_view != nil { wgpu.TextureViewRelease(state.backdrop_offscreen_view) }
	if state.backdrop_offscreen_texture != nil { wgpu.TextureDestroy(state.backdrop_offscreen_texture); wgpu.TextureRelease(state.backdrop_offscreen_texture) }
	if state.capture_offscreen_view != nil { wgpu.TextureViewRelease(state.capture_offscreen_view) }
	if state.capture_offscreen_texture != nil { wgpu.TextureDestroy(state.capture_offscreen_texture); wgpu.TextureRelease(state.capture_offscreen_texture) }
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
	delete(state.compositor_recreation_reference)
	delete(state.compositor_recreation_commands)
}
