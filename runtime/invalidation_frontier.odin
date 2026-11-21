package alicorn

import "core:fmt"
import "core:strings"

// Issue #193: invalidation-frontier capture.
//
// The trace ring already stamps cause_id on every event and remains the sole
// source of truth for visits and per-stage sampled nodes. This sidecar only
// adds the state the ring cannot express per cause: which region request was
// made, which retained nodes were already resolved as subscribers, the bounded
// ancestor chain, and whether a stage produced a changed output rather than
// merely being visited.
//
// The gate is compile-time. A release build (or an explicit
// `-define:ALICORN_INVALIDATION_FRONTIER=false`) compiles the store out of
// Runtime and every hook body to nothing. It adds no per-frame work,
// subscriptions, scans, or diagnostic allocations.
INVALIDATION_FRONTIER_ENABLED :: ODIN_DEBUG && #config(ALICORN_INVALIDATION_FRONTIER, true)

// All capture storage is fixed. These bounds keep one frontier below a few
// hundred bytes and make query formatting independent of trace capacity.
FRONTIER_CAUSE_CAPACITY :: 24
FRONTIER_SUBSCRIBER_LIMIT :: 8
FRONTIER_ANCESTOR_LIMIT :: 8
FRONTIER_SAMPLE_LIMIT :: 8
FRONTIER_CHANGED_SAMPLE_LIMIT :: 4
FRONTIER_KEY_CAPACITY :: 48

// Frontier_Stage is the author-facing stage vocabulary. Trace_Kind stays the
// finer-grained wire format; stage visits map onto the existing ring events.
Frontier_Stage :: enum u8 {
	Description,
	Measure,
	Layout,
	Paint,
	Composite,
}

FRONTIER_STAGE_COUNT :: int(Frontier_Stage.Composite)+1

// Frontier_Capture is a bounded summary keyed by the runtime's existing cause
// ID. It never owns strings: the region key is copied into a fixed buffer so a
// retired region index entry cannot leave the capture dangling.
Frontier_Capture :: struct {
	used: bool,
	cause_id: u64,
	cause_kind: Cause_Kind,
	action_id: Action_ID,
	first_sequence: u64,
	latest_sequence: u64,
	// invalidations counts every .Invalidation trace event attributed to the
	// cause. region_invalidations and root_invalidations classify the request
	// that produced it.
	invalidations: u64,
	region_invalidations: u64,
	root_invalidations: u64,
	region_key: [FRONTIER_KEY_CAPACITY]u8,
	region_key_length: int,
	region_key_hash: u64,
	region_revision: u64,
	// Subscribers are the live region nodes invalidate_region already resolved
	// from the maintained key index. Ancestors are their bounded parent chain.
	subscribers: [FRONTIER_SUBSCRIBER_LIMIT]Node_ID,
	subscriber_count: int,
	ancestors: [FRONTIER_ANCESTOR_LIMIT]Node_ID,
	ancestor_count: int,
	// changed counts outputs a stage actually produced (a new or changed
	// description, an executed measurement with a changed result, layout
	// writes, paint updates, and composite finalization). A stage may be
	// visited many times and change nothing; that is the Query-1 distinction.
	changed: [Frontier_Stage]u64,
	changed_nodes: [Frontier_Stage][FRONTIER_CHANGED_SAMPLE_LIMIT]Node_ID,
	changed_node_count: [Frontier_Stage]int,
	// fallbacks records global retained-work reasons observed while the cause
	// was active, diffed from the cause's first captured event.
	fallbacks: bit_set[Retained_Global_Work_Reason],
	fallback_work: u64,
	work_baseline: [Retained_Global_Work_Reason]u64,
}

Frontier_Node_Samples :: struct {
	count: int,
	nodes: [FRONTIER_SAMPLE_LIMIT]Node_ID,
}

