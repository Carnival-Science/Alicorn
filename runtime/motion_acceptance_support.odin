#+build !js
package alicorn

// Shared fixtures for the issue #146 release-gate acceptance tests. Keeping
// them in one support file lets each gap's regression live in its own test
// file without duplicating retained-tree setup.

motion_acceptance_find_command :: proc(rt: ^Runtime, owner: Node_ID, target := false) -> (command: Paint_Command, found: bool) {
	commands := rt.display_target if target else rt.display
	for candidate in commands {
		if candidate.owner == owner { return candidate, true }
	}
	return
}

// motion_acceptance_build_nested composes four retained levels so a leaf
// command can prove translations add once per level instead of being scaled or
// re-applied at each ancestor.
motion_acceptance_build_nested :: proc(rt: ^Runtime) -> (levels: [3]Node_ID, leaf: Node_ID) {
	ui, ready := begin_frame(rt)
	if !ready { return }
	container_begin_simple(&ui, .Root, key="motion-nested-root", style=layout_style(.Column, width=240, height=160))
	for index in 0..<3 {
		key := key_string("motion-nested-level-0")
		switch index {
		case 1: key = key_string("motion-nested-level-1")
		case 2: key = key_string("motion-nested-level-2")
		}
		levels[index] = container_begin_simple(
			&ui, .Container, key=key,
			style=layout_style(.Column, width=200, height=120, padding=4),
		)
	}
	leaf = surface_begin(
		&ui, surface_core_color_role(.Accent), key="motion-nested-leaf",
		style=layout_style(.Row, width=40, height=20), fill=Color{0.7, 0.3, 0.2, 1},
	)
	surface_end(&ui)
	for _ in 0..<3 { container_end(&ui) }
	container_end(&ui)
	end_frame(&ui)
	return
}

// motion_acceptance_build_scrolled builds a virtualized list whose second
// visible row is scrolled into place. The row is a clipped moving container
// with a painted surface, so a Follow_Visual translation can be checked
// against an ancestor scroll clip without double-applying the scroll offset.
motion_acceptance_build_scrolled :: proc(rt: ^Runtime) -> (scroll, moving, leaf: Node_ID) {
	ui, ready := begin_frame(rt)
	if !ready { return }
	container_begin_simple(&ui, .Root, key="motion-scroll-root", style=layout_style(.Column, width=120, height=80))
	list := virtual_list_begin(
		&ui, 6, 20, key=key_string("motion-scroll-list"),
		style=layout_style(.Column, width=80, height=40),
		content_width=80, scrollbars=.Hidden, label="motion-scroll-list",
	)
	scroll = list.scroll.id
	for index in list.first..=list.last {
		if index == 2 {
			moving = container_begin_simple(
				&ui, .Container, key=key_u64(u64(index+1)),
				style=layout_style(.Column, width=80, height=20, clip=true),
			)
			leaf = surface_begin(
				&ui, surface_core_color_role(.Surface), key=key_u64(u64(index+1)+100),
				style=layout_style(.Row, width=40, height=20), fill=Color{0.2, 0.5, 0.8, 1},
			)
			surface_end(&ui)
			container_end(&ui)
		} else {
			_ = container_begin_simple(
				&ui, .Container, key=key_u64(u64(index+1)),
				style=layout_style(.Column, width=80, height=20),
			)
			container_end(&ui)
		}
	}
	virtual_list_end(&ui, list)
	container_end(&ui)
	end_frame(&ui)
	return
}

motion_acceptance_build_split :: proc(rt: ^Runtime) -> (split: Split_Handle, divider: Node_ID) {
	ui, ready := begin_frame(rt)
	if !ready { return }
	container_begin_simple(&ui, .Root, key="motion-direct-root", style=layout_style(.Row, width=400, height=200))
	split = split_begin(
		&ui, key_string("motion-direct-split"), .Horizontal, 200,
		min_first=40, min_second=40,
		style=layout_style(.Row, grow=1, height=200, clip=true),
	)
	_ = split_first_begin(&ui, split)
	split_first_end(&ui, split)
	divider = split_divider(&ui, split, thickness=2, hit_size=10)
	_ = split_second_begin(&ui, split)
	split_second_end(&ui, split)
	split_end(&ui, split)
	container_end(&ui)
	end_frame(&ui)
	return
}

motion_acceptance_build_indexed :: proc(rt: ^Runtime) -> (target, sibling: Node_ID) {
	ui, ready := begin_frame(rt)
	if !ready { return }
	container_begin_simple(&ui, .Root, key="motion-hit-root", style=layout_style(.Row, width=240, height=120))
	circle, _ := button_begin(
		&ui, "C", key=key_string("motion-hit-circle"),
		style=layout_style(.Row, width=40, height=40), pointer_hit_shape=.Circle,
	)
	button_end(&ui)
	target, _ = button_begin(
		&ui, "T", key=key_string("motion-hit-target"),
		style=layout_style(.Row, width=60, height=30),
	)
	button_end(&ui)
	sibling = surface_begin(
		&ui, surface_core_color_role(.Surface), key="motion-hit-sibling",
		style=layout_style(.Row, width=40, height=20), fill=Color{0.3, 0.3, 0.3, 1},
	)
	surface_end(&ui)
	_ = circle
	container_end(&ui)
	end_frame(&ui)
	return
}
