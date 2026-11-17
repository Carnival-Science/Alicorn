# Browser WebGPU UI

This example uses `ui.run` on `js_wasm32`. The UI description, retained
runtime, text shaping, and shared WebGPU renderer remain in Odin. The browser
host owns canvas sizing, adapter/device creation, input and text composition,
the bounded semantic DOM projection, and demand-driven frame scheduling.

Build and serve it over localhost (WebGPU requires a secure context):

```powershell
.\build.ps1
python -m http.server 8092 --directory out/web
```

```sh
./build.sh
python3 -m http.server 8092 --directory out/web
```

Open `http://localhost:8092/` in a browser with WebGPU support. Application
state passed to `ui.run` must outlive the browser host; this example stores it
in package-global memory. `ui.run` returns after requesting the adapter and
device because WebGPU initialization is asynchronous in browsers.

If WebGPU is unavailable, the page reports whether it needs a secure context
(HTTPS or localhost) or a browser that exposes WebGPU before downloading the
WASM application.

The example demonstrates basic control interaction and textarea-backed text
input, plus the permission-gated `Read clipboard` and `Copy sample text`
actions through `UI_Host_Services`. Use the buttons directly in the browser;
clipboard access may be denied by browser policy. It does not claim
assistive-technology validation or device-loss recovery.
