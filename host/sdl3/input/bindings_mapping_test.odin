#+build !js

package sdl3_input

import "core:testing"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

@(test)
test_sdl_key_spec_covers_binding_vocabulary :: proc(t: ^testing.T) {
	expect_spec :: proc(t: ^testing.T, code: sdl3.Keycode, expected: alicorn.Key_Spec) {
		spec, mapped := key_spec_from_sdl(code)
		testing.expect(t, mapped, "every vocabulary key maps")
		testing.expect_value(t, spec, expected)
	}
	expect_spec(t, sdl3.K_A, .A)
	expect_spec(t, sdl3.K_Z, .Z)
	expect_spec(t, sdl3.K_7, .Seven)
	expect_spec(t, sdl3.K_F12, .F12)
	expect_spec(t, sdl3.K_PAGEDOWN, .Page_Down)
	expect_spec(t, sdl3.K_KP_ENTER, .Return)
	expect_spec(t, sdl3.K_LEFTBRACKET, .Left_Bracket)
	_, mapped := key_spec_from_sdl(sdl3.K_UNKNOWN)
	testing.expect(t, !mapped)
}

@(test)
test_sdl_key_event_normalizes_one_contract :: proc(t: ^testing.T) {
	// SDL reports Control as KMOD_CTRL and Command as KMOD_GUI. Primary is
	// Control on Windows/Linux and Command on macOS, matching the binding
	// vocabulary the host normalizes to.
	primary_mod := sdl3.KMOD_CTRL
	when ODIN_OS == .Darwin { primary_mod = sdl3.KMOD_GUI }
	event := sdl3.KeyboardEvent{
		scancode=sdl3.Scancode.S,
		key=sdl3.K_S,
		mod=primary_mod | sdl3.KMOD_SHIFT,
		repeat=true,
		timestamp=12345,
	}
	native := key_event_from_sdl(event, false, false)
	testing.expect_value(t, native.scancode, u32(sdl3.Scancode.S))
	testing.expect_value(t, native.key, alicorn.Key_Spec.S)
	testing.expect(t, alicorn.Menu_Modifier.Primary in native.modifiers)
	testing.expect(t, alicorn.Menu_Modifier.Shift in native.modifiers)
	testing.expect(t, native.repeat)
	testing.expect_value(t, native.timestamp_ns, u64(12345))
	testing.expect(t, !native.produces_text, "a Primary chord is a command, not text")

	plain := key_event_from_sdl(sdl3.KeyboardEvent{key=sdl3.K_S, mod={}}, false, false)
	testing.expect(t, plain.produces_text, "an unmodified letter produces text")
	focused := key_event_from_sdl(sdl3.KeyboardEvent{key=sdl3.K_S, mod={}}, true, false)
	testing.expect(t, focused.text_input_focused)
	composed := key_event_from_sdl(sdl3.KeyboardEvent{key=sdl3.K_S, mod={}}, true, true)
	testing.expect(t, composed.composition_active && !composed.produces_text)

	bridged := key_event_with_application_key(plain, .Find)
	testing.expect(t, bridged.has_application_key)
	testing.expect_value(t, bridged.application_key, alicorn.Application_Key.Find)
}
