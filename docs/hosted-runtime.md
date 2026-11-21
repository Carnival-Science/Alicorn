# Host-owned UI loops

`alicorn:runtime` exposes a retained session for an application that already
owns a native window and event loop. The host creates one `Hosted_Runtime` per
surface, delivers native input on its UI thread, calls a nonblocking step, and
submits the resulting paint commands through its renderer. The SDL `ui.run`
and `host.Run` entry points remain available and unchanged.

This is a Runtime lifecycle boundary, not a ready-made wxWidgets adapter. The
host still owns its window, event translation, renderer/device, clipboard,
dialogs, native menus, native text-input service, and native accessibility
bridge. In particular, a host must prove that its chosen renderer can present
into its surface and that native IME and accessibility behavior remain correct.

## Ownership and thread contract

- Initialize, deliver events, resize, step, inspect borrowed Runtime data, and
  destroy the session on the same native UI thread.
- One session owns one retained Runtime for every control on its surface.
  Application state and GPU/window resources remain host-owned.
- Workers may keep only a cloned `Hosted_Waker`. They never call Runtime,
  renderer, native-window, or application callbacks.
- The `post_wake` callback must only enqueue a host event and return promptly.
  It is called while Alicorn protects the wake handle; it must not re-enter
  `hosted_waker_*` or synchronously run the event loop.
- The allocator passed as `wake_allocator` must support allocation/free across
  the UI and worker threads. The default context allocator is suitable only
  when the host's allocator is thread-safe.
- Do not destroy or reinitialize the session from one of its callbacks. Queue
  a host close request and perform teardown after the callback returns.
- Do not race session operations or teardown from another thread. Apart from
  `Hosted_Waker`, the session handle and its borrowed data are UI-thread-only.

## Create and describe a session

`render` owns the application root, exactly like `native/sdl_gpu`'s
`Application.build`: open one `.Root` container, describe its children, and
close it before returning. The session calls `begin_frame`/`end_frame` around
the callback but does not add a host root column, so the application root's
bounds are the content viewport (reduced only by host-owned `content_inset_top`)
and overlay layers described with `modal_overlay_begin` resolve against the same
root as they do under the reference host. `on_initialize` runs after Runtime
creation and before the first description, so it can install application fonts.
`on_start` runs before the first step.

`Hosted_Runtime_Config.on_after_frame` runs after `end_frame` of the same
description pass and before the host presents that frame:
`describe -> end_frame -> after_frame -> present`. It runs on every described
frame, including the last one before an idle period, and does not depend on
another frame being scheduled. Use it for post-layout work such as focus or
scroll restoration. If it changes retained layout or paint state, it must call
`invalidate_root`; the bounded stabilization loop then runs another description
in the same step. `ui.run`, `ui/webgpu.run`, and the browser `run` expose the
same hook as `on_after_frame`.

Desktop font initialization is part of the same parity contract. `ui.run` and
the hosted SDL3/WebGPU `ui/webgpu.run` install the canonical stack through
`alicorn:host/fonts` (`load_default_fonts`): bundled Atkinson faces first, then
the bounded platform/DirectWrite fallbacks. A host that creates
`Hosted_Runtime` directly owns this step; calling only
`text_engine_load_default_fonts` leaves the runtime without system fallbacks and
will resolve CJK, emoji, and symbols differently from the SDL_GPU reference.
The browser `ui/webgpu.run` path loads bundled defaults only, because a page
cannot read local font files.

```odin
import alicorn "alicorn:runtime"
import "core:fmt"

App :: struct { count: int }
Host_Context :: struct {}

describe :: proc(data: rawptr, ui: ^alicorn.UI, width, height: int, dpi: f32) {
	app := (^App)(data)
	if alicorn.container_begin(
		ui,
		.Root,
		label="app-root",
		key="app-root",
		style=alicorn.layout_style(.Column, grow=1, padding=24, gap=12),
	) == 0 { return }
	alicorn.text(ui, "Hosted by the application", key="heading")
	alicorn.text(ui, fmt.tprintf("Count: %d", app.count), key="count")
	alicorn.container_end(ui)
}

// post_wake posts a custom event to the host's normal UI queue. The queued
// event should identify the live host session; it must not call Alicorn here.
post_wake :: proc(data: rawptr) -> bool {
	return host_queue_wake_event(data)
}

main :: proc() {
	app := App{}
	host := Host_Context{}
	view: alicorn.Hosted_Runtime
	status := alicorn.hosted_runtime_init(&view, alicorn.Hosted_Runtime_Config{
		state=rawptr(&app),
		logical_width=900,
		logical_height=600,
		pixel_width=1800,
		pixel_height=1200,
		dpi_scale=2,
		render=describe,
		post_wake_data=rawptr(&host),
		post_wake=post_wake,
	})
	if status != .Ok { return }
	defer alicorn.hosted_runtime_destroy(&view)

	// Run the host's normal event loop here; see the loop contract below.
}
```

The snippet shows the Alicorn side of the boundary; `host_queue_wake_event`
and native event polling are host-specific. Keep the host object and wake
callback data alive until `hosted_runtime_destroy` returns.

## Event loop contract

The host should process a bounded batch of queued native events, deliver each
event to the session in order, and call `hosted_runtime_step` once with the
current monotonic time. Do not drain an unbounded stream before giving other
UI work a chance to run. If the host still has queued input, it should enqueue
another immediate UI-loop turn. Combine that condition with
`Hosted_Step_Result.has_more_work`; neither condition requires a polling
timer.

```text
on native event:
    translate and deliver it on the UI thread
    if wake event:
        hosted_runtime_deliver_wake(session)

after a bounded event batch or one-shot timer:
    result = hosted_runtime_step(session, monotonic_now_ns)
    if result.render_required:
        commands = hosted_runtime_display_commands(session)
        submit commands using the host renderer
        if submission succeeds:
            hosted_runtime_frame_submission_succeeded(session)
    if host_queue_not_empty or result.has_more_work:
        enqueue an immediate host-loop turn
    else if result.next_wake_ns != 0:
        arm one host timer for that absolute monotonic deadline
    else:
        wait normally for native input or a worker wake
```

