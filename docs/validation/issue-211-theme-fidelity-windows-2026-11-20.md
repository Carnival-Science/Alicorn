# Theme color fidelity across the Scratchpad presentation matrix

Windows x64, NVIDIA GeForce RTX 2080 SUPER, 2026-11-20

Alicorn `codex/issue-211-scratchpad-webgpu` (this slice, `3596387` + changes)
Scratchpad `codex/issue-211-webgpu-frontend` @ `b458d6e`, candidate root,
`--allow-alicorn-revision`, no Scratchpad source or lock change.

Founder finding: syntax highlighting on the hosted build "seems to work, the
colors are just super subtle". Earlier evidence only covered one Go-editor scene
with one theme. This slice runs a matched real-application matrix before
changing anything: if hosted and reference are pixel-identical, the subtlety is
theme design; only a difference would be a renderer regression.

## Method

One Scratchpad build (`out/c4/scratchpad-alicorn.exe`, Alicorn `3596387`) serves
every leg; the host is selected with `SCRATCHPAD_RENDERER` (`sdl-gpu` or
`webgpu`) and the hosted GPU backend with `--backend=`.

The restored session is the founder's real Scratchpad session
(`%APPDATA%\Scratchpad\session.json`), copied into a fixture per scene. Every leg
of a scene gets the same session bytes, the same `preferences.json` theme, the
same 1216x799 window at 100% DPI, and the same capture arguments
(`--diagnostics --capture-dir=... --capture-after=600`). Theme selection uses the
app's own preference path so the capture shows the real chrome, not a fixture
that also opens Settings.

Scenes:

| Scene | State |
| --- | --- |
| `go-editor` | restored session, `language/detection.go` active (Go, Tree-sitter spans) |
| `markdown` | restored session, `README.md` active (markdown headings, inline code, fences) |
| `json-document` | restored session with `caliber.config.json` in the detection.go tab |
| `pinned` | `go-editor` plus `SCRATCHPAD_PINNED_FIXTURE=1` (two pinned ranges) |
| `workbench-start` | no session file: the workbench start screen |

Themes: `warm` (default; workbench chrome + paper editor palette), `cool-light`,
`charcoal-ink`, all with the founder's `workbench-relief` surface treatment.

Each leg is captured twice through F12; the harness requires the two frames to be
byte-identical before it accepts the second, so every number below is a settled
frame. `tools/compare_backends.ps1` backed up and restored the real session and
preferences around the run with SHA-256 verification.

## Comparison matrix

Full frame is 1216x799 = 2,914,752 channels. Candidate vs `sdl-gpu` reference.

| Scene | Theme | webgpu-d3d12 | webgpu-vulkan |
| --- | --- | --- | --- |
| go-editor | warm | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| go-editor | cool-light | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| go-editor | charcoal-ink | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| markdown | warm | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| markdown | cool-light | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| markdown | charcoal-ink | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| json-document | warm | 1113 / 2914752 (0.04%), max 319 | 1113 / 2914752 (0.04%), max 319 |
| json-document | cool-light | 1116 / 2914752 (0.04%), max 550 | 1116 / 2914752 (0.04%), max 550 |
| json-document | charcoal-ink | 1113 / 2914752 (0.04%), max 308 | 1113 / 2914752 (0.04%), max 308 |
| pinned | warm | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| pinned | cool-light | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| pinned | charcoal-ink | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| workbench-start | warm | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| workbench-start | cool-light | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |
| workbench-start | charcoal-ink | 0 / 2914752 (0.00%), max 0 | 0 / 2914752 (0.00%), max 0 |

27 of 30 comparisons are byte-identical. In the three `json-document` scenes the
difference is confined to the status strip:

| Region (json-document/cool-light) | Differing channels | Max | Mean | Bounding box |
| --- | --- | --- | --- | --- |
| full frame | 1116 / 2914752 | 550 | 0.0387 | (415,774)-(494,783) |
| editor-body | 0 / 1909440 | 0 | 0.0000 | - |
| sidebar | 0 / 717120 | 0 | 0.0000 | - |
| window-chrome | 0 / 145920 | 0 | 0.0000 | - |
| status-strip | 1116 / 142272 | 550 | 0.7937 | (415,774)-(494,783) |

