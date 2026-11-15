# Issue #196 — integrate Alicorn with a desktop host loop

Research snapshot: 2026-11-15. Source inspection only; no tests were run.

## Finding

The smallest credible boundary is a retained host session with explicit
`open`, nonblocking `step`, and `close` operations, all driven on the existing
wx UI thread. The session should own one Alicorn `Runtime` and its SDL_GPU
resources for the lifetime of one surface; the host should own event-loop
timing, native-window lifetime, and wake delivery. `step` should consume a
bounded batch of host events, run due UI work, and submit at most the pending
frame. It should return whether more immediate work remains and the earliest
deadline the host must schedule. A worker wake should post a wx event; it must
not call UI callbacks or render from the worker.

The current implementation cannot become this session by deleting its
blocking wait alone. `pump_events` reads SDL's queue directly, and the SDL
event dispatcher owns keyboard, pointer, focus, text/IME, resize, and close
routing. A wx adapter needs an explicit event ingress path, an SDL-compatible
surface strategy, and host-provided service/wake adapters. Keep the standalone
`Run` behavior available as the owner of its existing loop. [Current host
entry and loop](../../native/sdl_gpu/main.odin),
[event pump](../../native/sdl_gpu/event_dispatch.odin),
[SDL event retrieval](../../native/sdl_gpu/pointer_input.odin).

## Requirements from the issue