`step` never waits, polls, or drains the host's event queue. It advances
retained motion, tooltips, notices, drag-edge autoscroll, and the optional
application deadline, runs at most one due tick, then performs one bounded
application description sequence. `next_wake_ns` is the
earliest one-shot deadline Alicorn currently needs. `has_more_work` reports
work that requires another step; a pending frame is reported separately by
`render_required`. After a successful renderer submission, acknowledge it
once. If submission fails, do not acknowledge it; the host owns a bounded
retry policy and any GPU/device recovery.

The host should use one monotonic clock for `step`, pointer timestamps, and
deadlines. `hosted_runtime_set_deadline` installs or replaces one legacy
Frequent-class application deadline; zero cancels it. New code should use
`Hosted_Host_Services.scheduler` instead. Both deadline paths are one-shot and
the scheduled callback may install the next deadline from inside the callback.
There is no recurring wake except an installed `on_tick`; that callback runs at
the native host's bounded ~60 Hz cadence and is not an idle poll.
An application deadline remains armed while the surface is hidden; retained
motion, tooltip, notice, and drag-autoscroll sampling pause until the surface
becomes renderable. Ticks and scheduled wakes still run while hidden, mirroring
the reference host's event loop. Hidden steps can still process model
invalidation, but never report `render_required`. Restoration requests a
retained presentation and samples the current monotonic time, without replaying
missed ticks.

### Retained motion scheduling

Each `Hosted_Runtime` owns one retained-motion deadline, exactly like the
reference host's per-window motion scheduler. `next_wake_ns` publishes it while
a response is active; a settled surface publishes no motion deadline at all.

- Only a step at or after the deadline samples retained motion. A step caused by
  an unrelated event, a tick, a worker wake, or a queue-completion notification
  refreshes the injected motion clock (so `ui.motion` targets in an upcoming
  description resolve against the current time) but does not resample or
  present retained poses. Re-sampling on every host turn would let pointer
  storms and submission-completion wakes drive an animation faster than the
  display cadence; the reference host produces one sample per deadline.
- A response started by a description, an `on_after_frame` hook, or retained
  interaction paint arms its first deadline in the same step, before
  `next_wake_ns` is returned.
- A sample that changes a presented value requests one presentation-only frame
  (`render_required`); no application description is rebuilt. The final sample
  settles the response and clears the deadline, so the next step reports neither
  work nor a wake.
- `hosted_runtime_live_step` (the platform modal move/resize path) shares the
  same deadline and cadence. It advances retained motion, rebuilds an
  invalidated description, and reports presentation, but does not dispatch
  `on_tick` or application scheduled wakes.
- A host that quantizes its wait (for example SDL3 on Windows, which truncates a
  remaining nanosecond timeout to milliseconds) must not turn a sub-millisecond
  remainder into a zero-length wait: that re-enters the host loop for the final
  fraction of every sampling interval. `host/sdl3/run.odin` adds one millisecond
  of slack, mirroring `native/sdl_gpu`'s
  `native_event_wait_windows_timeout_ms`.

`runtime/hosted_motion_test.odin` pins the contract: a response presents a
bounded run of frames without any description change, a 1 ms host-turn storm
yields the display cadence rather than one frame per turn, a settled surface
presents nothing for a second of host turns, a tick-only surface presents
nothing, a hidden surface drops its deadline and samples once on restore, two
sessions schedule independently, and live steps share the same deadline.

The Runtime cannot observe arbitrary application memory. If `on_wake`,
`on_scheduled_wake`, `on_drag`, or `on_scroll` changes data used by the next
description, that callback must call `invalidate_root` on its supplied Runtime.
`on_key` returning `true`, application-owned text input, and pointer button
callbacks already request a description.

## Application callbacks and host services

`Hosted_Runtime_Config` exposes the full application callback surface used by
the native SDL_GPU host. Every field is optional and zero-default:

```text
on_drag              proc(state, rt, Drag_Event)
on_scroll_capture    proc(state, rt, Scroll_Event, target: Node_ID) -> bool
on_scroll            proc(state, rt, Scroll_Event)
on_text_input        proc(state, rt, owner: Node_ID, Hosted_Text_Input_Event)
on_scheduled_wake    proc(state, rt, class: Scheduled_Wake_Class)
on_file_drop         proc(state, rt, path: string)
on_tick              proc(state, rt)
on_after_frame       proc(state, rt)
on_menu_command      proc(state, rt, command: Action_ID)
on_close_requested   proc(state, rt) -> Hosted_Close_Result
on_dialog            proc(state, rt, result: ^File_Dialog_Result)
```

`Hosted_Scheduled_Wake_Proc`, `Hosted_File_Drop_Proc`, `Hosted_Tick_Proc`,
`Interaction_Update_Policy`, `Scheduled_Wake_Class`, and the scheduler service
are the same runtime-defined values that `native/sdl_gpu` re-exports as
`Application_*` aliases, so a native callback can be moved to the hosted
surface without signature changes. File-drop paths are borrowed for the
callback only.

`Hosted_Host_Services` publishes `windows`, `dialogs`, `quit`, `clipboard`,
`file_drag`, and `scheduler`:

- `Hosted_Dialog_Service` is an opaque host backend. Submit a
  `File_Dialog_Request` with `hosted_dialog_show_file`; the host copies the
  request, presents its native dialog, and calls `hosted_runtime_dialog` on the
  owner thread when a `File_Dialog_Result` is ready. Result paths and error text
  are borrowed for `on_dialog`.
- `Hosted_Quit_Service` completes a close request that `on_close_requested`
  deferred. Call `hosted_quit_request` after the application finishes its
  save/discard flow. The host owns teardown and retires the service after
  `on_stop`.
- `Hosted_Menu_Command_Proc` matches native
  `Application_Menu_Command_Proc`; `hosted_runtime_menu_command` routes one
  command under the native-command cause and invalidates the description.
