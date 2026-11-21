# Scratchpad-shaped workload summary

Runs per scenario and renderer: 5. Frames: 24. CPU wall time only; no GPU execution or scanout.

`application_build` is description minus reconcile; `measure_text` is text shaping across measure and layout.

## typing

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.477 | 0.482 | 0.470 |
| reconcile | 0.308 | 0.286 | 0.292 |
| reconcile_hash | 0.037 | 0.032 | 0.033 |
| reconcile_copy | 0.115 | 0.112 | 0.109 |
| structure_diff | 0.017 | 0.018 | 0.016 |
| measure | 0.048 | 0.048 | 0.041 |
| measure_text | 0.044 | 0.045 | 0.039 |
| layout | 0.001 | 0.001 | 0.001 |
| semantic_sync | 0.020 | 0.021 | 0.018 |
| paint | 0.007 | 0.007 | 0.007 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.185 | 0.197 | 0.188 |
| reconcile_other | 0.063 | 0.060 | 0.060 |

## scroll

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.469 | 0.438 | 0.441 |
| reconcile | 0.282 | 0.249 | 0.249 |
| reconcile_hash | 0.041 | 0.036 | 0.036 |
| reconcile_copy | 0.124 | 0.112 | 0.112 |
| structure_diff | 0.017 | 0.018 | 0.018 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.002 | 0.001 | 0.001 |
| semantic_sync | 0.020 | 0.020 | 0.021 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.204 | 0.192 | 0.194 |
| reconcile_other | 0.082 | 0.063 | 0.065 |

## selection

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.434 | 0.448 | 0.454 |
| reconcile | 0.253 | 0.255 | 0.277 |
| reconcile_hash | 0.036 | 0.035 | 0.036 |
| reconcile_copy | 0.113 | 0.110 | 0.112 |
| structure_diff | 0.017 | 0.018 | 0.019 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.001 | 0.001 | 0.001 |
| semantic_sync | 0.020 | 0.020 | 0.020 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.001 | 0.000 |
| application_build | 0.187 | 0.195 | 0.193 |
| reconcile_other | 0.064 | 0.061 | 0.064 |

## resize

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.588 | 0.550 | 0.584 |
| reconcile | 0.438 | 0.406 | 0.382 |
| reconcile_hash | 0.038 | 0.033 | 0.038 |
| reconcile_copy | 0.128 | 0.119 | 0.120 |
| structure_diff | 0.019 | 0.019 | 0.021 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.014 | 0.014 | 0.011 |
| layout | 0.165 | 0.144 | 0.137 |
| semantic_sync | 0.020 | 0.019 | 0.021 |
| paint | 0.022 | 0.021 | 0.020 |
| composition | 0.019 | 0.017 | 0.016 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.198 | 0.185 | 0.201 |
| reconcile_other | 0.069 | 0.063 | 0.064 |

## tabs

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.423 | 0.428 | 0.443 |
| reconcile | 0.256 | 0.248 | 0.249 |
| reconcile_hash | 0.036 | 0.036 | 0.037 |
| reconcile_copy | 0.118 | 0.114 | 0.112 |
| structure_diff | 0.017 | 0.018 | 0.018 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.001 | 0.002 | 0.001 |
| semantic_sync | 0.018 | 0.019 | 0.020 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.187 | 0.183 | 0.191 |
| reconcile_other | 0.064 | 0.063 | 0.063 |

## idle

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.175 | 0.194 | 0.190 |
| reconcile | 0.098 | 0.104 | 0.102 |
| reconcile_hash | 0.016 | 0.017 | 0.017 |
| reconcile_copy | 0.034 | 0.036 | 0.036 |
| structure_diff | 0.009 | 0.010 | 0.009 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.010 | 0.010 | 0.010 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.077 | 0.082 | 0.088 |
| reconcile_other | 0.029 | 0.030 | 0.029 |

## Description percentiles (median across runs)

| Scenario | Renderer | p50 (ms) | p95 (ms) | p99 (ms) |
|---|---|---:|---:|---:|
| typing | sdl-gpu | 0.374 | 0.477 | 0.509 |
| typing | d3d12 | 0.388 | 0.482 | 0.529 |
| typing | vulkan | 0.338 | 0.470 | 0.513 |
| scroll | sdl-gpu | 0.336 | 0.469 | 0.545 |
| scroll | d3d12 | 0.344 | 0.438 | 0.442 |
| scroll | vulkan | 0.346 | 0.441 | 0.465 |
| selection | sdl-gpu | 0.337 | 0.434 | 0.456 |
| selection | d3d12 | 0.346 | 0.448 | 0.506 |
| selection | vulkan | 0.345 | 0.454 | 0.497 |
| resize | sdl-gpu | 0.356 | 0.588 | 0.707 |
| resize | d3d12 | 0.364 | 0.550 | 0.602 |
| resize | vulkan | 0.362 | 0.584 | 0.651 |
| tabs | sdl-gpu | 0.346 | 0.423 | 0.462 |
| tabs | d3d12 | 0.356 | 0.428 | 0.450 |
| tabs | vulkan | 0.339 | 0.443 | 0.463 |
| idle | sdl-gpu | 0.175 | 0.175 | 0.175 |
| idle | d3d12 | 0.194 | 0.194 | 0.194 |
| idle | vulkan | 0.190 | 0.190 | 0.190 |

## Retained-work counters (median across runs)

| Scenario | Renderer | descriptions emitted | reused | reconcile | measure | text shapes | layout | paint | compose | full finalize passes | semantic changes | persistent alloc calls | scratch alloc calls |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typing | sdl-gpu | 3,588 | 3,566 | 3,588 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 564 | 2,809 |
| typing | d3d12 | 3,519 | 3,497 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 2,763 |
| typing | vulkan | 3,519 | 3,497 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 2,763 |
| scroll | sdl-gpu | 3,588 | 3,588 | 3,588 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 189 | 1,863 |
| scroll | d3d12 | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| scroll | vulkan | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| selection | sdl-gpu | 3,588 | 3,588 | 3,588 | 0 | 0 | 0 | 1 | 115 | 1 | 23 | 195 | 1,865 |
| selection | d3d12 | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 1 | 112 | 1 | 23 | 286 | 1,819 |
| selection | vulkan | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 1 | 112 | 1 | 23 | 286 | 1,819 |
| resize | sdl-gpu | 3,672 | 3,657 | 3,672 | 482 | 54 | 420 | 180 | 232 | 2 | 51 | 875 | 2,697 |
| resize | d3d12 | 3,603 | 3,588 | 3,603 | 467 | 54 | 412 | 177 | 226 | 2 | 50 | 950 | 2,642 |
| resize | vulkan | 3,603 | 3,588 | 3,603 | 467 | 54 | 412 | 177 | 226 | 2 | 50 | 950 | 2,642 |
| tabs | sdl-gpu | 3,588 | 3,588 | 3,588 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 189 | 1,863 |
| tabs | d3d12 | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| tabs | vulkan | 3,519 | 3,519 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| idle | sdl-gpu | 156 | 156 | 156 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 4 | 81 |
| idle | d3d12 | 153 | 153 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 79 |
| idle | vulkan | 153 | 153 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 79 |