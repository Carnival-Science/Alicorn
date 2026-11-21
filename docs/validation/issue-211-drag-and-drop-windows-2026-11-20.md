# Issue #211 Stage D slice 3: file and folder drag-and-drop (Windows, 2026-11-20)

Founder acceptance for this slice: three capabilities from the parity table.

1. Moving files/folders inside Scratchpad (retained drag-and-drop).
2. Dragging files/folders out to Explorer (native OS drag source).
3. Dropping files/folders from Explorer into Scratchpad (host file drop).

The work was done in `C:\Users\saman\.codex\worktrees\alicorn-webgpu-migration\alicorn`
(branch `codex/issue-211-scratchpad-webgpu`). The Scratchpad validator
`b458d6e` was used read-only through `--alicorn-root`; its source was not
modified by this slice.

## Inventory: what existed and where

| Capability | Reference SDL_GPU host | Hosted SDL3/WebGPU host before this slice |
| --- | --- | --- |
| Internal retained drag/drop | `runtime/drag_drop.odin`, hosted pointer dispatch in `native/sdl_gpu/event_dispatch.odin` | Same runtime through `hosted_runtime_pointer`; B5/C2 fixed pointer arbitration and preview |
| Drag out | `native/sdl_gpu/file_drag.odin` (`File_Drag_Service`) + `file_drag_windows.odin` (OLE `IDataObject`/`IDropSource`, `CF_HDROP`) | None. `Hosted_Host_Services` had no file-drag field, so `UI_Host_Services` could not publish it |
| Drop in | `SDL_EVENT_DROP_FILE` -> `Application.on_file_drop` in `event_dispatch.odin` | `SDL_EVENT_DROP_FILE` -> `hosted_runtime_file_drop` -> `on_file_drop` (B1) |

The existing native API shape is:

```odin
File_Drag_Service :: struct { data: rawptr, start: File_Drag_Start_Proc }
application_file_drag_start(service, path) -> bool
Application_Services.file_drag // native
```

The Windows implementation allocates a reference-counted object with a
`cf_format == CF_HDROP`, `dw_aspect == DVASPECT_CONTENT`, `lindex == -1`,
`tymed == TYMED_HGLOBAL` data object and a drop source that cancels on Escape,
continues while the left button is held, and drops on release.

## Shared implementation

- `runtime/file_drag.odin` now owns `File_Drag_Start_Proc`, `File_Drag_Service`,
  and `application_file_drag_start`, so the hosted API and the native API are the
  same values.
- `host/sdl3/file_drag/file_drag_windows.odin` now owns the OLE implementation.
  `native/sdl_gpu/file_drag_windows.odin` was deleted; the native host delegates
  through `native_file_drag_service` and keeps only aliases for source
  compatibility.
- `Hosted_Host_Services.file_drag` and `UI_Host_Services.file_drag` publish the
  service on the hosted path. `ui.run`'s SDL_GPU adapter, the native WebGPU
  adapter, and `Hosted_Window_Description` secondary windows all forward it.
- `host/sdl3/application.odin` installs the service for every hosted surface;
  `host/sdl3/file_drag/file_drag_other.odin` publishes an empty service on
  non-Windows platforms.

The object is also exposable to a mock consumer through
`windows_file_drag_object_create`; this is how the OLE contract is tested
without entering the modal loop.

## Modal drag re-entrancy

`DoDragDrop` re-enters the owning thread's Windows message loop and does not
return until the user drops or cancels. The application is therefore suspended
inside its own pointer callback. The shared source marks an `active` flag for the
duration, and both hosts consult `sdl3_file_drag.is_active()` before servicing a
nested live-resize/expose frame:

- `host/sdl3/live_resize_host.odin` returns not-renderable while a drag is
  active.
- `native/sdl_gpu/window_move.odin` does the same for its live-resize slots.

This is the drag counterpart of Stage C slice 1: no timer-driven description may
re-enter application state while the modal loop owns the thread. Ordinary host
events queued during the drag are processed after `DoDragDrop` returns.

## Capability evidence

### 1. Internal retained drag and drop (both hosts)

