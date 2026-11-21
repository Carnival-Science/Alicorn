# Issue #211 Stage C slice 6: high-DPI monitor transitions (Windows)

- Machine: Windows 10 22H2, NVIDIA RTX 2080 SUPER (driver 32.0.15.9597),
  two displays (2560x1440 and 1920x1080), **both currently at 96 DPI / 100%**.
- Branch: `codex/issue-211-scratchpad-webgpu`, base `b608799` + this slice.
- Odin: `C:\odin\odin.exe`. wgpu-native v29.0.1.1 (shared DLL).
- Acceptance: "High-DPI monitor transitions - correct geometry, text and hit
  testing."

Because both monitors report 96 DPI, this session cannot originate a real
cross-monitor WM_DPICHANGED. The fixture splits the OS sequence into the two
observable halves described in `docs/webgpu-migration.md`: posted window
messages for the window-proc/chrome branch, and explicit metric adoption for
the drawable/display-scale transition. The founder's physical drag remains the
final confirmation; the checklist is in the migration record.

## Audit summary

Compared `native/sdl_gpu` (`window_host.odin`, `event_dispatch.odin`,
`window_host.native_live_resize_redraw_once`) with the hosted SDL3 path
(`host/sdl3/application.odin`, `live_resize_host.odin`, `host/menus/chrome_windows.odin`,
`host/presentation/surface_presenter.odin`, `runtime/hosted.odin`).

Fixed divergences:

| Divergence | Fix |
| --- | --- |
| Hosted passed `pixel_width/logical_width` to the application as `dpi_scale`; native passes `display_scale`. | `host/sdl3/application.odin` reads `GetWindowPixelDensity` and `GetWindowDisplayScale` separately, stores both, passes display scale to the description, and keeps presentation on the drawable ratio. |
| Hosted had no independent display-scale state; diagnostics reported the same value for density and display scale. | `SDL3_WebGPU_Application` gained `pixel_density`/`display_scale`; `diagnostics.odin` reports them separately. |
| A metadata-only display-scale change (drawable ratio fixed) could not be adopted without a resize. | New `sdl3_webgpu_application_apply_metrics` publishes one coherent measurement and `hosted_runtime_resize` invalidates on display-scale change at fixed logical size. |
| Hosted live-resize geometry comparison ignored the scale inputs. | `sdl3_webgpu_live_resize_geometry_changed` compares pixel density and display scale too. |
| Native live-resize only invalidated on logical changes, missing a display-scale change mid-drag. | `window_host.odin` adds the `SDL display scale changed` invalidation when metadata scale changes without a logical change. |

Verified without changes: retained geometry stays logical and the device-grid
snap is rebuilt from unsnapped targets (no double scale); text is keyed by
physical size and re-rasterizes on a new scale; chrome re-syncs DPI, density,
caption layout, and inset on every pre-present sync; hit testing uses logical
bounds plus the chrome inset; each hosted application owns independent runtime,
text engine, presenter, and DPI state.

## Hosted transition fixture

Build and run:

```powershell
.\tools\validate_native_webgpu_dpi.ps1 -Odin C:\odin\odin.exe
.\tools\validate_native_webgpu_dpi.ps1 -Odin C:\odin\odin.exe -Backend vulkan
```

The fixture (`tests/fixtures/dpi_transition`) creates two real hosted WebGPU
windows on one device:

- primary: system decorations, a known text node and button;
- chrome: integrated Windows titlebar with a menu, used for the posted
  `WM_DPICHANGED` + `WM_DISPLAYCHANGE` branch.

Output (D3D12):

```text
dpi_transition baseline scale=1.000 logical=160.0x40.0 ink=4150 max_delta=1429
dpi_transition scale=1.250 dpi=1.250 presentation=1.250 ink=6026 midtones=43474 max_delta=1429
dpi_transition scale=1.500 dpi=1.500 presentation=1.500 ink=8733 midtones=62547 max_delta=1429
dpi_transition scale=1.750 dpi=1.750 presentation=1.750 ink=11440 midtones=85580 max_delta=1429
dpi_transition scale=1.250 dpi=1.250 presentation=1.250 ink=6026 midtones=43474 max_delta=1429
dpi_transition scale=1.000 dpi=1.000 presentation=1.000 ink=4150 midtones=27530 max_delta=1429
dpi_transition posted_messages=WM_DPICHANGED,WM_DISPLAYCHANGE chrome_layouts=11->12 chrome_metrics=1->1 header_h=32.0
dpi_transition per_window primary scale=1.250 secondary scale=1.750 hit=.../...
dpi_transition PASS
```

(`hit=` values are opaque 64-bit `Node_ID`s; the fixture compares them to the
keyed node, not their decimal form.)

Vulkan reports the same ink counts/deltas, scales, and PASS.

### What each assertion proves

