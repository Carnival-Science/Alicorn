#+build js wasm32, js wasm64p32

package web_host

import alicorn "alicorn:runtime"
import "core:fmt"
import "core:sys/wasm/js"

Browser_Input_Wake_Proc :: proc(data: rawptr)
Browser_Input_Visibility_Proc :: proc(data: rawptr, visible: bool)

// Browser_Input attaches DOM event delivery to one focusable canvas. Start with
// a zero-initialized value and keep it alive until browser_input_detach. The
// embedding host owns the Hosted_Runtime, canvas sizing, frame scheduler and
// callback state. Give the canvas tabindex="0" so it can receive keyboard
// input. text_input_id optionally names a host-provided, visually hidden
// textarea used for committed text, paste, and IME composition. For the focus
// bridge, both DOM IDs must use ASCII letters/digits, '_' or '-'. The textarea
// is an input device only; Hosted_Runtime remains authoritative. When
// on_visibility is supplied, that callback owns renderable coordination;
// otherwise this adapter directly updates Hosted_Runtime visibility.
Browser_Input :: struct {
	host: ^alicorn.Hosted_Runtime,
	canvas_id: string,
	text_input_id: string,
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
	focus_transfer: bool,
	dom_focus_known: bool,
	dom_focus_is_text: bool,
	composition_active: bool,
	composition_cancel_on_end: bool,
	suppress_composition_echo: bool,
	last_composition_hash: u64,
	last_composition_length: int,
	last_composition_timestamp: f64,
	proxy_left, proxy_top, proxy_height: f64,
	proxy_geometry_valid: bool,
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
	text_input_id: string = "",
) -> bool {
	if input == nil || host == nil || canvas_id == "" || wake == nil ||
	   (text_input_id != "" && !browser_input_dom_id_is_safe(canvas_id)) ||
	   (text_input_id != "" && text_input_id == canvas_id) ||
	   (text_input_id != "" && !browser_input_dom_id_is_safe(text_input_id)) {
		return false
	}
	if input.attached { return false }
	if _, status := alicorn.hosted_runtime_borrow(host); status != .Ok { return false }
	input^ = Browser_Input{
		host=host,
		canvas_id=canvas_id,
		text_input_id=text_input_id,
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
	if !js.add_event_listener(canvas_id, .Blur, rawptr(input), browser_input_element_blur) { browser_input_detach(input); return false }
	if !js.add_window_event_listener(.Blur, rawptr(input), browser_input_window_blur) { browser_input_detach(input); return false }
	if !js.add_document_event_listener(.Visibility_Change, rawptr(input), browser_input_visibility) { browser_input_detach(input); return false }
	if text_input_id != "" {
		if !js.add_event_listener(text_input_id, .Key_Down, rawptr(input), browser_input_key_down) { browser_input_detach(input); return false }
		if !js.add_event_listener(text_input_id, .Key_Press, rawptr(input), browser_input_key_press) { browser_input_detach(input); return false }
		if !js.add_event_listener(text_input_id, .Focus, rawptr(input), browser_input_focus) { browser_input_detach(input); return false }
		if !js.add_event_listener(text_input_id, .Blur, rawptr(input), browser_input_element_blur) { browser_input_detach(input); return false }
		if !js.add_custom_event_listener(text_input_id, "input", rawptr(input), browser_input_text_input) { browser_input_detach(input); return false }
		if !js.add_custom_event_listener(text_input_id, "compositionstart", rawptr(input), browser_input_composition_start) { browser_input_detach(input); return false }
		if !js.add_custom_event_listener(text_input_id, "compositionend", rawptr(input), browser_input_composition_end) { browser_input_detach(input); return false }
	}
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
		_ = js.remove_event_listener(input.canvas_id, .Blur, rawptr(input), browser_input_element_blur)
		_ = js.remove_window_event_listener(.Blur, rawptr(input), browser_input_window_blur)
		_ = js.remove_document_event_listener(.Visibility_Change, rawptr(input), browser_input_visibility)
	}
	if input.text_input_id != "" {
		_ = js.remove_event_listener(input.text_input_id, .Key_Down, rawptr(input), browser_input_key_down)
		_ = js.remove_event_listener(input.text_input_id, .Key_Press, rawptr(input), browser_input_key_press)
		_ = js.remove_event_listener(input.text_input_id, .Focus, rawptr(input), browser_input_focus)
		_ = js.remove_event_listener(input.text_input_id, .Blur, rawptr(input), browser_input_element_blur)
		_ = js.remove_custom_event_listener(input.text_input_id, "input", rawptr(input), browser_input_text_input)
		_ = js.remove_custom_event_listener(input.text_input_id, "compositionstart", rawptr(input), browser_input_composition_start)
		_ = js.remove_custom_event_listener(input.text_input_id, "compositionend", rawptr(input), browser_input_composition_end)
	}
	if input.composition_active { browser_input_cancel_composition(input) }
	if input.attached && input.host != nil && (input.focused || input.pointer_active) {
		_ = alicorn.hosted_runtime_focus_changed(input.host, false)
	}
	input.attached = false
	input.focused = false
	input.pointer_active = false
}

