package sdl3_dialogs

// SDL3 file dialogs are renderer-agnostic host services shared by the native
// SDL_GPU host and the opt-in SDL3/WebGPU host. SDL's file-dialog callback may
// run away from the application thread, so this bridge copies the request,
// queues the completion, and wakes the host event loop. Result strings stay
// borrowed for the application callback.

import "core:c"
import "core:mem"
import "base:runtime"
import "core:strings"
import "core:sync"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

Dialog_ID :: alicorn.Dialog_ID
File_Dialog_Kind :: alicorn.File_Dialog_Kind
Dialog_Filter :: alicorn.Dialog_Filter
File_Dialog_Request :: alicorn.File_Dialog_Request
Dialog_Status :: alicorn.Dialog_Status
File_Dialog_Result :: alicorn.File_Dialog_Result
Dialog_Service :: alicorn.Hosted_Dialog_Service

Dialog_Message_Kind :: enum {
	Information,
	Warning,
	Error,
}

Dialog_Message_Button :: struct {
	id:             int,
	text:           string,
	default_return: bool,
	default_escape: bool,
}

Dialog_Message_Request :: struct {
	kind:    Dialog_Message_Kind,
	title:   string,
	message: string,
	buttons: []Dialog_Message_Button,
}

// Dialog_Waker is the host event-loop wake bridge. It mirrors the shape of the
// native and hosted wakers without importing either one.
Dialog_Waker :: struct {
	data: rawptr,
	wake: proc(data: rawptr),
}

// Dialog_Diagnostics optionally records breadcrumb events. The optional
// retain/release pair lets the owning host keep its recorder alive while an SDL
// callback may still be in flight.
Dialog_Diagnostic_Event_Proc :: proc(data: rawptr, event: string, request_id: u64)
Dialog_Diagnostics :: struct {
	data:    rawptr,
	event:   Dialog_Diagnostic_Event_Proc,
	retain:  proc(data: rawptr),
	release: proc(data: rawptr),
}

Native_Dialog_String :: struct {
	bytes: []byte,
	cstr:  cstring,
}

Native_Dialog_Request :: struct {
	bridge:          ^Native_Dialog_Bridge,
	id:              Dialog_ID,
	props:           sdl3.PropertiesID,
	filters:         [dynamic]sdl3.DialogFileFilter,
	filter_names:    [dynamic]Native_Dialog_String,
	filter_patterns: [dynamic]Native_Dialog_String,
	title:           Native_Dialog_String,
	location:        Native_Dialog_String,
	accept:          Native_Dialog_String,
	cancel:          Native_Dialog_String,
}

Native_Dialog_Bridge :: struct {
	allocator:       mem.Allocator,
	mutex:           sync.Mutex,
	wake_cond:       sync.Cond,
	completions:     [dynamic]File_Dialog_Result,
	window:          ^sdl3.Window,
	waker:           Dialog_Waker,
	active:          bool,
	active_id:       Dialog_ID,
	accepting:       bool,
	wakes_in_flight: int,
	next_id:         u64,
	refs:            int,
	diagnostics:     Dialog_Diagnostics,
}

@(private)
dialog_diagnostic_event :: proc(diagnostics: Dialog_Diagnostics, event: string, request_id: u64) {
	if diagnostics.event != nil { diagnostics.event(diagnostics.data, event, request_id) }
}

native_dialog_string_make :: proc(value: string, allocator: mem.Allocator) -> (Native_Dialog_String, bool) {
	bytes, err := make([]byte, len(value)+1, allocator)
	if err != nil { return {}, false }
	copy(bytes, value)
	bytes[len(value)] = 0
	return Native_Dialog_String{bytes=bytes, cstr=cstring(&bytes[0])}, true
}

native_dialog_string_destroy :: proc(value: ^Native_Dialog_String, allocator: mem.Allocator) {
	if value == nil { return }
	if len(value.bytes) > 0 { delete(value.bytes, allocator) }
	value^ = {}
}

native_dialog_bridge_make :: proc(
	window: ^sdl3.Window,
	waker: Dialog_Waker,
	diagnostics: Dialog_Diagnostics = {},
) -> ^Native_Dialog_Bridge {
	bridge := new(Native_Dialog_Bridge, allocator=context.allocator)
	bridge.allocator = context.allocator
	bridge.completions = make([dynamic]File_Dialog_Result, 0, allocator=bridge.allocator)
	bridge.window = window
	bridge.waker = waker
	bridge.accepting = true
	bridge.refs = 1 // host ownership; each in-flight SDL callback owns another.
	bridge.diagnostics = diagnostics
	if diagnostics.retain != nil { diagnostics.retain(diagnostics.data) }
	return bridge
}

