# Deferred system fallback faces — Issue #172 phase 2, Windows

Date: 2026-11-22 (local capture)

This is phase 2 of issue #172. Phase 1
([`native-startup-attribution-windows-2026-11-21.md`](native-startup-attribution-windows-2026-11-21.md))
measured the fonts phase at 119–123 ms p50 in every app and attributed about
66 MiB of runtime-requested bytes to the 12 DirectWrite system fallback faces.
This report prototypes the ranked candidate #1: resolve the system fallback
stack on the first shaping request that actually needs it instead of during
startup, and measure the paired startup, memory and — critically — the deferred
stall at the moment it fires.

The change is a bounded lazy-initialization prototype, not an adopted
optimization. **Recommendation: NO-GO as prototyped**, because the deferred work
lands as a synchronous 116–121 ms stall on the first text that needs a system
face. The startup and memory win is real and measured; the blocker is the
interaction latency, and this report quantifies both.

## What the 66 MiB is

The eager stack is built by `host/fonts/fonts_windows.odin`:
`load_directwrite_fallback_faces` asks DirectWrite's
`IDWriteFontFallback::MapCharacters` for one locale-aware sample per entry and
then reads the mapped face's **whole font file** through the local font file
loader. `text_engine_font_file_load_bytes` retains one deduplicated copy of each
file for the runtime's lifetime and `text_engine_font_face_load` parses a Runa
face from it.

A one-off in-package diagnostic (not part of the commit) enumerated the 12
samples on the capture host:

| Sample | Locale | File bytes | Face index |
| --- | --- | ---: | ---: |
| 語 | en-US (takes the preferred Han locale) | 13,742,180 | 1 |
| 日本語 | ja-JP | 13,742,180 | 1 |
| 简体中文 | zh-CN | 19,704,352 | 1 |
| 繁體中文 | zh-TW | 21,402,152 | 1 |
| 한국어 | ko-KR | 13,457,164 | 0 |
| سلام | ar-SA | 955,804 | 0 |
| 🎉 | en-US | 2,072,388 | 0 |
| ❤️ | en-US | 2,072,388 | 0 |
| 👍🏽 | en-US | 2,072,388 | 0 |
| 👩‍💻 | en-US | 2,072,388 | 0 |
| 1️⃣ | en-US | 955,804 | 0 |
| 🇯🇵 | en-US | 2,072,388 | 0 |
| **raw read total** | | **94,321,576** | |

The runtime deduplicates identical file bytes, then registers only faces Runa
can parse. A second one-off diagnostic loaded the eager stack and printed the
registry inventory:

```
diag_eager files 5 faces 5 font_file_bytes 57876876
           fallback_ui_loaded true fallback_mono_loaded true
           live 69266072
```

So the eager `fonts_requested_bytes` of 65.7–66.0 MiB decomposes as:

| Component | Bytes |
| --- | ---: |
| 5 registered DirectWrite files/faces (Japanese 13.74 MB, Simplified Chinese 19.70 MB, Traditional Chinese 21.40 MB, emoji 2.07 MB, Arabic/keycap 0.96 MB) | 57,876,876 |
| Korean file read but not registered (Runa face parse produced no face) | (13,457,164 read, not retained) |
| Optional UI fallback `NotoSansJP-VF.ttf` | 9,590,844 |
| Optional monospace fallback `consola.ttf` | 459,180 |
| Runa face structures and runtime bookkeeping (live − files − optional) | ~1,339,172 |
| **total runtime requested live after the eager stack** | **69,266,072 (66.06 MiB)** |

The loader's `loaded_faces` count is 7: five DirectWrite samples that added a
face, plus the two optional role faces. It is not seven DirectWrite faces. The
cost is the **font file copies plus their Runa face parse**, not the text atlas
or the glyph cache: the text atlas transfer buffer is a separate 4 MiB declared
resource and first-frame glyph bytes were 6,264 B in phase 1.

The eager path also reads each sample into the scratch/temp allocator before
dedup, so it transiently touches the 94.3 MB raw total in addition to the
retained copies. That is why the settled working-set difference below is larger
than the 66 MiB runtime figure.

