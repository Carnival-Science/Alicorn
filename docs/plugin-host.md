# Embeddable plugin editors

`alicorn:host/plugin` is the narrow Windows Phase B adapter for hosting an
Alicorn UI inside an **externally owned** native window. It is for plugin hosts
and applications that already own the outer window, the message loop, and the
GPU device. It is not `ui.run`, not `host.Run`, and it does not change the
standalone SDL hosts.

The package creates one `WS_CHILD` HWND per editor, creates a WebGPU surface
directly from that HWND, binds one `Hosted_Runtime` and one
`Hosted_Surface_Presenter` to it, and routes only that child window's input into
that runtime. The host fixture in
`tests/fixtures/plugin_host` is a plain Win32 parent with no SDL dependency.

## Status

| Platform | Phase B status |
| --- | --- |
| Windows 10/11 | Implemented and fixture-validated (D3D12 real GPU; Vulkan real GPU) |
| macOS | Typed `Unsupported_Platform`; use a floating editor window |
| Linux X11 | Typed `Unsupported_Platform`; use a floating editor window |
| Linux Wayland | Typed `Unsupported_Wayland`; CLAP's documented floating-editor fallback |

`plugin_capabilities()` reports the compiled contract before an editor is
created. `plugin_status_string()` names the fallback in host logs. The package
never creates a hidden top-level window to imitate an embedded child.

## SDL 3.4.20 parent finding

The pinned SDL is 3.4.20 (`docs/getting-started.md`, `tools/package_app.ps1`).
That version exposes `SDL_PROP_WINDOW_CREATE_PARENT_POINTER`, but its value is an
`SDL_Window *`, not a foreign `HWND`. It also exposes
`SDL_PROP_WINDOW_CREATE_WIN32_HWND_POINTER` for wrapping an existing HWND with
`SDL_PROP_WINDOW_CREATE_EXTERNAL_GRAPHICS_CONTEXT_BOOLEAN`.

Wrapping the plugin host's parent HWND in an SDL window would hand SDL ownership
of the host's window and event behavior, which is exactly the ownership the
plugin host must keep. A `WS_CHILD` HWND created directly by the plugin host is
the correct boundary. The Windows implementation therefore uses
`InstanceCreateSurface` with `wgpu.SurfaceSourceWindowsHWND` and does not link
SDL for its window, surface, or input path.

## API surface

```odin
import plugin "alicorn:host/plugin"

host: plugin.Plugin_Host
status := plugin.plugin_host_init(&host, plugin.plugin_host_config_clear())

editor: plugin.Plugin_Editor
status = plugin.plugin_host_create_editor(&host, &editor, plugin.Plugin_Editor_Config{
    parent=plugin.Plugin_Native_Parent{
        kind=.Windows_HWND,
        window=rawptr(parent_hwnd),
        display=rawptr(hinstance), // optional
    },
    logical_width=480,
    logical_height=320,
    dpi_scale=1.5,
    visible=true,
    hosted=alicorn.Hosted_Runtime_Config{
        state=rawptr(&app),
        render=render,
        on_initialize=load_fonts,
        on_after_frame=after_frame,
    },
})
```

Editor lifecycle and scheduling:

```text
plugin_host_init / plugin_host_destroy
plugin_host_create_editor / plugin_host_destroy_editor
plugin_editor_attach(editor, parent)
plugin_editor_show / plugin_editor_hide
plugin_editor_resize(logical_w, logical_h, dpi_scale)
plugin_editor_resize_pixels(pixel_w, pixel_h, dpi_scale)
plugin_editor_request_presentation
plugin_host_step(host, plugin_monotonic_now_ns())
plugin_host_next_wake_ns / plugin_host_has_in_flight / plugin_host_poll
plugin_host_simulate_device_loss / plugin_host_recover
plugin_editor_native_window / plugin_editor_metrics
```

The host owns one shared WebGPU instance, adapter, device, and queue. Each
editor owns its child HWND, surface, swapchain, presenter, `Hosted_Runtime`,
retained motion deadline, scheduler, input/focus state, and optional
accessibility projection. Closing one editor does not retire another editor's
runtime, atlas, or renderer resources. The renderer/device remain alive until
`plugin_host_destroy`.

`Plugin_Editor_Config.hosted` is passed through with four host-owned overrides:
dimensions, `dpi_scale`, `post_wake` (posts `WM_APP + 0x1211` to the child), and
`monotonic_now` (the same clock as `plugin_monotonic_now_ns`). All application
callbacks, host services, menus, bindings, diagnostics paint, and
`interaction_update_policy` are unchanged from `Hosted_Runtime_Config`.

`plugin_monotonic_now_ns()` is the one clock for `plugin_host_step`, pointer
timestamps, and deadlines. Do not mix it with SDL ticks or wall-clock time.

## Event loop contract

The host's normal message pump remains authoritative. The child HWND receives
its own `WM_MOUSEMOVE`, `WM_LBUTTONDOWN/UP`, `WM_RBUTTONDOWN/UP`,
`WM_MBUTTONDOWN/UP`, `WM_MOUSEWHEEL`, `WM_KEYDOWN`, `WM_CHAR`,
`WM_SETFOCUS`/`WM_KILLFOCUS`, `WM_SIZE`, and `WM_SHOWWINDOW`. The plugin's
window procedure translates those into the hosted runtime. There is no global
filter, no SDL event watcher, and no second input queue.

