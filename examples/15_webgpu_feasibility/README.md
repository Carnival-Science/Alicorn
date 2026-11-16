# Shared native/browser WebGPU feasibility fixture

The interactive capability scene keeps a small bespoke draw list for exercising
the full set of WebGPU operations. Offscreen probes also build real Alicorn
`Paint_Display_List_View` values and send them through `renderer/webgpu/` and
the shared `renderer/cpu` products. The production renderer path and WGSL are
the same for native and browser; only `host_sdl3.odin` and `host_web.odin`
differ by platform. The application window still uses the fixture scene, so
this is renderer integration evidence, not yet a replacement for the SDL_GPU
application presenter.

The scene exercises solid geometry, alpha blending, a rounded surface, clipped
checker texture, Runa-shaped/rasterized text in an R8 atlas, and CPU waveform
bars. A marker animates for 1.8 seconds. The browser scheduler stops requesting
frames when it settles and wakes for resize or pointer activation. A 63×64
offscreen RGBA target is copied with a 256-byte row pitch (252 texel bytes plus
four padding bytes per row) to a staging buffer and mapped asynchronously; its
callback checks the pixel samples across the rows. The fixture also
performs a nonzero-offset partial vertex-buffer update and a WGSL uniform
buffer layout/binding probe, checking both rendered colors. It requests
`QueueOnSubmittedWorkDone`; the bounded native smoke waits for both async
callbacks before teardown. Browser probe results appear in the page's live
validation status as well as its developer console. A second 63×64 target
checks three samples from the real retained paint list: ordered source-over
blend at the overlap and untouched root color beyond the clipped parent on
both axes. The same display list is encoded twice; counters require one mesh
build and one vertex/viewport upload total, proving unchanged retained paint
reuses its prepared product. A third target renders a real Alicorn `Text_Paint`
through `renderer/webgpu/text.odin`, then checks visible glyph pixels. It also
repeats preparation unchanged and with translation-only motion: the unchanged
pass must create or upload nothing, and translation may update its small
transform buffer without rebuilding glyph geometry or atlas pages. The native
fixture submits atlas writes before acknowledging Runa's dirty generation. A
fourth target passes an interleaved surface/text/icon/image/custom-geometry list through the shared
`renderer/webgpu/compositor.odin`: a surface underlay, text, an opaque surface
over that text, another copy of the text below, a one-pixel scissor sentinel,
clipped tinted icons sampled from both immutable atlas pages, and two Runtime
images. The images check straight-alpha source-over blending, retained paint
order, clipped UV/geometry correspondence, and image texture switching.
Three semantic surfaces also check a horizontal theme-resolved gradient and
raised/recessed analytic relief using the shared CPU material tessellator.
Two retained custom-surface payloads check a rectangle, thick segment, filled
circle, masked point marker, marker scissor, and a two-sample waveform. Their
geometry comes from `renderer/cpu/gpu_surface.odin`, which is also used by the
SDL_GPU reference surface renderer.
Pixel checks assert the opaque overlay remains above earlier text, later text
remains visible, icon tint appears only inside its clip, and image colors,
alpha blending, and clipping are correct. One icon requires
the renderer to restore the target scissor after the sentinel; drawing the two
icons also exercises atlas bind-group switching. The compositor checks that
surface, text, icon, and image meshes reuse cached products; both icon atlas
pages and both Runtime images upload once. Image bounds changes rebuild their
mesh without resending unchanged pixels. Each custom geometry resource gets
its own retained mesh buffer, while a shared instance stream carries placement,
scale, and opacity. Unchanged preparation reuses both resource meshes;
placement and opacity changes upload only instance data. Growing a waveform
payload rebuilds only that resource and keeps its old buffer alive through the
last-use queue serial. Releasing an image while a submitted frame uses its
texture queues it for retirement; a queue-completion serial releases it only
after the host reports completion. GPU image residency is
bounded to 128 MiB, so a host must deliver completion serials to reclaim retired
bytes under cache pressure. Native Vulkan and browser readbacks pass the
gradient endpoint and raised/recessed face and bevel probes. Production
application hosts are not integrated yet. A fifth target is reused for two
45×36 crops of the same prepared mixed paint list, at physical origins (18, 28)
and (0, 0), in one command encoder. Each crop uses a separate dynamic viewport
slot, and every RGBA8 pixel is compared with the matching full-frame region.
This exercises queued origin isolation and translated/clipped scissors without
rebuilding retained meshes. Both crop comparisons passed the Windows D3D12
smoke and the later live browser replay.

