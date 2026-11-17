package clipboard

// Clipboard_Request_ID is owned by the requesting application. Hosts return
// it unchanged in the completion callback so overlapping requests can be
// matched without retaining application pointers in renderer state.
Clipboard_Request_ID :: distinct u64

Clipboard_Result :: enum {
	Success,
	Unsupported,
	Permission_Denied,
	Unavailable,
	Too_Large,
	Cancelled,
	Failed,
}

// A read completion's text is borrowed only until the callback returns. A
// service may complete synchronously (as native clipboard APIs often do) or
// later on the owning host thread (as browser permission APIs do).
Clipboard_Completion_Proc :: proc(
	data: rawptr,
	request_id: Clipboard_Request_ID,
	result: Clipboard_Result,
	text: string,
)

Clipboard_Read_Text_Proc :: proc(
	data: rawptr,
	request_id: Clipboard_Request_ID,
	completion_data: rawptr,
	completion: Clipboard_Completion_Proc,
) -> bool

Clipboard_Write_Text_Proc :: proc(
	data: rawptr,
	request_id: Clipboard_Request_ID,
	text: string,
	completion_data: rawptr,
	completion: Clipboard_Completion_Proc,
) -> bool

// Clipboard_Service is a borrowed host capability. Its owner keeps data and
// callback state alive until the host's stop callback has returned. A false
// request result means the host rejected the request and will not call back.
Clipboard_Service :: struct {
	data: rawptr,
	read_text: Clipboard_Read_Text_Proc,
	write_text: Clipboard_Write_Text_Proc,
}

clipboard_read_text :: proc(
	service: Clipboard_Service,
	request_id: Clipboard_Request_ID,
	completion_data: rawptr,
	completion: Clipboard_Completion_Proc,
) -> bool {
	return service.read_text != nil && completion != nil &&
		service.read_text(service.data, request_id, completion_data, completion)
}

clipboard_write_text :: proc(
	service: Clipboard_Service,
	request_id: Clipboard_Request_ID,
	text: string,
	completion_data: rawptr,
	completion: Clipboard_Completion_Proc,
) -> bool {
	return service.write_text != nil && completion != nil &&
		service.write_text(service.data, request_id, text, completion_data, completion)
}
