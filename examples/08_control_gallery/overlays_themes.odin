package main

// Overlays, commands, motion, and themes. The modal, context menu, and tooltip
// are described after the ordinary root; motion is paint-only; theme selection
// is a scoped Style_Environment with one optional live-reloaded custom theme.

import "core:fmt"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

gallery_color_role_row :: proc(ctx: ^ui.UI, captions: []Color_Role_Caption) {
	row_key := (u64(int(captions[0].role))+8000) if len(captions) > 0 else u64(8000)
	if ui.row(ctx, key=ui.key_u64(row_key), gap=8, align=.Center) {
		for caption in captions {
			if ui.column(ctx, key=ui.key_u64(u64(int(caption.role))+4000), width=76, gap=3,
				label=caption.label) {
				_ = ui.box(ctx, key=ui.key_u64(u64(int(caption.role))+5000), width=76, height=18,
					fill=alicorn.style_color(ctx, caption.role), radius=3,
					stroke=ui.border(1, alicorn.style_color(ctx, .Border)))
				ui.text(ctx, caption.label, key=ui.key_u64(u64(int(caption.role))+6000), size=9,
					decorative=true, color=alicorn.style_color(ctx, .Muted_Text))
			}
		}
	}
}

gallery_motion_demo :: proc(app: ^App, ctx: ^ui.UI) {
	labels := [3]string{"Library", "Editor", "Settings"}
	if ui.row(ctx, gap=8, align=.Center) {
		for label, index in labels {
			if ui.button(
				ctx,
				label,
				key=ui.key_u64(u64(index+1)),
				width=112,
				height=32,
				state=alicorn.Button_State{selected=app.motion_choice == index},
			) {
				app.motion_choice = index
			}
		}
	}
	if ui.row(ctx, height=4, gap=0, label="gallery-motion-track") {
		indicator := alicorn.container_begin(
			ctx,
			.Container,
			label="decorative motion indicator",
			key="gallery-motion-indicator",
			style=ui.layout_style(.Row, width=112, height=4),
			color=alicorn.style_color(ctx, .Accent),
		)
		if indicator != 0 {
			target_x := f64(app.motion_choice)*f64(112+8)
			status := ui.motion(
				ctx,
				indicator,
				ui.Motion_Target{translation=ui.Motion_Vector2{target_x, 0}, has_translation=true},
			)
			if status != .Ok {
				ui.text(ctx, fmt.tprintf("Motion target rejected: %v", status), size=11)
			}
			alicorn.container_end(ctx)
		}
	}
}

gallery_theme_picker :: proc(app: ^App, ctx: ^ui.UI) {
	if ui.row(ctx, gap=8, align=.Center) {
		if ui.button(ctx, "Ember", key="theme-ember", width=72, height=30,
			state=alicorn.Button_State{selected=app.theme_choice == .Ember}) {
			gallery_choose_theme(app, ctx, .Ember)
		}
		if ui.button(ctx, "Default", key="theme-default", width=74, height=30,
			state=alicorn.Button_State{selected=app.theme_choice == .Default}) {
			gallery_choose_theme(app, ctx, .Default)
		}
		if ui.button(ctx, "Paper", key="theme-light", width=72, height=30,
			state=alicorn.Button_State{
				selected=app.theme_choice == .Light,
				disabled=app.light_theme == 0,
			}) {
			gallery_choose_theme(app, ctx, .Light)
		}
		if ui.button(ctx, "Custom JSON", key="theme-custom", width=108, height=30,
			state=alicorn.Button_State{
				selected=app.theme_choice == .Custom,
				disabled=app.registered_theme == 0,
			}) {
			gallery_choose_theme(app, ctx, .Custom)
		}
	}
	if ui.button(ctx, "Reload theme.json", key="theme-reload", width=150, height=30,
		state=alicorn.Button_State{disabled=app.compiling}, variant=.Primary) {
		app.theme_choice_explicit = false
		gallery_start_compile(app)
	}
	status := gallery_theme_status_text(app)
	if len(status) == 0 { status = "Custom theme is loading." }
	ui.text(ctx, status, size=11, color=alicorn.style_color(ctx, .Muted_Text))
}

