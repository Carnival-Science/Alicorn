#+build !js
package webgpu_feasibility

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "vendor:wgpu"
import SDL "vendor:sdl3"
import "vendor:wgpu/sdl3glue"
import alicorn "../../runtime"
import native_sdl3_host "../../host/sdl3"

OS :: struct {
	window: ^SDL.Window,
}

native_hosted_application: native_sdl3_host.SDL3_WebGPU_Application

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
		when FEASIBILITY_TEST_SURFACE_PRESENTER {
			if state.ready && state.surface_present_count > 0 && state.surface_motion_active {
				_ = surface_runtime_motion_tick(dt)
			}
		}
		when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
			if state.ready && state.native_hosted_ready {
				hosted_step := native_sdl3_host.sdl3_webgpu_application_step(
					&native_hosted_application, u64(SDL.GetTicksNS()),
				)
				step, presentation := hosted_step, hosted_step.presentation
				if step.status != .Ok {
					fmt.panicf("native Hosted_Runtime step failed: %v", step.status)
				}
				if presentation == .Invalid_Input || presentation == .Resource_Failure ||
				   presentation == .Render_Failure || presentation == .Surface_Acquire_Failure ||
				   presentation == .Present_Failure {
					fmt.panicf("native hosted surface presentation failed: %v", presentation)
				}
				if presentation == .Ok {
					state.native_hosted_presented = true
					state.native_hosted_present_count += 1
					if state.native_hosted_resize_applied && !state.native_hosted_resize_presented {
						state.native_hosted_resize_presented = true
						when FEASIBILITY_TEST_NATIVE_HOSTED_SMOKE {
							fmt.printf("[webgpu-feasibility] native hosted resize presentation PASS pixel=%dx%d\n",
								state.width, state.height)
						}
					}
				}
				state.native_hosted_has_more_work = step.has_more_work
				state.native_hosted_next_wake_ns = step.next_wake_ns
				when FEASIBILITY_TEST_NATIVE_HOSTED_SMOKE {
					if state.native_hosted_presented && !state.native_hosted_smoke_click_sent {
						native_hosted_smoke_click_button()
						state.native_hosted_smoke_click_sent = true
					}
					if state.native_hosted_app.click_count > 0 && !state.native_hosted_app.text_key_passed {
						native_hosted_smoke_generic_text_key()
					}
					if state.native_hosted_app.click_count > 0 && !state.native_hosted_app.text_input_passed {
						native_hosted_smoke_text_and_ime()
					}
					if state.native_hosted_app.click_count > 0 && !state.native_hosted_smoke_resize_requested {
						state.native_hosted_smoke_resize_requested = true
						fmt.println("[webgpu-feasibility] native hosted pointer activation PASS; requesting SDL resize")
						if !SDL.SetWindowSize(state.os.window, 800, 450) {
							fmt.panicf("native Hosted_Runtime smoke could not request its resize: %s", SDL.GetError())
						}
					}
				}
			}
		} else {
		if state.ready && (state.dirty || state.animation_seconds<ANIMATION_SECONDS) {
			if !state.surface_presenter_completion_pending {
				state.animation_seconds+=dt
				state.dirty=false
				render_surface_frame()
			}
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
		when FEASIBILITY_TEST_NATIVE_HOSTED_SMOKE {
			if state.native_hosted_presented &&
			   state.native_hosted_resize_presented &&
			   !native_sdl3_host.sdl3_webgpu_application_has_in_flight(&native_hosted_application) &&
			   !state.readback_pending && !state.queue_work_done_pending {
				state.quit = true
			}
			smoke_elapsed += f64(dt)
			if smoke_elapsed >= SMOKE_TIMEOUT_SECONDS && !state.quit {
				fmt.println("[webgpu-feasibility] native Hosted_Runtime presenter smoke timed out")
				state.quit = true
			}
		}
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
		needs_wakeup = needs_wakeup || state.surface_presenter_completion_pending
		when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
			needs_wakeup = needs_wakeup || native_sdl3_host.sdl3_webgpu_application_has_in_flight(&native_hosted_application)
			needs_wakeup = needs_wakeup || state.native_hosted_has_more_work
		}
		when FEASIBILITY_TEST_SURFACE_PRESENTER {
			needs_wakeup = needs_wakeup || state.surface_motion_active || (state.ready && state.surface_present_count == 0)
		}
		when FEASIBILITY_TEST_RESIZE {
			needs_wakeup = needs_wakeup || (state.ready && (!state.test_resize_pre_frame || !state.test_resize_post_frame))
		}
		when FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY {
			needs_wakeup = needs_wakeup || (!state.ready && !state.device_lost)
		}
		if needs_wakeup {
			wait_timeout_ms := 16
			when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
				if state.native_hosted_ready {
					now_ns := u64(SDL.GetTicksNS())
					if state.native_hosted_has_more_work {
						wait_timeout_ms = 0
					} else if deadline := state.native_hosted_next_wake_ns; deadline > now_ns {
						wait_timeout_ms = min(1000, max(1, int((deadline-now_ns+999_999)/1_000_000)))
					} else if deadline != 0 {
						wait_timeout_ms = 0
					}
				}
			}
			if SDL.WaitEventTimeout(&event, SDL.Sint32(wait_timeout_ms)) { handle_event(event) }
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
	case .WINDOW_HIDDEN,.WINDOW_MINIMIZED:
		when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
				_ = native_sdl3_host.sdl3_webgpu_application_set_visible(&native_hosted_application, false)
		}
	case .WINDOW_SHOWN,.WINDOW_RESTORED:
		when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
				_ = native_sdl3_host.sdl3_webgpu_application_set_visible(&native_hosted_application, true)
		}
	case .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST, .KEY_DOWN, .KEY_UP,
	     .MOUSE_MOTION, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_WHEEL:
		when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
			result := native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, event)
			if result == .Failure { fmt.panicf("native SDL3/WebGPU event routing failed for %v", event.type) }
		}
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
	needs_poll := state.readback_pending || state.queue_work_done_pending || state.surface_presenter_completion_pending
	when FEASIBILITY_TEST_NATIVE_HOSTED_PRESENTER {
		needs_poll = needs_poll || native_sdl3_host.sdl3_webgpu_application_has_in_flight(&native_hosted_application)
	}
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

