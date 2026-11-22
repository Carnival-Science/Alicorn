# Issue #91 motion dogfood: Reveal port, Scratchpad capture, physical Hz, code reduction

Date: 2026-11-22

**Status:** implementation and evidence record. It supplies the dogfood,
physical-refresh, and code-reduction pieces the [#91](https://github.com/Carnival-Science/Alicorn/issues/91)
GO gate and the [#146](https://github.com/Carnival-Science/Alicorn/issues/146)
release matrix still listed as outstanding. It does not close any issue and it
does not substitute for a founder screen recording or a macOS/Linux physical
run.

## Pins and environment

| Item | Value |
| --- | --- |
| Alicorn branch / commit | `finish-91` at `3d49b8b` |
| Alicorn worktree | `finish-91-motion-close-2` |
| Scratchpad port branch | `motion/quick-open-reveal` at `f70d898` (base `adb28fc`) |
| Scratchpad remote | `https://github.com/samanshaiza004/scratchpad.git` |
| Build | Scratchpad clone built against Alicorn `3d49b8b` with `--alicorn-root` and `--allow-alicorn-revision` |
| Odin | `dev-2026-11-nightly:08539cd` |
| Host | `native/sdl_gpu`, SDL 3.4.20, Direct3D 12 on RTX 2080 SUPER (driver 32.0.15.9597) |
| OS | Windows 10 Home, build 19045 |
| Primary display | AORUS CV27Q (GBT2705), 2560x1440, default 165 Hz |
| Secondary display | F22 (SPT08D5), 1920x1080 |

Raw evidence is under
[raw/issue-91-motion-dogfood-2026-11-22](raw/issue-91-motion-dogfood-2026-11-22/manifest.json).
Key frames are committed under
[assets/issue-91](assets/issue-91). The complete capture bundles (including
`screenshot.ppm`, full `timeline.json`, `windows.json`, and `inspector.txt`) are
local, git-ignored artifacts under
`<scratchpad-clone>/out/issue-91/raw/`; the manifest maps every committed excerpt
to its bundle timestamp.

## 1. Quick Open Reveal accent port

### Source and target

The pilot accent lives only in the issue-54 worktree
`C:\Users\saman\dev\scratchpad\out\worktrees\issue-54-installable-themes`
(branch `codex/issue-54-installable-themes` at `eb87f32`). It is **not** in
`quick_open.odin`; it is the decorative `.Accent` bar in the pre-AliKit
`frontends/alicorn/command_palette.odin` query row, declared with
`gui.motion(..., .Reveal, {y=-6})` and re-declared with `Settle` when the shared
motion-policy signature changes. That authoring shape was introduced/refined by
Scratchpad commit `646e02d` ("fix motion cleanup across tab reorder
interruptions"), which is already the parent of the current frontend's
tab-reorder motion.

On the current branch the command palette was rewritten onto the vendored AliKit
package (`4811634`). AliKit's
[UPSTREAM.md](https://github.com/samanshaiza004/scratchpad/blob/codex/issue-211-webgpu-frontend/third_party/alicorn-kit/UPSTREAM.md)
requires any further vendored presentation change to be ported to the private
upstream repository first; this slice does not fork the vendored component.
The Reveal accent is therefore ported to the **frontend-owned Quick Open
palette**, which is the same modal/query surface the acceptance matrix and #60
describe, and keeps the exact authoring contract: one decorative, paint-only
accent; immediate panel/query/focus/semantics; no exit ghost.

### Change

Commit `f70d8985a276d4de1a19695230042910d48b1633` on
`motion/quick-open-reveal`, pushed to `samanshaiza004/scratchpad`:

```text
 frontends/alicorn/main.odin            |   3 +
 frontends/alicorn/quick_open.odin      |  49 ++++++++++++-
 frontends/alicorn/quick_open_test.odin | 128 +++++++++++++++++++++++++++++++++
 3 files changed, 179 insertions(+), 1 deletion(-)
```

- `App` gains the accent node, the one-shot `reveal_pending` flag, and the
  motion-policy signature.
- `quick_open_open_surface` queues exactly one Reveal; `quick_open_close_surface`
  discards it (no tombstone/exit ghost).
- The query row now owns a 2x26 `.Accent` surface. It declares
  `Motion_Target{opacity=1, has_opacity=true, has_translation=true}` with
  `.Reveal` and `{y=-6}` on the first description, then only re-declares when
  `scratchpad_motion_policy_signature` changes. A policy change mid-reveal
  retargets the existing presentation with `Settle`; it never replays the birth
  pose. The same signature helper is shared with the tab-reorder motion.
- Query/path updates do not re-declare, and the accent keeps stable identity and
  bounds.

### Verification

`tools/alicorn.ps1 test -Odin C:\odin\odin.exe --alicorn-root <Alicorn 3d49b8b>
--allow-alicorn-revision`:

| Stage | Result |
| --- | --- |
| Go packages / bridge / lifecycle | Green |
| Odin harness runner | 13 tests, all successful |
| Scratchpad frontend (includes all #60 motion tests) | **259 tests, all successful**, no memory-tracker warnings |

Two new #60-adjacent regressions were added:

- `test_quick_open_reveals_only_its_decoration_once` - normal and reduced
  motion; one `reveals` count; panel/query/focus alive immediately; offset
  `{0,-6}`/opacity 0 while active; reduced motion snaps to target; a query
  rebuild preserves accent identity/bounds and adds no declaration; settlement
  leaves zero active owners; close clears the pending intent.
- `test_quick_open_reduce_motion_change_during_reveal_does_not_replay_birth` -
  a Reduce Motion change during the entrance re-declares Settle, keeps
  `reveals == 1`, lands exactly on target, preserves query focus, and an
  unchanged policy adds no further declaration.

The full log is committed as
[scratchpad-suite-full.txt](raw/issue-91-motion-dogfood-2026-11-22/scratchpad-suite-full.txt).

## 2. G11 - Scratchpad #60 native capture

### Method

The clone was built against this Alicorn root with the SDL_GPU reference host
(`--renderer sdl-gpu` is the default). It ran with an isolated `%APPDATA%` /
`%LOCALAPPDATA%` fixture so the real Scratchpad session and preferences were not
touched; the fixture session restored three documents (`main.odin`, `notes.md`,
`settings.json`) in a temporary workspace. `SCRATCHPAD_ALICORN_WORKSPACE` was
deliberately **not** set because the backend skips session document restore when
a start-workspace override is present.

Each run used:

```powershell
scratchpad-alicorn.exe --diagnostics --capture-after=600 --capture-dir=<bundle-root>
# then real SendInput: Ctrl+P / F12 / Esc / drag, with the window foreground-verified
```

F12 only latches a capture request; the host writes the bundle on the next
presented frame. For settled states the automation toggles debug bounds on for
one forced frame, then off together with the F12 request, so the captured frame
is clean. During active motion, the motion frame itself supplies the
presentation and F12 is sent directly. No app state was changed for the capture
tooling.

### Captures

| Leg | State | Image | Bundle (local) | Timeline rows | Motion-only frames |
| --- | --- | --- | --- | ---: | ---: |
| Quick Open | three connected tabs, settled | [baseline](assets/issue-91/quick-open-baseline.png) | `quick-open/20261122T182332.287Z-0001` | 7 | 0 |
| Quick Open | palette open, accent Reveal in flight | [reveal-mid](assets/issue-91/quick-open-reveal-mid.png) | `quick-open/20261122T182333.074Z-0002` | 17 | **3** |
| Quick Open | palette open, accent settled | [reveal-settled](assets/issue-91/quick-open-reveal-settled.png) | `quick-open/20261122T182334.319Z-0003` | 45 | 26 |
| Quick Open | palette closed, no ghost | [closed](assets/issue-91/quick-open-closed.png) | `quick-open/20261122T182335.450Z-0004` | 52 | 27 |
| Tabs | three connected tabs, settled | [baseline](assets/issue-91/tabs-baseline.png) | `tabs/20261122T182456.876Z-0001` | 7 | 0 |
| Tabs | live reorder drag, neighbours displaced | [reorder-mid](assets/issue-91/tabs-reorder-mid.png) | `tabs/20261122T182458.073Z-0002` | 28 | **11** |
| Tabs | reordered after drop, settled | [reorder-settled](assets/issue-91/tabs-reorder-settled.png) | `tabs/20261122T182459.290Z-0003` | 49 | 26 |
| Inspector | Motion tab, accent record during the entrance | [inspector-reveal](assets/issue-91/inspector-motion-reveal.png) | `inspector/20261122T182521.955Z-0002` | 47 | - |
| Inspector | Motion tab, settled counters and idle scheduler | [inspector-settled](assets/issue-91/inspector-motion-settled.png) | `inspector/20261122T182524.005Z-0003` | 58 | - |

Tab selection itself remains immediate by design - the #60 record removed the
selection-indicator animation - so the captured tab motion is the ported live
reorder, which is the motion this dogfood actually ships. The drag exercised
that path: `main.odin` (the active tab) was dragged right past `notes.md`; the
mid capture shows the neighbours carrying their presentation-only offsets, and
the settled capture shows the committed order `notes.md, main.odin,
settings.json`. Unlike the 2026-11-21 #120 attempt, scripted real `SendInput`
reached this window reliably once the foreground was verified; the earlier
failure was not reproduced.

### Motion-sample rows

The timeline exports per-turn work counters. Motion-only frames are samples with
`activity_class = "present"`, `app_builds = 0`, `descriptions_emitted = 0`,
`reconcile_visits = 0`, `layout_visits = 0`, `presentation_updates = 1`, and
`composition_visits > 0`. Extracted rows are in:

- [timeline-reveal-mid.json](raw/issue-91-motion-dogfood-2026-11-22/quick-open/timeline-reveal-mid.json)
- [timeline-closed.json](raw/issue-91-motion-dogfood-2026-11-22/quick-open/timeline-closed.json)
- [timeline-reorder-mid.json](raw/issue-91-motion-dogfood-2026-11-22/tabs/timeline-reorder-mid.json)
- [timeline-reorder-settled.json](raw/issue-91-motion-dogfood-2026-11-22/tabs/timeline-reorder-settled.json)

Representative rows from the reorder-mid excerpt (values are per host turn):

| sample | class | app builds | description | reconcile | layout | paint | compose | presentation | GPU submit |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 21 | present | 0 | 0 | 0 | 0 | 0 | 67 | 1 | 1 |
| 22 | present | 0 | 0 | 0 | 0 | 0 | 67 | 1 | 1 |
| 23 | present | 0 | 0 | 0 | 0 | 0 | 67 | 1 | 1 |
| 24 | present | 0 | 0 | 0 | 0 | 0 | 67 | 1 | 1 |

The reveal-mid excerpt carries three such frames with `composition_visits = 85`
and zero application description/reconcile/layout work. The closed capture's
inspector transition and the settled inspector counters record the owner
retiring and the scheduler going idle. The diagnostic bundles add the native
scheduler counters:

| Bundle | motion samples | timer wakes | max owners | missed intervals | max lateness |
| --- | ---: | ---: | ---: | ---: | ---: |
| reveal-mid | 4 | 4 | 1 | 0 | 15.0 ms |
| reveal-settled | 28 | 28 | 1 | 2 | 47.2 ms |
| reorder-mid | 7 | 7 | 1 | 0 | 1.3 ms |
| reorder-settled | 22 | 23 | 1 | 2 | 37.5 ms |
| inspector reveal | 30 | 30 | 1 | 1 | 16.7 ms |
| inspector settled | 30 | 30 | 1 | 1 | 16.7 ms |

The larger maxima are single stalls during startup/forced captures, not
steady-state samples; they are retained rather than filtered.

### Inspector evidence

The Motion tab shows the accent's passive record: `Intent: Reveal`, declaration
`alicorn/quick_open.odin:366:15`, owner generation 1, target `(0,0)`/opacity 1,
presented values, the position/velocity tolerances, and `Target_Static` hit
policy ("paint translation does not move hit regions"). The settled capture adds
aggregate scheduler evidence:

```text
Motion ticks=33 owner visits=33
Property samples=65
Presentation requests=34 coalesced=5
Acknowledged app submissions=31
Native samples=30 timer wakes=30 restores=0 snaps=0
Sampling total=0.193 ms max=0.012 ms
Max scheduler lateness=16.678 ms
Native presentation scheduler: idle (no next deadline)
Retarget=0 no-op=0 mode=0
Reveal=1 reduced-motion=0
Release=0 retired=1 settled=2
Recent transition #5 ... Owner_Retired ... intent=Reveal ... source=alicorn/quick_open.odin:349:39
```

This is the same idle/retirement proof the matrix cites for the core, now on the
ported surface.

### Honest scope: what is captured, what remains hands-on

Captured automatically and committed here:

- real native frames of tab reorder in flight and settled, with logical tab
  geometry and close affordances unchanged in the model;
- real native frames of Quick Open's birth Reveal (accent at full settled
  position in the settled frame) and a mid-reveal frame with motion frames in
  the timeline;
- the inspector's Reveal record and settled idle scheduler state;
- per-frame stage rows proving motion-only composition in the same turns.

**Not** captured automatically:

- a smooth screen recording that a human can judge for feel, tearing, or
  visible cadence. The host writes single-frame bundles plus timeline rows, not
  video. A founder should still record Shortcut/Ctrl+P open, Esc close, a
  rapid reorder reversal, and a Reduce Motion flip at the OS level on the exact
  release build.
- macOS and Linux physical motion. The matrix keeps those at CI tier.

The founder steps in the matrix remain valid; the Scratchpad commit to record
for them is `f70d898` (or the merge commit on the release branch).

## 3. G10 - physical refresh-rate capture

### Supported rates

The primary panel advertises these 2560x1440 modes:
[59, 60, 120, 144, 165] Hz
([supported-modes-primary.txt](raw/issue-91-motion-dogfood-2026-11-22/hz/supported-modes-primary.txt)).
The default desktop is 165 Hz. Requesting 60 Hz is applied by Windows as 59 Hz
(59.94); the observed rate is recorded below rather than rounded.

### Measured

Runbook: set the primary display mode, run the motion-instrumented native
example (`examples/09_retained_motion --motion-validation --diagnostics
--capture-after=1`) once per rate, then restore the original mode. Each run is a
bounded ~3 s sequence with two interruptions, settlement, and an idle
checkpoint; it is not a steady-state benchmark. Raw per-rate logs are committed.

| Requested | Observed | Run | Motion samples | Missed intervals | p50 lateness | p95 | p99 | Max | Submissions |
| ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 60 | 59 | PASS | 48 | 3 | 0.607 ms | 12.706 ms | 29.956 ms | 45.512 ms | 50 |
| 120 | 120 | PASS | 49 | 12 | 0.756 ms | 1.334 ms | 114.056 ms | 114.158 ms | 50 |
| 144 | 144 | PASS | 49 | 7 | 1.310 ms | 1.348 ms | 50.832 ms | 75.447 ms | 50 |
| 165 | 165 | PASS | 49 | 5 | 0.944 ms | 1.622 ms | 41.049 ms | 55.033 ms | 51 |

All four legs exit 0 with `SDL application PASS`, a D3D12 swapchain, and the
same motion sequence. The original 165 Hz desktop mode was restored and verified
after the run.

### Interpretation and limits

- These are scheduler deadline-to-sample **lateness** values, not compositor
  present timestamps, input-to-photon latency, or a vsync claim. The issue's D1
  rejection (predicted-present timestamps) still applies.
- The 120/144/165 p99/max values are dominated by one startup/mode-change stall
  in a 3 s run; p50/p95 are in the same sub-2 ms band as the earlier
  Windows/D3D12 records. The 60 Hz leg's p95 is elevated for the same reason.
- This machine supports and measured 60/120/144/165 Hz. The matrix's "120/144
  remain founder-scoped on appropriate hardware" caveat is therefore discharged
  **for this panel and this run**; other panels, macOS, and Linux remain
  platform follow-ups.
- No cadence claim is made for hidden/minimized windows; that behavior is
  covered analytically and by the earlier native records.

## 4. Dogfood code reduction

### Measure

Bounded authoring-cost estimate, not a benchmark. The motion-API side is the
ported production code in Scratchpad commit `f70d898`; the manual side is a
single illustrative implementation of the same presented values in
[manual_motion_twin.odin.txt](raw/issue-91-motion-dogfood-2026-11-22/manual-twin/manual_motion_twin.odin.txt)
(not compiled, not wired into the app). Lines are physical production lines,
excluding blanks and comment-only lines; tests are excluded on both sides.

| Piece | Motion API | Manual twin |
| --- | ---: | ---: |
| Quick Open Reveal accent (state, open/close, accent + declaration) | 38 | - |
| Tab reorder (state, motion mechanics, build call site) | 51 | - |
| Full manual kernel + accent + tab motion + teardown | - | 208 |
| **Total** | **89** | **208** |

Ratio: **2.34x** more app code for the manual twin. The twin owns the monotonic
clock, critically damped evaluation with stalled-turn substeps, generation and
retirement checks, retarget-without-replay, reduced-motion snap, per-frame
presentation requests, tab identity reuse, drop/cancel cleanup, and re-describing
the accent row each frame because there is no paint-only overlay API outside
motion.

Caveats:

- Another author could write the twin longer or shorter; the ratio is evidence
  for the #91 "removes repeated app code" gate, not a universal constant.
- The motion path's 89 lines reuse the pre-existing
  `scratchpad_motion_policy_signature` helper and the pre-existing drag gesture;
  only the motion mechanics are counted.
- The manual twin would rebuild the description every frame for the accent; the
  motion API does not. That difference is behavioral as well as linear, and is
  not converted into a performance claim here.

## 5. Per-child closure recommendations

These are recommendations for the parent session; this record does not change any
issue state.

### #138 - generation-safe retained records and typed property targeting

**Recommend: accept node-scoped typed slots as v0.3 core; defer visual-part
identity, alpha animation, and gradients.** The boundary is already recorded in
[issue-138-motion-ownership.md](../research/issue-138-motion-ownership.md)
("Remaining boundary"): motion stays node-owned with fixed typed slots for
translation, opacity, and semantic-surface fill; a general visual-part/property
key, moving hit geometry, alpha animation, gradient-stop targeting, and
renderer-specific effects are not implemented. Nothing in this run changes that
boundary; the port used only the existing translation/opacity slots and the
documented static interaction policy.

### #140 - per-window demand-driven presentation scheduling

**Recommend: close at the implemented scope; predicted-present timestamps are
rejected (D1), and the macOS sampled-animation limitation is a platform note,
not an implementation gap.** The host samples against a monotonic source, not a
compositor present timestamp; the matrix records D1. The macOS/Metal CI leg
proves host/scheduler/settlement wiring but recorded zero samples because the
window was not sampled on that leg; that remains a platform evidence limit, not
a reason to add an untrustworthy prediction API. This run supplies 60/120/144/165
Hz physical scheduler samples on Windows/D3D12.

### #141 - tiny intent-based authoring, theme policies, reduced motion

**Recommend: close the dogfood half with this record.** The Quick Open Reveal
port uses the intended authoring shape (`target + intent` during describe,
one declaration per policy/birth, policy re-declare instead of replay, reduced
motion snap, no app-owned handle/clock), and the measured 2.34x code ratio is the
authoring evidence the GO gate asked for. Tab reorder continues to share the
same policy signature. The existing runtime/UI tests plus the two new
Scratchpad tests cover the mid-flight policy and close behavior.

### #146 - release gate

**Recommend: keep #146 open only for founder-hands-on acceptance.** The core
matrix, G6, and G9 (CI tier) are unchanged. After this slice:

- **G10** is measured on the founder's Windows/D3D12 panel at 60 (reported 59),
  120, 144, and 165 Hz, with all runs passing and the original mode restored.
- **G11** has native captures for tab reorder and Quick Open Reveal, plus
  timeline motion-only rows and Motion-tab inspector evidence. A founder screen
  recording (feel/tearing/reverse/escape/OS Reduce Motion) and macOS/Linux
  physical runs still remain, exactly as the matrix's founder-scoped note
  anticipated.
- No core invariant failed in this slice.

### #91 - GO gate

**Recommend: GO for the public v0.3 motion surface.** The previously unmeasured
piece - a real dogfood code-reduction comparison - is now 89 motion-API lines
versus 208 manual-twin lines (2.34x) for the same two presented-value features,
with ownership, interruption, retirement, focus, and idle behavior covered by
the existing core tests and the new Scratchpad regressions. The deferred pieces
(visual-part identity/alpha/gradients, predicted timestamps, FLIP, ghosts,
QoS) remain deferred per the recorded boundaries above.

## 6. Checks run in this worktree

| Check | Result |
| --- | --- |
| `odin test runtime` | 511 tests, all successful |
| `odin test native\sdl_gpu` (with staged SDL3.dll) | 172 tests, all successful |
| Scratchpad `tools/alicorn.ps1 test` (Alicorn `3d49b8b`) | 13 + 259 tests, all successful, exit 0 |
| Scratchpad build against Alicorn `3d49b8b` | exit 0, D3D12 native runs PASS |
| Scratchpad branch push | `f70d898` on `samanshaiza004/scratchpad` |

Logs: [runtime](raw/issue-91-motion-dogfood-2026-11-22/alicorn-runtime-tests.txt),
[native](raw/issue-91-motion-dogfood-2026-11-22/alicorn-native-sdl-gpu-tests.txt),
[Scratchpad](raw/issue-91-motion-dogfood-2026-11-22/scratchpad-suite-full.txt).

## 7. Limits

- One Windows 10 / D3D12 machine with one GPU and one panel family. macOS and
  Linux were not run physically.
- Captures are single frames plus bounded timeline rows, not video; motion feel
  and visible cadence still need founder hands.
- G10 is scheduler lateness sampling, not compositor present timing or
  input-to-photon latency; the 3 s legs include startup stalls.
- The code-reduction number is an authoring estimate with an uncompiled twin,
  not a benchmark.
- The Scratchpad clone is a fresh clone; the generic theme files regenerated by
  the build were reverted and are not part of the commit.
