package testui

// Issue #193 invalidation-frontier checks mirror pattern_checks: one call
// verifies a bounded, published diagnostic contract and returns the first
// violated rule with the causal turn that produced it. The check never reads
// retained runtime storage; it uses the runtime's public frontier query, which
// is itself projected from the bounded trace ring and the debug-only capture.
//
// The helper works only in debug builds with the frontier gate enabled. In a
// release build (or with ALICORN_INVALIDATION_FRONTIER=false) it returns a
// clean .Capture_Available failure instead of silently passing.

import "core:fmt"
import "core:strings"
import alicorn "alicorn:runtime"

FRONTIER_CHECK_TEXT_CAPACITY :: 192

Frontier_Check_Step :: enum {
	Capture_Available,
	Resolve_Cause,
	Stage_Visits,
	Stage_Changed,
	Stage_Sample,
	Changed_Output,
	Fallback,
	Subscriber,
}

// Frontier_Stage_Expectation checks one author-facing stage. Every field is
// opt-in so a test can assert a count, a changed-output count, or a sampled
// node independently.
Frontier_Stage_Expectation :: struct {
	stage: alicorn.Frontier_Stage,
	check_visits: bool,
	visits: u64,
	check_changed: bool,
	changed: u64,
	check_sample: bool,
	sample: alicorn.Node_ID,
}

Frontier_Expectation :: struct {
	// use_turn_cause verifies the cause recorded by the most recent harness
	// turn. Set false and supply cause_id to inspect an older capture.
	use_turn_cause: bool,
	cause_id: u64,
	stages: []Frontier_Stage_Expectation,
	// check_unchanged requires the cause to have invalidated work while
	// changing no stage output (the Query-1 same-value-write distinction).
	check_unchanged: bool,
	expect_unchanged: bool,
	// Fallback policy. expect_no_fallbacks rejects any global retained-work
	// reason observed during the cause; required_fallback adds one positive
	// or negative reason assertion.
	expect_no_fallbacks: bool,
	check_required_fallback: bool,
	required_fallback: alicorn.Retained_Global_Work_Reason,
	required_fallback_present: bool,
	// check_subscriber requires the captured region invalidation to have
	// resolved this exact live subscriber instance.
	check_subscriber: bool,
	expected_subscriber: alicorn.Node_ID,
}

Frontier_Failure :: struct {
	step: Frontier_Check_Step,
	stage: alicorn.Frontier_Stage,
	stage_valid: bool,
	cause_id: u64,
	node: alicorn.Node_ID,
	expected: [FRONTIER_CHECK_TEXT_CAPACITY]u8,
	expected_length: int,
	actual: [FRONTIER_CHECK_TEXT_CAPACITY]u8,
	actual_length: int,
	message: [FRONTIER_CHECK_TEXT_CAPACITY]u8,
	message_length: int,
	turn: Turn_Report,
}

Frontier_Report :: struct {
	ok: bool,
	failure: Frontier_Failure,
}

frontier_capture_available :: proc() -> bool {
	return alicorn.frontier_capture_enabled()
}

@(private)
frontier_copy_text :: proc(buffer: []u8, length: ^int, text: string) {
	length^ = copy(buffer, text)
}

@(private)
frontier_fail_message :: proc(report: ^Frontier_Report, step: Frontier_Check_Step, expected, actual: string) {
	report.ok = false
	failure := &report.failure
	failure.step = step
	failure.stage_valid = false
	frontier_copy_text(failure.expected[:], &failure.expected_length, expected)
	frontier_copy_text(failure.actual[:], &failure.actual_length, actual)
}

@(private)
frontier_fail_stage :: proc(
	handle: ^Test_Handle($T),
	report: ^Frontier_Report,
	step: Frontier_Check_Step,
	stage: alicorn.Frontier_Stage,
	node: alicorn.Node_ID,
	expected, actual: string,
	message := "",
) {
	report.ok = false
	failure := &report.failure
	failure.step = step
	failure.stage = stage
	failure.stage_valid = true
	failure.node = node
	frontier_copy_text(failure.expected[:], &failure.expected_length, expected)
	frontier_copy_text(failure.actual[:], &failure.actual_length, actual)
	frontier_copy_text(failure.message[:], &failure.message_length, message)
	failure.turn = last_turn(handle)
	failure.cause_id = failure.turn.cause_id
}

