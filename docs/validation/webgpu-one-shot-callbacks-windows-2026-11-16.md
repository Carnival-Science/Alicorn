# Odin WebGPU one-shot callback correction — Windows

Validated 2026-11-16 on Windows x64 with Odin
`dev-2026-11-nightly:08539cd` and Node.js `v24.18.0`.

## Finding

The copied Odin `vendor/wgpu/wgpu.js` uses `.catch(error).then(success)` for
eight one-shot async WebGPU callbacks. If a promise rejects, the error callback
runs and the promise returned by `catch()` fulfills, so the success callback
also runs. The queue completion case can therefore free the same host callback
context twice. The same pattern affects adapter/device requests, buffer mapping,
pipeline creation, error scopes, and shader compilation.

## Correction

`tools/patch_odin_wgpu_js.js` rewrites the generated browser bundle to
`.then(success, error)`. It changes only the copied build artifact, requires all
eight current callback chains, and stops the build if the vendor source drifts.
The installed Odin SDK is left unchanged. Both `examples/15_webgpu_feasibility`
and `examples/17_browser_webgpu_ui` apply the correction after copying the
upstream WGPU JS bridge.

## Validation

- `node tools/test_odin_wgpu_js_patch.js`: both tests passed. A resolved promise
  dispatched only success; a rejected promise dispatched only error. An
  unexpected source shape was rejected.
- `node --check` passed on the patched WGPU bridge copied from the installed
  SDK.
- `examples/17_browser_webgpu_ui/build.ps1 -Odin C:\odin\odin.exe` passed and
  patched all eight chains in `out/web/wgpu.js`.
- `examples/15_webgpu_feasibility/build.ps1 -Odin C:\odin\odin.exe` passed;
  its native fixture builds and browser WASM build completed, and all eight
  chains were patched in `web/wgpu.js`.

## Limits

The regression drives controlled JavaScript promises; it does not force a real
browser GPU rejection or driver/OS device loss. Device-loss callback ordering,
pending-submission retirement, and resource recreation remain unvalidated.
The correction is a local Odin-binding workaround and should be removed when a
fixed upstream binding revision is pinned.
