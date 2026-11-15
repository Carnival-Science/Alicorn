# #162 — Host-owned presentation boundary

**Status: prototype implemented; comparison and integration gates remain open.**

## Finding

The Runtime already exposes a renderer-neutral `Paint_Display_List_View`, but
that view is a short-lived borrow. Its commands can reference Runtime-owned text,
image, and geometry payloads, so a renderer must resolve and consume them on the
Runtime's owner thread before the next mutation or frame operation. The view is
not a GPU-fence-owned packet and cannot safely be retained as-is.

The SDL compositor already accepts an external command buffer, target texture,
dimensions, scales, and a display-list slice in
[`gpu_frame.odin`](../../native/sdl_gpu/gpu_frame.odin). The standalone host
owns the corresponding text, surface, and solid renderer resources, submits the
command buffer, stores its fence, and acknowledges the Runtime only after a
successful submission in
[`application_loop.odin`](../../native/sdl_gpu/application_loop.odin). Before
this prototype, those pieces were joined only inside that host loop; an
independent host had no documented lifecycle boundary around them.

[Acetate's current integration notes](https://github.com/samanshaiza004/Acetate/blob/main/src/alicorn/README.md)
say the timeline view does not create an Alicorn window or GPU renderer and
still presents retained geometry through `wxGraphicsContext`; the source
adapter is [`AlicornTimelineView.cpp`](https://github.com/samanshaiza004/Acetate/blob/main/src/alicorn/AlicornTimelineView.cpp).
The new boundary gives an SDL_GPU host access to Alicorn's existing renderer
without adopting `host.Run`; it does **not** turn a `wxGraphicsContext` into an
SDL_GPU target or switch Acetate's interface by itself.

## Implemented boundary

[`presentation.odin`](../../native/sdl_gpu/presentation.odin) adds
`Sdl_GPU_Presenter` for one borrowed Runtime and one borrowed SDL_GPU device.
The host continues to own SDL initialization, window/device creation, target
acquisition, command buffers, event dispatch, resize policy, input translation,
and its event loop.

The frame contract is:

1. `Sdl_GPU_Presenter_Encode` obtains the current borrowed display view and
   resolves it synchronously into the host's target and command buffer. It
   retains neither the view nor the command-buffer pointer. Flat surfaces,
   text, icons, images, and custom geometry are supported. Backdrop effects and
   unknown command kinds fail preflight instead of being silently omitted.
2. The host submits the command buffer and obtains an SDL_GPU fence.
3. `Sdl_GPU_Presenter_Submission_Succeeded` takes ownership of that fence,
   commits renderer uploads, and acknowledges the Runtime only if its display
   revision still matches the one encoded. The returned token contains a
   presenter generation, monotonically increasing submission serial, and that
   display revision, never a raw GPU pointer. The generation prevents tokens
   from separate presenters or Runtime instances from being confused.
4. The host can poll or wait for a token. The presenter keeps at most three
   fences and waits for the oldest before accepting another encoded frame when
   the queue is full. Destroying the presenter waits for all of its submitted
   work before releasing renderer resources.
5. If encoding fails, the host cancels its command buffer and then calls
   `Sdl_GPU_Presenter_Cancel_Frame`. If a submit attempt fails without a clear
   guarantee that no work was queued, it first waits for GPU idle. Pending
   atlas/image work is retried or discarded without acknowledging the Runtime.

The target must use the format supplied at presenter creation. The host must
keep the Runtime and GPU device alive until presenter destruction and keep each
host target alive until its corresponding submission token completes. The
presenter does not claim the host window or change device frame limits. All
presenter calls run on the Runtime's owning host thread.

The minimal external consumer in
[`examples/15_host_owned_sdl_gpu/main.odin`](../../examples/15_host_owned_sdl_gpu/main.odin)
creates its own SDL window and GPU device, authors one ordinary Runtime frame,
encodes and submits it through the new API, then blocks in its own event wait.
It does not call `Run` or the standalone application loop.

## Acetate integration boundary

The prototype proves a second **SDL_GPU host** can use Alicorn's native
compositor and own its frame loop. It does not yet prove that wxWidgets can
present into that target or share a native window/device safely. Acetate would
need a supported SDL_GPU target for its window, or a separate SDL-owned
presentation surface embedded by the wx host. Alicorn now has a UI-thread
`Hosted_Runtime` session API; an external host can borrow that Runtime with
`hosted_runtime_borrow` and pass it to `Sdl_GPU_Presenter_Create`. The
presenter's submission-success call already acknowledges that Runtime frame,
so the host must not separately acknowledge that same submission through
`hosted_runtime_frame_submission_succeeded`. See the
[hosted-runtime contract](../hosted-runtime.md).

The wx host fixture, native service ownership, and complete Audacity
interaction/teardown proof remain open in [#196](https://github.com/samanshaiza004/alicorn/issues/196);
native window attachment remains in [#121](https://github.com/samanshaiza004/alicorn/issues/121).
This document covers the renderer/frame seam in
[#162](https://github.com/samanshaiza004/alicorn/issues/162). Acetate's wx
adapter remains its active presentation path until those pieces are integrated.

Input, accessibility, clipboard/IME routing, native menus, integrated titlebar
chrome, DevTools overlays, retained backdrop effects, device loss, and device
recreation are not handled by this presenter. The host must keep dispatching
events into the same Runtime and arrange a new frame when needed. The API rejects
backdrop effects; the full host's effects cache remains a host-only service.

## Verification and remaining gates

The fixture establishes a buildable public call path around a host-owned
window, device, command buffer, target, and event loop. A successful compile
does not establish pixel equivalence or correct physical presentation. Before
calling #162 complete, compare the fixture and standalone host for:

- pixel output for flat surfaces and text;
- focus and input behavior when the host routes events to the same Runtime;
- no repeated frames or GPU submissions while idle;
- cancellation, successful submission, fence retirement, and Runtime/device
  destruction ordering;
- allocation and CPU/GPU submission costs.

This prototype intentionally adds no generic renderer interface or serialized
paint packet. The Runtime's existing paint stream stays renderer-neutral; the
new package API is an explicitly SDL_GPU implementation of its host-owned frame
and resource-lifetime boundary.
