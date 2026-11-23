package main

import "core:testing"
import "core:fmt"
import alicorn "alicorn:runtime"
import testui "alicorn:testui"
import ui "alicorn:ui"

gallery_interaction_test_app :: proc(section: Section) -> (app: App, ok: bool) {
	name, name_ok := ui.text_buffer("Alicorn")
	if !name_ok { return }
	app = App{
		name=name,
		section=section,
		gain=0.65,
		density_key=2,
		selected_record=41,
		record_count=GALLERY_RECORD_COUNT,
		selected_order=0,
		active_doc=0,
		motion_choice=0,
		theme_choice=.Ember,
		theme_choice_explicit=true,
		signal_preset=.Harmonic,
		signal_position=1,
		signal_show_grid=true,
		docs={
			{title="main.odin", open=true, dirty=true},
			{title="theme.json", open=true, dirty=false},
			{title="README.md", open=true, dirty=false},
		},
		order={
			{id=101, label="Foundations"},
			{id=102, label="Controls"},
			{id=103, label="Collections"},
			{id=104, label="Layout"},
			{id=105, label="Overlays"},
		},
	}
	return app, true
}

gallery_interaction_test_initialize :: proc(data: rawptr, rt: ^alicorn.Runtime) {
	gallery_initialize(cast(^App)data, rt)
}

