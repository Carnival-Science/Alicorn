package web_ui_package

import ui "alicorn:ui"

main :: proc() {
	ctx := ui.UI{}
	_ = ui.text(&ctx, "shared Alicorn UI authoring")
}
