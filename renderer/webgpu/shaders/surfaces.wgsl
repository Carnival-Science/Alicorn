
struct View_Uniform {
	physical_size: vec2<f32>,
	origin_px: vec2<f32>,
};
@group(0) @binding(0) var<uniform> view: View_Uniform;
@group(1) @binding(0) var marker_texture: texture_2d<f32>;
@group(1) @binding(1) var marker_sampler: sampler;

struct Vertex_Input {
	@location(0) position: vec3<f32>,
	@location(1) color: vec4<f32>,
	@location(2) uv: vec2<f32>,
	@location(3) scale_origin: vec4<f32>,
	@location(4) opacity: f32,
};
struct Vertex_Output {
	@builtin(position) position: vec4<f32>,
	@location(0) color: vec4<f32>,
	@location(1) uv: vec2<f32>,
};

@vertex fn vs_main(input: Vertex_Input) -> Vertex_Output {
	var output: Vertex_Output;
	let physical = input.position.xy * input.scale_origin.xy + input.scale_origin.zw - view.origin_px;
	let top_left_ndc = physical / view.physical_size * 2.0 - vec2<f32>(1.0, 1.0);
	output.position = vec4<f32>(top_left_ndc.x, -top_left_ndc.y, input.position.z, 1.0);
	output.color = input.color;
	output.color.a *= input.opacity;
	output.uv = input.uv;
	return output;
}

@fragment fn fs_main(input: Vertex_Output) -> @location(0) vec4<f32> {
	return textureSample(marker_texture, marker_sampler, input.uv) * input.color;
}
