#+build !js

package alicorn

import "core:testing"

Dialog_Fake_Test_State :: struct {
	callbacks:   int,
	last_status: Dialog_Status,
	last_id:     Dialog_ID,
	path_count:  int,
}

dialog_fake_test_callback :: proc(data: rawptr, _rt: ^Runtime, result: ^File_Dialog_Result) {
	state := cast(^Dialog_Fake_Test_State)data
	state.callbacks += 1
	state.last_status = result.status
	state.last_id = result.id
	state.path_count = len(result.paths)
}

@(test)
test_optional_dialog_service_rejects_requests :: proc(t: ^testing.T) {
	testing.expect(t, !hosted_dialog_show_file({}, File_Dialog_Request{}),
		"a host without a dialog service rejects requests without crashing")
}

@(test)
test_fake_dialog_service_busy_and_completion_policy :: proc(t: ^testing.T) {
	state := Dialog_Fake_Test_State{}
	fake: Dialog_Fake_Backend
	service := Dialog_Fake_Service(&fake, dialog_fake_test_callback, rawptr(&state), nil)
	request := File_Dialog_Request{id=Dialog_ID(7), kind=.Open_Folder}
	testing.expect(t, hosted_dialog_show_file(service, request),
		"the first fake dialog request is accepted")
	testing.expect(t, !hosted_dialog_show_file(service, request) && fake.busy_rejections == 1,
		"a second active fake dialog request is rejected and observable")
	testing.expect(t, Dialog_Fake_Complete(&fake, .Accepted, "/tmp/example-repository"),
		"completing an active fake dialog invokes the callback")
	testing.expect(t, state.callbacks == 1 && state.last_status == .Accepted &&
		state.last_id == Dialog_ID(7) && state.path_count == 1,
		"the accepted completion preserves ID, status, and paths")
	testing.expect(t, hosted_dialog_show_file(service, request),
		"the fake dialog accepts a new request after completion")
	testing.expect(t, Dialog_Fake_Complete(&fake, .Cancelled),
		"a cancelled fake completion invokes the callback")
	testing.expect(t, state.callbacks == 2 && state.last_status == .Cancelled &&
		state.path_count == 0,
		"the cancelled completion clears paths")
}
