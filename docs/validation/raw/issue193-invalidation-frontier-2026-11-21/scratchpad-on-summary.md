# Scratchpad-shaped workload summary

Runs per scenario and renderer: 2. Frames: 24. CPU wall time only; no GPU execution or scanout.

`application_build` is description minus reconcile; `measure_text` is text shaping across measure and layout.

## typing

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.390 | 0.387 | 0.369 |
| reconcile | 0.195 | 0.199 | 0.188 |
| reconcile_hash | 0.071 | 0.068 | 0.065 |
| reconcile_copy | 0.008 | 0.008 | 0.008 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.044 | 0.043 | 0.041 |
| measure_text | 0.041 | 0.040 | 0.038 |
| layout | 0.002 | 0.002 | 0.002 |
| semantic_sync | 0.020 | 0.020 | 0.018 |
| paint | 0.016 | 0.009 | 0.008 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.183 | 0.190 | 0.185 |
| reconcile_other | 0.049 | 0.053 | 0.052 |

## idle

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.152 | 0.135 | 0.213 |
| reconcile | 0.054 | 0.049 | 0.103 |
| reconcile_hash | 0.019 | 0.016 | 0.032 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.010 | 0.010 | 0.041 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.098 | 0.086 | 0.109 |
| reconcile_other | 0.025 | 0.023 | 0.031 |

## Description percentiles (median across runs)

| Scenario | Renderer | p50 (ms) | p95 (ms) | p99 (ms) |
|---|---|---:|---:|---:|
| typing | sdl-gpu | 0.284 | 0.390 | 0.394 |
| typing | d3d12 | 0.296 | 0.387 | 0.447 |
| typing | vulkan | 0.275 | 0.369 | 0.390 |
| idle | sdl-gpu | 0.152 | 0.152 | 0.152 |
| idle | d3d12 | 0.135 | 0.135 | 0.135 |
| idle | vulkan | 0.213 | 0.213 | 0.213 |

## Retained-work counters (median across runs)

| Scenario | Renderer | descriptions emitted | reused | exact-match reuses | structure-sequence matches | reconcile | measure | text shapes | layout | paint | compose | full finalize passes | semantic changes | persistent alloc calls | scratch alloc calls |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typing | sdl-gpu | 3,588 | 3,566 | 3,566 | 23 | 3,588 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 564 | 1,383 |
| typing | d3d12 | 3,519 | 3,497 | 3,497 | 23 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 1,383 |
| typing | vulkan | 3,519 | 3,497 | 3,497 | 23 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 1,383 |
| idle | sdl-gpu | 156 | 156 | 156 | 1 | 156 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 4 | 19 |
| idle | d3d12 | 153 | 153 | 153 | 1 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 19 |
| idle | vulkan | 153 | 153 | 153 | 1 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 19 |

