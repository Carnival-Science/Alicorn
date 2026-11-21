#+build !js
package alicorn

import "core:mem"
import "core:testing"

// Helpers for issue #227: the maintained region index must stay exactly
// equivalent to the prior linear retained-node scan across creation,
// retirement, reparenting, key reuse, and randomized update sequences.

Region_Index_Test_Item :: struct {
	scope:    int,
	key:      string,
	present:  bool,
	revision: u64,
}

region_index_test_linear :: proc(rt: ^Runtime, key: string, allocator := context.temp_allocator) -> [dynamic]Node_ID {
	result := make([dynamic]Node_ID, 0, allocator=allocator)
	for id, node in rt.nodes {
		if node != nil && node.active && node.region && node.label == key {
			append(&result, id)
		}
	}
	return result
}

region_index_test_indexed :: proc(rt: ^Runtime, key: string, allocator := context.temp_allocator) -> [dynamic]Node_ID {
	result := make([dynamic]Node_ID, 0, allocator=allocator)
	entry, found := rt.region_nodes[key]
	if !found { return result }
	for id in entry.nodes {
		node, ok := rt.nodes[id]
		if ok && node != nil && node.active && node.region && node.label == key {
			append(&result, id)
		}
	}
	return result
}

region_index_test_same_set :: proc(a, b: []Node_ID) -> bool {
	if len(a) != len(b) { return false }
	for id in a {
		found := false
		for other in b {
			if other == id { found = true; break }
		}
		if !found { return false }
	}
	return true
}

region_index_test_check_key :: proc(t: ^testing.T, rt: ^Runtime, key: string) -> bool {
	linear := region_index_test_linear(rt, key)
	indexed := region_index_test_indexed(rt, key)
	ok := region_index_test_same_set(linear[:], indexed[:])
	testing.expectf(t, ok, "indexed lookup for %q must match the linear region scan (%d indexed, %d linear)",
		key, len(indexed), len(linear))
	return ok
}

region_index_test_root_begin :: proc(ui: ^UI, key: string) {
	container_begin(ui, .Root, key=key_string(key), style=layout_style(.Column, gap=2))
}

region_index_test_region :: proc(ui: ^UI, key: string, revision: u64) -> Node_ID {
	id, reused := region_begin(ui, key, revision)
	if id == 0 || reused { return id }
	text(ui, key, key=key_string(key))
	region_end(ui, id, false, 0)
	return id
}

region_index_test_reuse_describe :: proc(ui: ^UI, scopes: []string, revision: u64) {
	container_begin(ui, .Root, key=key_string("region-index-reuse-root"), style=layout_style(.Column, gap=2))
	for scope_name in scopes {
		if !key_scope_begin(ui, key_string(scope_name)) { continue }
		id, reused := region_begin(ui, "meter", revision)
		if id != 0 && !reused {
			text(ui, "meter", key=key_string("meter-text"))
			region_end(ui, id, false, 0)
		}
		key_scope_end(ui)
	}
	container_end(ui)
}

