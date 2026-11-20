package ui

import clipboard "alicorn:host/clipboard"
import alicorn "alicorn:runtime"

// UI_Host_Services contains capabilities supplied by the selected platform
// host. Unsupported services are nil. Native alicorn:ui/webgpu currently
// provides one secondary window, native file dialogs, and a deferred-close quit
// request; browser UI currently has no window or dialog service.
UI_Host_Services :: struct {
	clipboard: clipboard.Clipboard_Service,
	windows: alicorn.Hosted_Window_Service,
	dialogs: alicorn.Hosted_Dialog_Service,
	quit: alicorn.Hosted_Quit_Service,
}

UI_Dialog_ID :: alicorn.Dialog_ID
UI_File_Dialog_Kind :: alicorn.File_Dialog_Kind
UI_Dialog_Filter :: alicorn.Dialog_Filter
UI_File_Dialog_Request :: alicorn.File_Dialog_Request
UI_Dialog_Status :: alicorn.Dialog_Status
UI_File_Dialog_Result :: alicorn.File_Dialog_Result
UI_Dialog_Service :: alicorn.Hosted_Dialog_Service
UI_Dialog_Result_Proc :: alicorn.Hosted_Dialog_Proc

// ui_dialog_show_file submits one asynchronous file-dialog request. The host
// copies the request and later delivers File_Dialog_Result through the
// application's on_dialog callback. It returns false when no dialog backend is
// available or the host already has a dialog open.
ui_dialog_show_file :: proc(service: UI_Dialog_Service, request: UI_File_Dialog_Request) -> bool {
	return alicorn.hosted_dialog_show_file(service, request)
}

// ui_quit_request completes a close request that the application deferred from
// on_close_requested. It is a no-op when the host supplied no quit service.
ui_quit_request :: proc(service: alicorn.Hosted_Quit_Service) {
	alicorn.hosted_quit_request(service)
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
