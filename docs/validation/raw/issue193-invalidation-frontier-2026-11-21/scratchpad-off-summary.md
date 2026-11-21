# Scratchpad-shaped workload summary

Runs per scenario and renderer: 2. Frames: 24. CPU wall time only; no GPU execution or scanout.

`application_build` is description minus reconcile; `measure_text` is text shaping across measure and layout.

## typing

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.410 | 0.389 | 0.399 |
| reconcile | 0.234 | 0.206 | 0.221 |
| reconcile_hash | 0.091 | 0.070 | 0.085 |
| reconcile_copy | 0.010 | 0.009 | 0.009 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.052 | 0.051 | 0.054 |
| measure_text | 0.048 | 0.045 | 0.049 |
| layout | 0.002 | 0.001 | 0.002 |
| semantic_sync | 0.021 | 0.021 | 0.018 |
| paint | 0.011 | 0.011 | 0.008 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.189 | 0.194 | 0.195 |
| reconcile_other | 0.054 | 0.053 | 0.054 |

## idle

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.142 | 0.130 | 0.179 |
| reconcile | 0.055 | 0.049 | 0.079 |
| reconcile_hash | 0.021 | 0.014 | 0.032 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.010 | 0.011 | 0.010 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.087 | 0.081 | 0.100 |
| reconcile_other | 0.024 | 0.024 | 0.036 |

## Description percentiles (median across runs)

| Scenario | Renderer | p50 (ms) | p95 (ms) | p99 (ms) |
|---|---|---:|---:|---:|
| typing | sdl-gpu | 0.332 | 0.410 | 0.428 |
| typing | d3d12 | 0.322 | 0.389 | 0.517 |
| typing | vulkan | 0.317 | 0.399 | 0.466 |
| idle | sdl-gpu | 0.142 | 0.142 | 0.142 |
| idle | d3d12 | 0.130 | 0.130 | 0.130 |
| idle | vulkan | 0.179 | 0.179 | 0.179 |

## Retained-work counters (median across runs)

| Scenario | Renderer | descriptions emitted | reused | exact-match reuses | structure-sequence matches | reconcile | measure | text shapes | layout | paint | compose | full finalize passes | semantic changes | persistent alloc calls | scratch alloc calls |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typing | sdl-gpu | 3,432 | 3,411 | 3,411 | 22 | 3,432 | 21 | 21 | 0 | 21 | 21 | 0 | 43 | 545 | 1,321 |
| typing | d3d12 | 3,519 | 3,497 | 3,497 | 23 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 1,383 |
| typing | vulkan | 3,519 | 3,497 | 3,497 | 23 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 1,383 |
| idle | sdl-gpu | 156 | 156 | 156 | 1 | 156 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 4 | 19 |
| idle | d3d12 | 153 | 153 | 153 | 1 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 19 |
| idle | vulkan | 153 | 153 | 153 | 1 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 19 |

