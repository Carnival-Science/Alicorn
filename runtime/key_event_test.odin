package alicorn

import "core:testing"

@(test)
test_key_event_contract_is_host_neutral_value_data :: proc(t: ^testing.T) {
	native := Key_Event{
		scancode=42,
		key=.S,
		modifiers={.Primary},
		repeat=false,
		composition_active=false,
		text_input_focused=false,
		produces_text=false,
		timestamp_ns=123,
		application_key=.Find,
		has_application_key=true,
	}
	headless := native
	headless.scancode = 0
	testing.expect_value(t, headless.key, Key_Spec.S)
	testing.expect_value(t, headless.modifiers, Key_Modifiers{.Primary})
	testing.expect(t, key_binding_matches(headless.key, headless.modifiers, .S, {.Primary}))
	testing.expect(t, !key_binding_matches(headless.key, headless.modifiers, .S, {.Primary, .Shift}),
		"binding modifier matching is exact")
	testing.expect(t, !key_binding_matches(headless.key, headless.modifiers, .A, {.Primary}))
}

@(test)
test_key_event_produced_text_policy :: proc(t: ^testing.T) {
	testing.expect(t, key_event_produces_text(.A, {}))
	testing.expect(t, key_event_produces_text(.Space, {.Shift}))
	testing.expect(t, !key_event_produces_text(.A, {.Primary}))
	testing.expect(t, !key_event_produces_text(.A, {.Super}))
	testing.expect(t, !key_event_produces_text(.Return, {}))
	testing.expect(t, !key_event_produces_text(.Tab, {}))
	testing.expect(t, !key_event_produces_text(.F5, {}))
}
