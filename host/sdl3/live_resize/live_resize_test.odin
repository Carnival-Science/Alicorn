package sdl3_live_resize

// Headless tests for the shared live-resize mechanism. They cover the dispatch
// guards, work gating, slot identity, and counter attribution without creating a
// platform window; the Windows modal-loop paths are exercised by the scripted
// drag fixture in tools\validate_native_webgpu_resize.ps1.

import "core:testing"
import "vendor:sdl3"

Plugin_Host :: struct {
	renders: int,
	last_slot: Slot,
	last_cause: Cause,
	renderable: [SLOT_COUNT]bool,
	has_work: [SLOT_COUNT]bool,
	gated: bool,
}

plugin_window :: proc(_data: rawptr, _slot: Slot) -> ^sdl3.Window { return nil }

plugin_renderable :: proc(data: rawptr, slot: Slot) -> bool {
	host := cast(^Plugin_Host)data
	return host.renderable[slot_index(slot)]
}

plugin_has_work :: proc(data: rawptr, slot: Slot) -> bool {
	host := cast(^Plugin_Host)data
	return host.has_work[slot_index(slot)]
}

plugin_render :: proc(data: rawptr, slot: Slot, _now_ns: u64, cause: Cause) {
	host := cast(^Plugin_Host)data
	host.renders += 1
	host.last_slot = slot
	host.last_cause = cause
	if host.gated {
		// A nested exposure during a present must be coalesced, not rendered.
		live_resize_service(global_core, .Secondary, 0, .Expose)
	}
}

plugin_ops :: proc(host: ^Plugin_Host) -> Ops {
	return Ops{
		data=rawptr(host),
		window=plugin_window,
		renderable=plugin_renderable,
		has_work=plugin_has_work,
		render=plugin_render,
	}
}

plugin_core :: proc(host: ^Plugin_Host) -> Core {
	core := Core{
		active=true,
		ops=plugin_ops(host),
	}
	core.slots[slot_index(.Primary)] = Slot_State{active=true, window_id=11}
	core.slots[slot_index(.Secondary)] = Slot_State{active=true, window_id=22}
	host.renderable = {true, true}
	return core
}

@(test)
test_slot_identity :: proc(t: ^testing.T) {
	host: Plugin_Host
	core := plugin_core(&host)
	slot, found := live_resize_slot_for_window_id(&core, 11)
	testing.expect(t, found && slot == .Primary, "primary window id resolves to the primary slot")
	slot, found = live_resize_slot_for_window_id(&core, 22)
	testing.expect(t, found && slot == .Secondary, "secondary window id resolves to the secondary slot")
	_, found = live_resize_slot_for_window_id(&core, 33)
	testing.expect(t, !found, "unknown window ids are ignored, not defaulted")
	_, found = live_resize_slot_for_window_id(&core, 0)
	testing.expect(t, !found, "zero window ids never match a slot")
}

@(test)
test_service_dispatches_to_slot :: proc(t: ^testing.T) {
	host: Plugin_Host
	core := plugin_core(&host)
	global_core = &core
	defer global_core = nil
	live_resize_service(&core, .Secondary, 100, .Timer)
	testing.expect_value(t, host.renders, 1)
	testing.expect(t, host.last_slot == .Secondary, "the requested slot is serviced")
	testing.expect(t, host.last_cause == .Timer, "the dispatch cause is reported to the renderer")
	testing.expect(t, core.counters.move_redraws == 0, "the core never attributes a timer frame on its own")
}

@(test)
test_service_ignores_inactive_slot :: proc(t: ^testing.T) {
	host: Plugin_Host
	core := plugin_core(&host)
	core.slots[slot_index(.Secondary)].active = false
	global_core = &core
	defer global_core = nil
	live_resize_service(&core, .Secondary, 100, .Expose)
	testing.expect_value(t, host.renders, 0)
}

@(test)
test_nested_expose_is_coalesced :: proc(t: ^testing.T) {
	host: Plugin_Host
	host.gated = true
	core := plugin_core(&host)
	global_core = &core
	defer global_core = nil
	live_resize_service(&core, .Primary, 100, .Expose)
	// One outer pass plus the one coalesced pending pass; the guard does not
	// recurse beyond the reference host's bounded two-pass loop.
	testing.expect_value(t, host.renders, 2)
	testing.expect_value(t, core.counters.deferred_exposes, 2)
}

@(test)
test_work_gating :: proc(t: ^testing.T) {
	host: Plugin_Host
	core := plugin_core(&host)
	host.has_work = {false, false}
	testing.expect(t, !live_resize_has_work(&core), "no retained work never installs the move timer")
	host.has_work = {false, true}
	testing.expect(t, live_resize_has_work(&core), "any live slot with work keeps the modal cadence")
	core.slots[slot_index(.Secondary)].active = false
	testing.expect(t, !live_resize_has_work(&core), "a retired slot stops contributing work")
}

@(test)
test_stop_slot_clears_move_state :: proc(t: ^testing.T) {
	host: Plugin_Host
	core := plugin_core(&host)
	core.slots[slot_index(.Primary)].move_active = true
	core.slots[slot_index(.Primary)].move_timer_active = true
	core.slots[slot_index(.Primary)].move_hwnd = rawptr(uintptr(1))
	live_resize_stop_slot(&core, .Primary)
	entry := core.slots[slot_index(.Primary)]
	testing.expect(t, !entry.move_active && !entry.move_timer_active && entry.move_hwnd == nil,
		"stopping a slot forgets its modal identity")
	testing.expect(t, entry.active, "stopping a move leaves the window slot itself live")
}

@(test)
test_clear_window_retires_slot :: proc(t: ^testing.T) {
	host: Plugin_Host
	core := plugin_core(&host)
	core.slots[slot_index(.Secondary)].move_active = true
	live_resize_clear_window(&core, .Secondary)
	testing.expect(t, !core.slots[slot_index(.Secondary)].active, "a destroyed window leaves no live slot")
	testing.expect(t, !core.slots[slot_index(.Secondary)].move_active, "a destroyed window leaves no modal move")
}

@(test)
test_presented_frame_counting :: proc(t: ^testing.T) {
	host: Plugin_Host
	core := plugin_core(&host)
	live_resize_note_presented_frame(&core, .Expose)
	live_resize_note_presented_frame(&core, .Timer)
	testing.expect_value(t, core.counters.expose_frames, 1)
}

@(test)
test_start_requires_render :: proc(t: ^testing.T) {
	core := Core{}
	testing.expect(t, !live_resize_start(&core, Ops{}), "a core without a renderer cannot start")
	testing.expect(t, !core.active, "a failed start leaves the core inactive")
}
