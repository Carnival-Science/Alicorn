#+build !js
package webgpu_feasibility

import "core:fmt"
import "core:os"
import "vendor:wgpu"
import SDL "vendor:sdl3"
import "vendor:wgpu/sdl3glue"

OS :: struct { window: ^SDL.Window }

os_init :: proc() {
	if !SDL.Init({.VIDEO}) { fmt.panicf("SDL init failed: %s",SDL.GetError()) }
	state.os.window=SDL.CreateWindow("Alicorn WebGPU feasibility",960,540,{.RESIZABLE,.HIGH_PIXEL_DENSITY})
	if state.os.window==nil { fmt.panicf("SDL window creation failed: %s",SDL.GetError()) }
}

os_run :: proc() {
	last:=SDL.GetPerformanceCounter()
	for !state.quit {
		begin_test_device_loss()
		now:=SDL.GetPerformanceCounter()
		dt:=f32(f64(now-last)/f64(SDL.GetPerformanceFrequency()))
		last=now
		if state.ready && (state.dirty || state.animation_seconds<ANIMATION_SECONDS) {
			state.animation_seconds+=dt
			render_surface_frame()
			state.dirty=false
		}
		event:SDL.Event
		for SDL.PollEvent(&event) { handle_event(event) }
		os_process_gpu_events()
		if state.quit { break }
		needs_wakeup := state.readback_pending || state.queue_work_done_pending || state.animation_seconds < ANIMATION_SECONDS
		when FEASIBILITY_TEST_DEVICE_LOSS {
			needs_wakeup = needs_wakeup || (!state.ready && !state.device_lost)
		}
		if needs_wakeup {
			if SDL.WaitEventTimeout(&event, 16) { handle_event(event) }
		} else if SDL.WaitEvent(&event) {
			handle_event(event)
		}
	}
	finish()
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
	when FEASIBILITY_TEST_DEVICE_LOSS {
		needs_poll = needs_poll || (!state.ready && !state.device_lost)
	}
	if state.device != nil && needs_poll {
		// Native wgpu-native needs an explicit nonblocking device poll to drive
		// device-scoped callbacks. Poll only while an async operation is pending;
		// settled native windows block in SDL_WaitEvent.
		_ = wgpu.DevicePoll(state.device, false)
		when FEASIBILITY_TEST_DEVICE_LOSS {
			if !state.ready && !state.device_lost && !state.native_loss_wait_probed {
				state.native_loss_wait_probed = true
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
