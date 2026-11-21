package alicorn_sdl_gpu

// Mixed-DPI / monitor-transition parity coverage for the reference SDL_GPU host.
//
// The hosted WebGPU path has an end-to-end window fixture that injects the same
// metric sequence (tools/validate_native_webgpu_dpi.ps1). These tests exercise
// the reference host's adoption function directly with synthetic
// per-monitor measurements so both hosts can be compared without a second
// physical display: logical geometry and pointer mapping are invariant, the
// presentation scale follows the drawable, and display-scale metadata changes
// rebuild the description even when the logical size does not change.

import "core:testing"
import alicorn "../../runtime"

DPI_Transition_Test_State :: struct {
	button: alicorn.Node_ID,
	text:   alicorn.Node_ID,
	builds: int,
	dpi:    f32,
}

dpi_transition_test_build :: proc(
	state: rawptr,
	rt: ^alicorn.Runtime,
	logical_width, logical_height: int,
	dpi_scale: f32,
) -> alicorn.Node_ID {
	app := cast(^DPI_Transition_Test_State)state
	app.builds += 1
	app.dpi = dpi_scale
	ui, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(
		&ui,
		.Root,
		label="dpi-transition-root",
		key="dpi-transition-root",
		style=alicorn.layout_style(
			.Column, width=f32(logical_width), height=f32(logical_height), gap=8,
		),
	)
	app.text = alicorn.text(
		&ui, "DPI transition probe", key=alicorn.key_string("dpi-transition-text"),
	)
	app.button, _ = alicorn.button_ex(
		&ui, "Known target", key="dpi-transition-button",
		style=alicorn.layout_style(width=140, height=36),
	)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return root
}

dpi_transition_metrics :: proc(
	scale, pixel_density: f32,
) -> Window_Metrics {
	width := 800
	height := 600
	return Window_Metrics{
		logical_width=width,
		logical_height=height,
		window_logical_height=height,
		pixel_width=int(f32(width)*pixel_density+0.5),
		pixel_height=int(f32(height)*pixel_density+0.5),
		pixel_density=pixel_density,
		display_scale=scale,
	}
}

@(test)
test_dpi_transition_preserves_logical_bounds_and_hit_testing :: proc(t: ^testing.T) {
	state: DPI_Transition_Test_State
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&rt)
	_ = dpi_transition_test_build(&state, &rt, 800, 600, 1)
	if state.button == 0 || state.text == 0 {
		testing.expect(t, false, "the DPI fixture must build its known nodes")
		return
	}
	baseline_button := rt.nodes[state.button].bounds
	baseline_text := rt.nodes[state.text].bounds
	metrics := dpi_transition_metrics(1, 1)
	center_x := baseline_button.x+baseline_button.w*0.5
	center_y := baseline_button.y+baseline_button.h*0.5
	testing.expect(t, alicorn.hit_test(&rt, center_x, center_y) == state.button,
		"the baseline pointer position must hit the fixture button")

	scales := []f32{1.25, 1.5, 1.75, 1.25, 1}
	for scale in scales {
		current := dpi_transition_metrics(scale, scale)
		changed := native_window_metrics_apply(&rt, &metrics, current)
		testing.expectf(t, changed, "scale %.2f must be observed as a metrics change", scale)
		testing.expectf(t, rt.presentation_scale_x == scale && rt.presentation_scale_y == scale,
			"presentation scale must follow the drawable at %.2f", scale)
		testing.expectf(t, rt.invalidated, "scale %.2f must invalidate the application description", scale)
		_ = dpi_transition_test_build(&state, &rt, 800, 600, scale)
		testing.expectf(t, rt.nodes[state.button].bounds == baseline_button &&
			rt.nodes[state.text].bounds == baseline_text,
			"logical bounds must be invariant across scale %.2f", scale)
		testing.expectf(t, alicorn.hit_test(&rt, center_x, center_y) == state.button,
			"the same logical pointer position must hit the same node at scale %.2f", scale)
		testing.expectf(t, state.dpi == scale,
			"the application must receive display scale %.2f", scale)
	}
}

@(test)
test_dpi_transition_metadata_scale_change_rebuilds_without_moving_geometry :: proc(t: ^testing.T) {
	state: DPI_Transition_Test_State
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 800, 600})
	defer alicorn.destroy_runtime(&rt)
	_ = dpi_transition_test_build(&state, &rt, 800, 600, 1.5)
	metrics := dpi_transition_metrics(1.5, 1.5)
	baseline_button := rt.nodes[state.button].bounds
	rt.invalidated = false

	// Content scale changes while the framebuffer ratio stays fixed. Some
	// platforms (and Windows text-scaling modes) can report this combination;
	// descriptions sized from display_scale must still be rebuilt.
	metadata := dpi_transition_metrics(1.25, 1.5)
	changed := native_window_metrics_apply(&rt, &metrics, metadata)
	testing.expect(t, changed, "a metadata-only display-scale change must be observed")
	testing.expect(t, rt.invalidated, "a metadata-only display-scale change must rebuild the description")
	testing.expect(t, rt.presentation_scale_x == 1.5 && rt.presentation_scale_y == 1.5,
		"the device grid must keep following the unchanged drawable ratio")
	_ = dpi_transition_test_build(&state, &rt, 800, 600, 1.25)
	testing.expect(t, rt.nodes[state.button].bounds == baseline_button && state.dpi == 1.25,
		"metadata-only scale changes must not move logical geometry and must reach the application")
	center_x := baseline_button.x+baseline_button.w*0.5
	center_y := baseline_button.y+baseline_button.h*0.5
	testing.expect(t, alicorn.hit_test(&rt, center_x, center_y) == state.button,
		"hit testing must remain valid after a metadata-only scale change")
}
