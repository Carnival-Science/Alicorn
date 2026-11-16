#+build !js

package sdl3_host

import "vendor:sdl3"

// event_window_id_from_sdl returns the owning window for SDL event variants
// that participate in a window's independent input, focus, and scale stream.
// Device-level and process-level events return zero and stay with the primary
// host loop.
event_window_id_from_sdl :: proc(event: sdl3.Event) -> sdl3.WindowID {
	#partial switch event.type {
	case .WINDOW_SHOWN, .WINDOW_HIDDEN, .WINDOW_EXPOSED, .WINDOW_MOVED,
	     .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_METAL_VIEW_RESIZED,
	     .WINDOW_MINIMIZED, .WINDOW_MAXIMIZED, .WINDOW_RESTORED,
	     .WINDOW_MOUSE_ENTER, .WINDOW_MOUSE_LEAVE, .WINDOW_FOCUS_GAINED,
	     .WINDOW_FOCUS_LOST, .WINDOW_CLOSE_REQUESTED, .WINDOW_DISPLAY_CHANGED,
	     .WINDOW_DISPLAY_SCALE_CHANGED, .WINDOW_SAFE_AREA_CHANGED,
	     .WINDOW_ENTER_FULLSCREEN, .WINDOW_LEAVE_FULLSCREEN, .WINDOW_DESTROYED:
		return event.window.windowID
	case .KEY_DOWN, .KEY_UP:
		return event.key.windowID
	case .TEXT_INPUT:
		return event.text.windowID
	case .TEXT_EDITING:
		return event.edit.windowID
	case .TEXT_EDITING_CANDIDATES:
		return event.edit_candidates.windowID
	case .MOUSE_MOTION:
		return event.motion.windowID
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		return event.button.windowID
	case .MOUSE_WHEEL:
		return event.wheel.windowID
	case .DROP_FILE, .DROP_TEXT, .DROP_BEGIN, .DROP_COMPLETE, .DROP_POSITION:
		return event.drop.windowID
	case:
		return 0
	}
}
