#+build !js
package alicorn

import "core:testing"

@(test)
test_runtime_destroy_with_active_motion_releases_owners_and_sidecars :: proc(t: ^testing.T) {
	stats := Runtime_Allocation_Stats{}
	rt := new_runtime(Rect{0, 0, 240, 120}, Runtime_Config{allocation_stats=&stats})
	_, child, _ := motion_retained_test_build(&rt, true)
	if child == 0 { testing.expect(t, false, "the shutdown fixture should build"); return }
	_ = motion_diagnostics_ensure(&rt)
	handle, status := motion_owner_begin(&rt, child)
	config := Motion_Config{omega=1.5, position_tolerance=0.001, velocity_tolerance=0.001}
	if status != .Ok || motion_target_translation(&rt, handle, Motion_Vector2{120, 0}, config, .Settle, Motion_Time(0)) != .Ok {
		testing.expect(t, false, "the shutdown fixture should start a long transition")
		destroy_runtime(&rt)
		return
	}
	_ = motion_tick(&rt, Motion_Time(50_000_000))
	active := motion_activity(&rt)
	owners_before := len(rt.motion_owners)
	frees_before := stats.persistent_free_calls
	live_before := stats.persistent_requested_bytes_live
	testing.expect(t, active.active_owners == 1 && owners_before == 1 && live_before > 0,
		"the fixture should hold one active motion owner and allocated motion sidecars at shutdown")
	destroy_runtime(&rt)
	testing.expect(t, stats.persistent_requested_bytes_live == 0 &&
		stats.persistent_free_calls > frees_before,
		"runtime destruction during an active transition must release every tracked motion allocation")
}