native_hosted_init :: proc() {
	state.native_hosted_app = {}
	host_config := alicorn.Hosted_Runtime_Config{
		state=rawptr(&state.native_hosted_app),
		render=native_hosted_render,
		on_initialize=native_hosted_initialize_runtime,
		on_text_change=native_hosted_text_change,
		on_text_key=native_hosted_text_key,
	}
	if result := native_sdl3_host.sdl3_webgpu_application_init(
		&native_hosted_application,
		host_config,
		state.os.window,
		state.surface,
		state.device,
		state.queue,
		state.config,
	); result != .Ok {
		fmt.panicf("native SDL3/WebGPU application initialization failed: %v", result)
	}
	state.native_hosted_ready = true
	state.animation_seconds = ANIMATION_SECONDS
	state.dirty = false
	fmt.println("[webgpu-feasibility] SDL3 native host uses shared Hosted_Runtime WebGPU surface presenter")
}

native_hosted_text_change :: proc(data: rawptr, _rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^Native_Hosted_Feasibility_App)data
	if app != nil && change.changed { app.text_change_count += 1 }
}

native_hosted_text_key :: proc(
	data: rawptr,
	_rt: ^alicorn.Runtime,
	owner: alicorn.Node_ID,
	event: alicorn.Application_Text_Key_Event,
) -> bool {
	app := cast(^Native_Hosted_Feasibility_App)data
	if app == nil { return false }
	app.text_key_count += 1
	app.text_key_passed = owner == app.generic_text_owner && event.key == .Left
	return app.text_key_passed
}

native_hosted_resize :: proc() {
	logical_width, logical_height: i32
	pixel_width, pixel_height: i32
	if !SDL.GetWindowSize(state.os.window, &logical_width, &logical_height) ||
	   !SDL.GetWindowSizeInPixels(state.os.window, &pixel_width, &pixel_height) {
		fmt.panicf("native Hosted_Runtime could not query resized window metrics")
	}
	if logical_width < 0 || logical_height < 0 || pixel_width < 0 || pixel_height < 0 { return }
	state.width, state.height = u32(pixel_width), u32(pixel_height)
	if state.native_hosted_smoke_resize_requested && !state.native_hosted_resize_applied &&
	   logical_width == 800 && logical_height == 450 {
		state.native_hosted_resize_applied = true
		fmt.printf("[webgpu-feasibility] native hosted SDL resize applied PASS logical=%dx%d pixel=%dx%d\n",
			logical_width, logical_height, pixel_width, pixel_height)
	}
	result := native_sdl3_host.sdl3_webgpu_application_resize(&native_hosted_application)
	if result != .Ok && result != .Suspended {
		fmt.panicf("native Hosted_Runtime resize failed: %v", result)
	}
}

