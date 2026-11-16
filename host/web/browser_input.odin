#+build js wasm32, js wasm64p32

package web_host

import alicorn "alicorn:runtime"
import "core:sys/wasm/js"

Browser_Input_Wake_Proc :: proc(data: rawptr)
Browser_Input_Visibility_Proc :: proc(data: rawptr, visible: bool)

// Browser_Input attaches DOM event delivery to one focusable canvas. Start with
// a zero-initialized value and keep it alive until browser_input_detach. The
// embedding host owns the Hosted_Runtime, canvas sizing, frame scheduler and
// callback state. Give the canvas tabindex="0" so it can receive keyboard
// input; browser text composition still requires the separate text-input host.
// When on_visibility is supplied, that callback owns renderable coordination;
// otherwise this adapter directly updates Hosted_Runtime visibility.
Browser_Input :: struct {
	host: ^alicorn.Hosted_Runtime,
	canvas_id: string,
	platform: Browser_Platform,
	wake_data: rawptr,
	wake: Browser_Input_Wake_Proc,
	visibility_data: rawptr,
	on_visibility: Browser_Input_Visibility_Proc,
	last_x, last_y: f32,
	active_pointer_id: int,
	has_pointer_position: bool,
	pointer_active: bool,
	keyboard_modality: bool,
	focused: bool,
	attached: bool,
}

browser_input_install :: proc(
	input: ^Browser_Input,
	host: ^alicorn.Hosted_Runtime,
	canvas_id: string,
	platform: Browser_Platform,
	wake_data: rawptr,
	wake: Browser_Input_Wake_Proc,
	visibility_data: rawptr = nil,
	on_visibility: Browser_Input_Visibility_Proc = nil,
) -> bool {
	if input == nil || host == nil || canvas_id == "" || wake == nil { return false }
	if input.attached { return false }
	if _, status := alicorn.hosted_runtime_borrow(host); status != .Ok { return false }
	input^ = Browser_Input{
		host=host,
		canvas_id=canvas_id,
		platform=platform,
		wake_data=wake_data,
		wake=wake,
		visibility_data=visibility_data,
		on_visibility=on_visibility,
	}
	if !js.add_event_listener(canvas_id, .Pointer_Down, rawptr(input), browser_input_pointer_down) { browser_input_detach(input); return false }
	if !js.add_window_event_listener(.Pointer_Move, rawptr(input), browser_input_pointer_move) { browser_input_detach(input); return false }
	if !js.add_window_event_listener(.Pointer_Up, rawptr(input), browser_input_pointer_up) { browser_input_detach(input); return false }
	if !js.add_window_event_listener(.Pointer_Cancel, rawptr(input), browser_input_pointer_cancel) { browser_input_detach(input); return false }
	if !js.add_event_listener(canvas_id, .Wheel, rawptr(input), browser_input_wheel) { browser_input_detach(input); return false }
	if !js.add_event_listener(canvas_id, .Key_Down, rawptr(input), browser_input_key_down) { browser_input_detach(input); return false }
	if !js.add_event_listener(canvas_id, .Key_Press, rawptr(input), browser_input_key_press) { browser_input_detach(input); return false }
	if !js.add_document_event_listener(.Key_Down, rawptr(input), browser_input_document_key_down, use_capture=true) { browser_input_detach(input); return false }
	if !js.add_event_listener(canvas_id, .Focus, rawptr(input), browser_input_focus) { browser_input_detach(input); return false }
	if !js.add_event_listener(canvas_id, .Blur, rawptr(input), browser_input_blur) { browser_input_detach(input); return false }
	if !js.add_window_event_listener(.Blur, rawptr(input), browser_input_blur) { browser_input_detach(input); return false }
	if !js.add_document_event_listener(.Visibility_Change, rawptr(input), browser_input_visibility) { browser_input_detach(input); return false }
	input.attached = true
	return true
}

browser_input_detach :: proc(input: ^Browser_Input) {
	if input == nil { return }
	if input.canvas_id != "" {
		_ = js.remove_event_listener(input.canvas_id, .Pointer_Down, rawptr(input), browser_input_pointer_down)
		_ = js.remove_window_event_listener(.Pointer_Move, rawptr(input), browser_input_pointer_move)
		_ = js.remove_window_event_listener(.Pointer_Up, rawptr(input), browser_input_pointer_up)
		_ = js.remove_window_event_listener(.Pointer_Cancel, rawptr(input), browser_input_pointer_cancel)
		_ = js.remove_event_listener(input.canvas_id, .Wheel, rawptr(input), browser_input_wheel)
		_ = js.remove_event_listener(input.canvas_id, .Key_Down, rawptr(input), browser_input_key_down)
		_ = js.remove_event_listener(input.canvas_id, .Key_Press, rawptr(input), browser_input_key_press)
		_ = js.remove_document_event_listener(.Key_Down, rawptr(input), browser_input_document_key_down, use_capture=true)
		_ = js.remove_event_listener(input.canvas_id, .Focus, rawptr(input), browser_input_focus)
		_ = js.remove_event_listener(input.canvas_id, .Blur, rawptr(input), browser_input_blur)
		_ = js.remove_window_event_listener(.Blur, rawptr(input), browser_input_blur)
		_ = js.remove_document_event_listener(.Visibility_Change, rawptr(input), browser_input_visibility)
	}
	if input.attached && input.host != nil && (input.focused || input.pointer_active) {
		_ = alicorn.hosted_runtime_focus_changed(input.host, false)
	}
	input.attached = false
	input.focused = false
	input.pointer_active = false
}

