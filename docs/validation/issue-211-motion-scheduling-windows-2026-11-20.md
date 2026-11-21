# Issue #211 Stage C slice 5: retained motion scheduling on the hosted WebGPU path

Date: 2026-11-20. Machine: Windows 11 x64, NVIDIA GeForce RTX 2080 SUPER
(32.0.15.9597), 100% DPI. Alicorn `codex/issue-211-scratchpad-webgpu` at
`36bf76d` plus this slice; Scratchpad `codex/issue-211-webgpu-frontend` at
`b458d6e` (read-only, candidate root this worktree, no Scratchpad source or lock
change).

Founder acceptance for the slice: **"Motion scheduling - no frozen animations or
unnecessary idle rendering."**

## 1. Reference scheduling, as implemented

`native/sdl_gpu/scheduling.odin` gives every window one
`Native_Motion_Scheduler_State`:

- `native_motion_scheduler_prepare(state, active_owners, renderable, now)`
  consumes a due demand **exactly once**. The first active turn arms
  `now + NATIVE_MOTION_SAMPLE_INTERVAL_NS` (16_666_667). A later turn samples
  only when `now >= next_deadline`, and the missed-interval count is derived from
  lateness rather than replaying poses.
- A hidden/minimized/occluded window drops its deadline, records
  `Host_Suspended`, and keeps `suspended_since_ns`; restoring returns one
  immediate sample (`restore_samples`) and reports `Hidden_Gap_Fast_Forward`.
- When due, `native_motion_scheduler_advance` calls `motion_tick(at)` once,
  applies `motion_snap_unestablished` after the 5 s uncertified limit, and
  `native_motion_scheduler_finish_sample` re-arms `now + 16.67 ms` while owners
  remain.
- `native_motion_scheduler_next_deadline` feeds the event wait
  (`Primary_Motion` / `Child_Motion`); the loop waits for the earliest deadline
  across windows.
- A turn that is **not** due still calls
  `native_motion_clock_set_current_time(rt)` before every description
  (`native_application_build_until_stable`), so `ui.motion` targets resolve
  against the current time without sampling. After the retained-paint flush a
  second `native_motion_scheduler_prepare` arms the first deadline for a hover
  transition that started during that flush.
- The Windows event wait adds 1 ms of slack
  (`native_event_wait_windows_timeout_ms`) because SDL truncates a remaining
  nanosecond timeout to milliseconds and would otherwise return immediately for
  the final fraction of every interval.

## 2. What the hosted runtime actually did

`runtime/hosted.odin` called `motion_tick(now)` on **every** step. Animation did
not freeze when the description was stable - a fixture response presented 40
frames without a single re-description - but the sampling rate equalled the host
loop rate rather than the display cadence. Runtime-seam probe, one settle
response stepped every 1 ms for 250 steps:

```text
before: storm-paced frames: 200 over 400 ms   active true   descriptor delta 0
after:  storm-paced frames:  23 over 400 ms   active false  descriptor delta 0
```

Every one of those frames is a surface acquire, encode, submit and present.

The second half was a pre-existing hosted loop defect that a fixed deadline
exposes: `host/sdl3/run.odin` used `ceil((next_wake-now)/1 ms)` and called
`SDL_WaitEventTimeout` directly. SDL3's Windows backend truncates the remaining
timeout to milliseconds, so a sub-millisecond remainder becomes a
zero-millisecond wait. The `settled` workload scenario - a single frame and then
1.2 s idle - re-entered the hosted loop 525-1138 times; the reference host waits
once.

## 3. Changes

`runtime/hosted.odin`:

- `Hosted_Runtime_State.motion_deadline_ns` is the surface motion deadline.
- `hosted_motion_sample_due` gates sampling: no active owner clears the
  deadline; an unarmed deadline samples (first response or restore); otherwise
  only `now >= deadline`.
- A non-sampling step calls `motion_clock_set_time(now, .Native_Monotonic)`,
  mirroring the reference host's pre-description clock update: `ui.motion`
  intents still resolve at the current time, but nothing is sampled or queued.