@(test)
test_region_index_tracks_creation_and_retirement :: proc(t: ^testing.T) {
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)

	stats := Runtime_Allocation_Stats{}
	rt := new_runtime(Rect{0, 0, 480, 320}, Runtime_Config{
		persistent_allocator = mem.tracking_allocator(&tracking),
		allocation_stats = &stats,
	})

	keys := []string{"region-index-a", "region-index-b", "region-index-c", "region-index-d"}
	region_ids := make([]Node_ID, len(keys), context.temp_allocator)
	defer delete(region_ids, context.temp_allocator)

	ui, build := begin_frame(&rt)
	testing.expect(t, build, "the first frame must describe the region fixture")
	region_index_test_root_begin(&ui, "region-index-root")
	for key, index in keys {
		region_ids[index] = region_index_test_region(&ui, key, 1)
	}
	container_end(&ui)
	end_frame(&ui)

	testing.expect(t, region_index_is_consistent(&rt), "the region index must be consistent after creation")
	testing.expectf(t, len(rt.region_nodes) == len(keys), "every live region key must have one index entry (have %d, want %d)",
		len(rt.region_nodes), len(keys))
	for key, index in keys {
		testing.expect(t, region_ids[index] != 0, "the fixture must retain each region")
		entry, found := rt.region_nodes[key]
		testing.expectf(t, found && len(entry.nodes) == 1 && entry.nodes[0] == region_ids[index],
			"region %q must be indexed under its own key", key)
		testing.expect(t, region_index_test_check_key(t, &rt, key), "index lookup must match the linear scan")
	}
	live_after_mount := stats.persistent_requested_bytes_live
	testing.expect(t, live_after_mount > 0, "the mounted runtime must own persistent storage")

	// Re-describe only the first region. The other three are omitted and must be
	// retired through both the retained tree and the index.
	live_before_retire := stats.persistent_requested_bytes_live
	frees_before_retire := stats.persistent_free_calls
	invalidate_root(&rt, "retire most region-index regions")
	ui, build = begin_frame(&rt)
	testing.expect(t, build, "the retirement frame must describe")
	region_index_test_root_begin(&ui, "region-index-root")
	region_index_test_region(&ui, keys[0], 1)
	container_end(&ui)
	end_frame(&ui)

	testing.expect(t, region_index_is_consistent(&rt), "the region index must be consistent after retirement")
	testing.expectf(t, len(rt.region_nodes) == 1, "retirement must release index entries (have %d, want 1)", len(rt.region_nodes))
	testing.expect(t, rt.region_nodes[keys[0]].nodes[0] == region_ids[0], "the surviving region keeps its entry")
	for key in keys[1:] {
		_, found := rt.region_nodes[key]
		testing.expectf(t, !found, "retired region %q must leave no index entry", key)
	}
	testing.expect(t, stats.persistent_free_calls > frees_before_retire,
		"retiring regions must free persistent index and node storage")
	testing.expectf(t, stats.persistent_requested_bytes_live < live_before_retire,
		"retirement must release tracked live bytes (%d before, %d after)", live_before_retire, stats.persistent_requested_bytes_live)

	// Retire the last region as well: the index must return to empty, not to a
	// tombstone entry for a dead key.
	invalidate_root(&rt, "retire the last region-index region")
	ui, build = begin_frame(&rt)
	testing.expect(t, build, "the final retirement frame must describe")
	region_index_test_root_begin(&ui, "region-index-root")
	container_end(&ui)
	end_frame(&ui)
	testing.expect(t, len(rt.region_nodes) == 0, "an empty retained tree must leave an empty region index")
	testing.expect(t, region_index_is_consistent(&rt), "an empty region index is trivially consistent")

	destroy_runtime(&rt)
	testing.expect(t, stats.persistent_requested_bytes_live == 0, "destroy must release tracked runtime bytes")
	testing.expect(t, tracking.current_memory_allocated == 0,
		"destroy must release every persistent region-index allocation")
}

@(test)
test_region_index_invalidates_every_instance_of_a_reused_key :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 480, 320})
	defer destroy_runtime(&rt)

	scopes := []string{"region-index-scope-a", "region-index-scope-b"}

	ui, build := begin_frame(&rt)
	testing.expect(t, build, "the multi-instance fixture must describe its first frame")
	region_index_test_reuse_describe(&ui, scopes[:], 1)
	end_frame(&ui)

	entry, found := rt.region_nodes["meter"]
	testing.expect(t, found && len(entry.nodes) == 2,
		"the same region key under two keyed scopes must index both instances")
	testing.expect(t, region_index_is_consistent(&rt), "the multi-instance index must be consistent")
	testing.expect(t, region_index_test_check_key(t, &rt, "meter"), "index lookup must match the linear scan for a reused key")
	instances := make([]Node_ID, len(entry.nodes), context.temp_allocator)
	defer delete(instances, context.temp_allocator)
	copy(instances, entry.nodes[:])
	testing.expect(t, instances[0] != instances[1], "keyed scopes must keep the region instances distinct")

	invalidate_region(&rt, "meter", 2, "invalidate every live instance")
	testing.expect(t, !rt.hard_error, "invalidation of live instances must not report a diagnostic")
	for id in instances {
		node, ok := rt.nodes[id]
		testing.expect(t, ok && node.region_revision == 2 && !node.region_cached,
			"every instance of a reused region key must receive the new revision")
	}

	ui, build = begin_frame(&rt)
	testing.expect(t, build, "the rebuilt multi-instance frame must describe")
	region_index_test_reuse_describe(&ui, scopes[:], 2)
	end_frame(&ui)
	for id in instances {
		node, ok := rt.nodes[id]
		testing.expect(t, ok && node.region_cached && node.region_revision == 2,
			"every instance must rebuild and re-cache at the invalidated revision")
	}

	// Drop the second scope: only one instance retires, and the key must remain
	// invalidatable through the surviving instance.
	invalidate_root(&rt, "retire one instance of the reused region key")
	ui, build = begin_frame(&rt)
	testing.expect(t, build, "the partial retirement frame must describe")
	region_index_test_reuse_describe(&ui, scopes[:1], 2)
	end_frame(&ui)

	entry, found = rt.region_nodes["meter"]
	testing.expect(t, found && len(entry.nodes) == 1, "retiring one scope must leave the other instance indexed")
	testing.expect(t, entry.nodes[0] == instances[0], "the surviving instance must keep the index entry")
	_, retired_found := rt.nodes[instances[1]]
	testing.expect(t, !retired_found, "the retired instance must leave the retained map")
	testing.expect(t, region_index_is_consistent(&rt), "the partially retired index must be consistent")

	invalidate_region(&rt, "meter", 3, "invalidate the surviving instance")
	testing.expect(t, !rt.hard_error, "invalidating the surviving instance must not diagnose an unknown key")
	node, ok := rt.nodes[instances[0]]
	testing.expect(t, ok && node.region_revision == 3 && !node.region_cached,
		"the surviving instance must still resolve through the index")
	testing.expect(t, region_index_test_check_key(t, &rt, "meter"), "index lookup must match the linear scan after retirement")
}