browser_input_modifiers :: proc(event: js.Event) -> alicorn.Input_Modifiers {
	return alicorn.Input_Modifiers{
		shift=event.mouse.shift,
		control=event.mouse.ctrl,
		alt=event.mouse.alt,
		super=event.mouse.meta,
	}
}

browser_input_key :: proc(event: js.Event) -> Browser_Key_Event {
	return Browser_Key_Event{
		code=event.key.code,
		control=event.key.ctrl,
		shift=event.key.shift,
		alt=event.key.alt,
		meta=event.key.meta,
	}
}

browser_input_timestamp_ns :: proc(event: js.Event) -> u64 {
	if event.timestamp <= 0 { return 0 }
	return u64(event.timestamp * 1_000_000_000)
}

browser_input_canvas_point :: proc(input: ^Browser_Input, event: js.Event) -> (x, y: f32, inside: bool) {
	if input == nil || input.canvas_id == "" { return 0, 0, false }
	rect := js.get_bounding_client_rect(input.canvas_id)
	x = f32(f64(event.mouse.client[0])-rect.x)
	y = f32(f64(event.mouse.client[1])-rect.y)
	inside = x >= 0 && y >= 0 && x < f32(rect.width) && y < f32(rect.height)
	return x, y, inside
}

browser_input_dispatch_pointer :: proc(input: ^Browser_Input, event: js.Event, kind: alicorn.Pointer_Kind) -> bool {
	if input == nil || input.host == nil { return false }
	x, y, inside := browser_input_canvas_point(input, event)
	if kind == .Move {
		if input.pointer_active {
			if event.mouse.pointer.pointer_id != input.active_pointer_id { return false }
		} else if !inside || event.mouse.pointer.pointer_type == .Touch {
			return false
		}
	} else if kind == .Up || kind == .Cancel {
		if !input.pointer_active || event.mouse.pointer.pointer_id != input.active_pointer_id { return false }
	}
	if kind == .Down && input.pointer_active { return false }
	if kind == .Down || kind == .Up || kind == .Move {
		input.last_x, input.last_y = x, y
		input.has_pointer_position = true
	}
	button := 0
	if kind == .Down || kind == .Up {
		switch event.mouse.button {
		case 0: button = alicorn.POINTER_BUTTON_PRIMARY
		case 1: button = alicorn.POINTER_BUTTON_MIDDLE
		case 2: button = alicorn.POINTER_BUTTON_SECONDARY
		}
	}
	if kind == .Down {
		input.pointer_active = true
		input.active_pointer_id = event.mouse.pointer.pointer_id
		input.keyboard_modality = false
		input.focused = true
		_ = alicorn.hosted_runtime_focus_changed(input.host, true, false)
	}
	_, status := alicorn.hosted_runtime_pointer(input.host, alicorn.Pointer_Event{
		kind=kind,
		x=x,
		y=y,
		button=button,
		modifiers=browser_input_modifiers(event),
		timestamp_ns=browser_input_timestamp_ns(event),
	})
	if kind == .Up || kind == .Cancel {
		input.pointer_active = false
		input.active_pointer_id = 0
	}
	if status != .Ok {
		if kind == .Down {
			input.pointer_active = false
			input.active_pointer_id = 0
		}
		return false
	}
	input.wake(input.wake_data)
	return status == .Ok
}

browser_input_pointer_down :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil { return }
	_ = browser_input_dispatch_pointer(input, event, .Down)
}

browser_input_pointer_move :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil { return }
	_ = browser_input_dispatch_pointer(input, event, .Move)
}

browser_input_pointer_up :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil { return }
	_ = browser_input_dispatch_pointer(input, event, .Up)
}

browser_input_pointer_cancel :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil { return }
	_ = browser_input_dispatch_pointer(input, event, .Cancel)
}

browser_input_wheel :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil { return }
	mode := Browser_Wheel_Mode.Pixels
	switch event.wheel.delta_mode {
	case .Line: mode = .Lines
	case .Page: mode = .Pages
	case .Pixel:
	}
	viewport_height: f32 = 24
	if input.canvas_id != "" { viewport_height = f32(max(js.get_bounding_client_rect(input.canvas_id).height, 24)) }
	x, y := input.last_x, input.last_y
	if !input.has_pointer_position { x, y = 0, 0 }
	handled, status := alicorn.hosted_runtime_scroll(input.host, web_scroll_event(
		event.wheel.delta[0], event.wheel.delta[1], mode, viewport_height, x, y,
	))
	if status == .Ok && handled {
		js.event_prevent_default()
		input.wake(input.wake_data)
	}
}

