#+build !js
package webgpu_feasibility

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "vendor:wgpu"
import SDL "vendor:sdl3"
import "vendor:wgpu/sdl3glue"

OS :: struct { window: ^SDL.Window }

SMOKE_TIMEOUT_SECONDS :: 15.0

os_requested_backend :: proc() -> (wgpu.BackendType, bool) {
	for argument in os.args {
		if argument == "--backend=d3d12" { return .D3D12, true }
		if argument == "--backend=vulkan" { return .Vulkan, true }
		if strings.has_prefix(argument, "--backend=") {
			return .Undefined, false
		}
	}
	return .Undefined, true
}

os_init :: proc() {
	if !SDL.Init({.VIDEO}) { fmt.panicf("SDL init failed: %s",SDL.GetError()) }
	state.os.window=SDL.CreateWindow("Alicorn WebGPU feasibility",960,540,{.RESIZABLE,.HIGH_PIXEL_DENSITY})
	if state.os.window==nil { fmt.panicf("SDL window creation failed: %s",SDL.GetError()) }
}

os_run :: proc() {
	last:=SDL.GetPerformanceCounter()
	smoke_elapsed:=0.0
	for !state.quit {
		begin_test_explicit_device_destroy()
		now:=SDL.GetPerformanceCounter()
		dt:=f32(f64(now-last)/f64(SDL.GetPerformanceFrequency()))
		last=now
		if state.ready && (state.dirty || state.animation_seconds<ANIMATION_SECONDS) {
			state.animation_seconds+=dt
			state.dirty=false
			render_surface_frame()
			when FEASIBILITY_TEST_RESIZE {
				if state.test_resize_pre_applied && !state.test_resize_pre_frame &&
					state.surface_present_count>state.test_resize_pre_present_before {
					state.test_resize_pre_frame=true
					fmt.printf("[webgpu-feasibility] during-animation SurfacePresent submitted at %dx%d\n",state.config.width,state.config.height)
				}
				if state.test_resize_post_applied && !state.test_resize_post_frame &&
					state.surface_present_count>state.test_resize_post_present_before {
					state.test_resize_post_frame=true
					fmt.printf("[webgpu-feasibility] post-animation SurfacePresent submitted at %dx%d\n",state.config.width,state.config.height)
					if smoke_complete() ||
					   (state.readback_callback_received && state.queue_work_done && state.surface_cache_pressure_serial >= 4) {
						state.quit=true
					}
				}
			}
		}
		when FEASIBILITY_TEST_RESIZE {
			if state.ready && !state.test_resize_pre_requested && state.animation_seconds>=0.30 && state.animation_seconds<ANIMATION_SECONDS {
				state.test_resize_pre_requested=true
				state.test_resize_pre_present_before=state.surface_present_count
				fmt.println("[webgpu-feasibility] requesting resize during animation to 800x450")
				if !SDL.SetWindowSize(state.os.window,800,450) {
					fmt.printf("[webgpu-feasibility] SDL_SetWindowSize failed: %s\n",SDL.GetError())
					state.quit=true
				}
			}
			if state.ready && state.animation_seconds>=ANIMATION_SECONDS && !state.test_resize_post_requested {
				state.test_resize_post_delay+=dt
				if state.test_resize_post_delay>=0.25 {
					state.test_resize_post_requested=true
					state.test_resize_post_present_before=state.surface_present_count
					fmt.println("[webgpu-feasibility] requesting resize after animation to 720x405")
					if !SDL.SetWindowSize(state.os.window,720,405) {
						fmt.printf("[webgpu-feasibility] SDL_SetWindowSize failed: %s\n",SDL.GetError())
						state.quit=true
					}
				}
			}
		}
		event:SDL.Event
		for SDL.PollEvent(&event) { handle_event(event) }
		os_process_gpu_events()
		when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
			if sync.atomic_load(&state.device_lost_callback_count) > 0 {
				state.device_lost = true
				state.ready = false
				state.quit = true
			}
		}
		when FEASIBILITY_TEST_QUIT_AFTER_READBACK {
			smoke_elapsed += f64(dt)
			if smoke_elapsed >= SMOKE_TIMEOUT_SECONDS && !smoke_complete() {
				fmt.printf("[webgpu-feasibility] bounded smoke timed out after %.1f seconds (readback_done=%v queue_done=%v queue_ok=%v cache_inflight=%v cache_final=%v)\n",
					SMOKE_TIMEOUT_SECONDS,
					state.readback_done,
					state.queue_work_done,
					state.queue_work_done_ok,
					state.surface_cache_pressure_inflight_passed,
					state.surface_cache_pressure_passed,
				)
				state.quit = true
			}
		}
		when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
			smoke_elapsed += f64(dt)
			if smoke_elapsed >= SMOKE_TIMEOUT_SECONDS && !state.device_lost {
				fmt.printf("[webgpu-feasibility] explicit-destroy callback probe timed out after %.1f seconds (triggered=%v callbacks=%d)\n",
					SMOKE_TIMEOUT_SECONDS,
					state.test_explicit_destroy_triggered,
					sync.atomic_load(&state.device_lost_callback_count),
				)
				state.quit = true
			}
		}
		if state.quit { break }
		needs_wakeup := state.dirty || state.readback_pending || state.queue_work_done_pending || state.animation_seconds < ANIMATION_SECONDS
		when FEASIBILITY_TEST_RESIZE {
			needs_wakeup = needs_wakeup || (state.ready && (!state.test_resize_pre_frame || !state.test_resize_post_frame))
		}
		when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
			needs_wakeup = needs_wakeup || (!state.ready && !state.device_lost)
		}
		if needs_wakeup {
			if SDL.WaitEventTimeout(&event, 16) { handle_event(event) }
		} else if SDL.WaitEvent(&event) {
			handle_event(event)
		}
	}
	when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
		callback_count := sync.atomic_load(&state.device_lost_callback_count)
		reason := wgpu.DeviceLostReason(sync.atomic_load(&state.device_loss_reason_raw))
		state.test_explicit_destroy_callback_passed = state.test_explicit_destroy_triggered && state.device_lost &&
			callback_count == 1 && reason == .Destroyed
		if !state.test_explicit_destroy_callback_passed {
			fmt.printf("[webgpu-feasibility] explicit-destroy callback probe FAIL before teardown (triggered=%v invalidated=%v reason=%v callbacks=%d; expected exactly one Destroyed callback)\n",
				state.test_explicit_destroy_triggered,
				state.device_lost,
				reason,
				callback_count,
			)
		}
	}
	finish()
	when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
		callback_count_after_teardown := sync.atomic_load(&state.device_lost_callback_count)
		if !state.test_explicit_destroy_callback_passed || callback_count_after_teardown != 1 {
			fmt.printf("[webgpu-feasibility] explicit-destroy callback probe FAIL after teardown (passed_before_teardown=%v callbacks=%d)\n",
				state.test_explicit_destroy_callback_passed,
				callback_count_after_teardown,
			)
			os_exit_failure()
		}
		fmt.println("[webgpu-feasibility] explicit-destroy callback probe PASS: exactly one reason=Destroyed callback before teardown; this is not driver/OS loss evidence")
	}
	SDL.DestroyWindow(state.os.window)
	SDL.Quit()
}

