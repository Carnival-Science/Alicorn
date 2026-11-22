// Issue #193 invalidation-frontier evidence fixture.
//
// Reproduces the three adversarial authoring mistakes named by the issue on a
// small keyed-region scene, then replays the same mutations with correct
// invalidation. The frontier reports are printed from the public query; the
// scene hash is a fresh-runtime comparison over the public paint display list
// and retained text content. Domain text in this fixture is synthetic and
// safe to publish; the reports themselves never copy ring reason strings.
//
// Build and run (debug; frontier capture is a debug default):
//
//   odin build benchmarks\diagnostics\issue193_invalidation_frontier.odin -file `
//       -collection:alicorn=. -out:out\issue193_frontier.exe
//   out\issue193_frontier.exe > docs\validation\raw\issue193-adversarial.txt
package main

import "core:fmt"
import "core:os"
import "core:strings"
import alicorn "alicorn:runtime"

FRONTIER_FIXTURE_FONT :: #load("../../assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")

Frontier_Row :: struct {
	key: string,
	revision: u64,
	value: string,
}

Frontier_App :: struct {
	parent_revision: u64,
	peer_revision: u64,
	peer: string,
	rows: [3]Frontier_Row,
}

frontier_app :: proc() -> Frontier_App {
	return Frontier_App{
		parent_revision=1,
		peer_revision=1,
		peer="Peer output",
		rows={
			{"fixture-alpha", 1, "Alpha value"},
			{"fixture-bravo", 1, "Bravo value"},
			{"fixture-charlie", 1, "Charlie value"},
		},
	}
}

frontier_describe :: proc(ui: ^alicorn.UI, app: ^Frontier_App, ids: ^[3]alicorn.Node_ID = nil) {
	alicorn.container_begin(ui, .Root, key=alicorn.key_string("fixture-root"),
		style=alicorn.layout_style(.Column, gap=4))
	parent, parent_reused := alicorn.region_begin(ui, "fixture-parent", app.parent_revision,
		style=alicorn.layout_style(.Column, width=260, height=220, gap=4))
	if parent != 0 && !parent_reused {
		for index in 0..<len(app.rows) {
			row := app.rows[index]
			id, cached := alicorn.region_begin(ui, row.key, row.revision,
				style=alicorn.layout_style(.Column, width=240, height=64))
			if ids != nil { ids[index] = id }
			if id == 0 || cached { continue }
			alicorn.text(ui, row.value, key=alicorn.key_pair(u64(index), 1),
				style=alicorn.layout_style(.Row, height=24))
			alicorn.region_end(ui, id, false, 0)
		}
		alicorn.region_end(ui, parent, false, 0)
	}
	peer, peer_reused := alicorn.region_begin(ui, "fixture-peer", app.peer_revision,
		style=alicorn.layout_style(.Column, width=240, height=48))
	if peer != 0 && !peer_reused {
		alicorn.text(ui, app.peer, key=alicorn.key_string("fixture-peer-text"),
			style=alicorn.layout_style(.Row, height=24))
		alicorn.region_end(ui, peer, false, 0)
	}
	alicorn.container_end(ui)
}

frontier_settle :: proc(rt: ^alicorn.Runtime, app: ^Frontier_App, ids: ^[3]alicorn.Node_ID = nil) -> int {
	for pass in 0..<4 {
		ui, build := alicorn.begin_frame(rt)
		if !build { return pass }
		frontier_describe(&ui, app, ids)
		alicorn.end_frame(&ui)
	}
	fmt.println("HARD: description did not settle")
	return 4
}

frontier_hash_text :: proc(hash: u64, value: string) -> u64 {
	result := hash
	for index in 0..<len(value) {
		result = (result ~ u64(value[index]))*1099511628211
	}
	return result
}

frontier_hash_f32 :: proc(hash: u64, value: f32) -> u64 {
	bits := transmute(u32)value
	return (hash ~ u64(bits))*1099511628211
}

