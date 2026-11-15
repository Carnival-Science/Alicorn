#+build js
package webgpu_feasibility

import "base:runtime"
import "core:sys/wasm/js"
import "vendor:wgpu"

OS :: struct {}

os_init :: proc() {}
os_run :: proc() {}
os_process_gpu_events :: proc() {}
os_exit_failure :: proc() { panic("WebGPU feasibility readback failed") }

os_get_framebuffer_size :: proc()->(width,height:u32) {
	rect:=js.get_bounding_client_rect("wgpu-canvas")
	dpi:=js.device_pixel_ratio()
	return u32(max(f64(1),rect.width*dpi)),u32(max(f64(1),rect.height*dpi))
}
os_set_surface_size :: proc(width,height:u32) {
	js.set_element_key_f64("wgpu-canvas","width",f64(width))
	js.set_element_key_f64("wgpu-canvas","height",f64(height))
}
os_get_surface :: proc(instance:wgpu.Instance)->wgpu.Surface {
	return wgpu.InstanceCreateSurface(instance,&wgpu.SurfaceDescriptor{
		nextInChain=&wgpu.SurfaceSourceCanvasHTMLSelector{sType=.SurfaceSourceCanvasHTMLSelector,selector="#wgpu-canvas"},
	})
}
@(private="file", fini)
os_fini :: proc "contextless" () {
	context=runtime.default_context()
	finish()
}
