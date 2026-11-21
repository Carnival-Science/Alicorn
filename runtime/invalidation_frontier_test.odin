#+build !js
package alicorn

import "core:fmt"
import "core:strings"
import "core:testing"

// Issue #193 runtime coverage: the capture is built from the existing ring and
// the already-resolved invalidation path. These tests assert declared
// subscribers/ancestors, changed-output vs visit distinction, and the
// novice-facing report. They are skipped cleanly when the compile-time gate is
// off; the release proof is a separate paired build.
@(test)
test_invalidation_frontier_captures_region_and_changed_outputs :: proc(t: ^testing.T) {
	if !INVALIDATION_FRONTIER_ENABLED {
		testing.expect(t, !frontier_capture_enabled(), "the gate constant and query must agree when disabled")
		rt := new_runtime(Rect{0, 0, 400, 420})
		defer destroy_runtime(&rt)
		_, found := frontier_capture(&rt, 1)
		testing.expect(t, !found, "a disabled build must not synthesize capture entries")
		testing.expect(t, strings.contains(frontier_inspect(&rt, 1), "capture unavailable"),
			"the query must report a disabled capture cleanly")
		return
	}
	rt := new_runtime(Rect{0, 0, 400, 420}, Runtime_Config{trace_capacity=256})
	defer destroy_runtime(&rt)
	material := coherence_setup(t, &rt)
	app := coherence_app()
	ids: [3]Node_ID
	_ = coherence_settle(t, &rt, &app, material, &ids)
	parent_id, parent_found := node_by_key(&rt, key_string("coherence-parent"), .Container)
	testing.expect(t, parent_found, "the fixture parent region must be retained")

	row := &app.rows[1]
	scope := application_mutation_begin(&rt, "frontier row", .Description, row.revision)
	row.value = "Bravo revised"
	row.revision += 1
	// The cached parent region must be re-described to reach the keyed child.
	// This is an app revision change, not a second invalidation request.
	app.parent_revision += 1
	invalidate_region(&rt, row.key, row.revision, "frontier diagnostic reason text")
	cause_id := rt.cause_sequence
	application_mutation_end(&rt, &scope, row.revision)
	_ = coherence_settle(t, &rt, &app, material)

	capture, found := frontier_capture(&rt, cause_id)
	testing.expect(t, found, "the invalidation cause must have a bounded capture")
	testing.expect(t, capture.invalidations == 1 && capture.region_invalidations == 1 && capture.root_invalidations == 0,
		"one region request must be classified exactly once")
	testing.expect(t, capture.subscriber_count == 1 && capture.subscribers[0] == ids[1],
		"the region key must resolve to its already-indexed subscriber instance")
	testing.expect(t, capture.ancestor_count >= 1 && frontier_node_list_contains(capture.ancestors[:], capture.ancestor_count, parent_id),
		"ancestors must follow retained parent links from the subscriber")
	testing.expect(t, capture.changed[.Description] > 0 && capture.changed[.Paint] > 0,
		"a content change must produce changed description and paint outputs")
	testing.expect(t, capture.changed[.Composite] > 0, "a changed paint product must finalize a composite output")

	summary := frontier_trace_summary(&rt, cause_id)
	testing.expect(t, summary.events > 0 && summary.visits[.Reconcile] > 0 && summary.visits[.Paint] > 0,
		"stage visits must still come from the existing trace ring")
	testing.expect(t, summary.samples[.Paint].count > 0,
		"sampled stage node IDs must be taken from existing ring events")

	why := frontier_why_touched(&rt, cause_id, ids[1])
	defer delete(why)
	testing.expect(t, strings.contains(why, "subscribed instance 0"),
		"the why-touched query must cite the resolved subscriber")

	outside := frontier_why_touched(&rt, cause_id, ids[0])
	defer delete(outside)
	testing.expect(t, strings.contains(outside, "outside the declared frontier"),
		"a sibling instance must be reported as outside this cause's frontier")

	report := frontier_inspect(&rt, cause_id)
	defer delete(report)
	testing.expect(t, strings.contains(report, "Alicorn invalidation frontier") &&
		strings.contains(report, "coherence-b") && strings.contains(report, "subscribers (1)") &&
		strings.contains(report, "changed outputs:") && strings.contains(report, "why node #"),
		"the report must include the origin, region, subscribers, changed outputs, and why line")
	testing.expect(t, !strings.contains(report, "frontier diagnostic reason text"),
		"the report must not copy application reason strings from the ring")

	inspection := inspect(&rt)
	defer delete(inspection)
	testing.expect(t, strings.contains(inspection, "frontiers:") && strings.contains(inspection, "cause #"),
		"inspect() must include the bounded frontier inventory used by capture bundles")
}

