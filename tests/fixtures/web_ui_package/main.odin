package web_ui_package

import ui "alicorn:ui"
import cpu_renderer "alicorn:renderer/cpu"

main :: proc() {
	ctx := ui.UI{}
	_ = ui.text(&ctx, "shared Alicorn UI authoring")
	vertices := make([dynamic]cpu_renderer.Vertex, 0, 6, context.temp_allocator)
	defer delete(vertices)
	cpu_renderer.Append_Quad(&vertices, 0, 0, 1, 1, [4]f32{1, 1, 1, 1})
	_, _ = cpu_renderer.Snap_Text_X(0.75)
	_ = cpu_renderer.Pixel_Edge(-2.5, 1.25)
}
