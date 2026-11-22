package main

import "core:fmt"
import "core:math"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

SIGNAL_CARD_HEIGHT :: f32(394)
SIGNAL_PLOT_HEIGHT :: f32(244)
SIGNAL_PLOT_INSET :: f32(14)
SIGNAL_FILL_BIN_COUNT :: 192
SIGNAL_MIN_TRACE_POINTS :: 96
SIGNAL_MAX_TRACE_POINTS :: 360
SIGNAL_TRACE_SPACING_PIXELS :: f32(3.5)
SIGNAL_POSITIONS := [3]int{250, 500, 750}

Signal_Preset :: enum u64 { Harmonic = 1, Triangle, Pulse }

Signal_Plot :: struct {
	surface:       alicorn.Node_ID,
	width, height: f32,
	pixel_width:   int,
	preset:        Signal_Preset,
	gain:          f32,
	show_grid:     bool,
	accent, grid:  ui.Color,
}

gallery_showcase :: proc(app: ^App, ctx: ^ui.UI) {
	wide := ctx.runtime.viewport.w >= 820
	direction := alicorn.Layout_Direction.Row if wide else .Column
	height := SIGNAL_CARD_HEIGHT if wide else alicorn.LAYOUT_SIZE_FIT_CONTENT
	if alicorn.container_begin(ctx, .Container, key="signal-workbench",
		style=ui.layout_style(direction, height=height, gap=14)) != 0 {
		gallery_signal_chart(app, ctx, wide)
		gallery_signal_controls(app, ctx, wide)
		alicorn.container_end(ctx)
	}
	if ui.panel(ctx, key="signal-source", padding=16, gap=8, radius=12,
		fill=alicorn.style_color(ctx, .Editor_Background), label="Signal workbench source") {
		if ui.row(ctx, gap=12, align=.Center, justify=.Space_Between) {
			gallery_card_title(ctx, "From the source")
			ui.text(ctx, "showcase.odin", font=.Monospace, size=11, color=alicorn.style_color(ctx, .Muted_Text))
		}
		ui.text(ctx, `ui.slider_f32(ctx, "Gain", &app.gain, 0, 1, step=0.01)`, font=.Monospace, size=13,
			color=alicorn.style_color(ctx, .Text))
		ui.text(ctx, "The slider binds to an Odin value. The chart republishes its geometry when that value changes.",
			size=12, color=alicorn.style_color(ctx, .Muted_Text))
	}
	gallery_foundations(app, ctx)
}

gallery_signal_chart :: proc(app: ^App, ctx: ^ui.UI, wide: bool) {
	accent := alicorn.style_color(ctx, .Accent)
	muted := alicorn.style_color(ctx, .Muted_Text)
	chart := alicorn.surface_begin(ctx, alicorn.surface_core_color_role(.Subtle_Surface),
		key="signal-card", label="Signal workbench",
		style=ui.layout_style(.Column, height=-1 if wide else alicorn.LAYOUT_SIZE_FIT_CONTENT, grow=1 if wide else 0,
			padding=20, gap=12),
		shape=alicorn.surface_shape_rounded_corners({top_left=16, top_right=16, bottom_right=16, bottom_left=16}),
		gradient=alicorn.surface_gradient_to(alicorn.surface_core_color_role(.Surface)),
		stroke=alicorn.Paint_Stroke{color=alicorn.style_color(ctx, .Border), width=1},
		stroke_placement=.Inside)
	if chart == 0 { return }
	defer alicorn.surface_end(ctx)

	if ui.column(ctx, gap=3) {
		ui.text(ctx, "Signal workbench", size=34,
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_BOLD})
		ui.text(ctx, "Shape a waveform and move the playhead.", size=14, color=muted)
	}
	if ui.panel(ctx, key="signal-plot-frame", height=SIGNAL_PLOT_HEIGHT, radius=10, clip=true,
		fill=alicorn.style_color(ctx, .Editor_Background), label="Waveform plot") {
		gallery_signal_plot(app, ctx, accent)
	}
	if ui.row(ctx, gap=12, align=.Center, justify=.Space_Between) {
		labels := [5]string{"0 ms", "250", "500", "750", "1 s"}
		for label, index in labels {
			ui.text(ctx, label, key=ui.key_u64(u64(index+1)), size=11, font=.Monospace, decorative=true, color=muted)
		}
	}
}

