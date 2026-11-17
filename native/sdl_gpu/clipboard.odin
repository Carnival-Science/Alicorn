package alicorn_sdl_gpu

// Temporary compatibility surface: the SDL clipboard now belongs to the
// SDL3 host package, while existing SDL_GPU applications retain these names
// during the renderer migration.
import sdl3_host "alicorn:host/sdl3"

Clipboard_Get_Text_Proc :: sdl3_host.Clipboard_Get_Text_Proc
Clipboard_Set_Text_Proc :: sdl3_host.Clipboard_Set_Text_Proc
Clipboard_Service :: sdl3_host.Clipboard_Service

ClipboardGetText :: proc(service: Clipboard_Service, allocator := context.allocator) -> (text: string, ok: bool) {
	return sdl3_host.ClipboardGetText(service, allocator)
}

ClipboardSetText :: proc(service: Clipboard_Service, text: string) -> bool {
	return sdl3_host.ClipboardSetText(service, text)
}

native_clipboard_service :: proc() -> Clipboard_Service {
	return sdl3_host.SDL3ClipboardService()
}
