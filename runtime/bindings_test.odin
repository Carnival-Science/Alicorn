package alicorn

import "core:testing"

BINDING_TEST_TIMEOUT_NS :: u64(500_000_000)

binding_test_key :: proc(key: Key_Spec, modifiers: Key_Modifiers = {}) -> Binding_Key {
	return Binding_Key{key=key, modifiers=modifiers}
}

binding_test_event :: proc(
	key: Key_Spec,
	modifiers: Key_Modifiers = {},
	composition_active := false,
	text_input_focused := false,
	produces_text := false,
	repeat := false,
) -> Key_Event {
	return Key_Event{
		key=key,
		modifiers=modifiers,
		composition_active=composition_active,
		text_input_focused=text_input_focused,
		produces_text=produces_text,
		repeat=repeat,
	}
}

@(test)
test_binding_conflicts_are_duplicate_prefix_and_scope_deterministic :: proc(t: ^testing.T) {
	single := [][]Binding_Key{
		{binding_test_key(.S, {.Primary})},
	}
	prefix := [][]Binding_Key{
		{binding_test_key(.S, {.Primary}), binding_test_key(.N, {.Primary})},
	}
	duplicate := []Command_Binding{
		{command=Action_ID(10), strokes=single[:], scope="Global"},
		{command=Action_ID(11), strokes=single[:], scope="Global"},
	}
	duplicate_conflicts := binding_conflicts(Binding_Table{bindings=duplicate})
	testing.expect_value(t, len(duplicate_conflicts), 1)
	if len(duplicate_conflicts) == 1 {
		testing.expect_value(t, duplicate_conflicts[0].kind, Binding_Conflict_Kind.Duplicate_Stroke)
		testing.expect_value(t, duplicate_conflicts[0].first, 0)
		testing.expect_value(t, duplicate_conflicts[0].second, 1)
	}
	binding_conflicts_destroy(duplicate_conflicts)

	prefixed := []Command_Binding{
		{command=Action_ID(10), strokes=single[:], scope="Global"},
		{command=Action_ID(12), strokes=prefix[:], scope="Global"},
	}
	prefix_conflicts := binding_conflicts(Binding_Table{bindings=prefixed})
	testing.expect_value(t, len(prefix_conflicts), 1)
	if len(prefix_conflicts) == 1 {
		testing.expect_value(t, prefix_conflicts[0].kind, Binding_Conflict_Kind.Prefix_Ambiguity)
		testing.expect_value(t, prefix_conflicts[0].stroke_count, 1)
	}
	binding_conflicts_destroy(prefix_conflicts)

	scoped := []Command_Binding{
		{command=Action_ID(10), strokes=single[:], scope="Global"},
		{command=Action_ID(13), strokes=single[:], scope="Editor"},
	}
	scope_conflicts := binding_conflicts(Binding_Table{bindings=scoped})
	testing.expect_value(t, len(scope_conflicts), 1)
	if len(scope_conflicts) == 1 {
		testing.expect_value(t, scope_conflicts[0].kind, Binding_Conflict_Kind.Scope_Overlap)
	}
	binding_conflicts_destroy(scope_conflicts)
}

@(test)
test_binding_single_stroke_dispatches_immediately_and_repeat_is_consumed :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{command=Action_ID(7), strokes=[][]Binding_Key{{binding_test_key(.F, {.Primary})}}, scope="Global"},
	}
	state: Binding_State
	binding_state_init(&state, Binding_Table{bindings=bindings, chord_timeout_ns=BINDING_TEST_TIMEOUT_NS})
	result := binding_state_resolve(&state, binding_test_event(.F, {.Primary}), 100)
	testing.expect(t, result.consumed && result.dispatched)
	testing.expect_value(t, result.command, Action_ID(7))
	testing.expect_value(t, state.pending_count, 0)
	repeat := binding_state_resolve(&state, binding_test_event(.F, {.Primary}, repeat=true), 200)
	testing.expect(t, !repeat.consumed && !repeat.dispatched,
		"a repeat of a single-stroke binding falls through instead of firing repeatedly")
}

@(test)
test_binding_chord_completes_and_stale_epoch_is_rejected :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{
			command=Action_ID(20),
			strokes=[][]Binding_Key{{
				binding_test_key(.K, {.Primary}),
				binding_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
	}
	state: Binding_State
	binding_state_init(&state, Binding_Table{bindings=bindings, chord_timeout_ns=BINDING_TEST_TIMEOUT_NS})
	first := binding_state_resolve(&state, binding_test_event(.K, {.Primary}), 100)
	testing.expect(t, first.consumed && first.pending)
	deadline, found := binding_state_deadline(&state)
	testing.expect(t, found && deadline == 100+BINDING_TEST_TIMEOUT_NS)
	stale_epoch := state.epoch
	second := binding_state_resolve(&state, binding_test_event(.S, {.Primary}), 200)
	testing.expect(t, second.consumed && second.dispatched)
	testing.expect_value(t, second.command, Action_ID(20))
	stale := binding_state_timeout(&state, stale_epoch, 10_000)
	testing.expect(t, !stale.dispatched && !stale.canceled, "a stale wake epoch is ignored")
}

@(test)
test_binding_timeout_dispatches_shorter_exact_match :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{command=Action_ID(30), strokes=[][]Binding_Key{{binding_test_key(.G, {.Primary})}}, scope="Global"},
		{
			command=Action_ID(31),
			strokes=[][]Binding_Key{{
				binding_test_key(.G, {.Primary}), binding_test_key(.G, {.Primary}),
			}},
			scope="Global",
		},
	}
	state: Binding_State
	binding_state_init(&state, Binding_Table{bindings=bindings, chord_timeout_ns=BINDING_TEST_TIMEOUT_NS})
	first := binding_state_resolve(&state, binding_test_event(.G, {.Primary}), 0)
	testing.expect(t, first.pending && !first.dispatched,
		"an exact match that shares a prefix waits for the longer chord")
	epoch := state.epoch
	early := binding_state_timeout(&state, epoch, BINDING_TEST_TIMEOUT_NS-1)
	testing.expect(t, !early.dispatched && !early.canceled, "the deadline cannot fire early")
	timed_out := binding_state_timeout(&state, epoch, BINDING_TEST_TIMEOUT_NS)
	testing.expect(t, timed_out.dispatched)
	testing.expect_value(t, timed_out.command, Action_ID(30))
}

