package main

// The offscreen sweep renders the same 528-command stream through the real
// production display-list path on a real GPU device. It exists because Windows
// reports a single display scale per monitor: the window runs cover the
// conditions at the observed scale, and this device-backed sweep covers 1x,
// 1.25x, 1.5x, and 2x expansion and fill cost without inventing a fake window.
//
// Each measured pass is: solid expand + pack, text/icon/image prep, encode,
// submit, and a fence wait. The fence wait is a GPU completion round trip, not
// presented-frame latency or scan-out.

import "core:fmt"
import "core:strconv"
import "core:time"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import "vendor:sdl3"

OFF_PASSES :: MATERIAL_STREAM_PASSES
OFF_WARMUP :: 2

Off_Samples :: struct {
	pack:   [OFF_PASSES]u64,
	build:  [OFF_PASSES]u64,
	submit: [OFF_PASSES]u64,
	wait:   [OFF_PASSES]u64,
	wall:   [OFF_PASSES]u64,
	count:  int,
}

off_record :: proc(samples: ^Off_Samples, pack, build, submit, wait, wall: u64) {
	if samples.count >= OFF_PASSES { return }
	index := samples.count
	samples.pack[index] = pack
	samples.build[index] = build
	samples.submit[index] = submit
	samples.wait[index] = wait
	samples.wall[index] = wall
	samples.count += 1
}

off_sort :: proc(values: []u64) {
	for index in 1..<len(values) {
		value := values[index]
		position := index
		for position > 0 && values[position-1] > value {
			values[position] = values[position-1]
			position -= 1
		}
		values[position] = value
	}
}

off_percentile :: proc(values: []u64, fraction: f64) -> u64 {
	if len(values) == 0 { return 0 }
	sorted := make([]u64, len(values), context.temp_allocator)
	defer delete(sorted, context.temp_allocator)
	copy(sorted, values)
	off_sort(sorted)
	return sorted[int(fraction*f64(len(sorted)-1))]
}

off_condition_viewport :: proc(condition: Condition, step: u64) -> f32 {
	if condition == .Resize_Sweep {
		return f32(MATERIAL_STREAM_WIDTH+int(step%4)*60)
	}
	return MATERIAL_STREAM_WIDTH
}

