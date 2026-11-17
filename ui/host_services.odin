package ui

import clipboard "alicorn:host/clipboard"

// UI_Host_Services contains capabilities supplied by the selected platform
// host. Unsupported services are nil; applications can use the same callback
// on native and browser targets without importing a renderer package.
UI_Host_Services :: struct {
	clipboard: clipboard.Clipboard_Service,
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
