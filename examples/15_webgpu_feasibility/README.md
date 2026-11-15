# Shared native/browser WebGPU feasibility fixture

This example stays separate from the production renderer. The Odin scene
builder, vertex stream, WGSL shader/pipeline, texture upload, and drawing code
are shared. Only host_sdl3.odin and host_web.odin differ by platform.

The scene exercises solid geometry, alpha blending, a rounded surface, clipped
checker texture, Runa-shaped/rasterized text in an R8 atlas, and CPU waveform
bars. A marker animates for 1.8 seconds. The browser scheduler stops requesting
frames when it settles and wakes for resize or pointer activation. A 64×64
offscreen RGBA target is copied to a padded staging buffer and mapped
asynchronously; its callback checks the pixel result.

## Windows native

~~~powershell
.\build.ps1 -Odin C:\odin\odin.exe
.\out\webgpu_feasibility.exe
~~~

Resize while the marker moves and after it settles. The native host waits in
SDL when there is no frame, animation deadline, or WGPU callback work.

## Browser

The browser build uses Odin js_wasm32 without Emscripten. Serve web/ over
localhost or HTTPS:

~~~powershell
python -m http.server 8080 --directory web
~~~

Open http://localhost:8080/. Confirm the settled status, resize once, and click
the canvas to replay. A WASM build alone is not browser-GPU validation; the
browser needs navigator.gpu and a functioning adapter.

The fixture uses default device limits because of Odin binding issue #8174. It
does not validate fallback-font chains, production image decoding, retained
invalidation, device recreation, secondary windows, or production performance.

## Opt-in device-destruction callback probe

This deliberately destroys the device immediately after successful offscreen
readback. It is diagnostic only and does not test recreation. Build and run the
browser variant with:

~~~powershell
C:\odin\odin.exe build . -target:js_wasm32 -o:size `
    -define:FEASIBILITY_TEST_DEVICE_LOSS=true `
    -out:web\feasibility.wasm -extra-linker-flags:--export-table
~~~

Reload the page. The browser should print the successful readback followed by a
`device loss notification reason=Destroyed` message. Rebuild the normal variant
afterward with `.\build.ps1 -Odin C:\odin\odin.exe`.

For Windows native, build to a fresh executable so a running normal fixture is
not overwritten:

~~~powershell
C:\odin\odin.exe build . -define:FEASIBILITY_TEST_DEVICE_LOSS=true `
    -out:out\device_loss_probe.exe
Copy-Item C:\odin\vendor\sdl3\SDL3.dll out\SDL3.dll -Force
Copy-Item C:\odin\vendor\wgpu\lib\wgpu-windows-x86_64-msvc-release\lib\wgpu_native.dll out\wgpu_native.dll -Force
.\out\device_loss_probe.exe
~~~

The current Windows full-render probe passes readback and stops rendering after
destroy. The SDL host calls the existing `wgpu.DevicePoll` wrapper and
`InstanceProcessEvents`; the opt-in probe performs one blocking poll, reports
whether the queue drained, then follows normal teardown. On the tested Windows
D3D12 setup it reported `queue_empty=true`, but no native device-loss callback
was observed.

For a minimal zero-work native repro, build and run:

~~~powershell
C:\odin\odin.exe build . `
    -define:FEASIBILITY_TEST_DEVICE_LOSS=true `
    -define:FEASIBILITY_TEST_DEVICE_LOSS_EARLY=true `
    -out:out\device_loss_early.exe
.\out\device_loss_early.exe
~~~

To test the alternate callback dispatch mode, add
`-define:FEASIBILITY_TEST_DEVICE_LOSS_SPONTANEOUS=true` to the build. Both modes
currently report `queue_empty=true device_lost=false` on Windows D3D12. The
probe exits through normal teardown. The browser variant still delivers
`reason=Destroyed` after destruction is deferred until the host loop resumes.
These are explicit-destroy tests, not simulations of an OS/driver-initiated
device loss, and neither proves device recreation.