browser_input_dom_id_is_safe :: proc(id: string) -> bool {
	if len(id) == 0 { return false }
	for ch in id {
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
		     (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') {
			return false
		}
	}
	return true
}

browser_input_text_owner :: proc(input: ^Browser_Input) -> (^alicorn.Runtime, alicorn.Node_ID, bool) {
	if input == nil || input.host == nil || input.text_input_id == "" { return nil, 0, false }
	rt, status := alicorn.hosted_runtime_borrow(input.host)
	if status != .Ok { return nil, 0, false }
	owner := alicorn.focused_node(rt)
	info, found := alicorn.node_info(rt, owner)
	if !found || !info.active || info.disabled { return rt, owner, false }
	return rt, owner, info.kind == .Text_Field || info.text_input_target
}

browser_input_focus_dom_target :: proc(input: ^Browser_Input, wants_text: bool) {
	if input == nil || input.text_input_id == "" { return }
	if input.dom_focus_known && input.dom_focus_is_text == wants_text { return }
	input.focus_transfer = true
	js.evaluate(browser_input_focus_script(input.canvas_id, input.text_input_id, wants_text))
	input.focus_transfer = false
	input.dom_focus_known = true
	input.dom_focus_is_text = wants_text
}

browser_input_string_hash :: proc(value: string) -> u64 {
	hash: u64 = 14695981039346656037
	for index in 0..<len(value) {
		hash = (hash ~ u64(value[index])) * 1099511628211
	}
	return hash
}

browser_input_text_value :: proc(input: ^Browser_Input) -> string {
	if input == nil || input.text_input_id == "" { return "" }
	utf16_length := js.get_element_value_string_length(input.text_input_id)
	if utf16_length <= 0 { return "" }
	// Odin's JS DOM helper returns a UTF-16 code-unit count, while TextEncoder
	// writes UTF-8. Three bytes per UTF-16 unit is sufficient for every scalar.
	buffer := make([]byte, utf16_length*3, context.temp_allocator)
	for &entry in buffer { entry = 0xFF }
	_ = js.get_element_value_string(input.text_input_id, buffer)
	byte_length := 0
	for byte_length < len(buffer) && buffer[byte_length] != 0xFF { byte_length += 1 }
	return string(buffer[:byte_length])
}

browser_input_clear_text_value :: proc(input: ^Browser_Input) {
	if input == nil || input.text_input_id == "" { return }
	js.set_element_value_string(input.text_input_id, "")
	js.set_element_key_f64(input.text_input_id, "selectionStart", 0)
	js.set_element_key_f64(input.text_input_id, "selectionEnd", 0)
}

browser_input_send_text :: proc(
	input: ^Browser_Input,
	kind: alicorn.Hosted_Text_Input_Kind,
	value: string = "",
	selection_start: int = 0,
	selection_end: int = 0,
) -> bool {
	if input == nil || input.host == nil { return false }
	status := alicorn.hosted_runtime_text_input(
		input.host,
		0,
		kind,
		value,
		selection_start,
		max(selection_end-selection_start, 0),
	)
	if status == .Ok { input.wake(input.wake_data); return true }
	return false
}

browser_input_cancel_composition :: proc(input: ^Browser_Input) {
	if input == nil || !input.composition_active { return }
	_ = browser_input_send_text(input, .Cancel)
	input.composition_active = false
	input.composition_cancel_on_end = false
	browser_input_clear_text_value(input)
}

