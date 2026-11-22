package web_host

import alicorn "alicorn:runtime"

// browser_pointer_button_from_mouse translates the DOM `MouseEvent.button`
// index into Alicorn's platform-neutral pointer button number. The auxclick
// indices 3 and 4 describe the back and forward navigation buttons; the
// browser host forwards them through the ordinary pointer path so applications
// own any navigation behavior.
browser_pointer_button_from_mouse :: proc(button: int) -> int {
	switch button {
	case 0: return alicorn.POINTER_BUTTON_PRIMARY
	case 1: return alicorn.POINTER_BUTTON_MIDDLE
	case 2: return alicorn.POINTER_BUTTON_SECONDARY
	case 3: return alicorn.POINTER_BUTTON_BACK
	case 4: return alicorn.POINTER_BUTTON_FORWARD
	}
	return 0
}
