# Benchmark evidence

Benchmark reports summarize workloads, environments, and interpretation. Raw
captures are kept separately under [`raw/`](raw/) so they remain available
without crowding the project’s user and contributor guides.

## Reports

- [Deferred system fallback faces — Issue #172 phase 2, Windows (2026-11-22)](native-startup-deferred-fallback-windows-2026-11-22.md)
  — paired A/B of deferring the DirectWrite/optional fallback stack to the
  first shaping miss: −117 to −119 ms fonts phase and −69 MiB runtime requested
  in all three apps, with a measured 116–121 ms first-fallback stall.
  **NO-GO as prototyped** under the issue's interaction-latency rule; the
  shipped default stays eager and the lazy path is opt-in.
- [Issue #104 phase A material-stream bottleneck — Windows (2026-11-22)](../validation/issue-104-phase-a-2026-11-22.md)
  — same-stream flat/rounded/relief expansion at 1x-2x, the per-frame native
  solid rebuild that dominates pack time, the hosted-WebGPU retention
  comparison, and the phase B disposition.
- [Native SDL_GPU startup attribution — Issue #172 phase 1, Windows (2026-11-21)](native-startup-attribution-windows-2026-11-21.md)
  — measurement-only startup markers plus a fresh-process attribution of
  working set, private bytes, GPU process memory, runtime requested bytes and
  the host-declared eager resource budget for Hello, Scratchpad and Punks, with
  warm/cold limits and a ranked lazy-init candidate list.
- [v0.3.0 measured performance ledger — Windows (2026-11-21)](v030-performance-ledger.md)
  — consolidated stage ledger for invalidation lookup, measure, layout, paint,
  display finalization, description/reconcile, and keyed regions; one row per
  measured result with its report and raw evidence, the #231 localization map,
  the Scratchpad A/B headline, and the limits/open-issue status.
- [Matched Scratchpad adoption + three-arm Quick Open — keyed regions, Windows (2026-11-21)](scratchpad-region-adoption-windows-2026-11-21.md)
- [Matched Scratchpad A/B — keyed-region pilot, Windows (2026-11-21)](scratchpad-region-pilot-windows-2026-11-21.md)
- [Matched Scratchpad A/B — phase 2 description reuse, Windows (2026-11-21)](scratchpad-ab-phase2-windows-2026-11-21.md)
- [Matched Scratchpad A/B — Windows (2026-11-21)](scratchpad-ab-windows-2026-11-21.md)
- [Sparse application updates and authoring cost — Issue #190 (Windows, 2026-11-21)](issue190-sparse-updates-windows-2026-11-21.md)
- [v0.2.1 candidate performance scorecard — Windows (2026-11-04)](performance-scorecard-v0.2.1-windows-2026-11-04.md)
- [Matched Scratchpad A/B — Windows (2026-11-04)](scratchpad-ab-windows-2026-11-04.md)
- [Initial retained-tree construction — Issue #157 (macOS, 2026-11-04)](issue-157-construction-cpu-macos-2026-11-04.md)
- [Performance audit — Windows, 2026-10-27](performance-audit-windows-2026-10-27.md)
- [Runtime performance audit — Windows, 2026-10-28](performance-audit-windows-2026-10-28.md)
- [Final performance refresh — Windows, 2026-10-28](performance-final-windows-2026-10-28.md)
- [Retained work — Windows](retained-work-windows.md)
- [Retained work — macOS](retained-work-macos.md)
- [Native dogfood — Windows](native-dogfood-windows.md)
- [Native hello — macOS](native-hello-macos.md)
- [Native materials — Windows](native-material-windows.md)
- [Text layout](text-layout.md)

Machine-specific captures are evidence for the named host and revision, not
cross-platform performance guarantees. The Windows 2026-10-27 report identifies
the post-merge benchmark set and its limits; repeat those workloads on macOS
before making cross-platform comparisons.