## The prototype

Smallest defensible change, one deferred unit (the whole platform stack):

- `runtime/text.odin`: a `Text_Engine` may be armed with a host
  `Text_System_Fallback_Loader`. `text_run_build` shapes as usual; if any
  cluster is still `unresolved_fallback`, it calls the loader once, rebuilds the
  face stack and reshapes once. The loader is **never** called again in that
  process, and there is no timer, worker or idle work.
- `host/fonts/fonts.odin`: `load_default_fonts(rt, defer_system_fallbacks)`
  splits the canonical stack into bundled faces (always eager) and
  `load_system_fallback_fonts` (DirectWrite + optional UI/monospace faces); the
  latter is also the armed loader body.
- `native/sdl_gpu`: `--eager-system-fonts` reproduces the pre-change startup in
  the same binary for the paired baseline arm; `--fallback-probe-after-first-frame`
  is a measurement-only probe that shapes `日本語 🎉 →` immediately after the
  first application submit, on the same `text_run_build` path a first CJK/emoji
  text entry uses.
- Startup markers gained `deferred_system_font_faces`, `..._ns`, `..._at_ns`
  (from the host origin) and `..._before_first_submit`, plus the probe's
  `fallback_probe_*` fields.

Trigger precision: the decision point is Runa's cluster-atomic
`unresolved_fallback` result, not a codepoint pre-scan. A run that the loaded
stack covers completely never touches the loader. One miss attempts the load
once; a miss that no platform face resolves is terminal instead of re-querying
the platform on every later run.

## Method

Host: Windows 10 Home build 19045, AMD Ryzen 5 7600X (6 cores, 12 logical),
15.2 GiB visible, NVIDIA GeForce RTX 2080 SUPER (driver 32.0.15.9597),
Direct3D 12 through SDL 3.4.20. CPU load was 3 % at the start and 47 % at the
end of the series; other desktop applications were running. Odin
`dev-2026-11-nightly:08539cd`, Go 1.27.1, Cargo 1.98.1.

Builds:

| App | Source | Build |
| --- | --- | --- |
| Hello | `examples/01_hello` in this worktree | `odin build -o:speed`, `-collection:alicorn=<this worktree>` |
| Scratchpad | clone at `adb28fc2` | `go run ./cmd/alicorn-dev build --alicorn-root <this worktree> --allow-alicorn-revision --release --renderer=sdl-gpu` |
| Punks | clone at `0296473`; own pinned `alicorn-kit`; frontend compiled against this worktree with `-collection:alicorn=<this worktree>` | `cargo build -p punks-caliber --release`, then `odin build punks-standalone/odin -o:speed` |

Both arms are the **same executable**; only the extra argument differs
(`prototype`: none, `baseline`: `--eager-system-fonts`). The baseline branch is
taken before the first frame and calls the pre-change startup function with the
pre-change argument order, so it is the master `edd5a1f` path with no other
difference.

Protocol per app (`tools/bench_startup.ps1 -Paired -Runs 12`):

- one unmeasured file-cache warmup per arm;
- 12 measured rounds; each round launches prototype and baseline back to back,
  alternating which arm goes first, so monotonic drift cancels;
- fresh `APPDATA`/`LOCALAPPDATA` per Scratchpad launch and the generated
  193-file workspace (8 project directories × 24 files, one 5,000-line
  `sample_00.go`, plus README);
- Hello and Scratchpad used the harness `--idle-validation-seconds=3`; Punks
  used `--smoke --folder crates/punks-audio/tests/fixtures`;
- separate 6-round paired series with `--fallback-probe-after-first-frame` on
  both arms, to measure the deferred work itself;
- separate 4-round paired series with `--idle-validation-seconds=20` for warm
  memory;
- one 8-round Scratchpad A/A control with **both** arms eager, to test whether
  Scratchpad's `on_start` jitter is arm-dependent (it is not; see below).

All launches are warm-order. There was no reboot, cache purge or page-file
control. Times are host-tick markers from the host startup origin; `window_shown`
is after `SDL_ShowWindow`, `first_application_submit` is a GPU submission (not a
visible pixel), and `first_input_ready` is the first completed event pump.

