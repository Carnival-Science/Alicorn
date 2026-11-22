package alicorn_sdl_gpu

import "vendor:sdl3"

// Offline artifacts: DXC 1.9.2609 and glslang 16.6.0, pinned in
// lighting_shaders/manifest.json. Metal source is compiled by SDL on device.
// The fragment program reads the captured paint prefix once and writes the
// shaded result with blending disabled, so a group pixel is never darkened by
// the same light twice.
GPU_LIGHTING_FRAG_DXIL := #load("lighting_shaders/lighting.frag.dxil")
GPU_LIGHTING_FRAG_SPV := #load("lighting_shaders/lighting.frag.spv")
GPU_LIGHTING_FRAG_MSL := #load("lighting_shaders/lighting.frag.metal")

native_lighting_fragment_shader :: proc(device: ^sdl3.GPUDevice) -> ^sdl3.GPUShader {
	if device == nil { return nil }
	supported := sdl3.GetGPUShaderFormats(device)
	info := sdl3.GPUShaderCreateInfo{stage=.FRAGMENT, num_samplers=1, num_uniform_buffers=1}
	if native_shader_supported(supported, {.DXIL}) {
		info.format = {.DXIL}
		info.code = &GPU_LIGHTING_FRAG_DXIL[0]
		info.code_size = uint(len(GPU_LIGHTING_FRAG_DXIL))
		info.entrypoint = "PSMain"
	} else if native_shader_supported(supported, {.MSL}) {
		info.format = {.MSL}
		info.code = &GPU_LIGHTING_FRAG_MSL[0]
		info.code_size = uint(len(GPU_LIGHTING_FRAG_MSL))
		info.entrypoint = "main0"
	} else if native_shader_supported(supported, {.SPIRV}) {
		info.format = {.SPIRV}
		info.code = &GPU_LIGHTING_FRAG_SPV[0]
		info.code_size = uint(len(GPU_LIGHTING_FRAG_SPV))
		info.entrypoint = "main"
	}
	if info.code == nil { return nil }
	return sdl3.CreateGPUShader(device, info)
}
