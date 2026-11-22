package host_bindings

import "core:testing"
import alicorn "alicorn:runtime"

TEST_TIMEOUT_NS :: u64(400_000_000)

Bindings_Test_State :: struct {
	commands:       [8]alicorn.Action_ID,
	command_count:  int,
	scheduled_ns:   u64,
	schedule_count: int,
	cancel_count:   int,
	scheduled:      bool,
}

bindings_test_dispatch :: proc(data: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID) -> bool {
	state := cast(^Bindings_Test_State)data
	if state == nil { return false }
	if state.command_count < len(state.commands) {
		state.commands[state.command_count] = command
		state.command_count += 1
	}
	return true
}

bindings_test_schedule :: proc(data: rawptr, class: alicorn.Scheduled_Wake_Class, delay_ns: u64) -> bool {
	state := cast(^Bindings_Test_State)data
	if state == nil || class != .Frequent { return false }
	state.scheduled_ns = delay_ns
	state.schedule_count += 1
	state.scheduled = true
	return true
}

bindings_test_cancel_scheduled :: proc(data: rawptr, class: alicorn.Scheduled_Wake_Class) -> bool {
	state := cast(^Bindings_Test_State)data
	if state == nil || class != .Frequent { return false }
	state.cancel_count += 1
	state.scheduled = false
	return true
}

bindings_test_scheduler :: proc(state: ^Bindings_Test_State) -> alicorn.Application_Scheduler {
	return alicorn.Application_Scheduler{
		data=rawptr(state),
		schedule=bindings_test_schedule,
		cancel=bindings_test_cancel_scheduled,
	}
}

bindings_test_key :: proc(key: alicorn.Key_Spec, modifiers: alicorn.Key_Modifiers = {}) -> alicorn.Binding_Key {
	return alicorn.Binding_Key{key=key, modifiers=modifiers}
}

bindings_test_event :: proc(
	key: alicorn.Key_Spec,
	modifiers: alicorn.Key_Modifiers = {},
	composition_active := false,
	text_input_focused := false,
	produces_text := false,
) -> alicorn.Key_Event {
	return alicorn.Key_Event{
		key=key,
		modifiers=modifiers,
		composition_active=composition_active,
		text_input_focused=text_input_focused,
		produces_text=produces_text,
	}
}

@(test)
test_binding_service_single_stroke_dispatches_and_reports_conflicts :: proc(t: ^testing.T) {
	bindings := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(100),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.S, {.Primary})}},
			scope="Global",
			description="Save",
		},
		{
			command=alicorn.Action_ID(101),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.S, {.Primary})}},
			scope="Global",
		},
	}
	test_state: Bindings_Test_State
	service: Binding_Service
	binding_service_init(
		&service,
		alicorn.Binding_Table{bindings=bindings, chord_timeout_ns=TEST_TIMEOUT_NS},
		rawptr(&test_state), bindings_test_dispatch, bindings_test_scheduler(&test_state),
	)
	consumed := binding_service_resolve(
		&service, nil, bindings_test_event(.S, {.Primary}), 10,
	)
	testing.expect(t, consumed)
	testing.expect_value(t, test_state.command_count, 1)
	testing.expect_value(t, test_state.commands[0], alicorn.Action_ID(100))
	testing.expect_value(t, test_state.schedule_count, 0)

	conflicts := binding_service_conflicts(&service)
	defer alicorn.binding_conflicts_destroy(conflicts)
	testing.expect_value(t, len(conflicts), 1)
	if len(conflicts) == 1 {
		testing.expect_value(t, conflicts[0].kind, alicorn.Binding_Conflict_Kind.Duplicate_Stroke)
	}
}