`runtime/hosted_parity_test.odin` adds
`test_hosted_retained_drag_drop_between_targets_matches_the_reference_route`. It
describes a document source (`document.txt`) and a folder drop target, then runs
the identical Down/Move/Move/Up sequence through:

- `hosted_runtime_pointer` (hosted route), and
- `process_pointer` plus the native `drag_event_take` dispatch (reference
  route).

Both routes emit the same `Started` -> `Target_Changed` -> `Dropped` sequence,
including source/target semantic identities and the `On` drop position. The
runtime suite is 421 tests.

The existing example 16 `--tab-drag-smoke` was also re-run on all three
backends. It reports `tab_drag_smoke PASS mode=Source_Subtree ... drop_target 2
drop_position After` and a captured mid-drag bundle with three preview commands
on D3D12, Vulkan, and SDL_GPU.

### 2. Drag out to another application (shared seam, Windows OLE)

`host/sdl3/file_drag/file_drag_windows_test.odin` (3 tests) drives the exported
vtables as a mock drop target:

- `QueryInterface` returns the `IDataObject` and `IDropSource` faces from one
  object and rejects an unrelated IID with `E_NOINTERFACE`.
- `QueryGetData` accepts only `CF_HDROP` / content / index -1 / HGLOBAL and
  rejects the other format, aspect, index, and `tymed` with
  `DV_E_FORMATETC`/`DV_E_TYMED`.
- `GetData` returns one `TYMED_HGLOBAL` medium whose `DROPFILES` header is
  wide/whole-file and whose UTF-16 path round-trips exactly, including a
  non-ASCII (`dräge me.txt`) file and a folder path.
- `EnumFORMATETC` yields exactly the one supported format, ends with `S_FALSE`,
  resets, and releases.
- `GetDataHere`/`SetData` return `E_NOTIMPL`; advise methods return
  `OLE_E_ADVISENOTSUPPORTED`.
- `QueryContinueDrag` cancels on Escape, continues with `MK_LBUTTON`, and drops
  when the button is released; `GiveFeedback` requests the default cursors.
- `application_file_drag_start` rejects an empty path and an embedded NUL before
  OLE.

The host-level publication was exercised by example 16 `--services-smoke` on
D3D12, Vulkan, and SDL_GPU. Each run prints `file_drag true` through
`UI_Host_Services`, proving the same service reaches both `ui.run` and the hosted
WebGPU `run` (the hosted run uses `Hosted_Host_Services.file_drag`).

A real `DoDragDrop` loop cannot be completed by synthetic input in this
automation. Both D3D12 and SDL_GPU were driven with an injected press/move/release
and remained inside the modal OLE loop after `file_drag_demo begin`; OLE waits
for a physical drag. The mock consumer plus service publication is the automated
evidence. The actual drop into Explorer is the founder's hands-on check below.
Example 16 now has `--file-drag-demo` as a real app-facing call site:
`file_drag_demo_pointer` calls `ui.ui_file_drag_start` from the pointer gesture.

Limitation recorded for the Scratchpad validator: `b458d6e` has no
`Scratchpad_Services.file_drag` field and no workspace-row drag-out call site, so
the reference and hosted builds both currently drop that service during their
1:1 adapter mapping. Alicorn's hosted API now matches native exactly, but
Scratchpad must map the field and call `application_file_drag_start` from its
workspace drag threshold for the founder's Scratchpad drag-out check. This is the
same one-line mapping the reference path would need; it is not a renderer
difference.

### 3. Drop in from Explorer (both hosts)

- Native: `native/sdl_gpu/file_drop_test.odin` pushes a real
  `SDL_EVENT_DROP_FILE` through SDL's queue, calls `pump_events`, and asserts
  `Application.on_file_drop` receives `C:/alicorn/native-drop.txt` and the
  retained description is invalidated.
- Hosted: `host/sdl3/application_test.odin` now pushes the same event through
  `SDL_PushEvent`, peeps it from SDL's queue, dispatches it through
  `sdl3_webgpu_application_handle_event`, and asserts `on_file_drop` receives
  the exact path and the next step rebuilds the description.
