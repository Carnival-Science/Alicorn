
struct View_Uniform {
	physical_size: vec2<f32>,
	origin_px: vec2<f32>,
};
@group(0) @binding(0) var<uniform> view: View_Uniform;
@group(0) @binding(1) var<storage, read> translations: array<vec2<f32>>;
@group(1) @binding(0) var atlas_texture: texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

struct Vertex_Input {
	@location(0) position: vec3<f32>,
	@location(1) color: vec4<f32>,
	@location(2) uv: vec2<f32>,
	@location(3) command_index: u32,
	@location(4) color_glyph: u32,
};
struct Vertex_Output {
	@builtin(position) position: vec4<f32>,
	@location(0) color: vec4<f32>,
	@location(1) uv: vec2<f32>,
	@location(2) @interpolate(flat) color_glyph: u32,
};

@vertex fn vs_main(input: Vertex_Input) -> Vertex_Output {
	var output: Vertex_Output;
	let physical = input.position.xy + translations[input.command_index];
	let local_position = physical - view.origin_px;
	let top_left_ndc = local_position / view.physical_size * 2.0 - vec2<f32>(1.0, 1.0);
	output.position = vec4<f32>(top_left_ndc.x, -top_left_ndc.y, input.position.z, 1.0);
	output.color = input.color;
	output.uv = input.uv;
	output.color_glyph = input.color_glyph;
	return output;
}

@fragment fn fs_main(input: Vertex_Output) -> @location(0) vec4<f32> {
	let sample = textureSample(atlas_texture, atlas_sampler, input.uv);
	if input.color_glyph != 0u {
		return sample * vec4<f32>(input.color.rgb, input.color.a);
	}
	return vec4<f32>(input.color.rgb, sample.r * input.color.a);
}
