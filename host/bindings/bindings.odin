// Package host_bindings is the host-facing service around the runtime's pure
// binding resolver. It owns a borrowed Binding_Table, the chord state machine,
// and the host dispatch callback. Runtime itself has no host-loop dependency;
// native and hosted hosts can use this package or the same Binding_State
// directly.
//
// The service never polls. When a chord is armed it reports a deadline and,
// when a scheduler is supplied, arms one Frequent-class wake. A host that owns
// its own loop can instead include binding_service_deadline in its wait
// timeout and call binding_service_timeout when it expires.
package host_bindings

import alicorn "alicorn:runtime"

Binding_Dispatch_Proc :: proc(data: rawptr, rt: ^alicorn.Runtime, command: alicorn.Action_ID) -> bool

Binding_Service :: struct {
	state:        alicorn.Binding_State,
	data:         rawptr,
	dispatch:     Binding_Dispatch_Proc,
	scheduler:    alicorn.Application_Scheduler,
	last_now_ns:  u64,
	// armed_epoch and scheduled identify the wake this service owns. A stale
	// epoch is rejected by the runtime resolver.
	armed_epoch:  u64,
	scheduled:    bool,
}

binding_service_init :: proc(
	service: ^Binding_Service,
	table: alicorn.Binding_Table,
	data: rawptr,
	dispatch: Binding_Dispatch_Proc,
	scheduler: alicorn.Application_Scheduler = {},
) {
	if service == nil { return }
	service^ = Binding_Service{
		data=data,
		dispatch=dispatch,
		scheduler=scheduler,
	}
	alicorn.binding_state_init(&service.state, table)
}

binding_service_active :: proc(service: ^Binding_Service) -> bool {
	return service != nil && len(service.state.table.bindings) > 0
}

// binding_service_update replaces the borrowed table and clears any pending
// chord. Existing borrowed storage may be mutated in place before this call;
// the resolver always reads the current table.
binding_service_update :: proc(service: ^Binding_Service, table: alicorn.Binding_Table) {
	if service == nil { return }
	binding_service_unschedule(service)
	alicorn.binding_state_update(&service.state, table)
}

@(private)
binding_service_unschedule :: proc(service: ^Binding_Service) {
	if service == nil || !service.scheduled { return }
	if service.scheduler.cancel != nil {
		_ = alicorn.application_cancel_scheduled_wake(service.scheduler, .Frequent)
	}
	service.scheduled = false
}

@(private)
binding_service_schedule :: proc(service: ^Binding_Service, now_ns: u64) {
	if service == nil { return }
	deadline, found := alicorn.binding_state_deadline(&service.state)
	if !found {
		binding_service_unschedule(service)
		return
	}
	if service.scheduled && service.armed_epoch == service.state.epoch { return }
	if service.scheduler.schedule == nil { return }
	delay := u64(0)
	if deadline > now_ns { delay = deadline-now_ns }
	if alicorn.application_schedule_after(service.scheduler, .Frequent, delay) {
		service.scheduled = true
		service.armed_epoch = service.state.epoch
	}
}

// binding_service_cancel clears a pending chord. Hosts call it on focus change,
// committed/preedit/canceled text, pointer-down, and any other event that ends
// the key sequence.
binding_service_cancel :: proc(service: ^Binding_Service) -> bool {
	if service == nil { return false }
	binding_service_unschedule(service)
	return alicorn.binding_state_cancel(&service.state)
}

// binding_service_resolve routes one key transition. consumed follows the
// additive contract: a miss falls through to the host's existing menu,
// Application_Key, text, and interaction routing.
binding_service_resolve :: proc(
	service: ^Binding_Service,
	rt: ^alicorn.Runtime,
	event: alicorn.Key_Event,
	now_ns: u64,
) -> bool {
	if service == nil || !binding_service_active(service) { return false }
	service.last_now_ns = now_ns
	result := alicorn.binding_state_resolve(&service.state, event, now_ns)
	if result.dispatched {
		binding_service_unschedule(service)
		if service.dispatch != nil { _ = service.dispatch(service.data, rt, result.command) }
		return true
	}
	binding_service_schedule(service, now_ns)
	return result.consumed
}

// binding_service_timeout applies the armed deadline. It accepts now_ns so a
// host can use its own wait clock; a stale wake epoch returns false without
// touching the newer chord.
binding_service_timeout :: proc(
	service: ^Binding_Service,
	rt: ^alicorn.Runtime,
	now_ns: u64,
) -> bool {
	if service == nil || !binding_service_active(service) { return false }
	service.last_now_ns = now_ns
	epoch := service.armed_epoch
	if epoch == 0 { epoch = service.state.epoch }
	result := alicorn.binding_state_timeout(&service.state, epoch, now_ns)
	if result.dispatched {
		service.scheduled = false
		if service.dispatch != nil { _ = service.dispatch(service.data, rt, result.command) }
		return true
	}
	if result.canceled {
		service.scheduled = false
	}
	return false
}

// binding_service_scheduled_wake lets a host forward its Frequent wake. The
// runtime has already cleared the scheduler class before this callback.
binding_service_scheduled_wake :: proc(
	service: ^Binding_Service,
	rt: ^alicorn.Runtime,
	class: alicorn.Scheduled_Wake_Class,
	now_ns: u64 = 0,
) -> bool {
	if service == nil || class != .Frequent { return false }
	at := now_ns
	if at == 0 { at = service.last_now_ns }
	if at == 0 { at = service.state.deadline_ns }
	return binding_service_timeout(service, rt, at)
}

binding_service_pending :: proc(service: ^Binding_Service) -> []alicorn.Binding_Key {
	if service == nil { return nil }
	return alicorn.binding_state_pending(&service.state)
}

binding_service_deadline :: proc(service: ^Binding_Service) -> (u64, bool) {
	if service == nil { return 0, false }
	return alicorn.binding_state_deadline(&service.state)
}

binding_service_conflicts :: proc(
	service: ^Binding_Service,
	allocator := context.allocator,
) -> []alicorn.Binding_Conflict {
	if service == nil { return nil }
	return alicorn.binding_conflicts(service.state.table, allocator)
}
