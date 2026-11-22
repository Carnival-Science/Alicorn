package main

// Layout and surfaces: retained split panes, the shared-track Grid, surface-local
// positioned labels, theme-resolved gradient/shape primitives, and a bounded
// retained geometry surface.

import "core:fmt"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

gallery_split_demo :: proc(ctx: ^ui.UI) {
	split := alicorn.split_begin(
		ctx,
		"gallery-split",
		.Horizontal,
		220,
		min_first=132,
		min_second=180,
		style=ui.layout_style(.Row, height=178, clip=true),
		label="Draggable split panes",
	)
	if split.id == 0 { return }
	if alicorn.split_first_begin(ctx, split) != 0 {
		if ui.column(ctx, padding=10, gap=4) {
			ui.text(ctx, "Navigator pane", size=12, text_style=alicorn.Text_Style{
				font_weight=alicorn.FONT_WEIGHT_SEMIBOLD,
			})
			ui.text(ctx, "Drag the divider.", size=11, color=alicorn.style_color(ctx, .Muted_Text))
			ui.text(ctx, "• main.odin", size=12)
			ui.text(ctx, "• controls.odin", size=12)
			ui.text(ctx, "• collections.odin", size=12)
		}
		alicorn.split_first_end(ctx, split)
	}
	_ = alicorn.split_divider(ctx, split, 2, 10)
	if alicorn.split_second_begin(ctx, split) != 0 {
		if ui.column(ctx, padding=10, gap=6) {
			ui.text(ctx, "Preview pane", size=12, text_style=alicorn.Text_Style{
				font_weight=alicorn.FONT_WEIGHT_SEMIBOLD,
			})
			ui.text(ctx, "The split owns only a preferred extent; panes stay clipped while the window resizes.",
				size=11, color=alicorn.style_color(ctx, .Muted_Text))
			if ui.panel(ctx, grow=1, padding=8, fill=alicorn.style_color(ctx, .Subtle_Surface), radius=5) {
				ui.text(ctx, "Nested surfaces keep ordinary layout.", size=11)
			}
		}
		alicorn.split_second_end(ctx, split)
	}
	alicorn.split_end(ctx, split)
}

gallery_grid_demo :: proc(ctx: ^ui.UI) {
	columns := [2]alicorn.Grid_Track{alicorn.grid_fixed(92), alicorn.grid_fraction(1)}
	rows := [3]alicorn.Grid_Track{alicorn.grid_auto(), alicorn.grid_auto(), alicorn.grid_auto()}
	if alicorn.grid_begin(
		ctx,
		"gallery-details-grid",
		columns[:],
		rows[:],
		style=ui.layout_style(.Column, width=-1, height=90),
		gap_x=8,
		gap_y=4,
		label="Label and value grid",
	) == 0 { return }
	labels := [3]string{"Kind", "Rows", "Identity"}
	values := [3]string{"Virtual list", "500 · fixed 28 px", "Stable data keys"}
	for row in 0..<3 {
		label := ui.text(ctx, labels[row], key=ui.key_u64(u64(row*2+1)), size=12,
			color=alicorn.style_color(ctx, .Muted_Text))
		_ = alicorn.grid_cell(ctx, label, row, 0)
		value := ui.text(ctx, values[row], key=ui.key_u64(u64(row*2+2)), size=12)
		_ = alicorn.grid_cell(ctx, value, row, 1)
	}
	alicorn.grid_end(ctx)
}

gallery_positioned_ruler :: proc(ctx: ^ui.UI) {
	if ui.column(ctx, key="gallery-ruler", width=360, height=62, clip=true, label="Positioned label ruler") {
		_ = ui.box(ctx, key="gallery-ruler-line", width=352, height=1,
			fill=alicorn.style_color(ctx, .Border))
		for second in 0..=6 {
			x := f32(second)/6*352
			_ = ui.positioned_text(
				ctx,
				fmt.tprintf("%ds", second),
				x,
				8,
				key=ui.key_u64(u64(second+1)),
				size=11,
				decorative=true,
				color=alicorn.style_color(ctx, .Muted_Text),
				horizontal=.Center if second > 0 && second < 6 else (.Start if second == 0 else .End),
			)
		}
		_ = ui.positioned_text(
			ctx,
			"surface-local labels share the geometry transform",
			0,
			32,
			key="gallery-ruler-caption",
			size=10,
			decorative=true,
			color=alicorn.style_color(ctx, .Muted_Text),
		)
	}
}