native_dialog_result_destroy :: proc(result: ^File_Dialog_Result, allocator: mem.Allocator) {
	if result == nil { return }
	for path in result.paths {
		if len(path) > 0 { delete(path, allocator) }
	}
	if len(result.paths) > 0 { delete(result.paths) }
	if len(result.error) > 0 { delete(result.error, allocator) }
	result^ = {}
}

native_dialog_bridge_destroy :: proc(bridge: ^Native_Dialog_Bridge) {
	if bridge == nil { return }
	for &result in bridge.completions {
		native_dialog_result_destroy(&result, bridge.allocator)
	}
	delete(bridge.completions)
	if bridge.diagnostics.release != nil { bridge.diagnostics.release(bridge.diagnostics.data) }
	free(bridge, allocator=bridge.allocator)
}

native_dialog_bridge_release :: proc(bridge: ^Native_Dialog_Bridge) {
	if bridge == nil { return }
	should_destroy := false
	sync.mutex_lock(&bridge.mutex)
	bridge.refs -= 1
	if bridge.refs == 0 { should_destroy = true }
	sync.mutex_unlock(&bridge.mutex)
	if should_destroy { native_dialog_bridge_destroy(bridge) }
}

native_dialog_bridge_shutdown :: proc(bridge: ^Native_Dialog_Bridge) {
	if bridge == nil { return }
	sync.mutex_lock(&bridge.mutex)
	active_id := bridge.active_id
	bridge.accepting = false
	bridge.active = false
	bridge.active_id = 0
	bridge.waker = {}
	sync.cond_broadcast(&bridge.wake_cond)
	sync.mutex_unlock(&bridge.mutex)
	dialog_diagnostic_event(bridge.diagnostics, "dialog.shutdown.begin", u64(active_id))
	sync.mutex_lock(&bridge.mutex)
	// A callback may have copied the waker before accepting was cleared. Keep
	// the host's stack-owned waker alive until those calls have returned.
	for bridge.wakes_in_flight > 0 {
		sync.cond_wait(&bridge.wake_cond, &bridge.mutex)
	}
	sync.mutex_unlock(&bridge.mutex)
	dialog_diagnostic_event(bridge.diagnostics, "dialog.shutdown.complete", u64(active_id))
}

native_dialog_bridge_finish_wake :: proc(bridge: ^Native_Dialog_Bridge) {
	if bridge == nil { return }
	sync.mutex_lock(&bridge.mutex)
	bridge.wakes_in_flight -= 1
	if bridge.wakes_in_flight == 0 {
		sync.cond_broadcast(&bridge.wake_cond)
	}
	sync.mutex_unlock(&bridge.mutex)
}

native_dialog_request_destroy :: proc(request: ^Native_Dialog_Request) {
	if request == nil { return }
	bridge := request.bridge
	allocator := bridge.allocator
	if request.props != sdl3.PropertiesID(0) { sdl3.DestroyProperties(request.props) }
	for &value in request.filter_names { native_dialog_string_destroy(&value, allocator) }
	for &value in request.filter_patterns { native_dialog_string_destroy(&value, allocator) }
	delete(request.filter_names)
	delete(request.filter_patterns)
	delete(request.filters)
	native_dialog_string_destroy(&request.title, allocator)
	native_dialog_string_destroy(&request.location, allocator)
	native_dialog_string_destroy(&request.accept, allocator)
	native_dialog_string_destroy(&request.cancel, allocator)
	free(request, allocator=allocator)
}

native_dialog_callback_path :: proc(value: cstring, allocator: mem.Allocator) -> (string, bool) {
	if value == nil { return "", false }
	copy, err := strings.clone(string(value), allocator)
	if err != nil { return "", false }
	return copy, true
}