@(test)
test_invalidation_frontier_same_value_write_changes_nothing :: proc(t: ^testing.T) {
	if !INVALIDATION_FRONTIER_ENABLED { return }
	rt := new_runtime(Rect{0, 0, 400, 420}, Runtime_Config{trace_capacity=256})
	defer destroy_runtime(&rt)
	material := coherence_setup(t, &rt)
	app := coherence_app()
	_ = coherence_settle(t, &rt, &app, material)
	row := &app.rows[0]
	// A same-value write legally invalidates the declared dependency and
	// schedules a description, but the retained description matches exactly.
	invalidate_region(&rt, row.key, row.revision, "same value write")
	cause_id := rt.cause_sequence
	testing.expect(t, coherence_settle(t, &rt, &app, material) == 1,
		"the invalidation must schedule exactly one description pass")
	capture, found := frontier_capture(&rt, cause_id)
	testing.expect(t, found && capture.invalidations == 1 && capture.region_invalidations == 1,
		"the same-value request must still be captured as a declared invalidation")
	testing.expect(t, frontier_changed_total(&capture) == 0 && capture.changed[.Description] == 0,
		"a same-value write must change no stage output; visiting is not changing")
	report := frontier_inspect(&rt, cause_id)
	defer delete(report)
	testing.expect(t, strings.contains(report, "description ran without a changed output"),
		"the report must distinguish an unchanged description from missing work")
	testing.expect(t, strings.contains(report, "where work stopped: before description output"),
		"the report must say where work stopped when nothing changed")
}

@(test)
test_invalidation_frontier_root_capture_and_bounded_report :: proc(t: ^testing.T) {
	if !INVALIDATION_FRONTIER_ENABLED { return }
	rt := new_runtime(Rect{0, 0, 400, 420}, Runtime_Config{trace_capacity=256})
	defer destroy_runtime(&rt)
	material := coherence_setup(t, &rt)
	app := coherence_app()
	_ = coherence_settle(t, &rt, &app, material)
	invalidate_root(&rt, "frontier root invalidation")
	cause_id := rt.cause_sequence
	_ = coherence_settle(t, &rt, &app, material)
	capture, found := frontier_capture(&rt, cause_id)
	testing.expect(t, found && capture.root_invalidations == 1 && capture.region_invalidations == 0,
		"a root request must be classified separately from a region request")
	row_id, row_found := node_by_key(&rt, key_string("before-action"), .Text_Field)
	testing.expect(t, row_found, "the root description must retain the status field")
	why := frontier_why_touched(&rt, cause_id, row_id)
	defer delete(why)
	testing.expect(t, strings.contains(why, "whole-tree scope"),
		"a root request must explain that every retained node is in scope")

	// Capacity is fixed: many causes must not grow the store or make the query
	// unbounded. The oldest entries are allowed to leave the bounded ring.
	for index in 0..<(FRONTIER_CAUSE_CAPACITY+8) {
		invalidate_root(&rt, "bounded frontier ring")
		_ = coherence_settle(t, &rt, &app, material)
	}
	report := frontier_inspect(&rt, rt.cause_sequence)
	defer delete(report)
	testing.expect(t, len(report) < 8192, "one report must stay bounded regardless of history")
}
