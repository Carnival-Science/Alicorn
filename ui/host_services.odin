package ui

import clipboard "alicorn:host/clipboard"
import alicorn "alicorn:runtime"

// UI_Host_Services contains capabilities supplied by the selected platform
// host. Unsupported services are nil. Native alicorn:ui/webgpu currently
// provides one secondary window; browser UI currently has no window service.
UI_Host_Services :: struct {
	clipboard: clipboard.Clipboard_Service,
	windows: alicorn.Hosted_Window_Service,
}

UI_Window_Description :: alicorn.Hosted_Window_Description
UI_Window_Service :: alicorn.Hosted_Window_Service

ui_window_open :: proc(service: UI_Window_Service, description: UI_Window_Description) -> bool {
	return alicorn.hosted_window_open(service, description)
}

ui_window_close :: proc(service: UI_Window_Service) {
	alicorn.hosted_window_close(service)
}

ui_window_set_always_on_top :: proc(service: UI_Window_Service, always_on_top: bool) -> bool {
	return alicorn.hosted_window_set_always_on_top(service, always_on_top)
}

ui_window_set_title :: proc(service: UI_Window_Service, title: string) -> bool {
	return alicorn.hosted_window_set_title(service, title)
}

UI_Clipboard_Request_ID :: clipboard.Clipboard_Request_ID
UI_Clipboard_Result :: clipboard.Clipboard_Result
UI_Clipboard_Completion_Proc :: clipboard.Clipboard_Completion_Proc

ui_clipboard_read_text :: proc(
	service: clipboard.Clipboard_Service,
	request_id: UI_Clipboard_Request_ID,
	completion_data: rawptr,
	completion: UI_Clipboard_Completion_Proc,
) -> bool {
	return clipboard.clipboard_read_text(service, request_id, completion_data, completion)
}

ui_clipboard_write_text :: proc(
	service: clipboard.Clipboard_Service,
	request_id: UI_Clipboard_Request_ID,
	text: string,
	completion_data: rawptr,
	completion: UI_Clipboard_Completion_Proc,
) -> bool {
	return clipboard.clipboard_write_text(service, request_id, text, completion_data, completion)
}
