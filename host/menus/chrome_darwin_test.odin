#+build darwin

package host_menus

import "core:testing"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

// The hosted macOS pointer-sample translation is compile-checked on Windows but
// can only be executed on a Mac. These tests mirror the reference host's
// coverage so a physical macOS run exercises the same pairing rules.
@(test)
test_darwin_titlebar_pointer_samples_pair_native_points_with_sdl_events :: proc(t: ^testing.T) {
	adapter: Native_Menu_Adapter
	state := Darwin_Menu_State{}
	state.titlebar.active = true
	adapter.platform_data = rawptr(&state)

	darwin_titlebar_pointer_sample_push(&state.titlebar.pointer_samples, sdl3.Point{29, 321}, {})
	darwin_titlebar_pointer_sample_push(&state.titlebar.pointer_samples, sdl3.Point{400, 19}, {})
	darwin_titlebar_pointer_sample_push(&state.titlebar.pointer_samples, sdl3.Point{400, 19}, {.LEFT})
	darwin_titlebar_pointer_sample_push(&state.titlebar.pointer_samples, sdl3.Point{410, 24}, {})

	press_event := sdl3.Event{}
	press_event.button = sdl3.MouseButtonEvent{
		commonEvent=sdl3.CommonEvent{type=.MOUSE_BUTTON_DOWN},
		button=sdl3.BUTTON_LEFT,
		down=true,
	}
	press := darwin_titlebar_translate_pointer(
		&adapter,
		alicorn.Pointer_Event{kind=.Down, x=999, y=999},
		press_event,
	)
	testing.expect(t, press.x == 400 && press.y == 19,
		"pointer press skips an unpaired hover sample and uses the native press point")

	release_event := sdl3.Event{}
	release_event.button = sdl3.MouseButtonEvent{
		commonEvent=sdl3.CommonEvent{type=.MOUSE_BUTTON_UP},
		button=sdl3.BUTTON_LEFT,
	}
	release := darwin_titlebar_translate_pointer(
		&adapter,
		alicorn.Pointer_Event{kind=.Up, x=999, y=999},
		release_event,
	)
	testing.expect(t, release.x == 410 && release.y == 24,
		"pointer release consumes the remaining native sample")
}

@(test)
test_darwin_titlebar_consumed_sample_cancels_gesture :: proc(t: ^testing.T) {
	adapter: Native_Menu_Adapter
	state := Darwin_Menu_State{}
	state.titlebar.active = true
	state.titlebar.gesture_owner = .Window
	adapter.platform_data = rawptr(&state)

	darwin_titlebar_pointer_sample_push(&state.titlebar.pointer_samples, sdl3.Point{620, 22}, {.LEFT})
	darwin_titlebar_pointer_sample_push(&state.titlebar.pointer_samples, sdl3.Point{180, 22}, {})

	native_menu_adapter_note_window_hit_test(&adapter)
	testing.expect(t, state.titlebar.gesture_owner == .Window,
		"a consumed press sample keeps the drag owner latched")

	native_menu_adapter_note_window_hit_test(&adapter)
	testing.expect(t, state.titlebar.gesture_owner == .None &&
		state.titlebar.pointer_samples.count == 0,
		"a consumed release sample drains the ring and clears gesture ownership")
}

@(test)
test_darwin_titlebar_translation_falls_back_to_last_hit_test_point :: proc(t: ^testing.T) {
	adapter: Native_Menu_Adapter
	state := Darwin_Menu_State{}
	state.titlebar.active = true
	state.titlebar.last_sdl_pointer_point = sdl3.Point{75, 18}
	state.titlebar.last_sdl_pointer_valid = true
	adapter.platform_data = rawptr(&state)

	motion_event := sdl3.Event{}
	motion_event.motion = sdl3.MouseMotionEvent{commonEvent=sdl3.CommonEvent{type=.MOUSE_MOTION}}
	point := darwin_titlebar_translate_pointer(
		&adapter,
		alicorn.Pointer_Event{kind=.Move, x=1, y=2},
		motion_event,
	)
	testing.expect(t, point.x == 75 && point.y == 18,
		"client pointer events fall back to the last native hit-test point")
}