@(test)
test_gallery_narrow_layout_and_scroll_interactions :: proc(t: ^testing.T) {
	app, app_ok := gallery_interaction_test_app(.Collections)
	if !testing.expect(t, app_ok, "the gallery fixture should initialize its text buffer") { return }
	defer ui.text_buffer_destroy(&app.name)
	handle, status := testui.open(
		&app,
		render,
		width=720,
		height=800,
		initialize=gallery_interaction_test_initialize,
		render_overlays=gallery_render_overlays,
	)
	if !testing.expect(t, status == .Ok, "TestUI should render the actual Collections section") { return }
	defer testui.close(&handle)
	defer gallery_stop(&app)

	panel_keys := [4]string{
		"collections-records",
		"collections-scroll",
		"collections-documents",
		"collections-drag",
	}
	previous_bottom := f32(0)
	for key in panel_keys {
		id, found := alicorn.node_by_key(handle.runtime, alicorn.key_string(key), .Container)
		if !testing.expect(t, found, fmt.tprintf("every narrow-layout collection card should be retained: missing %s", key)) { return }
		node := handle.runtime.nodes[id]
		if previous_bottom > 0 {
			if !testing.expect(t, node.bounds.y >= previous_bottom-1,
				fmt.tprintf("stacked cards should not overlap at the narrow breakpoint: viewport=%.1f key=%s x=%.1f y=%.1f w=%.1f h=%.1f previous_bottom=%.1f",
					handle.runtime.viewport.w, key, node.bounds.x, node.bounds.y, node.bounds.w, node.bounds.h, previous_bottom)) { return }
		}
		previous_bottom = node.bounds.y+node.bounds.h
	}
	columns_id, columns_found := alicorn.node_by_key(handle.runtime, alicorn.key_string("gallery-demo-columns"), .Container)
	if !testing.expect(t, columns_found && handle.runtime.nodes[columns_id].style.direction == .Column,
		"the gallery must select the stacked layout below its two-column breakpoint") { return }

	inner_id, found := alicorn.node_by_key(handle.runtime, alicorn.key_string("gallery-scroll-region"), .Scroll_Region)
	if !testing.expect(t, found, "the plain scroll example should be present") { return }
	inner := handle.runtime.nodes[inner_id]
	if !testing.expect(t, inner.scroll_content_height >= 22*22 && inner.scrollbar_vertical_visible,
		"the gallery's fully described scroll example should derive a usable extent") { return }
	first_line_id, first_line_found := alicorn.node_by_key(handle.runtime, alicorn.key_u64(900), .Text)
	if !testing.expect(t, first_line_found,
		"the first real gallery scroll row should have retained geometry") { return }
	first_line_y := handle.runtime.nodes[first_line_id].bounds.y
	if !testing.expect(t, alicorn.focus(handle.runtime, inner_id),
		"the gallery scroll region should accept keyboard focus") { return }
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Down})
	if !testing.expect(t, status == .Ok && alicorn.scroll_region_offset(handle.runtime, inner_id) > 0,
		"Arrow Down should scroll the focused gallery region") { return }
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Page_Down})
	if !testing.expect(t, status == .Ok && alicorn.scroll_region_offset(handle.runtime, inner_id) > 22,
		"Page Down should scroll the focused gallery region by a viewport") { return }
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Home})
	if !testing.expect(t, status == .Ok && alicorn.scroll_region_offset(handle.runtime, inner_id) == 0,
		"Home should return the focused gallery region to its first line") { return }
	inner_viewport := inner.scroll_viewport_bounds
	status = testui.step(&handle, testui.Input{
		kind=.Scroll,
		scroll=alicorn.Scroll_Event{
			delta_y=-1,
			x=inner_viewport.x+inner_viewport.w*0.5,
			y=inner_viewport.y+inner_viewport.h*0.5,
		},
	})
	if !testing.expect(t, status == .Ok && alicorn.scroll_region_offset(handle.runtime, inner_id) > 0,
		"wheel input should move the gallery's nested scroll region") { return }
	inner = handle.runtime.nodes[inner_id]
	first_line := handle.runtime.nodes[first_line_id]
	if !testing.expect(t, first_line.bounds.y < first_line_y &&
		first_line.clip == inner.scroll_viewport_bounds,
		"wheel input should move the gallery's actual retained rows while its viewport stays fixed") { return }
	inner_thumb := inner.scrollbar_vertical_thumb
	inner_track := inner.scrollbar_vertical_track
	status = testui.step(&handle, testui.Input{kind=.Pointer, pointer=alicorn.Pointer_Event{
		kind=.Down,
		x=inner_thumb.x+inner_thumb.w*0.5,
		y=inner_thumb.y+inner_thumb.h*0.5,
		button=alicorn.POINTER_BUTTON_PRIMARY,
	}})
	if !testing.expect(t, status == .Ok, "the nested gallery scrollbar thumb should accept pointer input") { return }
	status = testui.step(&handle, testui.Input{kind=.Pointer, pointer=alicorn.Pointer_Event{
		kind=.Move,
		x=inner_thumb.x+inner_thumb.w*0.5,
		y=inner_track.y+inner_track.h-1,
	}})
	inner = handle.runtime.nodes[inner_id]
	first_line = handle.runtime.nodes[first_line_id]
	if !testing.expect(t, status == .Ok &&
		alicorn.scroll_region_offset(handle.runtime, inner_id) >= inner.scroll_content_height-inner.scroll_viewport_height-1,
		"dragging the actual gallery thumb should reach the final scroll rows") { return }
	if !testing.expect(t, first_line.bounds.y < first_line_y-(inner.scroll_content_height-inner.scroll_viewport_height)+1 &&
		first_line.clip == inner.scroll_viewport_bounds,
		"dragging the actual gallery thumb should move its retained rows to the end without moving the viewport") { return }
	_ = testui.step(&handle, testui.Input{kind=.Pointer, pointer=alicorn.Pointer_Event{
		kind=.Up,
		x=inner_thumb.x+inner_thumb.w*0.5,
		y=inner_track.y+inner_track.h-1,
		button=alicorn.POINTER_BUTTON_PRIMARY,
	}})
	outer_id, outer_found := alicorn.node_by_key(
		handle.runtime,
		alicorn.key_u64(u64(int(Section.Collections)+1)),
		.Scroll_Region,
	)
	outer, outer_node_found := handle.runtime.nodes[outer_id]
	if !testing.expect(t, outer_found && outer_node_found &&
		outer.scroll_content_height > outer.scroll_viewport_height,
		"the whole gallery section should be measured beyond its viewport") { return }
	outer_offset_before_nested_edge := alicorn.scroll_region_offset(handle.runtime, outer_id)
	status = testui.step(&handle, testui.Input{kind=.Scroll, scroll=alicorn.Scroll_Event{
		delta_y=-1,
		x=inner_viewport.x+inner_viewport.w*0.5,
		y=inner_viewport.y+inner_viewport.h*0.5,
	}})
	if !testing.expect(t, status == .Ok &&
		alicorn.scroll_region_offset(handle.runtime, inner_id) >= inner.scroll_content_height-inner.scroll_viewport_height-1 &&
		alicorn.scroll_region_offset(handle.runtime, outer_id) > outer_offset_before_nested_edge,
		"wheel input at the nested region's end should continue scrolling the gallery page") { return }

	outer_viewport := outer.scroll_viewport_bounds
	status = testui.step(&handle, testui.Input{
		kind=.Scroll,
		scroll=alicorn.Scroll_Event{
			delta_y=-1,
			x=outer_viewport.x+outer_viewport.w-8,
			y=outer_viewport.y+8,
		},
	})
	testing.expect(t, status == .Ok && alicorn.scroll_region_offset(handle.runtime, outer_id) > 0,
		"wheel input over ordinary section content should scroll the page")
}

