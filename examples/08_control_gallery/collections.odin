package main

// Collections: a virtualized list with fixed-height rows, closable document
// tabs with dirty state, a drag-reorder list, and a non-virtualized scroll
// region. All selection, ordering, and tab lifecycle state is application-owned.

import "core:fmt"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

gallery_doc_open_position :: proc(app: ^App, doc_index: int) -> int {
	position := 0
	for doc, index in app.docs {
		if !doc.open { continue }
		if index == doc_index { return position }
		position += 1
	}
	return -1
}

gallery_doc_at_open_position :: proc(app: ^App, position: int) -> int {
	current := 0
	for doc, index in app.docs {
		if !doc.open { continue }
		if current == position { return index }
		current += 1
	}
	return -1
}

gallery_toggle_active_doc_dirty :: proc(app: ^App) {
	if app.active_doc < 0 || app.active_doc >= len(app.docs) { return }
	app.docs[app.active_doc].dirty = !app.docs[app.active_doc].dirty
}

gallery_close_doc :: proc(app: ^App, doc_index: int) {
	if doc_index < 0 || doc_index >= len(app.docs) { return }
	app.docs[doc_index].open = false
	if app.active_doc != doc_index { return }
	app.active_doc = -1
	for doc, index in app.docs {
		if doc.open { app.active_doc = index; break }
	}
}

gallery_reopen_docs :: proc(app: ^App) {
	for index in 0..<len(app.docs) { app.docs[index].open = true }
	if app.active_doc < 0 { app.active_doc = 0 }
}

gallery_document_tabs :: proc(app: ^App, ctx: ^ui.UI) {
	items: [3]alicorn.Tab_Bar_Item
	count := 0
	for doc, index in app.docs {
		if !doc.open { continue }
		items[count] = alicorn.Tab_Bar_Item{
			key=ui.key_u64(u64(index+1)),
			label=doc.title,
			selected=index == app.active_doc,
			closable=true,
			dirty=doc.dirty,
			tooltip="Close with the tab's close button",
		}
		count += 1
	}
	if count == 0 {
		ui.text(ctx, "All documents are closed.", size=12, color=alicorn.style_color(ctx, .Muted_Text))
	} else if ui.column(ctx, key="gallery-document-preview") {
		paper := alicorn.style_color(ctx, .Editor_Background)
		result := alicorn.tab_bar(
			ctx,
			"gallery-document-tabs",
			items[:count],
			options=alicorn.Tab_Bar_Options{
				min_tab_width=128, max_tab_width=174, height=34, gap=2, presentation=.Compact,
				appearance=.Connected, close_policy=.Selected_Or_Hover,
				selected_fill=paper,
				selected_text=alicorn.style_color(ctx, .Text), selected_fill_set=true,
			},
			style=ui.layout_style(.Row, height=34, clip=true),
		)
		if result.action == .Select {
			doc_index := gallery_doc_at_open_position(app, result.item_index)
			if doc_index >= 0 { app.active_doc = doc_index }
		} else if result.action == .Close {
			doc_index := gallery_doc_at_open_position(app, result.item_index)
			gallery_close_doc(app, doc_index)
		}
		if app.active_doc >= 0 {
			snippets := [3]string{
				`ui.run(&app, render, title="Control Gallery")`,
				`"extends": "alicorn.base"`,
				`# Alicorn Control Gallery`,
			}
			if ui.panel(ctx, padding=12, fill=paper,
				corner_radii={top_right=8, bottom_right=8, bottom_left=8}, label="Selected document preview") {
				ui.text(ctx, snippets[app.active_doc], font=.Monospace, size=12)
			}
		}
	}
	if ui.row(ctx, gap=6, align=.Center) {
		if ui.button(ctx, "Toggle dirty", key="doc-toggle-dirty", height=26, width=106, variant=.Quiet) {
			gallery_toggle_active_doc_dirty(app)
		}
		if ui.button(ctx, "Reopen all", key="doc-reopen", height=26, width=96, variant=.Quiet) {
			gallery_reopen_docs(app)
		}
		if app.active_doc >= 0 {
			ui.text(
				ctx,
				fmt.tprintf("Active: %s%s", app.docs[app.active_doc].title,
					" · modified" if app.docs[app.active_doc].dirty else ""),
				size=11,
				color=alicorn.style_color(ctx, .Muted_Text),
			)
		}
	}
}

gallery_reorder_list :: proc(app: ^App, ctx: ^ui.UI) {
	for item, index in app.order {
		item_id := alicorn.Semantic_ID{namespace=GALLERY_DRAG_NAMESPACE, value=item.id}
		owner, activated := alicorn.button_begin(
			ctx,
			item.label,
			key=ui.key_u64(item.id),
			style=ui.layout_style(.Row, width=-1, height=30),
			state=alicorn.Button_State{selected=index == app.selected_order},
			content_style=alicorn.button_content_style(.Start, .Center, padding_x=10),
			variant=.Toolbar,
		)
		if owner == 0 { continue }
		_ = alicorn.semantic_bind(ctx, item_id)
		_ = alicorn.drag_source(ctx, GALLERY_DRAG_TYPE, item_id, .Label)
		_ = alicorn.drop_target(ctx, GALLERY_DRAG_TYPE, item_id, .Between_Vertical)
		if activated { app.selected_order = index }
		alicorn.button_end(ctx)
	}
}

