# #162 — Host-owned presentation boundary

**Status: bounded SDL_GPU host-owned presentation proof complete on Windows.**
The wx/Audacity integration and native plugin-window work remain separate in
[#196](https://github.com/samanshaiza004/alicorn/issues/196) and
[#121](https://github.com/samanshaiza004/alicorn/issues/121).

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

## Windows comparison results

**Bounded comparison complete on Windows (SDL_GPU Direct3D 12, 2026-11-15).** The
repeatable fixture is `--presentation-validation`, exposed through
`tools/native_sdl_gpu.ps1 -PresentationValidation`. It uses two independently
initialized but identical Runtime instances, the same display description,
font setup, GPU device, swapchain format, and 480×300 offscreen target size.
One is drawn through the standalone host's `draw_display_list`; the other is
encoded and acknowledged through the public `Sdl_GPU_Presenter` API. Separate
Runtime instances are necessary because each renderer owns its own GPU text
atlas and Runtime atlas-dirty state.

The optimized `-o:speed` fixture was run three times. Each run alternated 64
matched standalone/presenter encode samples:

```powershell
. .\tools\common.ps1
$Odin = Resolve-AlicornOdin
$AccessKit = Get-AlicornAccessKit
& $Odin build native\sdl_gpu_entry -o:speed @($AccessKit.CompilerArguments) -out:out\alicorn_sdl_gpu_release.exe
Copy-Item (Join-Path (Split-Path -Parent $Odin) 'vendor\sdl3\SDL3.dll') out\SDL3.dll -Force
.\out\alicorn_sdl_gpu_release.exe --presentation-validation
```

The debug/repro run is `tools/native_sdl_gpu.ps1 -PresentationValidation`.
Results:

| Comparison | Result |
| --- | --- |
| Initial raw target readback | Exact byte match: 0 differing bytes; both hashes `4283490736380418686` |
| After focus, caret movement, and text input | Exact match: 0 differing bytes; both hashes `7613017125873392090` |
| Input behavior | Both activated the button once, focused the same keyed text field, moved the caret from byte 0 to byte 1, inserted `-host`, and ended with identical text `e-hostditable input` and caret byte 6 |
| Canceled frame | Canceling the SDL command buffer then presenter frame left the Runtime frame pending and retryable |
| Warm encode work | Across the three runs, per-run means ranged 26.5–28.0 µs standalone and 26.5–27.6 µs hosted. The pooled means were 27.04 µs and 27.03 µs (about 0.04% apart), well within this single-machine run-to-run spread. CPU encode only; excludes command-buffer acquisition, submission, fence wait, and display, so this is not a total frame-time claim |
| GPU submissions | Both paths recorded 66 submissions per run (initial + post-input + 64 matched samples) |
| Persistent Runtime allocations | Both recorded 399 calls per run. The 64 matched encode samples each caused 64 allocations and 64 frees on both paths, with 0 live-byte growth; idle then added 0 allocations. |
| Settled idle | About 299 ms native event wait, 0 events, 0 Runtime allocation calls, 0 submissions, and neither Runtime requested another frame |
| Presenter lifetime | Eight submitted frames; 1–3 fences remained in flight before Destroy across runs. Destroy retired all fences, cleared presenter state, and the GPU reached idle before Runtime/device teardown |
| Standalone lifetime | Host waited its submission fence, destroyed renderer resources, then Runtime; the device remained alive until after both paths completed |

The same validation also passed in a debug build. Build warnings are the
existing large `Native_Secondary_Window` stack-size warnings.

### Scope of this evidence

The pixel check proves equality of the composed SDL_GPU target for this bounded
fixture, which includes flat surfaces, retained text, a focus ring, and an
edited text field. It is not a cross-backend or cross-platform image guarantee.
Input uses the same normalized Runtime pointer, text-command, and text-input
operations on both instances; it verifies the host-owned path can route input
to the Runtime without losing focus or edit state. It does not validate a
particular third-party toolkit's native event adapter, physical keyboard or
IME behavior, accessibility bridge, clipboard, menus, device loss, or resize
policy. Those remain host integration responsibilities and are outside this
frame-boundary proof.

The result is **GO for the bounded SDL_GPU frame boundary**: an external host
can own the window, device, command buffer, target, event wait, and teardown
while using Alicorn's public retained compositor without adopting `host.Run`.
This does not establish a renderer-agnostic API, wx/Audacity integration, or
native plugin-window attachment; those remain tracked separately in #196 and
#121. No generic renderer interface or serialized paint packet was added.