The pixels are the app's conditional **"Editor focused"** status cue: the hosted
legs draw it, the reference does not
(`assets/issue-211-status-cue-hosted.png`, `-reference.png`). Both hosted backends
are identical to each other; the editor, tab strip, sidebar and chrome are
byte-identical to the reference, and every syntax-token pixel is identical.

### Why the cue differs (bisected)

This is not a paint, material, or color difference. The cue is application text
`app_editor_view.odin:1204`, drawn only when
`editor_focus_needs_status_cue` finds the editor focused and its caret either
unrealized (`editor_input_anchor_node == 0`) or outside the scroll viewport.

An env-gated trace of `begin_frame`, `focus` and `text_node_caret_geometry`
(build-time only, removed before commit) shows both hosts run the same startup
sequence, and the reference runs **one more describe turn** after it:

```text
reference: frame-begin focused=0
           focus-trace owner=12670298533246491620 previous=0
           frame-begin focused=owner  x2      native-passes 3
           frame-begin focused=owner
           caret-trace anchor found=false     <- status built from the previous pass
           native-passes 1
           frame-begin focused=owner
           caret-trace anchor found=true      <- cue cleared
           native-passes 1

hosted:    frame-begin focused=0
           focus-trace owner=12670298533246491620 previous=0
           frame-begin focused=owner  x2      hosted-passes 3
           frame-begin focused=owner
           caret-trace anchor found=false     <- status built from the previous pass
           hosted-passes 1                    <- no further turn; stale cue presented
```

The app's status strip is described before the virtual list realizes the caret
line's retained node, so the first build in a turn reads the previous pass's
anchor id; the reference's extra turn resolves it. The hosted host services the
same invalidation set but presents one fewer turn, so the app's last frame keeps
the stale cue. That is a host turn/scheduling parity gap with a visible
application-state label, not a renderer color regression: the same app state
paints identical pixels on both hosts, which is what the other 27 comparisons
show.

No runtime or host change is made in this slice. The known-good workaround for
future capture comparisons is to include a scene with a caret in view *and* a
warm-up interaction, or to treat this label as an application-state exclusion.
The follow-up slice should make the hosted loop present the same final turn as
`native/sdl_gpu` (or make the app's status read the current pass's anchor); both
are outside theme color fidelity.

## Verdict

- **Theme color fidelity: parity holds.** For the same application state the
  hosted D3D12 and Vulkan frames are byte-identical to the SDL_GPU reference
  across 5 scenes x 3 themes (27/30), including all syntax-token colors,
  selection, chrome, pinned editor, and the start screen.
- The founder's "super subtle" is **theme/presentation-contract design**, not a
  hosted renderer regression. The one mismatch is an application status label
  driven by a stale focus/caret anchor, reproduced on both hosted backends and
  absent from every colored region.

## Why the colors are subtle (measured)

Both hosts follow the documented contract (`docs/themes.md`): theme channels are
linear-sRGB after the compiler's sRGB decode, and they are written unchanged into
a non-sRGB swapchain. The displayed color is therefore the *linear* channel value
interpreted as an sRGB code, not the authored sRGB color. The palette the
designer picked never appears on screen on either host.

Measured on the captured Go editor (`go-editor/cool-light`, both hosts identical):

| Surface | Authored (`themes/*.json`) | Displayed (both hosts) |
| --- | --- | --- |
| editor background | `#fafbfe` | `#f4f6fd` |
| body text | `#121a26` | `#020305` |
| keyword | `#604a88` | `#1e113f` |
| string | `#7a502b` | `#321406` |
| comment | `#53657a` | `#162132` |

The decode compresses every dark value toward black. That preserves contrast
against the light background (which is why the text is readable) but collapses
the *token-to-plain-text* difference: all syntax colors approach the same
luminance as ordinary identifiers.