browser_input_context_key :: proc(code: string) -> alicorn.Context_Menu_Key {
	switch code {
	case "ArrowUp": return .Up
	case "ArrowDown": return .Down
	case "Home": return .Home
	case "End": return .End
	case "Enter", "NumpadEnter", "Space": return .Activate
	case "Escape": return .Cancel
	case: return .Other
	}
}

browser_input_key_down :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil { return }
	input.keyboard_modality = true
	input.focused = true
	_ = alicorn.hosted_runtime_focus_changed(input.host, true, true)
	if event.is_composing { return }
	rt, status := alicorn.hosted_runtime_borrow(input.host)
	if status != .Ok { return }
	key_event := browser_input_key(event)

	if key_event.code == "Tab" && !key_event.control {
		if alicorn.application_dispatch_overlay_key(rt, .Other, is_tab=true, reverse_tab=key_event.shift) {
			js.event_prevent_default()
			input.wake(input.wake_data)
			return
		}
	} else if alicorn.application_dispatch_overlay_key(rt, browser_input_context_key(key_event.code)) {
		js.event_prevent_default()
		input.wake(input.wake_data)
		return
	}

	owner := alicorn.focused_node(rt)
	info, has_focus := alicorn.node_info(rt, owner)
	text_input_focused := has_focus && (info.kind == .Text_Field || info.text_input_target)
	composition_active := event.is_composing
	if has_focus && info.kind == .Text_Field {
		if interaction, ok := alicorn.text_field_interaction(rt, owner); ok {
			composition_active = composition_active || interaction.composition_active
		}
		if !composition_active {
			text_key, mapped := web_text_navigation_key(key_event, input.platform)
			if mapped {
				result, text_status := alicorn.hosted_runtime_text_key(input.host, text_key)
				if text_status == .Ok && result != .Unhandled {
					js.event_prevent_default()
					input.wake(input.wake_data)
					return
				}
			}
		}
	}

	if key_event.code == "Tab" && !key_event.control {
		if alicorn.application_dispatch_tab_focus(rt, key_event.shift) {
			js.event_prevent_default()
			input.wake(input.wake_data)
		}
		return
	}

	key, mapped := web_application_key(key_event, input.platform, menus_open=alicorn.context_menu_is_open(rt))
	if !mapped || (text_input_focused && !alicorn.application_key_can_preempt_text_field(key, composition_active)) { return }
	app_handled, key_status := alicorn.hosted_runtime_key(input.host, alicorn.Hosted_Key_Event{
		key_code=u32(key),
		pressed=true,
		repeat=event.key.repeat,
		modifiers=alicorn.Input_Modifiers{
			control=key_event.control,
			shift=key_event.shift,
			alt=key_event.alt,
			super=key_event.meta,
		},
	})
	if key_status == .Ok && app_handled {
		js.event_prevent_default()
		input.wake(input.wake_data)
		return
	}
	if alicorn.application_route_focused_control_key(rt, key) {
		js.event_prevent_default()
		input.wake(input.wake_data)
	}
}

// Observe document-level keyboard modality so a canvas that receives focus via
// Tab can show keyboard focus treatment before its first focused key handler.
browser_input_document_key_down :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input != nil { input.keyboard_modality = true }
}

browser_input_key_press :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil { return }
	key_event := browser_input_key(event)
	if !web_keypress_is_text(key_event, event.key.key, event.is_composing) { return }
	if alicorn.hosted_runtime_text_input(input.host, 0, .Commit, event.key.key) == .Ok {
		js.event_prevent_default()
		input.wake(input.wake_data)
	}
}

browser_input_focus :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil { return }
	if !input.focused {
		input.focused = true
		_ = alicorn.hosted_runtime_focus_changed(input.host, true, input.keyboard_modality)
	}
	input.wake(input.wake_data)
}

browser_input_blur :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil { return }
	input.pointer_active = false
	input.active_pointer_id = 0
	if input.focused {
		input.focused = false
		_ = alicorn.hosted_runtime_focus_changed(input.host, false)
	}
	input.wake(input.wake_data)
}

browser_input_visibility :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil { return }
	visible := event.visibility_change.is_visible
	if input.on_visibility == nil {
		_ = alicorn.hosted_runtime_set_renderable(input.host, visible)
	}
	if !visible {
		input.pointer_active = false
		input.active_pointer_id = 0
		if input.focused {
			input.focused = false
			_ = alicorn.hosted_runtime_focus_changed(input.host, false)
		}
	}
	if input.on_visibility != nil { input.on_visibility(input.visibility_data, visible) }
	if visible { input.wake(input.wake_data) }
}
