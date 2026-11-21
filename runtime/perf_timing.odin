package alicorn

// Per-stage CPU attribution for the issue #229 performance ledger.
//
// The timers are always enabled. They read the CPU cycle counter, accumulate
// one u64 per stage, and allocate nothing. Sections are measured with
// begin/finish pairs; nested stages (measure inside reconcile, text shaping
// inside measure and layout) are reported both as a total and as their own
// bucket.
//
// The cycle counter is calibrated once per process against the monotonic clock.
// That keeps the per-node hash/copy marks cheap enough to leave enabled: a
// core:time tick costs far more than the work it measures at 150-400 nodes.
// If a platform cannot expose a cycle counter, the same helpers fall back to
// time.tick_now rather than silently disabling attribution.
//
// Runtime_Timing_Stage is intentionally an ordinary enum so a test or
// benchmark can index Frame_Stats.stage_timings_ns without allocating.

import "base:intrinsics"
import "core:sync"
import "core:time"

Runtime_Timing_Stage :: enum {
	// Description covers begin_frame through the end of end_frame, including
	// application build and every runtime stage below.
	Description,
	// Reconcile covers the whole reconcile procedure, including the nested
	// measure, layout, semantic, paint, composition, and finalize buckets.
	Reconcile,
	// Reconcile_Hash and Reconcile_Copy are per-described-node sub-stages of
	// reconcile. They exclude the fixed per-node commit bookkeeping.
	Reconcile_Hash,
	Reconcile_Copy,
	// Structure_Diff covers bucket construction, child-list reconciliation,
	// retirement, and an order rebuild when structure changed.
	Structure_Diff,
	Measure,
	// Measure_Text is the text-shaping subset of work inside Measure and
	// Layout. It is reported as a shared bucket, not as a subset of Measure.
	Measure_Text,
	Layout,
	// Semantic_Sync covers adaptive semantic publication, focus realization,
	// collection pruning, and the semantic commit.
	Semantic_Sync,
	// Paint covers the retained paint-queue visit, including localized range
	// finalization. Composition covers a full display rebuild when the sparse
	// path could not be used.
	Paint,
	Composition,
	Finalize,
}

RUNTIME_TIMING_STAGE_COUNT :: int(Runtime_Timing_Stage.Finalize)+1

// Perf_Mark is an opaque monotonic snapshot. valid=false means "not measured"
// so a zero value never contributes a bogus duration.
Perf_Mark :: struct {
	cycles: i64,
	tick:   time.Tick,
	use_tick: bool,
	valid:  bool,
}

@(private)
perf_cycle_hz: u64
@(private)
perf_cycle_once: sync.Once

@(private)
perf_calibrate_cycles :: proc() {
	start_tick := time.tick_now()
	start_cycles := intrinsics.read_cycle_counter()
	// 200 µs is long enough for the monotonic clock to resolve a stable ratio
	// and short enough to be invisible during process startup.
	for time.duration_nanoseconds(time.tick_diff(start_tick, time.tick_now())) < 200_000 {}
	end_cycles := intrinsics.read_cycle_counter()
	end_tick := time.tick_now()
	elapsed_ns := time.duration_nanoseconds(time.tick_diff(start_tick, end_tick))
	if end_cycles <= start_cycles || elapsed_ns <= 0 { return }
	hz := u64((u128(u64(end_cycles-start_cycles))*1_000_000_000)/u128(u64(elapsed_ns)))
	if hz > 0 { sync.atomic_store(&perf_cycle_hz, hz) }
}

@(private)
perf_cycles_per_second :: proc() -> u64 {
	sync.once_do(&perf_cycle_once, perf_calibrate_cycles)
	return sync.atomic_load(&perf_cycle_hz)
}

// perf_mark_begin snapshots the cheapest available monotonic counter.
perf_mark_begin :: proc() -> Perf_Mark {
	if perf_cycles_per_second() > 0 {
		return Perf_Mark{cycles=intrinsics.read_cycle_counter(), valid=true}
	}
	return Perf_Mark{tick=time.tick_now(), use_tick=true, valid=true}
}

// perf_mark_elapsed_ns returns the elapsed nanoseconds, or zero for an
// unmeasured mark. A non-monotonic reading is clamped to zero so a stage total
// can never move backwards.
perf_mark_elapsed_ns :: proc(mark: Perf_Mark) -> u64 {
	if !mark.valid { return 0 }
	if mark.use_tick {
		elapsed := time.duration_nanoseconds(time.tick_diff(mark.tick, time.tick_now()))
		return u64(elapsed) if elapsed > 0 else 0
	}
	now := intrinsics.read_cycle_counter()
	if now <= mark.cycles { return 0 }
	hz := sync.atomic_load(&perf_cycle_hz)
	if hz == 0 { return 0 }
	return u64((u128(u64(now-mark.cycles))*1_000_000_000)/u128(hz))
}

// perf_add_mark accumulates one stage. This is the only write performed by the
// instrumentation, and it is always inlined at the call site.
perf_add_mark :: proc(rt: ^Runtime, stage: Runtime_Timing_Stage, mark: Perf_Mark) {
	if rt == nil || !mark.valid { return }
	rt.stats.stage_timings_ns[stage] += perf_mark_elapsed_ns(mark)
}

// perf_finish_description closes the Description bucket opened by begin_frame
// or begin_presentation_frame.
perf_finish_description :: proc(rt: ^Runtime) {
	if rt == nil || !rt.description_timing { return }
	perf_add_mark(rt, .Description, rt.description_mark)
	rt.description_timing = false
	rt.description_mark = Perf_Mark{}
}
