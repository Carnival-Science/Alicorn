# Issue #203 — Retained Node size budget

## Disposition

Issue [#203](https://github.com/Carnival-Science/Alicorn/issues/203) was
resolved on `master` by [PR #202](https://github.com/Carnival-Science/Alicorn/pull/202),
merged as [`523a927`](https://github.com/samanshaiza004/alicorn/commit/523a92792b7b5fa10f52d22d24b500e9b0bcbcf8). A later retained stroke-path
feature caused a new size regression. This follow-up keeps the 2,048-byte
budget and moves that optional payload into sparse runtime storage.

## Original cause and fix

The issue recorded `Node=2,088` bytes against the unchanged 2,048-byte
tripwire. The PR investigation reproduced that size on both its base and PR
before the fix. The follow-up commit [`0a8be32`](https://github.com/samanshaiza004/alicorn/commit/0a8be325da0fde75a17e1f6a69eee1e5ad2993a2)
changed the small, closed-set enums stored in retained nodes to `enum u8`,
including `Node_Kind`, `Split_Axis`, GPU-surface state, drop state, scroll
configuration, `Font_Role`, and `Button_Variant`. It also compacted
`Adaptive_Selection_Reason` in [`runtime/adaptive.odin`](https://github.com/Carnival-Science/Alicorn/blob/master/runtime/adaptive.odin).

That removed padding and redundant per-node enum storage without increasing
the fixed budget.

## Later regression and follow-up

Commit [`113cccc`](https://github.com/Carnival-Science/Alicorn/commit/113cccc42c979fb47f00f86fd33c3055d2311951)
added a dynamic stroke-point array, thickness, and color directly to every
`Node`, including nodes that are not custom surfaces. The current size test
reproduced `Node=2,096` bytes.

Stroke paths are now copied into the sparse
`Runtime.gpu_surface_stroke_paths` map, keyed by live surface ID. The existing
surface-payload resolver returns a borrowed view of that storage. Payloads are
released on replacement, clear, retype, retirement, and runtime destruction;
invalid replacements preserve the previous payload and revision. The
ordinary `Node` no longer carries unused stroke-path storage.

## Validation

The focused size test now reports:

```text
Node=2032 bytes, Description=720 bytes, Paint_Command=128 bytes
```

`NODE_SIZE_TRIPWIRE_BYTES :: 2048` remains unchanged, with 16 bytes of margin.
The new surface regression test checks that path points are copied, invalid
replacements are atomic, clear releases the path, and retyping away from a
custom surface discards the sidecar.

The earlier hosted results for [`ec109c5`](https://github.com/samanshaiza004/alicorn/commit/ec109c5b5725f6378e75bfcd51ff60251a6a4e24)
remain historical evidence that the original enum compaction passed on
Windows and macOS. They do not validate this later regression or its follow-up.
