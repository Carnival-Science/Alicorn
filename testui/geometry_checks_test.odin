package testui

import "core:testing"
import alicorn "alicorn:runtime"

Geometry_Check_App :: struct {
	activations: int,
}

geometry_check_render :: proc(app: ^Geometry_Check_App, ui: ^alicorn.UI) {
	_ = alicorn.container_begin(ui, .Root,
		key=alicorn.key_string("geometry-check-root"),
		style=alicorn.layout_style(.Column, width=240, height=120, padding=8, gap=4))
	_ = alicorn.semantic_describe_as(ui,
		alicorn.Semantic_ID{namespace=0x544553545549, value=1}, .Dialog, "Panel")
	if alicorn.button(ui, "Save", key=alicorn.key_string("geometry-check-save"),
		style=alicorn.layout_style(width=160, height=32)) {
		app.activations += 1
	}
	alicorn.container_end(ui)
}

@(test)
test_layout_assertions_check_width_alignment_and_overflow :: proc(t: ^testing.T) {
	app := Geometry_Check_App{}
	h, status := open(&app, geometry_check_render, width=240, height=120)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)

	panel := find(&h, Query{role=.Dialog, name="Panel", match_role=true, match_name=true})
	defer destroy_find_result(&panel)
	save := find(&h, Query{role=.Button, name="Save", match_role=true, match_name=true})
	defer destroy_find_result(&save)
	if !testing.expect(t, panel.match == .Unique && save.match == .Unique &&
		panel.element.has_bounds && save.element.has_bounds,
		"the fixture should publish a measurable panel and button") { return }

	inside := expect_inside(&h, &save.element, &panel.element)
	testing.expect(t, inside.ok, layout_check_diagnostic(inside))
	visible_save := expect_visible_text(&h, &save.element, "Save")
	testing.expect(t, visible_save.ok, visible_text_diagnostic(visible_save))
	no_overflow := expect_no_overflow(&h, &save.element)
	testing.expect(t, no_overflow.ok, layout_check_diagnostic(no_overflow))

	width_mismatch := expect_fills_width(&h, &save.element, &panel.element)
	testing.expect(t, !width_mismatch.ok && width_mismatch.failure == .Width_Mismatch,
		"a fixed-width button should fail the parent-width assertion")
	filled := save.element
	filled.bounds.x = panel.element.bounds.x
	filled.bounds.w = panel.element.bounds.w
	filled_width := expect_fills_width(&h, &filled, &panel.element)
	testing.expect(t, filled_width.ok, layout_check_diagnostic(filled_width))

	aligned := expect_aligned(&h, &save.element, &save.element, .Center_Y)
	testing.expect(t, aligned.ok, layout_check_diagnostic(aligned))
	shifted := save.element
	shifted.bounds.y += 2
	misaligned := expect_aligned(&h, &shifted, &save.element, .Center_Y, tolerance=0.5)
	testing.expect(t, !misaligned.ok && misaligned.failure == .Alignment_Mismatch,
		"a shifted control should fail the center-alignment assertion")
}

@(test)
test_visible_text_assertion_requires_shaped_clipped_paint :: proc(t: ^testing.T) {
	app := Harness_Test_App{}
	defer if len(app.name) > 0 { delete(app.name) }
	h, status := open(&app, harness_test_render, width=240, height=120,
		on_text_change=harness_test_text_changed)
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	defer close(&h)

	field := find(&h, Query{role=.Text_Field, name="Name", match_role=true, match_name=true})
	if !testing.expect(t, field.match == .Unique && click(&h, &field.element) == .Ok,
		"the fixture field should be focusable through normal hit testing") {
		destroy_find_result(&field)
		return
	}
	testing.expect(t, step(&h, Input{kind=.Text_Commit, text="Ada"}) == .Ok,
		"the field should accept committed text")
	destroy_find_result(&field)

	field = find(&h, Query{role=.Text_Field, name="Name", match_role=true, match_name=true})
	defer destroy_find_result(&field)
	visible := expect_visible_text(&h, &field.element, "Ada")
	testing.expect(t, visible.ok, visible_text_diagnostic(visible))
	missing := expect_visible_text(&h, &field.element, "missing")
	testing.expect(t, !missing.ok && missing.failure == .Text_Not_Shaped,
		"text that is absent from the shaped run must fail the visibility assertion")
}
