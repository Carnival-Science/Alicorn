# Issue #205 multi-surface acknowledgements: Acetate native validation

Date: 2026-11-20. Platform: Windows 10 22H2, NVIDIA RTX 2080 SUPER,
SDL_GPU Direct3D 12. Alicorn: v0.2.2
(`67b31b8a80cb316dd91becbf4d2dde2582759030`). Acetate:
`codex/issue-205-acetate-integration`, branched from `origin/main`
(`58a649f68`).

## Result

Acetate's native two-window fixture passed **37/37 checks**: one retained
`Runtime` presented two disjoint outputs into two real swapchain targets, each
encoded and submitted independently, with exact-revision acknowledgement,
per-target fences, independent dirty routing, shared resize, stale-ack
rejection, hidden/restored targets, removed/recreated outputs, and a settled
one-second idle window with **zero** GPU submissions.

The full Audacity/wx application was not rebuilt. The Acetate wx timeline
adapter was compile-checked against v0.2.2; the native fixture isolates the
Alicorn contract without the wx/Audacity dependency tree. This is recorded as a
remaining later step, not as a failed check.

## Contract summary

One `Runtime` may publish presentation work for several native targets. A host
registers one `Presentation_Output_ID` per target, binds each ID to a disjoint
retained subtree, and acknowledges a target only after that target's submission
succeeds.

Public API (all Runtime-scoped; IDs become invalid on unregister or Runtime
destruction and are never reused):

| API | Semantics |
| --- | --- |
| `presentation_output_register` | Create an initially visible output; returns an identity scoped to one Runtime. |
| `presentation_output_bind_root` | Bind a described retained root. Roots must be disjoint; nested roots return `Root_Overlap`. |
| `presentation_output_set_visible` | Suspend scheduling/acknowledgement while hidden; restoring marks the current retained contents for a fresh published revision. Hidden outputs never keep `frame_needs_submission` true. |
| `presentation_output_snapshot` | Report `root`, published `revision`, `acknowledged_revision`, `visible`, and whether a visible published revision is pending. |
| `paint_display_list_for_output` | Borrow the published commands for one output root plus Runtime-wide owner-zero overlays, tagged with that output's revision. |
| `presentation_output_frame_submission_succeeded` | Acknowledge exactly the published revision submitted for that output. A stale revision returns `Stale_Revision`; a hidden or clean output returns `No_Pending_Frame`. |
| `presentation_output_unregister` | Permanently remove a target and discard its obsolete pending work. |