// Frontier_Trace_Summary is projected from the existing ring on demand. It
// allocates nothing and never extends the trace.
Frontier_Trace_Summary :: struct {
	cause_id: u64,
	events: u64,
	visits: [Trace_Kind]u64,
	samples: [Trace_Kind]Frontier_Node_Samples,
}

when INVALIDATION_FRONTIER_ENABLED {
	Frontier_Store :: struct {
		entries: [FRONTIER_CAUSE_CAPACITY]Frontier_Capture,
		next: int,
		count: int,
	}
} else {
	Frontier_Store :: struct {}
}

// frontier_capture_enabled reports the compile-time gate so hosts and test
// helpers can distinguish "no work in this cause" from "capture not built".
frontier_capture_enabled :: proc() -> bool {
	return INVALIDATION_FRONTIER_ENABLED
}

@(private)
frontier_node_list_contains :: proc(nodes: []Node_ID, count: int, id: Node_ID) -> bool {
	for index in 0..<min(count, len(nodes)) {
		if nodes[index] == id { return true }
	}
	return false
}

when INVALIDATION_FRONTIER_ENABLED {
	@(private)
	frontier_reset_capture :: proc(rt: ^Runtime, capture: ^Frontier_Capture, cause: Cause_Context) -> ^Frontier_Capture {
		capture^ = Frontier_Capture{
			used=true,
			cause_id=cause.id,
			cause_kind=cause.kind,
			action_id=cause.action_id,
			first_sequence=rt.trace.sequence,
			latest_sequence=rt.trace.sequence,
			work_baseline=rt.stats.global_work_by_reason,
		}
		return capture
	}

	// frontier_entry finds the bounded capture for this cause, creating it on
	// first mention. More causes than capacity evict the oldest entry; the
	// fixed ring is the only storage and is never resized.
	@(private)
	frontier_entry :: proc(rt: ^Runtime, cause: Cause_Context) -> ^Frontier_Capture {
		if rt == nil { return nil }
		for index in 0..<rt.frontier.count {
			entry := &rt.frontier.entries[index]
			if entry.used && entry.cause_id == cause.id {
				if cause.action_id != Action_ID(0) && entry.action_id == Action_ID(0) { entry.action_id = cause.action_id }
				if cause.kind != .None { entry.cause_kind = cause.kind }
				return entry
			}
		}
		if rt.frontier.count < FRONTIER_CAUSE_CAPACITY {
			entry := &rt.frontier.entries[rt.frontier.count]
			rt.frontier.count += 1
			return frontier_reset_capture(rt, entry, cause)
		}
		entry := &rt.frontier.entries[rt.frontier.next]
		rt.frontier.next = (rt.frontier.next+1)%FRONTIER_CAUSE_CAPACITY
		return frontier_reset_capture(rt, entry, cause)
	}

	@(private)
	frontier_observe_work :: proc(rt: ^Runtime, capture: ^Frontier_Capture) {
		total: u64
		for reason in Retained_Global_Work_Reason {
			value := rt.stats.global_work_by_reason[reason]
			baseline := capture.work_baseline[reason]
			if value > baseline { capture.fallbacks += {reason} }
			if value >= baseline { total += value-baseline }
		}
		capture.fallback_work = total
	}

	frontier_note_trace :: proc(rt: ^Runtime, cause: Cause_Context, sequence: u64, kind: Trace_Kind) {
		capture := frontier_entry(rt, cause)
		if capture == nil { return }
		if capture.first_sequence == 0 { capture.first_sequence = sequence }
		capture.latest_sequence = sequence
		if kind == .Invalidation { capture.invalidations += 1 }
		frontier_observe_work(rt, capture)
	}

	frontier_note_cause_end :: proc(rt: ^Runtime, cause: Cause_Context) {
		if rt == nil { return }
		for index in 0..<rt.frontier.count {
			entry := &rt.frontier.entries[index]
			if entry.used && entry.cause_id == cause.id {
				frontier_observe_work(rt, entry)
				return
			}
		}
	}

	// frontier_note_changed records a stage output that actually changed. It
	// never allocates and never records a trace event; the ring remains the
	// visit log and this is the changed-output annotation.
	frontier_note_changed :: proc(rt: ^Runtime, stage: Frontier_Stage, node: Node_ID) {
		if rt == nil { return }
		cause := trace_current_cause(rt)
		capture := frontier_entry(rt, cause)
		if capture == nil { return }
		capture.changed[stage] += 1
		count := capture.changed_node_count[stage]
		if node != 0 && count < FRONTIER_CHANGED_SAMPLE_LIMIT &&
			!frontier_node_list_contains(capture.changed_nodes[stage][:], count, node) {
			capture.changed_nodes[stage][count] = node
			capture.changed_node_count[stage] = count+1
		}
	}

	// frontier_note_region copies the bounded invalidation target and its
	// already-resolved subscribers. Callers pass the node list they just
	// filtered, so this is O(instances of the key) and adds no scan. Ancestors
	// walk only parent links from those subscribers.
	frontier_note_region :: proc(
		rt: ^Runtime,
		cause: Cause_Context,
		key: string,
		revision: u64,
		subscribers: []Node_ID,
	) {
		if rt == nil { return }
		capture := frontier_entry(rt, cause)
		if capture == nil { return }
		capture.region_invalidations += 1
		capture.region_revision = revision
		length := min(len(key), FRONTIER_KEY_CAPACITY)
		capture.region_key = {}
		if length > 0 { copy(capture.region_key[:length], key[:length]) }
		capture.region_key_length = length
		capture.region_key_hash = hash_string(key)
		capture.subscribers = {}
		capture.subscriber_count = 0
		for id in subscribers {
			node, found := rt.nodes[id]
			if !found || node == nil || !node.active || !node.region || node.label != key { continue }
			if capture.subscriber_count >= FRONTIER_SUBSCRIBER_LIMIT { break }
			if frontier_node_list_contains(capture.subscribers[:], capture.subscriber_count, id) { continue }
			capture.subscribers[capture.subscriber_count] = id
			capture.subscriber_count += 1
		}
		capture.ancestors = {}
		capture.ancestor_count = 0
		for id in capture.subscribers[:capture.subscriber_count] {
			current := id
			for _ in 0..<FRONTIER_ANCESTOR_LIMIT {
				node, found := rt.nodes[current]
				if !found || node == nil || node.parent == 0 { break }
				parent := node.parent
				if parent == id { break }
				if !frontier_node_list_contains(capture.ancestors[:], capture.ancestor_count, parent) {
					if capture.ancestor_count >= FRONTIER_ANCESTOR_LIMIT { break }
					capture.ancestors[capture.ancestor_count] = parent
					capture.ancestor_count += 1
				}
				current = parent
			}
		}
		frontier_observe_work(rt, capture)
	}

	frontier_note_root :: proc(rt: ^Runtime, cause: Cause_Context) {
		if rt == nil { return }
		capture := frontier_entry(rt, cause)
		if capture == nil { return }
		capture.root_invalidations += 1
	}
} else {
	frontier_note_trace :: proc(rt: ^Runtime, cause: Cause_Context, sequence: u64, kind: Trace_Kind) {}
	frontier_note_cause_end :: proc(rt: ^Runtime, cause: Cause_Context) {}
	frontier_note_changed :: proc(rt: ^Runtime, stage: Frontier_Stage, node: Node_ID) {}
	frontier_note_region :: proc(rt: ^Runtime, cause: Cause_Context, key: string, revision: u64, subscribers: []Node_ID) {}
	frontier_note_root :: proc(rt: ^Runtime, cause: Cause_Context) {}
}