The fixture also creates a second production `WebGPU_Compositor` and renders a
backdrop-effect marker into an offscreen target. It captures the paint prefix
to renderer-owned sampleable textures, runs both shared-mesh Gaussian passes,
and composites at the marker in paint order. Readback checks blurred pixels
contain contributions from both sides of the source boundary and that pixels
outside the effect clip remain unchanged. The Windows D3D12 probe passed on
2026-11-15, and the same fixture passed live browser readback. The fixture also
resizes the cached crop while its earlier submission is still in flight, then
checks that the old textures retire only after the reported completion serial.
An over-budget but valid effect plan skips only its marker; its full RGBA
readback matches plain paint with the marker removed. D3D12 passes the resize,
retirement, and fallback probes; browser readback passes the over-budget
fallback parity probe. The browser adapter's hardware/software class was not
reported. This single-marker probe does not establish full effect parity or
application host integration.

## Windows native

~~~powershell
.\build.ps1 -Odin C:\odin\odin.exe
.\out\webgpu_feasibility.exe
~~~

Resize while the marker moves and after it settles. The native host waits in
SDL when there is no frame, animation deadline, or WGPU callback work.

For a bounded native adapter/render/readback smoke that exits on completion:

~~~powershell
.\out\webgpu_feasibility_smoke.exe
~~~

Both smoke executables accept an explicit native backend when collecting
backend-specific evidence:

~~~powershell
.\out\webgpu_feasibility_smoke.exe --backend=vulkan
.\out\webgpu_feasibility_smoke.exe --backend=d3d12
.\out\webgpu_feasibility_resize_smoke.exe --backend=d3d12
~~~

The fixture logs both the requested backend and the adapter's reported backend;
count a result only when those agree. The unqualified invocation leaves backend
selection to wgpu-native.

The smoke exits nonzero if any pixel probe or the queue-completion callback
fails or either asynchronous completion callback does not arrive within 15
seconds. A timeout prints the readback and queue-callback state before exiting.

For native surface reconfiguration during motion and after it settles, run:

~~~powershell
.\out\webgpu_feasibility_resize_smoke.exe
~~~

It changes the SDL window size during the 1.8-second animation, changes it
again after settlement, and exits only after both surface reconfigurations have
been observed and a `SurfacePresent` call at each new size has been submitted.
The same run also performs the padded offscreen readback and waits for queue
completion.

## macOS native

~~~sh
brew install lld
export PATH="$(brew --prefix lld)/bin:$PATH"
sh build.sh
./out/webgpu_feasibility_smoke
~~~

This uses the same shared Odin renderer with SDL3 and wgpu-native/Metal.

## Linux x64 native

Install the platform's SDL3 development package, Vulkan loader/driver, and
`wasm-ld`, then install the pinned compiler and wgpu-native archive:

~~~sh
sh tools/setup_linux_odin.sh "$HOME/opt/alicorn-odin"
export ODIN_ROOT="$HOME/opt/alicorn-odin"
export ALICORN_ODIN="$ODIN_ROOT/odin"
sh tools/setup_linux_wgpu_native.sh "$ODIN_ROOT"
sh examples/15_webgpu_feasibility/build.sh --odin "$ALICORN_ODIN"
~~~

