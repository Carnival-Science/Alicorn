package web_host

import "core:fmt"

// browser_input_focus_script returns the narrow DOM command used to transfer
// focus between the canvas and the hidden text input without moving the page.
// Callers must validate the element IDs before embedding them in JavaScript.
browser_input_focus_script :: proc(canvas_id, text_input_id: string, wants_text: bool) -> string {
	target_id := canvas_id
	if wants_text { target_id = text_input_id }
	return fmt.tprintf("document.getElementById('%s').focus({{preventScroll:true}})", target_id)
}