// frontier_capture returns a value copy of the bounded capture for cause_id.
// The copy owns no strings and remains valid after later trace overwrites.
frontier_capture :: proc(rt: ^Runtime, cause_id: u64) -> (capture: Frontier_Capture, found: bool) {
	when INVALIDATION_FRONTIER_ENABLED {
		if rt == nil { return {}, false }
		for index in 0..<rt.frontier.count {
			entry := &rt.frontier.entries[index]
			if entry.used && entry.cause_id == cause_id {
				return entry^, true
			}
		}
	}
	return {}, false
}

// frontier_trace_summary projects visits and sampled node IDs for one cause
// from the existing bounded ring. It adds no events and allocates nothing.
frontier_trace_summary :: proc(rt: ^Runtime, cause_id: u64) -> Frontier_Trace_Summary {
	summary := Frontier_Trace_Summary{cause_id=cause_id}
	if rt == nil || rt.trace.count <= 0 || len(rt.trace.events) <= 0 { return summary }
	for offset in 0..<rt.trace.count {
		index := (rt.trace.next-1-offset+len(rt.trace.events))%len(rt.trace.events)
		event := &rt.trace.events[index]
		if event.cause_id != cause_id { continue }
		summary.events += 1
		summary.visits[event.kind] += 1
		if event.node != 0 {
			samples := &summary.samples[event.kind]
			if samples.count < FRONTIER_SAMPLE_LIMIT &&
				!frontier_node_list_contains(samples.nodes[:], samples.count, event.node) {
				samples.nodes[samples.count] = event.node
				samples.count += 1
			}
		}
	}
	return summary
}