- End-to-end in a real hosted app: example 16 `--services-smoke` pushes the drop
  from its tick callback. D3D12, Vulkan, and SDL_GPU all report
  `drops 1 drop_ok true` and exit 0.

## Suites and smokes

`tools/test.ps1` ran through the AccessKit dependency check and every suite up
to `ui`, then stopped at `tools/check_web_ui_package.ps1` with the pre-existing
`DevicePoll` JS-binding failure described below. The suites after that point
(and the new `host/sdl3/file_drag` suite) were run individually with the same
compiler arguments.

| Suite | Result |
| --- | --- |
| runtime | 421 passed |
| host/fonts | 5 passed |
| host/sdl3 | 8 passed |
| host/sdl3/file_drag | 3 passed |
| host/sdl3/live_resize | 9 passed |
| host/sdl3/window_frame | 1 passed |
| host/sdl3/input | 8 passed |
| host/sdl3/clipboard | 3 passed |
| host/sdl3/dialogs | 5 passed |
| host/menus | 9 passed |
| host/web | 14 passed |
| host/diagnostics | 9 passed |
| host/presentation | 7 passed |
| renderer/webgpu | 9 passed |
| renderer/cpu | 23 passed |
| ui | 50 passed |
| testui | 13 passed |
| theme | 37 passed |
| native/sdl_gpu | 169 passed |
| native/scroll_capture_tests | 6 passed |
| accessibility contract | 1 passed |
| `odin build tests` / `out/alicorn_tests.exe` | foundation PASS |
| examples/16 `--services-smoke` D3D12 / Vulkan / SDL_GPU | PASS x3 |
| examples/16 `--tab-drag-smoke` D3D12 / Vulkan / SDL_GPU | PASS x3 |
| Scratchpad `b458d6e` smoke, hosted D3D12 | clean + recovery PASS |
| Scratchpad `b458d6e` smoke, SDL_GPU reference | clean + recovery PASS |

`tools/check_web_ui_package.ps1` fails with
`host/presentation/surface_presenter.odin(498): DevicePoll is not declared by
wgpu` on this Odin installation. The identical failure reproduces at base commit
`b79ef57` in a clean worktree, so it is not introduced by this slice.

Raw logs are in `docs/validation/raw/issue-211-dnd-*-2026-11-20.txt`.

## Founder hands-on checklist

1. **Drag out (Scratchpad prerequisite).** Add the one-line
   `Scratchpad_Services.file_drag` mapping and call
   `alicorn.application_file_drag_start(app.services.file_drag, path)` when a
   workspace row crosses the drag threshold. Both host adapters already publish
   the service. Then drag a file and a folder from the Scratchpad tree onto an
   open Explorer window. Explorer must receive the item (copy effect) and the
   Scratchpad drag must end cleanly; Escape must cancel.
2. **Drag out without Scratchpad changes.** Run example 16 with
   `--file-drag-demo` on the hosted build, press in the window, and drag to
   Explorer. It prints `file_drag_demo begin` and then
   `Native file drag returned true ...`. Repeat with `--backend=sdl-gpu`; both
   renderers use the same service.
3. **Drop in.** Drag a file and a folder from Explorer onto the Scratchpad
   window. Both must reach the application's `on_file_drop` path; a folder must
   arrive as a path, not an enumerated list. Repeat on the SDL_GPU reference and
   confirm the same behavior.
4. **Internal move.** Drag a file onto a folder row and a folder onto another
   folder row in Scratchpad. The item must move on disk once, the tree must
   refresh, and the tab/preview state must settle. Repeat on both renderers.
5. **Modal sanity.** Start a drag out, move the pointer over the Scratchpad
   window, and cancel with Escape. The window must not resize, jump, or show a
   stale mid-drag frame; then resize and move the window normally.

## Limits

- OLE drag-out is Windows-only in this slice. Other platforms publish an empty
  service and return false.
- The automated drag-out evidence is the IDataObject/IDropSource contract and
  service publication, not a completed Explorer drop.
- Scratchpad `b458d6e` does not yet call the drag-out service. Its 1:1 service
  adapter needs the field mapping described above before the founder's real
  Scratchpad drag-out can succeed.
- The browser host has no native drag-out equivalent.