native_hosted_initialize_runtime :: proc(_data: rawptr, rt: ^alicorn.Runtime) {
	if !alicorn.text_engine_load_font_role(&rt.text_engine, .UI, FONT_DATA) {
		fmt.panicf("native Hosted_Runtime fixture could not load its UI font")
	}
}

native_hosted_render :: proc(data: rawptr, ui: ^alicorn.UI, _width, _height: int, _dpi: f32) {
	app := cast(^Native_Hosted_Feasibility_App)data
	alicorn.text(
		ui, "Shared Alicorn WebGPU host",
		key=alicorn.key_string("native-hosted-title"),
		style=alicorn.layout_style(.Row, height=42, padding=10),
		text_style=alicorn.Text_Style{font_size=25},
	)
	alicorn.text(
		ui, "SDL3 owns the native window and input; this retained surface uses the same Hosted_Runtime presenter as the browser.",
		key=alicorn.key_string("native-hosted-description"),
		style=alicorn.layout_style(.Row, height=56, padding=10),
		text_style=alicorn.Text_Style{font_size=15, overflow=.Wrap},
	)
	if alicorn.button(
		ui, "Activate retained control",
		key=alicorn.key_string("native-hosted-button"),
		style=alicorn.layout_style(.Row, width=250, height=44, padding=8),
	) {
		app.click_count += 1
	}
	label := "Click the button to verify native pointer routing."
	if app.click_count > 0 { label = "Button input reached Hosted_Runtime." }
	alicorn.text(
		ui, label,
		key=alicorn.key_string("native-hosted-state"),
		style=alicorn.layout_style(.Row, height=34, padding=10),
	)
	alicorn.text_field(
		ui, "seed",
		key=alicorn.key_string("native-hosted-text-field"),
		style=alicorn.layout_style(.Row, width=360, height=40, padding=8),
	)
	app.generic_text_owner, _ = alicorn.button_ex(
		ui, "Application-owned editor surface",
		key="native-hosted-editor",
		explicit_key=true,
		style=alicorn.layout_style(.Row, width=360, height=40, padding=8),
	)
	_ = alicorn.text_input_target(ui, app.generic_text_owner)
}

native_hosted_smoke_click_button :: proc() {
	rt, borrow_status := alicorn.hosted_runtime_borrow(&native_hosted_application.hosted)
	if borrow_status != .Ok || rt == nil { fmt.panicf("native hosted smoke could not borrow its Runtime") }
	id, found := alicorn.node_by_key(rt, alicorn.key_string("native-hosted-button"), .Button)
	if !found { fmt.panicf("native hosted smoke button is absent after its first frame") }
	info, info_found := alicorn.node_info(rt, id)
	if !info_found { fmt.panicf("native hosted smoke button geometry is unavailable") }
	x := info.bounds.x + info.bounds.w * 0.5
	y := info.bounds.y + info.bounds.h * 0.5
	down_status := native_sdl3_host.sdl3_webgpu_application_pointer(&native_hosted_application, alicorn.Pointer_Event{
		kind=.Down, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY,
		click_count=1, timestamp_ns=u64(SDL.GetTicksNS()),
	})
	up_status := native_sdl3_host.sdl3_webgpu_application_pointer(&native_hosted_application, alicorn.Pointer_Event{
		kind=.Up, x=x, y=y, button=alicorn.POINTER_BUTTON_PRIMARY,
		click_count=1, timestamp_ns=u64(SDL.GetTicksNS()),
	})
	if down_status != .Ok || up_status != .Ok {
		fmt.panicf("native hosted smoke pointer activation failed: down=%v up=%v", down_status, up_status)
	}
	state.native_hosted_has_more_work = true
	wake := SDL.Event{type=native_hosted_application.wake_event_type}
	if !SDL.PushEvent(&wake) { fmt.panicf("native hosted smoke could not wake after pointer activation") }
	fmt.printf("[webgpu-feasibility] native hosted pointer routed through Hosted_Runtime PASS target=%d\n", id)
}