Documented behavior (see [`../hosted-runtime.md`](../hosted-runtime.md#multiple-outputs-from-one-runtime)):

- Changes inside one output root publish only that output. Changes outside every
  registered root are shared chrome and publish all outputs.
- A successful submission means the target's command buffer was submitted
  (GPU) or its synchronous paint callback completed (wx). Submission is not
  fence retirement or physical scanout; the presenter still owns GPU resource
  retirement.
- A failed target submission leaves its exact revision pending.
- Retired roots detach after the next description; a recreated native target
  must unregister the old ID and register a new one.
- With no registered outputs, whole-display `frame_needs_submission` and
  `frame_submission_succeeded` are unchanged. A host that submits only one of
  several targets must not call the whole-display acknowledgement.

## Acetate integration

Acetate's wx timeline already consumes the contract: one `Runtime` owns ruler,
waveform-geometry, and waveform-label roots; the C++ paint callbacks read each
output revision and acknowledge it after the synchronous wx paint succeeds
(`src/alicorn/AudacityTimelineView.odin`, `AlicornTimelineView.cpp`). That
adapter passed `odin check src/alicorn -no-entry-point` against the v0.2.2 pin
with no API drift.

For native pixels and fences, `host-spike/multisurface_validation/main.odin`
is a standalone Acetate fixture that mirrors the same consumption without wx:

- one `alicorn.new_runtime` with two `Presentation_Output_ID`s;
- two SDL windows claimed by the same SDL_GPU device (Direct3D 12);
- the ruler and waveform described as disjoint sibling roots bound to their IDs;
- each frame, `paint_display_list_for_output` for one target, encoded into that
  window's swapchain with that window's own pixel scale;
- one command buffer and one fence per target; acknowledgement of the exact
  revision only after `SubmitGPUCommandBufferAndAcquireFence` succeeds;
- no target is repainted or acknowledged when only its sibling is dirty.

The fixture also writes PPM captures and a JSON/LOG bundle with revisions,
acknowledgements, window metrics, and encode/submit/fence timings. It mirrors
the v0.2.2 `F12` capture intent rather than requiring the full host loop.

## Build toolchain

- Installed through winget on this machine: CMake 4.4.4 and Ninja 1.13.2.
- Odin: `dev-2026-11-nightly:08539cd` at `C:\odin\odin.exe`.
- SDL3: Odin vendor `SDL3.dll`/`SDL3.lib`.
- AccessKit: the pinned standalone binding and static library initialized by
  Alicorn `tools/common.ps1` (`Get-AlicornAccessKit`), required because
  `alicorn:native/sdl_gpu` links the Windows accessibility adapter.
- Compile checks against v0.2.2: `host-spike/app`, `host-spike/ruler_validation`,
  `host-spike/multisurface_validation`, and `src/alicorn` (no entry point) all
  exited 0.
- The Audacity backend/wx library was not configured: this checkout has no
  configured Audacity build/dependency tree, and the task scope allowed the
  isolated native harness. CMake/Ninja are now present for that later build.

## Validation matrix

| Acceptance criterion | Native evidence | Result |
| --- | --- | --- |
| One Runtime for two native targets | Two output IDs from one Runtime; two SDL windows; distinct swapchains; distinct captured pixels | PASS |
| Ruler-only update repaints the ruler and does not falsely acknowledge the waveform | Ruler published revision 5 while the waveform stayed clean; waveform submission count unchanged | PASS |
| Waveform-only update behaves symmetrically | Waveform published revision 7 while ruler stayed clean; ruler submission count unchanged | PASS |
| Shared update reports every affected output | `request_presentation` marked both pending at revision 9 | PASS |
| Shared resize reports every affected output | Runtime 640x220 to 736x268; both outputs republished at revision 10 | PASS |
| Hidden target cannot spin idle or falsely acknowledge | Hidden waveform stayed non-pending; visible ruler settled; acknowledging the hidden output returned `No_Pending_Frame`; `frame_needs_submission` false | PASS |
| Restored target republishes current content; old revision cannot acknowledge it | Restore published revision 15 (> old 12); old revision returned `Stale_Revision` | PASS |
| Removed target detaches and cannot spin idle | Waveform root became 0, pending dropped; host returned idle | PASS |
| Recreated target gets a fresh identity | New output ID accepted; old ID returned `Invalid_Output`; new target settled | PASS |
| Stale acknowledgement cannot clear newer work | Old revision returned `Stale_Revision`; newer work remained pending until the current revision was acknowledged | PASS |
| Documentation defines lifetime, visibility, and successful submission | `hosted-runtime.md` multi-output section; clarified per-target scale behavior in this pass | PASS |
| Real GPU, per-target fences, idle | Direct3D 12; one fence wait per target; 1 s settled interval with zero submissions and zero descriptions | PASS |

Per-target scale was exercised by resizing only the waveform window: the ruler
target was then 640x220 against the shared 736x268 layout (encode scale
0.87x0.82), while the waveform target stayed 1.0x1.0. Both attached displays
report 96 DPI, so a physical mixed-DPI monitor transition was **not** exercised.
The contract test is that each target applies its own drawable scale to the
shared logical composition.

## Captures and counters

- [Ruler target, Direct3D 12](assets/issue-205-acetate-ruler-d3d12-2026-11-20.png)
- [Waveform target, Direct3D 12](assets/issue-205-acetate-waveform-d3d12-2026-11-20.png)
- [Both targets side by side](assets/issue-205-acetate-both-d3d12-2026-11-20.png)
- [Raw JSON summary](assets/issue-205-acetate-multisurface-d3d12-2026-11-20.json)
- [Full validation log](assets/issue-205-acetate-validation-2026-11-20.txt)

Final settled counters:

| Target | Submissions | Acks | Last revision | Acknowledged | Window | Encode total | Submit total | Fence-wait total |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ruler | 7 | 7 | 16 | 16 | 640x220 | 3.82 ms | 3.53 ms | 81.43 ms |
| waveform | 6 | 6 | 18 | 18 | 736x268 | 3.17 ms | 1.66 ms | 1.01 ms |

The ruler's larger fence-wait total includes the first-frame pipeline/upload
cost; the post-warmup submits are tens of microseconds. Fence waiting is per
target and immediate in this fixture, so submissions do not overlap; the
contract does not require overlap.

## Gaps found

- No Runtime contract gap. Independent dirty routing, exact-revision
  acknowledgement, hidden/restored behavior, and removal all matched the
  documented behavior.
- Documentation gap fixed: `hosted-runtime.md` now states that output IDs do not
  create per-target layout or device-scale state, and that hosts should keep
  one shared layout scale and apply each target's drawable scale at encode time
  instead of varying `set_presentation_scale` per output.
- The Acetate fixture initially counted a queued native resize event as idle
  work. That was a fixture event-handling issue (duplicate resize events
  repainted after the resize step), fixed by making the fixture wait for native
  metrics and ignore duplicate sizes. It was not an Alicorn idle defect.

## Reproduction

```powershell
# Acetate checkout, Alicorn v0.2.2 checkout at C:\Users\saman\dev\alicorn-accept-205-acetate
$Alicorn = 'C:\Users\saman\dev\alicorn-accept-205-acetate'
$Odin = 'C:\odin\odin.exe'
$AccessKit = "$Alicorn\.deps\odin-accesskit"
$AccessKitLib = "$Alicorn\.deps\accesskit\accesskit-c-0.23.1\lib\windows\x86_64\msvc\static"
& $Odin build host-spike/multisurface_validation -o:speed `
  -collection:alicorn=$Alicorn `
  -collection:accesskit=$AccessKit `
  -collection:accesskit_c=$AccessKitLib `
  "-extra-linker-flags:bcrypt.lib ntdll.lib propsys.lib runtimeobject.lib uiautomationcore.lib userenv.lib ws2_32.lib" `
  -out:out/multisurface-acetate.exe
Copy-Item C:\odin\vendor\sdl3\SDL3.dll out/SDL3.dll -Force
out/multisurface-acetate.exe --auto --capture-dir=out/multisurface-acetate
```

## Remaining limits

- The full wx/Audacity `Audacity` target was not rebuilt in this session; the
  wx three-output adapter was compile-checked only. An interactive wx session
  should still confirm painted pixels and callback ordering on a configured
  build.
- Mixed-DPI movement between monitors was not exercised (both displays 96 DPI).
  Per-target drawable scaling was exercised by asymmetric window sizes.
- This fixture uses two immediate per-target fence waits. Asynchronous
  per-target submission queues and GPU-resource retirement across targets
  remain host responsibilities and were not stress-tested here.