The captured bytes match those computed values within one code value (the GPU
rounds the linear channel either side of the tool's `round()`); the dominant
colors in the Go editor band are exactly `#f4f6fd`, `#0a0f16` and `#1e113f` for
cool-light, `#f0ebdb`, `#12120e` and `#211131` for warm, and `#060607`,
`#ccc2af`, `#88435f` for charcoal-ink.

WCAG 2.1 contrast and CIE76 dE, computed from the generated style files the app
compiles (`frontends/alicorn/style_*_generated.odin`, read-only). "Baseline" is
the `syntax.variable` role, which is how Scratchpad paints most plain
identifiers:

### cool-light (`#f4f6fd` displayed background, baseline `#0a0f16`)

| Token | Displayed | vs bg | vs baseline | dE | Authored | vs bg (intent) | vs baseline (intent) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| keyword | `#1e113f` | 16.11:1 | 1.10:1 | 30.6 | `#604a88` | 7.17:1 | 1.34:1 |
| function | `#071733` | 16.49:1 | 1.08:1 | 17.3 | `#2f557c` | 7.49:1 | 1.28:1 |
| string | `#321406` | 15.70:1 | 1.13:1 | 23.7 | `#7a502b` | 6.74:1 | 1.42:1 |
| comment | `#162132` | 14.99:1 | 1.19:1 | 11.7 | `#53657a` | 5.78:1 | 1.66:1 |
| number | `#041a2c` | 16.35:1 | 1.09:1 | 11.0 | `#245a73` | 7.29:1 | 1.32:1 |
| type | `#041b24` | 16.38:1 | 1.09:1 | 8.0 | `#245c69` | 7.22:1 | 1.33:1 |
| constant | `#331204` | 15.82:1 | 1.12:1 | 24.9 | `#7c4b20` | 7.04:1 | 1.36:1 |

### warm (`#f0ebdb` displayed background, baseline `#12120e`)

| Token | Displayed | vs bg | vs baseline | dE | Authored | vs bg (intent) | vs baseline (intent) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| keyword | `#211132` | 14.79:1 | 1.06:1 | 27.4 | `#654a7a` | 6.90:1 | 1.16:1 |
| function | `#061630` | 15.11:1 | 1.04:1 | 22.1 | `#2b5278` | 7.52:1 | 1.07:1 |
| string | `#321204` | 14.39:1 | 1.09:1 | 20.1 | `#7a4b1f` | 6.81:1 | 1.18:1 |
| comment | `#1f2218` | 13.54:1 | 1.16:1 | 8.9 | `#626657` | 5.46:1 | 1.47:1 |
| number | `#041b22` | 14.86:1 | 1.06:1 | 11.4 | `#235c66` | 6.95:1 | 1.15:1 |
| type | `#051b14` | 15.01:1 | 1.05:1 | 9.5 | `#285c4f` | 7.10:1 | 1.13:1 |
| constant | `#2d0f01` | 14.92:1 | 1.06:1 | 18.2 | `#754411` | 7.49:1 | 1.07:1 |

### charcoal-ink (`#060607` displayed background, baseline `#ccc2af`)

| Token | Displayed | vs bg | vs baseline | dE | Authored | vs bg (intent) | vs baseline (intent) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| keyword | `#88435f` | **2.91:1** | 3.95:1 | 53.9 | `#c18ca4` | 5.05:1 | 2.15:1 |
| function | `#356382` | 3.14:1 | 3.65:1 | 51.1 | `#7ea7bd` | 5.45:1 | 2.00:1 |
| string | `#657332` | 3.91:1 | 2.94:1 | 43.1 | `#a9b37a` | 6.30:1 | 1.73:1 |
| comment | `#3e4c3d` | **2.22:1** | 5.16:1 | 49.1 | `#879486` | 4.42:1 | 2.46:1 |
| number | `#545090` | **2.82:1** | 4.07:1 | 64.4 | `#9b98c6` | 5.15:1 | 2.11:1 |
| type | `#2e6764` | 3.13:1 | 3.67:1 | 46.0 | `#76aaa8` | 5.41:1 | 2.01:1 |
| constant | `#a6702e` | 4.80:1 | 2.39:1 | 45.2 | `#d3b176` | 6.90:1 | 1.58:1 |

What the numbers say:

- **Readability against the background** is excellent on the light themes
  (13.5:1 to 17.8:1): nothing there is below 3:1, so this is not a
  "can't read the code" problem. It is a "can't see the highlighting" problem:
  every token is within 1.04-1.19:1 luminance of plain text, and only hue
  (dE 8-31) separates them. Warm is the flattest; its comment colour differs
  from plain text by dE 8.9.
- **charcoal-ink fails the 3:1 body-text threshold** for keyword (2.91:1),
  number (2.82:1) and comment (2.22:1) against its own background. The authored
  palette has 4.42-5.15:1; the transfer compresses it below the threshold.
- The **authored palettes themselves are modest**: 1.07-1.66:1 against plain
  text. That is normal for syntax highlighting (VS Code Dark+ is ~1.5:1), so the
  design intent is defensible; the defect is that the intent is not displayed.

Full generated tables: `raw/issue-211-theme-contrast-2026-11-20.md` (JSON:
`raw/issue-211-theme-contrast-2026-11-20.json`). Matrix machine record:
`raw/issue-211-theme-matrix-2026-11-20.json`; the per-scene reports, frames and
registry diffs stay in the git-ignored `out/backend-compare/<scene>-<theme>/`
directories (`report.md`, `report.json`, `diff-*.json`, `sdl-gpu/capture/...`).

## Options for the founder (no theme or renderer change applied)

### A. Make the contract and the authoring agree (systemic, deliberate)

Land true sRGB output on **both** hosts together: present through an sRGB target
so the GPU encodes linear values back to the authored sRGB code. Then the
displayed column equals the authored column for every surface, on both hosts.
This is the contract change `docs/themes.md` already flags: it must land on
SDL_GPU, hosted WebGPU, both image-texture paths, and it changes every chrome and
editor color (backgrounds get lighter, blends and relief materials shift).
Expected result for syntax: cool-light keyword `#604a88` vs baseline `#384452`
= 1.34:1 (dE 33.5), warm keyword 1.16:1 (dE 37.5), charcoal keyword 2.15:1.
Still modest against plain text, but visibly the authored palette. Needs a
visual review of the whole app, not just the editor.

### B. Pre-compensate in the theme generator (same visual result, contained)

Have the compiler store `sRGB-encode(authored)` so the linear channel that reaches
the non-sRGB swapchain *is* the authored sRGB code. No renderer change; applies
to both hosts by construction. Global application also changes every surface;
scoping it to `app.scratchpad.syntax.*` only fixes highlighting and leaves the
chrome as it is today.

For the syntax-only scope, replacing each JSON `$value.components` with these
values displays the current authored colour (right column) in the current
contract:

| Theme | Token | New components (sRGB author) | Displays as |
| --- | --- | --- | --- |
| cool-light | keyword | 0.6472, 0.5750, 0.7569 | `#604a88` |
| cool-light | function | 0.4665, 0.6125, 0.7262 | `#2f557c` |
| cool-light | string | 0.7210, 0.5959, 0.4475 | `#7a502b` |
| cool-light | comment | 0.6059, 0.6622, 0.7210 | `#53657a` |
| cool-light | number | 0.4116, 0.6286, 0.7021 | `#245a73` |
| warm | keyword | 0.6622, 0.5750, 0.7210 | `#654a7a` |
| warm | function | 0.4475, 0.6026, 0.7156 | `#2b5278` |
| warm | string | 0.7210, 0.5786, 0.3835 | `#7a4b1f` |
| warm | comment | 0.6533, 0.6652, 0.6190 | `#626657` |
| warm | number | 0.4062, 0.6349, 0.6652 | `#235c66` |
| charcoal-ink | keyword | 0.8844, 0.7668, 0.8228 | `#c18ca4` |
| charcoal-ink | function | 0.7315, 0.8294, 0.8762 | `#7ea7bd` |
| charcoal-ink | string | 0.8338, 0.8554, 0.7210 | `#a9b37a` |
| charcoal-ink | comment | 0.7544, 0.7860, 0.7519 | `#879486` |
| charcoal-ink | number | 0.8024, 0.7954, 0.8944 | `#9b98c6` |

Measured effect against today's plain-text baseline and background:

| Theme | Token | Now vs baseline | After vs baseline | After vs bg |
| --- | --- | --- | --- | --- |
| cool-light | keyword | 1.10:1 | 2.59:1 | 6.87:1 |
| cool-light | comment | 1.19:1 | 3.21:1 | 5.54:1 |
| warm | keyword | 1.06:1 | 2.52:1 | 6.26:1 |
| warm | comment | 1.16:1 | 3.18:1 | 4.95:1 |
| charcoal-ink | keyword | 3.95:1 (2.91 vs bg) | 1.58:1 (7.29 vs bg) | 7.29:1 |
| charcoal-ink | comment | 5.16:1 (2.22 vs bg) | 1.80:1 (6.38 vs bg) | 6.38:1 |

(The charcoal line reads differently because its baseline is light text on a dark
background: the pre-compensated token is *lighter* than the compressed one, so it
separates from the background and the plain text by luminance rather than only
hue.)

Which file to regenerate: the four `themes/scratchpad-*.json` sources, then
`tools/alicorn.ps1 build` (the driver runs `alicorn theme compile` and writes
`frontends/alicorn/style_*_generated.odin`). No generated file is hand-edited.

### C. Retune the syntax palette itself (largest visible change)

If the founder wants highlighting to read clearly (≥3:1 against plain text), the
palette needs new colours, not just correct ones. Starting from the authored hue
and raising each light-theme token to 3:1 against the displayed baseline gives,
for cool-light: keyword `#6a5392`, function `#3d6189`, string `#805530`,
comment `#53657a`, number `#31657e`, type `#306673` (all 2.98-3.21:1 vs
baseline, 5.9-6.0:1 vs background). Authoring those under the current contract
means writing the sRGB-encoded components (`srgb_encode(hex/255)`), e.g. keyword
`0.6768, 0.6059, 0.7813`. This is a design decision and should follow A or B,
otherwise it doubles the pre-compensation work.

### D. Non-colour alternative

Increase typographic separation instead: bold keywords/types and italic comments
in the editor's style spans. It needs no colour contract change and works on both
hosts today, but it is a different visual language from the current themes.

Recommendation: decide between A (correct the contract globally, best long term)
and B scoped to syntax (fastest visible improvement with no renderer change).
Charcoal-ink's 2.22-2.91:1 readability failures make some change worthwhile even
before a global contract decision.

## Tooling added

- `tools/compare_backends.ps1` — the matched dual-backend harness: launches every
  leg with the same state/env/args, proves the frame settled with two F12
  captures, diffs each candidate against the reference, and writes `report.md` +
  `report.json` plus per-leg capture bundles.
- `tools/ppm_diff.py` — dependency-free P6 differ with full-frame and named-region
  statistics (channels, pixels, max/mean delta, bounding box), JSON/markdown
  output, `--fail-on-diff`.
- `tools/theme_contrast.py` — parses generated style files and reports WCAG
  contrast and dE for displayed and authored colours, plus the pre-compensated
  projection.
- `tools/test_compare_tools.py` — 10 unit tests over the PPM parser, region
  clamping/statistics, markdown/JSON output, and the contrast math.
- `docs/development.md` — usage for the new harness.

The structural bands used above live in
`tools/compare_regions.scratchpad-1216x799.json`; the full-frame diff remains
authoritative and the bands clamp to whatever frame is captured.

## Validation

- `python tools/test_compare_tools.py`: 10/10 pass.
- Matrix: 30 comparisons (5 scenes x 3 themes x 2 hosted backends) against the
  SDL_GPU reference, 27 byte-identical and 3 status-cue-only differences as
  detailed above. Every leg enforced a settled frame.
- Alicorn suites (run individually, because `tools/test.ps1` still stops in the
  AccessKit binding check under Windows PowerShell 5.1, exactly as recorded in
  the earlier slices): runtime 412/412, host/fonts 5/5, host/sdl3 7/7,
  host/sdl3/live_resize 9/9, input 8/8, clipboard 3/3, dialogs 5/5, host/menus
  8/8, host/web 14/14, host/diagnostics 9/9, host/presentation 7/7,
  renderer/webgpu 8/8, renderer/cpu 23/23, ui 50/50, testui 13/13, theme 37/37,
  native/sdl_gpu 166/166, native/scroll_capture 6/6, `odin build tests` and
  `out/alicorn_tests.exe`, the accessibility contract fixture, the restoration
  checks, the SDL_GPU text-input contract, and the theme CLI check/compile/
  explain smoke all pass.
- Scratchpad smokes (unchanged Scratchpad source and lock): `smoke
  --renderer=webgpu --backend=d3d12`, `--backend=vulkan`, and
  `--renderer=sdl-gpu` report `publication_rendered`, `wake_observed`,
  `ordered_shutdown`, and `session_restore` true.
- No runtime changes: the trace instrumentation used for the bisect was removed
  before commit; `git status` shows only tools and docs.
