# Scratchpad-shaped workload summary

Runs per scenario and renderer: 5. Frames: 24. CPU wall time only; no GPU execution or scanout.

`application_build` is description minus reconcile; `measure_text` is text shaping across measure and layout.

## typing

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.401 | 0.363 | 0.380 |
| reconcile | 0.218 | 0.201 | 0.204 |
| reconcile_hash | 0.081 | 0.064 | 0.072 |
| reconcile_copy | 0.009 | 0.009 | 0.009 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.042 | 0.049 | 0.048 |
| measure_text | 0.038 | 0.046 | 0.043 |
| layout | 0.001 | 0.001 | 0.001 |
| semantic_sync | 0.020 | 0.019 | 0.019 |
| paint | 0.009 | 0.008 | 0.009 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.191 | 0.185 | 0.182 |
| reconcile_other | 0.053 | 0.052 | 0.049 |

## scroll

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.327 | 0.303 | 0.302 |
| reconcile | 0.150 | 0.136 | 0.140 |
| reconcile_hash | 0.075 | 0.067 | 0.065 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.001 | 0.001 | 0.001 |
| semantic_sync | 0.018 | 0.018 | 0.019 |
| paint | 0.001 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.180 | 0.161 | 0.176 |
| reconcile_other | 0.054 | 0.056 | 0.056 |

## selection

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.338 | 0.308 | 0.289 |
| reconcile | 0.168 | 0.139 | 0.137 |
| reconcile_hash | 0.081 | 0.065 | 0.064 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.002 | 0.001 | 0.001 |
| semantic_sync | 0.019 | 0.020 | 0.017 |
| paint | 0.001 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.188 | 0.170 | 0.178 |
| reconcile_other | 0.054 | 0.053 | 0.048 |

## resize

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.534 | 0.521 | 0.493 |
| reconcile | 0.422 | 0.371 | 0.359 |
| reconcile_hash | 0.077 | 0.062 | 0.069 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.012 | 0.014 | 0.013 |
| layout | 0.160 | 0.174 | 0.173 |
| semantic_sync | 0.020 | 0.017 | 0.019 |
| paint | 0.018 | 0.020 | 0.022 |
| composition | 0.016 | 0.018 | 0.018 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.187 | 0.159 | 0.177 |
| reconcile_other | 0.059 | 0.045 | 0.054 |

## tabs

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.337 | 0.289 | 0.311 |
| reconcile | 0.154 | 0.128 | 0.144 |
| reconcile_hash | 0.079 | 0.066 | 0.064 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.001 | 0.001 | 0.001 |
| semantic_sync | 0.020 | 0.018 | 0.019 |
| paint | 0.001 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.182 | 0.172 | 0.180 |
| reconcile_other | 0.056 | 0.048 | 0.055 |

## churn

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.862 | 0.839 | 0.916 |
| reconcile | 0.665 | 0.657 | 0.684 |
| reconcile_hash | 0.060 | 0.057 | 0.064 |
| reconcile_copy | 0.064 | 0.066 | 0.069 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.231 | 0.210 | 0.225 |
| measure_text | 0.218 | 0.199 | 0.214 |
| layout | 0.197 | 0.176 | 0.189 |
| semantic_sync | 0.020 | 0.018 | 0.019 |
| paint | 0.040 | 0.041 | 0.043 |
| composition | 0.024 | 0.022 | 0.023 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.222 | 0.210 | 0.229 |
| reconcile_other | 0.062 | 0.065 | 0.069 |

## idle

| Stage (median of per-run p95) | sdl-gpu | d3d12 | vulkan |
|---|---:|---:|---:|
| description | 0.128 | 0.136 | 0.150 |
| reconcile | 0.048 | 0.053 | 0.058 |
| reconcile_hash | 0.016 | 0.018 | 0.021 |
| reconcile_copy | 0.000 | 0.000 | 0.000 |
| structure_diff | 0.000 | 0.000 | 0.000 |
| measure | 0.000 | 0.000 | 0.000 |
| measure_text | 0.000 | 0.000 | 0.000 |
| layout | 0.000 | 0.000 | 0.000 |
| semantic_sync | 0.011 | 0.011 | 0.011 |
| paint | 0.000 | 0.000 | 0.000 |
| composition | 0.000 | 0.000 | 0.000 |
| finalize | 0.000 | 0.000 | 0.000 |
| application_build | 0.077 | 0.079 | 0.093 |
| reconcile_other | 0.021 | 0.024 | 0.026 |

## Description percentiles (median across runs)

