#+build !js

package sdl3_host

import alicorn "alicorn:runtime"
import "core:c"
import "vendor:sdl3"

@(private)
sdl3_webgpu_application_text_owner :: proc(application: ^SDL3_WebGPU_Application) -> alicorn.Node_ID {
	if application == nil || !application.text_input.window_focused { return 0 }
	rt, status := alicorn.hosted_runtime_borrow(&application.hosted)
	if status != .Ok { return 0 }
	owner := alicorn.focused_node(rt)
	info, found := alicorn.node_info(rt, owner)
	if !found || !info.active || !info.focusable || info.disabled ||
		alicorn.text_input_target_is_suspended(rt, owner) {
		return 0
	}
	if info.kind == .Text_Field || info.text_input_target || alicorn.select_wants_text_input(rt) {
		return owner
	}
	return 0
}

@(private)
sdl3_webgpu_application_sync_text_input :: proc(application: ^SDL3_WebGPU_Application) -> bool {
	if application == nil || !application.initialized || application.window == nil { return false }
	state := &application.text_input
	desired := sdl3_webgpu_application_text_owner(application)
	if desired != state.owner {
		if state.composition_owner != 0 {
			_ = alicorn.hosted_runtime_text_input(
				&application.hosted,
				state.composition_owner,
				.Cancel,
			)
			state.composition_owner = 0
		}
		if state.active {
			if !sdl3.ClearComposition(application.window) || !sdl3.StopTextInput(application.window) {
				return false
			}
			state.active = false
		}
		state.owner = 0
		state.last_area_valid = false
		if desired != 0 {
			if !sdl3.StartTextInput(application.window) { return false }
			state.active = true
			state.owner = desired
		}
	}
	if !state.active || state.owner == 0 { return true }
	rt, status := alicorn.hosted_runtime_borrow(&application.hosted)
	if status != .Ok { return false }
	area, valid := alicorn.text_input_area(rt, state.owner)
	if !valid {
		if state.last_area_valid && !sdl3.SetTextInputArea(application.window, nil, 0) { return false }
		state.last_area_valid = false
		state.last_area = {}
		return true
	}
	if state.last_area_valid && state.last_area == area { return true }
	width := max(1, int(area.rect.w))
	height := max(1, int(area.rect.h))
	rect := sdl3.Rect{
		x=c.int(area.rect.x),
		y=c.int(area.rect.y),
		w=c.int(width),
		h=c.int(height),
	}
	if !sdl3.SetTextInputArea(application.window, &rect, c.int(area.cursor_x)) { return false }
	state.last_area = area
	state.last_area_valid = true
	return true
}

@(private)
sdl3_webgpu_application_text_composition_active :: proc(
	application: ^SDL3_WebGPU_Application,
	owner: alicorn.Node_ID,
) -> bool {
	if application == nil || owner == 0 { return false }
	if application.text_input.composition_owner == owner { return true }
	rt, status := alicorn.hosted_runtime_borrow(&application.hosted)
	if status != .Ok { return false }
	field, ok := alicorn.text_field_interaction(rt, owner)
	return ok && field.composition_active
}

@(private)
sdl3_webgpu_application_cancel_composition :: proc(
	application: ^SDL3_WebGPU_Application,
	owner: alicorn.Node_ID,
) -> bool {
	if application == nil || owner == 0 { return false }
	status := alicorn.hosted_runtime_text_input(&application.hosted, owner, .Cancel)
	if status != .Ok { return false }
	application.text_input.composition_owner = 0
	return sdl3.ClearComposition(application.window)
}

