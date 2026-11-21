# Hosted-WebGPU live resize and window movement parity

Windows x64, NVIDIA GeForce RTX 2080 SUPER, Windows 10 22H2, 2026-11-20
Alicorn `codex/issue-211-scratchpad-webgpu` (Stage C slice 1), Scratchpad
`codex/issue-211-webgpu-frontend` @ `b458d6e` (read-only validator worktree)

## Symptom and mechanism

Founder evidence: on the hosted WebGPU build a window resize only landed on mouse
release; during the drag the window showed the pre-drag frame stretched into the
new size. The SDL_GPU reference resized live and continuously.

The reference host never depended on queued `WINDOW_RESIZED` events for this.
Inside the platform modal loop it had two entry points:

1. an SDL event watch on `WINDOW_EXPOSED` (`data1 == 1`) that redraws directly
   from the watcher callback (SDL documents this one event as safe to redraw
   from a watcher, on the main thread); and
2. on Windows, a `SetWindowsMessageHook` that tracks `WM_ENTERSIZEMOVE` /
   `WM_EXITSIZEMOVE` and installs one 17 ms `SetTimer` on the moving HWND, so
   the host gets a display-like cadence while the pointer is held even though
   `SDL_PollEvent`/`SDL_WaitEvent` never returns.

Both are re-entrant with respect to the host's own frame path: a `Present` can
pump messages, so an exposure or timer tick that arrives mid-frame is coalesced
(bounded two-pass loop) or dropped (timer guard), never nested.

The hosted host had none of this: its loop blocks in `SDL_WaitEventTimeout` for
the whole drag, so nothing rebuilt layout or configured the surface until
release.

## Change

The mechanism moved into the shared SDL3 host layer as
`host/sdl3/live_resize` (package `sdl3_live_resize`): event watch, Windows
message hook, per-HWND move timer, per-window slot state, re-entrancy guards, and
counters. Renderers implement `Ops{window, renderable, has_work, render}`.

- `host/sdl3` installs the core for the primary window and the optional
  secondary window (`host/sdl3/live_resize_host.odin`). A live frame re-reads
  logical and pixel geometry, reconfigures the surface, then runs
  `hosted_runtime_live_step` (new in `runtime/hosted.odin`) and presents through
  the shared presenter. `hosted_runtime_live_step` advances retained motion and
  rebuilds an invalidated description but does not dispatch `on_tick` or
  application-scheduled wakes.
- `native/sdl_gpu` now consumes the same core. `window_move_windows.odin` is an
  adapter (slot policy + reference frame), the host's event watch and message
  hook are deleted, and its live-resize telemetry reads the shared counters.

## Evidence 1: hosted fixture, before and after

Harness: `tools/validate_native_webgpu_resize.ps1` drives
`examples/16_native_webgpu_ui --titlebar-smoke --live-resize-smoke --interactive
--test-live-resize-trace` through real `SendInput` drags: a caption-band move
drag (+100, +50, 24 steps at 25 ms) and a right-edge resize drag (+140 px, same
cadence). A dedicated reader thread timestamps every `live_resize_frame` line the
host traces and samples the live client rectangle at receipt.

Before the fix (hosted D3D12, no live dispatch):

```text
resize presentations happen mid-drag   FAIL  frames=0 pixel_widths=
drawable tracks the live window size   FAIL  client_before=1100 max_frame_pixel_width=0 client_after=1240
fixture-side live layout accounting     FAIL  frames 8 size_changes 3 distinct_widths 3
```

After the fix, D3D12 (79 mid-drag frames, monotonic pixel widths):

```text
mid-drag pixel widths  1105,1111,1117,1123,1129,1135,1140,1146,1152,1158,1164,
                       1170,1175,1181,1187,1193,1199,1205,1210,1216,1222,1228,
                       1234,1240
aspect                 drawable=1240x700 live_client=1240x700 aspect_delta=0.00% width_delta=0
fixture accounting     frames 31 size_changes 26 distinct_widths 26 min 736 max 1240
host telemetry         frames 104 expose_events 118 expose_frames 77
                       move_enter_messages 2 move_exit_messages 2 move_timer_wakes 27
                       move_redraws 27 deferred_exposes 0 deferred_timer_ticks 0
```

