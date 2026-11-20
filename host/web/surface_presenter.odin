#+build js wasm32, js wasm64p32

package web_host

import alicorn "alicorn:runtime"
import "vendor:wgpu"
import shared "alicorn:host/presentation"

Browser_Surface_Result :: shared.Hosted_Surface_Result
Browser_Surface_Wake_Proc :: shared.Hosted_Surface_Wake_Proc
Browser_Surface_Presenter :: shared.Hosted_Surface_Presenter

browser_surface_presenter_init :: proc(
	presenter: ^Browser_Surface_Presenter,
	hosted: ^alicorn.Hosted_Runtime,
	surface: wgpu.Surface,
	device: wgpu.Device,
	queue: wgpu.Queue,
	configuration: wgpu.SurfaceConfiguration,
	logical_width, logical_height: int,
	dpi_scale: f32,
	wake_data: rawptr,
	wake: Browser_Surface_Wake_Proc,
	clear_color: wgpu.Color = {0.04, 0.06, 0.08, 1},
) -> Browser_Surface_Result {
	return shared.hosted_surface_presenter_init(
		presenter, hosted, surface, device, queue, configuration,
		logical_width, logical_height, dpi_scale, wake_data, wake, clear_color,
	)
}

browser_surface_presenter_resize :: proc(
	presenter: ^Browser_Surface_Presenter,
	logical_width, logical_height, pixel_width, pixel_height: int,
	dpi_scale: f32,
) -> Browser_Surface_Result {
	return shared.hosted_surface_presenter_resize(
		presenter, logical_width, logical_height, pixel_width, pixel_height, dpi_scale,
	)
}

browser_surface_presenter_set_visible :: proc(
	presenter: ^Browser_Surface_Presenter,
	visible: bool,
) -> Browser_Surface_Result {
	return shared.hosted_surface_presenter_set_visible(presenter, visible)
}

browser_surface_visibility_changed :: proc(data: rawptr, visible: bool) {
	shared.hosted_surface_visibility_changed(data, visible)
}

browser_surface_presenter_step :: proc(
	presenter: ^Browser_Surface_Presenter,
	now_ns: u64,
) -> (step: alicorn.Hosted_Step_Result, presentation: Browser_Surface_Result) {
	return shared.hosted_surface_presenter_step(presenter, now_ns)
}

browser_surface_presenter_destroy :: proc(presenter: ^Browser_Surface_Presenter) -> bool {
	return shared.hosted_surface_presenter_destroy(presenter)
}

browser_surface_presenter_mark_device_lost :: proc(presenter: ^Browser_Surface_Presenter) {
	shared.hosted_surface_presenter_mark_device_lost(presenter)
}

browser_surface_presenter_destroy_after_device_loss :: proc(presenter: ^Browser_Surface_Presenter) -> bool {
	return shared.hosted_surface_presenter_destroy_after_device_loss(presenter)
}