@(test)
test_gallery_dialog_escape_restores_safe_focus :: proc(t: ^testing.T) {
	app, app_ok := gallery_interaction_test_app(.Overlays)
	if !testing.expect(t, app_ok, "the gallery fixture should initialize its text buffer") { return }
	defer ui.text_buffer_destroy(&app.name)
	handle, status := testui.open(
		&app,
		render,
		width=900,
		height=800,
		initialize=gallery_interaction_test_initialize,
		render_overlays=gallery_render_overlays,
	)
	if !testing.expect(t, status == .Ok, "TestUI should render the actual Overlays section") { return }
	defer testui.close(&handle)
	defer gallery_stop(&app)
	app.record_count = 3
	app.selected_record = 1

	opener := testui.find(&handle, testui.Query{
		role=.Button,
		name="Open confirmation dialog",
		match_role=true,
		match_name=true,
	})
	defer testui.destroy_find_result(&opener)
	if !testing.expect(t, opener.match == .Unique && opener.element.has_bounds,
		fmt.tprintf("the confirmation dialog trigger should exist with bounds, got %v status %v", opener.match, opener.status)) { return }
	opener_bounds := opener.element.bounds
	status = testui.click_at(&handle, opener_bounds.x+opener_bounds.w*0.5, opener_bounds.y+opener_bounds.h*0.5)
	if !testing.expect(t, status == .Ok && app.dialog_open && app.dialog_opener == opener.element.visual_node,
		"clicking the real dialog trigger should open the modal and retain its opener") { return }

	cancel, cancel_found := alicorn.node_by_key(handle.runtime, alicorn.key_string("dialog-cancel"), .Button)
	if !testing.expect(t, cancel_found && alicorn.focused_node(handle.runtime) == cancel,
		"a destructive confirmation should place initial keyboard focus on Cancel") { return }
	status = testui.step(&handle, testui.Input{kind=.Key, key=.Escape})
	testing.expect(t, status == .Ok && !app.dialog_open,
		"Escape should dismiss the modal through its interaction scope")
	testing.expect(t, alicorn.focused_node(handle.runtime) == opener.element.visual_node,
		"dismissing the modal should restore focus to its opener")
	testing.expect(t, app.record_count == 3 && app.selected_record == 1,
		"Escape should cancel without changing the sample collection")

	status = testui.click_at(&handle, opener_bounds.x+opener_bounds.w*0.5, opener_bounds.y+opener_bounds.h*0.5)
	if !testing.expect(t, status == .Ok && app.dialog_open, "the same trigger should reopen the modal") { return }
	delete, delete_found := alicorn.node_by_key(handle.runtime, alicorn.key_string("dialog-delete"), .Button)
	if !testing.expect(t, delete_found, "the modal should expose its destructive action") { return }
	delete_bounds := handle.runtime.nodes[delete].bounds
	status = testui.click_at(&handle, delete_bounds.x+delete_bounds.w*0.5, delete_bounds.y+delete_bounds.h*0.5)
	testing.expect(t, status == .Ok && !app.dialog_open && app.record_count == 2 &&
		app.record_ids[0] == 0 && app.record_ids[1] == 2 && app.selected_record == 2,
		"confirming should remove the selected row, preserve remaining identities, and select the next row")
}
