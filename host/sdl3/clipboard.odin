#+build !js

package sdl3_host

import "core:mem"
import "core:strings"
import "vendor:sdl3"

// Clipboard_Get_Text_Proc returns an owned UTF-8 copy allocated by allocator.
// A successful empty clipboard is "", true; an OS failure is "", false.
Clipboard_Get_Text_Proc :: proc(data: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool)

// Clipboard_Set_Text_Proc copies borrowed UTF-8 text before returning.
Clipboard_Set_Text_Proc :: proc(data: rawptr, text: string) -> bool

// Clipboard_Service is an SDL3 host service. Calls belong on the SDL owner
// thread; the service contains no renderer or GPU state.
Clipboard_Service :: struct {
	data: rawptr,
	get_text: Clipboard_Get_Text_Proc,
	set_text: Clipboard_Set_Text_Proc,
}

ClipboardGetText :: proc(service: Clipboard_Service, allocator := context.allocator) -> (text: string, ok: bool) {
	if service.get_text == nil { return "", false }
	return service.get_text(service.data, allocator)
}

// ClipboardSetText rejects embedded NUL bytes, which cannot be represented
// by SDL's NUL-terminated clipboard API.
ClipboardSetText :: proc(service: Clipboard_Service, text: string) -> bool {
	if !ClipboardTextIsSupported(text) || service.set_text == nil { return false }
	return service.set_text(service.data, text)
}

ClipboardTextIsSupported :: proc(text: string) -> bool {
	return !strings.contains_rune(text, 0)
}

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