// frontier_scene_hash covers the visible paint products, including text-run
// content. Text-run handles and node identity are deliberately excluded so a
// fresh runtime with identical output hashes equally.
frontier_scene_hash :: proc(rt: ^alicorn.Runtime) -> u64 {
	hash := u64(14695981039346656037)
	view, ok := alicorn.paint_display_list(rt)
	if !ok { return 0 }
	hash = (hash ~ u64(len(view.commands)))*1099511628211
	for command in view.commands {
		hash = frontier_hash_f32(hash, command.bounds.x)
		hash = frontier_hash_f32(hash, command.bounds.y)
		hash = frontier_hash_f32(hash, command.bounds.w)
		hash = frontier_hash_f32(hash, command.bounds.h)
		hash = frontier_hash_f32(hash, command.clip.x)
		hash = frontier_hash_f32(hash, command.clip.y)
		hash = frontier_hash_f32(hash, command.clip.w)
		hash = frontier_hash_f32(hash, command.clip.h)
		hash = frontier_hash_f32(hash, command.opacity)
		switch payload in command.payload {
		case alicorn.Text_Paint:
			if run, found := alicorn.paint_text_run_resolve(rt, payload.run); found && run != nil {
				hash = frontier_hash_text(hash, run.value)
			}
		case alicorn.Icon_Paint:
			hash = frontier_hash_text(hash, fmt.tprintf("icon:%v", payload.id))
		case alicorn.Image_Paint:
			hash = frontier_hash_text(hash, "image")
		case alicorn.Geometry_Paint:
			hash = frontier_hash_text(hash, "geometry")
		case alicorn.Surface_Paint:
			hash = frontier_hash_text(hash, "surface")
		case alicorn.Backdrop_Effect_Paint:
			hash = frontier_hash_text(hash, "effect")
		case alicorn.Lighting_Group_Paint:
			hash = frontier_hash_text(hash, "lighting")
		}
	}
	return hash
}

frontier_new_runtime :: proc(app: ^Frontier_App, use: ^alicorn.Runtime) -> bool {
	use^ = alicorn.new_runtime(alicorn.Rect{0, 0, 320, 320}, alicorn.Runtime_Config{trace_capacity=512})
	if !alicorn.font_load_bytes(use, .UI, FRONTIER_FIXTURE_FONT) { return false }
	_ = frontier_settle(use, app)
	return true
}

frontier_matches_fresh :: proc(rt: ^alicorn.Runtime, app: ^Frontier_App) -> bool {
	fresh: alicorn.Runtime
	fresh_app := app^
	if !frontier_new_runtime(&fresh_app, &fresh) { return false }
	defer alicorn.destroy_runtime(&fresh)
	return frontier_scene_hash(rt) == frontier_scene_hash(&fresh)
}

frontier_node_text :: proc(rt: ^alicorn.Runtime, key: alicorn.UI_Key) -> string {
	if id, found := alicorn.node_by_key(rt, key, .Text); found {
		if info, ok := alicorn.node_info(rt, id); ok {
			return fmt.tprintf("#%d w=%.2f h=%.2f", id, info.text_content_width, info.text_content_height)
		}
	}
	return "absent"
}

frontier_report :: proc(title: string, rt: ^alicorn.Runtime, cause_id: u64) {
	fmt.println("==== ", title, " ====")
	report := alicorn.frontier_inspect(rt, cause_id)
	fmt.print(report)
	delete(report)
}

