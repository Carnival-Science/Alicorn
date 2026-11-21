#+build !windows

package sdl3_file_drag

// Native drag-out currently has a Windows OLE implementation only. Other hosts
// still receive SDL file drops and retained in-application drag/drop; they
// report no native source so applications can fall back without a platform
// branch. See file_drag_windows.odin for the shared contract.

import alicorn "alicorn:runtime"

service :: proc() -> alicorn.File_Drag_Service {
	return {}
}

is_active :: proc() -> bool {
	return false
}
