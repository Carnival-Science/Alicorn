#+build !js
package alicorn

import "core:testing"

// A collection can name its semantic parent when it is published. Popup lists
// use this to belong to their trigger without reaching into the pending
// description record after semantic_collection_begin returns.

COLLECTION_PARENT_TEST_NAMESPACE :: u64(0x53454D434F4C5001)
COLLECTION_PARENT_TEST_ROOT :: u64(1)
COLLECTION_PARENT_TEST_LIST :: u64(2)
COLLECTION_PARENT_TEST_TRIGGER :: u64(3)
COLLECTION_PARENT_TEST_GROUP :: u64(0x20)
COLLECTION_PARENT_TEST_OPTION_BASE :: u64(0x10)

Collection_Parent_Test_Mode :: enum {
	// The popup panel passes the trigger's semantic ID as the collection parent.
	Explicit,
	// The popup panel omits the parent and keeps the semantic-ancestor fallback.
	Fallback,
	// The collection is described before its named parent entity exists.
	Forward,
}

Collection_Parent_Test_Frame :: struct {
	root_group: Semantic_ID,
	trigger: Semantic_ID,
	list: Semantic_ID,
	panel: Node_ID,
}

collection_parent_test_id :: proc(value: u64) -> Semantic_ID {
	return Semantic_ID{namespace=COLLECTION_PARENT_TEST_NAMESPACE, value=value}
}

collection_parent_test_item :: proc(
	ui: ^UI,
	collection: Semantic_Collection_Handle,
	position: u64,
	id: Semantic_ID,
	role: Semantic_Role,
	label: string,
	parent := Semantic_ID{},
) {
	row := container_begin_simple(
		ui,
		.Container,
		label=label,
		key=key_u64(0x5200+position),
		style=layout_style(.Row, height=24),
	)
	if row == 0 { return }
	_ = semantic_collection_item(ui, collection, position, Semantic_Node_Description{
		id=id,
		role=role,
		label=label,
		value=label,
		parent=parent,
	})
	container_end(ui)
}

collection_parent_test_panel :: proc(ui: ^UI, parent: Semantic_ID) -> (panel: Node_ID, collection: Semantic_Collection_Handle) {
	panel = container_begin_simple(
		ui,
		.Container,
		label="collection-parent-panel",
		key=key_string("collection-parent-panel"),
		style=layout_style(.Column, width=200, height=120),
	)
	if panel == 0 { return }
	collection = semantic_collection_begin(
		ui,
		panel,
		collection_parent_test_id(COLLECTION_PARENT_TEST_LIST),
		.List_Box,
		"Choices",
		2,
		realized_first=0,
		realized_last=2,
		parent=parent,
	)
	collection_parent_test_item(
		ui,
		collection,
		0,
		collection_parent_test_id(COLLECTION_PARENT_TEST_OPTION_BASE),
		.List_Box_Option,
		"One",
	)
	collection_parent_test_item(
		ui,
		collection,
		1,
		collection_parent_test_id(COLLECTION_PARENT_TEST_OPTION_BASE+1),
		.List_Box_Option,
		"Two",
	)
	container_end(ui)
	return
}

collection_parent_test_describe :: proc(ui: ^UI, mode: Collection_Parent_Test_Mode) -> Collection_Parent_Test_Frame {
	frame := Collection_Parent_Test_Frame{
		root_group=collection_parent_test_id(COLLECTION_PARENT_TEST_ROOT),
		trigger=collection_parent_test_id(COLLECTION_PARENT_TEST_TRIGGER),
		list=collection_parent_test_id(COLLECTION_PARENT_TEST_LIST),
	}
	root := container_begin_simple(
		ui,
		.Root,
		label="collection-parent-root",
		key=key_string("collection-parent-root"),
		style=layout_style(.Column, width=320, height=240, gap=8, padding=8),
	)
	if root == 0 { return frame }
	_ = semantic_describe_as(ui, frame.root_group, .Group, "Collection parent root")

	if mode == .Forward {
		// Describe the collection first: its named parent does not have a
		// semantic entity (or even a visual node) yet.
		frame.panel, _ = collection_parent_test_panel(ui, frame.trigger)
		trigger_node, _ := button_begin(ui, "Choose", key=key_string("collection-parent-trigger"), style=layout_style(width=160, height=32))
		if trigger_node != 0 { _ = semantic_bind(ui, frame.trigger) }
		button_end(ui)
	} else {
		trigger_node, _ := button_begin(ui, "Choose", key=key_string("collection-parent-trigger"), style=layout_style(width=160, height=32))
		if trigger_node != 0 { frame.trigger = semantic_visual_id(trigger_node) }
		button_end(ui)
		parent := Semantic_ID{}
		if mode == .Explicit { parent = frame.trigger }
		frame.panel, _ = collection_parent_test_panel(ui, parent)
	}

	container_end(ui)
	return frame
}

collection_parent_test_render :: proc(rt: ^Runtime, mode: Collection_Parent_Test_Mode) -> Collection_Parent_Test_Frame {
	invalidate_root(rt, "semantic collection parent fixture")
	ui, build := begin_frame(rt)
	if !build { return {} }
	frame := collection_parent_test_describe(&ui, mode)
	end_frame(&ui)
	return frame
}

@(test)
test_semantic_collection_begin_parent_overrides_visual_ancestry :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 240})
	defer destroy_runtime(&rt)
	frame := collection_parent_test_render(&rt, .Explicit)
	if !testing.expect(t, frame.panel != 0 && semantic_id_is_valid(frame.trigger),
		"the fixture should describe a popup panel and a trigger") { return }

	list, list_found := semantic_node_lookup(&rt, frame.list)
	option, option_found := semantic_node_lookup(&rt, collection_parent_test_id(COLLECTION_PARENT_TEST_OPTION_BASE))
	testing.expect(t, list_found && list.role == .List_Box && list.parent == frame.trigger &&
		list.parent != frame.root_group,
		"an explicit collection parent should name the trigger semantic entity instead of the visual ancestor")
	testing.expect(t, option_found && option.parent == frame.list && option.collection_id == frame.list,
		"collection items without their own parent should still name the List_Box")
}