```text
drain a bounded batch of host messages (DispatchMessage routes child input)
result = plugin_host_step(host, plugin_monotonic_now_ns())
plugin_host_poll(host) when plugin_host_has_in_flight(host)
if result.has_more_work: immediate turn
else if has_in_flight: retry ~1 ms
else if result.next_wake_ns != 0: arm one host timer for that deadline
else: wait for native input, a child wake, or a worker wake
```

A hidden editor is inert for presentation: `plugin_editor_hide` sets the
presenter invisible and the runtime renderable flag false. Retained model work
can still run, but `step.render_required` is false and no submission occurs.
An occluded surface (`.Hidden`) does not schedule a retry; the host calls
`plugin_editor_request_presentation` on restore. A settled visible editor
publishes no deadline and no immediate work.

## Input, focus, and IME boundary

Scoped translation covers pointer move/down/up/cancel, double-click counts,
capture loss, wheel ticks, Tab focus traversal, Enter/Space activation,
application key translation, normal text-key intents, and `WM_CHAR`/`WM_IME_CHAR`
committed text. Each child has its own focus and capture state, so clicking one
editor cannot move another editor's pointer or focus stream.

Phase B does **not** implement inline IME composition/preedit. Committed IME
characters that arrive as `WM_CHAR`/`WM_IME_CHAR` are delivered, but composition
candidate placement, preedit read-back, and `Imm32` composition windows are not.
`plugin_capabilities().ime_composition` is false. A host that needs rich IME
must keep a validated floating editor or contribute the platform composition
adapter; the package does not claim parity with the SDL host's IME path.

## Host services

`Hosted_Host_Services` is host-mediated exactly as in the standalone hosted
path. The plugin supplies the per-editor scheduler and wake path; the embedding
host supplies clipboard, dialogs, file drag, window services, and quit policy
through `Hosted_Runtime_Config.host_services`. The fixture leaves dialogs and
file drag empty. A Windows host can reuse `alicorn:host/sdl3/file_drag` for its
OLE drag-out source and implement the synchronous clipboard shape directly.

## Audio/process threads

Audio and DSP threads must never call `plugin_host_*`, `plugin_editor_*`, the
Runtime, the renderer, dialogs, or accessibility code. They may only call
`alicorn.hosted_waker_notify` on a cloned `Hosted_Waker`. That path takes the
wake-control mutex, coalesces one pending wake, calls the plugin's
`post_wake` (a Win32 `PostMessage`), and returns promptly. It does not wait for
the UI thread, allocate a new queue, or touch the GPU.

The UI thread reads bounded worker data in `on_tick` or `on_scheduled_wake`,
then invalidates the description. The worker must be stopped and joined in
`on_stop`; `hosted_runtime_destroy` closes the wake gate before it calls
`on_stop`. A cloned waker that outlives `on_stop` is a safe no-op after the
gate closes.

## Device loss

`plugin_host_simulate_device_loss` is the fixture/test injection. Real wgpu
device-loss callbacks enter the same state machine:

1. mark every presenter lost and refuse new presentation work;
2. drain queue-completion callbacks until every presenter can be destroyed;
3. release per-editor surfaces and the shared adapter/device/queue/instance;
4. recreate the instance, surfaces from the same child HWNDs, adapter, and
   device;
5. reattach each presenter to its retained `Hosted_Runtime` and request one
   presentation.

The child HWND, `Hosted_Runtime`, retained description, application state,
scroll/focus state, and surface geometry survive the recovery. Recovery is a
bounded synchronous UI-thread operation (5 s deadline per phase) because a
plugin host has no second UI thread to run it on; it is not an idle poll.

## Optional accessibility

The core package does not link SDL or AccessKit. For per-editor native
semantics on Windows, import `alicorn:host/plugin/accessibility`:

```odin
import plugin_accessibility "alicorn:host/plugin/accessibility"

accessibility: plugin_accessibility.Editor_Accessibility
config.accessibility = plugin_accessibility.plugin_accessibility_init(&accessibility)
```

Each editor gets its own AccessKit adapter attached to its child HWND and its
own semantic projection. The adapter reuses the existing per-window SDL3
accessibility host, with `native_accessibility_adapter_init_hwnd` as the only
new attachment seam. `plugin_editor_metrics().accessibility_attached` reports
whether attach succeeded. A failed attach does not take down the editor; native
semantics are simply unavailable for that instance. The plugin wake path is
Win32, so the accessibility waker is deliberately inactive in this Phase B
slice; activation still returns a fresh tree. UIA/Narrator validation remains a
future platform gate.

## Fixture and validation

`tests/fixtures/plugin_host` creates a plain Win32 parent and drives:

- create/attach/show, first frame, settle, resize, hide/show;
- scoped keyboard activation in instance A;
- two simultaneous instances with input isolation;
- close A while B keeps presenting;
- two sequential open/close rounds;
- simulated device loss and retained-state recovery;
- post-recovery idle and clean teardown;
- zero submissions over a 750 ms settled window and a 500 ms hidden window.

```powershell
.\tools\validate_plugin_host.ps1 -Backend d3d12
.\tools\validate_plugin_host.ps1 -Backend vulkan -HoldMs 3500 -Screenshot docs\validation\assets\issue-121-plugin-host-dual-d3d12-2026-11-22.png
```

The fixture prints per-instance process-private-byte deltas, frame/presentation
counts, configure counts, logical/pixel sizes, and the last surface-configure
cost. Process-private memory includes shared device/allocation slack; it is not
an exact per-editor heap or GPU-byte measurement.

The dated acceptance record is
[`validation/issue-121-plugin-host-2026-11-22.md`](validation/issue-121-plugin-host-2026-11-22.md).
