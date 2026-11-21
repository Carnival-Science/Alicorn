package select_parts

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_select_parts_prefix_match_is_case_insensitive_and_unicode_aware :: proc(t: ^testing.T) {
	testing.expect(t, select_parts_text_has_prefix("Charlie", "c"), "lowercase prefixes should match uppercase labels")
	testing.expect(t, select_parts_text_has_prefix("Éclair", "é"), "unicode case folding should match accented prefixes")
	testing.expect(t, !select_parts_text_has_prefix("Alpha", "be"), "non-prefix text should not match")
	testing.expect(t, !select_parts_text_has_prefix("Alpha", ""), "an empty prefix should not match")
}

@(test)
test_select_parts_group_validation_rejects_duplicate_and_malformed_options :: proc(t: ^testing.T) {
	valid := [2]Select_Parts_Group{
		{label="First", options=[]Select_Parts_Option{{key=1, label="Alpha"}, {key=2, label="Beta"}}},
		{label="Second", options=[]Select_Parts_Option{{key=3, label="Charlie"}}},
	}
	testing.expect(t, select_parts_groups_valid(valid[:]), "unique stable keys and bounded labels should validate")
	duplicate := [1]Select_Parts_Group{{options=[]Select_Parts_Option{{key=1, label="Alpha"}, {key=1, label="Again"}}}}
	testing.expect(t, !select_parts_groups_valid(duplicate[:]), "duplicate stable keys should be rejected")
	empty_label := [1]Select_Parts_Group{{options=[]Select_Parts_Option{{key=1, label=""}}}}
	testing.expect(t, !select_parts_groups_valid(empty_label[:]), "empty option labels should be rejected")
	zero_key := [1]Select_Parts_Group{{options=[]Select_Parts_Option{{key=0, label="Zero"}}}}
	testing.expect(t, !select_parts_groups_valid(zero_key[:]), "zero stable keys should be rejected")
}

@(test)
test_select_parts_semantic_identity_is_stable_per_instance_and_key :: proc(t: ^testing.T) {
	trigger_a := select_parts_trigger_id(11)
	trigger_b := select_parts_trigger_id(22)
	list_a := select_parts_list_id(11)
	option_a := select_parts_option_id(11, 7)
	option_b := select_parts_option_id(22, 7)
	testing.expect(t, trigger_a == select_parts_trigger_id(11), "one instance should retain a stable trigger ID")
	testing.expect(t, trigger_a != trigger_b && list_a != trigger_a, "instances should not share trigger/list identities")
	testing.expect(t, option_a == select_parts_option_id(11, 7), "one key should retain a stable option ID")
	testing.expect(t, option_a != option_b, "the same key in two owner instances should have distinct identities")
	testing.expect(t, select_parts_option_id(11, 0) == alicorn.Semantic_ID{}, "zero option keys should produce no identity")
}

@(test)
test_select_parts_recent_extension_is_bounded_and_moves_reused_keys_to_front :: proc(t: ^testing.T) {
	state := Select_Parts_State{}
	_ = select_parts_note_recent(&state, 10)
	_ = select_parts_note_recent(&state, 20)
	_ = select_parts_note_recent(&state, 30)
	keys := select_parts_recent_keys(&state)
	testing.expect(t, len(keys) == 3 && keys[0] == 30 && keys[1] == 20 && keys[2] == 10,
		"recent keys should be most-recent first")
	_ = select_parts_note_recent(&state, 10)
	keys = select_parts_recent_keys(&state)
	testing.expect(t, len(keys) == 3 && keys[0] == 10 && keys[1] == 30 && keys[2] == 20,
		"reusing a key should move it to the front without duplicating it")
	for key in u64(1)..=u64(RECENT_CAPACITY+3) { _ = select_parts_note_recent(&state, key) }
	testing.expect(t, len(select_parts_recent_keys(&state)) == RECENT_CAPACITY,
		"the extension buffer should stay bounded")
	select_parts_clear_recent(&state)
	testing.expect(t, len(select_parts_recent_keys(&state)) == 0, "clearing recents should empty the extension buffer")
}

@(test)
test_select_parts_recipe_and_theme_contract_are_explicit :: proc(t: ^testing.T) {
	compact := recipe_default(.Compact)
	rich := recipe_default(.Rich)
	testing.expect(t, select_parts_recipe_valid(compact) && select_parts_recipe_valid(rich),
		"both shipped appearances should declare the complete recipe")
	contract := theme_contract_default(compact)
	testing.expect(t, contract.required[0].role == compact.trigger_role && contract.optional[0].role == compact.badge_role,
		"the theme contract should name every required role and the optional badge role")
	invalid := compact
	invalid.focus_role = 0
	testing.expect(t, !select_parts_recipe_valid(invalid), "a missing required theme role should invalidate the recipe")
}