gallery_signal_plot :: proc(app: ^App, ctx: ^ui.UI, accent: ui.Color) {
	track := [1]alicorn.Grid_Track{alicorn.grid_fraction(1)}
	if alicorn.grid_begin(ctx, "signal-plot-layers", track[:], track[:],
		style=ui.layout_style(.Column, grow=1, clip=true), label="Waveform and playhead") == 0 { return }
	defer alicorn.grid_end(ctx)

	app.signal_surface = alicorn.gpu_geometry_surface(ctx, "signal-waveform",
		ui.layout_style(.Column, clip=true))
	app.signal_accent = accent
	app.signal_grid_color = alicorn.style_color(ctx, .Border)
	_ = alicorn.grid_cell(ctx, app.signal_surface, 0, 0)

	// The playhead is an inert retained surface. Only its paint transform moves.
	// Wait for the first measured width so it starts at the selected time.
	width := app.signal_plot.width
	if width <= 2*SIGNAL_PLOT_INSET { return }
	overlay := alicorn.container_begin(ctx, .Container, key="signal-playhead-layer",
		style=ui.layout_style(.Row, align=.Start, clip=true))
	if overlay != 0 {
		marker := ui.box(ctx, key="signal-playhead", width=2, height=SIGNAL_PLOT_HEIGHT,
			fill=accent)
		position := f64(SIGNAL_POSITIONS[app.signal_position]) / 1000
		x := f64(SIGNAL_PLOT_INSET) + position*f64(max(width-2*SIGNAL_PLOT_INSET, 0))
		_ = ui.motion(ctx, marker, ui.Motion_Target{translation={x, 0}, has_translation=true})
		alicorn.container_end(ctx)
		_ = alicorn.grid_cell(ctx, overlay, 0, 0)
	}
}

