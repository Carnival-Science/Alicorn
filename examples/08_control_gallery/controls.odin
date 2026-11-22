package main

// Controls: the ordinary form vocabulary. Each control adopts user input into
// application-owned state; validation, formatting, and error presentation remain
// application decisions.

import "core:fmt"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

gallery_controls :: proc(app: ^App, ctx: ^ui.UI) {
	gallery_section_intro(
		ctx,
		"Controls",
		"A controlled text field with application validation, pointer-bound checkbox and slider, and a select popup with a disabled option.",
	)

	if gallery_section_columns(ctx) {
		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("controls-profile"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Profile form") {
				gallery_card_title(ctx, "Profile form")
				ui.text(
					ctx,
					"ui.text_field emits a visible label and binds the same label to the field's accessible name.",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
				_ = ui.text_field(ctx, "Display name", &app.name, key="gallery-name", width=-1, height=34)
				if app.name_invalid {
					_ = alicorn.semantic_augment(
						ctx,
						description="Display name is required before the sample can be saved.",
						states_add=alicorn.semantic_states_add({}, .Invalid),
					)
				}
				if ui.row(ctx, gap=8, align=.Center) {
					if ui.button(ctx, "Validate", key="controls-validate", width=100, height=30, variant=.Primary) {
						app.name_invalid = len(app.name.text) == 0
					}
					if ui.button(ctx, "Reset", key="controls-reset", width=88, height=30, variant=.Quiet) {
						_ = ui.text_buffer_set(&app.name, "Alicorn")
						app.name_invalid = false
					}
					if app.name_invalid {
						ui.text(ctx, "Name is required", size=12, color=alicorn.style_color(ctx, .Danger))
					} else {
						ui.text(ctx, fmt.tprintf("Stored: %s", app.name.text), size=12,
							color=alicorn.style_color(ctx, .Muted_Text))
					}
				}
				ui.checkbox(ctx, "Email me about updates", &app.notifications)
				_ = ui.checkbox(ctx, "Disabled option", &app.notifications, key="controls-disabled-check",
					disabled=true)
			}

			if ui.panel(ctx, key=alicorn.key_string("controls-status"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Application-owned values") {
				gallery_card_title(ctx, "Application-owned values")
				ui.text(ctx, fmt.tprintf("Name: %s", app.name.text), size=12)
				ui.text(ctx, fmt.tprintf("Notifications: %s", "on" if app.notifications else "off"), size=12)
				ui.text(ctx, fmt.tprintf("Gain: %.0f%% · Density key: %d", app.gain*100, app.density_key), size=12)
				ui.text(
					ctx,
					"Nothing here is stored by Alicorn. Controls report changes; the app struct is the source of truth.",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}
		}

		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("controls-values"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Ranged and discrete values") {
				gallery_card_title(ctx, "Ranged and discrete values")
				_ = ui.slider_f32(ctx, "Gain", &app.gain, 0, 1, step=0.05, key="controls-gain",
					width=-1, height=40)
				// Add a human-readable value immediately after the slider while
				// preserving its numeric range and step for assistive technology.
				_ = alicorn.semantic_range_value_text(ctx, fmt.tprintf("%.0f percent", app.gain*100))
				ui.text(ctx, fmt.tprintf("Gain value: %.0f%%", app.gain*100), size=12,
					color=alicorn.style_color(ctx, .Muted_Text))

				ui.text(ctx, "Density", size=12)
				options := [4]alicorn.Select_Option{
					{key=1, label="Compact"},
					{key=2, label="Comfortable"},
					{key=3, label="Spacious"},
					{key=4, label="Custom theme only", disabled=true},
				}
				choice := alicorn.select_control(
					ctx,
					"controls-density",
					"Density",
					options[:],
					app.density_key,
					style=ui.layout_style(width=-1, height=36),
				)
				if choice.changed { app.density_key = choice.selected_key }
				ui.text(
					ctx,
					"Select owns its anchored listbox, type-ahead, keyboard navigation, dismissal, and focus restoration.",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}

			if ui.panel(ctx, key=alicorn.key_string("controls-keyboard"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Keyboard and focus") {
				gallery_card_title(ctx, "Keyboard and focus")
				ui.text(ctx, "• Tab / Shift+Tab traverse focusable controls", size=12)
				ui.text(ctx, "• Space toggles a checkbox and activates a button", size=12)
				ui.text(ctx, "• Arrow keys move a focused slider; Home/End jump to bounds", size=12)
				ui.text(ctx, "• The select popup handles Up/Down, Home/End, type-ahead, Enter, Escape, and Tab", size=12)
				ui.text(ctx, "• Text fields use the native text-input, IME, and selection path", size=12)
				ui.text(
					ctx,
					"Focus paint is separate from semantic focus. The inspector (F9) shows both retained state and causes.",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}

			if ui.panel(ctx, key=alicorn.key_string("controls-limits"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Behavior limits") {
				gallery_card_title(ctx, "Behavior limits")
				ui.text(ctx, "• ui.checkbox and ui.slider_f32 adopt changes directly; use runtime value-returning controls when a proposed value must be transformed first.", size=12)
				ui.text(ctx, "• Validation is app-owned. This sample adds the Invalid semantic state only after Validate is pressed.", size=12)
				ui.text(ctx, "• The disabled option is skipped by pointer and keyboard selection.", size=12)
				ui.text(ctx, "• There is no mask, password, or multi-line field in this release.", size=12)
			}
		}
	}
}
