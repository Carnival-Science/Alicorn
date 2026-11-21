package alicorn_sdl_gpu

// Shared timeline export shim; see host/diagnostics/export.odin.

import alicorn "../../runtime"
import diag "alicorn:host/diagnostics"

native_flight_cause_name :: proc(kind: alicorn.Cause_Kind) -> string {
	return diag.cause_name_schema(kind)
}

native_flight_global_work_reason_name :: proc(reason: alicorn.Retained_Global_Work_Reason) -> string {
	return diag.global_work_reason_name(reason)
}

native_flight_pointer_kind_name :: proc(kind: alicorn.Pointer_Kind) -> string {
	return diag.pointer_kind_name(kind)
}

native_flight_node_kind_name :: proc(kind: alicorn.Node_Kind, valid: bool) -> string {
	return diag.node_kind_name(kind, valid)
}

native_flight_timeline_json :: proc(recorder: ^Native_Flight_Recorder) -> string {
	return diag.timeline_json(recorder)
}

native_write_flight_timeline :: proc(path: string, recorder: ^Native_Flight_Recorder) -> bool {
	return diag.write_timeline(path, recorder)
}
