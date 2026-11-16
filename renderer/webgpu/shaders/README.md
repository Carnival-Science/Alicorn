# WebGPU shader inventory

These are the shared WGSL sources used by the native and browser renderer.
Each Odin module embeds its source at compile time with `#load`, so runtime
shader-file access is not required and both targets compile the same text.

| Source | Pipeline role |
| --- | --- |
| `solid.wgsl` | Solid vertex colors and viewport mapping. |
| `text.wgsl` | Runa glyph atlas sampling, including color glyphs and retained per-command translation. |
| `icons.wgsl` | Tinted icon-atlas coverage sampling. |
| `images.wgsl` | Image texture sampling and vertex-color modulation. |
| `surfaces.wgsl` | Retained custom-surface geometry with per-instance transform and opacity. |
| `backdrop_effects.wgsl` | Backdrop effect texture sampling and composition. |

The Odin modules own pipeline and bind-group layouts. Keep WGSL entry points,
resource bindings, and vertex locations aligned with those declarations when
editing a source. This inventory intentionally lists renderer pipelines only;
the retired SDL_GPU shader artifacts remain under `native/sdl_gpu` until the
SDL_GPU removal gate.
