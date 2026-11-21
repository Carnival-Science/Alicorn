package alicorn

import "core:strings"

// File_Drag_Start_Proc starts a native drag offering one existing filesystem
// path. The host copies or encodes the path before returning. The operation is
// synchronous with the initiating pointer gesture, as required by native drag
// source APIs.
File_Drag_Start_Proc :: proc(data: rawptr, path: string) -> bool

// File_Drag_Service is a UI-thread-only bridge for exporting a filesystem item
// to another native application. It is shared by the reference SDL_GPU host and
// the hosted SDL3/WebGPU host so an application uses one service vocabulary on
// either renderer. Importing dropped files remains a separate, cross-platform
// host input path; native drag-out is currently provided by the Windows OLE
// implementation in alicorn:host/sdl3/file_drag.
File_Drag_Service :: struct {
	data:  rawptr,
	start: File_Drag_Start_Proc,
}

application_file_drag_start :: proc(service: File_Drag_Service, path: string) -> bool {
	if service.start == nil || len(path) == 0 || strings.contains_rune(path, 0) { return false }
	return service.start(service.data, path)
}