- A sample re-arms `now + HOSTED_MOTION_SAMPLE_INTERVAL_NS` while owners remain
  active and clears the deadline when the response settles.
- `hosted_motion_deadline` arms the first deadline for a response started by the
  same step's description or retained-paint flush; `hosted_runtime_next_deadline`
  publishes it. A hidden surface drops the deadline
  (`hosted_runtime_advance_presentation` early return) so restore samples once at
  the current time. `hosted_runtime_live_step` uses the same deadline.

`host/sdl3/run.odin`:

- `sdl3_webgpu_run_wait_timeout_ms` adds 1 ms to a positive wait timeout on
  Windows, mirroring the reference host's guard.

`benchmarks/workload_matrix/main.odin`:

- The fixture did not compile against the current API (`ui.run(&app, render,
  title=...)` mixes positional and named arguments; `ui.run_webgpu` does not
  exist). It now calls `ui.run` / `ui/webgpu.run` with named arguments. This was
  required to produce the real-window numbers below and repairs
  `tools/bench_webgpu_vs_sdlgpu.ps1 -Matrix`.

`runtime/hosted_motion_test.odin` (new, six tests): cadence-to-settlement without
description changes plus a one-second idle assertion, 1 ms host-turn storm
cadence, hidden/restore deadline, tick-only surface presents nothing,
two-session independence, and live-step cadence without ticks.

## 4. Measurements

### Runtime seam

| Assertion | Before | After |
| --- | ---: | ---: |
| Frames for one settle response, deadline-paced | 40 | 40 |
| Frames for the same response with 1 ms host turns (400 ms) | 200 | 23 |
| Frames after settlement over 1 s of host turns | 0 | 0 |
| Descriptions during a motion-only response | 0 | 0 |

### Matched real-window matrix (`benchmarks/workload_matrix`)

Command per cell (one `ui.motion` reveal; no driver frames):

```powershell
.\out\workload_matrix_after.exe --workload=<scenario> --frames=1 --smoke `
  --smoke-hold-ms=1200 --timings --backend=<d3d12|vulkan|sdl-gpu>