@(private)
native_dialog_file_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	request := cast(^Native_Dialog_Request)userdata
	if request == nil || request.bridge == nil { return }
	bridge := request.bridge
	request_id := request.id
	dialog_diagnostic_event(bridge.diagnostics, "dialog.callback.enter", u64(request_id))
	result := File_Dialog_Result{id=request_id, selected_filter=int(filter)}
	result.paths = make([dynamic]string, 0, allocator=bridge.allocator)
	if filelist == nil {
		result.status = .Error
		message := sdl3.GetError()
		if message != nil {
			result.error, _ = strings.clone(string(message), bridge.allocator)
		}
		if len(result.error) == 0 { result.error, _ = strings.clone("native file dialog failed", bridge.allocator) }
	} else if filelist[0] == nil {
		result.status = .Cancelled
	} else {
		result.status = .Accepted
		for i := 0; filelist[i] != nil; i += 1 {
			path, ok := native_dialog_callback_path(filelist[i], bridge.allocator)
			if ok { append(&result.paths, path) }
		}
		if len(result.paths) == 0 {
			result.status = .Error
			result.error, _ = strings.clone("native file dialog returned no paths", bridge.allocator)
		}
	}
	switch result.status {
	case .Accepted:   dialog_diagnostic_event(bridge.diagnostics, "dialog.callback.accepted", u64(request_id))
	case .Cancelled:  dialog_diagnostic_event(bridge.diagnostics, "dialog.callback.cancelled", u64(request_id))
	case .Error:      dialog_diagnostic_event(bridge.diagnostics, "dialog.callback.error", u64(request_id))
	}

	should_wake := false
	waker: Dialog_Waker
	sync.mutex_lock(&bridge.mutex)
	bridge.active = false
	bridge.active_id = 0
	if bridge.accepting {
		append(&bridge.completions, result)
		waker = bridge.waker
		bridge.wakes_in_flight += 1
		should_wake = true
	}
	sync.mutex_unlock(&bridge.mutex)
	if should_wake {
		dialog_diagnostic_event(bridge.diagnostics, "dialog.callback.queued", u64(request_id))
	} else {
		dialog_diagnostic_event(bridge.diagnostics, "dialog.callback.dropped_shutdown", u64(request_id))
		native_dialog_result_destroy(&result, bridge.allocator)
	}
	native_dialog_request_destroy(request)
	if should_wake {
		if waker.wake != nil { waker.wake(waker.data) }
		native_dialog_bridge_finish_wake(bridge)
	}
	dialog_diagnostic_event(bridge.diagnostics, "dialog.callback.completed", u64(request_id))
	native_dialog_bridge_release(bridge)
}

native_dialog_build_request :: proc(bridge: ^Native_Dialog_Bridge, request: File_Dialog_Request) -> (^Native_Dialog_Request, bool) {
	native := new(Native_Dialog_Request, allocator=bridge.allocator)
	native.bridge = bridge
	native.id = request.id
	native.filter_names = make([dynamic]Native_Dialog_String, 0, allocator=bridge.allocator)
	native.filter_patterns = make([dynamic]Native_Dialog_String, 0, allocator=bridge.allocator)
	native.filters = make([dynamic]sdl3.DialogFileFilter, 0, allocator=bridge.allocator)
	if native.id == Dialog_ID(0) {
		bridge.next_id += 1
		native.id = Dialog_ID(bridge.next_id)
	}
	for filter in request.filters {
		name, name_ok := native_dialog_string_make(filter.name, bridge.allocator)
		pattern, pattern_ok := native_dialog_string_make(filter.pattern, bridge.allocator)
		if !name_ok || !pattern_ok {
			native_dialog_string_destroy(&name, bridge.allocator)
			native_dialog_string_destroy(&pattern, bridge.allocator)
			native_dialog_request_destroy(native)
			return nil, false
		}
		append(&native.filter_names, name)
		append(&native.filter_patterns, pattern)
		append(&native.filters, sdl3.DialogFileFilter{name=name.cstr, pattern=pattern.cstr})
	}
	ok: bool
	native.title, ok = native_dialog_string_make(request.title, bridge.allocator)
	if !ok { native_dialog_request_destroy(native); return nil, false }
	native.location, ok = native_dialog_string_make(request.initial_location, bridge.allocator)
	if !ok { native_dialog_request_destroy(native); return nil, false }
	native.accept, ok = native_dialog_string_make(request.accept_label, bridge.allocator)
	if !ok { native_dialog_request_destroy(native); return nil, false }
	native.cancel, ok = native_dialog_string_make(request.cancel_label, bridge.allocator)
	if !ok { native_dialog_request_destroy(native); return nil, false }
	native.props = sdl3.CreateProperties()
	if native.props == sdl3.PropertiesID(0) { native_dialog_request_destroy(native); return nil, false }
	if len(native.filters) > 0 {
		if !sdl3.SetPointerProperty(native.props, sdl3.PROP_FILE_DIALOG_FILTERS_POINTER, rawptr(&native.filters[0])) {
			native_dialog_request_destroy(native); return nil, false
		}
	}
	if !sdl3.SetNumberProperty(native.props, sdl3.PROP_FILE_DIALOG_NFILTERS_NUMBER, sdl3.Sint64(len(native.filters))) ||
		!sdl3.SetPointerProperty(native.props, sdl3.PROP_FILE_DIALOG_WINDOW_POINTER, rawptr(bridge.window)) ||
		!sdl3.SetBooleanProperty(native.props, sdl3.PROP_FILE_DIALOG_MANY_BOOLEAN, request.allow_many) {
		native_dialog_request_destroy(native); return nil, false
	}
	if len(native.location.bytes) > 1 && !sdl3.SetStringProperty(native.props, sdl3.PROP_FILE_DIALOG_LOCATION_STRING, native.location.cstr) {
		native_dialog_request_destroy(native); return nil, false
	}
	if len(native.title.bytes) > 1 && !sdl3.SetStringProperty(native.props, sdl3.PROP_FILE_DIALOG_TITLE_STRING, native.title.cstr) {
		native_dialog_request_destroy(native); return nil, false
	}
	if len(native.accept.bytes) > 1 && !sdl3.SetStringProperty(native.props, sdl3.PROP_FILE_DIALOG_ACCEPT_STRING, native.accept.cstr) {
		native_dialog_request_destroy(native); return nil, false
	}
	if len(native.cancel.bytes) > 1 && !sdl3.SetStringProperty(native.props, sdl3.PROP_FILE_DIALOG_CANCEL_STRING, native.cancel.cstr) {
		native_dialog_request_destroy(native); return nil, false
	}
	return native, true
}