@(test)
test_region_index_updates_when_a_region_stops_being_a_region_or_is_rekeyed :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 480, 320})
	defer destroy_runtime(&rt)
	source := site("tests/region-index-transition.odin", 12, 1, "region-index-transition")

	ui, build := begin_frame(&rt)
	testing.expect(t, build, "the transition fixture must describe its first frame")
	region_index_test_root_begin(&ui, "region-index-transition-root")
	region_id, reused := region_begin(&ui, "index-status", 1, source)
	if region_id != 0 && !reused {
		text(&ui, "status", key=key_string("index-status-text"))
		region_end(&ui, region_id, false, 0)
	}
	container_end(&ui)
	end_frame(&ui)
	testing.expect(t, region_id != 0 && rt.nodes[region_id].region, "the fixture must start with a live region")
	testing.expect(t, region_index_is_consistent(&rt), "the initial transition index must be consistent")

	// Describe the same retained identity as an ordinary container. The node
	// stops being a region and its key must leave the index immediately.
	invalidate_root(&rt, "describe the region identity as a container")
	ui, build = begin_frame(&rt)
	testing.expect(t, build, "the container transition frame must describe")
	region_index_test_root_begin(&ui, "region-index-transition-root")
	container_id := container_begin_ex(&ui, .Container, source, key="index-status", explicit_key=true,
		style=layout_style(.Column, gap=2))
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	testing.expect(t, container_id == region_id, "the transition fixture must retain the same node identity")
	node, ok := rt.nodes[region_id]
	testing.expect(t, ok && !node.region, "the retained node must stop reporting itself as a region")
	_, indexed := rt.region_nodes["index-status"]
	testing.expect(t, !indexed, "a node that stops being a region must leave the index")
	testing.expect(t, region_index_is_consistent(&rt), "the container transition index must be consistent")

	// Restore the region form; it must be indexed again.
	invalidate_root(&rt, "restore the region identity")
	ui, build = begin_frame(&rt)
	testing.expect(t, build, "the restored region frame must describe")
	region_index_test_root_begin(&ui, "region-index-transition-root")
	restored_id, restored_reused := region_begin(&ui, "index-status", 1, source)
	if restored_id != 0 && !restored_reused {
		text(&ui, "status", key=key_string("index-status-text"))
		region_end(&ui, restored_id, false, 0)
	}
	container_end(&ui)
	end_frame(&ui)
	testing.expect(t, restored_id == region_id && rt.nodes[region_id].region, "the restored region must reuse its identity")
	testing.expect(t, region_index_test_check_key(t, &rt, "index-status"), "the restored region must be indexed under its key")

	// Rekey the region. Region identity includes the key, so the old node retires
	// and the new node owns the new entry; the old key must leave the index.
	invalidate_root(&rt, "rekey the region")
	ui, build = begin_frame(&rt)
	testing.expect(t, build, "the rekeyed region frame must describe")
	region_index_test_root_begin(&ui, "region-index-transition-root")
	rekeyed_id, rekeyed_reused := region_begin(&ui, "index-status-renamed", 1, source)
	if rekeyed_id != 0 && !rekeyed_reused {
		text(&ui, "status", key=key_string("index-status-text"))
		region_end(&ui, rekeyed_id, false, 0)
	}
	container_end(&ui)
	end_frame(&ui)
	testing.expect(t, rekeyed_id != 0 && rekeyed_id != region_id, "a rekeyed region must take a new identity")
	_, old_indexed := rt.region_nodes["index-status"]
	testing.expect(t, !old_indexed, "the old region key must leave the index after a rekey")
	testing.expect(t, region_index_test_check_key(t, &rt, "index-status-renamed"), "the new key must resolve through the index")
	testing.expect(t, region_index_is_consistent(&rt), "the rekeyed index must be consistent")
	if entry, entry_found := rt.region_nodes["index-status-renamed"]; entry_found {
		testing.expect(t, len(entry.nodes) == 1 && entry.nodes[0] == rekeyed_id,
			"the new key must index exactly the rekeyed node")
	}
}

