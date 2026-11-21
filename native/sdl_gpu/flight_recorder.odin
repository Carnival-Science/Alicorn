package alicorn_sdl_gpu

// Shared diagnostics compatibility. The implementation lives in
// alicorn:host/diagnostics so other Alicorn hosts (the hosted SDL3/WebGPU
// runtime and the browser host) get the same recorder, HUD model, bounds
// inspection, and capture schema. These aliases keep the reference SDL_GPU
// host's established names and tests unchanged.

import alicorn "../../runtime"
import diag "alicorn:host/diagnostics"

NATIVE_FLIGHT_RECORDER_CAPACITY :: diag.RECORDER_CAPACITY
NATIVE_POINTER_EVENT_CAPACITY    :: diag.POINTER_EVENT_CAPACITY

Native_DevTools_Sample :: diag.Sample
Native_Pointer_Event_Sample :: diag.Pointer_Sample
Native_DevTools_Activity_Class :: diag.Activity_Class
Native_Flight_Recorder :: diag.Recorder

native_flight_record :: proc(rec: ^Native_Flight_Recorder, sample: Native_DevTools_Sample) {
	diag.record(rec, sample)
}

native_flight_sample_at :: proc(
	rec: ^Native_Flight_Recorder,
	logical_index: int,
) -> (Native_DevTools_Sample, bool) {
	return diag.sample_at(rec, logical_index)
}

native_flight_sample_count :: proc(rec: ^Native_Flight_Recorder) -> int {
	return diag.sample_count(rec)
}

native_flight_sequence :: proc(rec: ^Native_Flight_Recorder) -> u64 {
	return diag.sequence(rec)
}

native_flight_pointer_record :: proc(rec: ^Native_Flight_Recorder, sample: Native_Pointer_Event_Sample) {
	diag.pointer_record(rec, sample)
}

native_flight_pointer_sample_at :: proc(
	rec: ^Native_Flight_Recorder,
	logical_index: int,
) -> (Native_Pointer_Event_Sample, bool) {
	return diag.pointer_sample_at(rec, logical_index)
}

native_flight_pointer_sample_count :: proc(rec: ^Native_Flight_Recorder) -> int {
	return diag.pointer_sample_count(rec)
}

native_flight_pointer_split_state :: proc(
	rt: ^alicorn.Runtime,
	id: alicorn.Node_ID,
) -> (owner_id: alicorn.Node_ID, position: f32, dragging, found: bool) {
	return diag.pointer_split_state(rt, id)
}