## Paired A/B results

p50 / p95 over 12 paired rounds. Times in ms, memory in MiB. `Δ` is the median
of the 12 per-round `prototype − baseline` differences (negative = prototype
lower), with the number of rounds the prototype was lower.

### Hello

| Metric | Prototype | Baseline | Δ median | Rounds lower |
| --- | ---: | ---: | ---: | ---: |
| Window shown | 426.1 / 966.2 | 615.3 / 1,055.9 | −114.2 | 9/12 |
| First application submit | 429.0 / 968.5 | 617.6 / 1,058.2 | −121.2 | 9/12 |
| First input ready | 426.2 / 966.4 | 615.5 / 1,056.1 | −114.2 | 9/12 |
| Fonts phase | 0.23 / 0.27 | 117.80 / 122.95 | **−117.6** | **12/12** |
| Initial app build | 4.02 / 4.51 | 4.14 / 4.45 | +0.0 | 6/12 |
| GPU device create | 375.4 / 923.7 | 461.4 / 906.2 | +8.0 | 6/12 |
| Working set at settle | 97.1 / 97.3 | 254.0 / 254.0 | **−164.5** | **12/12** |
| Private bytes at settle | 136.1 / 138.0 | 316.6 / 318.7 | **−189.2** | **12/12** |
| GPU dedicated at settle | 37.7 / 37.7 | 37.7 / 37.7 | 0.0 | — |
| GPU shared at settle | 33.8 / 34.0 | 33.8 / 33.8 | 0.0 | — |
| Runtime requested live / peak | 1.5 / 1.5 | 67.1 / 67.1 | **−68.9** | **12/12** |
| Runtime fonts phase requested | 367,160 B | 69,220,684 B | — | — |

The `window_shown` delta (−114 ms) matches the fonts-phase saving; the rest of
the window path is unchanged (initial build 4 ms, renderers, GPU device create).

### Scratchpad

| Metric | Prototype | Baseline | Δ median | Rounds lower |
| --- | ---: | ---: | ---: | ---: |
| Window shown | 968.5 / 1,736.5 | 551.8 / 1,542.6 | +339.7 | 4/12 |
| First application submit | 971.9 / 1,739.8 | 555.2 / 1,546.0 | +341.5 | 4/12 |
| First input ready | 968.9 / 1,736.8 | 552.1 / 1,542.9 | +339.8 | 4/12 |
| Fonts phase | 0.00 / 0.00 | 118.75 / 121.42 | **−118.8** | **12/12** |
| Initial app build | 1.43 / 1.70 | 1.56 / 1.99 | −0.1 | 8/12 |
| GPU device create | 525.6 / 1,068.3 | 292.6 / 917.7 | +106.9 | 3/12 |
| Working set at settle | 111.5 / 112.0 | 268.3 / 268.7 | **−164.5** | **12/12** |
| Private bytes at settle | 205.4 / 206.6 | 382.7 / 385.1 | **−185.7** | **12/12** |
| GPU dedicated at settle | 43.3 / 43.3 | 43.3 / 43.3 | 0.0 | — |
| Runtime requested live / peak | 1.9 / 2.0 | 67.6 / 67.6 | **−68.9** | **12/12** |
| Runtime fonts phase requested | 0 B | 68,853,458 B | — | — |

**Scratchpad's window numbers are not resolvable at n=12.** The app spends
0–1,300 ms in `on_start` (host loop setup) waiting on its own Go/Caliber
backend; that wait is bimodal (p50 90–273 ms, p95 641–1,190 ms across the
series) and arm-independent. Two independent 12-round series disagree in sign:
this one is +340 ms for the prototype, an immediate replicate is −223 ms, and
the 8-round A/A control with **both** arms eager also makes the "prototype"
label 48 ms slower (831 vs 783 ms p50) with `on_start` ranging 61–862 ms. The
fonts phase (12/12 rounds, −118.8 ms) and memory (12/12 rounds) are deterministic
and are the numbers this app supports.

### Punks

