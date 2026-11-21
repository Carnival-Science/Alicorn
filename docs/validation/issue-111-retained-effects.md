# Issue #111: bounded retained backdrop blur

Research: 2026-11-03; Gaussian quality validation: 2026-11-04; host retry and API promotion: 2026-11-04.
Sources: [primary-source review](../research/retained-effects-issue-111.md).

## Scope and decision

Backdrop blur is now a supported, bounded semantic-surface capability in Alicorn's native SDL_GPU window compositor. Applications request it with `backdrop_blur(sigma, .Direct)` on `surface_begin`; Alicorn owns capture, Gaussian filtering, retained textures, fence tracking, composition, and fallback. This is a focused material capability, not a general effects graph. Existing analytic materials remain the component-shadow implementation.

Scratchpad Quick Open is the first ordinary consumer. It uses a stable six-logical-pixel Gaussian, 70% panel fill, and 50% modal dim. The developer comparison/tuning controls and compile-time feature gate have been removed. The user confirmed that the Gaussian result is visually useful, then found that interaction-triggered cache deferral could leave one direct fallback frame displayed until another pointer event. The host now distinguishes temporary fence deferral from permanent fallback and schedules a host-only retry; cached idle scenes still arm no timer or wake.

The bounded host implementation has hosted readback validation on both Metal and D3D12. The macOS and Windows foundation jobs passed on PR head `6a5a104`; see the [Metal workflow](https://github.com/samanshaiza004/alicorn/actions/runs/42293184017) and [D3D12 workflow](https://github.com/samanshaiza004/alicorn/actions/runs/42293184107). These results validate the bounded readback fixture on those backends, not interactive frame pacing or universal renderer parity. The newly integrated head still needs fresh CI. The local validation environment has no enumerated macOS display, so it cannot complete the live GUI path.

The Gaussian quality gate replaced the stretched five-tap binomial with a sampled discrete Gaussian. Metal readbacks compare against an independent dense CPU convolution. The filter is correct for the documented encoded-SDR contract; linear-light treatment, HDR, wide-gamut color management, and output corner masks are outside this version.

## Run

```sh
sh tools/validate_effects.sh --odin /path/to/odin
# Where SDL supports Vulkan:
sh tools/validate_effects.sh --odin /path/to/odin --driver=vulkan
```

```powershell
./tools/validate_effects.ps1 -Odin odin
./tools/validate_effects.ps1 -Odin odin -Driver vulkan
```

The runners execute native unit tests, then device-only GPU readbacks. Requested-device failure is a failure, never a silent pass or a switch to a different renderer. Captures are written to `out/retained-effects/{flat,analytic-shadow,blur-cold,blur-retained}.ppm`. Foundation CI runs Metal and D3D12 readbacks; the linked workflow results above passed on PR head `6a5a104`.

## Boundary and rendering contract

The validation fixture's `Native_Effect_Request` contains one stable key,
authoritative source generation, resolved output rectangle/ancestor clip,
uniform DPI scale, Gaussian standard deviation (`sigma`) in logical pixels,
and depth. The fixture advances the source generation explicitly. In the
application path, a paint-stream marker defines the boundary and the
host hashes the commands before it together with bounds, clip, DPI scale, and
effect parameters. Commands after the marker (including Quick Open
query/results) do not invalidate the backdrop. This observes only the generic
paint commands represented in that prefix; it is not a general dependency
tracker for arbitrary GPU resources.

The effect captures the specified paint prefix before foreground commands. It
replays it through `draw_display_list`, translated into the input rectangle,
with the original per-command clips preserved. It never samples a swapchain.
The palette comparison replays a **known opaque background** with the prefix;
the filtered alpha-one result replaces the original backdrop at composition.
Replaying a transparent prefix over itself would double-composite it and is
not a valid general backdrop capture. Transparent isolated layers are tested
separately by the readback cases.
The input includes the complete three-sigma halo on each side and rounds
outward in physical pixels. The output is scissored to the resolved
region/ancestor intersection. Nested effects are rejected; nested ordinary
clips are retained.

The filter is a separable, discrete Gaussian truncated at
`ceil(3 * sigma_physical_pixels)`. It computes normalized dense weights, then
pairs adjacent weights on each side into fractional-offset samples. Linear
texture filtering reconstructs the paired integer coefficients, reducing the
number of shader draws without stretching a sparse fixed-tap kernel across a
wider radius. The tap count grows with sigma and is bounded at 97 samples per
axis. The same compiled image shader handles every tap; no new shader artifact,
runtime compilation, or backend-specific effect implementation is needed.
Capture uses RGBA8_UNORM; horizontal and vertical intermediates use
RGBA16_FLOAT to avoid quantizing each weighted contribution to eight bits.
Two filter passes accumulate premultiplied RGBA; composition uses
`ONE, ONE_MINUS_SRC_ALPHA` so alpha is not multiplied twice. The final palette
and foreground retain painter order. All passes end before the next pass
begins.

The color contract is **encoded SDR RGBA8**, matching the existing ordinary
UNORM renderer. This is deliberately not a linear-light blur. HDR, sRGB render
targets, wide-gamut/native display color management, and rounded effect-output
masks are unimplemented. This supported API currently excludes those cases; changing the whole renderer's
color contract is outside this feature slice.

## Bounded retention and failure behavior

- The low-level fixture uses one slot. The primary application host uses
  two fence-tracked slots, each with three textures, maximum 2048 physical
  pixels on either axis, sigma at most eight logical pixels (32 physical
  pixels), radius at most 96 physical pixels, and depth one. The app cache has
  a 48 MiB requested-storage budget across slots. There is no unbounded cache
  or hidden full-window target.
- The fixture uses a 16 MiB budget for requested texture and fixed vertex/transfer
  buffer bytes. Existing source-renderer buffers, final target/readback buffers,
  pipeline/sampler objects, and driver allocation overhead are excluded. This
  is not a measurement of total frame memory or hardware texture residency.
- Textures and buffers do not cycle. A changed source generation repaints the
  complete bounded input; unchanged generations reuse the filtered result.
  There is no partial-damage algorithm.
- The isolated validation fixture uses conservative device-idle retirement.
  The application path reuses a slot only after its last-use submission fence
  retires; if both slots are busy, the host draws directly for that frame and
  schedules one retry opportunity. At that opportunity it waits only through
  the earliest fence that can free a cache slot, rather than polling the GPU
  continuously. A hard budget/format/allocation failure remains a direct
  fallback. Ordinary replacement, resize, and dismissal do not drain the GPU. Device-idle
  waiting remains a shutdown fallback after the host's final submission wait.
- Unsupported format, budget, or allocation failure chooses direct drawing.
  Canceled/submission-failed work is not published as a valid output generation.
  Reset retires the slot; a fresh cache recreates resources lazily.
- Device loss is not transparently recovered. A failed device requires the
  host's device teardown/recreation; old cache handles must never migrate to a
  new device. Actual device removal and injected submit failure remain untested.
- Initially inactive scenes create zero effect resources. A stable cached scene
  performs no filter pass, allocation, submission, timer, or wake. A retry timer
  exists only while a valid effect is deferred by in-flight GPU work; the host
  consumes it once, retires the relevant submission fence, and redraws without
  rebuilding or acknowledging the application description.

## Validation and measurement boundaries

The CPU reference directly convolves the generic renderer's downloaded source
pixels with every normalized dense Gaussian coefficient, then computes
premultiplied source-over and foreground ordering. This is independent of the
GPU's bilinear-paired taps and half-float intermediates, and validates the
filter and composition; the source renderer's correctness remains covered
separately by the existing blend/readback suite. Source and destination never
alias. A frequency-response regression also checks that the new Gaussian
attenuates a six-pixel repeating pattern that the former spacing-six binomial
filter passed unchanged.

Readbacks cover transparent colored edges, text, ancestor clipping, input halo,
foreground overlap, sigma values 1/4/8 at scales 1/1.5/2, source-generation
changes, cache reuse, fresh rebuild equality, cancellation, reset/recreation,
and direct fallback. The maximum supported physical sigma is also checked at
the unit-test boundary (97 bounded paired samples per axis).
Transfer rows are padded to the D3D12-compatible 256-byte alignment. The unit
tests reject invalid numeric values, oversized regions, excess nesting, and
missing source identity before allocation.

The fixture is built with `-o:speed`. Timing prints first-frame encoding and
submission-to-fence wall time, followed by
40 warm samples' p95 for flat, direct analytic shadow, changed-source blur,
and retained blur during a forced ordinary repaint. The first sample's artifact
readback is excluded from warm samples. These first frames occur in a warmed
process after correctness probes; they are not cold application/driver startup
measurements. Encoding wall time includes preparation and the conservative
device-idle wait. Submission-to-fence wall time includes
driver/queue/wait costs and is **not hardware GPU timestamp duration**. SDL_GPU
does not expose a portable timestamp query used by this fixture. Captures,
correctness readbacks, and device-idle resize stalls are not described as frame
presentation latency.

Remaining validation includes stationary-pointer interaction after a deferred
rebuild, Windows/D3D12 native UI behavior, hardware GPU time and residency
measurements, native idle tracing with an enabled but cached effect, failure
injection/device removal, and resize/close stress under two frames in flight.

## Scratchpad Quick Open integration

Quick Open now uses the supported Alicorn surface API directly:

- Gaussian sigma: 6 logical pixels.
- Panel fill: 70% opacity, keeping query/results foreground readable.
- Workspace dim: 50% opacity.
- The bounded result list and all foreground text remain crisp.
- The panel keeps a fixed ten-row viewport, so query and result changes do not alter the capture bounds.

The blur marker precedes the panel fill and its children. Typing and result navigation change foreground paint only and should reuse the same captured prefix. Edits, scrolling, theme, geometry, clipping, and scale changes behind Quick Open invalidate the cached image. A host that cannot satisfy the bounded resource policy draws the direct panel fallback.

The user has visually reviewed the Gaussian treatment and reported the interaction-triggered disappearance now addressed by the deferred-effect retry. The user should recheck stationary-pointer behavior after the updated Alicorn and Scratchpad revisions are built on their interactive Mac. This environment cannot enumerate a display, so I could not independently reproduce the GUI interaction here.

## Historical native results: five-tap prototype

These measurements are retained to document the original prototype. Its
fixed-spaced binomial filter was visually inadequate at wide spacing and these
numbers do not describe the Gaussian implementation below.

Apple M1 MacBook Air, 8 GiB, macOS 27.2; Odin
`dev-2026-11-nightly:9a69916`, SDL 3.4.18. One run, 40 warm samples per mode,
384×256 final target. The resolved output is 192×144 at 1×; padded input is
208×160. Metal API validation enabled.

| Mode | First encode / submit-wait (ms) | Warm encode p95 (ms) | Warm submit-wait p95 (ms) | Warm render passes | Effect bytes live/peak |
| --- | --- | --- | --- | --- | --- |
| Flat palette | 2.562 / 1.650 | 1.514 | 2.154 | 15 | 0 |
| Existing analytic shadow | 1.546 / 1.273 | 1.626 | 2.656 | 16 | 0 |
| Blur, source changed every frame | 3.804 / 2.204 | 2.880 | 4.107 | 29 | 404,112 |
| Retained blur, forced ordinary repaint | 3.210 / 2.101 | 1.586 | 2.259 | 16 | 404,112 |

This earlier filter used five taps per axis and RGBA8 intermediate targets.
Its source-changing mode replayed and filtered every frame; retained mode
filtered once then reused the result. See [the original raw run](raw/issue-111-metal-2026-11-04.txt).

## Gaussian native results: Apple M1, macOS 27.2, Metal

Odin `dev-2026-11-nightly:9a69916`, SDL 3.4.18; baseline commit `fe8967f` plus
the retained-effects branch merged with `origin/master` `067ff0c`, plus this
Gaussian implementation. Metal API validation was enabled. One run, 40 warm
samples per mode, 384×256 final target. The effect's resolved output is
192×144 at 1×; at sigma 4 its padded input is 216×168. These are small fixture
results, not a product benchmark or a cross-framework comparison.

| Mode | First encode / submit-wait (ms) | Warm encode p95 (ms) | Warm submit-wait p95 (ms) | Warm render passes | Effect bytes live/peak |
| --- | --- | --- | --- | --- | --- |
| Flat palette | 2.807 / 5.493 | 1.564 | 4.756 | 15 | 0 |
| Existing analytic shadow | 1.618 / 1.428 | 1.634 | 4.731 | 16 | 0 |
| Blur, source changed every frame | 4.055 / 2.141 | 2.986 | 7.997 | 29 | 810,000 |
| Retained blur, forced ordinary repaint | 3.503 / 1.822 | 1.673 | 7.810 | 16 | 810,000 |

The Gaussian source-changing mode replayed the prefix and filtered each time
(82 filter passes over 41 frames). The retained mode filtered once (two filter
passes), then reused that texture for 40 repaints. Each effect mode created
eight SDL objects and uploaded 42,120 effect vertex bytes; source-only changes
did not reupload the filter mesh. Repeated inactive/unchanged requests created
no additional effect resources or submissions. Reset returned charged live
bytes to zero. The 810,000-byte charge is about 0.77 MiB, below the 16 MiB
requested-storage budget. The extra storage reflects RGBA16_FLOAT filter
targets and the full 3σ capture halo.

Nine GPU readbacks (sigma 1/4/8 at scales 1/1.5/2) matched the independent
dense Gaussian reference with worst error 1–2 RGBA8 channel values. The paired
tap counts ranged from 5 to 49; the unit suite checks the maximum 97-tap bound.
Cached-versus-fresh equality, direct fallback identity, and 100 unchanged-cache
requests also passed. These checks establish that the native sampling matches
the specified Gaussian. They do not establish linear-light perceptual output:
the pipeline still filters encoded SDR values, and the sample panel tint remains
strong.

Submission-to-fence wall times in this run varied from 1.428 to 5.493 ms at
first frame and had warm p95 values of 4.731–7.997 ms. These include queue,
driver, and fence-wait costs; they are **not hardware GPU duration** and are
noisy relative to the CPU encoding measurements. Warm encode p95 ranged from
1.564 ms for the flat palette to 2.986 ms when the source changed every frame;
retained blur measured 1.673 ms.

| Check | Result |
| --- | --- |
| Complete `tools/test.sh`, default build | PASS on merged master: AccessKit ABI/external consumer, 321 foundation, 1 accessibility, 39 UI, 35 theme, 152 native, 6 scroll-capture tests, text-input contract, restoration |
| Opt-in native suite | PASS, 163 tests including Gaussian normalization, tiny-sigma underflow, spectral suppression, max-radius, and allocation-bound checks |
| Metal effects readback | PASS, nine dense-Gaussian comparisons; worst error ≤2/255, plus clipping/DPI/alpha/order/cache/invalidation/cancel/reset/fallback |
| Existing Metal blend suite | PASS, 156/156 cases plus motion clip checks |
| Default native-hello idle smoke | PASS, three seconds; one submission/retirement, two event waits, zero application wake events/ticks or motion timers |
| Default binary effect-symbol audit | PASS; no `native_effect_*` symbols in the ordinary host build |
| Vulkan availability on this Mac | UNAVAILABLE: `SDL_HINT_GPU_DRIVER vulkan unsupported!` |
| Hosted Metal readback on PR head `6a5a104` | PASS; [macOS workflow](https://github.com/samanshaiza004/alicorn/actions/runs/42293184017) |
| Hosted D3D12 readback on PR head `6a5a104` | PASS; [Windows workflow](https://github.com/samanshaiza004/alicorn/actions/runs/42293184107) |
| Fresh CI on the integrated head | PENDING |
| Actual device loss / hardware GPU timestamps / real dogfood interaction comparison | UNVERIFIED |

The sandbox cannot enumerate this Mac's displays. The successful Metal runs
used the normal desktop session with elevated execution; this limitation was
not bypassed using a dummy video driver.

Raw Gaussian output: [Metal fixture and readbacks](raw/issue-111-gaussian-metal-2026-11-04.txt); [full foundation suite](raw/issue-111-gaussian-foundation-macos-2026-11-04.txt).

## WebGPU and native validation reconciliation

2026-11-20. This section maps the evidence now held on the SDL_GPU and WebGPU
paths onto the acceptance gate the
[primary-source review](../research/retained-effects-issue-111.md) fixed before
implementation (`docs/research/retained-effects-issue-111.md:51-53`). It adds no
new measurements. **PASS** means the cited record satisfies that criterion
within the scope it states. **PARTIAL** means evidence covers only part of the
required scope. **UNVERIFIED** means no record exists.

### Decision status

The GO recorded in "Scope and decision" is **provisional for the bounded blur
capability**, not a full pass of the original gate. The gate requires two named
real application interactions that visibly and materially beat cheaper
alternatives. Only **one** is documented: Scratchpad Quick Open ("Scratchpad
Quick Open integration"). The research note's second candidate — localized
glow/shadow around ordinary content — is still produced by the existing
analytic materials, and that note's own source review already observed that
many ordinary shape and text glows and shadows need no separate render effect
(`docs/research/retained-effects-issue-111.md:11`). No matched trace compares
Quick Open against a cheaper alternative (opaque panel, cached mask, analytic
treatment) in the real application, so "materially beats the cheaper
alternative" rests on visual review alone.

### Gate criteria

| Gate criterion (`docs/research/retained-effects-issue-111.md:51`) | Status | Evidence |
| --- | --- | --- |
| Two named real app interactions materially beat cheaper alternatives | PARTIAL | Quick Open is the only documented consumer (this report, "Scratchpad Quick Open integration"). Glow/shadow remains analytic (this report, "Scope and decision"; research note line 11). No real-application comparison against a cheap alternative. |
| Measured cold/warm costs fit agreed budgets | PARTIAL | Fixture warm encode/submit p95 exist (this report, "Gaussian native results"), but no absolute product budget was agreed before measuring as the research note requires (line 45), and no application frame-pacing measurement exists. |
| Repeated resize/open/close stays bounded | PARTIAL | The WebGPU D3D12 fixture prepared a resize before the prior effect submission completed, retired the old set, and returned residency to the active set (`docs/validation/webgpu-backdrop-effects-windows-browser-2026-11-15.md:60-65`). The SDL fixture covers reset/recreation and cache reuse (this report, "Validation and measurement boundaries"). Resize/close stress with two frames in flight remains open (same section, remaining-validation list). |
| Failure paths never show stale pixels | PARTIAL | Direct-fallback identity, cancellation, over-budget fallback parity, and the deferred-effect retry are recorded (this report, "Bounded retention and failure behavior"; `docs/validation/webgpu-backdrop-effects-windows-browser-2026-11-15.md:66-69,109-110`). Injected creation/submission failure and device removal are untested, and device loss is not transparently recovered (this report, same section). |
| No-effect control and return to true idle unchanged | PASS (cited scope) | No-effect native idle smoke: one submission/retirement, two event waits, zero application wake events or motion timers, and no `native_effect_*` symbols in the default binary (this report, "Gaussian native results"). Inactive scenes allocate nothing; cached scenes schedule no filter, allocation, submission, timer, or wake (this report, "Bounded retention and failure behavior"). Browser replay requested no animation frames for 500 ms after settling (`docs/validation/webgpu-backdrop-effects-windows-browser-2026-11-15.md:70-75,118-120`). Native idle tracing with an enabled but cached effect remains open. |
| Readback/native evidence covers Metal, Vulkan, D3D12 plus lower-power baseline | PARTIAL | See the backend matrix below. Vulkan is unverified on the Metal host, there is no Metal WebGPU effects readback, no effects evidence in a real native application window, and no integrated/low-power GPU record. |

### Backend matrix

| Backend | SDL_GPU path | WebGPU path |
| --- | --- | --- |
| Metal | PASS. Fixture readbacks on Apple M1 (this report, "Gaussian native results") and hosted readback on PR head `6a5a104` ([macOS workflow](https://github.com/samanshaiza004/alicorn/actions/runs/42293184017)). | UNVERIFIED for effects. No Metal WebGPU effects readback is recorded; the WebGPU effect evidence is Windows and browser only (`docs/validation/webgpu-backdrop-effects-windows-browser-2026-11-15.md:84-95`). |
| D3D12 | PASS. Hosted readback on PR head `6a5a104` ([Windows workflow](https://github.com/samanshaiza004/alicorn/actions/runs/42293184107)). | PASS. Fixture readback, including the two-marker case, on an RTX 2080 SUPER (`docs/validation/webgpu-backdrop-effects-windows-browser-2026-11-15.md:52-69,112-120`). |
| Vulkan | UNVERIFIED. The validation Mac reports `SDL_HINT_GPU_DRIVER vulkan unsupported!` (this report, "Gaussian native results"). | PASS at fixture scale on the RTX 2080 SUPER (`docs/validation/webgpu-backdrop-effects-windows-browser-2026-11-15.md:116-117`), plus browser WebGPU readback with the adapter acceleration class unclassified (`docs/validation/webgpu-backdrop-effects-windows-browser-2026-11-15.md:70-75`). |
| Real native application window | PARTIAL. Quick Open is user-reviewed on the interactive Mac; there is no scripted or readback capture of the application window (this report, "Scratchpad Quick Open integration"). | UNVERIFIED. The native WebGPU UI records cover smoke, text, UIA, and window lifecycle without effects (`docs/validation/native-webgpu-ui-windows-2026-11-16.md:7-50`; `docs/validation/native-webgpu-ui-interactive-windows-2026-11-19.md:10-12,70-94`). |
| Lower-power / integrated GPU | UNVERIFIED. | UNVERIFIED. |
| Genuine device loss | UNVERIFIED. Actual device removal and injected submit failure are untested, and recovery is not transparent (this report, "Bounded retention and failure behavior"). | UNVERIFIED for the effect cache. Induced D3D12 removal covers the wider host, not this cache (`docs/validation/webgpu-native-backend-removal-windows-2026-11-19.md`), and the migration tracker still counts genuine driver loss as open (`docs/webgpu-migration.md:88-90`). |

### Deferral triggers

| NO-GO trigger (`docs/research/retained-effects-issue-111.md:53`) | Finding |
| --- | --- |
| Analytic geometry/cached masks suffice | Not settled. No real-application comparison exists, and the glow/shadow interaction is still analytic, so this trigger stays live for that interaction. |
| Only one interaction benefits | **Present.** This is why the GO is provisional rather than a gate pass. |
| Backdrop capture requires mandatory whole-window composition | Avoided. The capability captures a bounded paint prefix and otherwise draws directly; there is no full-window target (this report, "Bounded retention and failure behavior"). |
| Correctness depends on undefined contents/aliasing | Avoided in the validated cases. Source and destination never alias, slots are fence-tracked and non-cycling, and load/store discipline is explicit (this report, "Boundary and rendering contract"). |
| Memory grows with cycling/in-flight work | Not observed. Fixture live/peak charges returned to zero on reset and the application cache is two bounded slots, but driver residency and allocation churn are unmeasured (this report, "Validation and measurement boundaries"). |
| Color contract unresolved | Resolved by an explicit decision, not by linear-light filtering; see the accepted deviation below. |
| Static scenes acquire new work | Avoided in the cited idle evidence. |

### Accepted deviation: encoded-SDR filtering

The research note prefers linear-light color filtering and treats the color
contract as a gate input (`docs/research/retained-effects-issue-111.md:31,51`).
The shipped slice filters encoded SDR RGBA8 values through capture, both
Gaussian passes, and composition, matching the ordinary UNORM renderer
("Boundary and rendering contract"). This is an accepted, documented deviation
scoped to this feature slice: HDR, sRGB render targets, wide-gamut/native
display color management, and rounded output masks stay unimplemented, and
changing the whole renderer's color contract remains outside the slice. The
readbacks establish numeric agreement with the CPU Gaussian in encoded space;
they do not establish linear-light perceptual output. The WebGPU compositor
inherits the same encoded-SDR filtering and records no SDR parity across output
formats (`docs/validation/webgpu-backdrop-effects-windows-browser-2026-11-15.md:84-95`).

### What the recorded numbers do and do not measure

- All SDL_GPU timing rows are fixture-scale: a 384×256 final target with a
  192×144 effect output, run in a warmed process after correctness probes
  (this report, "Gaussian native results"). They are not product benchmarks and
  the first frames are not cold application or driver startup.
- Submission-to-fence wall time includes queue, driver, and fence-wait costs
  and is **not hardware GPU duration**; SDL_GPU exposes no portable timestamp
  query used by the fixture, so no GPU-time figure exists on either path
  (this report, "Validation and measurement boundaries").
- The WebGPU residency figures (74,120 bytes active, 100,040 bytes peak under
  the 48 MiB aggregate budget) are tracked mesh+texture allocations, not total
  device residency or driver memory
  (`docs/validation/webgpu-backdrop-effects-windows-browser-2026-11-15.md:54-56`).
  Hardware GPU time and residency measurements remain open on both paths.

### Out of scope

General shader compilation and shader libraries, a material or effect graph,
GPU PBR/GI, and any v0.3 ship commitment remain out of scope for this record and
are not advanced by the evidence above. This reconciliation amends only the
issue #111 decision record.

## Visual comparison

These deterministic captures show the same static palette/content scene, not
live dogfood screenshots. They were inspected locally after the Gaussian and
opaque-prefix corrections. The Gaussian capture removes the sparse-sampling
replicas seen in the prior version. This sample still uses encoded-SDR
filtering and a strong panel tint; it does not establish a finished
frosted-glass treatment or a second useful application need.

| Flat palette | Direct analytic shadow | Retained backdrop blur |
| --- | --- | --- |
| ![Flat palette](assets/issue111-flat.png) | ![Analytic shadow](assets/issue111-analytic-shadow.png) | ![Retained blur](assets/issue111-blur-retained.png) |

The production API intentionally remains narrow: one bounded backdrop blur
request on a semantic surface, an explicit direct fallback, and host-owned
resource lifetime. The Gaussian implementation and Quick Open consumer are
now part of Alicorn/Scratchpad; backend parity and the remaining stress cases
above are still validation work.
