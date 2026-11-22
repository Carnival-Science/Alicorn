package alicorn

// Application-owned command bindings.
//
// Command identity is Action_ID. The binding surface deliberately introduces no
// command enum: an application can bind a command that Alicorn has never heard
// of, and Action_ID(0) stays the "no command" sentinel.
//
// Storage is borrowed. A Binding_Table and every Command_Binding.strokes slice
// remain owned by the application and must stay valid while a host resolves
// keys or a menu adapter presents accelerators. Hosts read the table on each
// transition instead of snapshotting a second keymap, so an application can
// remap at runtime by updating the same borrowed structures.
//
// Command_Binding.strokes is a list of alternative chord sequences. Each outer
// element is one complete chord; each inner element is the ordered strokes of
// that chord. One single-stroke chord is the ordinary menu-accelerator case.
// A Binding_Key already carries its normalized modifiers, so a stroke is a
// complete key transition.
//
// Chord semantics are deterministic:
//   - The first stroke of a complete single-stroke binding dispatches
//     immediately when no longer binding shares that prefix.
//   - If a longer binding shares the prefix, the stroke is held pending and a
//     host-scheduled deadline is armed. No frame loop polls for it.
//   - A later stroke either completes a binding or cancels the pending chord
//     and is reprocessed from the first stroke, so a missed chord never steals
//     the next command.
//   - At the deadline, a pending sequence that exactly equals a complete
//     binding dispatches that binding (the shorter exact match wins); otherwise
//     the pending chord is canceled.
//   - A focused text owner, produced text, and active IME composition suppress
//     bindings unless the binding opts in with preempt_text or
//     allow_during_composition. Composition always clears pending state first.
//
// scope is an authoring label used by conflict reporting. It does not change
// resolution: the first matching binding in table order wins. That keeps
// dispatch stable while a keymap editor reports overlaps to the user.

DEFAULT_CHORD_TIMEOUT_NS :: u64(1_000_000_000)
MAX_BINDING_CHORD_STROKES :: 8

Binding_Key :: struct {
	key:       Key_Spec,
	modifiers: Key_Modifiers,
}

Command_Binding :: struct {
	command:                  Action_ID,
	strokes:                  [][]Binding_Key,
	// scope names the authoring context, for example "Global" or
	// "Piano Roll". Equal strokes in equal scopes are duplicates; equal strokes
	// in different scopes are reported as Scope_Overlap.
	scope:                    string,
	preempt_text:             bool,
	allow_during_composition: bool,
	description:              string,
}

Binding_Table :: struct {
	bindings:         []Command_Binding,
	chord_timeout_ns: u64,
}

binding_table_timeout :: proc(table: Binding_Table) -> u64 {
	if table.chord_timeout_ns == 0 { return DEFAULT_CHORD_TIMEOUT_NS }
	return table.chord_timeout_ns
}

Binding_Conflict_Kind :: enum {
	Duplicate_Stroke,
	Prefix_Ambiguity,
	Scope_Overlap,
}

// Binding_Conflict indexes the table in its original order. first is always
// less than second, and conflicts are emitted in ascending first/second order,
// so reporting is deterministic across runs.
Binding_Conflict :: struct {
	kind:         Binding_Conflict_Kind,
	first, second: int,
	// stroke_count is the length of the shared stroke prefix.
	stroke_count: int,
}

binding_key_equal :: proc(a, b: Binding_Key) -> bool {
	return a.key == b.key && key_modifiers_equal(a.modifiers, b.modifiers)
}

binding_sequence_equal :: proc(a, b: []Binding_Key) -> bool {
	if len(a) != len(b) { return false }
	for index in 0..<len(a) {
		if !binding_key_equal(a[index], b[index]) { return false }
	}
	return true
}

binding_sequence_starts_with :: proc(value: []Binding_Key, prefix: []Binding_Key) -> bool {
	if len(prefix) > len(value) { return false }
	for index in 0..<len(prefix) {
		if !binding_key_equal(value[index], prefix[index]) { return false }
	}
	return true
}

@(private)
binding_has_stroke_count :: proc(binding: ^Command_Binding, count: int, longer: ^bool, complete: ^bool) {
	if binding == nil { return }
	for sequence in binding.strokes {
		if len(sequence) == count {
			complete^ = true
		} else if len(sequence) > count {
			longer^ = true
		}
	}
}

