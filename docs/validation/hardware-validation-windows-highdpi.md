# Windows high-DPI validation — operator runbook

Short, by-hand runbook for this machine (Windows 10 22H2, RTX 2080 SUPER).
Goal: prove that per-monitor scale changes and dragging a window between
monitors of different scale do not rebuild retained geometry, and that the
WebGPU host keeps presenting through the transition.

The automated half of this check is
`tools/validate_native_webgpu_dpi.ps1` (Stage C slice 6). It posts synthetic
`WM_DPICHANGED`/`WM_DISPLAYCHANGE` messages, adopts the metric shape of
1.0/1.25/1.5/1.75 transitions at the same logical size, captures text, and
checks logical bounds, hit testing, and per-window scales. Run it first; the
physical passes below are what it cannot cover.

```powershell
.\tools\validate_native_webgpu_dpi.ps1 -Odin C:\odin\odin.exe
```

If both monitors are at 100% (the current state of this machine), set different
scales in **Settings → System → Display** before the physical passes. The
expanded founder checklist is in `docs/webgpu-migration.md` (Stage C slice 6):
mid-drag DPI change, per-monitor scale, text sharpness, chrome band metrics, and
hit-test validity after landing.

## Prepare

Build the native WebGPU example (stages `SDL3.dll` and the shared
`wgpu_native.dll`):

```powershell
.\tools\build_examples.ps1 -Odin C:\odin\odin.exe
```

Confirm both monitors and their scales in **Settings → System → Display**
(e.g. monitor A = 100%, monitor B = 150%). Note which is primary.

Open a PowerShell window and use:

```powershell
.\out\examples\16_native_webgpu_ui.exe --timing-motion --timings
```

`--timing-motion` runs a retained motion probe; `--timings` prints cumulative
`[alicorn-webgpu-workload]` counters and `[alicorn-webgpu-timing]` CPU-wall
percentiles once, at exit. Keep the log (`Tee-Object` or copy from the console).

## Three passes

Run each pass with the window at a comparable size (~720×480), let it settle,
then close it with the window close button so the counters print.

1. **Baseline on monitor A.** Start on A, do not move the window, wait ~5 s,
   close. Save the workload lines.
2. **Baseline on monitor B.** Start on B (different scale), same wait, close.
   Save the workload lines.
3. **Transition.** Start on A with motion running, drag the window to B
   mid-motion, leave it ~2 s, drag back to A, resize once, and close.

Optional: while pass 3 is running, change the display scale in Settings
(100% ↔ 150%) or toggle "Make text bigger", then drag again.

## What to look at

The counters are cumulative, so compare pass 1 and pass 2 totals first, then
look at what changed in pass 3:

- `solid_mesh_rebuilds`, `text_mesh_rebuilds`, `icon_mesh_rebuilds`,
  `image_mesh_rebuilds` — must **not** increase merely because the window
  changed monitor/scale. No full rebuild on a pure scale change.
- `solid_viewport_uploads`, `text_viewport_uploads` — these may increase per
  transition; they are the expected transform/viewport update.
- `solid_vertex_uploads`, `text_vertex_uploads`, `atlas_uploads` — should stay
  flat unless content actually changed.
- `frames_presented` keeps increasing through and after each transition.
- `[alicorn-webgpu-timing]` p95/p99 should stay in the same order of magnitude
  as the baselines; a one-frame spike during a drag is acceptable.

Also watch the window itself: text and controls stay the same logical size when
the DPI changes, hit targets track content, no blank/black frames, no assertion
or validation error in the console.

## Coordinate reminder

Three quantities differ and all matter:

- **SDL window coordinates** are logical (DIP) units; pointer/hit testing uses
  these.
- **Framebuffer pixels** are the configured surface width/height; the renderer
  and `viewport` use these.
- **Display scale** is framebuffer pixels ÷ logical size for the monitor the
  window is on (1.0, 1.25, 1.5, …).

A scale change should update the framebuffer size and viewport, not the retained
mesh geometry.

## Evidence template

Copy this into a dated `docs/validation/` document and fill it in:

```markdown
# Windows high-DPI / mixed-scale validation (<date>)

- Machine: Windows 10 22H2, RTX 2080 SUPER, driver <version>
- Commit: <sha>; Odin: <version>; wgpu-native: v29.0.1.1
- Monitors: A <resolution> @ <scale> (<primary?>), B <resolution> @ <scale>
- Command: `16_native_webgpu_ui.exe --timing-motion --timings`

## Workload counters

| Pass | frames | solid rebuilds | text rebuilds | solid viewport | text viewport | p50/p95/p99 |
| --- | --- | --- | --- | --- | --- | --- |
| A baseline | | | | | | |
| B baseline | | | | | | |
| A→B→A + resize | | | | | | |

## Observations

- Mesh rebuilds across scale change: <none / list>
- Viewport uploads per transition: <counts>
- Visual: <text size, hit targets, blank frames, errors>
- Logs: <paths>

## Limits

CPU wall time only; no GPU execution or scanout measurement. One machine and
driver. Does not exercise device loss.
```

## Pass/fail

Pass: no mesh rebuilds caused purely by a scale/monitor change, viewport
updates present, motion continues, no crash or validation error, counters
comparable to the baseline passes.

Fail: any `*_mesh_rebuilds` jump on a pure scale change, a blank/black frame
that does not recover, a lost surface without recovery, or a validation error.
