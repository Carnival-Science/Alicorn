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

`odin test runtime` passes all 353 tests on Odin dev-2026-11-nightly. The
issue-specific host fixture is
[`hosted_multisurface_test.odin`](../../runtime/hosted_multisurface_test.odin):
one `Hosted_Runtime` describes ruler and waveform roots, while two independent
target records submit snapshots and acknowledge them separately. It verifies
that failed submissions remain pending; ruler-only and waveform-only
description changes dirty only their matching target; resize dirties both;
hidden output work does not keep the host awake; stale acknowledgements are
rejected after restore; and removed/recreated targets cannot revive old work.
The runtime tests also cover shared presentation invalidation, retained paint
and custom-geometry updates, disjoint-root validation, and the unchanged
single-display acknowledgement path.

The host fixture models two separate targets without opening native windows;
it validates revision routing and acknowledgement, not pixels or window-system
behavior. Acetate's
[`AudacityTimelineView.odin`](https://github.com/samanshaiza004/acetate/blob/main/src/alicorn/AudacityTimelineView.odin)
binds ruler, waveform, and waveform-label roots to one Runtime. Its wx paint
adapters read the per-output revision and acknowledge it after the synchronous
paint callback succeeds. Native interactive/pixel parity and GPU-resource
retirement remain platform integration evidence, separate from this Runtime
contract.

No new Runtime API was needed for this follow-up: the optional output IDs,
per-output dirty revisions, visibility, and exact-revision acknowledgement
were already present on `master`. This pass closes the automated host-contract
coverage and clarifies output lifecycle and successful-submission semantics in
[`hosted-runtime.md`](../hosted-runtime.md).

## Remaining integration validation

Use Acetate's shared timeline Runtime for a native session that records which
wx callback runs for isolated ruler and waveform updates, and confirms output
revisions settle independently on supported native platforms. Keep the
existing wx rendering path while doing that validation.