| Scenario | Renderer | p50 (ms) | p95 (ms) | p99 (ms) |
|---|---|---:|---:|---:|
| typing | sdl-gpu | 0.312 | 0.401 | 0.448 |
| typing | d3d12 | 0.292 | 0.363 | 0.400 |
| typing | vulkan | 0.261 | 0.380 | 0.383 |
| scroll | sdl-gpu | 0.263 | 0.327 | 0.364 |
| scroll | d3d12 | 0.225 | 0.303 | 0.307 |
| scroll | vulkan | 0.245 | 0.302 | 0.342 |
| selection | sdl-gpu | 0.263 | 0.338 | 0.371 |
| selection | d3d12 | 0.230 | 0.308 | 0.322 |
| selection | vulkan | 0.237 | 0.289 | 0.324 |
| resize | sdl-gpu | 0.267 | 0.534 | 0.589 |
| resize | d3d12 | 0.183 | 0.521 | 0.627 |
| resize | vulkan | 0.231 | 0.493 | 0.625 |
| tabs | sdl-gpu | 0.255 | 0.337 | 0.346 |
| tabs | d3d12 | 0.247 | 0.289 | 0.318 |
| tabs | vulkan | 0.257 | 0.311 | 0.333 |
| churn | sdl-gpu | 0.680 | 0.862 | 0.915 |
| churn | d3d12 | 0.655 | 0.839 | 0.916 |
| churn | vulkan | 0.693 | 0.916 | 0.985 |
| idle | sdl-gpu | 0.128 | 0.128 | 0.128 |
| idle | d3d12 | 0.136 | 0.136 | 0.136 |
| idle | vulkan | 0.150 | 0.150 | 0.150 |

## Retained-work counters (median across runs)

| Scenario | Renderer | descriptions emitted | reused | exact-match reuses | structure-sequence matches | reconcile | measure | text shapes | layout | paint | compose | full finalize passes | semantic changes | persistent alloc calls | scratch alloc calls |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| typing | sdl-gpu | 3,588 | 3,566 | 3,566 | 23 | 3,588 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 564 | 1,383 |
| typing | d3d12 | 3,519 | 3,497 | 3,497 | 23 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 1,383 |
| typing | vulkan | 3,519 | 3,497 | 3,497 | 23 | 3,519 | 22 | 22 | 0 | 22 | 22 | 0 | 45 | 655 | 1,383 |
| scroll | sdl-gpu | 3,588 | 3,588 | 3,588 | 23 | 3,588 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 189 | 437 |
| scroll | d3d12 | 3,519 | 3,519 | 3,519 | 23 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 437 |
| scroll | vulkan | 3,519 | 3,519 | 3,519 | 23 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 437 |
| selection | sdl-gpu | 3,588 | 3,588 | 3,588 | 23 | 3,588 | 0 | 0 | 0 | 1 | 115 | 1 | 23 | 195 | 439 |
| selection | d3d12 | 3,519 | 3,519 | 3,519 | 23 | 3,519 | 0 | 0 | 0 | 1 | 112 | 1 | 23 | 286 | 439 |
| selection | vulkan | 3,519 | 3,519 | 3,519 | 23 | 3,519 | 0 | 0 | 0 | 1 | 112 | 1 | 23 | 286 | 439 |
| resize | sdl-gpu | 3,672 | 3,658 | 3,650 | 22 | 3,672 | 415 | 54 | 404 | 179 | 232 | 2 | 51 | 862 | 1,284 |
| resize | d3d12 | 3,603 | 3,589 | 3,581 | 22 | 3,603 | 401 | 54 | 396 | 176 | 226 | 2 | 50 | 937 | 1,273 |
| resize | vulkan | 3,603 | 3,589 | 3,581 | 22 | 3,603 | 401 | 54 | 396 | 176 | 226 | 2 | 50 | 937 | 1,273 |
| tabs | sdl-gpu | 3,588 | 3,588 | 3,588 | 23 | 3,588 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 189 | 437 |
| tabs | d3d12 | 3,519 | 3,519 | 3,519 | 23 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 437 |
| tabs | vulkan | 3,519 | 3,519 | 3,519 | 23 | 3,519 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 280 | 437 |
| churn | sdl-gpu | 3,588 | 2,048 | 2,048 | 23 | 3,588 | 5,016 | 154 | 3,982 | 1,738 | 2,508 | 22 | 155 | 9,719 | 7,246 |
| churn | d3d12 | 3,519 | 1,979 | 1,979 | 23 | 3,519 | 4,862 | 154 | 3,938 | 1,738 | 2,442 | 22 | 155 | 9,722 | 7,180 |
| churn | vulkan | 3,519 | 1,979 | 1,979 | 23 | 3,519 | 4,862 | 154 | 3,938 | 1,738 | 2,442 | 22 | 155 | 9,722 | 7,180 |
| idle | sdl-gpu | 156 | 156 | 156 | 1 | 156 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 4 | 19 |
| idle | d3d12 | 153 | 153 | 153 | 1 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 19 |
| idle | vulkan | 153 | 153 | 153 | 1 | 153 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 8 | 19 |