off_run_config :: proc(
	device: ^sdl3.GPUDevice,
	rt: ^alicorn.Runtime,
	text: ^host.Native_Text_Renderer,
	surface: ^host.Native_Surface_Renderer,
	scene: ^Material_Scene,
	condition: Condition,
	scale: f32,
	target: ^sdl3.GPUTexture,
	display: ^[dynamic]alicorn.Paint_Command,
) -> bool {
	passes := condition_passes(condition)
	warmups := OFF_WARMUP if passes > 1 else 0
	solid := host.Native_Solid_Renderer{}
	ok := false
	solid, ok = host.native_solid_make(device, .R8G8B8A8_UNORM, rt)
	if !ok { return false }
	defer host.native_solid_destroy(&solid)

	target_w := sdl3.Uint32(f32(MATERIAL_STREAM_WIDTH)*scale)
	target_h := sdl3.Uint32(f32(MATERIAL_STREAM_HEIGHT)*scale)
	samples := Off_Samples{}
	vertices_total: u64 = 0
	measured_draws: u64 = 0
	measured_bytes: u64 = 0
	pass_index := 0
	for pass_index < warmups+passes {
		step := u64(pass_index)
		scene.step = step
		viewport := off_condition_viewport(condition, step)
		material_scene_commands(scene, display, viewport)
		pass_start := time.now()
		command := sdl3.AcquireGPUCommandBuffer(device)
		if command == nil { return false }
		target_info := sdl3.GPUColorTargetInfo{
			texture=target, clear_color=sdl3.FColor{0.03, 0.04, 0.06, 1},
			load_op=.CLEAR, store_op=.STORE,
		}
		pass := sdl3.BeginGPURenderPass(command, &target_info, 1, nil)
		if pass == nil { _ = sdl3.CancelGPUCommandBuffer(command); return false }
		sdl3.EndGPURenderPass(pass)
		pack_start := time.now()
		build_before := solid.build_ns
		draws_before := solid.draw_calls
		bytes_before := solid.vertex_upload_bytes
		if !host.draw_display_list(
			command, target, target_w, target_h,
			text, surface, &solid, display[:], scale, scale,
			clear_background=false,
		) {
			_ = sdl3.CancelGPUCommandBuffer(command)
			return false
		}
		pack_ns := u64(time.duration_nanoseconds(time.since(pack_start)))
		pass_draws := solid.draw_calls-draws_before
		pass_bytes := solid.vertex_upload_bytes-bytes_before
		pass_vertices := u64(len(solid.vertices))
		build_ns := solid.build_ns-build_before
		submit_start := time.now()
		fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
		if fence == nil { return false }
		submit_ns := u64(time.duration_nanoseconds(time.since(submit_start)))
		wait_start := time.now()
		fences := [1]^sdl3.GPUFence{fence}
		if !sdl3.WaitForGPUFences(device, true, &fences[0], 1) { return false }
		wait_ns := u64(time.duration_nanoseconds(time.since(wait_start)))
		sdl3.ReleaseGPUFence(device, fence)
		wall_ns := u64(time.duration_nanoseconds(time.since(pass_start)))
		if pass_index >= warmups {
			vertices_total += pass_vertices
			measured_draws += pass_draws
			measured_bytes += pass_bytes
			off_record(&samples, pack_ns, build_ns, submit_ns, wait_ns, wall_ns)
		}
		pass_index += 1
	}

	measured := samples.count
	if measured == 0 { return true }
	capacity_peak := solid.capacity.peak_capacity
	fmt.printf(
		"[alicorn-material-offscreen] treatment=%s condition=%s scale=%.2f surfaces=%d "+
		"passes=%d vertices_total=%d vertices_per_pass=%d draw_calls_per_pass=%d "+
		"upload_bytes_per_pass=%d peak_vertex_capacity=%d growth_events=%d growth_ms=%.3f "+
		"idle_waits=%d idle_ms=%.3f "+
		"pack_p50_ns=%d pack_p95_ns=%d pack_p99_ns=%d "+
		"build_p50_ns=%d build_p95_ns=%d build_p99_ns=%d "+
		"submit_p50_ns=%d submit_p95_ns=%d submit_p99_ns=%d "+
		"wait_p50_ns=%d wait_p95_ns=%d wait_p99_ns=%d "+
		"wall_p50_ns=%d wall_p95_ns=%d wall_p99_ns=%d\n",
		scene.treatment.name, condition_name(condition), scale,
		MATERIAL_STREAM_CARDS+MATERIAL_STREAM_ROWS, measured,
		vertices_total, vertices_total/u64(measured), measured_draws/u64(measured),
		measured_bytes/u64(measured),
		capacity_peak, solid.capacity.growth_events,
		f64(solid.capacity.growth_ns)/1e6,
		solid.capacity.idle_waits, f64(solid.capacity.idle_wait_ns)/1e6,
		off_percentile(samples.pack[:measured], 0.50),
		off_percentile(samples.pack[:measured], 0.95),
		off_percentile(samples.pack[:measured], 0.99),
		off_percentile(samples.build[:measured], 0.50),
		off_percentile(samples.build[:measured], 0.95),
		off_percentile(samples.build[:measured], 0.99),
		off_percentile(samples.submit[:measured], 0.50),
		off_percentile(samples.submit[:measured], 0.95),
		off_percentile(samples.submit[:measured], 0.99),
		off_percentile(samples.wait[:measured], 0.50),
		off_percentile(samples.wait[:measured], 0.95),
		off_percentile(samples.wait[:measured], 0.99),
		off_percentile(samples.wall[:measured], 0.50),
		off_percentile(samples.wall[:measured], 0.95),
		off_percentile(samples.wall[:measured], 0.99),
	)
	return true
}

