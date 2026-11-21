#+build !js

package sdl3_host

// The SDL3 event and input mapping helpers are WebGPU-agnostic and live in
// alicorn:host/sdl3/input so SDL_GPU-only consumers (native/sdl_gpu) can use
// them without importing this WebGPU host package. These aliases keep the
// WebGPU host's existing unqualified call sites readable.
import sdl3_input "alicorn:host/sdl3/input"

Pointer_Button_State :: sdl3_input.Pointer_Button_State
pointer_button_state_clear :: sdl3_input.pointer_button_state_clear
input_modifier_is_set :: sdl3_input.input_modifier_is_set
pointer_modifiers_from_sdl :: sdl3_input.pointer_modifiers_from_sdl
text_primary_modifier_from_sdl :: sdl3_input.text_primary_modifier_from_sdl
text_word_modifier_from_sdl :: sdl3_input.text_word_modifier_from_sdl
text_line_modifier_from_sdl :: sdl3_input.text_line_modifier_from_sdl
text_document_modifier_from_sdl :: sdl3_input.text_document_modifier_from_sdl
text_key_event_from_sdl :: sdl3_input.text_key_event_from_sdl
pointer_button_from_sdl :: sdl3_input.pointer_button_from_sdl
pointer_event_from_sdl :: sdl3_input.pointer_event_from_sdl
pointer_modifier_state_update :: sdl3_input.pointer_modifier_state_update
focused_control_key_from_sdl :: sdl3_input.focused_control_key_from_sdl
context_menu_key_from_sdl :: sdl3_input.context_menu_key_from_sdl
application_key_from_sdl :: sdl3_input.application_key_from_sdl
menu_modifiers_from_sdl :: sdl3_input.menu_modifiers_from_sdl
scroll_event_from_sdl :: sdl3_input.scroll_event_from_sdl
event_window_id_from_sdl :: sdl3_input.event_window_id_from_sdl