// binding_conflicts reports ambiguous application keymaps. It compares each
// binding's first authored chord alternative pairwise in table order, which is
// the sequence the resolver tries first. It is pure and allocates only its
// result. Call binding_conflicts_destroy with the same allocator when finished.
binding_conflicts :: proc(
	table: Binding_Table,
	allocator := context.allocator,
) -> []Binding_Conflict {
	result := make([dynamic]Binding_Conflict, allocator=allocator)
	for first in 0..<len(table.bindings) {
		for second in first+1..<len(table.bindings) {
			a := &table.bindings[first]
			b := &table.bindings[second]
			if len(a.strokes) == 0 || len(b.strokes) == 0 { continue }
			a_strokes := a.strokes[0]
			b_strokes := b.strokes[0]
			if len(a_strokes) == 0 || len(b_strokes) == 0 { continue }
			if binding_sequence_equal(a_strokes, b_strokes) {
				kind := Binding_Conflict_Kind.Duplicate_Stroke
				if a.scope != b.scope { kind = .Scope_Overlap }
				append(&result, Binding_Conflict{
					kind=kind, first=first, second=second, stroke_count=len(a_strokes),
				})
				continue
			}
			shared := min(len(a_strokes), len(b_strokes))
			if shared > 0 && binding_sequence_equal(a_strokes[:shared], b_strokes[:shared]) {
				append(&result, Binding_Conflict{
					kind=.Prefix_Ambiguity, first=first, second=second, stroke_count=shared,
				})
			}
		}
	}
	return result[:]
}

binding_conflicts_destroy :: proc(conflicts: []Binding_Conflict, allocator := context.allocator) {
	if conflicts != nil { delete(conflicts, allocator) }
}

Binding_Result :: struct {
	// consumed means the host must not offer this transition to text input,
	// interaction scopes, Application_Key routing, or the application on_key
	// callback.
	consumed:   bool,
	// dispatched is set when a complete binding fired. command is valid then.
	dispatched: bool,
	command:    Action_ID,
	// pending is set when the transition armed or extended a chord.
	pending:    bool,
	// canceled is set when a pending chord was abandoned by this transition.
	// The host may still fall through when consumed is false.
	canceled:   bool,
}

// Binding_State is the host-owned chord machine. It stores only value data so
// native hosts, the hosted runtime, and the headless harness share identical
// behavior. The host supplies the current monotonic time and dispatches the
// command through its own policy.
Binding_State :: struct {
	table:         Binding_Table,
	pending:       [MAX_BINDING_CHORD_STROKES]Binding_Key,
	pending_count: int,
	deadline_ns:   u64,
	// epoch changes whenever pending state is armed or cleared. A host-scheduled
	// wake carries the epoch it was armed for, so a stale wake can never complete
	// or cancel a newer chord.
	epoch:         u64,
}

binding_state_init :: proc(state: ^Binding_State, table: Binding_Table) {
	if state == nil { return }
	state^ = Binding_State{table=table}
}

binding_state_update :: proc(state: ^Binding_State, table: Binding_Table) {
	if state == nil { return }
	_ = binding_state_cancel(state)
	state.table = table
}

binding_state_cancel :: proc(state: ^Binding_State) -> bool {
	if state == nil { return false }
	had_pending := state.pending_count > 0
	state.pending_count = 0
	state.deadline_ns = 0
	state.epoch += 1
	return had_pending
}

binding_state_pending :: proc(state: ^Binding_State) -> []Binding_Key {
	if state == nil || state.pending_count <= 0 { return nil }
	return state.pending[:state.pending_count]
}

binding_state_deadline :: proc(state: ^Binding_State) -> (deadline_ns: u64, found: bool) {
	if state == nil || state.pending_count <= 0 || state.deadline_ns == 0 { return 0, false }
	return state.deadline_ns, true
}

@(private)
binding_available :: proc(binding: ^Command_Binding, event: ^Key_Event) -> bool {
	if binding == nil || len(binding.strokes) == 0 { return false }
	if event.composition_active {
		if !binding.allow_during_composition { return false }
		if event.text_input_focused && !binding.preempt_text { return false }
		return true
	}
	if event.text_input_focused || event.produces_text {
		return binding.preempt_text
	}
	return true
}

@(private)
binding_matches_first_stroke :: proc(binding: ^Command_Binding, event: ^Key_Event) -> (complete: bool, longer: bool) {
	if !binding_available(binding, event) { return }
	for sequence in binding.strokes {
		if len(sequence) == 0 { continue }
		if !key_binding_matches(event.key, event.modifiers, sequence[0].key, sequence[0].modifiers) {
			continue
		}
		if len(sequence) == 1 { complete = true }
		else { longer = true }
	}
	return
}