Vulkan is equivalent (78 mid-drag frames, 118 exposures, 27 timer wakes, 0.00 %
aspect delta). Caption-drag frames: 24 on both backends, i.e. the retained motion
probe kept animating through the modal move loop.

Reference comparison, same harness and fixture on `--backend=sdl-gpu`:

```text
fixture accounting  frames 30 size_changes 26 distinct_widths 26
reference counters  live_resize_expose_events 120  windows_move_redraws 26
```

The reference has no per-frame trace seam, so the harness checks its shutdown
counters and the shared fixture accounting; the hostile case (zero mid-drag
frames) is exactly what the hosted run showed before this slice.

## Evidence 2: real Scratchpad, scripted drag

Built with `ALICORN_CANDIDATE_ROOT` at this branch and
`--allow-alicorn-revision`, then driven with the same harness in
`-Mode application` (no fixture chrome, real application window):

```text
backend  resize frames  pixel widths                                  aspect
d3d12    24             1105..1240 (24 distinct)                     0.00%
vulkan   24             1105..1240 (24 distinct)                     0.00%
sdl-gpu  -              (reference counters: expose 120, move 0)      -
```

Both hosted backends reported `move_enter_messages 2`, `move_timer_wakes 24`,
`geometry_adoptions 24`, `step_failures 0`, and 24 frames during the caption
move drag. The reference run is frame-identical to its pre-slice behaviour
(exposure-driven redraw; Scratchpad keeps no retained motion, so its modal timer
correctly does not start).

Scratchpad smoke (`go run ./cmd/alicorn-dev smoke --allow-alicorn-revision`),
both legs (`clean`, `recovery`), `publication_rendered/wake_observed/
ordered_shutdown/session_restore` all true:

- `--renderer=webgpu --backend=d3d12`
- `--renderer=webgpu --backend=vulkan`
- `--renderer=sdl-gpu` (reference)

## Evidence 3: suites

All run on this branch (pinned AccessKit arguments, Windows x64):

| suite | result |
| --- | --- |
| runtime | pass |
| host/sdl3 | pass |
| host/sdl3/live_resize (new, 9 tests) | pass |
| host/sdl3/input, clipboard, dialogs | pass |
| host/menus, host/web, host/diagnostics, host/presentation | pass |
| renderer/webgpu, renderer/cpu | pass |
| ui, testui, theme | pass |
| native/sdl_gpu (169 tests) | pass |
| native/scroll_capture_tests | pass |
| `odin build tests` + `out/alicorn_tests.exe` | pass |
| accessibility contract fixture (build + test) | pass |
| examples (all) | build |

`examples/16_native_webgpu_ui` passed `--smoke`, `--workbench-smoke`,
`--titlebar-smoke`, `--child-chrome-smoke`, `--menu-smoke`, `--services-smoke` on
`--backend=d3d12`, `--backend=vulkan`, and `--backend=sdl-gpu` (18/18 exit 0),
and `--test-diagnostics-sequence --diagnostics` on D3D12 wrote three
five-artifact bundles.

## Hands-on items left for the founder

1. Drag-resize and drag-move the Scratchpad hosted window on the real desktop
   and confirm the drag feels like the SDL_GPU build (no stretched last frame,
   animation continues).
2. A live drag across a mixed-DPI monitor boundary (`WM_DPICHANGED` mid-drag).
   The live path re-reads logical and pixel metrics together on every frame, but
   no scripted multi-monitor arrangement is available here.
3. Snap Layouts hover, theme/contrast switches, and trackpad inertia remain
   OS-owned interactions; their message-path survival is covered, the feel is
   not.

## Follow-up: presentation latency (Stage D slice 5)

This record answers "does a frame land during the drag"; it does not say how
quickly one lands after each size change. Stage D slice 5 measured that interval
and found up to ~16 ms of compositor wait on the hosted path before a new size
was presented, then added an opt-in message-driven geometry dispatch for the
hosted host. The per-metric tables, raw CSVs, and the 2.6 ms post-fix result are
in
[live-resize presentation latency](issue-211-live-resize-performance-windows-2026-11-20.md).
The assertions in this document are unchanged and still pass.