```

`frames_presented`, `steps` (host-loop turns) and
`idle_after_last_present_ns` from `[alicorn-webgpu-workload]`; the `sdl-gpu` leg
reports `primary_gpu_submissions`. `before` is the same binary built from
`36bf76d` without this slice's runtime/host changes.

| Scenario | Reference (SDL_GPU) | Hosted before | Hosted after |
| --- | ---: | ---: | ---: |
| `transform` D3D12 | 36 submits, `motion_samples=35` | 40 frames, 784 steps | **37 frames, 93-103 steps** |
| `transform` Vulkan | - | 43 (matrix record, 2026-11-19) | **37 frames, 90 steps** |
| `multiwindow` D3D12 | 29 submits, `motion_samples=27` | 36 frames, 671 steps | **36 frames, 94 steps** |
| `multiwindow` Vulkan | - | 67 (matrix record, 2026-11-19) | **35 frames, 93 steps** |
| `settled` D3D12 | 1 submit, `motion_samples=0` | 1 frame, 525 / 912 / 1138 steps | **1 frame, 7 steps** |
| `settled` Vulkan | - | 1 frame | **1 frame, 7 steps** |

Idle observation window was 1200 ms in every hosted cell and every cell reported
`idle_after_last_present_ns` at or above 1200 ms with no further frame. The
`transform` and `multiwindow` scenarios each describe **once** per window, so
every frame after that is presentation-only.

The pre-fix `multiwindow` overshoot recorded on 2026-11-19 (94 D3D12 / 67
Vulkan) did not reproduce on this machine at `36bf76d` (36 / 36); the numbers
above are what this build produces, not a claim about the earlier record.

### Wait-granularity A/B (same binary)

A temporary probe build (not committed) enabled/disabled only the 1 ms slack at
runtime:

| Scenario | slack | no slack |
| --- | ---: | ---: |
| `transform` D3D12 | 99 steps, 37 frames | 5256 steps, 38 frames |
| `settled` D3D12 | 7 steps, 1 frame | 642 steps, 1 frame |

This isolates the SDL Windows truncation from the motion gating: without slack
the loop spins for the last fraction of each wait (worst with a fixed deadline).
With slack, loop turns are one per presented frame plus the bounded 250 ms
device-loss observation poll.

## 5. Validation

Suites (run individually with the pinned AccessKit collections, as in the
previous slices because `tools/test.ps1` stops in the AccessKit binding check on
this machine):

| Suite | Result |
| --- | ---: |
| runtime | 418/418 (6 new hosted motion tests) |
| host/fonts | 5/5 |
| host/sdl3 | 7/7 |
| host/sdl3/live_resize | 9/9 |
| host/sdl3/input | 8/8 |
| host/sdl3/clipboard | 3/3 |
| host/sdl3/dialogs | 5/5 |
| host/menus | 8/8 |
| host/web | 14/14 |
| host/diagnostics | 9/9 |
| host/presentation | 7/7 |
| renderer/webgpu | 8/8 |
| renderer/cpu | 23/23 |
| ui | 50/50 |
| testui | 13/13 |
| theme | 37/37 |
| native/sdl_gpu | 166/166 |
| native/scroll_capture_tests | 6/6 |
| tests/fixtures/accessibility_contract | 1/1 |
| `odin build tests` + `out/alicorn_tests.exe` | PASS |

`examples/16_native_webgpu_ui` (`-define:WGPU_SHARED=true`) passes all seven
smokes - `--smoke`, `--workbench-smoke`, `--titlebar-smoke`,
`--child-chrome-smoke`, `--menu-smoke`, `--services-smoke`, `--tab-drag-smoke` -
on `--backend=d3d12`, `--backend=vulkan` and `--backend=sdl-gpu` (21/21, exit 0).

Scratchpad (`b458d6e`, built with `--alicorn-root` this worktree and
`--allow-alicorn-revision`):

| Leg | clean | recovery |
| --- | --- | --- |
| `smoke --renderer=webgpu --backend=d3d12` | pass | pass |
| `smoke --renderer=webgpu --backend=vulkan` | pass | pass |
| `smoke --renderer=sdl-gpu` | pass | pass |

Every leg reported `publication_rendered`, `wake_observed`, `ordered_shutdown`
and `session_restore` true. No Scratchpad source or lock file was changed.

## 6. C4 describe-turn residual

**Status: not closed; scheduled.** The C4 record's JSON-scene status cue is not
a motion-scheduling artifact. From the C4 trace both hosts run the same
three-pass startup turn and the same one-pass follow-up; the reference then takes
one more host turn whose description finds the caret anchor. That turn cannot be
a stabilization pass, because hosted runs an application invalidation inside the
same step (`hosted_root_describe`); it is a host turn the application did not
request. The traced cause is an application-state read: the status strip is
described before the virtual list realizes the caret row, so the first pass of a
turn reads the previous pass's `editor_input_anchor_node`.

Two candidate fixes, both outside motion scheduling:

1. Scratchpad realizes the caret row (or defers the status strip) before reading
   `editor_input_anchor_node`, or invalidates once when the anchor is newly
   resolved.
2. A future host slice identifies which reference invalidation source produces
   that extra turn. The leading candidate is the startup pixel-resize event:
   `native/sdl_gpu` applies it after its first description and invalidates the
   content viewport, while the hosted host adopts the same metrics before its
   first step.

## 7. Hands-on items

- Founder hover/scroll in Scratchpad on both hosted backends: a hover
  transition should animate and then stop; an idle window must show no activity
  in the F10 HUD.
- Founder tab reorder / Quick Open / command palette animation on the hosted
  build: the slice's fix is that these respond at the display cadence (and not
  faster), and a 1 ms input storm must not speed them up.
- This automation session cannot deliver synthetic pointer motion to a real
  window (recorded in earlier slices), so animated retained motion is verified at
  the runtime seam plus the real-window workload matrix, not by a scripted drag
  inside Scratchpad.