| Metric | Prototype | Baseline | Δ median | Rounds lower |
| --- | ---: | ---: | ---: | ---: |
| Window shown | 506.9 / 1,308.1 | 721.3 / 1,436.5 | −118.3 | 9/12 |
| First application submit | 510.5 / 1,311.4 | 724.6 / 1,439.9 | −118.5 | 9/12 |
| First input ready | 507.1 / 1,308.2 | 721.4 / 1,436.7 | −118.3 | 9/12 |
| Fonts phase | 0.20 / 0.23 | 117.24 / 121.42 | **−117.1** | **12/12** |
| Initial app build | 5.11 / 5.38 | 5.21 / 5.40 | −0.1 | 11/12 |
| GPU device create | 472.5 / 1,274.9 | 556.9 / 1,278.6 | +3.6 | 5/12 |
| Working set at settle | 105.5 / 105.8 | 196.8 / 196.9 | −95.8 | 7/7 |
| Peak working set | 111.9 / 112.1 | 268.7 / 269.0 | — | — |
| Private bytes at settle | 154.6 / 157.3 | 268.5 / 270.3 | −120.6 | 7/7 |
| GPU dedicated at settle | 49.5 / 49.5 | 49.5 / 49.5 | 0.0 | — |
| Runtime requested live / peak | 2.4 / 2.5 | 68.1 / 68.1 | **−68.9** | **12/12** |

Punks exits immediately after its smoke PASS line, so the 10 ms sampler missed
the settle sample in 6 of 24 launches (4 prototype, 2 baseline); the paired
working-set columns therefore use the 7 complete pairs. The peak working set is
unaffected by that race and shows the eager 66 MiB transient (268.7 MiB peak vs
196.8 MiB settle) that the prototype does not touch (111.9 vs 105.5 MiB).

### Warm memory over a 20 s idle sample

p50 of 4 paired rounds with `--idle-validation-seconds=20`:

| App | Arm | Working set | Private bytes | Peak working set |
| --- | --- | ---: | ---: | ---: |
| Hello | prototype | 95.3 | 135.0 | 97.1 |
| Hello | baseline | 251.4 | 315.7 | 254.0 |
| Scratchpad | prototype | 112.1 | 209.5 | 112.4 |
| Scratchpad | baseline | 268.4 | 386.7 | 269.3 |

