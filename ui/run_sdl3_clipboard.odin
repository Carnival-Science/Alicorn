#+build !js

package ui

import clipboard "alicorn:host/clipboard"
import sdl3_host "alicorn:host/sdl3"

// Run_SDL3_Clipboard_Backend keeps the platform service value alive for the
// shared UI service callback. The application loop's service callback fills
// this value before UI on_services or on_start runs.
Run_SDL3_Clipboard_Backend :: struct {
	service: sdl3_host.Clipboard_Service,
}

run_sdl3_clipboard_service :: proc(backend: ^Run_SDL3_Clipboard_Backend) -> clipboard.Clipboard_Service {
	if backend == nil { return {} }
	return clipboard.Clipboard_Service{
		data=rawptr(backend),
		read_text=run_sdl3_clipboard_read_text,
		write_text=run_sdl3_clipboard_write_text,
	}
}

run_sdl3_clipboard_read_text :: proc(
	data: rawptr,
	request_id: clipboard.Clipboard_Request_ID,
	completion_data: rawptr,
	completion: clipboard.Clipboard_Completion_Proc,
) -> bool {
	backend := cast(^Run_SDL3_Clipboard_Backend)data
	if backend == nil || completion == nil { return false }
	text, ok := sdl3_host.ClipboardGetText(backend.service, context.allocator)
	defer if len(text) > 0 { delete(text, context.allocator) }
	result := clipboard.Clipboard_Result.Failed
	if ok { result = .Success }
	completion(completion_data, request_id, result, text)
	return true
}

run_sdl3_clipboard_write_text :: proc(
	data: rawptr,
	request_id: clipboard.Clipboard_Request_ID,
	text: string,
	completion_data: rawptr,
	completion: clipboard.Clipboard_Completion_Proc,
) -> bool {
	backend := cast(^Run_SDL3_Clipboard_Backend)data
	if backend == nil || completion == nil { return false }
	ok := sdl3_host.ClipboardSetText(backend.service, text)
	result := clipboard.Clipboard_Result.Failed
	if ok { result = .Success }
	completion(completion_data, request_id, result, "")
	return true
}
