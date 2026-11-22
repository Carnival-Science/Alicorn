package main

// Foundations: typography, the complete built-in icon set, Button variants and
// states, and the semantic defaults that make these controls usable from a
// keyboard and a screen reader.

import "core:fmt"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

gallery_section_intro :: proc(ctx: ^ui.UI, title, description: string) {
	ui.text(ctx, title, size=22, text_style=alicorn.Text_Style{
		font_weight=alicorn.FONT_WEIGHT_SEMIBOLD,
	})
	ui.text(ctx, description, size=13, color=alicorn.style_color(ctx, .Muted_Text))
}

gallery_card_title :: proc(ctx: ^ui.UI, title: string) {
	ui.text(ctx, title, size=14, text_style=alicorn.Text_Style{
		font_weight=alicorn.FONT_WEIGHT_SEMIBOLD,
	})
}

gallery_section_columns_end :: proc(ctx: ^ui.UI, opened: bool) {
	if opened { alicorn.container_end(ctx) }
}

@(deferred_in_out=gallery_section_columns_end)
gallery_section_columns :: proc(ctx: ^ui.UI) -> bool {
	two_columns := ctx.runtime.viewport.w >= GALLERY_TWO_COLUMN_WIDTH
	direction := alicorn.Layout_Direction.Row if two_columns else .Column
	align := alicorn.Align.Start if two_columns else .Stretch
	return alicorn.container_begin(ctx, .Container, key="gallery-demo-columns",
		style=ui.layout_style(direction, height=alicorn.LAYOUT_SIZE_FIT_CONTENT, gap=12, align=align)) != 0
}

gallery_icon_caption_row :: proc(ctx: ^ui.UI, captions: []Icon_Caption) {
	row_key := (u64(captions[0].id)+7000) if len(captions) > 0 else u64(7000)
	if ui.row(ctx, key=ui.key_u64(row_key), gap=6, align=.Center) {
		for caption in captions {
			if ui.column(ctx, key=ui.key_u64(u64(caption.id)+1000), width=56, gap=3, align=.Center,
				label=caption.label) {
				ui.icon(ctx, caption.id, key=ui.key_u64(u64(caption.id)+2000), size=22, color_role=.Text)
				ui.text(ctx, caption.label, key=ui.key_u64(u64(caption.id)+3000), size=9, decorative=true,
					color=alicorn.style_color(ctx, .Muted_Text))
			}
		}
	}
}

