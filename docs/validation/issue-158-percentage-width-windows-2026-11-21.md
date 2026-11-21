# Percentage-width production validation — Windows

Date: 2026-11-21. Status: automated coverage, the Scratchpad source suite, and the
consumer-shaped CPU A/B are complete; the Scratchpad executable A/B on a
scripted native trace and physical-display interaction remain open.

This record covers the retained, definite-parent percentage-width capability
kept from Alicorn #109 and tracked for production acceptance by
[#158](https://github.com/Carnival-Science/Alicorn/issues/158). It does not
reopen the wider sizing-algebra decision: percentage height, aspect ratio,
`allocated()`, and a general constraint solver remain out of scope.

## Revisions and environment

| Item | Value |
| --- | --- |
| Alicorn | `codex/issue-158-54-validation`, implementation commit `f8454f0` |
| Odin | `dev-2026-11-nightly:08539cd` |
| Host | Windows 10 Home 22H2, build 19045; Ryzen 5 7600X, 12 logical processors, 15.2 GiB RAM |
| GPU | NVIDIA GeForce RTX 2080 SUPER, driver 32.0.15.9597 |
| Build profile | Release `-o:speed`, headless benchmark executable |

## Automated coverage

`ui/ui_percent_validation_test.odin` adds production-shaped compositions to the
existing `ui/ui_authoring_test.odin` percentage cases:

- two nested percentage columns under the Root viewport, including wrapped text,
  across retained-only resizes of 800/1000/640/1200 and fresh-runtime geometry
  parity at every size;
- the same nested pair inside a reused region whose fixed parent changes from
  400 to 600 without a revision change: stable `Node_ID`s, updated outer/inner
  widths, updated wrapped-text constraint, and equality with a fresh runtime;
- a percentage row containing a percentage column with a scroll region and
  button, plus a capped percentage panel; retained resize releases/widens the
  uncapped column while the panel stays capped, and the nested scroll viewport
  follows;
- a positioned badge inside a percentage owner that re-anchors when a preceding
  percentage sibling changes width, including presentation-scale (`1.25 x 1.5`)
  snapping without a second logical width multiply;
- a palette-only theme switch and a 1.5x text scale: identity and percentage
  basis stay fixed while the wrapped body remeasures and grows;
- a zero-percentage tree: no sidecar allocation, no layout work in settled
  retained frames, and no synthetic idle wake.

The validation exposed one ordering gap and it is fixed in
`runtime/percent_width.odin`: nested percentage relationships are now resolved
parent-first. The dependency maps have no iteration order, so the previous
single pass could read an outer percentage parent's previous-frame width. Flat
trees, including the measured single-dependency consumer, keep the
allocation-free single pass; nested trees use a small scratch-ordered pass.

`tools/test.ps1` passed on this branch: 421 runtime tests, 56 UI tests, 37 theme
tests, 13 testui tests, 23 CPU-renderer tests, 169 native SDL_GPU tests, 6
scroll-capture tests, and the remaining host suites; the foundation, restart,
and text-input/native-ownership contracts also passed. Host Windows PowerShell
5.1 required two harness-only workarounds that do not change Alicorn code: the
pinned odin-accesskit native UIA example was skipped (the documented
`verify-uia.ps1` window-selection flake in odin-accesskit#1), and the
intentionally invalid theme CLI check needed a local continue-on-native-stderr
scope so its expected nonzero exit could be read. The workarounds were reverted
before committing.

## Consumer-shaped A/B

The Scratchpad font picker is the demonstrated consumer and uses exactly one
percentage relationship: a modal panel with `width=percent(1)`,
`max_width=900`, overlay padding 24, and a fixed height cap. The benchmark
fixture in `benchmarks/diagnostics/issue158_percent_width_benchmark.odin`
reproduces that composition (header/footer text, default row, and twelve
retained result rows) with two behavior-equivalent variants:

- `percentage`: `width=percent(1), max_width=900`;
- `manual`: `width=min(viewport.w-48, 900)`.

Both variants rebuild the same description on every measured frame, so the
resize trace contains the same application, measurement, and layout work. The
fixture asserts identical panel and row geometry at 800 (752 wide) and 1200
(900, capped). It is a consumer-shaped CPU fixture, not the Scratchpad
executable, and it does not include GPU submission or displayed-frame latency.

Method: 100 warmup frames and 2,000 measured frames per trace, five fresh
release processes, medians of per-process p95. `same_width` redescribes at
1200; `resize_cap_release` alternates 800/1200; `idle` polls a settled tree.
Times are microseconds except allocations/bytes.

| Trace | Variant | Frame p95 | Frame p50 | Describe p95 | Layout p95 | Alloc calls | Live bytes | Layout updates | Measure hits/misses |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| same_width | percentage | 14.9 | 11.9 | 4.6 | 10.4 | 8,000 | 1 | 0 | 0 / 0 |
| same_width | manual | 14.9 | 12.0 | 4.3 | 9.3 | 8,000 | 1 | 0 | 0 / 0 |
| resize_cap_release | percentage | 162.3 | 125.3 | 4.9 | 158.3 | 656,000 | 5,760,001 | 64,000 | 8,000 / 116,000 |
| resize_cap_release | manual | 171.1 | 124.4 | 5.2 | 166.1 | 656,000 | 5,760,001 | 64,000 | 8,000 / 116,000 |
| idle | percentage | 0.1 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 / 0 |
| idle | manual | 0.1 | 0.0 | 0.0 | 0.0 | 0 | 0 | 0 | 0 / 0 |

Interpretation:

- At the measured consumer fanout of one, the percentage variant is within
  run noise of the manual baseline on the same-width and resize traces. The
  complete-frame p95 is identical in the same-width trace; the layout-stage p95
  is 1.1 us higher for the percentage variant, which is the retained sidecar
  pass over one relationship. That is about 7% of this deliberately shallow
  12-15 us headless full-rebuild frame, or roughly 0.007% of a 16.7 ms display
  frame. The resize p95 difference favors the percentage variant and is not
  attributable to the sidecar: both variants perform identical width-changing
  measurement and layout work and record identical allocation and
  measurement-cache counters.
- Allocations, live-byte growth, layout updates, and measurement hits/misses
  are identical between variants. The percentage sidecar contributes one
  retained relationship and no per-frame allocation at this fanout.
- A tree with no percentage declarations never initializes the sidecar. Settled
  idle polls cost 0.1 us p95, allocate nothing, and perform no layout.
- The manual baseline reaches 752 at an 800 viewport and 900 at 1200; the
  percentage variant matches both. The cap release is behaviorally identical.

Raw capture: [`raw/issue-158-percent-width-windows-2026-11-21.txt`](raw/issue-158-percent-width-windows-2026-11-21.txt).

## Scratchpad consumer revision check

Scratchpad commit `adb28fc` (the checkout's pre-existing uncommitted generated
theme edits were preserved and were the only tracked changes before and after
the run) was validated against Alicorn `f8454f0` with the consumer's own
candidate-override path:

```powershell
go run ./cmd/alicorn-dev test `
  --alicorn-root <alicorn checkout> --allow-alicorn-revision `
  --odin <odin> --out out/alicorn-158-validation
```

The run passed its Go unit packages, Caliber bridge/lifecycle tests, theme
codegen, and all 257 frontend tests. Scratchpad's lock still pins Alicorn
`0beff9d`; this was a candidate-override validation, not a lock rewrite. The
suite includes the font picker's narrow/grow/cap identity regression and its
theme, focus, and selection paths, but it does not measure native frame time.
Summary: [`raw/issue-158-scratchpad-suite-2026-11-21.txt`](raw/issue-158-scratchpad-suite-2026-11-21.txt).

## Fanout decision

The demonstrated consumer has one dependent. The 128/256-dependent resize
costs in the #109 synthetic capture remain a stress profile, not a consumer
workload. Sibling-invalidation batching is therefore **not** added; keep the
sidecar sparse and revisit only if a real application with a materially higher
fanout shows the cost.

## Limits and untested configurations

- No Scratchpad executable A/B on a scripted native interaction trace was run
  for this record. The consumer-shaped fixture is the measured substitute and
  is labelled as such; the source suite proves the consumer still builds and
  behaves correctly on this revision but is not a frame-time comparison.
- Physical per-monitor DPI transitions, monitor moves, and native font-picker
  focus/selection retention were not exercised. Presentation-scale snapping at
  1.25/1.5 and theme/text-scale changes are covered headlessly.
- No GPU complete-frame time, present latency, scanout, or input-to-display
  measurement is claimed. The benchmark is CPU-only.
- macOS and Linux were not run for this record.

## Decision

Keep definite-parent percentage width narrow and opt-in for the demonstrated
Scratchpad relationship. Do not add sibling batching, percentage height, aspect
ratio, `allocated()`, or a general solver from this validation. The remaining
closure work for #158 is the pinned Scratchpad executable comparison and the
native interactive checks above.
