#+build !js

package web_host

import "core:encoding/json"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_browser_accessibility_payload_preserves_semantics_and_stable_ids :: proc(t: ^testing.T) {
	button_id := alicorn.Semantic_ID{namespace=0x42524F5753455201, value=1}
	field_id := alicorn.Semantic_ID{namespace=0x42524F5753455201, value=2}
	run_id := alicorn.Semantic_ID{namespace=0x42524F5753455202, value=1}
	snapshot := alicorn.Semantic_Snapshot{
		revision=19,
		keyboard_focus=field_id,
		nodes=make([dynamic]alicorn.Semantic_Node, 0, 3),
	}
	defer delete(snapshot.nodes)
	button_actions := alicorn.semantic_actions_add({}, .Press)
	button_actions = alicorn.semantic_actions_add(button_actions, .Focus)
	button_states := alicorn.semantic_states_add({}, .Disabled)
	append(&snapshot.nodes, alicorn.Semantic_Node{
		id=button_id,
		role=.Button,
		label="Search \"current\"",
		description="Run the current query",
		states=button_states,
		actions=button_actions,
		tree_order=1,
	})
	field_actions := alicorn.semantic_actions_add({}, .Focus)
	field_actions = alicorn.semantic_actions_add(field_actions, .Set_Value)
	field_actions = alicorn.semantic_actions_add(field_actions, .Set_Text_Selection)
	append(&snapshot.nodes, alicorn.Semantic_Node{
		id=field_id,
		role=.Text_Field,
		label="Query",
		value="café",
		actions=field_actions,
		is_collection=false,
		tree_order=2,
	})
	append(&snapshot.nodes, alicorn.Semantic_Node{
		id=run_id,
		role=.Text_Run,
		parent=field_id,
		value="café",
		text_run_character_lengths=[]u8{1, 1, 2, 1},
		tree_order=3,
	})

	payload, status := browser_accessibility_payload_build(snapshot, "a11y-root")
	defer delete(payload.nodes)
	if !testing.expect(t, status == .Success && payload.revision == 19 && len(payload.nodes) == 2,
	                   "the browser projection is bounded to exposed semantic controls") { return }
	button_view := payload.nodes[0]
	field_view := payload.nodes[1]
	testing.expect(t,
		button_view.id == browser_accessibility_semantic_dom_id("a11y-root", button_id) &&
		button_view.role == "button" && button_view.disabled && button_view.can_press &&
		field_view.role == "textbox" && !field_view.multiline && field_view.can_set_text_selection,
		"role, disabled state, edit actions, and stable namespaced IDs should survive projection")
	testing.expect(t, payload.focus == field_view.id,
		"semantic keyboard focus should map to the stable DOM identity")
	encoded, json_status := browser_accessibility_payload_json(payload)
	defer delete(encoded)
	json_text := string(encoded)
	testing.expect(t, json_status == .Success &&
		strings.contains(json_text, `"canSetTextSelection":true`) &&
		strings.contains(json_text, `"label":"Search \"current\""`) &&
		strings.contains(json_text, `"value":"café"`),
		"JSON output must safely preserve user text and action/state fields")
}

@(test)
test_browser_accessibility_projection_rejects_invalid_and_oversized_roots :: proc(t: ^testing.T) {
	invalid, invalid_status := browser_accessibility_payload_build({}, "unsafe root")
	_ = invalid
	testing.expect(t, invalid_status == .Invalid_Root_ID,
		"DOM IDs must be safe before embedding them into browser integration calls")

	snapshot := alicorn.Semantic_Snapshot{
		nodes=make([dynamic]alicorn.Semantic_Node, BROWSER_ACCESSIBILITY_MAX_NODES+1),
	}
	defer delete(snapshot.nodes)
	for i in 0..<len(snapshot.nodes) {
		snapshot.nodes[i] = alicorn.Semantic_Node{
			id=alicorn.Semantic_ID{namespace=0x42524F5753455201, value=u64(i+1)},
			role=.Static_Text,
		}
	}
	too_many, status := browser_accessibility_payload_build(snapshot, "a11y-root")
	_ = too_many
	testing.expect(t, status == .Too_Many_Nodes,
		"a semantic tree above the DOM bound must fail closed rather than materialize unbounded controls")
}

