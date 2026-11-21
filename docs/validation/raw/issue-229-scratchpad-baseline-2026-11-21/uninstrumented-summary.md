# Scratchpad-shaped workload summary

Runs per scenario and renderer: 5. Frames: 24. CPU wall time only; no GPU execution or scanout.

`application_build` is description minus reconcile; `measure_text` is text shaping across measure and layout.

## typing

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.464 | 0.473 | 0.447 |
| reconcile | 0.000 | 0.000 | 0.000 |
| reconcile_hash | 0.000 | 0.000 | 0.000 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.000 | 0.000 | 0.000 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.464 | 0.473 | 0.447 |
| reconcile_other | 0.000 | 0.000 | 0.000 |

## scroll

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.403 | 0.419 | 0.395 |
| reconcile | 0.000 | 0.000 | 0.000 |
| reconcile_hash | 0.000 | 0.000 | 0.000 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.000 | 0.000 | 0.000 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.403 | 0.419 | 0.395 |
| reconcile_other | 0.000 | 0.000 | 0.000 |

## selection

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.404 | 0.414 | 0.400 |
| reconcile | 0.000 | 0.000 | 0.000 |
| reconcile_hash | 0.000 | 0.000 | 0.000 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.000 | 0.000 | 0.000 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.404 | 0.414 | 0.400 |
| reconcile_other | 0.000 | 0.000 | 0.000 |

## resize

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.500 | 0.493 | 0.594 |
| reconcile | 0.000 | 0.000 | 0.000 |
| reconcile_hash | 0.000 | 0.000 | 0.000 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.000 | 0.000 | 0.000 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.500 | 0.493 | 0.594 |
| reconcile_other | 0.000 | 0.000 | 0.000 |

## tabs

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.407 | 0.400 | 0.354 |
| reconcile | 0.000 | 0.000 | 0.000 |
| reconcile_hash | 0.000 | 0.000 | 0.000 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.000 | 0.000 | 0.000 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.407 | 0.400 | 0.354 |
| reconcile_other | 0.000 | 0.000 | 0.000 |

## idle

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.182 | 0.171 | 0.181 |
| reconcile | 0.000 | 0.000 | 0.000 |
| reconcile_hash | 0.000 | 0.000 | 0.000 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.000 | 0.000 | 0.000 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.182 | 0.171 | 0.181 |
| reconcile_other | 0.000 | 0.000 | 0.000 |

## Retained-work counters (median across runs)

| Scenario | Renderer | descriptions emitted | reused | reconcile | measure | text shapes | layout | paint | compose | semantic changes | persistent alloc calls |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typing | sdl-gpu | 3,588 | 3,566 | 3,588 | 22 | 22 | 0 | 22 | 22 | 45 | 564 |
| typing | d3d12 | 3,519 | 3,497 | 3,519 | 22 | 22 | 0 | 22 | 22 | 45 | 655 |
| typing | vulkan | 3,519 | 3,497 | 3,519 | 22 | 22 | 0 | 22 | 22 | 45 | 655 |
| scroll | sdl-gpu | 3,588 | 3,588 | 3,588 | 0 | 0 | 0 | 0 | 0 | 23 | 189 |
| scroll | d3d12 | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 23 | 280 |
| scroll | vulkan | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 23 | 280 |
| selection | sdl-gpu | 3,588 | 3,588 | 3,588 | 0 | 0 | 0 | 1 | 115 | 23 | 195 |
| selection | d3d12 | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 1 | 112 | 23 | 286 |
| selection | vulkan | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 1 | 112 | 23 | 286 |
| resize | sdl-gpu | 3,672 | 3,657 | 3,672 | 482 | 54 | 420 | 180 | 232 | 51 | 875 |
| resize | d3d12 | 3,603 | 3,588 | 3,603 | 467 | 54 | 412 | 177 | 226 | 50 | 950 |
| resize | vulkan | 3,603 | 3,588 | 3,603 | 467 | 54 | 412 | 177 | 226 | 50 | 950 |
| tabs | sdl-gpu | 3,588 | 3,588 | 3,588 | 0 | 0 | 0 | 0 | 0 | 23 | 189 |
| tabs | d3d12 | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 23 | 280 |
| tabs | vulkan | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 23 | 280 |
| idle | sdl-gpu | 156 | 156 | 156 | 0 | 0 | 0 | 0 | 0 | 1 | 4 |
| idle | d3d12 | 153 | 153 | 153 | 0 | 0 | 0 | 0 | 0 | 1 | 8 |
| idle | vulkan | 153 | 153 | 153 | 0 | 0 | 0 | 0 | 0 | 1 | 8 |