region_index_test_random :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return state^ >> 33
}

region_index_test_describe_model :: proc(ui: ^UI, items: []Region_Index_Test_Item, scopes: []string) {
	container_begin(ui, .Root, key=key_string("region-index-random-root"), style=layout_style(.Column, gap=1))
	for scope_name, scope_index in scopes {
		if !key_scope_begin(ui, key_string(scope_name)) { continue }
		for &item in items {
			if item.scope != scope_index || !item.present { continue }
			source := site("tests/region-index-random.odin", 40, 1, "region-index-random")
			id, reused := region_begin(ui, item.key, item.revision, source)
			if id != 0 && !reused {
				text(ui, item.key, key=key_string(item.key))
				region_end(ui, id, false, 0)
			}
		}
		key_scope_end(ui)
	}
	container_end(ui)
}

@(test)
test_region_index_matches_linear_scan_under_randomized_updates :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 640, 480})
	defer destroy_runtime(&rt)

	keys := []string{"random-a", "random-b", "random-c", "random-d"}
	scopes := []string{"random-scope-0", "random-scope-1"}
	items: [8]Region_Index_Test_Item
	for &item, index in items {
		item.scope = index / len(keys)
		item.key = keys[index % len(keys)]
		item.present = index < len(keys)
		item.revision = 1
	}

	state := u64(0x2545f4914f6cdd1d)
	// Describe the initial model so invalidations have retained regions to
	// resolve before the randomized sequence begins.
	invalidate_root(&rt, "randomized region-index initial frame")
	ui, build := begin_frame(&rt)
	testing.expect(t, build, "the randomized fixture must describe its first frame")
	region_index_test_describe_model(&ui, items[:], scopes[:])
	end_frame(&ui)
	for iteration in 0 ..< 120 {
		switch region_index_test_random(&state) % 4 {
		case 0:
			// Toggle one instance: exercises creation and retirement of one
			// instance while another scope may keep the same key alive.
			index := int(region_index_test_random(&state) % u64(len(items)))
			items[index].present = !items[index].present
		case 1:
			// Bump every live instance of one key and invalidate that key, which
			// is the app-owned revision pattern the public API documents.
			key_index := int(region_index_test_random(&state) % u64(len(keys)))
			revision := u64(0)
			live := false
			for &item in items {
				if item.present && item.key == keys[key_index] {
					live = true
					if item.revision > revision { revision = item.revision }
				}
			}
			if live {
				revision += 1
				for &item in items {
					if item.present && item.key == keys[key_index] { item.revision = revision }
				}
				invalidate_region(&rt, keys[key_index], revision, "randomized region update")
			}
		case 2:
			// Reorder two entries; retention and the index must not depend on
			// description order.
			left := int(region_index_test_random(&state) % u64(len(items)))
			right := int(region_index_test_random(&state) % u64(len(items)))
			if left != right { items[left], items[right] = items[right], items[left] }
		case 3:
			// No application change: the index must survive an idle reconciliation
			// without accumulating or dropping entries.
		}

		invalidate_root(&rt, "randomized region-index frame")
		ui, build := begin_frame(&rt)
		if !build {
			testing.expect(t, false, "the randomized fixture must describe every requested frame")
			return
		}
		region_index_test_describe_model(&ui, items[:], scopes[:])
		end_frame(&ui)

		if rt.hard_error {
			testing.expectf(t, false, "randomized region updates must not trigger diagnostics at iteration %d", iteration)
			return
		}
		if !region_index_is_consistent(&rt) {
			testing.expectf(t, false, "the region index must stay consistent at iteration %d", iteration)
			return
		}
		for key in keys {
			if !region_index_test_check_key(t, &rt, key) {
				testing.expectf(t, false, "indexed lookup must match the linear scan at iteration %d", iteration)
				return
			}
		}
	}

	// The model and the index must agree on the live instance count after the
	// sequence, not merely per key.
	live_model := 0
	for item in items { if item.present { live_model += 1 } }
	live_index := 0
	for _, entry in rt.region_nodes { live_index += len(entry.nodes) }
	testing.expectf(t, live_index == live_model, "the index must hold one entry per live instance (%d indexed, %d model)",
		live_index, live_model)
}