@(test)
test_browser_accessibility_projection_caps_text_payload :: proc(t: ^testing.T) {
	large_value := strings.repeat("x", BROWSER_ACCESSIBILITY_MAX_TEXT_BYTES+1)
	defer delete(large_value)
	snapshot := alicorn.Semantic_Snapshot{
		nodes=make([dynamic]alicorn.Semantic_Node, 1),
	}
	defer delete(snapshot.nodes)
	snapshot.nodes[0] = alicorn.Semantic_Node{
		id=alicorn.Semantic_ID{namespace=0x42524F5753455201, value=1},
		role=.Static_Text,
		value=string(large_value),
	}
	payload, status := browser_accessibility_payload_build(snapshot, "a11y-root")
	_ = payload
	testing.expect(t, status == .Too_Much_Text,
		"a semantic snapshot with oversized text must fail closed before JSON serialization")
}

@(test)
test_browser_accessibility_replacement_diff_keeps_utf8_boundaries :: proc(t: ^testing.T) {
	testing.expect(t, browser_accessibility_text_difference("read cat", "read dog") == "dog",
		"replacement text should isolate the changed portion")
	testing.expect(t, browser_accessibility_text_difference("draft", "draft now") == " now",
		"insertions at the end should retain their leading space")
	testing.expect(t, browser_accessibility_text_difference("café", "cafe") == "e",
		"common multibyte characters should remain outside the replacement")
	testing.expect(t, browser_accessibility_text_difference("x🌍a", "x🙂a") == "🙂",
		"supplementary Unicode characters must remain whole UTF-8 units")
	testing.expect(t, browser_accessibility_text_difference("remove 🌍", "remove ") == "",
		"deletions should produce an empty inserted value")
}

@(test)
test_browser_accessibility_selection_maps_utf16_to_grapheme_boundaries :: proc(t: ^testing.T) {
	run := alicorn.Semantic_Node{
		role=.Text_Run,
		value="Aé🌍",
		text_run_character_lengths=[]u8{1, 2, 4},
	}
	middle, middle_ok := browser_accessibility_run_unit_index(run, 2, round_up=false)
	inside_astral_down, down_ok := browser_accessibility_run_unit_index(run, 3, round_up=false)
	inside_astral_up, up_ok := browser_accessibility_run_unit_index(run, 3, round_up=true)
	end, end_ok := browser_accessibility_run_unit_index(run, 4, round_up=false)
	testing.expect(t, browser_accessibility_run_utf16_length(run) == 4 &&
		middle_ok && middle == 2 && down_ok && inside_astral_down == 2 &&
		up_ok && inside_astral_up == 3 && end_ok && end == 3,
		"UTF-16 offsets should map to selectable grapheme boundaries and never split an astral scalar")
	malformed := alicorn.Semantic_Node{role=.Text_Run, value="é", text_run_character_lengths=[]u8{1}}
	_, malformed_ok := browser_accessibility_run_unit_index(malformed, 1, round_up=false)
	testing.expect(t, browser_accessibility_run_utf16_length(malformed) == -1 && !malformed_ok,
		"inconsistent run byte lengths must be rejected")
}

@(test)
test_browser_accessibility_role_mapping_covers_runtime_roles :: proc(t: ^testing.T) {
	testing.expect(t,
		browser_accessibility_role_name(.Button) == "button" &&
		browser_accessibility_role_name(.Text_Area) == "textbox" &&
		browser_accessibility_role_name(.Tree_Item) == "treeitem" &&
		browser_accessibility_role_name(.List_Box_Option) == "option" &&
		browser_accessibility_role_name(.Alert) == "alert",
		"runtime semantic roles should map to browser ARIA roles")
}

@(test)
test_browser_accessibility_payload_json_is_strict_json :: proc(t: ^testing.T) {
	payload := Browser_Accessibility_Payload{root="a11y", revision=3}
	data, status := browser_accessibility_payload_json(payload)
	defer delete(data)
	value, parse_error := json.parse(string(data))
	defer json.destroy_value(value)
	testing.expect(t, status == .Success && parse_error == nil,
		"serialized accessibility payload must parse as strict JSON")
}
