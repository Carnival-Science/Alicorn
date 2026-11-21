package alicorn_sdl_gpu

import alicorn "../../runtime"
import sdl3_file_drag "alicorn:host/sdl3/file_drag"

// The drag-out vocabulary lives in alicorn:runtime so the reference SDL_GPU
// host, the hosted SDL3/WebGPU host, and alicorn:ui publish one service shape.
// These aliases preserve the native Application-facing names. The platform
// implementation is shared in alicorn:host/sdl3/file_drag; this host delegates.
File_Drag_Start_Proc :: alicorn.File_Drag_Start_Proc

// File_Drag_Service is a UI-thread-only bridge for exporting a filesystem item
// to another native application. Importing dropped files remains available on
// all SDL platforms; native drag-out is currently provided by the Windows host.
File_Drag_Service :: alicorn.File_Drag_Service

application_file_drag_start :: alicorn.application_file_drag_start

native_file_drag_service :: proc() -> File_Drag_Service {
	return sdl3_file_drag.service()
}