The 20 s sample keeps the same deltas as the 3 s sample: about −156 MiB working
set and −180 MiB private bytes in Hello and Scratchpad. No additional wake-up
appears in either arm (`motion_timer_wakes` 0, `native_host_wake_events` 0 in
Hello; 1 in both Scratchpad arms from the app's own backend).

## The deferred hitch

The probe series runs `text_run_build("日本語 🎉 →", 16)` immediately after the
first application submit. That is the exact path a first CJK/emoji paste or
first CJK edit takes; only the input event dispatch is skipped.

| App | Arm | Loader faces added | Deferred load | Fires at (from origin) | Probe build | Fallback glyphs | Unresolved |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Hello | prototype | 7 | **121.3 ms** (p95 122.4) | 366.8 ms (submit 366.8) | 121.3 ms | 5/7 | 0 |
| Hello | baseline | 0 | 0 | — | 0.04 ms | 5/7 | 0 |
| Scratchpad | prototype | 7 | **116.4 ms** (p95 122.0) | 1,104.7 ms (submit 1,104.7) | 116.4 ms | 5/7 | 0 |
| Scratchpad | baseline | 0 | 0 | — | 0.04 ms | 5/7 | 0 |
| Punks | prototype | 7 | **120.9 ms** (p95 124.6) | 445.3 ms (submit 445.3) | 121.0 ms | 5/7 | 0 |
| Punks | baseline | 0 | 0 | — | 0.05 ms | 5/7 | 0 |

"Loader faces added" is the loader's return count: 5 registered DirectWrite
faces plus the optional Noto Sans JP and Consolas role faces. Baseline reports 0
because the same 7 were added during startup, before the counter snapshot.
Every prototype probe fire is *after* the first application submit
(`deferred_system_font_before_first_submit` 0 in all 18 prototype probe
launches), i.e. the first frame was already submitted before the stall; a real
interaction pays it in the next frame's build.

Facts the A/B establishes:

1. **The deferred load never fires during the startup of these three apps.**
   All 36 measured launches (3 apps × 12 paired rounds) report `deferred_system_font_faces 0`
   and a 0 ns deferred load; the first frame of Hello, Scratchpad
   and Punks contains only text the bundled Atkinson faces cover. The fonts
   phase is therefore empty in the prototype arm, not merely moved into
   `build_initial` (initial build is unchanged at 1.4–5.1 ms).
2. **The hitch is bounded and one-time.** It is a single 116–121 ms
   synchronous load of the whole platform stack (5 DirectWrite faces + 2
   optional role faces, 68 MB of retained font files, 70.4 MB runtime live
   after the load); a second fallback run in the same process reuses the stack
   (`system_fallback_ns` does not change; pinned by the new `host/fonts` test).
3. **It is user-visible when it fires.** The load happens inside
   `text_run_build`, i.e. in the frame that first needs the glyphs, before that
   frame's submit. A 120 ms frame is about seven 60 Hz frames: a visible freeze.
   For a Scratchpad user who pastes Japanese into an otherwise Latin document,
   the 120 ms stall lands on that first paste.
4. **It is deterministic and per-process, not per-glyph.** The whole 12-sample
   stack loads on any miss, including a miss no platform face can fix (a
   private-use codepoint). That last case is the worst shape: 120 ms and 66 MiB
   for no rendered glyph.

## GO / NO-GO

Issue #172's acceptance rule is explicit: a faster launch that defers a visible
hitch to the first text input is a regression, not a win. The prototype does
exactly that: it removes a 117–119 ms startup phase and 66 MiB of retained
runtime bytes, and in exchange introduces a 116–121 ms synchronous freeze the
first time a process shapes text that needs a platform face. That freeze is
bounded and rare (only users who use non-Latin scripts, once per process), but
it is visible and it is on an interaction path that was previously instant.

**NO-GO for adoption as prototyped.** The measured win is real — −117 ms
`fonts_ns` (12/12 paired rounds in all three apps), −114/−118 ms window-shown in
Hello/Punks, −69 MiB runtime-requested live, −96 to −165 MiB working set and
−121 to −189 MiB private bytes at settle, unchanged at 20 s idle — but it fails
the issue's interaction-latency bar.

What would make it a GO: a follow-up that bounds the first-need load to a
non-interactive window. The two measured options are:

- **Per-need face mapping.** Pass the unresolved run's text to the loader and
  let DirectWrite map only those codepoints, loading 1–2 faces instead of the
  whole stack. From the per-sample table, first Japanese text would read 13.7 MB
  (one face) instead of 57.9 MB of DirectWrite files plus 10.1 MB of optional
  faces; first emoji text 2.1 MB. Scaling the measured 120 ms by bytes suggests
  roughly 20–40 ms, still visible but much smaller. This is not measured here
  and should be prototyped and paired before any claim.
- **An explicit product decision** to accept a one-time first-CJK stall in
  exchange for the startup/memory win on every launch (e.g. a preference, or
  only on machines where the fallback stack is large). That is a product call,
  not a benchmark result.

Until one of those exists, the eager stack should stay. The attribution table
and the per-sample file costs remain the primary deliverable, and they say the
66 MiB is exactly six system font files read and retained eagerly, not atlas or
cache growth.

Candidate #2 (lazy icon-atlas upload + `SDL_WaitForGPUIdle` removal,
4.8–5.4 ms p50, 1.84 MB) was **not** prototyped: candidate #1's trigger was
cleanly available and did not fire at startup, so the pivot rule did not apply.
It remains the next candidate with a much smaller, but also non-interactive-if-
deferred-to-first-icon-frame, upside.

## Regression checks