handle_event :: proc(event:SDL.Event) {
	#partial switch event.type {
	case .QUIT: state.quit=true
	case .WINDOW_RESIZED,.WINDOW_PIXEL_SIZE_CHANGED: resize()
	}
}

os_get_framebuffer_size :: proc()->(width,height:u32) {
	w,h:i32
	SDL.GetWindowSizeInPixels(state.os.window,&w,&h)
	return u32(max(w,1)),u32(max(h,1))
}
os_set_surface_size :: proc(width,height:u32) {}
os_get_surface :: proc(instance:wgpu.Instance)->wgpu.Surface {
	return sdl3glue.GetSurface(instance,state.os.window)
}
os_process_gpu_events :: proc() {
	needs_poll := state.readback_pending || state.queue_work_done_pending
	when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
		needs_poll = needs_poll || (!state.ready && !state.device_lost)
	}
	if state.device != nil && needs_poll {
		// Native wgpu-native needs an explicit nonblocking device poll to drive
		// device-scoped callbacks. Poll only while an async operation is pending;
		// settled native windows block in SDL_WaitEvent.
		_ = wgpu.DevicePoll(state.device, false)
		when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
			if !state.ready && !state.device_lost && !state.native_destroy_wait_probed {
				state.native_destroy_wait_probed = true
				queue_empty := wgpu.DevicePoll(state.device, true)
				fmt.printf("[webgpu-feasibility] blocking device poll returned queue_empty=%v device_lost=%v\n", queue_empty, state.device_lost)
				// Finish through the normal teardown path after the diagnostic poll;
				// DeviceRelease may also drive any final native callbacks.
				state.quit = true
			}
		}
	}
	if state.instance != nil && needs_poll {
		wgpu.InstanceProcessEvents(state.instance)
	}
}

os_exit_failure :: proc() { os.exit(1) }