@(test)
test_semantic_collection_begin_zero_parent_keeps_semantic_ancestor_fallback :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 240})
	defer destroy_runtime(&rt)
	frame := collection_parent_test_render(&rt, .Fallback)
	list, list_found := semantic_node_lookup(&rt, frame.list)
	testing.expect(t, list_found && list.parent == frame.root_group,
		"the zero parent default should keep the nearest described semantic ancestor")
}

@(test)
test_semantic_collection_parent_publishes_through_pending_and_unrealized_records :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 240})
	defer destroy_runtime(&rt)
	invalidate_root(&rt, "semantic collection parent pending fixture")
	ui, build := begin_frame(&rt)
	if !testing.expect(t, build, "the pending collection fixture should build") { return }
	frame := collection_parent_test_describe(&ui, .Forward)

	_, parent_realized := semantic_node_lookup(&rt, frame.trigger)
	_, owner_realized := rt.nodes[frame.panel]
	pending_parent := Semantic_ID{}
	pending_found := false
	for index := len(rt.pending)-1; index >= 0; index -= 1 {
		item := &rt.pending[index]
		if item.kind == .Description && item.description.id == frame.panel {
			pending_found = true
			pending_parent = item.semantic.parent
			break
		}
	}
	testing.expect(t, !parent_realized && !owner_realized,
		"the collection owner and its named parent should still be unrealized pending records")
	testing.expect(t, pending_found && pending_parent == frame.trigger,
		"semantic_collection_begin should write the explicit parent into the pending collection record")
	end_frame(&ui)

	list, list_found := semantic_node_lookup(&rt, frame.list)
	trigger, trigger_found := semantic_node_lookup(&rt, frame.trigger)
	testing.expect(t, list_found && trigger_found && trigger.role == .Button && list.parent == frame.trigger,
		"a forward-named parent should resolve after reconciliation without a second pending-record patch")

	frame = collection_parent_test_render(&rt, .Forward)
	list, list_found = semantic_node_lookup(&rt, frame.list)
	testing.expect(t, list_found && list.parent == frame.trigger,
		"the explicit parent should survive collection re-description in later frames")
}

@(test)
test_semantic_collection_parent_composes_with_group_item_parents :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 240})
	defer destroy_runtime(&rt)
	invalidate_root(&rt, "semantic collection grouped parent fixture")
	ui, build := begin_frame(&rt)
	if !testing.expect(t, build, "the grouped collection fixture should build") { return }

	group_id := collection_parent_test_id(COLLECTION_PARENT_TEST_GROUP)
	list_id := collection_parent_test_id(COLLECTION_PARENT_TEST_LIST)
	container_begin_simple(
		&ui,
		.Root,
		label="collection-parent-grouped-root",
		key=key_string("collection-parent-grouped-root"),
		style=layout_style(.Column, width=320, height=240, gap=8, padding=8),
	)
	trigger, _ := button_begin(&ui, "Choose", key=key_string("collection-parent-grouped-trigger"), style=layout_style(width=160, height=32))
	button_end(&ui)
	panel := container_begin_simple(
		&ui,
		.Container,
		label="collection-parent-grouped-panel",
		key=key_string("collection-parent-grouped-panel"),
		style=layout_style(.Column, width=200, height=160),
	)
	if panel != 0 {
		collection := semantic_collection_begin(
			&ui,
			panel,
			list_id,
			.List_Box,
			"Grouped choices",
			3,
			realized_first=0,
			realized_last=3,
			parent=semantic_visual_id(trigger),
		)
		collection_parent_test_item(
			&ui,
			collection,
			0,
			group_id,
			.Group,
			"Fruit",
			parent=list_id,
		)
		collection_parent_test_item(
			&ui,
			collection,
			1,
			collection_parent_test_id(COLLECTION_PARENT_TEST_OPTION_BASE),
			.List_Box_Option,
			"Apple",
			parent=group_id,
		)
		collection_parent_test_item(
			&ui,
			collection,
			2,
			collection_parent_test_id(COLLECTION_PARENT_TEST_OPTION_BASE+1),
			.List_Box_Option,
			"Other",
		)
		container_end(&ui)
	}
	container_end(&ui)
	end_frame(&ui)

	list, list_found := semantic_node_lookup(&rt, list_id)
	group, group_found := semantic_node_lookup(&rt, group_id)
	apple, apple_found := semantic_node_lookup(&rt, collection_parent_test_id(COLLECTION_PARENT_TEST_OPTION_BASE))
	other, other_found := semantic_node_lookup(&rt, collection_parent_test_id(COLLECTION_PARENT_TEST_OPTION_BASE+1))
	testing.expect(t, list_found && list.role == .List_Box && list.logical_count == 3 &&
		list.parent == semantic_visual_id(trigger),
		"the explicit collection parent should compose with a grouped List_Box")
	testing.expect(t, group_found && group.role == .Group && group.parent == list_id && group.collection_id == list_id,
		"a group header should remain a List_Box child while acting as an option parent")
	testing.expect(t, apple_found && apple.role == .List_Box_Option && apple.parent == group_id &&
		apple.collection_id == list_id && apple.position_in_set == 1,
		"a grouped option should name its Group through the item parent")
	testing.expect(t, other_found && other.role == .List_Box_Option && other.parent == list_id,
		"an ungrouped option should remain a direct List_Box child")
}
