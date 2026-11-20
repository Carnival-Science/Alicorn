package alicorn

// Scheduled_Wake_Class distinguishes work that should run at a useful cadence
// from lower-fidelity work that can wait until the user has been quiet. The
// reference SDL_GPU host and hosted runtimes share this vocabulary so an
// application can move between hosts without changing its scheduler policy.
Scheduled_Wake_Class :: enum {Frequent, Opportunistic}

SCHEDULED_WAKE_CLASS_COUNT :: 2
SCHEDULED_WAKE_MAX_U64 :: u64(0xffff_ffff_ffff_ffff)

// APPLICATION_OPPORTUNISTIC_QUIET_NS is the input-quiet window used by native
// SDL_GPU and hosted runtimes before an Opportunistic deadline may run.
APPLICATION_OPPORTUNISTIC_QUIET_NS :: u64(150_000_000)

Application_Schedule_After_Proc :: proc(data: rawptr, class: Scheduled_Wake_Class, delay_ns: u64) -> bool
Application_Cancel_Scheduled_Proc :: proc(data: rawptr, class: Scheduled_Wake_Class) -> bool
Application_Scheduler_Stats_Proc :: proc(data: rawptr) -> Application_Scheduler_Stats

Application_Scheduler_Stats :: struct {
	scheduled:               u64,
	coalesced:               u64,
	frequent_wakes:          u64,
	opportunistic_wakes:     u64,
	opportunistic_deferrals: u64,
	maximum_lateness_ns:     u64,
	frequent_pending:        bool,
	opportunistic_pending:   bool,
}

// Application_Scheduler is a UI-thread-only service. It owns at most one
// replaceable deadline for each class; it is deliberately not a task queue.
Application_Scheduler :: struct {
	data:       rawptr,
	schedule:   Application_Schedule_After_Proc,
	cancel:     Application_Cancel_Scheduled_Proc,
	read_stats: Application_Scheduler_Stats_Proc,
}

application_schedule_after :: proc(scheduler: Application_Scheduler, class: Scheduled_Wake_Class, delay_ns: u64) -> bool {
	return scheduler.schedule != nil && scheduler.schedule(scheduler.data, class, delay_ns)
}

application_cancel_scheduled_wake :: proc(scheduler: Application_Scheduler, class: Scheduled_Wake_Class) -> bool {
	return scheduler.cancel != nil && scheduler.cancel(scheduler.data, class)
}

application_scheduler_stats :: proc(scheduler: Application_Scheduler) -> Application_Scheduler_Stats {
	if scheduler.read_stats != nil { return scheduler.read_stats(scheduler.data) }
	return {}
}

// Application_Scheduled_Wake_Proc receives the class that became due. The
// runtime clears that class before invoking the callback, so the application
// may arm the next deadline from inside it.
Application_Scheduled_Wake_Proc :: proc(state: rawptr, rt: ^Runtime, class: Scheduled_Wake_Class)

scheduled_wake_class_index :: proc(class: Scheduled_Wake_Class) -> int {
	switch class {
	case .Frequent: return 0
	case .Opportunistic: return 1
	}
	return -1
}

scheduled_wake_deadline_after :: proc(now_ns, delay_ns: u64) -> u64 {
	if delay_ns > SCHEDULED_WAKE_MAX_U64-now_ns { return SCHEDULED_WAKE_MAX_U64 }
	return now_ns+delay_ns
}

scheduled_wake_timeout_ms :: proc(deadline_ns, now_ns: u64) -> u64 {
	remaining := u64(0)
	if deadline_ns > now_ns { remaining = deadline_ns-now_ns }
	milliseconds := remaining/1_000_000
	if remaining%1_000_000 != 0 { milliseconds += 1 }
	return min(milliseconds, u64(0x7fff_ffff))
}

// Scheduled_Wake_State holds the two replaceable deadlines shared by native
// and hosted scheduler implementations.
Scheduled_Wake_State :: struct {
	deadlines_ns: [SCHEDULED_WAKE_CLASS_COUNT]u64,
	pending:      [SCHEDULED_WAKE_CLASS_COUNT]bool,
}

scheduled_wake_state_schedule :: proc(
	state: ^Scheduled_Wake_State,
	class: Scheduled_Wake_Class,
	now_ns, delay_ns: u64,
) -> bool {
	index := scheduled_wake_class_index(class)
	if state == nil || index < 0 { return false }
	state.pending[index] = true
	state.deadlines_ns[index] = scheduled_wake_deadline_after(now_ns, delay_ns)
	return true
}

scheduled_wake_state_cancel :: proc(state: ^Scheduled_Wake_State, class: Scheduled_Wake_Class) -> bool {
	index := scheduled_wake_class_index(class)
	if state == nil || index < 0 { return false }
	state.pending[index] = false
	return true
}

scheduled_wake_state_next_deadline :: proc(state: ^Scheduled_Wake_State) -> (deadline_ns: u64, found: bool) {
	if state == nil { return }
	for index in 0..<SCHEDULED_WAKE_CLASS_COUNT {
		if state.pending[index] && (!found || state.deadlines_ns[index] < deadline_ns) {
			deadline_ns = state.deadlines_ns[index]
			found = true
		}
	}
	return
}

scheduled_wake_state_is_due :: proc(state: ^Scheduled_Wake_State, class: Scheduled_Wake_Class, now_ns: u64) -> bool {
	index := scheduled_wake_class_index(class)
	return state != nil && index >= 0 && state.pending[index] && state.deadlines_ns[index] <= now_ns
}

// scheduled_wake_defer_until_quiet returns a later deadline when an
// Opportunistic request would run before the input-quiet window elapses.
scheduled_wake_defer_until_quiet :: proc(
	now_ns, last_interaction_ns, quiet_ns: u64,
) -> (deadline_ns: u64, deferred: bool) {
	if last_interaction_ns == 0 || now_ns < last_interaction_ns { return }
	quiet_deadline := scheduled_wake_deadline_after(last_interaction_ns, quiet_ns)
	if now_ns < quiet_deadline {
		return quiet_deadline, true
	}
	return
}
