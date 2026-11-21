# Scratchpad-shaped workload summary

Runs per scenario and renderer: 5. Frames: 24. CPU wall time only; no GPU execution or scanout.

`application_build` is description minus reconcile; `measure_text` is text shaping across measure and layout.

## typing

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.504 | 0.519 | 0.500 |
| reconcile | 0.313 | 0.327 | 0.311 |
| reconcile_hash | 0.036 | 0.039 | 0.037 |
| reconcile_copy | 0.122 | 0.127 | 0.113 |
| structure_diff | 0.018 | 0.018 | 0.018 |
| measure | 0.047 | 0.051 | 0.051 |
| measure_text | 0.043 | 0.046 | 0.046 |
| layout | 0.001 | 0.002 | 0.001 |
| semantic_sync | 0.020 | 0.020 | 0.021 |
| paint | 0.009 | 0.009 | 0.008 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.192 | 0.200 | 0.189 |
| reconcile_other | 0.061 | 0.067 | 0.064 |

## scroll

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.414 | 0.435 | 0.417 |
| reconcile | 0.239 | 0.246 | 0.236 |
| reconcile_hash | 0.036 | 0.034 | 0.036 |
| reconcile_copy | 0.112 | 0.108 | 0.106 |
| structure_diff | 0.017 | 0.017 | 0.018 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.002 | 0.001 | 0.002 |
| semantic_sync | 0.018 | 0.018 | 0.019 |
| paint | 0.001 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.178 | 0.180 | 0.183 |
| reconcile_other | 0.056 | 0.063 | 0.060 |

## selection

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.386 | 0.431 | 0.429 |
| reconcile | 0.231 | 0.252 | 0.239 |
| reconcile_hash | 0.033 | 0.036 | 0.035 |
| reconcile_copy | 0.101 | 0.111 | 0.103 |
| structure_diff | 0.017 | 0.017 | 0.018 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.001 | 0.001 | 0.001 |
| semantic_sync | 0.018 | 0.017 | 0.018 |
| paint | 0.000 | 0.001 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.169 | 0.181 | 0.179 |
| reconcile_other | 0.054 | 0.068 | 0.062 |

## resize

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.549 | 0.573 | 0.542 |
| reconcile | 0.394 | 0.408 | 0.370 |
| reconcile_hash | 0.033 | 0.033 | 0.038 |
| reconcile_copy | 0.102 | 0.108 | 0.121 |
| structure_diff | 0.018 | 0.019 | 0.020 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.012 | 0.015 | 0.011 |
| layout | 0.145 | 0.164 | 0.140 |
| semantic_sync | 0.018 | 0.017 | 0.020 |
| paint | 0.019 | 0.020 | 0.021 |
| composition | 0.016 | 0.016 | 0.016 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.174 | 0.175 | 0.195 |
| reconcile_other | 0.061 | 0.054 | 0.072 |

## tabs

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.414 | 0.403 | 0.432 |
| reconcile | 0.231 | 0.243 | 0.250 |
| reconcile_hash | 0.036 | 0.035 | 0.035 |
| reconcile_copy | 0.103 | 0.111 | 0.109 |
| structure_diff | 0.016 | 0.019 | 0.018 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.001 | 0.002 | 0.002 |
| semantic_sync | 0.019 | 0.018 | 0.021 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.169 | 0.182 | 0.183 |
| reconcile_other | 0.057 | 0.058 | 0.062 |

## churn

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.919 | 1.010 | 0.976 |
| reconcile | 0.721 | 0.776 | 0.730 |
| reconcile_hash | 0.035 | 0.036 | 0.037 |
| reconcile_copy | 0.145 | 0.137 | 0.127 |
| structure_diff | 0.016 | 0.017 | 0.018 |
| measure | 0.192 | 0.223 | 0.200 |
| measure_text | 0.180 | 0.210 | 0.187 |
| layout | 0.174 | 0.187 | 0.191 |
| semantic_sync | 0.019 | 0.019 | 0.020 |
| paint | 0.045 | 0.045 | 0.052 |
| composition | 0.025 | 0.023 | 0.027 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.215 | 0.233 | 0.244 |
| reconcile_other | 0.079 | 0.080 | 0.080 |

## idle

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.201 | 0.196 | 0.205 |
| reconcile | 0.109 | 0.112 | 0.111 |
| reconcile_hash | 0.018 | 0.019 | 0.019 |
| reconcile_copy | 0.036 | 0.038 | 0.040 |
| structure_diff | 0.009 | 0.010 | 0.009 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.011 | 0.010 | 0.011 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.090 | 0.085 | 0.098 |
| reconcile_other | 0.029 | 0.033 | 0.031 |

## Description percentiles (median across runs)