Run `examples/15_webgpu_feasibility/out/webgpu_feasibility_smoke` and
`webgpu_feasibility_resize_smoke` inside an X11 or Wayland session. Hosted
Linux CI forces Mesa lavapipe under Xvfb, so it checks the Vulkan software
path and X11 surface contract, not physical GPU performance or Wayland. The
hosted Linux x64 readback, resize submission, and browser build passed in the
[2026-11-15 feasibility run](https://github.com/samanshaiza004/alicorn/actions/runs/43759132474).

## Browser

The browser build uses Odin js_wasm32 without Emscripten. Serve web/ over
localhost or HTTPS:

~~~powershell
python -m http.server 8080 --directory web
~~~

Open http://localhost:8080/. After the animation, confirm the status reports no
new `requestAnimationFrame` requests for 500 ms. Resize once and confirm a
single presentation is scheduled; click the canvas to replay. A WASM build
alone is not browser-GPU validation; the browser needs `navigator.gpu` and a
functioning adapter. The status also reports how many one-shot frames occurred
while waiting for adapter/device callbacks; the browser host must not poll with
a continuous animation-frame loop during initialization.

The fixture uses default device limits because of Odin binding issue #8174. It
has passed an actual browser WebGPU runtime/readback session and native Windows
Vulkan on an NVIDIA Turing adapter; a successful browser build alone does not
count as runtime evidence. The backdrop-effect readback also passed in both a
Windows D3D12 run and a live browser replay, including
unchanged-prefix reuse and changed-prefix invalidation. The browser status did
not identify the adapter's hardware/software acceleration class, so that run
is correctness evidence rather than a performance measurement. The fixture
does not validate fallback-font chains, effect-texture resize retirement and
budget fallback, device recreation, secondary windows, application-window
presentation, or production performance. The mixed paint list is fixture-only;
it covers solid surfaces, text, icons, images, materials, and custom geometry.

## Opt-in device-destruction callback probe

This is diagnostic only and does not test device recreation. Build and run the
browser variant with:

~~~powershell
C:\odin\odin.exe build . -target:js_wasm32 -o:size `
    -define:FEASIBILITY_TEST_DEVICE_LOSS=true `
    -out:web\feasibility.wasm -extra-linker-flags:--export-table
~~~

Reload the page. The browser should print the successful readback followed by a
`device loss notification reason=Destroyed` message. Rebuild the normal variant
afterward with `.\build.ps1 -Odin C:\odin\odin.exe`.

The unmodified Odin wgpu-native binary passes rendering/readback but does not
deliver the native destroy callback on the tested Windows D3D12 setup. Source
inspection found that pinned wgpu-native `v29.0.1.1` stores the C callback but
does not register wgpu-core's device-lost closure. A narrowly scoped source
patch now registers it; build and test instructions and results are in
[`docs/validation/webgpu-device-loss-callback-patch-windows-2026-11-15.md`](../../docs/validation/webgpu-device-loss-callback-patch-windows-2026-11-15.md).

The native probe is bounded and now fails unless the explicit destroy was
triggered and exactly one `reason=Destroyed` callback arrived before ordinary
teardown. It also checks that teardown does not deliver a duplicate callback.
With the patched static library, the zero-work native repro delivers the
callback with both `AllowProcessEvents` and `AllowSpontaneous`, including after
releasing the last device handle before polling. The full fixture also
completes readback and receives the callback. The unpatched library is a
negative control: it exits nonzero when the callback is missing. These are
explicit-destroy tests, not simulations of OS/driver-initiated device loss, and
they do not prove device recreation.

On macOS arm64, `sh tools/validate_wgpu_native_device_loss_macos.sh` builds the
same pinned wgpu-native source patch with Metal and runs all four native
variants. The script restores the downloaded Odin package library on exit.
The hosted macOS arm64 foundation run for [`cde2f08`](https://github.com/samanshaiza004/alicorn/actions/runs/43756274305)
passed this step. This does not simulate driver-initiated loss or prove
recovery.
