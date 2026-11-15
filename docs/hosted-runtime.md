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
retained motion, tooltips, notices, and the optional application deadline,
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
motion, tooltip, and notice sampling pause until the surface becomes renderable.
The Runtime cannot observe arbitrary application memory. If `on_wake`,
`on_scheduled_wake`, `on_drag`, or `on_scroll` changes data used by the next
description, that callback must call `invalidate_root` on its supplied Runtime.
`on_key` returning `true`, application-owned text input, and pointer button
callbacks already request a description.

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

On focus loss, `hosted_runtime_focus_changed` cancels active composition, hides
the keyboard focus indicator, and dismisses tooltips. On focus gain, pass
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
invoke an application callback.

## Current boundary and integration gates

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