@(test)
test_binding_service_chord_arms_scheduled_wake_and_completes :: proc(t: ^testing.T) {
	bindings := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(110),
			strokes=[][]alicorn.Binding_Key{{
				bindings_test_key(.K, {.Primary}), bindings_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
	}
	test_state: Bindings_Test_State
	service: Binding_Service
	binding_service_init(
		&service,
		alicorn.Binding_Table{bindings=bindings, chord_timeout_ns=TEST_TIMEOUT_NS},
		rawptr(&test_state), bindings_test_dispatch, bindings_test_scheduler(&test_state),
	)
	testing.expect(t, binding_service_resolve(&service, nil, bindings_test_event(.K, {.Primary}), 100))
	testing.expect_value(t, test_state.schedule_count, 1)
	testing.expect_value(t, test_state.scheduled_ns, TEST_TIMEOUT_NS)
	testing.expect_value(t, len(binding_service_pending(&service)), 1)

	testing.expect(t, binding_service_resolve(&service, nil, bindings_test_event(.S, {.Primary}), 200))
	testing.expect_value(t, test_state.command_count, 1)
	testing.expect_value(t, test_state.commands[0], alicorn.Action_ID(110))
	testing.expect_value(t, len(binding_service_pending(&service)), 0)
	testing.expect_value(t, test_state.cancel_count, 1)
}

@(test)
test_binding_service_timeout_dispatch_and_cancel :: proc(t: ^testing.T) {
	short := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(120),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.G, {.Primary})}},
			scope="Global",
		},
		{
			command=alicorn.Action_ID(121),
			strokes=[][]alicorn.Binding_Key{{
				bindings_test_key(.G, {.Primary}), bindings_test_key(.G, {.Primary}),
			}},
			scope="Global",
		},
	}
	test_state: Bindings_Test_State
	service: Binding_Service
	binding_service_init(
		&service,
		alicorn.Binding_Table{bindings=short, chord_timeout_ns=TEST_TIMEOUT_NS},
		rawptr(&test_state), bindings_test_dispatch, bindings_test_scheduler(&test_state),
	)
	testing.expect(t, binding_service_resolve(&service, nil, bindings_test_event(.G, {.Primary}), 0))
	testing.expect(t, !binding_service_timeout(&service, nil, TEST_TIMEOUT_NS-1))
	testing.expect(t, binding_service_timeout(&service, nil, TEST_TIMEOUT_NS))
	testing.expect_value(t, test_state.command_count, 1)
	testing.expect_value(t, test_state.commands[0], alicorn.Action_ID(120))

	incomplete := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(122),
			strokes=[][]alicorn.Binding_Key{{
				bindings_test_key(.K, {.Primary}), bindings_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
	}
	test_state = {}
	binding_service_init(
		&service,
		alicorn.Binding_Table{bindings=incomplete, chord_timeout_ns=TEST_TIMEOUT_NS},
		rawptr(&test_state), bindings_test_dispatch, bindings_test_scheduler(&test_state),
	)
	testing.expect(t, binding_service_resolve(&service, nil, bindings_test_event(.K, {.Primary}), 0))
	testing.expect(t, !binding_service_timeout(&service, nil, TEST_TIMEOUT_NS))
	testing.expect_value(t, test_state.command_count, 0)
	testing.expect_value(t, len(binding_service_pending(&service)), 0)
}

@(test)
test_binding_service_cancel_cases_cover_unmatched_text_composition_and_pointer :: proc(t: ^testing.T) {
	bindings := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(130),
			strokes=[][]alicorn.Binding_Key{{
				bindings_test_key(.K, {.Primary}), bindings_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
	}
	test_state: Bindings_Test_State
	service: Binding_Service
	binding_service_init(
		&service,
		alicorn.Binding_Table{bindings=bindings, chord_timeout_ns=TEST_TIMEOUT_NS},
		rawptr(&test_state), bindings_test_dispatch, bindings_test_scheduler(&test_state),
	)
	testing.expect(t, binding_service_resolve(&service, nil, bindings_test_event(.K, {.Primary}), 0))
	testing.expect(t, !binding_service_resolve(&service, nil, bindings_test_event(.Q, {.Primary}), 1))
	testing.expect_value(t, len(binding_service_pending(&service)), 0)

	testing.expect(t, binding_service_resolve(&service, nil, bindings_test_event(.K, {.Primary}), 2))
	testing.expect(t, binding_service_cancel(&service))
	testing.expect_value(t, len(binding_service_pending(&service)), 0)

	testing.expect(t, binding_service_resolve(&service, nil, bindings_test_event(.K, {.Primary}), 3))
	// Composition clears pending before the resolver applies its own policy.
	testing.expect(t, !binding_service_resolve(
		&service, nil, bindings_test_event(.S, {.Primary}, composition_active=true), 4,
	))
	testing.expect_value(t, len(binding_service_pending(&service)), 0)

	// A host cancel path for pointer-down, focus change, or committed text.
	testing.expect(t, binding_service_resolve(&service, nil, bindings_test_event(.K, {.Primary}), 5))
	testing.expect(t, binding_service_cancel(&service))
	testing.expect_value(t, len(binding_service_pending(&service)), 0)
}

@(test)
test_binding_service_rebind_updates_dispatch_and_clears_pending :: proc(t: ^testing.T) {
	first := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(140),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.S, {.Primary})}},
			scope="Global",
		},
		{
			command=alicorn.Action_ID(141),
			strokes=[][]alicorn.Binding_Key{{
				bindings_test_key(.K, {.Primary}), bindings_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
	}
	rebound := []alicorn.Command_Binding{
		{
			command=alicorn.Action_ID(140),
			strokes=[][]alicorn.Binding_Key{{bindings_test_key(.J, {.Primary, .Shift})}},
			scope="Global",
		},
	}
	test_state: Bindings_Test_State
	service: Binding_Service
	binding_service_init(
		&service,
		alicorn.Binding_Table{bindings=first, chord_timeout_ns=TEST_TIMEOUT_NS},
		rawptr(&test_state), bindings_test_dispatch, bindings_test_scheduler(&test_state),
	)
	_ = binding_service_resolve(&service, nil, bindings_test_event(.K, {.Primary}), 0)
	testing.expect_value(t, len(binding_service_pending(&service)), 1)
	binding_service_update(&service, alicorn.Binding_Table{bindings=rebound, chord_timeout_ns=TEST_TIMEOUT_NS})
	testing.expect_value(t, len(binding_service_pending(&service)), 0)
	testing.expect(t, !binding_service_resolve(&service, nil, bindings_test_event(.S, {.Primary}), 10),
		"the old accelerator no longer resolves")
	testing.expect(t, binding_service_resolve(&service, nil, bindings_test_event(.J, {.Primary, .Shift}), 11))
	testing.expect_value(t, test_state.commands[0], alicorn.Action_ID(140))
}
