#+build !js

package sdl3_clipboard

import clipboard "alicorn:host/clipboard"

// UI_Clipboard_Backend keeps the platform service value alive for the shared
// UI service callback. The native application loop fills service before UI
// on_services or on_start runs.
UI_Clipboard_Backend :: struct {
	service: Clipboard_Service,
}

// UI_Clipboard_Service adapts the SDL3 clipboard host service to the
// renderer-neutral UI_Host_Services contract. It performs no rendering or GPU
// work, so SDL_GPU-only consumers can link this package without WebGPU.
UI_Clipboard_Service :: proc(backend: ^UI_Clipboard_Backend) -> clipboard.Clipboard_Service {
	if backend == nil { return {} }
	return clipboard.Clipboard_Service{
		data=rawptr(backend),
		read_text=ui_clipboard_read_text,
		write_text=ui_clipboard_write_text,
	}
}

ui_clipboard_read_text :: proc(
	data: rawptr,
	request_id: clipboard.Clipboard_Request_ID,
	completion_data: rawptr,
	completion: clipboard.Clipboard_Completion_Proc,
) -> bool {
	backend := cast(^UI_Clipboard_Backend)data
	if backend == nil || completion == nil { return false }
	text, ok := ClipboardGetText(backend.service, context.allocator)
	defer if len(text) > 0 { delete(text, context.allocator) }
	result := clipboard.Clipboard_Result.Failed
	if ok { result = .Success }
	completion(completion_data, request_id, result, text)
	return true
}

ui_clipboard_write_text :: proc(
	data: rawptr,
	request_id: clipboard.Clipboard_Request_ID,
	text: string,
	completion_data: rawptr,
	completion: clipboard.Clipboard_Completion_Proc,
) -> bool {
	backend := cast(^UI_Clipboard_Backend)data
	if backend == nil || completion == nil { return false }
	ok := ClipboardSetText(backend.service, text)
	result := clipboard.Clipboard_Result.Failed
	if ok { result = .Success }
	completion(completion_data, request_id, result, "")
	return true
}
