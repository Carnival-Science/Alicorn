# Issue #211 topmost re-entry regression (Windows, 2026-11-20)

Stage D slice 1 evidence for the hosted floating-window position regression.
Machine: Windows 10 22H2, NVIDIA GeForce RTX 2080 SUPER, SDL 3.4.20.
Branch: `codex/issue-211-scratchpad-webgpu`.
Scratchpad validator: `codex/issue-211-webgpu-frontend` at `b458d6e`
(used as a source dependency only; no Scratchpad change).

## Defect

On the hosted WebGPU path a secondary `ALWAYS_ON_TOP` window moved up and to the
left on every mouse re-entry. SDL's `WIN_OnWindowEnter` promotes such a window
with `WIN_AdjustWindowRect`, which re-applies the standard caption/border inset
that Alicorn's full-client `WM_NCCALCSIZE` already covers. The reference host
had intercepted this in `bae58e9` inside `native/sdl_gpu/menus_windows.odin`;
the hosted chrome port (`host/menus/chrome_windows.odin`) had no
`WM_WINDOWPOSCHANGING` branch, so only the hosted path regressed.

## Fix

`host/sdl3/window_frame` now owns the discrimination and the `SWP_NOMOVE`
interception. Native `win32_menu_preserve_topmost_promotion_position` delegates
to it and keeps its `windows.json` counter; hosted
`win32_chrome_preserve_topmost_promotion_position` calls it from
`win32_chrome_handle_message` before `DefSubclassProc`.

Predicate (all must hold):

- integrated frame active, SDL window has `.ALWAYS_ON_TOP`;
- request has `SWP_NOSIZE | SWP_NOACTIVATE` and not
  `SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED`;
- requested origin equals `SDL_GetWindowPosition()` plus the
  `AdjustWindowRectExForDpi` origin inset, and that inset is nonzero.

## Negative control (proves the runner is sensitive)

With `position.flags |= win.SWP_NOMOVE` temporarily removed from the shared
predicate and example 16 rebuilt:

```text
backend=d3d12
baseline rect=892,439,1668,938
entry 0 rect=884,408,1660,907 delta=(-8,-31)
FAIL entry-0-position-preserved expected 892,439
topmost_reentry FAIL backend=d3d12 failures=1 pass=4
```

`(-8,-31)` is the founder's "shifts to the left and up". The line was restored
from a byte-for-byte backup before the final builds.

## Fixed runs

`tools/validate_native_webgpu_topmost.ps1` hovers the real cursor out of and
back into an integrated-chrome `ALWAYS_ON_TOP` child four times. Every backend:

```text
backend=d3d12   baseline 892,439,1668,938  entries 0-3 delta=(0,0)  PASS 8/8
backend=vulkan  baseline 892,439,1668,938  entries 0-3 delta=(0,0)  PASS 8/8
backend=sdl-gpu baseline 892,439,1668,938  entries 0-3 delta=(0,0)  PASS 8/8
```

Raw logs: `out/topmost-reentry/*-topmost-reentry-20261120-1850*.log`.

## Message-injection regression tests

- `host/menus` 9/9, including the ported
  `test_win32_hosted_topmost_mouse_entry_preserves_native_rectangle`
  (8 entries preserved, no activation, counter 8; explicit move and resize
  still apply; topmost off/on adds 8 more, counter 16).
- `host/sdl3/window_frame` 1/1 predicate discrimination matrix.
- `native/sdl_gpu` 168/168, including the original
  `test_integrated_topmost_window_mouse_entry_preserves_native_rectangle`
  and the platform diagnostics assertions (counter 16).

## Example 16 smokes

```text
--child-chrome-smoke  d3d12 PASS  vulkan PASS  sdl-gpu PASS
--titlebar-smoke      d3d12 PASS  vulkan PASS  sdl-gpu PASS
```

## Scratchpad smoke (`b458d6e`, candidate root this branch)

```text
smoke --renderer=webgpu --backend=d3d12  clean passed true  recovery passed true
smoke --renderer=webgpu --backend=vulkan clean passed true  recovery passed true
smoke --renderer=sdl-gpu                 clean passed true  recovery passed true
```

Logs: `out/stageD-smoke-*.log` in the Scratchpad checkout. No Scratchpad source
or lock change; `--alicorn-root` and `--allow-alicorn-revision` selected this
branch for the build.

## Hands-on remaining

The physical runner uses the fixture child, not Scratchpad's floating window.
The founder checklist in
[`../webgpu-migration.md`](../webgpu-migration.md#stage-d-slice-1-topmost-floating-window-re-entry-position-windows-2026-11-20)
still applies to the real detach/on-top flow, multi-monitor scales, and
partially off-screen placement.