native_hosted_smoke_generic_text_key :: proc() {
	rt, borrow_status := alicorn.hosted_runtime_borrow(&native_hosted_application.hosted)
	if borrow_status != .Ok || rt == nil { fmt.panicf("native hosted smoke could not inspect its application editor target") }
	owner := state.native_hosted_app.generic_text_owner
	info, info_found := alicorn.node_info(rt, owner)
	if !info_found || owner == 0 { fmt.panicf("native hosted smoke application text target is missing") }
	window_id := SDL.GetWindowID(state.os.window)
	focus_event := SDL.Event{type=.WINDOW_FOCUS_GAINED}
	focus_event.window.windowID = window_id
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, focus_event) != .Handled {
		fmt.panicf("native Hosted_Runtime could not focus the synthetic editor surface")
	}
	x := info.bounds.x + info.bounds.w * 0.5
	y := info.bounds.y + info.bounds.h * 0.5
	down := SDL.Event{type=.MOUSE_BUTTON_DOWN}
	down.button.windowID = window_id
	down.button.button = 1
	down.button.clicks = 1
	down.button.x, down.button.y = x, y
	up := SDL.Event{type=.MOUSE_BUTTON_UP}
	up.button.windowID = window_id
	up.button.button = 1
	up.button.clicks = 1
	up.button.x, up.button.y = x, y
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, down) != .Handled ||
		native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, up) != .Handled {
		fmt.panicf("native Hosted_Runtime could not focus the synthetic application editor target")
	}
	if native_hosted_application.text_input.owner != owner || !native_hosted_application.text_input.active {
		fmt.panicf("native SDL text-input ownership did not follow the generic editor target")
	}
	left := SDL.Event{type=.KEY_DOWN}
	left.key.windowID = window_id
	left.key.key = SDL.K_LEFT
	left.key.down = true
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, left) != .Handled ||
		!state.native_hosted_app.text_key_passed || state.native_hosted_app.text_key_count != 1 {
		fmt.panicf("native SDL Left did not route to the application-owned editor callback")
	}
	fmt.println("[webgpu-feasibility] native SDL application-owned editor text-key callback PASS")
}

