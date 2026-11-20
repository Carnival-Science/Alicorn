#+build !js

package sdl3_input

import "core:testing"
import "vendor:sdl3"

@(test)
test_sdl_event_window_ownership_covers_window_input_text_drop_and_global_events :: proc(t: ^testing.T) {
	CHILD :: sdl3.WindowID(42)
	event := sdl3.Event{type=.WINDOW_PIXEL_SIZE_CHANGED}
	event.window.windowID = CHILD
	testing.expect(t, event_window_id_from_sdl(event) == CHILD, "window events use the window union's owner")

	event = sdl3.Event{type=.KEY_UP}
	event.key.windowID = CHILD
	testing.expect(t, event_window_id_from_sdl(event) == CHILD, "keyboard events route to their focused window")

	event = sdl3.Event{type=.TEXT_INPUT}
	event.text.windowID = CHILD
	testing.expect(t, event_window_id_from_sdl(event) == CHILD, "committed text routes to its input window")

	event = sdl3.Event{type=.TEXT_EDITING}
	event.edit.windowID = CHILD
	testing.expect(t, event_window_id_from_sdl(event) == CHILD, "IME preedit routes to its input window")

	event = sdl3.Event{type=.TEXT_EDITING_CANDIDATES}
	event.edit_candidates.windowID = CHILD
	testing.expect(t, event_window_id_from_sdl(event) == CHILD, "IME candidate updates route to their input window")

	event = sdl3.Event{type=.MOUSE_MOTION}
	event.motion.windowID = CHILD
	testing.expect(t, event_window_id_from_sdl(event) == CHILD, "pointer motion routes to its source window")

	event = sdl3.Event{type=.MOUSE_BUTTON_DOWN}
	event.button.windowID = CHILD
	testing.expect(t, event_window_id_from_sdl(event) == CHILD, "pointer buttons route to their source window")

	event = sdl3.Event{type=.MOUSE_WHEEL}
	event.wheel.windowID = CHILD
	testing.expect(t, event_window_id_from_sdl(event) == CHILD, "wheel input routes to its source window")

	event = sdl3.Event{type=.DROP_POSITION}
	event.drop.windowID = CHILD
	testing.expect(t, event_window_id_from_sdl(event) == CHILD, "drag-and-drop events route to their source window")

	event = sdl3.Event{type=.CLIPBOARD_UPDATE}
	testing.expect(t, event_window_id_from_sdl(event) == 0, "process-level events stay on the primary host loop")
}
