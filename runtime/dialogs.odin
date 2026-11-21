package alicorn

import "core:mem"
import "core:strings"

// Host file dialogs are asynchronous services: an application submits a
// request through Hosted_Dialog_Service and receives one completion through
// Hosted_Dialog_Proc on the Runtime owner thread. Result paths and error text
// are borrowed only for the callback; clone any value the application keeps.
// The vocabulary mirrors the native SDL_GPU host so applications can move
// handlers between hosts without reshaping their dialog policy.

Dialog_ID :: distinct u64

File_Dialog_Kind :: enum {
	Open_File,
	Open_Folder,
	Save_File,
}

Dialog_Filter :: struct {
	name: string,
	// Host extension tokens, separated by semicolons (for example "json",
	// "jpg;jpeg", or "*"). This is not a glob; do not include "*.".
	pattern: string,
}

File_Dialog_Request :: struct {
	id:               Dialog_ID,
	kind:             File_Dialog_Kind,
	title:            string,
	initial_location: string,
	filters:          []Dialog_Filter,
	allow_many:       bool,
	accept_label:     string,
	cancel_label:     string,
}

Dialog_Status :: enum {
	Accepted,
	Cancelled,
	Error,
}

File_Dialog_Result :: struct {
	id:              Dialog_ID,
	status:          Dialog_Status,
	paths:           [dynamic]string,
	selected_filter: int,
	error:           string,
}

Hosted_Dialog_Proc :: proc(state: rawptr, rt: ^Runtime, result: ^File_Dialog_Result)

Hosted_Dialog_Show_File_Proc :: proc(data: rawptr, request: File_Dialog_Request) -> bool

// Hosted_Dialog_Service is an opaque host-owned service. A host that cannot
// present a dialog leaves the zero value, and hosted_dialog_show_file reports
// false. The request is copied by the host before the call returns.
Hosted_Dialog_Service :: struct {
	data:      rawptr,
	show_file: Hosted_Dialog_Show_File_Proc,
}

hosted_dialog_show_file :: proc(service: Hosted_Dialog_Service, request: File_Dialog_Request) -> bool {
	return service.show_file != nil && service.show_file(service.data, request)
}

// file_dialog_result_destroy releases the optional result allocations a host or
// test backend created with the supplied allocator.
file_dialog_result_destroy :: proc(result: ^File_Dialog_Result, allocator: mem.Allocator) {
	if result == nil { return }
	for path in result.paths {
		if len(path) > 0 { delete(path, allocator) }
	}
	if len(result.paths) > 0 { delete(result.paths) }
	if len(result.error) > 0 { delete(result.error, allocator) }
	result^ = {}
}

// Dialog_Fake_Backend is a headless test/service implementation. It exercises
// the accepted/cancelled/error callback shape and one-dialog busy policy without
// opening an OS panel. Complete it from the owner thread with
// Dialog_Fake_Complete.
Dialog_Fake_Backend :: struct {
	allocator:        mem.Allocator,
	active:           bool,
	request_count:    int,
	busy_rejections:  int,
	pending_id:       Dialog_ID,
	pending_kind:     File_Dialog_Kind,
	callback:         Hosted_Dialog_Proc,
	callback_state:   rawptr,
	callback_runtime: ^Runtime,
}

@(private)
dialog_fake_show_file :: proc(data: rawptr, request: File_Dialog_Request) -> bool {
	fake := cast(^Dialog_Fake_Backend)data
	if fake == nil || fake.callback == nil { return false }
	if fake.active {
		fake.busy_rejections += 1
		return false
	}
	fake.active = true
	fake.request_count += 1
	fake.pending_id = request.id
	fake.pending_kind = request.kind
	return true
}

Dialog_Fake_Service :: proc(
	fake: ^Dialog_Fake_Backend,
	callback: Hosted_Dialog_Proc,
	state: rawptr,
	rt: ^Runtime,
	allocator := context.allocator,
) -> Hosted_Dialog_Service {
	if fake == nil { return {} }
	fake^ = Dialog_Fake_Backend{
		allocator=allocator,
		callback=callback,
		callback_state=state,
		callback_runtime=rt,
	}
	return Hosted_Dialog_Service{data=rawptr(fake), show_file=dialog_fake_show_file}
}

Dialog_Fake_Complete :: proc(fake: ^Dialog_Fake_Backend, status: Dialog_Status, path := "", error := "") -> bool {
	if fake == nil || !fake.active || fake.callback == nil { return false }
	fake.active = false
	result := File_Dialog_Result{id=fake.pending_id, status=status, selected_filter=-1}
	result.paths = make([dynamic]string, 0, allocator=fake.allocator)
	if len(path) > 0 {
		copy, clone_err := strings.clone(path, fake.allocator)
		if clone_err == nil { append(&result.paths, copy) }
	}
	if len(error) > 0 { result.error, _ = strings.clone(error, fake.allocator) }
	fake.callback(fake.callback_state, fake.callback_runtime, &result)
	file_dialog_result_destroy(&result, fake.allocator)
	return true
}
