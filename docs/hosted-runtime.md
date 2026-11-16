# Host-owned UI loops

`alicorn:runtime` exposes a retained session for an application that already
owns a native window and event loop. The host creates one `Hosted_Runtime` per
surface, delivers native input on its UI thread, calls a nonblocking step, and
submits the resulting paint commands through its renderer. The SDL `ui.run`
and `host.Run` entry points remain available and unchanged.

This is a Runtime lifecycle boundary, not a ready-made wxWidgets adapter. The
host still owns its window, event translation, renderer/device, clipboard,
dialogs, native text-input service, and native accessibility bridge. In
particular, a host must prove that its chosen renderer can present into its
surface and that native IME and accessibility behavior remain correct.

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

`render` describes the application content inside Alicorn's root. It does not
call `begin_frame` or `end_frame`; the session does that. `on_initialize` runs
after Runtime creation and before the first description, so it can install
application fonts. `on_start` runs before the first step.

```odin
import alicorn "alicorn:runtime"
import "core:fmt"

App :: struct { count: int }
Host_Context :: struct {}

describe :: proc(data: rawptr, ui: ^alicorn.UI, width, height: int, dpi: f32) {
	app := (^App)(data)
	if alicorn.container_begin(
		ui,
		.Column,
		key="hosted-content",
		style=alicorn.layout_style(.Column, padding=24, gap=12),
	) != 0 {
		alicorn.text(ui, "Hosted by the application", key="heading")
		alicorn.text(ui, fmt.tprintf("Count: %d", app.count), key="count")
		alicorn.container_end(ui)
	}
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
retained motion, tooltips, notices, drag-edge autoscroll, and the optional application deadline,
then performs at most one application description. `next_wake_ns` is the
earliest one-shot deadline Alicorn currently needs. `has_more_work` reports
work that requires another step; a pending frame is reported separately by
`render_required`. After a successful renderer submission, acknowledge it
once. If submission fails, do not acknowledge it; the host owns a bounded
retry policy and any GPU/device recovery.

The host should use one monotonic clock for `step`, pointer timestamps, and
deadlines. `hosted_runtime_set_deadline` installs or replaces one application
deadline; zero cancels it. The scheduled callback may install the next
deadline. There is no recurring tick when the Runtime is idle.
An application deadline remains armed while the surface is hidden; retained
motion, tooltip, notice, and drag-autoscroll sampling pause until the surface
becomes renderable. Hidden steps can still process model invalidation, but
never report `render_required`. Restoration requests a retained presentation
and samples the current monotonic time, without replaying missed ticks.
The Runtime cannot observe arbitrary application memory. If `on_wake`,
`on_scheduled_wake`, `on_drag`, or `on_scroll` changes data used by the next
description, that callback must call `invalidate_root` on its supplied Runtime.
`on_key` returning `true`, application-owned text input, and pointer button
callbacks already request a description.

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
| Focus traversal | `hosted_runtime_focus_traverse` |
| Enter/Space activation | `hosted_runtime_activate` |
| Slider arrows/Home/End | `hosted_runtime_adjust_focused_slider`, `hosted_runtime_set_focused_slider_bound` |
| Text commit/preedit/cancel | `hosted_runtime_text_input` |
| Runtime text-field navigation/edit | `hosted_runtime_text_command` |
| Native focus gain/loss | `hosted_runtime_focus_changed` |
| Native accessibility action | `hosted_runtime_accessibility_action` |

After `hosted_runtime_pointer` processes a pointer event, it dispatches any
pending retained drag transition to the configured `on_drag` callback. Scroll
capture is offered to `on_scroll_capture` before retained scroll handling;
unclaimed events go to the retained regions and then `on_scroll`.

The host maps native key and modifier conventions. `Hosted_Key_Event.key_code`
is an opaque host-normalized value; Alicorn does not interpret SDL, wx, or
platform key constants. The key callback receives the current focused owner
and whether the event is pressed or repeating. It should return `true` when
it consumes the event; Alicorn then invalidates the application description.
For Tab and activation keys, route through the focus/activation helpers when
the host's IME and application shortcut policy allows it. The host remains
responsible for not stealing keys from an active IME composition.

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
with logical size, drawable pixel size, and the host's logical DPI/text scale.
The session updates the logical viewport, invalidates layout when needed, and
sets independent X/Y presentation scales from drawable-to-logical dimensions.
Zero drawable dimensions are valid while minimized; the last presentation
scale is retained until a nonzero drawable size returns. Call
`hosted_runtime_set_renderable(false)` while the surface cannot present, then
restore it and step with the current monotonic time when it becomes renderable.

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

## Current boundary and integration gates

The headless hosted-session regression suite in `runtime/hosted_test.odin`
exercises retained description and submission acknowledgement, idle and one-shot
deadlines, resize and independent drawable scales, hidden motion and restoration,
drag-edge deadlines and focus cancellation, UTF-8 preedit/commit and semantic
actions, and worker-thread wake coalescing, failed posts, owner-thread rejection,
and shutdown. Run it as part of `odin test runtime`. These tests validate the
Runtime contract, not a native wxWidgets surface or platform IME/AT integration.

This API does not wrap a wx window in SDL, own a GPU device, provide native
clipboard/dialog services, or implement a wx event adapter. It establishes a
single-threaded retained Runtime lifecycle and input boundary so those pieces
can be prototyped without creating another Runtime per control. The wx fixture
still needs to validate surface compatibility, event fairness, focus/IME,
native accessibility, resize/DPI, worker wakes, scheduled motion, and close
ordering on target platforms. Keep existing wx controls as fallbacks until
their behavior matches, particularly Audacity's specialized numeric selection
fields. Audio and DSP callbacks must never enter this UI API.

The fixture is separate from plugin editor child-window attachment in
[#121](https://github.com/samanshaiza004/alicorn/issues/121) and renderer
neutral frame boundaries in
[#162](https://github.com/samanshaiza004/alicorn/issues/162). See the
[#196 source and ownership research](research/issue-196-host-loop-integration.md)
for the existing SDL lifecycle map and platform risks.