- `clipboard` is the synchronous native SDL3 clipboard service:
  `ClipboardGetText(service, allocator)` returns an owned UTF-8 copy and
  `ClipboardSetText(service, text)` copies UTF-8 synchronously. This mirrors
  `Application_Services.clipboard` exactly. Browser hosts cannot provide it
  synchronously (the Web Clipboard API is asynchronous); they publish the
  renderer-neutral asynchronous service in `alicorn:host/clipboard` through
  `UI_Host_Services.clipboard` instead. Browser applications must consume the
  async request/completion shape; that migration is a Stage C concern.
- `file_drag` is the native drag-out capability and has exactly the
  `Application_Services.file_drag` shape: `File_Drag_Service` with
  `application_file_drag_start(service, path)`. The Windows SDL3 host installs
  the shared OLE `CF_HDROP` source from `alicorn:host/sdl3/file_drag`; hosts
  without a native source publish an empty service and the call returns false.
  File drops *into* a window remain a separate host input path delivered through
  `on_file_drop`.
- `scheduler` is a UI-thread-only `Application_Scheduler` with one replaceable
  `Frequent` and one replaceable `Opportunistic` deadline. Each hosted session
  publishes its own service, so a child surface schedules against its own
  runtime rather than the parent's. `Frequent` work runs at its deadline.
  `Opportunistic` work is deferred to 150 ms after the last keyboard, text,
  pointer, or scroll input, matching the reference host. The runtime clears
  the due class before `on_scheduled_wake` runs, so the callback may rearm it.
  `application_scheduler_stats` reports requests, coalesces, runs, deferrals,
  pending state, and maximum lateness. There is no task queue and no wake while
  no deadline is armed.

A host close request is delivered through `hosted_runtime_request_close`. A
missing callback returns `.Allow`, preserving immediate-close behavior. A
`.Defer` result means the host must keep the surface alive; the SDL3/WebGPU host
returns `Close_Deferred` from its event dispatch instead of `Close_Requested`.
Both native SDL3 hosts share `host/sdl3/dialogs`, so the dialog request,
copying, callback, and wake policy have one implementation rather than two.

`ui.run_hosted_config` adapts `Hosted_Run_State` to these fields, and
`ui/webgpu.run` exposes them with the same shapes. `ui.run` and the browser
`run` keep the host-owned-root callback contract: their `render` describes
content inside a host root. `ui/webgpu.run` uses `Hosted_Root_Ownership.Application`,
so its `render` owns the root exactly like `native/sdl_gpu`, and
`render_overlays` is described as a top-level layer after the application root
closes. Both `ui.run` entry points default `interaction_update_policy` to
`.Correct_After_Interaction`; pass `.Explicit` to keep host-driven invalidation
only. The hosted description loop mirrors the native bounded stabilization pass
limit (four descriptions). The browser host publishes ticks and scheduled wakes,
records the interaction policy, and has no file-drop or synchronous clipboard
event; its `UI_Host_Services.clipboard` remains asynchronous.

## Drag and drop

Three independent capabilities share this section because Scratchpad exercises
all three through the same application:

| Capability | Owner | Hosted path |
| --- | --- | --- |
| Move items inside the application | `runtime/drag_drop.odin` retained drag sessions | Same `Pointer_Event` route as the reference host (`hosted_runtime_pointer`) |
| Drag a file or folder out to another application | `alicorn:host/sdl3/file_drag` | `Hosted_Host_Services.file_drag` / `UI_Host_Services.file_drag` |
| Drop files from another application into the window | SDL3 `SDL_EVENT_DROP_FILE` | `hosted_runtime_file_drop` -> `on_file_drop` |

**Internal drag and drop.** Sources register with `drag_source`, targets with
`drop_target`, and both hosts dispatch through the retained runtime. The hosted
pointer route performs the same drag-event take/dispatch, autoscroll deadline,
preview presentation, and drop arbitration as the reference host; the fixture
`test_hosted_retained_drag_drop_between_targets_matches_the_reference_route`
compares the full Started/Target_Changed/Dropped sequence against
`process_pointer`.

**Drag out.** `File_Drag_Service` is a UI-thread-only
`application_file_drag_start(service, path)` call. The shared Windows
implementation is a minimal OLE `IDataObject`/`IDropSource` pair that advertises
one `CF_HDROP` path and answers `DROPEFFECT_COPY`; `native/sdl_gpu` delegates its
`Application_Services.file_drag` to the same package the hosted SDL3/WebGPU host
publishes. DoDragDrop is modal: it re-enters the owning thread's Windows message
loop and does not return until the user drops or cancels. While it runs, the
shared source marks itself active and both hosts suppress live-resize/expose
presentation (`sdl3_file_drag.is_active`). This is the drag equivalent of the
Stage C live-resize guard: the application is suspended inside its own pointer
callback, so rebuilding its retained description from a timer would re-enter
application state. The application must initiate the drag from its pointer
callback, exactly as the reference host requires.

The OLE source is Windows-only. Other platforms publish an empty service; the
call returns false and applications keep internal drag/drop and file drops.
There is no browser drag-out equivalent in this slice.

**Drop in.** The hosted SDL3 event loop routes `SDL_EVENT_DROP_FILE` to
`hosted_runtime_file_drop`, which copies the borrowed path into the callback
under the host-event cause and invalidates the description. The path is valid
only for `on_file_drop`. Native host fixtures push the same event through SDL's
queue (`native/sdl_gpu/file_drop_test.odin`); the hosted fixture does the same
through `host/sdl3/application_test.odin`.

## Native menus

`Hosted_Runtime_Config` carries `menus` and `menu_presentation`. Both
`Hosted_Run_State` and `ui.run`, `ui/webgpu.run` (and the browser `run` for
compile parity) accept `menus: []Menu` and
`menu_presentation: Menu_Presentation`.

```text
Hosted_Runtime_Config.menus         []Menu                (borrowed)
Hosted_Runtime_Config.menu_presentation  Menu_Presentation
```

