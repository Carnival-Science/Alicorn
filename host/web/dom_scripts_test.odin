#+build !js

package web_host

import "core:testing"

@(test)
test_browser_input_focus_script_targets_canvas_and_text_proxy :: proc(t: ^testing.T) {
	canvas := browser_input_focus_script("alicorn-canvas", "alicorn-text-input", false)
	text := browser_input_focus_script("alicorn-canvas", "alicorn-text-input", true)
	testing.expect(t,
		canvas == "document.getElementById('alicorn-canvas').focus({preventScroll:true})" &&
		text == "document.getElementById('alicorn-text-input').focus({preventScroll:true})",
		"focus script should target the requested element and preserve literal JavaScript option braces")
}
