#+build !js

package alicorn

import "core:testing"
import "core:fmt"

@(test)
test_semantic_snapshot_bounded_keeps_earliest_tree_order :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 200})
	defer destroy_runtime(&rt)
	orders := [5]u64{30, 10, 50, 20, 40}
	for order, index in orders {
		id := Semantic_ID{namespace=0x534E4150424F554E, value=u64(index+1)}
		description := Semantic_Node_Description{
			id=id,
			role=.List_Item,
			label=fmt.tprintf("item %d", order),
			tree_order=u64(order),
		}
		if !semantic_node_set(&rt, description) {
			testing.expect(t, false, "bounded snapshot fixture descriptions should be valid")
			return
		}
	}
	if !semantic_commit(&rt) {
		testing.expect(t, false, "the fixture entities should publish together")
		return
	}

	snapshot, truncated := semantic_snapshot_bounded(&rt, 3)
	defer semantic_snapshot_destroy(&snapshot)
	testing.expect(t, truncated && len(snapshot.nodes) == 3,
		"the bounded snapshot must report when semantic entities were omitted")
	if len(snapshot.nodes) == 3 {
		testing.expect(t,
			snapshot.nodes[0].tree_order == 10 && snapshot.nodes[1].tree_order == 20 && snapshot.nodes[2].tree_order == 30,
			"the bounded snapshot should retain the earliest nodes in stable tree order")
	}
}

@(test)
test_semantic_snapshot_bounded_reports_complete_and_zero_limits :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 200})
	defer destroy_runtime(&rt)
	id := Semantic_ID{namespace=0x534E4150424F554E, value=9}
	if !semantic_node_set(&rt, Semantic_Node_Description{id=id, role=.Button, label="Save"}) || !semantic_commit(&rt) {
		testing.expect(t, false, "the single semantic fixture should publish")
		return
	}
	complete, complete_truncated := semantic_snapshot_bounded(&rt, 1)
	defer semantic_snapshot_destroy(&complete)
	empty, empty_truncated := semantic_snapshot_bounded(&rt, 0)
	defer semantic_snapshot_destroy(&empty)
	testing.expect(t, !complete_truncated && len(complete.nodes) == 1 &&
		empty_truncated && len(empty.nodes) == 0,
		"exact capacity is complete, while a zero-node limit reports an omitted entity")
}

@(test)
test_semantic_snapshot_bounded_caps_text_before_cloning :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 200})
	defer destroy_runtime(&rt)
	id := Semantic_ID{namespace=0x534E4150424F554E, value=10}
	if !semantic_node_set(&rt, Semantic_Node_Description{
		id=id,
		role=.Static_Text,
		label="description exceeds the budget",
	}) || !semantic_commit(&rt) {
		testing.expect(t, false, "the bounded text fixture should publish")
		return
	}
	snapshot, truncated := semantic_snapshot_bounded(&rt, 8, max_text_bytes=8)
	defer semantic_snapshot_destroy(&snapshot)
	testing.expect(t, truncated && len(snapshot.nodes) == 0,
		"a text-budget overflow must return an empty snapshot before cloning strings")
}