The model lives in `runtime/menus.odin` so the SDL_GPU host, the hosted SDL3
host, and tests share one definition: `Menu`, `Menu_Item`, `Menu_Item_Kind`,
`Menu_Shortcut`, `Menu_Modifier(s)`, and `Menu_Presentation`. The
`Application_Menu*` names in `native/sdl_gpu` are aliases of these types.

Ownership follows the native host's documented contract exactly. Labels and
menu structure are snapshotted when the host prepares its native menu; the
`Action_State` in each borrowed item is read whenever a menu opens, an
accelerator matches, or a command is dispatched. Applications must keep the
borrowed slices stable and update state on the host's UI thread.

The shared policy in `runtime/menus.odin` is:

- `menu_match_shortcut` compares one printable key case-insensitively and
  requires an exact modifier set. `Primary` is Ctrl on Windows/Linux and
  Command on macOS; `Super` is the Windows key on Windows/Linux and Control on
  macOS. Disabled commands never match, and repeat key transitions are consumed
  without dispatching a second command.
- `menu_command_enabled` gates dispatch. A top-level direct command uses its
  borrowed description state; any other command requires at least one enabled
  borrowed item to carry that command and, when the Runtime has a registered
  action for the id, an enabled `Action_State`. Unknown ids remain dispatchable
  so hosts can forward chrome commands the application handles itself.
- `hosted_runtime_menu_command` applies that gate before it begins the
  `.Native_Command` cause, invokes `on_menu_command`, and invalidates the root.

`host/menus` adds the per-surface `Menu_Service` and the SDL3 adapters. The
service owns matching, the enabled gate, and safe-point dispatch; the adapter
owns presentation:

- Windows builds one HMENU tree, attaches it to the SDL window's HWND with
  `SetMenu`, refreshes enabled/checked state on `WM_INITMENUPOPUP`, and queues
  `WM_COMMAND` selections for dispatch after the event batch.