browser_input_text_input :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil { return }
	value := browser_input_text_value(input)
	if event.is_composing || input.composition_active {
		start_utf16 := int(max(js.get_element_key_f64(input.text_input_id, "selectionStart"), 0))
		end_utf16 := int(max(js.get_element_key_f64(input.text_input_id, "selectionEnd"), 0))
		start_character := browser_utf16_offset_to_character_index(value, start_utf16)
		end_character := browser_utf16_offset_to_character_index(value, end_utf16, round_up=end_utf16 > start_utf16)
		_ = browser_input_send_text(input, .Preedit, value, start_character, end_character)
		return
	}
	if input.suppress_composition_echo {
		elapsed := event.timestamp - input.last_composition_timestamp
		matches := len(value) == input.last_composition_length && browser_input_string_hash(value) == input.last_composition_hash
		if elapsed >= 0 && elapsed <= 0.05 && matches {
			input.suppress_composition_echo = false
			browser_input_clear_text_value(input)
			return
		}
		input.suppress_composition_echo = false
	}
	if len(value) > 0 { _ = browser_input_send_text(input, .Commit, value) }
	browser_input_clear_text_value(input)
}

browser_input_composition_start :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil { return }
	if input.composition_active { browser_input_cancel_composition(input) }
	input.suppress_composition_echo = false
	input.composition_active = true
	input.composition_cancel_on_end = false
	browser_input_clear_text_value(input)
}

browser_input_composition_end :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil || !input.composition_active { return }
	value := browser_input_text_value(input)
	if input.composition_cancel_on_end || len(value) == 0 {
		_ = browser_input_send_text(input, .Cancel)
		input.suppress_composition_echo = false
	} else if browser_input_send_text(input, .Commit, value) {
		input.suppress_composition_echo = true
		input.last_composition_hash = browser_input_string_hash(value)
		input.last_composition_length = len(value)
		input.last_composition_timestamp = event.timestamp
	}
	input.composition_active = false
	input.composition_cancel_on_end = false
	browser_input_clear_text_value(input)
}

// browser_input_update_text_input_area places the transparent DOM text entry
// surface at the retained caret so browser IME candidate UI follows Alicorn's
// shaped text geometry. Call after the Hosted_Runtime step and layout update.
browser_input_update_text_input_area :: proc(input: ^Browser_Input) {
	rt, owner, text_target := browser_input_text_owner(input)
	if !text_target || rt == nil { return }
	area, ok := alicorn.text_input_area(rt, owner)
	if !ok { return }
	canvas := js.get_bounding_client_rect(input.canvas_id)
	left := canvas.x + f64(area.rect.x+area.cursor_x)
	top := canvas.y + f64(area.rect.y)
	height := max(f64(area.rect.h), 1)
	if input.proxy_geometry_valid && input.proxy_left == left && input.proxy_top == top && input.proxy_height == height { return }
	js.set_element_style(input.text_input_id, "left", fmt.tprintf("%.2fpx", left))
	js.set_element_style(input.text_input_id, "top", fmt.tprintf("%.2fpx", top))
	js.set_element_style(input.text_input_id, "height", fmt.tprintf("%.2fpx", height))
	input.proxy_left, input.proxy_top, input.proxy_height = left, top, height
	input.proxy_geometry_valid = true
}

browser_input_sync_focus_target :: proc(input: ^Browser_Input) {
	if input == nil || !input.focused || input.text_input_id == "" { return }
	_, _, wants_text := browser_input_text_owner(input)
	browser_input_focus_dom_target(input, wants_text)
}

browser_input_focus_lost :: proc(input: ^Browser_Input) {
	if input == nil || input.host == nil { return }
	if input.composition_active { browser_input_cancel_composition(input) }
	input.pointer_active = false
	input.active_pointer_id = 0
	input.dom_focus_known = false
	if input.focused {
		input.focused = false
		_ = alicorn.hosted_runtime_focus_changed(input.host, false)
	}
	input.wake(input.wake_data)
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
	if kind == .Down { browser_input_sync_focus_target(input) }
	input.wake(input.wake_data)
	return status == .Ok
}