gallery_accent_demo :: proc(ctx: ^ui.UI) {
	if ui.row(ctx, gap=12, align=.Center) {
		scope := alicorn.style_environment_push(ctx, alicorn.Style_Environment{
			accent=alicorn.style_accent(ui.rgb(0xE07A3F)),
		})
		_ = ui.button(ctx, "Scoped accent", key="accent-demo-button", width=140, height=30, variant=.Primary)
		_ = ui.box(ctx, key="accent-demo-swatch", width=30, height=18,
			fill=alicorn.style_color(ctx, .Accent), radius=4)
		ui.text(ctx, "A subtree-local accent override; no theme registration is needed.",
			size=11, color=alicorn.style_color(ctx, .Muted_Text))
		if scope.active { alicorn.style_environment_pop(ctx, scope) }
	}
}

gallery_overlays_section :: proc(app: ^App, ctx: ^ui.UI) {
	gallery_section_intro(
		ctx,
		"Overlays & commands",
		"Application-owned modal state, delayed tooltips, notices, a context menu, and native View/Help menu integration.",
	)

	if gallery_section_columns(ctx) {
		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("overlays-modal"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Modal surface") {
				gallery_card_title(ctx, "Modal surface")
				ui.text(ctx, "The overlay paints above the workspace and confines pointer, wheel, and tab focus until removed.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
				opener, clicked := alicorn.button_ex(
					ctx,
					"Open confirmation dialog",
					key="open-dialog",
					style=ui.layout_style(width=220, height=32),
					variant=.Primary,
				)
				if clicked {
					app.dialog_opener = opener
					app.dialog_open = true
					alicorn.context_menu_close(ctx.runtime)
				}
			}

			if ui.panel(ctx, key=alicorn.key_string("overlays-context"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Context menu") {
				gallery_card_title(ctx, "Context menu · single level")
				ui.text(ctx, "The button opens a menu anchored to the focused control; the runtime restores focus when it closes.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
				if alicorn.context_menu_is_open(ctx.runtime) {
					ui.text(ctx, "Context menu is open.", size=12, color=alicorn.style_color(ctx, .Accent))
				}
				if ui.button(ctx, "Open context menu", key="open-context-menu", width=190, height=30) {
					if !alicorn.context_menu_open_for_focused(ctx.runtime) {
						gallery_command_status_set(app, "Context menu could not anchor to a focused control.")
					}
				}
				command_status := gallery_command_status_text(app)
				if len(command_status) == 0 {
					command_status = "Choose a menu item; the app receives an Action_ID."
				}
				ui.text(ctx, command_status, size=11,
					color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("overlays-notice"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Notices") {
				gallery_card_title(ctx, "Notices · independent overlay")
				ui.text(ctx, "Persistent notices remain until the application dismisses them; errors announce assertively.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
				if ui.row(ctx, gap=8) {
					if ui.button(ctx, "Show status notice", key="post-notice", width=160, height=30) {
						app.pending_notice = true
					}
					if ui.button(ctx, "Dismiss notices", key="dismiss-notice", width=140, height=30, variant=.Quiet) {
						app.pending_notice_dismiss = true
					}
				}
			}
		}

		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("overlays-tooltip"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Tooltip") {
				gallery_card_title(ctx, "Delayed tooltip")
				_ = ui.button(ctx, "Hover for help", key="tooltip-target", width=160, height=30)
				_ = alicorn.tooltip(ctx, "Tooltips wait for a one-shot hover deadline and never take focus.", 350)
				ui.text(ctx, "The popup is pointer-transparent and dismisses on press, keyboard input, or focus loss.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("overlays-menu"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Native menu") {
				gallery_card_title(ctx, "Native View and Help menus")
				ui.text(ctx, "View · sections with Primary+1 … Primary+6 shortcuts", size=12)
				ui.text(ctx, "View · Reload theme.json with Primary+R", size=12)
				ui.text(ctx, "Help · About posts the persistent notice from the app", size=12)
				ui.text(ctx, "Menu labels and structure are snapshotted by the host; app-owned Action_State is read when the menu opens.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("overlays-limits"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Overlay boundaries") {
				gallery_card_title(ctx, "Overlay boundaries")
				ui.text(ctx, "• Modals require application-owned dismissal and focus restoration.", size=12)
				ui.text(ctx, "• Context menus are single-level: no submenu, checkmark, or embedded widgets.", size=12)
				ui.text(ctx, "• Notices retain at most four entries and deduplicate stable IDs.", size=12)
				ui.text(ctx, "• Select popups paint above notices and own pointer input where they overlap.", size=12)
				ui.text(ctx, "• Native dialogs, file drop, and clipboard remain host services outside this example.", size=12)
			}
		}
	}
}

gallery_motion_themes :: proc(app: ^App, ctx: ^ui.UI) {
	gallery_section_intro(
		ctx,
		"Motion & themes",
		"Try retained motion, switch palettes, and preview changes to the JSON theme.",
	)

	if gallery_section_columns(ctx) {
		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("themes-motion"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Retained motion") {
				gallery_card_title(ctx, "Retained motion · decorative indicator")
				gallery_motion_demo(app, ctx)
				ui.text(ctx, "Click a tab: only the decorative marker retargets. Layout, hit geometry, and semantics stay authoritative.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
				ui.text(ctx, "Reduced-motion policy is a theme input; the native host imports supported system preferences.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("themes-choice"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Theme variants") {
				gallery_card_title(ctx, "Theme variants · scoped Style_Environment")
				gallery_theme_picker(app, ctx)
				ui.text(ctx, "Ember and Paper are registered in code. A worker compiles the Custom JSON palette.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
				ui.text(ctx, "Theme changes invalidate paint only when colors change; metric changes request a new description.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("themes-accent"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Scoped accent") {
				gallery_card_title(ctx, "Scoped accent override")
				gallery_accent_demo(ctx)
			}
		}

		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("themes-palette"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Semantic color palette") {
				gallery_card_title(ctx, "Semantic color palette · active theme")
				gallery_color_role_row(ctx, GALLERY_COLOR_ROLES[0:6])
				gallery_color_role_row(ctx, GALLERY_COLOR_ROLES[6:12])
				gallery_color_role_row(ctx, GALLERY_COLOR_ROLES[12:18])
				ui.text(ctx, "Controls resolve roles through the active recipe; the inspector records the chosen token and source.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("themes-live"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Live JSON reload") {
				gallery_card_title(ctx, "Live JSON reload · experimental")
				ui.text(ctx, "Edit examples/08_control_gallery/theme.json, then choose Reload theme.json or press Primary+R.",
					size=12)
				ui.text(ctx, "Color values may change. Token names, role bindings, lengths, recipes, and materials must stay fixed.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
				ui.text(ctx, "Invalid JSON or an incompatible candidate leaves the last good palette active; status appears above.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("themes-limits"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Theme boundaries") {
				gallery_card_title(ctx, "Theme boundaries")
				ui.text(ctx, "• Theme IDs are immutable registrations; replace updates a non-default snapshot between frames.", size=12)
				ui.text(ctx, "• Extension roles are component-owned; core roles receive contrast and transparency adaptation.", size=12)
				ui.text(ctx, "• Theme structure is not live-editable in this release; only color values are.", size=12)
				ui.text(ctx, "• There is no automatic file watcher or cross-runtime theme synchronization here.", size=12)
			}
		}
	}
}

gallery_restore_dialog_focus :: proc(state: rawptr, rt: ^alicorn.Runtime) {
	app := cast(^App)state
	if app == nil || app.dialog_opener == 0 { return }
	if alicorn.focus(rt, app.dialog_opener) {
		app.dialog_focus_restore_attempts = 0
		return
	}
	// The description that consumed Escape still contains the modal subtree.
	// Retry once after the invalidated root has been described without it.
	if app.dialog_focus_restore_attempts == 0 {
		app.dialog_focus_restore_attempts = 1
		_ = alicorn.interaction_after_frame_register(rt, state, gallery_restore_dialog_focus)
	}
}

gallery_close_dialog :: proc(app: ^App, ctx: ^ui.UI, message: string) {
	app.dialog_open = false
	app.dialog_focus_restore_attempts = 0
	gallery_command_status_set(app, message)
	_ = ui.after_frame(ctx, rawptr(app), gallery_restore_dialog_focus)
	alicorn.invalidate_root(ctx.runtime, "gallery dialog dismissed")
}

gallery_delete_selected_record :: proc(app: ^App, ctx: ^ui.UI) {
	if app == nil || ctx == nil { return }
	if app.record_count <= 0 {
		gallery_close_dialog(app, ctx, "There are no records left to delete.")
		return
	}
	deleted_position := -1
	for record_id, position in app.record_ids[:app.record_count] {
		if record_id == app.selected_record {
			deleted_position = position
			break
		}
	}
	if deleted_position < 0 { deleted_position = app.record_count-1 }
	deleted_record := app.record_ids[deleted_position]
	for position in deleted_position..<app.record_count-1 {
		app.record_ids[position] = app.record_ids[position+1]
	}
	app.record_count -= 1
	if app.record_count > 0 {
		app.selected_record = app.record_ids[min(deleted_position, app.record_count-1)]
	} else {
		app.selected_record = 0
	}
	app.renamed_record = false
	gallery_close_dialog(app, ctx, fmt.tprintf("Deleted record %03d from the collection.", deleted_record+1))
}

gallery_context_menu_overlay :: proc(app: ^App, ctx: ^ui.UI) {
	if !alicorn.context_menu_is_open(ctx.runtime) { return }
	if !alicorn.context_menu_begin(ctx, "gallery-context-menu", width=232) { return }
	theme_id := gallery_active_theme(app)
	theme_scope := alicorn.Style_Environment_Scope{}
	if theme_id != 0 {
		theme_scope = alicorn.style_environment_push(ctx, alicorn.Style_Environment{theme=theme_id})
	}
	alicorn.context_menu_item(ctx, GALLERY_ACTION_RENAME, "Rename record")
	alicorn.context_menu_item(ctx, GALLERY_ACTION_DUPLICATE, "Duplicate record")
	alicorn.context_menu_separator(ctx)
	alicorn.context_menu_item(ctx, GALLERY_ACTION_DELETE, "Delete record", enabled=false)
	if theme_scope.active { alicorn.style_environment_pop(ctx, theme_scope) }
	action := alicorn.context_menu_end(ctx)
	if action != 0 {
		gallery_apply_command(app, action)
		alicorn.invalidate_root(ctx.runtime, "gallery context command adopted")
	}
}

gallery_dialog_overlay :: proc(app: ^App, ctx: ^ui.UI) {
	overlay := alicorn.modal_overlay_begin(
		ctx,
		"gallery-modal",
		style=ui.layout_style(.Column, align=.Center, justify=.Center),
		backdrop_color=alicorn.Color{0.01, 0.02, 0.04, 0.74},
	)
	if overlay == 0 { return }
	theme_id := gallery_active_theme(app)
	theme_scope := alicorn.Style_Environment_Scope{}
	if theme_id != 0 {
		theme_scope = alicorn.style_environment_push(ctx, alicorn.Style_Environment{theme=theme_id})
	}
	_ = alicorn.interaction_scope_register(ctx.runtime, overlay, rawptr(app), alicorn.Interaction_Scope_Options{
		keys={.Escape},
		modal=true,
	})
	for {
		event, found := alicorn.interaction_event_next(ctx.runtime, overlay)
		if !found { break }
		if event.kind == .Key && event.key == .Escape {
			gallery_close_dialog(app, ctx, "Cancelled the modal with Escape and restored focus.")
		}
	}
	if ui.panel(ctx, width=440, height=218, padding=22, gap=12,
		fill=alicorn.style_color(ctx, .Surface),
		stroke=ui.border(1, alicorn.style_color(ctx, .Border)),
		radius=10,
		label="Confirmation dialog",
	) {
		_ = alicorn.semantic_description(
			ctx,
			.Dialog,
			"Confirm record deletion",
			"A modal confirmation with destructive and cancel actions.",
		)
		gallery_card_title(ctx, "Confirm record deletion")
		ui.text(ctx, fmt.tprintf("Record %03d will be removed from the virtual list. This action cannot be undone for this session.", app.selected_record+1),
			size=12, color=alicorn.style_color(ctx, .Muted_Text))
		if ui.row(ctx, gap=8, align=.Center) {
			if ui.button(ctx, "Cancel", key="dialog-cancel", width=110, height=32, variant=.Quiet) {
				gallery_close_dialog(app, ctx, "Cancelled the modal and restored focus.")
			}
			if ui.button(ctx, "Delete", key="dialog-delete", width=110, height=32, variant=.Danger) {
				gallery_delete_selected_record(app, ctx)
			}
			ui.text(ctx, "Escape also dismisses.", size=11,
				color=alicorn.style_color(ctx, .Muted_Text))
		}
	}
	if theme_scope.active { alicorn.style_environment_pop(ctx, theme_scope) }
	alicorn.modal_overlay_end(ctx)
}

gallery_render_overlays :: proc(app: ^App, ctx: ^ui.UI) {
	if app == nil || ctx == nil { return }
	if app.dialog_open {
		gallery_dialog_overlay(app, ctx)
		return
	}
	gallery_context_menu_overlay(app, ctx)
}