[Issue #196](https://github.com/samanshaiza004/alicorn/issues/196) calls for a
small wxWidgets fixture that keeps one UI thread and one primary event loop,
then hosts an Alicorn view through one of three modes: host-owned window and
loop with a step API; an Alicorn-owned SDL window stepped from the host loop;
or a separate process only if in-process ownership cannot be made safe. The
research must inventory event/input, wake, frame, clipboard/dialog,
accessibility, renderer-resource, and shutdown ownership. It must define
bounded event draining, idle and scheduled wakes, resize/DPI, focus/IME,
device loss, and teardown. Acceptance includes open, resize, focus, keyboard,
pointer, close, worker wakes, scheduled motion, no idle spin, UI-thread
callbacks, and no callbacks after teardown.

The issue distinguishes this work from [#121](https://github.com/samanshaiza004/alicorn/issues/121),
which investigates plugin-editor child-window attachment, and [#162](https://github.com/samanshaiza004/alicorn/issues/162),
which investigates a renderer-neutral frame boundary. The first wx proof
should reuse the current retained runtime and SDL_GPU renderer where feasible;
it should not become either a plugin wrapper or a renderer rewrite.

Two comments add concrete Audacity gates. The first reports that its current
button adapter creates separate runtimes and font state per view, and asks for
one retained surface with multiple controls and shared runtime/resources
([comment](https://github.com/samanshaiza004/alicorn/issues/196#issuecomment-6889700448)).
The second requires the Selection Toolbar's two specialized
`NumericTextCtrl`s to preserve Start/End, Start/Length, Length/End, and
Length/Center modes, localized format changes, digit editing/stepping, focus,
per-digit accessibility, and `ProjectSelectionManager` semantics. It calls
for committed text, preedit/cancel, navigation keys, accessible value/name/
focus, selection, and control lifetime; keep the wx editor as fallback until
that contract passes ([comment](https://github.com/samanshaiza004/alicorn/issues/196#issuecomment-6893307826)).
That comment describes Acetate's C ABI gap. This repository's Odin `Application`
surface already declares text-input and text-key callbacks, while the SDL host
currently supplies their native event path; a wx/C ABI adapter still needs to
prove the complete caret, selection, and IME behavior.

## Current standalone ownership

| Concern | Current owner and behavior |
| --- | --- |
| Window, SDL, GPU, and runtime creation | `native_run_application` initializes SDL video, creates a high-DPI SDL window, creates and claims an SDL_GPU device, constructs one `Runtime`, loads default fonts, and creates text/surface/solid renderers. It synchronously enters `run_application_loop`; its deferred cleanup owns the SDL window, GPU device, renderers, and runtime. [`main.odin`](../../native/sdl_gpu/main.odin) |
| Application and retained state | The host borrows `Application.state` through callbacks. The `Runtime` retains node, interaction, geometry, semantic, text, paint, image, and GPU-facing state; it does not retain the app-state pointer. The top-level host creates one runtime per window; secondary windows create independent runtimes while sharing the host GPU device. [`application_api.odin`](../../native/sdl_gpu/application_api.odin), [`runtime_init.odin`](../../runtime/runtime_init.odin), [`secondary_window_host.odin`](../../native/sdl_gpu/secondary_window_host.odin), [architecture](../architecture.md) |
| Event loop and input | `run_application_loop` owns the loop. `pump_events` optionally blocks in `SDL_WaitEvent`/`SDL_WaitEventTimeout`, then drains SDL events through `native_event_next`; the normal drain continues until the SDL queue is empty, with a secondary-window queue-full exception rather than a general event budget. Event dispatch handles key, pointer, scroll, focus/capture cancellation, text commit/preedit, file drop, close requests, and window changes. Darwin explicitly pumps AppKit before peeking SDL's translated queue. [`application_loop.odin`](../../native/sdl_gpu/application_loop.odin), [`event_dispatch.odin`](../../native/sdl_gpu/event_dispatch.odin), [`pointer_input.odin`](../../native/sdl_gpu/pointer_input.odin), [`events_darwin.odin`](../../native/sdl_gpu/events_darwin.odin) |
| Worker and native wakes | `Application_Waker` is borrowed, thread-safe, and currently pushes a registered SDL user event. A separate host-event waker handles native redraw requests. The loop dispatches app callbacks on the UI thread. `on_stop` must join every worker using the borrowed waker before it is retired. [`application_api.odin`](../../native/sdl_gpu/application_api.odin), [`application_host.odin`](../../native/sdl_gpu/application_host.odin), [reference](../reference.md) |
| Scheduled work and idle | `Application_Scheduler` owns one replaceable `Frequent` and one `Opportunistic` deadline; opportunistic work waits for 150 ms of input quiet. Retained motion has a separate approximately 60 Hz deadline and suspends while the window is unavailable. The loop chooses the earliest among these and other host deadlines, then waits for an event or timeout. The default event-driven path sleeps when settled; `on_tick` opts into recurring 60 Hz callbacks. [`application_api.odin`](../../native/sdl_gpu/application_api.odin), [`scheduling.odin`](../../native/sdl_gpu/scheduling.odin), [`application_loop.odin`](../../native/sdl_gpu/application_loop.odin), [architecture](../architecture.md) |
| Frame and GPU lifetime | The loop checks retained work, acquires the SDL swapchain, encodes paint, submits a GPU command buffer, and tracks fences with a two-frame in-flight limit. Runtime resources persist across event-loop iterations. The existing standalone path has no explicit host-level device-loss/recreation branch; the architecture's note that image pixels can recreate textures after device recreation is not a complete session-recovery contract. [`application_loop.odin`](../../native/sdl_gpu/application_loop.odin), [`gpu_frame.odin`](../../native/sdl_gpu/gpu_frame.odin), [architecture](../architecture.md) |
| Resize and DPI | SDL window events trigger a coherent reread of logical dimensions, pixel dimensions, pixel density, and display scale. `native_window_metrics_apply` updates the runtime viewport, invalidates description for logical/display-scale changes, and sets independent X/Y presentation scales. Live resize has a direct redraw event watch and a Windows move/resize hook. [`event_dispatch.odin`](../../native/sdl_gpu/event_dispatch.odin), [`window_host.odin`](../../native/sdl_gpu/window_host.odin) |
| Text and IME | The SDL host owns native text-session focus, composition cancellation/transfer, and candidate-window geometry. It converts SDL text input/editing into commit, preedit, and cancel handling; focus loss cancels composition. The Odin `Application` API exposes text-input and text-key callbacks, but these are currently reached through SDL dispatch. Cocoa also has a process-wide text-input coordinator across Alicorn windows. [`application_api.odin`](../../native/sdl_gpu/application_api.odin), [`text_input_host.odin`](../../native/sdl_gpu/text_input_host.odin), [`event_dispatch.odin`](../../native/sdl_gpu/event_dispatch.odin) |
| Clipboard, dialogs, accessibility | `on_services` receives SDL-backed clipboard, file-dialog, file-drop, scheduler, motion-clock, quit, and secondary-window services. Dialog completion copies results and wakes the SDL loop; clipboard calls are UI-thread-only. The AccessKit adapter is attached to the SDL native window on Windows/macOS and queues accessibility actions back to the host; the current repository has no Linux native adapter. A wx host must choose whether wx or Alicorn owns each native service and provide a tested adapter. [`dialogs.odin`](../../native/sdl_gpu/dialogs.odin), [`clipboard.odin`](../../native/sdl_gpu/clipboard.odin), [`accessibility_accesskit.odin`](../../native/sdl_gpu/accessibility_accesskit.odin), [architecture](../architecture.md), [reference](../reference.md) |
| Shutdown | The loop removes resize hooks, destroys secondary windows, shuts down accessibility, waits for GPU idle and retires effect resources, shuts down dialog callbacks, relinquishes native text input, then calls `on_stop` while the application waker remains live. It deactivates scheduling/wakers and releases outstanding fences; outer `Run` defers renderer, runtime, window, and device cleanup. This ordering is a lifetime contract for a stepped session, not incidental loop structure. [`application_loop.odin`](../../native/sdl_gpu/application_loop.odin), [`main.odin`](../../native/sdl_gpu/main.odin), [`dialogs.odin`](../../native/sdl_gpu/dialogs.odin) |

## Smallest safe host-owned stepping API

Keep the API to one per-surface session and four operations:

```text
session_open(application, host_surface, host_services, post_wake) -> Session
session_handle_event(session, Host_Event)                   // owning UI thread
session_step(session, monotonic_now) -> Step_Result          // nonblocking
session_close(session)                                      // owning UI thread

Step_Result = { has_more_work, next_deadline, close_requested, status }
```

`Host_Event` should cover only the events needed for the first contract:
resize/scale, expose/visibility, focus, close, keyboard/navigation, pointer,
text commit/preedit/cancel, and accessibility actions. Delivery order must be
preserved, including text commits that precede focus loss. One `session_step`
handles a bounded event batch and one presentation opportunity. If queued
events or retained work remain, it returns `has_more_work` so wx posts another
immediate event rather than monopolizing its dispatcher. When no work remains,
the host arms a single one-shot timer for `next_deadline`; with no deadline it
waits on wx normally. The deadline must be the earliest of app scheduling,
retained motion, drag autoscroll, tooltip/notice, and any bounded retry that
still requires a wake. Do not use `on_tick` as an idle pump.

`post_wake` is the session's thread-safe, borrowed wake callback. It posts a
custom wx event only; `on_wake`, event handling, runtime mutation, layout,
accessibility synchronization, and GPU submission stay on the owning UI
thread. `host_services` supplies explicit clipboard/dialog/accessibility
adapters and a consistent monotonic clock. Unsupported service or window
combinations return a clear status during `session_open`; they do not silently
fall back to polling. One session owns one shared runtime for all controls on
that surface. Keep app code and format/selection policy in Audacity.

Keep SDL_GPU as the renderer for the first proof. SDL3 documents wrapping an
existing native window through `SDL_CreateWindowWithProperties` on Windows,
macOS, X11, and Wayland, and documents that claiming a window for SDL_GPU must
occur on the thread that created the SDL window. The current Alicorn bootstrap
always calls `SDL_CreateWindow` and owns `SDL_Init`/`SDL_Quit`, so wrapping a wx
surface and coexisting with its event pump are unimplemented integration
points that the fixture must validate. [SDL3 window wrapping](https://wiki.libsdl.org/SDL3/SDL_CreateWindowWithProperties),
[SDL_GPU window claim](https://wiki.libsdl.org/SDL3/SDL_ClaimWindowForGPUDevice),
[current bootstrap](../../native/sdl_gpu/main.odin).

If wrapping the wx surface proves incompatible on the first target, a stepped
Alicorn-owned SDL window is a useful narrower loop-integration experiment; it
does not establish native-window ownership or main-content replacement. A
separate process is the fallback only after the in-process thread/lifetime
contract fails, because IPC would add input, text/IME, accessibility, and
presentation boundaries.

For close, stop accepting host events and cancel wx timers first. Quiesce
native dialog/accessibility callbacks, relinquish text composition, and call
`on_stop` while the worker waker is still valid so producers can join. Then
deactivate all wake sources, drain submitted GPU work, release renderer/runtime
resources, and return control to the host so it can destroy its native surface.
No callback may retain session-owned state after `session_close` returns.

## Risks and explicit non-goals

- The current SDL event pump is not budgeted and does not accept wx events. A
  step method without an event adapter cannot meet the wx keyboard, pointer,
  focus, close, or IME acceptance cases. Bounded draining and fair rescheduling
  are new contract requirements. [`event_dispatch.odin`](../../native/sdl_gpu/event_dispatch.odin),
  [`pointer_input.odin`](../../native/sdl_gpu/pointer_input.odin)
- SDL initialization, Cocoa pumping, event translation, and native-window
  ownership may conflict with wx's own dispatcher. Validate each platform
  before presenting the mode as portable. `events_darwin.odin` documents that
  SDL pumping dispatches through `NSApplication`.
- Returning one deadline must cover every existing wake source. Missing a
  motion, tooltip, scheduled callback, dialog result, or native redraw deadline
  can leave stale UI; a periodic fallback timer would violate idle acceptance.
- A host surface wrapper, swapchain/device loss, and destruction order need
  per-platform evidence. The current one-shot device setup does not specify
  recovery. A Runtime retaining CPU image data does not prove that all SDL_GPU
  resources can be restored.
- wx/native text input must preserve commit, preedit, cancellation, candidate
  area, selection/caret, navigation, and focus transfer. The specialized
  Audacity selection controls must keep their formatter and selection policy;
  a plain text field is not an equivalent replacement.
- Accessibility ownership must be singular per native surface. The current
  AccessKit adapter is Windows/macOS-specific and tied to SDL window handles;
  the wx fixture must verify exposed value/name/focus/actions and prevent
  duplicate or stale accessibility callbacks.
- Real-time audio and DSP are explicitly out of scope. Audio callbacks never
  call `session_step`, touch Runtime/GPU/native UI services, block, or send
  audio data through `Application_Waker`. The existing worker waker is a UI
  event request, not an audio transport or real-time scheduling guarantee.
- Also out of scope: a renderer rewrite, renderer-neutral frame protocol,
  plugin wrapper, arbitrary cross-platform GUI embedding protocol, and
  replacing standalone `Run` as the default host. See the separate scopes in
  [#121](https://github.com/samanshaiza004/alicorn/issues/121) and
  [#162](https://github.com/samanshaiza004/alicorn/issues/162).

## Relevant symbols and files

| Symbol or area | File |
| --- | --- |
| `Run`, `native_run_application` | [`native/sdl_gpu/main.odin`](../../native/sdl_gpu/main.odin) |
| `run_application_loop`, host setup, deadlines, frame submission, shutdown | [`native/sdl_gpu/application_loop.odin`](../../native/sdl_gpu/application_loop.odin) |
| `Application`, `Application_Waker`, scheduler, event callback types | [`native/sdl_gpu/application_api.odin`](../../native/sdl_gpu/application_api.odin) |
| `pump_events`, input/focus/text/resize/close dispatch | [`native/sdl_gpu/event_dispatch.odin`](../../native/sdl_gpu/event_dispatch.odin) |
| `poll_sdl_event`, `native_event_next` | [`native/sdl_gpu/pointer_input.odin`](../../native/sdl_gpu/pointer_input.odin) |
| `Window_Metrics`, `native_window_metrics_apply`, live resize | [`native/sdl_gpu/window_host.odin`](../../native/sdl_gpu/window_host.odin) |
| `Application_Services`, dialog and clipboard service implementations | [`native/sdl_gpu/dialogs.odin`](../../native/sdl_gpu/dialogs.odin), [`native/sdl_gpu/clipboard.odin`](../../native/sdl_gpu/clipboard.odin) |
| SDL text focus, composition, and candidate geometry | [`native/sdl_gpu/text_input_host.odin`](../../native/sdl_gpu/text_input_host.odin) |
| AccessKit native host lifecycle | [`native/sdl_gpu/accessibility_accesskit.odin`](../../native/sdl_gpu/accessibility_accesskit.odin) |
| Retained runtime lifetime and presentation model | [`runtime/runtime_init.odin`](../../runtime/runtime_init.odin), [`runtime/reconcile.odin`](../../runtime/reconcile.odin), [architecture](../architecture.md) |
| `ui.run`, typed lifecycle wrapper, `ui.wake` | [`ui/ui.odin`](../../ui/ui.odin), [API reference](../reference.md) |
