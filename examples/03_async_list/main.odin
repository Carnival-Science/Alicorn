package main

// 03 · Async List adds worker-published pages, retained scrolling, and
// fixed-row virtualization. The host wakes as pages arrive, then sleeps after
// the worker finishes.
// render_record uses one key scope for the whole component. Its children keep
// their call-site identities when records move or leave the visible window.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import ui "alicorn:ui"

ASYNC_LIST_ITEM_COUNT :: 10_000
ASYNC_LIST_ROW_HEIGHT :: 30
ASYNC_LIST_PAGE_SIZE  :: 500
ASYNC_LIST_PAGE_DELAY :: 250 * time.Millisecond
ASYNC_LIST_PAGE_COUNT :: (ASYNC_LIST_ITEM_COUNT + ASYNC_LIST_PAGE_SIZE - 1) / ASYNC_LIST_PAGE_SIZE

Item :: struct {
	id:    u64,
	score: int,
}

App :: struct {
	items:             []Item,
	worker:            ^thread.Thread,
	progress_mutex:    sync.Mutex,
	worker_loaded:     int,
	loaded_count:      int,
	worker_complete:   bool,
	stop_worker:       bool,
	loaded:            bool,
	load_failed:       bool,
	waker:             ui.Application_Waker,
	selected_id:       u64,
	build_calls:       u64,
	completed_builds:  u64,
	wake_calls:        u64,
	page_updates:      u64,
	smoke:             bool,
}

load_items :: proc(data: rawptr) {
	app := cast(^App)data
	page_delay := ASYNC_LIST_PAGE_DELAY
	if app.smoke {
		// Bounded smoke runs can exit on idle while the worker is paused between
		// pages. Keep this mode fast enough to finish before that idle deadline.
		page_delay = 20 * time.Millisecond
	}
	for first := 0; first < ASYNC_LIST_ITEM_COUNT; first += ASYNC_LIST_PAGE_SIZE {
		// Keep the loading state visible without polling from the UI thread.
		time.sleep(page_delay)
		sync.mutex_lock(&app.progress_mutex)
		if app.stop_worker {
			sync.mutex_unlock(&app.progress_mutex)
			return
		}
		last := min(first+ASYNC_LIST_PAGE_SIZE, ASYNC_LIST_ITEM_COUNT)
		for index in first..<last {
			app.items[index] = Item{id=u64(index+1), score=(index*37+11)%1000}
		}
		app.worker_loaded = last
		app.worker_complete = last == ASYNC_LIST_ITEM_COUNT
		finished := app.worker_complete
		sync.mutex_unlock(&app.progress_mutex)

		// The UI allocates and owns this fixed-size slice; the worker fills each
		// page before publishing its prefix under the mutex. The waker only asks
		// the host to deliver an event.
		ui.wake(app.waker)
		if finished { return }
	}
}

render_record :: proc(ctx: ^ui.UI, item: Item, selected: bool) -> bool {
	if ui.key_scope(ctx, item.id) {
		if ui.row(ctx, height=ASYNC_LIST_ROW_HEIGHT, gap=10, align=.Center) {
			ui.text(ctx, fmt.tprintf("Record %05d · score %03d", item.id, item.score),
				style=ui.layout_style(.Row, grow=1))
			return ui.button(ctx, "Select", width=84, height=26,
				state=ui.Button_State{selected=selected})
		}
	}
	return false
}

render :: proc(app: ^App, ctx: ^ui.UI) {
	app.build_calls += 1
	if app.loaded { app.completed_builds += 1 }
	if ui.column(ctx, grow=1, padding=20, gap=10, clip=true, label="async-list-content") {
		ui.text(ctx, "03 · Async virtual list", size=24)
		message := fmt.tprintf("Loading %d / %d records · %d-row pages", app.loaded_count, ASYNC_LIST_ITEM_COUNT, ASYNC_LIST_PAGE_SIZE)
		if app.loaded { message = fmt.tprintf("Loaded %d records · selected #%d · idle until input", app.loaded_count, app.selected_id) }
		if app.load_failed { message = "Worker could not be started. Close and rerun the example." }
		ui.text(ctx, message, style=ui.layout_style(height=24))
		if app.loaded_count > 0 {
			// Virtualization requires every emitted row to use this fixed height.
			if list, ok := ui.virtual_list(
				ctx,
				app.loaded_count,
				ASYNC_LIST_ROW_HEIGHT,
				key="records",
				label="loaded stable records",
			); ok {
				for position in list.first..<list.last {
					item := app.items[position]
					if render_record(ctx, item, item.id == app.selected_id) {
						app.selected_id = item.id
					}
				}
			}
		}
	}
}

start_app :: proc(app: ^App, waker: ui.Application_Waker) {
	app.waker = waker
	app.worker = thread.create_and_start_with_data(rawptr(app), load_items, name="alicorn-example-loader")
	app.load_failed = app.worker == nil
}

wake_app :: proc(app: ^App, ctx: ui.Application_Context) {
	app.wake_calls += 1
	sync.mutex_lock(&app.progress_mutex)
	loaded := app.worker_loaded
	complete := app.worker_complete
	sync.mutex_unlock(&app.progress_mutex)

	changed := loaded != app.loaded_count
	if changed {
		app.loaded_count = loaded
		app.page_updates += 1
	}
	if complete && !app.loaded {
		app.loaded = true
		changed = true
	}
	if changed {
		ui.invalidate(ctx, "async list page arrived")
	}
}

stop_app :: proc(app: ^App) {
	if app.worker != nil {
		// Stop and join before releasing data or returning the borrowed waker.
		sync.mutex_lock(&app.progress_mutex)
		app.stop_worker = true
		sync.mutex_unlock(&app.progress_mutex)
		thread.join(app.worker)
		thread.destroy(app.worker)
		app.worker = nil
	}
	if app.smoke {
		if !app.loaded || app.loaded_count != ASYNC_LIST_ITEM_COUNT {
			fmt.eprintln("async-list smoke stopped before the worker result was presented")
			os.exit(1)
		}
		// Wakes may coalesce, but every adopted page came from a worker wake.
		// After the final page, only a bounded retained-layout pass is allowed.
		if app.page_updates < 1 || app.page_updates > ASYNC_LIST_PAGE_COUNT ||
			app.wake_calls < app.page_updates || app.completed_builds < 1 || app.completed_builds > 2 {
			fmt.eprintln("async-list failed its bounded completion/idle check")
			os.exit(1)
		}
		fmt.println("async_list_smoke", "items", app.loaded_count, "pages", app.page_updates,
			"builds", app.build_calls, "completed_builds", app.completed_builds,
			"worker_wakes", app.wake_calls, "idle", true)
	}
}

main :: proc() {
	smoke := false
	for argument in os.args {
		if argument == "--smoke" { smoke = true }
	}
	app := App{items=make([]Item, ASYNC_LIST_ITEM_COUNT), smoke=smoke}
	// Result storage outlives the worker; run returns after on_stop joins it.
	defer delete(app.items)
	ui.run(&app, render, title="Alicorn · Async List", width=860, height=680,
		on_start=start_app,
		on_wake=wake_app,
		on_stop=stop_app,
		smoke=smoke,
	)
}