gallery_foundations :: proc(app: ^App, ctx: ^ui.UI) {
	gallery_section_intro(
		ctx,
		"Foundations",
		"Text roles, all 15 built-in icon masks, Button intent variants, ordinary control states, and accessible naming.",
	)

	if gallery_section_columns(ctx) {
		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("foundation-buttons"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Button variants") {
				gallery_card_title(ctx, "Button variants")
				if ui.row(ctx, gap=6, align=.Center) {
					_ = ui.button(ctx, "Default", key="variant-default", width=86, height=30, variant=.Default)
					_ = ui.button(ctx, "Primary", key="variant-primary", width=86, height=30, variant=.Primary)
					_ = ui.button(ctx, "Toolbar", key="variant-toolbar", width=86, height=30, variant=.Toolbar)
					_ = ui.button(ctx, "Quiet", key="variant-quiet", width=86, height=30, variant=.Quiet)
					_ = ui.button(ctx, "Tab", key="variant-tab", width=72, height=30, variant=.Tab)
					_ = ui.button(ctx, "Danger", key="variant-danger", width=86, height=30, variant=.Danger)
				}
				if ui.row(ctx, gap=8, align=.Center) {
					if ui.button(ctx, "Click me", key="variant-counter", width=100, height=30, variant=.Primary) {
						app.button_clicks += 1
					}
					_ = ui.button(ctx, "Selected", key="variant-selected", width=100, height=30,
						state=ui.Button_State{selected=true})
					_ = ui.button(ctx, "Disabled", key="variant-disabled", width=100, height=30,
						state=ui.Button_State{disabled=true})
					ui.text(ctx, fmt.tprintf("Activations: %d", app.button_clicks), size=12)
				}
				ui.text(
					ctx,
					"Recipes resolve selected, hovered, pressed, then disabled. Focus remains a separate outline.",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}

			if ui.panel(ctx, key=alicorn.key_string("foundation-icons"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Built-in icons") {
				gallery_card_title(ctx, "Built-in icons · 15 font-independent masks")
				gallery_icon_caption_row(ctx, GALLERY_ICONS[0:8])
				gallery_icon_caption_row(ctx, GALLERY_ICONS[8:15])
				if ui.row(ctx, gap=10, align=.Center) {
					if ui.icon_button(ctx, "More actions", .More_Horizontal, key="icon-more",
						style=ui.layout_style(width=32, height=32)) {
						app.icon_clicks += 1
					}
					if ui.icon_button(ctx, "Search", .Search, key="icon-search", selected=app.search_selected,
						style=ui.layout_style(width=32, height=32), variant=.Toolbar) {
						app.search_selected = !app.search_selected
						app.icon_clicks += 1
					}
					ui.text(ctx, fmt.tprintf("Icon activations: %d", app.icon_clicks), size=12)
				}
				ui.text(
					ctx,
					"Icon buttons have accessible names. Toggle Search to see the selected state.",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}
		}

		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("foundation-type"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Typography") {
				gallery_card_title(ctx, "Typography")
				ui.text(ctx, "Semibold heading", size=18,
					text_style=alicorn.Text_Style{font_weight=alicorn.FONT_WEIGHT_SEMIBOLD})
				ui.text(ctx, "Regular body copy at the default size.")
				ui.text(ctx, "Monospace role for code, identifiers, and numeric columns.", size=13, font=.Monospace)
				ui.text(ctx, "Ellipsized labels keep one line.", size=13,
					text_style=alicorn.Text_Style{overflow=.Ellipsis})
				ui.text(
					ctx,
					"Load app fonts once from on_initialize with font_load_bytes(rt, .UI, bytes); .Monospace is a separate role.",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}

			if ui.panel(ctx, key=alicorn.key_string("foundation-semantics"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Accessibility defaults") {
				gallery_card_title(ctx, "Accessibility defaults")
				ui.text(ctx, "ui.text publishes independent informational copy as Static_Text; pass decorative=true for ornament.")
				ui.text(ctx, "Buttons, checkboxes, sliders, text fields, selects, and tabs publish roles, names, values, and actions automatically.")
				if ui.row(ctx, gap=8, align=.Center) {
					ui.text(ctx, fmt.tprintf("Button activations: %d", app.button_clicks), size=12,
						style=ui.layout_style(.Row, grow=1, height=22))
					_ = alicorn.semantic_description(
						ctx,
						.Status,
						"Foundation activation count",
						"Live count of the Click me button in this section",
						value=fmt.tprintf("%d", app.button_clicks),
					)
				}
				ui.text(
					ctx,
					"Order is visual: this row's status is published after the text it describes. Group headings below use semantic_description(.Group).",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}

			if ui.panel(ctx, key=alicorn.key_string("foundation-limits"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Copyable surface notes") {
				gallery_card_title(ctx, "What this section demonstrates")
				ui.text(ctx, "• ui.text, ui.text_style, and the .Monospace font role", size=12)
				ui.text(ctx, "• ui.button with six variants plus selected and disabled state", size=12)
				ui.text(ctx, "• ui.icon and ui.icon_button over all 15 built-in masks", size=12)
				ui.text(ctx, "• Automatic accessibility semantics and a .Status role", size=12)
				ui.text(
					ctx,
					"Copy the calls in foundations.odin; each one is ordinary application code.",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}
		}
	}
}
