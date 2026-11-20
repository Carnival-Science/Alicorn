package cpu_renderer

// Vertex is the backend-neutral CPU mesh product consumed by the native and
// future WebGPU renderers. Its three float fields preserve Alicorn's current
// position/color/UV layout (nine f32 values, 36 bytes).
Vertex :: struct {
	position: [3]f32,
	color:    [4]f32,
	uv:       [2]f32,
}

Append_Quad :: proc(vertices: ^[dynamic]Vertex, x0, y0, x1, y1: f32, color: [4]f32) {
	uv := [2]f32{0.5, 0.5}
	append(vertices,
		Vertex{[3]f32{x0, y0, 0}, color, uv},
		Vertex{[3]f32{x1, y0, 0}, color, uv},
		Vertex{[3]f32{x1, y1, 0}, color, uv},
		Vertex{[3]f32{x0, y0, 0}, color, uv},
		Vertex{[3]f32{x1, y1, 0}, color, uv},
		Vertex{[3]f32{x0, y1, 0}, color, uv},
	)
}