| Scenario | Renderer | p50 (ms) | p95 (ms) | p99 (ms) |
|---|---|---:|---:|---:|
| typing | sdl-gpu | 0.398 | 0.504 | 0.576 |
| typing | d3d12 | 0.402 | 0.519 | 0.576 |
| typing | vulkan | 0.398 | 0.500 | 0.515 |
| scroll | sdl-gpu | 0.342 | 0.414 | 0.426 |
| scroll | d3d12 | 0.344 | 0.435 | 0.477 |
| scroll | vulkan | 0.343 | 0.417 | 0.446 |
| selection | sdl-gpu | 0.334 | 0.386 | 0.407 |
| selection | d3d12 | 0.348 | 0.431 | 0.444 |
| selection | vulkan | 0.284 | 0.429 | 0.443 |
| resize | sdl-gpu | 0.321 | 0.549 | 0.638 |
| resize | d3d12 | 0.351 | 0.573 | 0.603 |
| resize | vulkan | 0.351 | 0.542 | 0.641 |
| tabs | sdl-gpu | 0.274 | 0.414 | 0.439 |
| tabs | d3d12 | 0.338 | 0.403 | 0.451 |
| tabs | vulkan | 0.323 | 0.432 | 0.486 |
| churn | sdl-gpu | 0.699 | 0.919 | 0.968 |
| churn | d3d12 | 0.762 | 1.010 | 1.030 |
| churn | vulkan | 0.714 | 0.976 | 1.050 |
| idle | sdl-gpu | 0.201 | 0.201 | 0.201 |
| idle | d3d12 | 0.196 | 0.196 | 0.196 |
| idle | vulkan | 0.205 | 0.205 | 0.205 |

## Retained-work counters (median across runs)

| Scenario | Renderer | descriptions emitted | reused | exact-match reuses | structure-sequence matches | reconcile | measure | text shapes | layout | paint | compose | full finalize passes | semantic changes | persistent alloc calls | scratch alloc calls |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typing | sdl-gpu | 3,588 | 3,566 | 0 | 0 | 3,588 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 564 | 2,809 |
| typing | d3d12 | 3,519 | 3,497 | 0 | 0 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 2,763 |
| typing | vulkan | 3,519 | 3,497 | 0 | 0 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 2,763 |
| scroll | sdl-gpu | 3,588 | 3,588 | 0 | 0 | 3,588 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 189 | 1,863 |
| scroll | d3d12 | 3,519 | 3,519 | 0 | 0 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| scroll | vulkan | 3,519 | 3,519 | 0 | 0 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| selection | sdl-gpu | 3,588 | 3,588 | 0 | 0 | 3,588 | 0 | 0 | 0 | 1 | 115 | 1 | 23 | 195 | 1,865 |
| selection | d3d12 | 3,519 | 3,519 | 0 | 0 | 3,519 | 0 | 0 | 0 | 1 | 112 | 1 | 23 | 286 | 1,819 |
| selection | vulkan | 3,519 | 3,519 | 0 | 0 | 3,519 | 0 | 0 | 0 | 1 | 112 | 1 | 23 | 286 | 1,819 |
| resize | sdl-gpu | 3,672 | 3,657 | 0 | 0 | 3,672 | 482 | 54 | 420 | 180 | 232 | 2 | 51 | 875 | 2,697 |
| resize | d3d12 | 3,603 | 3,588 | 0 | 0 | 3,603 | 467 | 54 | 412 | 177 | 226 | 2 | 50 | 950 | 2,642 |
| resize | vulkan | 3,603 | 3,588 | 0 | 0 | 3,603 | 467 | 54 | 412 | 177 | 226 | 2 | 50 | 950 | 2,642 |
| tabs | sdl-gpu | 3,588 | 3,588 | 0 | 0 | 3,588 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 189 | 1,863 |
| tabs | d3d12 | 3,519 | 3,519 | 0 | 0 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| tabs | vulkan | 3,519 | 3,519 | 0 | 0 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 1,817 |
| churn | sdl-gpu | 3,588 | 2,048 | 0 | 0 | 3,588 | 5,016 | 154 | 3,982 | 1,738 | 2,508 | 22 | 155 | 9,719 | 8,672 |
| churn | d3d12 | 3,519 | 1,979 | 0 | 0 | 3,519 | 4,862 | 154 | 3,938 | 1,738 | 2,442 | 22 | 155 | 9,722 | 8,560 |
| churn | vulkan | 3,519 | 1,979 | 0 | 0 | 3,519 | 4,862 | 154 | 3,938 | 1,738 | 2,442 | 22 | 155 | 9,722 | 8,560 |
| idle | sdl-gpu | 156 | 156 | 0 | 0 | 156 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 4 | 81 |
| idle | d3d12 | 153 | 153 | 0 | 0 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 79 |
| idle | vulkan | 153 | 153 | 0 | 0 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 79 |