browser_input_pointer_down :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil { return }
	if input.text_input_id != "" { js.event_prevent_default() }
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
	key_event := browser_input_key(event)
	if event.is_composing {
		if key_event.code == "Escape" && input.composition_active {
			input.composition_cancel_on_end = true
		}
		if rt, status := alicorn.hosted_runtime_borrow(input.host); status == .Ok {
			owner := alicorn.focused_node(rt)
			info, has_focus := alicorn.node_info(rt, owner)
			text_focused := has_focus && (info.kind == .Text_Field || info.text_input_target)
			composed := web_key_event(
				key_event, input.platform, text_focused, true, event.key.repeat,
			)
			if handled, key_status := alicorn.hosted_runtime_key_event(input.host, composed);
				key_status == .Ok && handled {
				js.event_prevent_default()
				browser_input_sync_focus_target(input)
				input.wake(input.wake_data)
			}
		}
		return
	}
	rt, status := alicorn.hosted_runtime_borrow(input.host)
	if status != .Ok { return }

	if key_event.code == "Tab" && !key_event.control {
		if alicorn.application_dispatch_overlay_key(rt, .Other, is_tab=true, reverse_tab=key_event.shift) {
			js.event_prevent_default()
			browser_input_sync_focus_target(input)
			input.wake(input.wake_data)
			return
		}
	} else if alicorn.application_dispatch_overlay_key(rt, browser_input_context_key(key_event.code)) {
		js.event_prevent_default()
		browser_input_sync_focus_target(input)
		input.wake(input.wake_data)
		return
	}

	owner := alicorn.focused_node(rt)
	info, has_focus := alicorn.node_info(rt, owner)
	text_input_focused := has_focus && (info.kind == .Text_Field || info.text_input_target)
	composition_active := event.is_composing || input.composition_active
	if has_focus && info.kind == .Text_Field {
		if interaction, ok := alicorn.text_field_interaction(rt, owner); ok {
			composition_active = composition_active || interaction.composition_active
		}
	}
	app_key, app_mapped := web_application_key(key_event, input.platform, menus_open=alicorn.context_menu_is_open(rt))
	// One canonical Key_Event path: the resolver runs before Application_Key
	// routing, and legacy scoped text preemption was already applied inside it
	// for keys the application maps. A miss falls through to text editing.
	app_event := web_key_event(
		key_event, input.platform, text_input_focused, composition_active, event.key.repeat,
	)
	if app_mapped {
		app_event.application_key = app_key
		app_event.has_application_key = true
	}
	if app_handled, key_status := alicorn.hosted_runtime_key_event(input.host, app_event);
		key_status == .Ok && app_handled {
		js.event_prevent_default()
		browser_input_sync_focus_target(input)
		input.wake(input.wake_data)
		return
	}
	if text_input_focused && !composition_active {
		text_key, mapped := web_text_navigation_key(key_event, input.platform)
		if mapped {
			result, text_status := alicorn.hosted_runtime_text_key(input.host, text_key, composition_active)
			if text_status == .Ok && result != .Unhandled {
				js.event_prevent_default()
				browser_input_sync_focus_target(input)
				input.wake(input.wake_data)
				return
			}
		}
	}

	if key_event.code == "Tab" && !key_event.control {
		if alicorn.application_dispatch_tab_focus(rt, key_event.shift) {
			js.event_prevent_default()
			browser_input_sync_focus_target(input)
			input.wake(input.wake_data)
		}
		return
	}

	key, mapped := app_key, app_mapped
	if !mapped || (text_input_focused && !alicorn.application_key_can_preempt_text_field(key, composition_active)) { return }
	if alicorn.application_route_focused_control_key(rt, key) {
		js.event_prevent_default()
		browser_input_sync_focus_target(input)
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
	// The proxy textarea's input event is the UTF-8-safe text path. Let the
	// browser update that control, then consume its value in browser_input_text_input.
	if input.text_input_id != "" && event.id == input.text_input_id { return }
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
	input.dom_focus_known = true
	input.dom_focus_is_text = input.text_input_id != "" && event.id == input.text_input_id
	if !input.focused {
		input.focused = true
		_ = alicorn.hosted_runtime_focus_changed(input.host, true, input.keyboard_modality)
	}
	input.wake(input.wake_data)
}

browser_input_element_blur :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.focus_transfer { return }
	browser_input_focus_lost(input)
}

browser_input_window_blur :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input != nil { input.keyboard_modality = false }
	browser_input_focus_lost(input)
}

browser_input_visibility :: proc(event: js.Event) {
	input := cast(^Browser_Input)event.user_data
	if input == nil || input.host == nil { return }
	visible := event.visibility_change.is_visible
	if input.on_visibility == nil {
		_ = alicorn.hosted_runtime_set_renderable(input.host, visible)
	}
	if !visible {
		browser_input_focus_lost(input)
	}
	if input.on_visibility != nil { input.on_visibility(input.visibility_data, visible) }
	if visible { input.wake(input.wake_data) }
}