gallery_virtual_records :: proc(app: ^App, ctx: ^ui.UI) {
	if list, ok := ui.virtual_list(
		ctx,
		GALLERY_RECORD_COUNT,
		GALLERY_ROW_HEIGHT,
		key="gallery-records",
		width=-1,
		height=260,
		grow=0,
		label="500 stable records",
		focusable=true,
	); ok {
		for position in list.first..<list.last {
			if ui.button(
				ctx,
				gallery_record_label(app, position),
				key=ui.key_u64(u64(position+1)),
				style=ui.layout_style(.Row, width=-1, height=GALLERY_ROW_HEIGHT),
				state=alicorn.Button_State{selected=position == app.selected_record},
				content_style=alicorn.button_content_style(.Start, .Center, padding_x=10),
				variant=.Default,
			) {
				app.selected_record = position
			}
		}
	}
}

gallery_scroll_lines :: proc(ctx: ^ui.UI) {
	region := alicorn.scroll_region_begin(
		ctx,
		key="gallery-scroll-region",
		viewport_height=118,
		content_height=22*22,
		line_height=22,
		style=ui.layout_style(.Column, height=118, clip=true),
		label="Non-virtualized scroll region",
		axes=.Vertical,
	)
	if region.id == 0 { return }
	if ui.column(ctx, gap=0, label="gallery-scroll-content") {
		for line in 0..<22 {
			ui.text(
				ctx,
				fmt.tprintf("Scrollable line %02d · retained offset survives rebuilds", line+1),
				key=ui.key_u64(u64(900+line)),
				size=11,
				style=ui.layout_style(height=22),
				decorative=true,
				color=alicorn.style_color(ctx, .Muted_Text),
			)
		}
	}
	alicorn.scroll_region_end(ctx)
}

gallery_collections :: proc(app: ^App, ctx: ^ui.UI) {
	gallery_section_intro(
		ctx,
		"Collections",
		"Virtualization with stable row identity, closable and dirty document tabs, local drag reordering, and a plain scroll region.",
	)

	if gallery_section_columns(ctx) {
		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("collections-records"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Virtual list") {
				gallery_card_title(ctx, fmt.tprintf("Virtual list · %d fixed-height rows", GALLERY_RECORD_COUNT))
				gallery_virtual_records(app, ctx)
				ui.text(
					ctx,
					fmt.tprintf("Selected %03d · only [first,last) rows are described",
						app.selected_record+1),
					size=12,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}

			if ui.panel(ctx, key=alicorn.key_string("collections-scroll"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Scroll region") {
				gallery_card_title(ctx, "Scroll region · 22 logical lines")
				gallery_scroll_lines(ctx)
				ui.text(ctx, "Wheel, scrollbar, Page Up/Down, Home, and End are retained by the region.",
					size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}
		}

		if ui.column(ctx, grow=1, gap=12) {
			if ui.panel(ctx, key=alicorn.key_string("collections-documents"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Document tabs") {
				gallery_card_title(ctx, "Document tabs · close and dirty state")
				gallery_document_tabs(app, ctx)
				ui.text(
					ctx,
					"Each item carries a stable key, selected state, close policy, dirty dot, and optional tooltip.",
					size=11,
					color=alicorn.style_color(ctx, .Muted_Text),
				)
			}

			if ui.panel(ctx, key=alicorn.key_string("collections-drag"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Drag to reorder") {
				gallery_card_title(ctx, "Drag to reorder")
				gallery_reorder_list(app, ctx)
				status := gallery_drag_status_text(app)
				if len(status) == 0 {
					status = "Press a row and move at least 5 logical pixels to start a drag."
				}
				ui.text(ctx, status, size=11, color=alicorn.style_color(ctx, .Muted_Text))
			}

			if ui.panel(ctx, key=alicorn.key_string("collections-notes"), padding=12, gap=8, stroke=ui.border(1, alicorn.style_color(ctx, .Border)), radius=8, label="Identity contract") {
				gallery_card_title(ctx, "Identity contract")
				ui.text(ctx, "• Virtual list rows must keep the declared fixed height.", size=12)
				ui.text(ctx, "• Keys follow data, not positions; reordering keeps focus on the item.", size=12)
				ui.text(ctx, "• Drag sources and targets are stable Semantic_IDs interpreted by the app.", size=12)
				ui.text(ctx, "• Tab keys survive closing and reopening because the app owns document order.", size=12)
			}
		}
	}
}
