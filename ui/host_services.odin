package ui

import clipboard "alicorn:host/clipboard"
import alicorn "alicorn:runtime"

// UI_Host_Services contains capabilities supplied by the selected platform
// host. Unsupported services are nil. Native alicorn:ui/webgpu currently
// provides one secondary window, native file dialogs, a deferred-close quit
// request, the synchronous native clipboard, and the per-surface scheduler;
// browser UI has no window or dialog service and uses the asynchronous
// clipboard service.
UI_Host_Services :: struct {
	// clipboard is the renderer-neutral asynchronous UI clipboard contract.
	// Browser hosts complete it after permission checks; native hosts may
	// complete it synchronously.
	clipboard: clipboard.Clipboard_Service,
	// clipboard_text is the synchronous native SDL3 clipboard shape that
	// mirrors Application_Services.clipboard. It stays empty on browser hosts.
	clipboard_text: alicorn.Clipboard_Service,
	// file_drag mirrors Application_Services.file_drag. The Windows native
	// SDL_GPU host and the native SDL3/WebGPU host both publish the shared OLE
	// source; browser hosts leave it empty.
	file_drag: alicorn.File_Drag_Service,
	// scheduler mirrors Application_Services.scheduler. Every hosted Runtime
	// publishes one replaceable Frequent and Opportunistic deadline.
	scheduler: alicorn.Application_Scheduler,
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

// UI_Clipboard_Service is the synchronous native clipboard shape.
UI_Clipboard_Service :: alicorn.Clipboard_Service

ui_clipboard_get_text :: proc(service: UI_Clipboard_Service, allocator := context.allocator) -> (text: string, ok: bool) {
	return alicorn.ClipboardGetText(service, allocator)
}

ui_clipboard_set_text :: proc(service: UI_Clipboard_Service, text: string) -> bool {
	return alicorn.ClipboardSetText(service, text)
}

// UI_File_Drag_Service is the native drag-out capability. It has the same
// shape as native/sdl_gpu's Application_Services.file_drag, so an application
// initiates a drag with one call on either renderer.
UI_File_Drag_Service :: alicorn.File_Drag_Service
UI_File_Drag_Start_Proc :: alicorn.File_Drag_Start_Proc

ui_file_drag_start :: proc(service: UI_File_Drag_Service, path: string) -> bool {
	return alicorn.application_file_drag_start(service, path)
}

UI_Scheduler :: alicorn.Application_Scheduler
UI_Scheduled_Wake_Class :: alicorn.Scheduled_Wake_Class
UI_Scheduler_Stats :: alicorn.Application_Scheduler_Stats

ui_schedule_after :: proc(scheduler: UI_Scheduler, class: UI_Scheduled_Wake_Class, delay_ns: u64) -> bool {
	return alicorn.application_schedule_after(scheduler, class, delay_ns)
}

ui_cancel_scheduled_wake :: proc(scheduler: UI_Scheduler, class: UI_Scheduled_Wake_Class) -> bool {
	return alicorn.application_cancel_scheduled_wake(scheduler, class)
}

ui_scheduler_stats :: proc(scheduler: UI_Scheduler) -> UI_Scheduler_Stats {
	return alicorn.application_scheduler_stats(scheduler)
}

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