@(private)
binding_matches_pending :: proc(binding: ^Command_Binding, pending: []Binding_Key) -> (complete: bool, longer: bool) {
	for sequence in binding.strokes {
		if len(sequence) < len(pending) { continue }
		if !binding_sequence_starts_with(sequence, pending) { continue }
		if len(sequence) == len(pending) { complete = true }
		else { longer = true }
	}
	return
}

@(private)
binding_state_arm :: proc(state: ^Binding_State, now_ns: u64) {
	state.deadline_ns = scheduled_wake_deadline_after(now_ns, binding_table_timeout(state.table))
	state.epoch += 1
}

// binding_state_resolve applies one key-down transition. The returned command
// is the application's Action_ID; the host dispatches it through the same
// enabled-gate policy it uses for menu commands.
binding_state_resolve :: proc(
	state: ^Binding_State,
	event: Key_Event,
	now_ns: u64,
) -> Binding_Result {
	value := event
	if state == nil || len(state.table.bindings) == 0 { return {} }

	if value.composition_active && state.pending_count > 0 {
		_ = binding_state_cancel(state)
	}

	if state.pending_count > 0 {
		if value.repeat { return Binding_Result{consumed=true, pending=true} }
		if state.pending_count < MAX_BINDING_CHORD_STROKES {
			state.pending[state.pending_count] = Binding_Key{key=value.key, modifiers=value.modifiers}
			state.pending_count += 1
			count := state.pending_count
			complete := false
			longer := false
			for index in 0..<len(state.table.bindings) {
				c, l := binding_matches_pending(
					&state.table.bindings[index], state.pending[:count],
				)
				complete = complete || c
				longer = longer || l
			}
			if longer {
				binding_state_arm(state, now_ns)
				return Binding_Result{consumed=true, pending=true}
			}
			if complete {
				command: Action_ID
				for index in 0..<len(state.table.bindings) {
					c, _ := binding_matches_pending(
						&state.table.bindings[index], state.pending[:count],
					)
					if c { command = state.table.bindings[index].command; break }
				}
				_ = binding_state_cancel(state)
				return Binding_Result{consumed=true, dispatched=true, command=command}
			}
		}
		// The key was not a continuation. Abandon the chord and reprocess the
		// same transition as a fresh first stroke so it cannot steal the next
		// command.
		_ = binding_state_cancel(state)
		result := binding_state_resolve_fresh(state, &value, now_ns)
		result.canceled = true
		return result
	}

	return binding_state_resolve_fresh(state, &value, now_ns)
}

@(private)
binding_state_resolve_fresh :: proc(
	state: ^Binding_State,
	event: ^Key_Event,
	now_ns: u64,
) -> Binding_Result {
	if event.repeat { return {} }
	complete: ^Command_Binding
	has_longer := false
	for index in 0..<len(state.table.bindings) {
		binding := &state.table.bindings[index]
		c, l := binding_matches_first_stroke(binding, event)
		if l { has_longer = true }
		if c && complete == nil { complete = binding }
	}
	if has_longer {
		state.pending[0] = Binding_Key{key=event.key, modifiers=event.modifiers}
		state.pending_count = 1
		binding_state_arm(state, now_ns)
		return Binding_Result{consumed=true, pending=true}
	}
	if complete != nil {
		return Binding_Result{consumed=true, dispatched=true, command=complete.command}
	}
	return {}
}

// binding_state_timeout advances a pending chord deadline. Call it when the
// host's scheduled wake fires (or its loop observes the deadline); passing the
// epoch captured when the wake was armed rejects stale wakes. now_ns must be at
// or after the armed deadline.
binding_state_timeout :: proc(
	state: ^Binding_State,
	epoch: u64,
	now_ns: u64,
) -> Binding_Result {
	if state == nil || state.pending_count == 0 || epoch != state.epoch { return {} }
	if state.deadline_ns != 0 && now_ns < state.deadline_ns { return {} }
	command: Action_ID
	complete := false
	for index in 0..<len(state.table.bindings) {
		c, _ := binding_matches_pending(
			&state.table.bindings[index], state.pending[:state.pending_count],
		)
		if c {
			command = state.table.bindings[index].command
			complete = true
			break
		}
	}
	_ = binding_state_cancel(state)
	if complete {
		return Binding_Result{consumed=true, dispatched=true, command=command}
	}
	return Binding_Result{canceled=true}
}

// binding_state_next_deadline exposes the armed deadline for host wait-timeout
// calculations. A host that computes its next event-loop timeout from this
// value never polls for chord completion.
binding_state_next_deadline :: proc(state: ^Binding_State) -> (u64, bool) {
	return binding_state_deadline(state)
}
