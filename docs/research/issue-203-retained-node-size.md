# Issue #203 — Retained Node size budget

## Disposition

Issue [#203](https://github.com/samanshaiza004/alicorn/issues/203) is resolved on `master` by [PR #202](https://github.com/samanshaiza004/alicorn/pull/202), merged as [`523a927`](https://github.com/samanshaiza004/alicorn/commit/523a92792b7b5fa10f52d22d24b500e9b0bcbcf8). No additional production change or budget increase is needed.

## Cause and fix

The issue recorded `Node=2,088` bytes against the unchanged 2,048-byte tripwire. The PR investigation reproduced that size on both its base and PR before the fix. The follow-up commit [`0a8be32`](https://github.com/samanshaiza004/alicorn/commit/0a8be325da0fde75a17e1f6a69eee1e5ad2993a2) changed the small, closed-set enums stored in retained nodes to `enum u8`, including `Node_Kind`, `Split_Axis`, GPU-surface state, drop state, scroll configuration, `Font_Role`, and `Button_Variant`. It also compacted `Adaptive_Selection_Reason` in [`runtime/adaptive.odin`](https://github.com/samanshaiza004/alicorn/blob/master/runtime/adaptive.odin).

This removes padding and redundant per-node enum storage in place. It does not add a sidecar lookup to layout, input, or paint hot paths, and it leaves `NODE_SIZE_TRIPWIRE_BYTES :: 2048` intact in [`runtime/size_tripwire_test.odin`](https://github.com/samanshaiza004/alicorn/blob/master/runtime/size_tripwire_test.odin).

The later compact surface-marker work stores marker payloads in runtime side storage and did not undo the enum compaction. The current node-size measurement is the relevant check for accumulated changes.

## Current validation

The current `master` head, [`ec109c5`](https://github.com/samanshaiza004/alicorn/commit/ec109c5b5725f6378e75bfcd51ff60251a6a4e24), passed the hosted foundation suite on Windows and macOS. Both logs report:

```text
Node=2008 bytes, Description=704 bytes, Paint_Command=128 bytes
Finished 352 tests. All tests were successful.
```

- [Windows foundation run](https://github.com/samanshaiza004/alicorn/actions/runs/43799791216/job/133076934658)
- [macOS foundation run](https://github.com/samanshaiza004/alicorn/actions/runs/43799791179/job/133076934651)

The existing size tripwire remains the regression guard. Reconsider moving state to a sidecar only if future per-node state growth cannot be compacted at its representation boundary; do not raise the limit without a measured per-node memory rationale.
