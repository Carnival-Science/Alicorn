#+build !js

package sdl3_host

import "core:c"
import "core:strings"
import alicorn "alicorn:runtime"
import "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

SDL3_WebGPU_Secondary_Window :: struct {
	application: SDL3_WebGPU_Application,
	window: ^sdl3.Window,
	surface: wgpu.Surface,
	configuration: wgpu.SurfaceConfiguration,
}

// The first ui.run_webgpu window service intentionally supports one secondary
// window. It shares the primary device and queue while retaining independent
// surface, runtime, input, and presentation state.
SDL3_WebGPU_Window_Manager :: struct {
	instance: wgpu.Instance,
	adapter: wgpu.Adapter,
	device: wgpu.Device,
	queue: wgpu.Queue,
	primary_window: ^sdl3.Window,
	child: ^SDL3_WebGPU_Secondary_Window,
	pending: bool,
	creating: bool,
	pending_close: bool,
	pending_description: alicorn.Hosted_Window_Description,
	pending_title: string,
}

sdl3_webgpu_window_service :: proc(manager: ^SDL3_WebGPU_Window_Manager) -> alicorn.Hosted_Window_Service {
	if manager == nil { return {} }
	return {
		data=rawptr(manager),
		open=sdl3_webgpu_window_open,
		close=sdl3_webgpu_window_close_request,
		set_always_on_top=sdl3_webgpu_window_set_always_on_top,
		set_title=sdl3_webgpu_window_set_title,
	}
}

@(private)
sdl3_webgpu_window_open :: proc(data: rawptr, description: alicorn.Hosted_Window_Description) -> bool {
	manager := cast(^SDL3_WebGPU_Window_Manager)data
	if manager == nil || manager.instance == nil || manager.adapter == nil || manager.device == nil ||
	   manager.queue == nil || manager.primary_window == nil || manager.child != nil || manager.pending || manager.creating ||
	   description.config.render == nil {
		return false
	}
	title := description.title
	if title == "" { title = "Alicorn tool window" }
	owned_title, err := strings.clone(title, context.allocator)
	if err != nil { return false }
	manager.pending_description = description
	manager.pending_description.title = owned_title
	manager.pending_title = owned_title
	manager.pending = true
	return true
}

@(private)
sdl3_webgpu_window_close_request :: proc(data: rawptr) {
	manager := cast(^SDL3_WebGPU_Window_Manager)data
	if manager == nil { return }
	if manager.creating {
		manager.pending_close = true
		return
	}
	if manager.pending {
		if manager.pending_description.on_open_failed != nil {
			manager.pending_description.on_open_failed(manager.pending_description.config.state)
		}
		sdl3_webgpu_window_clear_pending(manager)
		return
	}
	if manager.child == nil { return }
	manager.pending_close = true
}

@(private)
sdl3_webgpu_window_set_always_on_top :: proc(data: rawptr, always_on_top: bool) -> bool {
	manager := cast(^SDL3_WebGPU_Window_Manager)data
	if manager == nil || manager.child == nil || manager.child.window == nil { return false }
	return sdl3.SetWindowAlwaysOnTop(manager.child.window, always_on_top)
}

@(private)
sdl3_webgpu_window_set_title :: proc(data: rawptr, title: string) -> bool {
	manager := cast(^SDL3_WebGPU_Window_Manager)data
	if manager == nil || manager.child == nil || manager.child.window == nil { return false }
	title_cstring, err := strings.clone_to_cstring(title, context.temp_allocator)
	if err != nil || !sdl3.SetWindowTitle(manager.child.window, title_cstring) { return false }
	return true
}

@(private)
sdl3_webgpu_window_clear_pending :: proc(manager: ^SDL3_WebGPU_Window_Manager) {
	if manager == nil { return }
	if len(manager.pending_title) > 0 { delete(manager.pending_title, context.allocator) }
	manager.pending_title = ""
	manager.pending_description = {}
	manager.pending = false
}

@(private)
sdl3_webgpu_window_creation_failed :: proc(manager: ^SDL3_WebGPU_Window_Manager) {
	if manager == nil { return }
	if manager.pending_description.on_open_failed != nil {
		manager.pending_description.on_open_failed(manager.pending_description.config.state)
	}
	sdl3_webgpu_window_clear_pending(manager)
}