// dialog_service adapts one bridge to the renderer-agnostic Hosted_Dialog_Service
// that both SDL3 hosts publish through Hosted_Host_Services.
dialog_service :: proc(bridge: ^Native_Dialog_Bridge) -> alicorn.Hosted_Dialog_Service {
	if bridge == nil { return {} }
	return alicorn.Hosted_Dialog_Service{data=rawptr(bridge), show_file=native_dialog_show_file}
}

// native_dialog_show_file returns false when the host is shutting down or
// another native file dialog is already active. The request is copied before
// SDL sees it, so every string/filter remains valid until the async callback.
@(private)
native_dialog_show_file :: proc(data: rawptr, request: File_Dialog_Request) -> bool {
	bridge := cast(^Native_Dialog_Bridge)data
	if bridge == nil { return false }
	effective_request := request
	sync.mutex_lock(&bridge.mutex)
	if effective_request.id == 0 {
		bridge.next_id += 1
		effective_request.id = Dialog_ID(bridge.next_id)
	} else if u64(effective_request.id) > bridge.next_id {
		bridge.next_id = u64(effective_request.id)
	}
	accepted := bridge.accepting && !bridge.active
	if accepted {
		bridge.active = true
		bridge.active_id = effective_request.id
		bridge.refs += 1
	}
	sync.mutex_unlock(&bridge.mutex)
	dialog_diagnostic_event(bridge.diagnostics, "dialog.request.received", u64(effective_request.id))
	if !accepted {
		dialog_diagnostic_event(bridge.diagnostics, "dialog.request.rejected", u64(effective_request.id))
		return false
	}
	native, ok := native_dialog_build_request(bridge, effective_request)
	if !ok {
		sync.mutex_lock(&bridge.mutex)
		bridge.active = false
		bridge.active_id = 0
		bridge.refs -= 1
		sync.mutex_unlock(&bridge.mutex)
		dialog_diagnostic_event(bridge.diagnostics, "dialog.request.rejected", u64(effective_request.id))
		return false
	}
	type: sdl3.FileDialogType
	switch effective_request.kind {
	case .Open_File: type = .OPENFILE
	case .Save_File: type = .SAVEFILE
	case .Open_Folder: type = .OPENFOLDER
	}
	request_id := native.id
	dialog_diagnostic_event(bridge.diagnostics, "dialog.invoke", u64(request_id))
	sdl3.ShowFileDialogWithProperties(type, native_dialog_file_callback, rawptr(native), native.props)
	dialog_diagnostic_event(bridge.diagnostics, "dialog.invoke_return", u64(request_id))
	return true
}