native_hosted_smoke_text_and_ime :: proc() {
	rt, borrow_status := alicorn.hosted_runtime_borrow(&native_hosted_application.hosted)
	if borrow_status != .Ok || rt == nil { fmt.panicf("native hosted smoke could not inspect its text field") }
	field, found := alicorn.node_by_key(rt, alicorn.key_string("native-hosted-text-field"), .Text_Field)
	if !found { fmt.panicf("native hosted smoke text field is absent after its first frame") }
	info, info_found := alicorn.node_info(rt, field)
	if !info_found { fmt.panicf("native hosted smoke text-field geometry is unavailable") }
	window_id := SDL.GetWindowID(state.os.window)
	x := info.bounds.x + info.bounds.w * 0.5
	y := info.bounds.y + info.bounds.h * 0.5
	focus_event := SDL.Event{type=.WINDOW_FOCUS_GAINED}
	focus_event.window.windowID = window_id
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, focus_event) != .Handled {
		fmt.panicf("native Hosted_Runtime could not accept synthetic window focus")
	}

	mouse_down := SDL.Event{type=.MOUSE_BUTTON_DOWN}
	mouse_down.button.windowID = window_id
	mouse_down.button.button = 1
	mouse_down.button.clicks = 1
	mouse_down.button.x, mouse_down.button.y = x, y
	mouse_up := SDL.Event{type=.MOUSE_BUTTON_UP}
	mouse_up.button.windowID = window_id
	mouse_up.button.button = 1
	mouse_up.button.clicks = 1
	mouse_up.button.x, mouse_up.button.y = x, y
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, mouse_down) != .Handled ||
		native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, mouse_up) != .Handled {
		fmt.panicf("native Hosted_Runtime could not focus the synthetic SDL text field")
	}
	if native_hosted_application.text_input.owner != field || !native_hosted_application.text_input.active {
		fmt.panicf("native SDL text input did not follow retained text-field focus")
	}
	if !alicorn.set_text_caret(rt, field, len("seed")) { fmt.panicf("native hosted smoke could not set its key-routing precondition") }
	left := SDL.Event{type=.KEY_DOWN}
	left.key.windowID = window_id
	left.key.key = SDL.K_LEFT
	left.key.down = true
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, left) != .Handled {
		fmt.panicf("native SDL Left did not route through Hosted_Runtime text navigation")
	}
	text_state, text_state_ok := alicorn.text_field_interaction(rt, field)
	if !text_state_ok || text_state.caret != len("see") {
		fmt.panicf("native SDL Left did not move the retained Text_Field caret")
	}
	select_all := SDL.Event{type=.KEY_DOWN}
	select_all.key.windowID = window_id
	select_all.key.key = SDL.K_A
	select_all.key.mod = SDL.KMOD_CTRL
	select_all.key.down = true
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, select_all) != .Handled {
		fmt.panicf("native SDL Control+A did not select the retained Text_Field text")
	}
	text_state, text_state_ok = alicorn.text_field_interaction(rt, field)
	if !text_state_ok || !text_state.has_selection || text_state.selection_start != 0 || text_state.selection_end != len("seed") {
		fmt.panicf("native SDL Control+A produced the wrong Text_Field selection")
	}

	preedit := SDL.Event{type=.TEXT_EDITING}
	preedit.edit.windowID = window_id
	preedit.edit.text = cstring("é")
	preedit.edit.start = 1
	preedit.edit.length = 0
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, preedit) != .Handled {
		fmt.panicf("native Hosted_Runtime rejected SDL IME preedit")
	}
	composition, composition_ok := alicorn.text_field_interaction(rt, field)
	if !composition_ok || !composition.composition_active {
		fmt.panicf("native SDL IME preedit did not reach the retained text field")
	}

	escape := SDL.Event{type=.KEY_DOWN}
	escape.key.windowID = window_id
	escape.key.key = SDL.K_ESCAPE
	escape.key.down = true
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, escape) != .Handled {
		fmt.panicf("Escape did not cancel the native IME composition")
	}
	composition, composition_ok = alicorn.text_field_interaction(rt, field)
	if !composition_ok || composition.composition_active {
		fmt.panicf("Escape left IME composition active in the retained text field")
	}
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, preedit) != .Handled {
		fmt.panicf("native Hosted_Runtime rejected the second SDL IME preedit")
	}
	focus_lost := SDL.Event{type=.WINDOW_FOCUS_LOST}
	focus_lost.window.windowID = window_id
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, focus_lost) != .Handled {
		fmt.panicf("native SDL focus loss did not route through Hosted_Runtime")
	}
	composition, composition_ok = alicorn.text_field_interaction(rt, field)
	if !composition_ok || composition.composition_active || native_hosted_application.text_input.active {
		fmt.panicf("native SDL focus loss did not cancel preedit and stop text input")
	}
	focus_gained := SDL.Event{type=.WINDOW_FOCUS_GAINED}
	focus_gained.window.windowID = window_id
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, focus_gained) != .Handled ||
		!native_hosted_application.text_input.active {
		fmt.panicf("native SDL focus gain did not restore retained text-input ownership")
	}

	commit := SDL.Event{type=.TEXT_INPUT}
	commit.text.windowID = window_id
	commit.text.text = cstring("typed")
	if native_sdl3_host.sdl3_webgpu_application_handle_event(&native_hosted_application, commit) != .Handled {
		fmt.panicf("native Hosted_Runtime rejected committed SDL text")
	}
	value, value_ok := alicorn.text_field_value(rt, field)
	if !value_ok || !strings.contains(value, "typed") || state.native_hosted_app.text_change_count != 1 {
		fmt.panicf("native SDL committed text did not update the authoritative Text_Field")
	}
	state.native_hosted_app.text_input_passed = true
	// The synthetic events run inside the presenter callback, after the outer
	// loop's wake decision. Queue the coordinator's wake event so the pending
	// retained update is described before the smoke can block idle.
	state.native_hosted_has_more_work = true
	wake := SDL.Event{type=native_hosted_application.wake_event_type}
	if !SDL.PushEvent(&wake) { fmt.panicf("native hosted smoke could not queue the SDL wake event") }
	fmt.println("[webgpu-feasibility] native SDL key editing, UTF-8 IME preedit/cancel, focus transfer, and text commit PASS (synthetic events)")
	state.native_hosted_smoke_resize_requested = true
	fmt.println("[webgpu-feasibility] requesting SDL resize after native text/IME input")
	if !SDL.SetWindowSize(state.os.window, 800, 450) {
		fmt.panicf("native Hosted_Runtime smoke could not request its resize: %s", SDL.GetError())
	}
}

native_hosted_shutdown :: proc() {
	if !state.native_hosted_ready { return }
	if native_sdl3_host.sdl3_webgpu_application_has_in_flight(&native_hosted_application) {
		// Keep callback-owned Runtime and presenter state alive until the final
		// native queue serial retires. This wait occurs only during fixture shutdown.
		_ = wgpu.DevicePoll(state.device, true)
		if state.instance != nil { wgpu.InstanceProcessEvents(state.instance) }
	}
	if !native_sdl3_host.sdl3_webgpu_application_destroy(&native_hosted_application) {
		fmt.println("[webgpu-feasibility] native SDL3/WebGPU application is still in flight at shutdown")
		return
	}
	state.native_hosted_ready = false
}

os_exit_failure :: proc() { os.exit(1) }
