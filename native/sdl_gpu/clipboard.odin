package alicorn_sdl_gpu

// Temporary compatibility surface: the SDL clipboard now belongs to the
// WebGPU-agnostic SDL3 clipboard package, while existing SDL_GPU applications
// retain these names during the renderer migration.
import sdl3_clipboard "alicorn:host/sdl3/clipboard"

Clipboard_Get_Text_Proc :: sdl3_clipboard.Clipboard_Get_Text_Proc
Clipboard_Set_Text_Proc :: sdl3_clipboard.Clipboard_Set_Text_Proc
Clipboard_Service :: sdl3_clipboard.Clipboard_Service

ClipboardGetText :: proc(service: Clipboard_Service, allocator := context.allocator) -> (text: string, ok: bool) {
	return sdl3_clipboard.ClipboardGetText(service, allocator)
}

ClipboardSetText :: proc(service: Clipboard_Service, text: string) -> bool {
	return sdl3_clipboard.ClipboardSetText(service, text)
}

native_clipboard_service :: proc() -> Clipboard_Service {
	return sdl3_clipboard.SDL3ClipboardService()
}
