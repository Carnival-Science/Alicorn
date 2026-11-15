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
fourth target passes an interleaved surface/text/icon/image list through the shared
`renderer/webgpu/compositor.odin`: a surface underlay, text, an opaque surface
over that text, another copy of the text below, a one-pixel scissor sentinel,
clipped tinted icons sampled from both immutable atlas pages, and two Runtime
images. The images check straight-alpha source-over blending, retained paint
order, clipped UV/geometry correspondence, and image texture switching.
Pixel checks assert the opaque overlay remains above earlier text, later text
remains visible, icon tint appears only inside its clip, and image colors,
alpha blending, and clipping are correct. One icon requires
the renderer to restore the target scissor after the sentinel; drawing the two
icons also exercises atlas bind-group switching. The compositor checks that
surface, text, icon, and image meshes reuse cached products; both icon atlas
pages and both Runtime images upload once. Image bounds changes rebuild their
mesh without resending unchanged pixels. Releasing an image while a submitted
frame uses its texture queues it for retirement; a queue-completion serial
releases it only after the host reports completion. GPU image residency is
bounded to 128 MiB, so a host must deliver completion serials to reclaim retired
bytes under cache pressure. Production application hosts are not integrated yet.

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
has passed an actual browser WebGPU runtime/readback session on an NVIDIA
Turing adapter as well as native Windows Vulkan; a successful browser build
alone does not count as runtime evidence. It does not validate fallback-font
chains, images, icons, backdrop effects, device recreation, secondary windows,
application-window presentation, or production performance. The mixed
surface/text composition check is fixture-only and does not yet cover the
remaining paint command families.

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