@(private)
frontier_fail_capture :: proc(
	handle: ^Test_Handle($T),
	report: ^Frontier_Report,
	step: Frontier_Check_Step,
	cause_id: u64,
	expected, actual: string,
	message := "",
) {
	report.ok = false
	failure := &report.failure
	failure.step = step
	failure.cause_id = cause_id
	frontier_copy_text(failure.expected[:], &failure.expected_length, expected)
	frontier_copy_text(failure.actual[:], &failure.actual_length, actual)
	frontier_copy_text(failure.message[:], &failure.message_length, message)
	failure.turn = last_turn(handle)
}

@(private)
frontier_capture_has_subscriber :: proc(capture: ^alicorn.Frontier_Capture, node: alicorn.Node_ID) -> bool {
	for id in capture.subscribers[:capture.subscriber_count] {
		if id == node { return true }
	}
	return false
}

@(private)
frontier_subscribers_text :: proc(capture: ^alicorn.Frontier_Capture) -> string {
	builder := strings.builder_make(allocator=context.temp_allocator)
	alicorn.frontier_append_nodes(&builder, capture.subscribers[:], capture.subscriber_count)
	return strings.to_string(builder)
}

// frontier_check verifies one cause's invalidation frontier. The report stops
// at the first violated expectation and carries the failing step, expected and
// actual values, the node/stage/cause identity, and the last bounded turn.
frontier_check :: proc(handle: ^Test_Handle($T), expectation: Frontier_Expectation) -> Frontier_Report {
	report := Frontier_Report{ok=true}
	if handle == nil || handle.runtime == nil {
		frontier_fail_message(&report, .Resolve_Cause, "valid test handle", "nil handle")
		return report
	}
	if !alicorn.frontier_capture_enabled() {
		frontier_fail_capture(handle, &report, .Capture_Available, 0,
			"debug invalidation-frontier capture",
			"frontier capture unavailable (release build or ALICORN_INVALIDATION_FRONTIER=false)")
		return report
	}
	turn := last_turn(handle)
	cause_id := expectation.cause_id
	if expectation.use_turn_cause { cause_id = turn.cause_id }
	if cause_id == 0 {
		frontier_fail_capture(handle, &report, .Resolve_Cause, cause_id,
			"a non-zero cause recorded by the turn or supplied by the expectation",
			"cause 0 (unassigned work has no declared frontier)")
		return report
	}
	capture, found := alicorn.frontier_capture(handle.runtime, cause_id)
	if !found {
		frontier_fail_capture(handle, &report, .Resolve_Cause, cause_id,
			fmt.tprintf("a captured frontier for cause #%d", cause_id),
			"no capture (the cause may have left the bounded capture ring)")
		return report
	}
	summary := alicorn.frontier_trace_summary(handle.runtime, cause_id)

	for stage in expectation.stages {
		visits := alicorn.frontier_stage_visits(summary, stage.stage)
		if stage.check_visits && visits != stage.visits {
			frontier_fail_stage(handle, &report, .Stage_Visits, stage.stage, 0,
				fmt.tprintf("%d %s visit(s)", stage.visits, alicorn.frontier_stage_name(stage.stage)),
				fmt.tprintf("%d %s visit(s)", visits, alicorn.frontier_stage_name(stage.stage)),
				"stage visits come from the existing bounded trace ring")
			return report
		}
		changed := capture.changed[stage.stage]
		if stage.check_changed && changed != stage.changed {
			node := alicorn.Node_ID(0)
			if capture.changed_node_count[stage.stage] > 0 { node = capture.changed_nodes[stage.stage][0] }
			frontier_fail_stage(handle, &report, .Stage_Changed, stage.stage, node,
				fmt.tprintf("%d changed %s output(s)", stage.changed, alicorn.frontier_stage_name(stage.stage)),
				fmt.tprintf("%d changed %s output(s)", changed, alicorn.frontier_stage_name(stage.stage)),
				"visiting a stage is not the same as changing its output")
			return report
		}
		if stage.check_sample {
			samples := alicorn.frontier_stage_samples(summary, stage.stage)
			sampled := false
			for node in samples.nodes[:samples.count] {
				if node == stage.sample { sampled = true; break }
			}
			if !sampled {
				frontier_fail_stage(handle, &report, .Stage_Sample, stage.stage, stage.sample,
					fmt.tprintf("sampled node #%d", stage.sample),
					fmt.tprintf("%d sampled node(s) from the bounded ring", samples.count),
					"sampled IDs are the existing ring events for this stage, not a new event stream")
				return report
			}
		}
	}

	if expectation.check_unchanged {
		total := alicorn.frontier_changed_total(&capture)
		unchanged := total == 0
		if unchanged != expectation.expect_unchanged {
			frontier_fail_capture(handle, &report, .Changed_Output, cause_id,
				fmt.tprintf("changed outputs present=%t", !expectation.expect_unchanged),
				fmt.tprintf("changed outputs present=%t (total=%d)", !unchanged, total))
			return report
		}
	}

	if expectation.expect_no_fallbacks && capture.fallbacks != {} {
		actual_builder := fmt.tprintf("")
		for reason in alicorn.Retained_Global_Work_Reason {
			if reason not_in capture.fallbacks { continue }
			actual_builder = fmt.tprintf("%s%s ", actual_builder, alicorn.frontier_work_reason_name(reason))
		}
		frontier_fail_capture(handle, &report, .Fallback, cause_id,
			"no global retained-work fallback", actual_builder,
			"an unexpected fallback means the cause escaped the locality it declared")
		return report
	}
	if expectation.check_required_fallback {
		present := expectation.required_fallback in capture.fallbacks
		if present != expectation.required_fallback_present {
			frontier_fail_capture(handle, &report, .Fallback, cause_id,
				fmt.tprintf("fallback %s present=%t", alicorn.frontier_work_reason_name(expectation.required_fallback), expectation.required_fallback_present),
				fmt.tprintf("fallback %s present=%t", alicorn.frontier_work_reason_name(expectation.required_fallback), present),
				"fallbacks are diffed from global_work_by_reason during this cause")
			return report
		}
	}

	if expectation.check_subscriber && !frontier_capture_has_subscriber(&capture, expectation.expected_subscriber) {
		subscribers := frontier_subscribers_text(&capture)
		frontier_fail_capture(handle, &report, .Subscriber, cause_id,
			fmt.tprintf("subscriber #%d", expectation.expected_subscriber), subscribers,
			"subscribers are the live region instances resolved on the invalidation path")
		return report
	}
	return report
}

// frontier_failure_diagnostic formats a failed report for test output. It
// borrows the report only for the duration of the returned string.
frontier_failure_diagnostic :: proc(failure: ^Frontier_Failure) -> string {
	stage := "none"
	if failure.stage_valid { stage = fmt.tprintf("%v", failure.stage) }
	turn := fmt.tprintf(
		"turn(input=%v key=%v descriptions=%d focus=%d cause=%d/%v revision=%d->%d)",
		failure.turn.input, failure.turn.key, failure.turn.descriptions,
		failure.turn.focus, failure.turn.cause_id, failure.turn.cause_kind,
		failure.turn.semantic_revision_before, failure.turn.semantic_revision,
	)
	return fmt.tprintf(
		"frontier/%v cause=%d stage=%s node=%d expected=%q actual=%q %s %s",
		failure.step, failure.cause_id, stage, failure.node,
		string(failure.expected[:failure.expected_length]),
		string(failure.actual[:failure.actual_length]),
		string(failure.message[:failure.message_length]), turn,
	)
}