| Check | Result |
| --- | --- |
| `odin test runtime` | 511 tests, all successful |
| `odin test native\sdl_gpu` | 172 tests, all successful |
| `odin test host\fonts` (incl. new lazy test) | 6 tests, all successful |
| `odin test host\diagnostics` | 9 tests, all successful |
| `odin test ui` | 57 tests, all successful |
| `odin test native\scroll_capture_tests` | 6 tests, all successful |
| `out\alicorn_tests.exe` (foundation) | PASS |
| `--text-input-contract-test` | PASS |
| Scratchpad frontend suite (`alicorn-dev test`, revision in manifest) | 257 tests, all successful |
| `tools\validate_icons.ps1` equivalent (D3D12) | atlas 1,835,008 B, 2 uploads, transparent source-over true |
| `tools\validate_images.ps1` equivalent | scales 1/1.25/1.5/2, SDR + SDR_LINEAR, fidelity/source-over true |
| `tools\validate_rectangles.ps1` equivalent (D3D12) | `issue_200_idle` PASS: 0 layout/paint/text visits, no pending idle submission or surface work |
| Font fallback correctness | new `host/fonts` test: Latin text does not trigger; first Japanese+emoji run triggers exactly once, resolves 5/7 glyphs through fallback faces, leaves no `unresolved_fallback`; later Chinese text reuses the stack. Probe launches in all three apps independently resolve 7 glyphs, 5 fallback, 0 unresolved in both arms |
| Device loss/recreate | not applicable: the prototype defers no GPU resource, pipeline or device object; only CPU font faces move |
| DPI | fonts are rasterized per display scale; the deferred load registers faces only, and image validation covered 1/1.25/1.5/2 |

The new test is the only code-level regression guard added: it pins that Latin
text leaves `system_fallback_*` untouched, that the first uncovered run loads
once and reshapes to resolved glyphs, and that a later fallback run does not
reload.

## What this cannot attribute

- The 117–119 ms is a single host phase; the split between DirectWrite mapping,
  file read, the runtime copy, the Runa face parse and the scratch-allocator
  growth is not separated. The per-sample file sizes bound the read/copy part.
- Runa may parse parts of each face lazily or retain extra tables; the
  `fonts_requested_bytes` figure is allocator-requested bytes, not resident.
- The working-set/private deltas are larger than 66 MiB because the process and
  the allocator touch transient copies and because Windows commit accounting is
  not the same as requested bytes. The conservative statement is "the eager
  path adds about 96–165 MiB of working set at settle and about 121–189 MiB of
  private bytes".
- The probe measures the load plus one short shape, not an input event round
  trip. The frozen frame is at least as long as the load; event dispatch is
  small compared with 116–121 ms.
- Scratchpad's window timings are backend-noise-limited at n=12, as documented
  above; its fonts and memory numbers are deterministic.
- macOS/Linux: the loader hook is platform-neutral but only the Windows
  DirectWrite path is measured. Linux fontconfig resolution and macOS system
  faces have their own costs.

## Reproduction

```powershell
# Paired startup A/B (same binary; baseline adds --eager-system-fonts)
.\tools\bench_startup.ps1 -App hello -Runs 12 -Paired -HelloExe .\out\hello-lazy.exe `
  -CompareArmArguments '--eager-system-fonts' `
  -ResultsDirectory docs\benchmarks\raw\native-startup-deferred-fallback-windows-2026-11-22\hello

# Deferred-hitch probe
.\tools\bench_startup.ps1 -App hello -Runs 6 -Paired -HelloExe .\out\hello-lazy.exe `
  -PrimaryArmArguments '--fallback-probe-after-first-frame' `
  -CompareArmArguments '--eager-system-fonts','--fallback-probe-after-first-frame' `
  -ResultsDirectory docs\benchmarks\raw\native-startup-deferred-fallback-windows-2026-11-22\probe-hello

# Paired analysis
.\docs\benchmarks\raw\native-startup-deferred-fallback-windows-2026-11-22\analyze_pairs.ps1
```

Raw evidence, including per-launch CSV/JSON, logs, the copied runner, the
A/A control, the paired analysis and the manifest, is in
[`raw/native-startup-deferred-fallback-windows-2026-11-22/`](raw/native-startup-deferred-fallback-windows-2026-11-22/).
