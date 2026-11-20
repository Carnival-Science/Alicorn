#+build !js

package sdl3_clipboard

import "core:mem"
import "core:strings"
import alicorn "alicorn:runtime"
import "vendor:sdl3"

// The synchronous clipboard vocabulary is defined by alicorn:runtime so the
// reference SDL_GPU host and hosted SDL3 surfaces publish one service shape.
Clipboard_Get_Text_Proc :: alicorn.Clipboard_Get_Text_Proc

Clipboard_Set_Text_Proc :: alicorn.Clipboard_Set_Text_Proc

Clipboard_Service :: alicorn.Clipboard_Service

ClipboardGetText :: alicorn.ClipboardGetText

ClipboardSetText :: alicorn.ClipboardSetText

ClipboardTextIsSupported :: alicorn.ClipboardTextIsSupported

@(private)
sdl3_clipboard_get_text :: proc(_data: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool) {
	native_text := sdl3.GetClipboardText()
	if native_text == nil { return "", false }
	defer sdl3.free(rawptr(native_text))

	cloned, err := strings.clone_from_cstring(cstring(native_text), allocator)
	return cloned, err == nil
}

@(private)
sdl3_clipboard_set_text :: proc(_data: rawptr, text: string) -> bool {
	if !ClipboardTextIsSupported(text) { return false }
	native_text, err := strings.clone_to_cstring(text, context.allocator)
	if err != nil { return false }
	defer delete(native_text, context.allocator)
	return sdl3.SetClipboardText(native_text)
}

SDL3ClipboardService :: proc() -> Clipboard_Service {
	return Clipboard_Service{
		get_text=sdl3_clipboard_get_text,
		set_text=sdl3_clipboard_set_text,
	}
}