// native_dialog_dispatch is called only by the host's owner-thread loop. Each
// result's paths and error remain borrowed through callback and are released
// immediately after it returns.
native_dialog_dispatch :: proc(
	bridge: ^Native_Dialog_Bridge,
	callback: alicorn.Hosted_Dialog_Proc,
	callback_state: rawptr,
	rt: ^alicorn.Runtime,
) {
	if bridge == nil || callback == nil { return }
	for {
		result: File_Dialog_Result
		have_result := false
		sync.mutex_lock(&bridge.mutex)
		if len(bridge.completions) > 0 {
			result = bridge.completions[0]
			ordered_remove(&bridge.completions, 0)
			have_result = true
		}
		sync.mutex_unlock(&bridge.mutex)
		if !have_result { break }
		dialog_diagnostic_event(bridge.diagnostics, "dialog.result.dispatched", u64(result.id))
		callback(callback_state, rt, &result)
		dialog_diagnostic_event(bridge.diagnostics, "dialog.result.dispatch_completed", u64(result.id))
		native_dialog_result_destroy(&result, bridge.allocator)
	}
}

dialog_message_flags :: proc(kind: Dialog_Message_Kind) -> sdl3.MessageBoxFlags {
	switch kind {
	case .Warning: return sdl3.MessageBoxFlags{.WARNING}
	case .Error: return sdl3.MessageBoxFlags{.ERROR}
	case .Information: return sdl3.MessageBoxFlags{.INFORMATION}
	}
	return sdl3.MessageBoxFlags{.INFORMATION}
}

Dialog_Message_Box_Show_Proc :: proc "c" (#by_ptr data: sdl3.MessageBoxData, selected: ^c.int) -> bool

dialog_show_message_box_result :: proc(
	data: sdl3.MessageBoxData,
	show: Dialog_Message_Box_Show_Proc,
) -> (button_id: int, ok: bool) {
	selected: c.int
	ok = show(data, &selected)
	return int(selected), ok
}

// ShowSimpleMessageBox is intentionally synchronous. Use it for genuinely
// modal alerts/confirmations, not for routine application errors.
ShowSimpleMessageBox :: proc(service: Dialog_Service, kind: Dialog_Message_Kind, title, message: string) -> bool {
	bridge := cast(^Native_Dialog_Bridge)service.data
	if bridge == nil { return false }
	title_c, title_err := strings.clone_to_cstring(title, context.temp_allocator)
	message_c, message_err := strings.clone_to_cstring(message, context.temp_allocator)
	if title_err != nil || message_err != nil { return false }
	return sdl3.ShowSimpleMessageBox(dialog_message_flags(kind), title_c, message_c, bridge.window)
}

// ShowMessageBox supports application-defined button IDs. It blocks the main
// thread until the user responds, as required for a native modal confirmation.
ShowMessageBox :: proc(service: Dialog_Service, request: Dialog_Message_Request) -> (button_id: int, ok: bool) {
	bridge := cast(^Native_Dialog_Bridge)service.data
	if bridge == nil { return 0, false }
	title_c, title_err := strings.clone_to_cstring(request.title, context.temp_allocator)
	message_c, message_err := strings.clone_to_cstring(request.message, context.temp_allocator)
	if title_err != nil || message_err != nil { return 0, false }
	buttons := make([]sdl3.MessageBoxButtonData, len(request.buttons), context.temp_allocator)
	for button, i in request.buttons {
		text, err := strings.clone_to_cstring(button.text, context.temp_allocator)
		if err != nil { return 0, false }
		flags := sdl3.MessageBoxButtonFlags{}
		if button.default_return { flags |= sdl3.MessageBoxButtonFlags{.RETURNKEY_DEFAULT} }
		if button.default_escape { flags |= sdl3.MessageBoxButtonFlags{.ESCAPEKEY_DEFAULT} }
		buttons[i] = sdl3.MessageBoxButtonData{flags=flags, buttonID=c.int(button.id), text=text}
	}
	button_ptr: [^]sdl3.MessageBoxButtonData
	if len(buttons) > 0 { button_ptr = &buttons[0] }
	data := sdl3.MessageBoxData{
		flags=dialog_message_flags(request.kind),
		window=bridge.window,
		title=title_c,
		message=message_c,
		numbuttons=c.int(len(buttons)),
		buttons=button_ptr,
	}
	return dialog_show_message_box_result(data, sdl3.ShowMessageBox)
}
