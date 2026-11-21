#+build !js
package alicorn

import "core:testing"

@(test)
test_motion_only_frames_perform_no_hit_index_maintenance_and_classify_lookup_work :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 240, 120})
	defer destroy_runtime(&rt)
	target, _ := motion_acceptance_build_indexed(&rt)
	if target == 0 { testing.expect(t, false, "the hit-maintenance fixture should build"); return }
	after_description := rt.stats
	testing.expect(t, after_description.hit_index_updates > 0 && after_description.hit_geometry_updates > 0,
		"the initial description/layout should be observable as hit maintenance work")

	handle, handle_status := motion_owner_begin(&rt, target)
	config := Motion_Config{omega=18, position_tolerance=0.001, velocity_tolerance=0.001}
	testing.expect(t, handle_status == .Ok && motion_target_translation(
		&rt, handle, Motion_Vector2{24, 4}, config, .Snap, Motion_Time(0),
	) == .Ok, "the fixture target should acquire and commit a motion pose")
	before_motion := rt.stats
	paint_before := before_motion.paint_updates
	composition_before := before_motion.composition_nodes_visited
	ui, ready := begin_presentation_frame(&rt)
	if ready { end_presentation_frame(&ui) }
	frame_submission_succeeded(&rt)
	after_motion := rt.stats
	testing.expect(t, ready && after_motion.hit_index_updates == before_motion.hit_index_updates &&
		after_motion.hit_geometry_updates == before_motion.hit_geometry_updates,
		"a motion-only frame must perform zero hit-index or hit-geometry maintenance, independent of tree size")
	testing.expect(t, after_motion.paint_updates == paint_before &&
		after_motion.composition_nodes_visited > composition_before &&
		after_motion.hit_test_queries == before_motion.hit_test_queries,
		"motion composition work should be classified separately from paint updates and hit queries")

	// An explicit hit-test query is a retained-order traversal, not an index
	// rebuild. Its cost is bounded by the retained node count, and it does not
	// change maintenance counters.
	queries_before := rt.stats.hit_test_queries
	examined_before := rt.stats.hit_test_nodes_examined
	maintenance_before := rt.stats.hit_index_updates
	bounds := rt.nodes[target].bounds
	hit := hit_test(&rt, bounds.x+bounds.w*0.5, bounds.y+bounds.h*0.5)
	query_after := rt.stats
	testing.expect(t, hit == target && query_after.hit_test_queries == queries_before+1,
		"the explicit query should hit the target and increment exactly one query counter")
	testing.expect(t, query_after.hit_test_nodes_examined > examined_before &&
		query_after.hit_test_nodes_examined-examined_before <= 3*u64(len(rt.order)) &&
		query_after.hit_index_updates == maintenance_before &&
		query_after.hit_geometry_updates == after_motion.hit_geometry_updates,
		"a hit-test traversal must stay within its bounded split/interactive/drag scans and perform no index maintenance")
}

