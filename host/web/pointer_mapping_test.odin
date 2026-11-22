#+build !js

package web_host

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_browser_pointer_buttons_include_back_and_forward :: proc(t: ^testing.T) {
	cases := [6]struct { dom, expected: int }{
		{0, alicorn.POINTER_BUTTON_PRIMARY},
		{1, alicorn.POINTER_BUTTON_MIDDLE},
		{2, alicorn.POINTER_BUTTON_SECONDARY},
		{3, alicorn.POINTER_BUTTON_BACK},
		{4, alicorn.POINTER_BUTTON_FORWARD},
		{5, 0},
	}
	for c in cases {
		testing.expect(t, browser_pointer_button_from_mouse(c.dom) == c.expected,
			"a DOM mouse-button index should map to the documented Alicorn pointer button")
	}
	testing.expect(t, browser_pointer_button_from_mouse(3) == alicorn.POINTER_BUTTON_BACK &&
		browser_pointer_button_from_mouse(4) == alicorn.POINTER_BUTTON_FORWARD,
		"browser auxclick buttons 3/4 must surface as back/forward, not as primary-like clicks")
}