frontier_stage_trace_kind :: proc(stage: Frontier_Stage) -> Trace_Kind {
	switch stage {
	case .Description: return .Reconcile
	case .Measure: return .Measure
	case .Layout: return .Layout
	case .Paint: return .Paint
	case .Composite: return .Composite
	}
	return .Reconcile
}

frontier_stage_name :: proc(stage: Frontier_Stage) -> string {
	switch stage {
	case .Description: return "description"
	case .Measure: return "measure"
	case .Layout: return "layout"
	case .Paint: return "paint"
	case .Composite: return "composite"
	}
	return "unknown"
}

frontier_work_reason_name :: proc(reason: Retained_Global_Work_Reason) -> string {
	switch reason {
	case .Measure_Font_Generation: return "measure-font-generation"
	case .Display_Structure_Rebuild: return "display-structure-rebuild"
	case .Display_Scale_Change: return "display-scale-change"
	case .Display_Transient_Update: return "display-transient-update"
	case .Display_Incremental_Fallback: return "display-incremental-fallback"
	case .Semantic_Order_Rebuild: return "semantic-order-rebuild"
	}
	return "unknown"
}

frontier_stage_visits :: proc(summary: Frontier_Trace_Summary, stage: Frontier_Stage) -> u64 {
	return summary.visits[frontier_stage_trace_kind(stage)]
}

frontier_stage_samples :: proc(summary: Frontier_Trace_Summary, stage: Frontier_Stage) -> Frontier_Node_Samples {
	return summary.samples[frontier_stage_trace_kind(stage)]
}

frontier_changed_total :: proc(capture: ^Frontier_Capture) -> u64 {
	total: u64
	for stage in Frontier_Stage { total += capture.changed[stage] }
	return total
}

frontier_key_text :: proc(capture: ^Frontier_Capture) -> string {
	length := clamp(capture.region_key_length, 0, len(capture.region_key))
	return string(capture.region_key[:length])
}

frontier_append_nodes :: proc(sb: ^strings.Builder, nodes: []Node_ID, count: int) {
	fmt.sbprintf(sb, "[")
	for index in 0..<min(count, len(nodes)) {
		if index > 0 { fmt.sbprintf(sb, ",") }
		fmt.sbprintf(sb, "%d", nodes[index])
	}
	fmt.sbprintf(sb, "]")
}

frontier_append_samples :: proc(sb: ^strings.Builder, samples: ^Frontier_Node_Samples) {
	frontier_append_nodes(sb, samples.nodes[:], samples.count)
}