@(private)
sdl3_webgpu_application_key_down :: proc(
	application: ^SDL3_WebGPU_Application,
	event: sdl3.KeyboardEvent,
) -> SDL3_WebGPU_Application_Event_Result {
	if application == nil || !application.initialized { return .Failure }
	rt, status := alicorn.hosted_runtime_borrow(&application.hosted)
	if status != .Ok { return .Failure }
	owner := alicorn.focused_node(rt)
	text_focused := sdl3_webgpu_application_text_owner(application) == owner && owner != 0
	composition_active := sdl3_webgpu_application_text_composition_active(application, owner)
	if event.key == sdl3.K_ESCAPE && composition_active {
		if !sdl3_webgpu_application_cancel_composition(application, owner) { return .Failure }
		return .Handled
	}

	overlay_handled := alicorn.application_dispatch_overlay_key(
		rt,
		context_menu_key_from_sdl(event.key),
		is_tab=event.key == sdl3.K_TAB,
		reverse_tab=input_modifier_is_set(event.mod, sdl3.KMOD_SHIFT),
	)
	if overlay_handled {
		if !sdl3_webgpu_application_sync_text_input(application) { return .Failure }
		return .Handled
	}

	// Control+Tab is application navigation and remains consumed when an app
	// chooses not to bind document cycling.
	control_tab := event.key == sdl3.K_TAB && input_modifier_is_set(event.mod, sdl3.KMOD_CTRL)
	if control_tab {
		key, mapped := application_key_from_sdl(event.key, event.mod, text_focused)
		if mapped {
			_, key_status := alicorn.hosted_runtime_key(&application.hosted, alicorn.Hosted_Key_Event{
				key_code=u32(key), pressed=true, repeat=event.repeat,
				modifiers=pointer_modifiers_from_sdl(event.mod),
				text_input_focused=text_focused,
				composition_active=composition_active,
			})
			if key_status != .Ok { return .Failure }
		}
		return .Handled
	}

	if key, mapped := application_key_from_sdl(event.key, event.mod, text_focused); mapped &&
		(!text_focused || alicorn.application_key_can_preempt_text_field(key, composition_active)) {
		key_handled, key_status := alicorn.hosted_runtime_key(&application.hosted, alicorn.Hosted_Key_Event{
			key_code=u32(key), pressed=true, repeat=event.repeat,
			modifiers=pointer_modifiers_from_sdl(event.mod),
			text_input_focused=text_focused,
			composition_active=composition_active,
		})
		if key_status != .Ok { return .Failure }
		if !sdl3_webgpu_application_sync_text_input(application) { return .Failure }
		if key_handled { return .Handled }
	}

	if text_focused && !composition_active {
		if text_primary_modifier_from_sdl(event.mod) && event.key == sdl3.K_A {
			if field_text, ok := alicorn.text_field_value(rt, owner); ok {
				if !alicorn.set_text_selection(rt, owner, 0, len(field_text)) { return .Failure }
				return .Handled
			}
		}
		if text_event, mapped := text_key_event_from_sdl(event.key, event.mod); mapped {
			result, key_status := alicorn.hosted_runtime_text_key(
				&application.hosted,
				text_event,
				composition_active,
			)
			if key_status != .Ok { return .Failure }
			if result != .Unhandled {
				if !sdl3_webgpu_application_sync_text_input(application) { return .Failure }
				return .Handled
			}
		}
	}

	if event.key == sdl3.K_TAB {
		direction := alicorn.Focus_Direction.Next
		if input_modifier_is_set(event.mod, sdl3.KMOD_SHIFT) { direction = .Previous }
		focused, focus_status := alicorn.hosted_runtime_focus_traverse(&application.hosted, direction)
		if focus_status != .Ok { return .Failure }
		if focused != 0 {
			if !sdl3_webgpu_application_sync_text_input(application) { return .Failure }
			return .Handled
		}
	}

	if key, mapped := focused_control_key_from_sdl(event.key); mapped {
		handled := alicorn.application_route_focused_control_key(rt, key)
		if handled { return .Handled }
	}
	if event.key == sdl3.K_RETURN || event.key == sdl3.K_KP_ENTER {
		if event.repeat || input_modifier_is_set(event.mod, sdl3.KMOD_SHIFT|sdl3.KMOD_CTRL|sdl3.KMOD_ALT|sdl3.KMOD_GUI) || composition_active {
			return .Ignored
		}
		if owner != 0 {
			if info, ok := alicorn.node_info(rt, owner); ok && info.kind == .Text_Field &&
				alicorn.text_field_request_submit(rt, owner) {
				return .Handled
			}
		}
	}
	if !sdl3_webgpu_application_sync_text_input(application) { return .Failure }
	return .Ignored
}

@(private)
sdl3_webgpu_application_text_input :: proc(
	application: ^SDL3_WebGPU_Application,
	event: sdl3.TextInputEvent,
) -> SDL3_WebGPU_Application_Event_Result {
	if event.text == nil || !application.text_input.active || application.text_input.owner == 0 { return .Ignored }
	text := string(event.text)
	rt, status := alicorn.hosted_runtime_borrow(&application.hosted)
	if status != .Ok { return .Failure }
	if alicorn.select_wants_text_input(rt) && alicorn.select_typeahead(rt, text) {
		application.text_input.composition_owner = 0
		return .Handled
	}
	input_status := alicorn.hosted_runtime_text_input(
		&application.hosted,
		application.text_input.owner,
		.Commit,
		text,
	)
	if input_status != .Ok { return .Ignored }
	application.text_input.composition_owner = 0
	if !sdl3_webgpu_application_sync_text_input(application) { return .Failure }
	return .Handled
}

@(private)
sdl3_webgpu_application_text_editing :: proc(
	application: ^SDL3_WebGPU_Application,
	event: sdl3.TextEditingEvent,
) -> SDL3_WebGPU_Application_Event_Result {
	if !application.text_input.active || application.text_input.owner == 0 { return .Ignored }
	text := ""
	if event.text != nil { text = string(event.text) }
	kind := alicorn.Hosted_Text_Input_Kind.Preedit
	if len(text) == 0 { kind = .Cancel }
	selection_start := max(0, int(event.start))
	selection_length := max(0, int(event.length))
	input_status := alicorn.hosted_runtime_text_input(
		&application.hosted,
		application.text_input.owner,
		kind,
		text,
		selection_start,
		selection_length,
	)
	if input_status != .Ok { return .Ignored }
	if kind == .Preedit { application.text_input.composition_owner = application.text_input.owner }
	else { application.text_input.composition_owner = 0 }
	if !sdl3_webgpu_application_sync_text_input(application) { return .Failure }
	return .Handled
}
