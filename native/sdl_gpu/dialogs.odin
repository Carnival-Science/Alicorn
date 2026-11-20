package alicorn_sdl_gpu

// The SDL3 file-dialog implementation lives in alicorn:host/sdl3/dialogs so the
// reference SDL_GPU host and the opt-in SDL3/WebGPU host share one bridge. This
// file keeps the native Application-facing service vocabulary and breadcrumb
// adapter.

import "core:mem"
import alicorn "../../runtime"
import dialogs "alicorn:host/sdl3/dialogs"
import "vendor:sdl3"

Dialog_ID :: alicorn.Dialog_ID
File_Dialog_Kind :: alicorn.File_Dialog_Kind
Dialog_Filter :: alicorn.Dialog_Filter
File_Dialog_Request :: alicorn.File_Dialog_Request
Dialog_Status :: alicorn.Dialog_Status
File_Dialog_Result :: alicorn.File_Dialog_Result
Dialog_Service :: alicorn.Hosted_Dialog_Service
ShowFileDialog :: alicorn.hosted_dialog_show_file

Dialog_Fake_Backend :: alicorn.Dialog_Fake_Backend
Dialog_Fake_Service :: alicorn.Dialog_Fake_Service
Dialog_Fake_Complete :: alicorn.Dialog_Fake_Complete

Dialog_Message_Kind :: dialogs.Dialog_Message_Kind
Dialog_Message_Button :: dialogs.Dialog_Message_Button
Dialog_Message_Request :: dialogs.Dialog_Message_Request
Dialog_Message_Box_Show_Proc :: dialogs.Dialog_Message_Box_Show_Proc
dialog_show_message_box_result :: dialogs.dialog_show_message_box_result
ShowSimpleMessageBox :: dialogs.ShowSimpleMessageBox
ShowMessageBox :: dialogs.ShowMessageBox

Native_Dialog_Bridge :: dialogs.Native_Dialog_Bridge

Application_Dialog_Proc :: alicorn.Hosted_Dialog_Proc

// Application_Diagnostics lets an application write a small named breadcrumb
// into the host's opt-in postmortem event log. Event names are limited to
// lowercase ASCII letters, digits, periods, underscores, and hyphens. Do not
// include paths or user data; the host records timestamps, thread IDs, and the
// supplied request ID.
Application_Diagnostic_Event_Proc :: proc(data: rawptr, event: string, request_id: u64)

Application_Diagnostics :: struct {
	data:   rawptr,
	record: Application_Diagnostic_Event_Proc,
}

application_diagnostic_event :: proc(service: Application_Diagnostics, event: string, request_id: u64 = 0) {
	if service.record != nil { service.record(service.data, event, request_id) }
}

Application_Services :: struct {
	dialogs:     Dialog_Service,
	diagnostics: Application_Diagnostics,
	clipboard:   Clipboard_Service,
	file_drag:   File_Drag_Service,
	scheduler:   Application_Scheduler,
	motion_clock: Application_Motion_Clock,
	quit:        Application_Quit_Request,
	windows:     Application_Window_Service,
}

// Application_Motion_Clock supplies the same monotonic nanosecond domain the
// native host uses when it samples retained motion. Values are still passed
// explicitly into motion APIs, so tests and replay can inject their own time.
Application_Motion_Time_Now_Proc :: proc(data: rawptr) -> alicorn.Motion_Time

Application_Motion_Clock :: struct {
	data: rawptr,
	now:  Application_Motion_Time_Now_Proc,
}

// Application_Quit_Request lets an application complete a previously deferred
// close request after its own save/discard flow has finished. It is UI-thread
// only and remains valid for the lifetime of Run.
Application_Quit_Request_Proc :: alicorn.Hosted_Quit_Request_Proc
Application_Quit_Request :: alicorn.Hosted_Quit_Service

application_request_quit :: alicorn.hosted_quit_request

@(private)
native_dialog_diagnostic_event :: proc(data: rawptr, event: string, request_id: u64) {
	native_breadcrumb_event(cast(^Native_Breadcrumb_Recorder)data, "alicorn", event, request_id)
}

@(private)
native_dialog_diagnostic_retain :: proc(data: rawptr) {
	native_breadcrumbs_retain(cast(^Native_Breadcrumb_Recorder)data)
}

@(private)
native_dialog_diagnostic_release :: proc(data: rawptr) {
	native_breadcrumbs_release(cast(^Native_Breadcrumb_Recorder)data)
}

native_dialog_bridge_make :: proc(
	window: ^sdl3.Window,
	waker: Application_Waker,
	diagnostics: ^Native_Breadcrumb_Recorder = nil,
) -> ^Native_Dialog_Bridge {
	options := dialogs.Dialog_Diagnostics{}
	if diagnostics != nil {
		options = dialogs.Dialog_Diagnostics{
			data=rawptr(diagnostics),
			event=native_dialog_diagnostic_event,
			retain=native_dialog_diagnostic_retain,
			release=native_dialog_diagnostic_release,
		}
	}
	return dialogs.native_dialog_bridge_make(
		window,
		dialogs.Dialog_Waker{data=waker.data, wake=waker.wake},
		options,
	)
}

native_dialog_bridge_release :: dialogs.native_dialog_bridge_release
native_dialog_bridge_shutdown :: dialogs.native_dialog_bridge_shutdown

native_dialog_service :: proc(bridge: ^Native_Dialog_Bridge) -> Dialog_Service {
	return dialogs.dialog_service(bridge)
}

@(private)
native_dialog_application_callback :: proc(
	data: rawptr,
	rt: ^alicorn.Runtime,
	result: ^File_Dialog_Result,
) {
	application := cast(^Application)data
	if application == nil || application.on_dialog == nil { return }
	cause := alicorn.cause_begin(rt, .Async_Wake, "native file dialog completed")
	application.on_dialog(application.state, rt, result)
	alicorn.cause_end(rt, cause)
}

native_dialog_dispatch :: proc(
	bridge: ^Native_Dialog_Bridge,
	application: ^Application,
	rt: ^alicorn.Runtime,
) {
	dialogs.native_dialog_dispatch(
		bridge,
		native_dialog_application_callback,
		rawptr(application),
		rt,
	)
}

// Keep result ownership explicit for native callers that build their own fake
// or bridge results.
native_dialog_result_destroy :: proc(result: ^File_Dialog_Result, allocator: mem.Allocator) {
	dialogs.native_dialog_result_destroy(result, allocator)
}