@(private)
sdl3_webgpu_window_surface_configuration :: proc(
	manager: ^SDL3_WebGPU_Window_Manager,
	surface: wgpu.Surface,
	width, height: int,
	primary: wgpu.SurfaceConfiguration,
) -> (configuration: wgpu.SurfaceConfiguration, ok: bool) {
	capabilities, status := wgpu.SurfaceGetCapabilities(surface, manager.adapter)
	if status != .Success || capabilities.formatCount == 0 || capabilities.alphaModeCount == 0 ||
	   capabilities.presentModeCount == 0 ||
	   (capabilities.usages & wgpu.TextureUsageFlags{.RenderAttachment}) == {} {
		if status == .Success { wgpu.SurfaceCapabilitiesFreeMembers(capabilities) }
		return
	}
	defer wgpu.SurfaceCapabilitiesFreeMembers(capabilities)
	configuration = primary
	configuration.device = manager.device
	configuration.width = u32(width)
	configuration.height = u32(height)
	format_found := false
	for i in 0..<int(capabilities.formatCount) {
		if capabilities.formats[i] == primary.format {
			configuration.format = primary.format
			format_found = true
			break
		}
	}
	if !format_found {
		configuration.format = capabilities.formats[0]
		for i in 0..<int(capabilities.formatCount) {
			if capabilities.formats[i] == .BGRA8Unorm { configuration.format = .BGRA8Unorm }
		}
		for i in 0..<int(capabilities.formatCount) {
			if capabilities.formats[i] == .BGRA8UnormSrgb {
				configuration.format = .BGRA8UnormSrgb
				break
			}
		}
	}
	present_found := false
	for i in 0..<int(capabilities.presentModeCount) {
		if capabilities.presentModes[i] == primary.presentMode {
			configuration.presentMode = primary.presentMode
			present_found = true
			break
		}
	}
	if !present_found {
		configuration.presentMode = capabilities.presentModes[0]
		for i in 0..<int(capabilities.presentModeCount) {
			if capabilities.presentModes[i] == .Fifo {
				configuration.presentMode = .Fifo
				break
			}
		}
	}
	alpha_found := false
	for i in 0..<int(capabilities.alphaModeCount) {
		if capabilities.alphaModes[i] == primary.alphaMode {
			configuration.alphaMode = primary.alphaMode
			alpha_found = true
			break
		}
	}
	if !alpha_found {
		configuration.alphaMode = capabilities.alphaModes[0]
		for i in 0..<int(capabilities.alphaModeCount) {
			if capabilities.alphaModes[i] == .Opaque {
				configuration.alphaMode = .Opaque
				break
			}
		}
	}
	return configuration, true
}

// Creates a pending child at a main-loop safe point. Failures before runtime
// callbacks begin notify on_open_failed; once initialization begins, normal
// on_stop ownership applies if setup has to unwind.
sdl3_webgpu_window_create_pending :: proc(
	manager: ^SDL3_WebGPU_Window_Manager,
	primary_configuration: wgpu.SurfaceConfiguration,
	clear_color: wgpu.Color,
) -> bool {
	if manager == nil || !manager.pending || manager.device == nil { return true }
	description := manager.pending_description
	title := manager.pending_title
	width := description.width if description.width > 0 else 640
	height := description.height if description.height > 0 else 480
	title_cstring, title_error := strings.clone_to_cstring(title, context.temp_allocator)
	if title_error != nil {
		sdl3_webgpu_window_creation_failed(manager)
		return false
	}
	flags := sdl3.WindowFlags{.HIDDEN, .RESIZABLE, .HIGH_PIXEL_DENSITY}
	if description.always_on_top { flags += {.ALWAYS_ON_TOP} }
	window := sdl3.CreateWindow(title_cstring, c.int(width), c.int(height), flags)
	if window == nil {
		sdl3_webgpu_window_creation_failed(manager)
		return false
	}
	surface := sdl3glue.GetSurface(manager.instance, window)
	if surface == nil {
		sdl3.DestroyWindow(window)
		sdl3_webgpu_window_creation_failed(manager)
		return false
	}
	lw, lh, pw, ph, metrics_ok := sdl3_webgpu_application_window_metrics(window)
	if !metrics_ok || lw <= 0 || lh <= 0 || pw <= 0 || ph <= 0 {
		wgpu.SurfaceRelease(surface)
		sdl3.DestroyWindow(window)
		sdl3_webgpu_window_creation_failed(manager)
		return false
	}
	configuration, config_ok := sdl3_webgpu_window_surface_configuration(
		manager, surface, pw, ph, primary_configuration,
	)
	if !config_ok {
		wgpu.SurfaceRelease(surface)
		sdl3.DestroyWindow(window)
		sdl3_webgpu_window_creation_failed(manager)
		return false
	}
	child := new(SDL3_WebGPU_Secondary_Window, allocator=context.allocator)
	if child == nil {
		wgpu.SurfaceRelease(surface)
		sdl3.DestroyWindow(window)
		sdl3_webgpu_window_creation_failed(manager)
		return false
	}
	child.window = window
	child.surface = surface
	child.configuration = configuration
	child_config := description.config
	child_config.logical_width, child_config.logical_height = lw, lh
	child_config.pixel_width, child_config.pixel_height = pw, ph
	child_config.dpi_scale = f32(pw) / f32(lw)
	child_config.host_services.windows = sdl3_webgpu_window_service(manager)
	manager.creating = true
	sdl3_webgpu_window_clear_pending(manager)
	manager.child = child
	if result := sdl3_webgpu_application_init(
		&child.application, child_config, window, surface,
		manager.device, manager.queue, configuration, clear_color,
	); result != .Ok {
		manager.creating = false
		manager.child = nil
		if result == .Runtime_Failure && description.on_open_failed != nil {
			description.on_open_failed(description.config.state)
		}
		if child.application.presenter.state != nil {
			for !sdl3_webgpu_application_destroy(&child.application) {
				_ = wgpu.DevicePoll(manager.device, true)
				wgpu.InstanceProcessEvents(manager.instance)
			}
		}
		wgpu.SurfaceUnconfigure(surface)
		wgpu.SurfaceRelease(surface)
		sdl3.DestroyWindow(window)
		free(child, context.allocator)
		return false
	}
	manager.creating = false
	if !sdl3.ShowWindow(window) || !sdl3.RaiseWindow(window) {
		manager.pending_close = true
	} else {
		sdl3_webgpu_window_clear_pending(manager)
	}
	return true
}

