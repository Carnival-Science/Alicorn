# Shared native/browser WebGPU feasibility fixture

This example stays separate from the production renderer. The Odin scene
builder, vertex stream, WGSL shader/pipeline, texture upload, and drawing code
are shared. Only host_sdl3.odin and host_web.odin differ by platform.

The scene exercises solid geometry, alpha blending, a rounded surface, clipped
checker texture, Runa-shaped/rasterized text in an R8 atlas, and CPU waveform
bars. A marker animates for 1.8 seconds. The browser scheduler stops requesting
frames when it settles and wakes for resize or pointer activation. A 63×64
offscreen RGBA target is copied with a 256-byte row pitch (252 texel bytes plus
four padding bytes per row) to a staging buffer and mapped asynchronously; its
callback checks thirteen pixel samples across the rows. The fixture also
performs a nonzero-offset partial vertex-buffer update and a WGSL uniform
buffer layout/binding probe, checking both rendered colors. It requests
`QueueOnSubmittedWorkDone`; the bounded native smoke waits for both async
callbacks before teardown. Browser probe results appear in the page's live
validation status as well as its developer console.

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

## macOS native

~~~sh
sh build.sh
./out/webgpu_feasibility_smoke
~~~

This uses the same shared Odin renderer with SDL3 and wgpu-native/Metal.

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
functioning adapter.

The fixture uses default device limits because of Odin binding issue #8174. It
does not validate fallback-font chains, production image decoding, retained
invalidation, device recreation, secondary windows, or production performance.

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

With the patched static library, the zero-work native repro delivers
`reason=Destroyed` with both `AllowProcessEvents` and `AllowSpontaneous`. The
full fixture also completes readback, receives the callback, and exits through
normal teardown. The opt-in fixture now exits automatically after callback
delivery. These are explicit-destroy tests, not simulations of an
OS/driver-initiated device loss, and they do not prove device recreation.
