# Issue #106 — Incremental-vs-fresh-runtime invalidation oracle

Status: initial scope COMPLETE. Two fixed-seed cases deterministically catch a
mis-scoped invalidation and an omitted invalidation through public APIs at
bounded cost. Issue #193 later exercised six of the previously optional corpus
ideas (dynamic adaptive branch change, keyed owner retirement/reopen,
same-value writes, cross-window consumers, valid-but-wrong ancestor and
sibling targets, and structural condition changes); see the
[#193 validation record](issue-193-invalidation-frontier-2026-11-21.md).

## Purpose and boundary

`runtime/invalidation_coherence_test.odin` compares a retained runtime after
declared app-model mutations with a fresh runtime described from the same model.
It is a deterministic test fixture, not production instrumentation. It does not
observe arbitrary Odin memory, infer missing revisions, or add per-frame
full-tree scans to applications.

The current fixture has three keyed regions and one unrelated peer. It exercises
content changes, typography scale, analytic surface material, combined changes,
root/parent/child invalidation, keyed reorder/removal, focus and semantic state,
text-field interaction and line geometry, and settled idle behavior. The
comparison uses public node/key queries, `Node_Info`, semantic snapshots,
text-field queries, text-line geometry, and stable resolved style/paint summaries
from the public inspector. Runtime-private node maps, display lists, and text-run
tables are not read. The inspector projection is not a GPU pixel comparison.

## Seeded failures and replay

The test `test_seeded_invalidation_oracle_replays_and_shrinks_wrong_region_failure`
uses fixed seed `0x106A11CE` to create eight deterministic mutations. At the
seed-derived fault step, it mutates one row but invalidates the unrelated peer.
That request schedules a description and does not trigger the advisory mutation
diagnostic, yet the retained row diverges from a fresh description. The test
checks the first failing prefix and deletes irrelevant actions until the minimal
reproduction contains only the wrong-region mutation.

The test `test_seeded_invalidation_oracle_catches_omitted_invalidation` uses
fixed seed `0x106A11CF` with the same bounds. At its seed-derived fault step the
app records the changed revision through the public mutation scope but requests
no invalidation. The retained output stays stale, so the fresh comparison
diverges at that step, the first-failing-prefix replay stops there, and action
deletion again reduces the report to the single omitted mutation. Replaying the
same mutations with a root invalidation must match a fresh runtime after every
step and settle with no description, layout, or presentation work pending.

Correct generated actions draw from root, parent, and child declarations, so the
corpus covers every supported correct scope; only the seed-derived fault step is
replaced. Mutation domains include content, typography scale, analytic material,
and combined changes. The diagnostic text includes the seed, minimal action
sequence, first divergence, keyed path, changed domain, invalidation scope, and
advisory-diagnostic count.

The wrong-region case demonstrates what advisory diagnostics cannot prove: a
caller can request work while invalidating a valid but unrelated region. The
omitted case covers the complementary misuse. When application-mutation
diagnostics are enabled, the advisory finding records the missing request, but
the oracle still supplies what the advisory cannot: proof that retained output is
stale and which keyed path diverges. The fresh-runtime comparison detects stale
output without claiming that Alicorn can infer which application-owned value
changed.

## Corpus review

Covered now:

- invalidation declarations: root, parent, and child for correct generated
  actions; wrong region and omitted as the two seeded faults;
- mutation domains: content, typography scale, analytic material, and combined;
- keyed reorder and removal, focus and semantic state, text-field interaction
  and line geometry, and settled idle behavior in the hand-written tests;
- reproducible generation from two fixed seeds, first-failing-prefix replay,
  action-deletion shrinking, and a stable failure report.
- issue #193 extensions: adaptive subscription branch changes, keyed owner
  retirement/reopen, same-value writes (no changed output), cross-window
  consumers, wrong-but-valid ancestor vs sibling targets, and structural
  condition add/remove. Each asserts fresh-runtime parity, and the same-value
  case also checks the debug frontier's zero changed-output count.

Remaining outside the initial scope, and why that is acceptable:

- virtualized-range changes and broad insertion/removal sequences need fixture
  APIs the current supported queries do not expose, so each would require a new
  fixture rather than another generated action;
- text selection and composition sequences need synthetic input and editor
  state that would duplicate the existing text-input contract tests;
- delayed corrective descriptions are already exercised by the consumed-action
  and forgotten-request tests in the same file;
- DPI and theme transitions change rendering inputs outside the invalidation
  contract and are covered by the DPI/theme validation records;
- focus and semantic mutation inside the seeded sequence would change the
  shrink and first-failure invariants for little new invalidation signal, since
  focus already has a deterministic test.

## Decision: initial scope complete

Issue #106's acceptance criteria are met:

- at least one seeded invalidation misuse is caught — two misuse classes are
  caught;
- replay is deterministic from the recorded seeds, action logs, and commands;
- comparisons use only public APIs, not retained runtime storage;
- CI cost is bounded: two seeds of eight actions over three rows, no fuzzing,
  no per-frame scans, and no new dependencies;
- further corpus expansion is an explicit NO-GO for the initial scope unless a
  concrete regression justifies the added fixture maintenance.

The expanded corpus ideas above remain optional follow-ups.

## Bounds and current limits

The generated case count is fixed at two seeds and eight actions each over three
rows; prefix replay and action deletion are bounded by each short sequence. The
fixture is covered by the ordinary `odin test runtime` suite and does not fuzz.

## Reproduction

From the repository root, run:

```powershell
odin test runtime
```

The repository-wide Windows suite is available with:

```powershell
.\tools\test.ps1 -Odin 'C:\path\to\odin.exe'
```

## Verification

An earlier full local Windows suite run with Odin
`C:\Users\saman\Documents\odin\dist\odin.exe` covered 308 runtime tests, 39 UI
tests, 35 theme tests, 168 native SDL tests, 8 AccessKit ABI tests, and 6 scroll
capture tests, plus the foundation, restoration, accessibility-contract, and
text-input smoke checks.

At the initial-scope review, `odin test runtime` passed with 422 tests (421
before the added omission case) using Odin `dev-2026-11-nightly:08539cd`. The
same command with application-mutation diagnostics enabled
(`-debug -define:ALICORN_APP_MUTATION_DIAGNOSTICS=true`) passed with 431 tests;
the additional tests live in the diagnostics fixture.

This report records fixture scope, not a claim that every client invalidation
pattern is verified. Consumer-specific tests remain necessary for application
state and layouts not represented by the fixture.