sdl3_webgpu_window_has_in_flight :: proc(manager: ^SDL3_WebGPU_Window_Manager) -> bool {
	return manager != nil && manager.child != nil &&
		sdl3_webgpu_application_has_in_flight(&manager.child.application)
}

sdl3_webgpu_window_mark_device_lost :: proc(manager: ^SDL3_WebGPU_Window_Manager) {
	if manager != nil && manager.child != nil {
		sdl3_webgpu_application_mark_device_lost(&manager.child.application)
	}
}

sdl3_webgpu_window_detach_lost_presenter :: proc(manager: ^SDL3_WebGPU_Window_Manager) -> bool {
	if manager == nil || manager.child == nil { return true }
	return sdl3_webgpu_application_detach_lost_presenter(&manager.child.application)
}

sdl3_webgpu_window_attach_presenter :: proc(
	manager: ^SDL3_WebGPU_Window_Manager,
	configuration: wgpu.SurfaceConfiguration,
) -> bool {
	if manager == nil || manager.child == nil { return true }
	child_configuration := configuration
	child_configuration.format = manager.child.configuration.format
	child_configuration.alphaMode = manager.child.configuration.alphaMode
	child_configuration.width = manager.child.configuration.width
	child_configuration.height = manager.child.configuration.height
	return sdl3_webgpu_application_attach_presenter(
		&manager.child.application, manager.child.surface,
		manager.device, manager.queue, child_configuration,
	) == .Ok
}

// Destroy returns false while submitted queue work still references the child.
sdl3_webgpu_window_destroy :: proc(manager: ^SDL3_WebGPU_Window_Manager) -> bool {
	if manager == nil || manager.child == nil { return true }
	child := manager.child
	if !sdl3_webgpu_application_destroy(&child.application) { return false }
	if child.surface != nil {
		wgpu.SurfaceUnconfigure(child.surface)
		wgpu.SurfaceRelease(child.surface)
	}
	if child.window != nil { sdl3.DestroyWindow(child.window) }
	free(child, context.allocator)
	manager.child = nil
	manager.pending_close = false
	manager.creating = false
	return true
}

sdl3_webgpu_window_manager_destroy :: proc(
	manager: ^SDL3_WebGPU_Window_Manager,
	instance: wgpu.Instance,
	device: wgpu.Device,
	device_lost: bool,
) {
	if manager == nil { return }
	if manager.pending && manager.pending_description.on_open_failed != nil {
		manager.pending_description.on_open_failed(manager.pending_description.config.state)
	}
	sdl3_webgpu_window_clear_pending(manager)
	manager.pending_close = true
	for manager.child != nil {
		if sdl3_webgpu_window_destroy(manager) { break }
		if !device_lost && device != nil { _ = wgpu.DevicePoll(device, true) }
		if instance != nil { wgpu.InstanceProcessEvents(instance) }
		if device_lost || device == nil {
			event: sdl3.Event
			_ = sdl3.WaitEventTimeout(&event, 1)
		}
	}
}