gallery_signal_controls :: proc(app: ^App, ctx: ^ui.UI, wide: bool) {
	muted := alicorn.style_color(ctx, .Muted_Text)
	if ui.panel(ctx, key="signal-controls", width=260 if wide else -1,
		height=-1 if wide else alicorn.LAYOUT_SIZE_FIT_CONTENT, padding=18, gap=12, radius=14,
		justify=.Space_Between if wide else .Start,
		fill=alicorn.style_color(ctx, .Window_Background),
		stroke=ui.border(1, alicorn.style_color(ctx, .Border)), label="Signal controls") {
		ui.text(ctx, "Signal controls", size=18,
			text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
		if ui.column(ctx, gap=6) {
			ui.text(ctx, "Waveform", size=13, color=muted, decorative=true)
			continuous := [2]alicorn.Select_Option{
				{key=u64(Signal_Preset.Harmonic), label="Harmonic"},
				{key=u64(Signal_Preset.Triangle), label="Triangle"},
			}
			digital := [1]alicorn.Select_Option{{key=u64(Signal_Preset.Pulse), label="Pulse"}}
			groups := [2]alicorn.Select_Group{
				{label="Continuous", options=continuous[:]},
				{label="Digital", options=digital[:]},
			}
			choice := alicorn.select_control_grouped(ctx, "signal-preset", "Waveform", groups[:],
				u64(app.signal_preset), style=ui.layout_style(width=-1, height=36))
			if choice.changed { app.signal_preset = Signal_Preset(choice.selected_key) }
		}
		if ui.row(ctx, gap=10, height=42, align=.Center) {
			_ = ui.slider_f32(ctx, "Gain", &app.gain, 0, 1, step=0.01, key="signal-gain", height=42, grow=1)
			_ = alicorn.semantic_range_value_text(ctx, fmt.tprintf("%.0f percent", app.gain*100))
			ui.text(ctx, fmt.tprintf("%.0f%%", app.gain*100), size=13, font=.Monospace,
				style=ui.layout_style(width=36), decorative=true, color=muted)
		}
		_ = ui.checkbox(ctx, "Show grid", &app.signal_show_grid, key="signal-show-grid")
		if ui.column(ctx, gap=6) {
			ui.text(ctx, "Playhead", size=13, color=muted)
			if ui.row(ctx, gap=5) {
				for milliseconds, index in SIGNAL_POSITIONS {
					if ui.button(ctx, fmt.tprintf("%d ms", milliseconds), key=ui.key_u64(u64(index+1)),
						width=58, grow=1, height=32, variant=.Toolbar,
						text_style=alicorn.Text_Style{font_size=13, overflow=.Ellipsis},
						content_style=alicorn.button_content_style(.Center, .Center, padding_x=5),
						state=ui.Button_State{selected=index == app.signal_position}) {
						app.signal_position = index
					}
				}
			}
		}
	}
}

gallery_signal_sample :: proc(preset: Signal_Preset, t: f32) -> f32 {
	switch preset {
	case .Harmonic:
		phase := f32(2*math.PI)*t*3.15 + 0.35
		envelope := 0.45 + 0.55*math.sin(t*f32(math.PI))
		return envelope*(0.78*math.sin(phase) + 0.15*math.sin(2*phase+0.4) + 0.07*math.sin(3*phase))
	case .Triangle:
		cycle := t*3.5
		return 1 - 4*abs(cycle-math.floor(cycle)-0.5)
	case .Pulse:
		cycle := t*4
		return 0.80 if cycle-math.floor(cycle) < 0.42 else -0.45
	}
	return 0
}

gallery_signal_y :: proc(value, gain, height: f32) -> f32 {
	return height*0.5 - value*gain*height*0.44
}

gallery_update_signal :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app.section != .Overview { return }
	surface, ok := alicorn.gpu_surface_context(rt, app.signal_surface)
	if !ok { return }
	width, height := surface.logical_bounds.w, surface.logical_bounds.h
	if width <= 2*SIGNAL_PLOT_INSET || height <= 0 { return }
	plot := Signal_Plot{
		surface=app.signal_surface,
		width=width,
		height=height,
		pixel_width=surface.pixel_width,
		preset=app.signal_preset,
		gain=app.gain,
		show_grid=app.signal_show_grid,
		accent=app.signal_accent,
		grid=app.signal_grid_color,
	}
	if plot == app.signal_plot && surface.payload_revision != 0 { return }

	segments: [8]alicorn.GPU_Surface_Line_Segment
	shading: [SIGNAL_FILL_BIN_COUNT]alicorn.GPU_Surface_Filled_Rectangle
	path_points: [SIGNAL_MAX_TRACE_POINTS]alicorn.GPU_Surface_Point
	count := 0
	point_count := 0
	baseline := height/2
	plot_width := width-2*SIGNAL_PLOT_INSET
	pixel_scale_x := f32(surface.pixel_width)/width
	if surface.pixel_width <= 0 { pixel_scale_x = surface.dpi_scale }
	pixel_plot_width := plot_width*pixel_scale_x
	trace_point_count := clamp(
		int(math.ceil(pixel_plot_width/SIGNAL_TRACE_SPACING_PIXELS))+1,
		SIGNAL_MIN_TRACE_POINTS,
		SIGNAL_MAX_TRACE_POINTS,
	)
	if plot.show_grid {
		for i in 0..=4 {
			x := SIGNAL_PLOT_INSET + f32(i)*plot_width/4
			segments[count] = {{x, 8}, {x, height-8}, 1, plot.grid}
			count += 1
		}
		for i in 1..=3 {
			y := f32(i)*height/4
			segments[count] = {{SIGNAL_PLOT_INSET, y}, {width-SIGNAL_PLOT_INSET, y}, 1, plot.grid}
			count += 1
		}
	}

	switch plot.preset {
	case .Harmonic:
		for i in 0..<trace_point_count {
			t := f32(i)/f32(trace_point_count-1)
			x := SIGNAL_PLOT_INSET+t*plot_width
			y := gallery_signal_y(gallery_signal_sample(plot.preset, t), plot.gain, height)
			path_points[point_count] = {x, y}
			point_count += 1
		}
	case .Triangle:
		// The triangle wave is linear between these exact corners. Adding the
		// corners directly avoids moving them to a nearby uniform sample.
		for i in 0..=7 {
			t := f32(i)/7
			x := SIGNAL_PLOT_INSET+t*plot_width
			y := gallery_signal_y(gallery_signal_sample(plot.preset, t), plot.gain, height)
			path_points[point_count] = {x, y}
			point_count += 1
		}
	case .Pulse:
		// Preserve the square edges as vertical joins at their exact duty-cycle
		// boundaries instead of drawing a diagonal ramp across a sample interval.
		high_y := gallery_signal_y(0.80, plot.gain, height)
		low_y := gallery_signal_y(-0.45, plot.gain, height)
		path_points[point_count] = {SIGNAL_PLOT_INSET, high_y}
		point_count += 1
		for cycle in 0..<4 {
			high_end_t := (f32(cycle)+0.42)/4
			high_end_x := SIGNAL_PLOT_INSET+high_end_t*plot_width
			path_points[point_count] = {high_end_x, high_y}
			path_points[point_count+1] = {high_end_x, low_y}
			point_count += 2
			period_end_t := f32(cycle+1)/4
			period_end_x := SIGNAL_PLOT_INSET+period_end_t*plot_width
			path_points[point_count] = {period_end_x, low_y}
			path_points[point_count+1] = {period_end_x, high_y}
			point_count += 2
		}
	}

	shade := plot.accent
	shade.a = 0.10
	fill_count := SIGNAL_FILL_BIN_COUNT if plot.preset != .Pulse else 0
	fill_step := plot_width/f32(SIGNAL_FILL_BIN_COUNT)
	for i in 0..<fill_count {
		x0 := SIGNAL_PLOT_INSET+f32(i)*fill_step
		x1 := SIGNAL_PLOT_INSET+f32(i+1)*fill_step
		t := (f32(i)+0.5)/SIGNAL_FILL_BIN_COUNT
		y := gallery_signal_y(gallery_signal_sample(plot.preset, t), plot.gain, height)
		// Bins meet edge-to-edge; the former 14% gaps made the trace read as
		// a set of disconnected bars. Keep this fill much quieter than the line.
		shading[i] = {alicorn.Rect{x0, min(y, baseline), x1-x0, max(abs(y-baseline), 0.01)}, shade}
	}
	trace := alicorn.GPU_Surface_Stroke_Path{
		points=path_points[:point_count],
		thickness=1.8,
		color=plot.accent,
	}
	if alicorn.gpu_surface_update_geometry_with_rectangles_and_stroke_path(
		rt, plot.surface, shading[:fill_count], segments[:count], nil, trace,
	) {
		width_changed := plot.width != app.signal_plot.width
		app.signal_plot = plot
		if width_changed { alicorn.invalidate_root(rt, "Place the playhead in the resized plot") }
	}
}
