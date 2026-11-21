package testui

import "core:fmt"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"

Frontier_Test_App :: struct {
	revision: u64,
	value: string,
	peer: string,
}

frontier_test_render :: proc(app: ^Frontier_Test_App, ui: ^alicorn.UI) {
	alicorn.container_begin(ui, .Root, key=alicorn.key_string("frontier-test-root"), style=alicorn.layout_style(.Column, gap=4))
	panel, reused := alicorn.region_begin(ui, "frontier-panel", app.revision,
		style=alicorn.layout_style(.Column, width=240, height=80))
	if panel != 0 && !reused {
		alicorn.text(ui, app.value, key=alicorn.key_string("frontier-value"), style=alicorn.layout_style(height=24))
		alicorn.region_end(ui, panel, false, 0)
	}
	peer, peer_reused := alicorn.region_begin(ui, "frontier-peer", 1,
		style=alicorn.layout_style(.Column, width=240, height=48))
	if peer != 0 && !peer_reused {
		alicorn.text(ui, app.peer, key=alicorn.key_string("frontier-peer-value"), style=alicorn.layout_style(height=24))
		alicorn.region_end(ui, peer, false, 0)
	}
	alicorn.container_end(ui)
}

@(test)
test_frontier_check_reports_captured_subscriber_and_changed_outputs :: proc(t: ^testing.T) {
	app := Frontier_Test_App{revision=1, value="Panel", peer="Peer"}
	h, status := open(&app, frontier_test_render, width=320, height=240)
	defer if h.runtime != nil { close(&h) }
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	if !frontier_capture_available() {
		report := frontier_check(&h, Frontier_Expectation{})
		testing.expect(t, !report.ok && report.failure.step == .Capture_Available,
			"a release/disabled build must report capture unavailable instead of passing silently")
		testing.expect(t, strings.contains(frontier_failure_diagnostic(&report.failure), "unavailable"),
			"the unavailable diagnostic must say why capture is absent")
		return
	}
	panel_id, panel_found := alicorn.node_by_key(h.runtime, alicorn.key_string("frontier-panel"), .Container)
	testing.expect(t, panel_found, "the fixture region must be retained")

	app.value = "Panel changed"
	app.revision += 1
	alicorn.invalidate_region(h.runtime, "frontier-panel", app.revision, "frontier check change")
	cause_id := h.runtime.cause_sequence
	testing.expect(t, step(&h, Input{kind=.Time_Advance}) == .Ok, last_turn_diagnostic(&h))
	testing.expect(t, h.last_turn.cause_id == cause_id,
		"the harness turn must retain the invalidation cause id")

	report := frontier_check(&h, Frontier_Expectation{
		use_turn_cause=true,
		check_subscriber=true,
		expected_subscriber=panel_id,
	})
	testing.expect(t, report.ok,
		fmt.tprintf("the turn cause must capture the resolved region subscriber: %s", frontier_failure_diagnostic(&report.failure)))

	capture, found := alicorn.frontier_capture(h.runtime, cause_id)
	testing.expect(t, found && capture.changed[.Description] > 0 && capture.changed[.Paint] > 0,
		"the changed text must produce changed description and paint outputs")
	changed_report := frontier_check(&h, Frontier_Expectation{
		use_turn_cause=true,
		stages=[]Frontier_Stage_Expectation{
			{stage=.Description, check_changed=true, changed=capture.changed[.Description]},
			{stage=.Paint, check_changed=true, changed=capture.changed[.Paint]},
		},
	})
	testing.expect(t, changed_report.ok,
		fmt.tprintf("changed-output expectations must match the capture: %s", frontier_failure_diagnostic(&changed_report.failure)))

	// Prove the helper reports the first incorrect expectation, not a generic
	// boolean failure.
	negative := frontier_check(&h, Frontier_Expectation{
		use_turn_cause=true,
		stages=[]Frontier_Stage_Expectation{
			{stage=.Paint, check_changed=true, changed=capture.changed[.Paint]+1},
		},
	})
	testing.expect(t, !negative.ok && negative.failure.step == .Stage_Changed && negative.failure.stage_valid &&
		negative.failure.stage == .Paint && negative.failure.cause_id == cause_id,
		fmt.tprintf("a mismatched changed-output expectation must fail at the stage with cause identity: %s",
			frontier_failure_diagnostic(&negative.failure)))
	diagnostic := frontier_failure_diagnostic(&negative.failure)
	testing.expect(t, strings.contains(diagnostic, "cause=") && strings.contains(diagnostic, "expected="),
		"the diagnostic must carry the cause, expected, and actual values")
}

@(test)
test_frontier_check_same_value_write_has_no_changed_output :: proc(t: ^testing.T) {
	app := Frontier_Test_App{revision=1, value="Panel", peer="Peer"}
	h, status := open(&app, frontier_test_render, width=320, height=240)
	defer if h.runtime != nil { close(&h) }
	if !testing.expect(t, status == .Ok, last_turn_diagnostic(&h)) { return }
	if !frontier_capture_available() { return }
	alicorn.invalidate_region(h.runtime, "frontier-panel", app.revision, "frontier same value")
	cause_id := h.runtime.cause_sequence
	testing.expect(t, step(&h, Input{kind=.Time_Advance}) == .Ok, last_turn_diagnostic(&h))
	report := frontier_check(&h, Frontier_Expectation{
		cause_id=cause_id,
		check_unchanged=true,
		expect_unchanged=true,
		expect_no_fallbacks=true,
	})
	testing.expect(t, report.ok,
		fmt.tprintf("a same-value write must visit the region without changing any stage output: %s", frontier_failure_diagnostic(&report.failure)))
	summary := alicorn.frontier_trace_summary(h.runtime, cause_id)
	testing.expect(t, summary.events > 0,
		"the ring must still contain the cause's visit events even when no output changed")
}