gallery_surface_demos :: proc(app: ^App, ctx: ^ui.UI) {
	scope := alicorn.Style_Environment_Scope{}
	if app.surface_theme != 0 {
		scope = alicorn.style_environment_push(ctx, alicorn.Style_Environment{theme=app.surface_theme})
	}
	start_role := alicorn.style_extension_color_role_id("app.gallery.surface", "gradient.start")
	end_role := alicorn.style_extension_color_role_id("app.gallery.surface", "gradient.end")
	arc_role := alicorn.style_extension_color_role_id("app.gallery.surface", "arc")
	ring_role := alicorn.style_extension_color_role_id("app.gallery.surface", "ring")

	if ui.row(ctx, gap=10, align=.Center) {
		gradient := alicorn.surface_begin(
			ctx,
			alicorn.surface_extension_color_role(start_role),
			key="gallery-gradient",
			style=ui.layout_style(.Row, width=236, height=42, padding=10, align=.Center),
			shape=alicorn.surface_shape_rounded_corners({top_left=8, top_right=8, bottom_right=8, bottom_left=8}),
			gradient=alicorn.surface_gradient_to(alicorn.surface_extension_color_role(end_role), .Horizontal),
			label="Two-stop gradient",
		)
		if gradient != 0 {
			ui.text(ctx, "Two-stop gradient", size=11, color=alicorn.Color{0.95, 0.98, 1, 1})
			alicorn.surface_end(ctx)
		}
		_ = alicorn.surface_begin(
			ctx,
			alicorn.surface_extension_color_role(ring_role),
			key="gallery-circle",
			style=ui.layout_style(width=42, height=42),
			shape=alicorn.surface_shape_circle(),
			label="Circle surface",
		)
		alicorn.surface_end(ctx)
		_ = alicorn.surface_begin(
			ctx,
			alicorn.surface_extension_color_role(arc_role),
			key="gallery-arc",
			style=ui.layout_style(width=74, height=52),
			shape=alicorn.surface_shape_arc(2.36, 4.71, radius=0.42),
			fill=alicorn.Color{0, 0, 0, 0},
			stroke=alicorn.Paint_Stroke{color=alicorn.Color{0.96, 0.60, 0.24, 1}, width=6},
			label="Arc surface",
		)
		alicorn.surface_end(ctx)
	}
	ui.text(
		ctx,
		"Gradient stops, circle, and arc are semantic surfaces. An app-scoped theme supplies their extension roles.",
		size=11,
		color=alicorn.style_color(ctx, .Muted_Text),
	)
	if scope.active { alicorn.style_environment_pop(ctx, scope) }
}

gallery_geometry_demo :: proc(app: ^App, ctx: ^ui.UI) {
	surface_id := alicorn.gpu_geometry_surface(
		ctx,
		"gallery-retained-geometry",
		ui.layout_style(width=-1, height=92),
		1,
	)
	if surface_id != app.geometry_surface {
		app.geometry_surface = surface_id
		app.geometry_ready = false
		app.geometry_width = 0
		app.geometry_height = 0
	}
	if surface_id != 0 {
		if surface, ok := alicorn.gpu_surface_context(ctx.runtime, surface_id); ok {
			if surface.logical_bounds.w != app.geometry_width || surface.logical_bounds.h != app.geometry_height {
				app.geometry_ready = false
			}
		}
	}
	ui.text(
		ctx,
		"Retained geometry updates after layout; the ordinary description stays idle.",
		size=11,
		color=alicorn.style_color(ctx, .Muted_Text),
	)
}

gallery_layout :: proc(app: ^App, ctx: ^ui.UI) {
	gallery_section_intro(
		ctx,
		"Layout & surfaces",
		"Split panes, Grid tracks, surface-local positioned labels, gradient and shape primitives, and retained geometry.",
	)

	if gallery_section_columns(ctx) {
		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("layout-split"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Split panes") {
				gallery_card_title(ctx, "Split panes · draggable divider")
				gallery_split_demo(ctx)
				ui.text(ctx, "split_state(rt, id) reads the preferred position without owning application state.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("layout-grid"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Shared-track Grid") {
				gallery_card_title(ctx, "Shared-track Grid")
				gallery_grid_demo(ctx)
				ui.text(ctx, "Every Grid child names an explicit cell; fixed columns align independent rows.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("layout-positioned"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Positioned text") {
				gallery_card_title(ctx, "Positioned text · surface-local coordinates")
				gallery_positioned_ruler(ctx)
				ui.text(ctx, "Labels do not size the owner and stay decorative unless decorative=false is passed.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}
		}

		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("layout-surfaces"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Theme-resolved surfaces") {
				gallery_card_title(ctx, "Theme-resolved surfaces")
				gallery_surface_demos(app, ctx)
			}

			if ui.panel(ctx, key=alicorn.key_string("layout-geometry"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Retained geometry") {
				gallery_card_title(ctx, "Retained geometry surface")
				gallery_geometry_demo(app, ctx)
			}

			if ui.panel(ctx, key=alicorn.key_string("layout-limits"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Layout notes") {
				gallery_card_title(ctx, "Layout notes")
				ui.text(ctx, "• Rows and columns fit content on the cross axis and own one main-axis allocation.", size=12)
				ui.text(ctx, "• Percentage width is opt-in through ui.layout_sized or panel(sizing=...).", size=12)
				ui.text(ctx, "• Grid supports fixed, auto, fraction, and min/max tracks.", size=12)
				ui.text(ctx, "• Split panes nest; the preferred extent survives ordinary resizes.", size=12)
				ui.text(ctx, "• Surfaces are clipping-scoped and do not create a second widget tree.", size=12)
			}
		}
	}
}
