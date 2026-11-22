#+build !js
package ui

import "core:testing"
import alicorn "alicorn:runtime"

ui_run_chrome_optional_render :: proc(_app: ^int, _ctx: ^UI) {}

ui_run_chrome_optional_post_wake :: proc(_data: rawptr) -> bool { return true }

ui_run_chrome_optional_appearance :: proc(
	_app: rawptr,
	_rt: ^alicorn.Runtime,
) -> alicorn.Window_Chrome_Appearance {
	return alicorn.Window_Chrome_Appearance{defined=true}
}

ui_run_chrome_optional_metrics :: proc(
	_app: rawptr,
	_rt: ^alicorn.Runtime,
	_metrics: alicorn.Window_Chrome_Metrics,
) {}

ui_run_chrome_optional_layout :: proc(
	_app: rawptr,
	_rt: ^alicorn.Runtime,
) -> alicorn.Window_Chrome_Layout {
	return {}
}

@(test)
test_ui_run_keeps_appearance_separate_from_owned_chrome :: proc(t: ^testing.T) {
	app_state := 0
	state := Hosted_Run_State(int){
		app=&app_state,
		render=ui_run_chrome_optional_render,
		window_decorations=.Integrated_Title_Bar,
		window_chrome_appearance=ui_run_chrome_optional_appearance,
	}
	native := run_application(&state, "optional chrome", 320, 240)
	testing.expect(t,
		native.window_chrome_metrics == nil && native.window_chrome_layout == nil &&
		native.window_chrome_appearance != nil,
		"an appearance-only app must retain host-owned titlebar hit testing")

	config := run_hosted_config(&state, 320, 240, 320, 240, 1, nil, ui_run_chrome_optional_post_wake)
	testing.expect(t,
		config.window_chrome_metrics == nil && config.window_chrome_layout == nil &&
		config.window_chrome_appearance != nil,
		"the shared hosted adapter must not turn appearance into app-owned chrome")
}

@(test)
test_ui_run_declares_custom_chrome_as_a_pair :: proc(t: ^testing.T) {
	app_state := 0
	state := Hosted_Run_State(int){
		app=&app_state,
		render=ui_run_chrome_optional_render,
		window_decorations=.Integrated_Title_Bar,
		window_chrome_layout=ui_run_chrome_optional_layout,
	}
	native := run_application(&state, "custom chrome", 320, 240)
	testing.expect(t,
		native.window_chrome_metrics != nil && native.window_chrome_layout != nil,
		"declaring either custom chrome callback must preserve the native callback pair")

	config := run_hosted_config(&state, 320, 240, 320, 240, 1, nil, ui_run_chrome_optional_post_wake)
	testing.expect(t,
		config.window_chrome_metrics != nil && config.window_chrome_layout != nil,
		"the shared hosted adapter must preserve the custom chrome callback pair")
}