main :: proc() {
	app := frontier_app()
	rt: alicorn.Runtime
	ids: [3]alicorn.Node_ID
	rt = alicorn.new_runtime(alicorn.Rect{0, 0, 320, 320}, alicorn.Runtime_Config{trace_capacity=512})
	defer alicorn.destroy_runtime(&rt)
	_ = alicorn.font_load_bytes(&rt, .UI, FRONTIER_FIXTURE_FONT)
	_ = frontier_settle(&rt, &app, &ids)
	fmt.println("[fixture] initial scene fresh-parity=", frontier_matches_fresh(&rt, &app))
	fmt.println("[fixture] nodes alpha/bravo/charlie/peer:",
		frontier_node_text(&rt, alicorn.key_pair(0, 1)),
		frontier_node_text(&rt, alicorn.key_pair(1, 1)),
		frontier_node_text(&rt, alicorn.key_pair(2, 1)),
		frontier_node_text(&rt, alicorn.key_string("fixture-peer-text")))

	// (1) Wrong-but-valid region: the app changes row Bravo but invalidates the
	// unrelated, live peer region. This is the first incorrect edge.
	app.rows[1].value = "Bravo changed in the app"
	app.rows[1].revision += 1
	alicorn.invalidate_region(&rt, "fixture-peer", app.peer_revision, "wrong-but-valid peer target")
	wrong_cause := rt.cause_sequence
	_ = frontier_settle(&rt, &app, &ids)
	fmt.println("[adversarial] changed dependency:", frontier_node_text(&rt, alicorn.key_pair(1, 1)))
	fmt.println("[adversarial] peer subscriber :", frontier_node_text(&rt, alicorn.key_string("fixture-peer-text")))
	fmt.println("[adversarial] fresh-parity=", frontier_matches_fresh(&rt, &app), "(false means stale output)")
	frontier_report("ADVERSARIAL: wrong-but-valid region", &rt, wrong_cause)
	fmt.println("why changed row region:",
		alicorn.frontier_why_touched(&rt, wrong_cause, ids[1]))

	// (2) Forgotten revision: the app changes row Alpha and requests no work.
	app.rows[0].value = "Alpha changed without a request"
	app.rows[0].revision += 1
	idle_passes := frontier_settle(&rt, &app, &ids)
	fmt.println("[adversarial] forgotten revision idle passes=", idle_passes,
		"fresh-parity=", frontier_matches_fresh(&rt, &app),
		"(no cause exists; the fresh-runtime oracle proves staleness)")

	// (3) Broad-ancestor invalidation: row Charlie changes and its revision is
	// bumped, while the declared target is the whole parent. The update is
	// correct but unexpectedly wide.
	app.rows[2].value = "Charlie changed under a broad target"
	app.rows[2].revision += 1
	app.parent_revision += 1
	alicorn.invalidate_region(&rt, "fixture-parent", app.parent_revision, "broad ancestor target")
	broad_cause := rt.cause_sequence
	_ = frontier_settle(&rt, &app, &ids)
	frontier_report("ADVERSARIAL: broad-ancestor region", &rt, broad_cause)

	// Repair every stale dependency and prove there is no continuing idle work.
	app.parent_revision += 1
	alicorn.invalidate_region(&rt, "fixture-parent", app.parent_revision, "repair all stale dependencies")
	_ = frontier_settle(&rt, &app, &ids)
	fmt.println("[adversarial] repaired fresh-parity=", frontier_matches_fresh(&rt, &app),
		"idle passes=", frontier_settle(&rt, &app, &ids))

	// Correct fixture: the same three mutations, each with the true dependency.
	correct := frontier_app()
	crt: alicorn.Runtime
	cids: [3]alicorn.Node_ID
	crt = alicorn.new_runtime(alicorn.Rect{0, 0, 320, 320}, alicorn.Runtime_Config{trace_capacity=512})
	defer alicorn.destroy_runtime(&crt)
	_ = alicorn.font_load_bytes(&crt, .UI, FRONTIER_FIXTURE_FONT)
	_ = frontier_settle(&crt, &correct, &cids)
	peer_before := frontier_node_text(&crt, alicorn.key_string("fixture-peer-text"))
	correct.rows[1].value = "Bravo changed in the app"
	correct.rows[1].revision += 1
	correct.parent_revision += 1
	alicorn.invalidate_region(&crt, correct.rows[1].key, correct.rows[1].revision, "correct child target")
	correct_cause := crt.cause_sequence
	_ = frontier_settle(&crt, &correct, &cids)
	local_parity := frontier_matches_fresh(&crt, &correct)
	fmt.println("[correct] bravo change fresh-parity=", local_parity,
		"peer unchanged=", peer_before == frontier_node_text(&crt, alicorn.key_string("fixture-peer-text")))
	frontier_report("CORRECT: child region invalidation", &crt, correct_cause)
	correct.rows[0].value = "Alpha changed with a request"
	correct.rows[0].revision += 1
	correct.parent_revision += 1
	alicorn.invalidate_region(&crt, correct.rows[0].key, correct.rows[0].revision, "correct alpha target")
	_ = frontier_settle(&crt, &correct, &cids)
	correct.rows[2].value = "Charlie changed with a request"
	correct.rows[2].revision += 1
	correct.parent_revision += 1
	alicorn.invalidate_region(&crt, correct.rows[2].key, correct.rows[2].revision, "correct charlie target")
	_ = frontier_settle(&crt, &correct, &cids)
	fmt.println("[correct] final fresh-parity=", frontier_matches_fresh(&crt, &correct),
		"idle passes=", frontier_settle(&crt, &correct, &cids))
	inspection := alicorn.inspect(&crt)
	defer delete(inspection)
	fmt.println("[correct] capture bundle contains frontier inventory=",
		strings.contains(inspection, "frontiers:"),
		"and cause records=", strings.contains(inspection, "cause #"))
}