- macOS builds an NSMenu main menu (application, Window, application menus, and
  Help in AppKit's conventional order) and queues selected item tags.
- Linux keeps the descriptions as semantic accelerator metadata and creates no
  native menu, matching the reference host.

The SDL3/WebGPU event host calls `menu_service_try_shortcut` after overlay-key
handling and before application key/text routing, and skips it during an active
IME composition. `ui.run` on the SDL_GPU host receives the same descriptions
through `Application.menus`.

Menu presentation is policy, not a promise that labels are always painted.
`Menu_Presentation.Hidden` suppresses only Windows integrated-title-bar labels;
a system menu bar and the macOS main menu still show labels. The browser host has
no native menu yet; its accelerator and presentation TODO remains.

## Integrated title bar and application chrome

The hosted host shares the SDL_GPU chrome vocabulary:
`Window_Decoration_Mode` (`.System`, `.Integrated_Title_Bar`,
`.Content_Title_Bar`), `Window_Chrome_Metrics`,
`Window_Chrome_Region`/`Window_Chrome_Layout`, and
`Window_Chrome_Appearance`. The runtime defines them; `native/sdl_gpu`'s
`Application_*` names alias the same types.

```text
Hosted_Runtime_Config.window_decorations        Window_Decoration_Mode
Hosted_Runtime_Config.window_chrome_height      f32
Hosted_Runtime_Config.window_chrome_metrics     Window_Chrome_Metrics_Proc
Hosted_Runtime_Config.window_chrome_layout      Window_Chrome_Layout_Proc
Hosted_Runtime_Config.window_chrome_appearance  Window_Chrome_Appearance_Proc
Hosted_Runtime_Config.chrome_paint              Hosted_Chrome_Paint_Proc (host-owned)
Hosted_Runtime_Config.content_inset_top         f32
```

`ui.run`, `ui/webgpu.run`, and the browser `ui.run` accept the same
application-facing fields; the browser records decoration policy only.
Application callbacks describe ordinary retained nodes. The metrics callback
receives measured window-logical geometry before the first build and when
native geometry changes. The layout callback is sampled after description and
retained layout and returns a borrowed header node plus up to
`WINDOW_CHROME_REGION_CAPACITY` `Interactive`/`Window_Drag` regions.

Two coordinate modes exist:

- A host-owned band (no `window_chrome_layout`) sets `content_inset_top`.
  Application descriptions see a reduced viewport, pointer/wheel input over the
  band is withheld (a captured interaction stays clamped until cancellation),
  and presentation translates application paint below the band.
- An application-owned header (`window_chrome_layout` supplied) keeps the inset
  at zero. Interactive regions receive ordinary client input; only explicit
  `Window_Drag` regions become caption gestures.

Host chrome paint is appended after application paint during presentation; the
shared SDL3 pre-present hook samples layout and metrics in the same frame.
`Hosted_Runtime` exposes `hosted_runtime_set_content_inset`,
`hosted_runtime_content_inset`, `hosted_runtime_presentation_list`,
`hosted_runtime_pointer_cancel`, and host text resources
(`runtime_host_text_run_set/resolve/release`) for shaped menu/title runs.

On Windows, `host/menus` owns one HMENU/subclass construction path for both the
system menu bar and the integrated band. On macOS, `Content_Title_Bar` uses
AppKit full-size-content coordination; it is compile-checked but not yet
validated on a physical Mac in this slice.

### Secondary windows

`Hosted_Window_Description`/`Hosted_Window_Service` mirror the reference
`Application_Window_Description`/`Application_Window_Service` contract. A
description carries `title`, `width`, `height`, `always_on_top`, one
`Hosted_Runtime_Config` (all application callbacks, menus, chrome policy), and
`on_open_failed`; the service has `open`, `close`, `set_always_on_top`, and
`set_title`. `ui.run`, `ui/webgpu.run`, and the browser `run` expose the same
`UI_Host_Services.windows` value. Native hosts defer creation to an event-loop
safe point.

Each hosted child owns independent retained state:

- Its own `Hosted_Runtime`, viewport, `content_inset_top`, pointer/text/focus
  state, close-deferral result, dialog bridge, `on_scheduled_wake` class
  deadlines, and per-surface `scheduler`. The SDL3/WebGPU loop steps the
  primary and child and arms the earliest of their deadlines. The synchronous
  clipboard service is host-shared because SDL's clipboard is process-global.
- Its own menu service and accelerator matching. On Windows the per-window
  HMENU is attached to the child HWND; commands and accelerators are queued and
  dispatched to that child's `on_menu_command`. On macOS the main menu is
  process-global, so a hosted child keeps no separate native menu, matching the
  reference host; its chrome and callbacks remain per-window.
- Its own decoration policy, chrome metrics/layout/appearance callbacks, chrome
  regions, and host chrome paint. `Window_Drag` regions in a child are caption
  gestures for that child only; the content inset is published on the child's
  Runtime and applied to the child's presenter.
- Its own `Hosted_Host_Services.dialogs`, `.quit`, `.file_drag`, and
  `.scheduler`. A child close request is routed through the child's
  `on_close_requested`; `.Defer` keeps that child alive and the child's `quit`
  service completes shutdown. The child's scheduler owns that surface's
  deadlines; it does not arm the parent's scheduler. A child can start the same
  native drag; the modal-drag guard is per UI thread and therefore covers every
  hosted window while `DoDragDrop` owns the loop.

The SDL_GPU `ui.run` path keeps its reference behavior by bridging a hosted
description onto `Application_Window_Description`. That bridge preserves menus,
chrome callbacks (with the hosted application state), dialogs, close deferral,
and the window service. It cannot manufacture a `Hosted_Waker` from the native
`Application_Waker`, so a child `on_start` receives an empty hosted waker on the
reference path; `ui/webgpu.run` supplies the real per-window waker.


## Multiple outputs from one Runtime

A host that presents disjoint retained regions into separate native targets can
register one `Presentation_Output_ID` per target. This is useful when one
application Runtime owns related surfaces such as a ruler and waveform. Keep
the output roots disjoint and bind each root after its container is described:

```odin
ruler_output, ruler_status := alicorn.presentation_output_register(rt)
waveform_output, waveform_status := alicorn.presentation_output_register(rt)

// Inside the application's render procedure:
ruler_root := alicorn.container_begin(ui, .Container, key="ruler", style=ruler_style)
_ = alicorn.presentation_output_bind_root(ui.runtime, ruler_output, ruler_root)
describe_ruler(ui)
alicorn.container_end(ui)

waveform_root := alicorn.container_begin(ui, .Container, key="waveform", style=waveform_style)
_ = alicorn.presentation_output_bind_root(ui.runtime, waveform_output, waveform_root)
describe_waveform(ui)
alicorn.container_end(ui)
```

After `hosted_runtime_step`, `render_required` means at least one visible,
bound output has a published revision awaiting submission. The host tracks the
IDs it registered, checks `presentation_output_snapshot` for each one, and
submits only outputs whose snapshot has `pending=true`:

```odin
snapshot, status := alicorn.presentation_output_snapshot(rt, ruler_output)
if status == .Ok && snapshot.pending {
    if submit_ruler(commands, snapshot.root) {
        _ = alicorn.presentation_output_frame_submission_succeeded(
            rt, ruler_output, snapshot.revision,
        )
    }
}
```

The revision argument is required. A stale acknowledgement is rejected and
cannot clear a newer update. Acknowledge only after the target's submission
has succeeded. For a synchronous wx paint target, that is after its paint
callback completes successfully; for a GPU target, it is after the command
buffer is successfully submitted for that target. SDL defines
[`SDL_SubmitGPUCommandBuffer`](https://wiki.libsdl.org/SDL3/SDL_SubmitGPUCommandBuffer)
as submission for GPU processing; this receipt does not mean GPU work has
retired or that pixels have reached physical scanout. Manage GPU resources with
the presenter's fence/retirement path. A failed target submission must leave
its snapshot pending.

`frame_submission_succeeded` remains the whole-display acknowledgement for a
host that submits the complete Runtime display in one operation. Do not call it
after submitting only one of several targets: it acknowledges every currently
visible output. Per-target hosts acknowledge each output with its exact
snapshot revision.

`presentation_output_bind_root` accepts a root while it is being described and
rejects overlapping output subtrees. Retained paint changes and custom-surface
payload updates are attributed through their owner ancestry. A presentation
request outside every registered root is treated as shared chrome and marks
all outputs dirty. Normal root invalidation and layout still use the ordinary
Runtime path; no per-output scheduler or extra timer is created.

Call `presentation_output_set_visible` when a native target is hidden or
restored. Hidden outputs do not keep `frame_needs_submission` true and do not
block visible outputs from reaching idle. Restoring an output publishes its
current retained contents as a new pending revision. Unregister a permanently
removed target; if its retained root disappears first, Alicorn detaches that
root after the next description and drops its obsolete pending frame.

An output ID belongs to one Runtime and remains valid until that output is
unregistered or the Runtime is destroyed. IDs are not reused. If a native
target is recreated, unregister the old output and register a new one before
binding the new target's root. Visibility and acknowledgement changes belong on
the Runtime's UI thread and do not create another timer or polling loop.

The display-command accessor still returns the complete borrowed Runtime
display. A multi-target host is responsible for routing or clipping those
commands into its targets. Output IDs currently define scheduling and exact
acknowledgement boundaries; they do not create separate retained trees or GPU
resources. With no registered outputs, the existing whole-display
`frame_needs_submission` and acknowledgement behavior is unchanged.

## Deliver input, focus, and accessibility

Call these from the host's UI thread, in native event order:

| Host event | Runtime entry point |
| --- | --- |
| Pointer motion/button/cancel | `hosted_runtime_pointer` |
| Scroll or trackpad delta | `hosted_runtime_scroll` |
| Key transition for app shortcuts | `hosted_runtime_key` |
| Key transition mapped to `Application_Key` | `hosted_runtime_application_key` |
| Text navigation/edit key for an application-owned editor | `hosted_runtime_text_key` |
| Focus traversal | `hosted_runtime_focus_traverse` |
| Enter/Space activation | `hosted_runtime_activate` |
| Slider arrows/Home/End | `hosted_runtime_adjust_focused_slider`, `hosted_runtime_set_focused_slider_bound` |
| Text commit/preedit/cancel | `hosted_runtime_text_input` |
| Runtime text-field navigation/edit | `hosted_runtime_text_command` |
| Native focus gain/loss | `hosted_runtime_focus_changed` |
| Native accessibility action | `hosted_runtime_accessibility_action` |

After `hosted_runtime_pointer` processes a pointer event, it dispatches any
pending retained drag transition to the configured `on_drag` callback. The
application callback then runs through the same arbitration as
`native/sdl_gpu`'s event loop: `application_dispatch_pointer` offers the event to
interaction scopes first, a live drag consumes it (a captured split handle keeps
its callback so application-owned measurement can refresh), and an open context
menu owns pointer input. Hosts therefore see identical pointer ordering,
scope routing, and drag suppression on both stacks. Scroll capture is offered to
`on_scroll_capture` before retained scroll handling; unclaimed events go to the
retained regions and then `on_scroll`.

The host maps native key and modifier conventions. `Hosted_Key_Event.key_code`
is an opaque host-normalized value; Alicorn does not interpret SDL, wx, or
platform key constants. `hosted_runtime_key` only delivers that event to the
application key callback, so an external host's own numeric key space cannot
preempt a text field or an interaction scope.

A host that has already translated a key into Alicorn's `Application_Key`
vocabulary calls `hosted_runtime_application_key(host, key, event)` with the
typed value. The typed route applies the shared interaction-scope preemption
policy and the text-field/IME guard; if neither consumes the key, the
accompanying event, whose `key_code` remains opaque, reaches the application
callback. The SDL3 native host uses this route for its translated shortcuts.
The callback receives the current focused owner and whether the event is
pressed or repeating. It should return `true` when it consumes the event;
Alicorn then invalidates the application description. For Tab and activation
keys, route through the focus/activation helpers when the host's IME and
application shortcut policy allows it. The host remains responsible for not
stealing keys from an active IME composition.

Map editor navigation and deletion keys to `Application_Text_Key_Event` and
pass them to `hosted_runtime_text_key`. A focused application-owned
`text_input_target` receives the configured `on_text_key` callback; built-in
`Text_Field` controls continue through Alicorn's shared caret and selection
policy. Pass `composition_active=true` while native or browser IME composition
is active so those keys remain with the input method. The shared `ui.run`
adapter exposes the same callback as its optional `on_text_key` argument.

Text-field preedit selection is supplied to `hosted_runtime_text_input` as
character offsets and converted at the boundary. App-owned text-input targets
receive UTF-8 byte offsets in `Hosted_Text_Input_Event`. A `Text_Change` passed
to `on_text_change` is borrowed only for that callback. The value returned by
`hosted_runtime_text_command` is owned and must be released with
`text_change_destroy` and the Runtime that produced it.

On focus loss, `hosted_runtime_focus_changed` cancels active composition and
retained pointer capture/drag, hides the keyboard focus indicator, closes
context menus, and dismisses tooltips. The host receives the cancellation
through its pointer/drag callbacks. On focus gain, pass
`focus_visible=true` only when the platform's input modality calls for a
visible keyboard-focus treatment.

`hosted_runtime_semantic_snapshot` returns an owned snapshot; release it with
`semantic_snapshot_destroy`. Borrowed paint commands from
`hosted_runtime_display_commands` and a Runtime from `hosted_runtime_borrow`
remain valid only on the UI thread and only until the next Runtime mutation or
destroy. Prefer the specific session accessors over borrowing the Runtime.

## Resize, DPI, visibility, and teardown

After native resize or display-scale changes, call `hosted_runtime_resize`
with logical size, drawable pixel size, and the host's display/text scale
(SDL's `GetWindowDisplayScale`, CSS device-pixel-ratio, or the equivalent
platform content scale) - not the drawable-to-logical ratio. The session
updates the logical viewport, invalidates layout when needed, delivers the
display scale to the next application description, and sets independent X/Y
presentation scales from drawable-to-logical dimensions. A display-scale
change invalidates the description even when the logical size is unchanged,
because applications may size DPI-dependent GPU surfaces from the scale they
receive. Zero drawable dimensions are valid while minimized; the last
presentation scale is retained until a nonzero drawable size returns. Call
`hosted_runtime_set_renderable(false)` while the surface cannot present, then
restore it and step with the current monotonic time when it becomes renderable.

The SDL3 host wraps the same contract in
`sdl3_webgpu_application_apply_metrics`: it publishes window logical size,
drawable size, `SDL_GetWindowPixelDensity`, and `SDL_GetWindowDisplayScale`
together, reconfigures the surface, re-syncs the native chrome inset, and then
invalidation runs through `hosted_runtime_resize`. Ordinary SDL resize and
display-scale events call it after re-reading the window; transition fixtures
call it with an explicit measurement. `hosted_surface_presenter_metrics`
reports the configured logical/drawable sizes and both presentation scales for
diagnostics and acceptance checks. Interactive resize runs the same adoption
from `host/sdl3/live_resize_host.odin`, including scale-only changes while a
modal move/size loop owns the thread.

### Live resize and window movement

Interactive sizing is not an ordinary event turn. On Windows the platform runs a
modal loop from the moment the pointer grabs a frame edge or caption until
release, and the host's `WaitEventTimeout`/`PollEvent` call does not return.
A host that only reacts to queued `WINDOW_RESIZED` events therefore shows the
frame captured at grab time, scaled into the live window, for the whole drag.
macOS behaves similarly inside Cocoa's live-resize session.

The shared SDL3 host layer owns the mechanism that keeps frames flowing:
`host/sdl3/live_resize` (package `sdl3_live_resize`). It is renderer-neutral and
installs:

- an SDL event watch that services `WINDOW_EXPOSED` (`data1 == 1`) by calling the
  host's render callback directly. SDL documents that this one event may be
  redrawn from a watcher, and it arrives on the main thread;
- an opt-in dispatch of `WINDOW_RESIZED` / `WINDOW_PIXEL_SIZE_CHANGED` while the
  same slot's modal move is active (`live_resize_set_geometry_dispatch`). SDL
  derives these from `WM_WINDOWPOSCHANGED` after caching the new size, so a host
  that enables it adopts the new drawable at the message instead of waiting for
  the compositor's next exposure. The hosted WebGPU host enables it; the SDL_GPU
  reference leaves it off and keeps its exposure-driven policy. Measured on
  Windows, this is the difference between ~7.3 ms and ~2.6 ms at p50 (16.5 ms to
  7.3 ms at p95) from size message to the first correctly sized present on the
  fixture;
- on Windows, `SDL_SetWindowsMessageHook` tracking `WM_ENTERSIZEMOVE`,
  `WM_EXITSIZEMOVE`, `WM_MOVING`, `WM_WINDOWPOSCHANGED`, `WM_SIZE`, and
  `WM_SHOWWINDOW`, plus one `SetTimer` (17 ms) on the moving HWND while the left
  button is held. A `WM_WINDOWPOSCHANGED` that changes the outer size also records
  the instant the client geometry changed, so a frame that adopts it can report
  the message-to-present age (the interval in which the desktop still stretches
  the previous frame);
- re-entrancy guards for both entry points. An exposure or timer tick that lands
  while a frame is encoding is coalesced into the outer call's bounded second
  pass, and a timer callback nested inside a present is dropped with a counter;
- slot identity for a primary and one secondary window, so each window keeps its
  own move state and timer; and
- the counters hosts publish as live-resize telemetry.

Hosts implement `live_resize.Ops`: `window`, `renderable`, `has_work`, and
`render(slot, now_ns, cause)`. `has_work` gates timer installation, which is why a
plain window move with no retained motion does not spin: the timer stops as soon
as the visible slots settle, and `WM_EXITSIZEMOVE` (or the release reconciliation
that covers an exit message the modal loop consumed) retires the move state.

A live frame must do two things in this order: adopt the live geometry
(logical and pixel size, reconfigure the surface) and then run one presentation
opportunity. Presenting a rebuilt description into the previous swapchain size is
what produces the stretched last frame. In `host/sdl3` the live frame is
`sdl3_webgpu_application_live_step`, which calls
`hosted_runtime_live_step` rather than `hosted_runtime_step`.

`hosted_runtime_live_step` advances retained motion, rebuilds an invalidated
description (so an application-owned root is re-laid out at the live size), and
reports pending presentation. It deliberately does **not** dispatch `on_tick` or
application-scheduled wakes: those are host-loop turns, and running arbitrary
application work from inside a platform modal loop is not part of the contract.
`on_after_frame` still runs for each description it completes, because that
callback belongs to the description pass.

Hosts that own a device must also retire submissions while the modal loop holds
the thread. `hosted_surface_presenter_poll` drains finished queue work without
waiting, so the two-frame presentation budget does not stay saturated and a
`Retry_Later` can clear on the next live tick.

`native/sdl_gpu` uses the same core: its `window_move_windows.odin` is now an
adapter that supplies the reference renderer's frame through `live_resize.Ops`,
and its host telemetry reads the shared counters. Both renderers therefore run
one implementation of windowing, scheduling, and modal-loop dispatch.

Before shutdown, stop accepting native events, cancel host timers, and prevent
new renderer submissions. Ensure submitted frames no longer borrow Runtime
paint buffers. Then call `hosted_runtime_destroy` on the owning UI thread. It
closes the worker-wake gate, calls `on_stop`, destroys Runtime state, and
releases its own wake reference. `on_stop` must stop and join workers and
release every cloned waker before returning. A worker that outlives `on_stop`
can only issue safe no-op notifications while its clone remains retained; the
application must still join it before freeing worker-owned state. Finally,
release the renderer/device and native surface in the host's required order.
Discard any already queued wake event after the session is closed; it must not
invoke an application callback. Duplicate wake deliveries with no pending
notification do not invoke the wake callback. A host that recreates a session
at the same address must tag queued events with a host-owned lifetime identity
and discard events from the earlier session before delivering them.

## Diagnostics

Diagnostics are host-owned, exactly as they are in the reference SDL_GPU host.
`host/diagnostics` is the shared, renderer-neutral core: the fixed 256-sample
flight recorder, activity classification and HUD model, the performance-HUD
geometry, retained-bounds outline geometry, capture options/paths/bundles, the
versioned timeline export, and the JSONL breadcrumb recorder. It depends only on
`alicorn:runtime`, so every host builds the same overlay and schema.

A host supplies a quad/paint sink and its renderer identity. The reference
`native/sdl_gpu` host aliases the shared types in thin compatibility shims and
appends overlay quads to its own solid mesh. `host/sdl3` converts the same quads
into host-owned paint commands and installs them on the hosted runtime through
`Hosted_Runtime_Config.diagnostics_paint`. Applications never opt in:
`hosted_runtime_presentation_list` appends diagnostics after application paint
and host chrome, and every `ui/webgpu.run` consumer receives them.

The hosted runtime keeps the reference key contract:

- `F10` (without `Shift`) toggles the performance HUD. It is consumed after menu
  accelerators and before application key routing, so applications do not see
  it. The HUD reports retained work, recent activity class, stage counters, and
  frame timings from the presenter's bounded CPU timing samples.
- `F11` toggles retained-bounds inspection. It is a host effect and does not
  consume the key.
- `F12` requests one diagnostic capture. Repeated captures in one run are
  supported. It is also non-consuming.

Overlay frames are re-composites of the current retained display. They do not
mutate the Runtime, increment application `Frame_Stats`, or count as
application submissions; the presenter acknowledges an application revision
once. Overlay geometry is staged in a host-owned, reused command buffer so a
visible HUD does not allocate per frame.

Capture flags mirror the reference host: `--diagnostics` enables captures and
breadcrumbs, `--capture-after=SECONDS` enables an automatic capture,
`--capture-dir=PATH` selects the output root (and enables breadcrumbs), and
`--debug-bounds` starts with bounds inspection visible. Without
`--capture-dir`, captures use SDL's preference path for `Alicorn / Alicorn
Diagnostics`. A bundle contains `diagnostics.json`, `inspector.txt`,
`timeline.json`, `screenshot.ppm`, and `windows.json`.

Backend identity is always reported. The hosted path records
`"gpu_driver": "webgpu/<backend>"`, a `backend` object with the wgpu backend,
adapter type, vendor, device, and description, and per-pass WebGPU
`backend_counters` for solid, text, icons, images, and surfaces (mesh
rebuilds/cache hits, uploads, upload bytes, transforms, viewports, atlas and
texture uploads). The shared `gpu` block keeps the reference key names for
cross-renderer comparison.

Capture also covers the failing frame. When frame encoding or presentation
fails, `host/sdl3` writes the bundle before returning the failure: retained
state, pending commands, counters, and timeline do not depend on presentation.
The screenshot is rendered from the retained display into an offscreen target,
not the swapchain, so a failing acquire/present still yields an image. A
failure capture is an error artifact and is written even without the
`--diagnostics` flags.

`--test-diagnostics-sequence` drives F10 → F11 → capture → F10 off → F11 off →
capture → quit inside the real host loop for automated validation.
`--test-diagnostics-present-failure` injects one presentation-boundary encode
failure after the first frame and exercises the failure-capture path.

`inspector.txt` records the live local drag session and the paint commands its
preview contributes: `drag: phase=... source=... target=... position=...
preview=(mode=... ready=... WxH display-start=... commands=...)` followed by up
to 16 `preview[i] index= kind= bounds= clip= translation= opacity= text=` lines.
Both hosts describe the same drag preview for the same application, so a
mid-drag capture bundle from each can be compared command for command (example
16's `--tab-drag-smoke` + `tools/validate_native_webgpu_tab_drag.ps1`).

## Current boundary and integration gates

The headless hosted-session regression suite in `runtime/hosted_test.odin` and
`runtime/hosted_services_test.odin` exercises retained description and
submission acknowledgement, idle and one-shot deadlines, the per-surface
scheduler (arm/cancel/coalescing/class/lateness/opportunistic deferral), tick
cadence, file-drop routing, the synchronous clipboard roundtrip, resize and
independent drawable scales, hidden motion and restoration, drag-edge deadlines
and focus cancellation, corrective versus explicit description policy, UTF-8
preedit/commit and semantic actions, and worker-thread wake coalescing, failed
posts, owner-thread rejection, and shutdown. Run them as part of
`odin test runtime`. These tests validate the Runtime contract, not a native
wxWidgets surface or platform IME/AT integration.

Stage A is complete on the native hosted path. `host/sdl3` now supplies one
per-window implementation of native menus and accelerators, integrated
titlebar/chrome metrics and regions, file dialogs, deferred close/quit, and one
secondary window with its own chrome, menus, dialogs, close policy, input, and
deadline. Both `ui/webgpu.run` and the reference SDL_GPU `ui.run` expose those
services through `UI_Host_Services` and `Hosted_Window_Description`; the
reference path translates the hosted description at its boundary. See
[`webgpu-migration.md`](webgpu-migration.md) for the slice record and
[`validation/webgpu-chrome-interactive-windows-2026-11-19.md`](validation/webgpu-chrome-interactive-windows-2026-11-19.md)
for Windows interaction evidence.

This API still does not wrap a wx window in SDL, own a GPU device, or implement
a wx event adapter. The wx fixture still needs to validate surface
compatibility, event fairness, focus/IME, native accessibility, resize/DPI,
worker wakes, scheduled motion, and close ordering on target platforms. Keep
existing wx controls as fallbacks until their behavior matches, particularly
Audacity's specialized numeric selection fields. Audio and DSP callbacks must
never enter this UI API.

What remains before Scratchpad can retire its native-only window path is
browser-side and physical-platform work, not another hosted API shape: browser
menus/accelerators and browser dialog/close/file-drop services are still
unimplemented; the browser clipboard remains asynchronous (the native
synchronous shape is intentionally unavailable there); macOS chrome,
per-window menu policy, and pointer-sample pairing are compile-checked but
unrun on a physical Mac; Linux keeps semantic menu metadata only; and Snap
Layouts, mixed-DPI moves, and trackpad inertia still need hands-on Windows
records.

The hosted scheduler, synchronous clipboard, file drag-out and drop-in, tick,
and interaction policy now mirror the reference host. `Hosted_Host_Services`
publishes `windows`, `dialogs`, `quit`, `clipboard`, `file_drag`, and a
per-surface `scheduler`;
`Hosted_Runtime_Config` carries `on_file_drop`, `on_tick`, and
`interaction_update_policy`. `on_tick` is a bounded ~60 Hz callback backed by a
one-shot hosted deadline rather than the native host's 1 ms delay pump; that is
observably equivalent for application work (the callback still runs at the same
16.67 ms minimum spacing) but it never becomes an idle poll. The reference
SDL_GPU `ui.run` path continues to use its native scheduler directly.

The remaining hosted service gap is browser clipboard consumption: a browser
application must use the asynchronous `UI_Host_Services.clipboard` request and
completion API rather than the synchronous native calls. Native WebGPU keeps
Scratchpad's existing synchronous call sites working unchanged.

The fixture is separate from plugin editor child-window attachment in
[#121](https://github.com/Carnival-Science/Alicorn/issues/121) and renderer
neutral frame boundaries in
[#162](https://github.com/Carnival-Science/Alicorn/issues/162). See the
[#196 source and ownership research](research/issue-196-host-loop-integration.md)
for the existing SDL lifecycle map and platform risks.