@(test)
test_binding_timeout_cancels_incomplete_chord :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{
			command=Action_ID(40),
			strokes=[][]Binding_Key{{
				binding_test_key(.K, {.Primary}), binding_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
	}
	state: Binding_State
	binding_state_init(&state, Binding_Table{bindings=bindings, chord_timeout_ns=BINDING_TEST_TIMEOUT_NS})
	_ = binding_state_resolve(&state, binding_test_event(.K, {.Primary}), 0)
	epoch := state.epoch
	timed_out := binding_state_timeout(&state, epoch, BINDING_TEST_TIMEOUT_NS)
	testing.expect(t, !timed_out.dispatched && timed_out.canceled)
	testing.expect_value(t, state.pending_count, 0)
}

@(test)
test_binding_unmatched_second_stroke_cancels_and_reprocesses :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{
			command=Action_ID(50),
			strokes=[][]Binding_Key{{
				binding_test_key(.K, {.Primary}), binding_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
		{command=Action_ID(51), strokes=[][]Binding_Key{{binding_test_key(.P, {.Primary})}}, scope="Global"},
	}
	state: Binding_State
	binding_state_init(&state, Binding_Table{bindings=bindings, chord_timeout_ns=BINDING_TEST_TIMEOUT_NS})
	_ = binding_state_resolve(&state, binding_test_event(.K, {.Primary}), 0)
	result := binding_state_resolve(&state, binding_test_event(.P, {.Primary}), 10)
	testing.expect(t, result.consumed && result.dispatched && result.canceled,
		"a non-continuation cancels the chord and is reprocessed as a fresh command")
	testing.expect_value(t, result.command, Action_ID(51))
}

@(test)
test_binding_text_and_composition_precedence :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{command=Action_ID(60), strokes=[][]Binding_Key{{binding_test_key(.A)}}, scope="Global"},
		{
			command=Action_ID(61), strokes=[][]Binding_Key{{binding_test_key(.B)}},
			scope="Global", preempt_text=true,
		},
		{
			command=Action_ID(62), strokes=[][]Binding_Key{{binding_test_key(.C, {.Primary})}},
			scope="Global", preempt_text=true, allow_during_composition=true,
		},
		{
			command=Action_ID(63), strokes=[][]Binding_Key{{binding_test_key(.D, {.Primary})}},
			scope="Global",
		},
	}
	state: Binding_State
	binding_state_init(&state, Binding_Table{bindings=bindings, chord_timeout_ns=BINDING_TEST_TIMEOUT_NS})
	testing.expect(t, !binding_state_resolve(&state, binding_test_event(.A, produces_text=true), 0).consumed,
		"a bare letter binding yields to produced text")
	testing.expect(t, binding_state_resolve(&state, binding_test_event(.B, produces_text=true), 1).dispatched,
		"preempt_text opts a binding over produced text")
	testing.expect(t, !binding_state_resolve(&state, binding_test_event(.D, {.Primary}, text_input_focused=true), 2).consumed,
		"a focused text owner keeps keys unless the binding opts in")
	composed := binding_state_resolve(
		&state, binding_test_event(.C, {.Primary}, composition_active=true, text_input_focused=true), 3,
	)
	testing.expect(t, composed.dispatched, "allow_during_composition permits composition-time commands")
}

@(test)
test_binding_composition_cancels_pending_chord :: proc(t: ^testing.T) {
	bindings := []Command_Binding{
		{
			command=Action_ID(70),
			strokes=[][]Binding_Key{{
				binding_test_key(.K, {.Primary}), binding_test_key(.S, {.Primary}),
			}},
			scope="Global",
		},
	}
	state: Binding_State
	binding_state_init(&state, Binding_Table{bindings=bindings, chord_timeout_ns=BINDING_TEST_TIMEOUT_NS})
	_ = binding_state_resolve(&state, binding_test_event(.K, {.Primary}), 0)
	testing.expect(t, state.pending_count == 1)
	result := binding_state_resolve(&state, binding_test_event(.S, {.Primary}, composition_active=true), 10)
	testing.expect(t, !result.consumed && state.pending_count == 0,
		"composition clears pending state and suppresses a non-opted binding")
}
