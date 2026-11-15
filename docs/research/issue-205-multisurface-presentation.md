# Issue #205: shared Runtime presentation outputs

## Question

Can one retained `Runtime` coordinate presentation for multiple native targets
without making a clean submission to one target acknowledge work still pending
on another?

The motivating consumer is an embedded audio timeline. Its ruler and waveform
share retained application state, but their host targets can repaint and
submit independently.

## Runtime contract implemented

- A host registers a `Presentation_Output_ID` for each target, then binds it
  to a retained subtree after the root is described.
- Output roots must be disjoint. Alicorn routes retained paint and
  custom-surface payload invalidations through the existing node ancestry;
  changes outside every output are conservatively treated as shared.
- Each output snapshot carries an exact published presentation revision.
  `presentation_output_frame_submission_succeeded` acknowledges only that
  revision, so an older target submission cannot clear newer output work.
- Visibility suspends scheduling and acknowledgement for hidden targets.
  Restoring visibility requests the target's current retained contents.
- Retired roots are detached after the next description. Permanently removed
  native targets should also unregister their IDs.
- With no registered output IDs, whole-display scheduling and
  `frame_submission_succeeded` retain the existing behavior.
- Output IDs divide scheduling and acknowledgement. The display-command
  accessor remains a combined borrowed stream; the embedding host still routes
  or clips commands into native targets.

The implementation uses a Runtime-owned sparse sidecar, leaving `Node` size
unchanged. No polling loop, timer, GPU target, or native resource is introduced
by the Runtime API.

## Verification

`odin test runtime` passes all 352 tests on Odin dev-2026-11-nightly. The new
tests cover independent output updates, shared invalidation, exact and stale
acknowledgements, visibility, subtree retirement, disjoint-root validation,
custom geometry payload updates, and the unchanged single-output path.

Acetate is now wired as the first consumer: its ruler and waveform bind to
disjoint outputs on one Runtime, and the wx paint adapters capture and
acknowledge the exact revision after their synchronous paint callback succeeds.
The C++ adapter passes syntax compilation and the Odin binding builds against
this implementation. The application-level acceptance still needs a native
session that records ruler-only and waveform-only updates, confirms only the
matching output is acknowledged, and checks visible idle behavior. Pixel parity,
input, and resource-lifetime comparisons remain separate evidence.

## Next consumer validation

Use Acetate's existing shared timeline Runtime as the native consumer fixture.
Record which wx callback runs for isolated ruler and waveform updates, then
confirm output revisions settle independently on supported native platforms.
Keep the existing wx rendering path while doing that validation.