frontier_append_work_reasons :: proc(sb: ^strings.Builder, reasons: bit_set[Retained_Global_Work_Reason]) {
	if reasons == {} { fmt.sbprintf(sb, "none"); return }
	first := true
	for reason in Retained_Global_Work_Reason {
		if reason not_in reasons { continue }
		if !first { fmt.sbprintf(sb, ",") }
		fmt.sbprintf(sb, "%s", frontier_work_reason_name(reason))
		first = false
	}
}

frontier_append_fallbacks :: proc(sb: ^strings.Builder, capture: ^Frontier_Capture) {
	frontier_append_work_reasons(sb, capture.fallbacks)
}

// frontier_populate_cause projects one bounded capture into the inspector's
// fixed-size cause summary. Strings stay out: only the copied key bytes, IDs,
// counts, and reason-bit flags cross into the overlay.
frontier_populate_cause :: proc(rt: ^Runtime, cause_id: u64, cause: ^Inspector_Cause) {
	if cause == nil { return }
	cause.capture_available = INVALIDATION_FRONTIER_ENABLED
	capture, found := frontier_capture(rt, cause_id)
	if !found { return }
	cause.invalidations = capture.invalidations
	cause.region_invalidations = capture.region_invalidations
	cause.root_invalidations = capture.root_invalidations
	cause.region_key = capture.region_key
	cause.region_key_length = capture.region_key_length
	cause.region_key_hash = capture.region_key_hash
	cause.region_revision = capture.region_revision
	cause.subscribers = capture.subscribers
	cause.subscriber_count = capture.subscriber_count
	cause.ancestors = capture.ancestors
	cause.ancestor_count = capture.ancestor_count
	cause.changed = capture.changed
	cause.fallbacks = capture.fallbacks
	cause.fallback_work = capture.fallback_work
}

frontier_cause_total_changed :: proc(cause: ^Inspector_Cause) -> u64 {
	total: u64
	for stage in Frontier_Stage { total += cause.changed[stage] }
	return total
}

// frontier_append_recent writes a bounded one-line-per-cause inventory for
// inspect() and capture bundles. Newest captures print first.
frontier_append_recent :: proc(sb: ^strings.Builder, rt: ^Runtime, limit: int) -> bool {
	when INVALIDATION_FRONTIER_ENABLED {
		if rt == nil { return false }
		printed := 0
		for offset in 0..<rt.frontier.count {
			if printed >= limit { break }
			index := rt.frontier.count-1-offset
			entry := &rt.frontier.entries[index]
			if !entry.used { continue }
			printed += 1
			fmt.sbprintf(sb, "  cause #%d %v action=%d traces=%d..%d invalidations=%d root=%d region=%d",
				entry.cause_id, entry.cause_kind, u32(entry.action_id),
				entry.first_sequence, entry.latest_sequence, entry.invalidations,
				entry.root_invalidations, entry.region_invalidations)
			if entry.region_key_length > 0 {
				fmt.sbprintf(sb, " key=%s@%d", frontier_key_text(entry), entry.region_revision)
			}
			if entry.subscriber_count > 0 {
				fmt.sbprintf(sb, " subscribers=")
				frontier_append_nodes(sb, entry.subscribers[:], entry.subscriber_count)
			}
			if entry.ancestor_count > 0 {
				fmt.sbprintf(sb, " ancestors=")
				frontier_append_nodes(sb, entry.ancestors[:], entry.ancestor_count)
			}
			fmt.sbprintf(sb, " changed=description:%d,measure:%d,layout:%d,paint:%d,composite:%d fallbacks=",
				entry.changed[.Description], entry.changed[.Measure], entry.changed[.Layout],
				entry.changed[.Paint], entry.changed[.Composite])
			frontier_append_work_reasons(sb, entry.fallbacks)
			fmt.sbprintln(sb)
		}
		return printed > 0
	}
	return false
}