run_offscreen :: proc() -> bool {
	if !sdl3.Init({.VIDEO}) {
		fmt.eprintln("SDL_Init(VIDEO) failed for the offscreen material sweep")
		return false
	}
	defer sdl3.Quit()
	formats := sdl3.GPUShaderFormat{.SPIRV, .DXIL, .MSL}
	device := sdl3.CreateGPUDevice(formats, false, nil)
	if device == nil {
		fmt.eprintf("SDL_CreateGPUDevice failed for the offscreen material sweep: %s\n", sdl3.GetError())
		return false
	}
	defer sdl3.DestroyGPUDevice(device)
	if !sdl3.SetGPUAllowedFramesInFlight(device, 2) { return false }
	fmt.printf("[alicorn-material-offscreen] driver=%s passes=%d warmup=%d\n",
		sdl3.GetGPUDeviceDriver(device), OFF_PASSES, OFF_WARMUP)

	rt := alicorn.new_runtime(alicorn.Rect{0, 0, MATERIAL_STREAM_WIDTH, MATERIAL_STREAM_HEIGHT})
	defer alicorn.destroy_runtime(&rt)
	scene := Material_Scene{}
	material_scene_register(&scene, &rt)
	if scene.material == alicorn.MATERIAL_FLAT {
		fmt.eprintln("relief material registration failed")
		return false
	}
	text, text_ok := host.native_text_make(device, .R8G8B8A8_UNORM, &rt)
	if !text_ok { return false }
	defer host.native_text_destroy(&text)
	surface, surface_ok := host.native_surface_make(device, .R8G8B8A8_UNORM, &rt)
	if !surface_ok { return false }
	defer host.native_surface_destroy(&surface)

	display := make([dynamic]alicorn.Paint_Command, 0,
		MATERIAL_STREAM_CARDS+MATERIAL_STREAM_ROWS, context.temp_allocator)
	defer delete(display)

	scales := MATERIAL_STREAM_SCALES
	only_treatment, has_treatment := parse_arg("--treatment=")
	only_condition, has_condition := parse_arg("--condition=")
	only_scale, has_scale := parse_arg("--scale=")
	scale_filter: f32 = 0
	if has_scale {
		if parsed, ok := strconv.parse_f32(only_scale); ok { scale_filter = parsed }
	}
	for scale in scales {
		if scale_filter > 0 && abs(scale-scale_filter) > 0.001 { continue }
		target := sdl3.CreateGPUTexture(device, sdl3.GPUTextureCreateInfo{
			type=.D2, format=.R8G8B8A8_UNORM,
			usage=sdl3.GPUTextureUsageFlags{.COLOR_TARGET, .SAMPLER},
			width=sdl3.Uint32(f32(MATERIAL_STREAM_WIDTH)*scale),
			height=sdl3.Uint32(f32(MATERIAL_STREAM_HEIGHT)*scale),
			layer_count_or_depth=1, num_levels=1, sample_count=._1,
		})
		if target == nil {
			fmt.eprintln("offscreen target texture creation failed")
			return false
		}
		defer sdl3.ReleaseGPUTexture(device, target)
		for treatment in TREATMENTS {
			if has_treatment && treatment.name != only_treatment { continue }
			scene.treatment = treatment
			for condition in CONDITIONS {
				if has_condition && condition_name(condition) != only_condition { continue }
				scene.condition = condition
				if condition == .Idle {
					fmt.printf(
						"[alicorn-material-offscreen] treatment=%s condition=idle scale=%.2f passes=0 note=not_applicable_no_host_loop\n",
						treatment.name, scale,
					)
					continue
				}
				if !off_run_config(device, &rt, &text, &surface, &scene, condition, scale,
					target, &display) {
					fmt.eprintf("offscreen config failed: %s/%s/%.2f\n",
						treatment.name, condition_name(condition), scale)
					return false
				}
			}
		}
	}
	return true
}