| Assertion | Evidence |
| --- | --- |
| Surface resized to new pixels and presentation scale updated | `hosted_surface_presenter_metrics` reports `logical * scale` configuration and `scale x scale` presenter scales after every adoption. |
| Application receives display scale | The render callback records `dpi`; it equals the adopted display scale (1.25/1.5/1.75/1.0). |
| Logical layout invariant | The button node's logical bounds equal the baseline at every scale and after returning to 1.0. |
| Hit testing remapped correctly | A pointer at the same logical center targets the same keyed button node after every scale change. |
| Text re-rasterized, not stretched | The WebGPU text mesh rebuild counter rises; on first visit to a scale, glyph rasterizations rise; captured ink area tracks `scale^2` (ratios 0.93-0.98); maximum adjacent luma step is 1429/2550 at every scale (no bilinear blur). |
| No stale atlas on revisit | Returning to 1.25 and 1.0 reuses cached slots and reproduces the same captures exactly. |
| Window-proc DPI branch runs | Posting `WM_DPICHANGED` to the integrated window turns an idle `.No_Frame` step into a presented `.Ok` frame and re-runs the chrome layout callback (`chrome_layouts 11 -> 12`). The metrics callback stays at 1 because the synthetic message cannot change `GetDpiForWindow`; geometry is re-read and republished regardless. |
| Per-window independence | Primary adopts 1.25, chrome window adopts 1.75 simultaneously; each presenter, display scale, description scale, bounds, and hit target remains its own. |

## Unit and reference-host parity

```powershell
C:\odin\odin.exe test runtime
C:\odin\odin.exe test host\sdl3 -collection:alicorn=<repo> @accesskit
C:\odin\odin.exe test native\sdl_gpu -collection:alicorn=<repo> @accesskit
```

- `runtime/hosted_test.odin` (419 total): repeated 1.0/1.25/1.5/1.75/1.25/1.0
  transitions at fixed logical size rebuild the description, deliver the display
  scale, preserve logical bounds, keep the hit target, and publish exact
  presentation scales. A metadata-only change (drawable 1.5, display 1.75)
  rebuilds while presentation stays 1.5.
- `host/sdl3/application_test.odin` (8 total): `apply_metrics` keeps density and
  display scale separate, rebuilds on metadata change, and falls back to the
  drawable ratio for zero scales.
- `native/sdl_gpu/dpi_transition_test.odin` (168 total): the reference host's
  `native_window_metrics_apply` produces the same observables for the same
  injected metric sequence, including metadata-only changes.

## Full suite results

| Suite | Result |
| --- | --- |
| runtime | 419 pass |
| host/fonts | 5 pass |
| host/sdl3 | 8 pass |
| host/sdl3/live_resize | 9 pass |
| host/sdl3/input | 8 pass |
| host/sdl3/clipboard | 3 pass |
| host/sdl3/dialogs | 5 pass |
| host/menus | 8 pass |
| host/web | 14 pass |
| host/diagnostics | 9 pass |
| host/presentation | 7 pass |
| renderer/webgpu | 8 pass |
| renderer/cpu | 23 pass |
| ui | 50 pass |
| testui | 13 pass |
| theme | 37 pass |
| native/sdl_gpu | 168 pass |
| native/scroll_capture_tests | 6 pass |
| accessibility contract | 1 pass |
| `odin build tests` + `out/alicorn_tests.exe` | foundation PASS |

Example 16 smokes: 7 smokes x 3 legs = 21/21 PASS (`--smoke`,
`--workbench-smoke`, `--titlebar-smoke`, `--child-chrome-smoke`,
`--menu-smoke`, `--services-smoke`, `--tab-drag-smoke` on D3D12, Vulkan,
SDL_GPU).

Scratchpad (`codex/issue-211-webgpu-frontend` at `b458d6e`, candidate root this
working tree, no Scratchpad source or lock change):

```powershell
go run ./cmd/alicorn-dev smoke --alicorn-root <this repo> --allow-alicorn-revision `
  --odin C:\odin\odin.exe --renderer=webgpu --backend=d3d12
go run ./cmd/alicorn-dev smoke --alicorn-root <this repo> --allow-alicorn-revision `
  --odin C:\odin\odin.exe --renderer=webgpu --backend=vulkan
go run ./cmd/alicorn-dev smoke --alicorn-root <this repo> --allow-alicorn-revision `
  --odin C:\odin\odin.exe --renderer=sdl-gpu
```

All three exit 0 and report `publication_rendered true`, `wake_observed true`,
`ordered_shutdown true`, `session_restore true`, with
`alicorn-smoke-session clean passed true` and `recovery passed true`. Logs were
captured under the scratchpad `out/` directory; no source or lock file was
modified.

## Limits

- No real per-monitor `WM_DPICHANGED`: both available monitors are at 96 DPI.
  The fixture covers the window-proc branch and the exact metric adoption
  separately; it cannot prove the OS's own suggested-rect application.
- CPU-side capture and counters only; no GPU scanout or display-color
  measurement.
- One machine and one GPU driver.
- The physical drag can still expose driver/compositor behavior (e.g., a
  transient blank swapchain) that offscreen capture does not reproduce.
