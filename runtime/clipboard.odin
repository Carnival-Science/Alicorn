package alicorn

import "core:mem"
import "core:strings"

// Clipboard_Get_Text_Proc returns an owned UTF-8 copy allocated by allocator.
// A successful empty clipboard is "", true; an OS failure is "", false.
Clipboard_Get_Text_Proc :: proc(data: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool)

// Clipboard_Set_Text_Proc copies borrowed UTF-8 text before returning.
Clipboard_Set_Text_Proc :: proc(data: rawptr, text: string) -> bool

// Clipboard_Service is a UI-thread-only, synchronous OS text clipboard
// capability. Native SDL3 and hosted SDL3 surfaces publish it as-is; browser
// hosts use the renderer-neutral asynchronous service in alicorn:host/clipboard
// instead because the Web Clipboard API completes asynchronously.
Clipboard_Service :: struct {
	data:     rawptr,
	get_text: Clipboard_Get_Text_Proc,
	set_text: Clipboard_Set_Text_Proc,
}

ClipboardGetText :: proc(service: Clipboard_Service, allocator := context.allocator) -> (text: string, ok: bool) {
	if service.get_text == nil { return "", false }
	return service.get_text(service.data, allocator)
}

// ClipboardSetText rejects embedded NUL bytes, which cannot be represented by
// SDL's NUL-terminated clipboard API.
ClipboardSetText :: proc(service: Clipboard_Service, text: string) -> bool {
	if !ClipboardTextIsSupported(text) || service.set_text == nil { return false }
	return service.set_text(service.data, text)
}

ClipboardTextIsSupported :: proc(text: string) -> bool {
	return !strings.contains_rune(text, 0)
}
