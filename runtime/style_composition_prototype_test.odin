package alicorn

import "core:testing"

// This is a bounded, private #245 experiment, not a runtime API. It tests a
// setup-time compiler for one typed family against Alicorn's existing Button
// arguments and theme recipes. There are no selectors, string keys, or
// per-description registry lookups.
@(private)
Style_Button_Composition_Recipe_ID :: distinct u32

@(private)
Style_Button_Composition_Fragment_ID :: distinct u32

@(private)
Style_Button_Composition_Context_ID :: distinct u32

@(private)
STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS :: 64

@(private)
Style_Button_Composition_Field :: enum u8 {
	Height,
	Padding,
	Font_Size,
	Shape,
	Surface_Role,
	Text_Role,
	Surface_Visible,
	Selected_Indicator,
	Focus_Indicator_Mode,
	Count,
}

@(private)
Style_Button_Composition_Fields :: distinct bit_set[Style_Button_Composition_Field; u16]

@(private)
STYLE_BUTTON_COMPOSITION_FIELD_COUNT :: int(Style_Button_Composition_Field.Count)

@(private)
Style_Button_Composition_Values :: struct {
	height: f32,
	padding: f32,
	font_size: f32,
	shape: Surface_Shape,
	surface_role: Style_Color_Role,
	text_role: Style_Color_Role,
	surface_visible: bool,
	selected_indicator: Button_Indicator,
	focus_indicator_mode: Focus_Indicator_Mode,
}

@(private)
Style_Button_Composition_Patch :: struct {
	fields: Style_Button_Composition_Fields,
	values: Style_Button_Composition_Values,
}

@(private)
Style_Button_Composition_Recipe :: struct {
	id: Style_Button_Composition_Recipe_ID,
	parent: Style_Button_Composition_Recipe_ID,
	patch: Style_Button_Composition_Patch,
	fragments: []Style_Button_Composition_Fragment_ID,
}

@(private)
Style_Button_Composition_Fragment :: struct {
	id: Style_Button_Composition_Fragment_ID,
	patch: Style_Button_Composition_Patch,
}

@(private)
Style_Button_Composition_Context_Rule :: struct {
	recipe: Style_Button_Composition_Recipe_ID,
	fragment: Style_Button_Composition_Fragment_ID,
}

@(private)
Style_Button_Composition_Context :: struct {
	id: Style_Button_Composition_Context_ID,
	rules: []Style_Button_Composition_Context_Rule,
}

@(private)
Style_Button_Composition_Source_Kind :: enum u8 {
	Core_Default,
	Theme,
	Recipe,
	Fragment,
	Context,
	Instance,
}

@(private)
Style_Button_Composition_Source :: struct {
	kind: Style_Button_Composition_Source_Kind,
	theme: Style_Theme_ID,
	variant: Button_Variant,
	recipe: Style_Button_Composition_Recipe_ID,
	fragment: Style_Button_Composition_Fragment_ID,
	ctx: Style_Button_Composition_Context_ID,
}

@(private)
Style_Button_Composition_Failure :: enum u8 {
	None,
	Too_Many_Definitions,
	Zero_Recipe_ID,
	Duplicate_Recipe_ID,
	Missing_Parent,
	Recipe_Cycle,
	Zero_Fragment_ID,
	Duplicate_Fragment_ID,
	Missing_Fragment,
	Zero_Context_ID,
	Duplicate_Context_ID,
	Missing_Context_Recipe,
	Duplicate_Context_Rule,
	Invalid_Base_Variant,
	Missing_Recipe,
	Missing_Context,
}

@(private)
Style_Button_Composition_Resolved :: struct {
	layout: Layout_Style,
	text: Text_Style,
	recipe: Button_Recipe,
	provenance: [STYLE_BUTTON_COMPOSITION_FIELD_COUNT]Style_Button_Composition_Source,
	valid: bool,
	failure: Style_Button_Composition_Failure,
}

@(private)
style_button_composition_recipe_lookup :: proc(
	definitions: []Style_Button_Composition_Recipe,
	id: Style_Button_Composition_Recipe_ID,
) -> (Style_Button_Composition_Recipe, bool, bool) {
	result: Style_Button_Composition_Recipe
	found := false
	for definition in definitions {
		if definition.id != id { continue }
		if found { return {}, false, true }
		result = definition
		found = true
	}
	return result, found, false
}

@(private)
style_button_composition_fragment_lookup :: proc(
	definitions: []Style_Button_Composition_Fragment,
	id: Style_Button_Composition_Fragment_ID,
) -> (Style_Button_Composition_Fragment, bool, bool) {
	result: Style_Button_Composition_Fragment
	found := false
	for definition in definitions {
		if definition.id != id { continue }
		if found { return {}, false, true }
		result = definition
		found = true
	}
	return result, found, false
}

@(private)
style_button_composition_context_lookup :: proc(
	definitions: []Style_Button_Composition_Context,
	id: Style_Button_Composition_Context_ID,
) -> (Style_Button_Composition_Context, bool, bool) {
	result: Style_Button_Composition_Context
	found := false
	for definition in definitions {
		if definition.id != id { continue }
		if found { return {}, false, true }
		result = definition
		found = true
	}
	return result, found, false
}

@(private)
style_button_composition_catalog_validate :: proc(
	recipes: []Style_Button_Composition_Recipe,
	fragments: []Style_Button_Composition_Fragment,
	contexts: []Style_Button_Composition_Context,
) -> Style_Button_Composition_Failure {
	if len(recipes) > STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS ||
		len(fragments) > STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS ||
		len(contexts) > STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS {
		return .Too_Many_Definitions
	}
	for recipe, recipe_index in recipes {
		if recipe.id == 0 { return .Zero_Recipe_ID }
		for previous in recipes[:recipe_index] {
			if previous.id == recipe.id { return .Duplicate_Recipe_ID }
		}
		if len(recipe.fragments) > STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS {
			return .Too_Many_Definitions
		}
		for fragment_id in recipe.fragments {
			fragment, found, duplicate := style_button_composition_fragment_lookup(fragments, fragment_id)
			_ = fragment
			if duplicate { return .Duplicate_Fragment_ID }
			if !found { return .Missing_Fragment }
		}

		visited: [STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS]Style_Button_Composition_Recipe_ID
		visited_count := 1
		visited[0] = recipe.id
		parent_id := recipe.parent
		for parent_id != 0 {
			for previous in visited[:visited_count] {
				if previous == parent_id { return .Recipe_Cycle }
			}
			parent, found, duplicate := style_button_composition_recipe_lookup(recipes, parent_id)
			if duplicate { return .Duplicate_Recipe_ID }
			if !found { return .Missing_Parent }
			if visited_count >= STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS { return .Too_Many_Definitions }
			visited[visited_count] = parent_id
			visited_count += 1
			parent_id = parent.parent
		}
	}
	for fragment, fragment_index in fragments {
		if fragment.id == 0 { return .Zero_Fragment_ID }
		for previous in fragments[:fragment_index] {
			if previous.id == fragment.id { return .Duplicate_Fragment_ID }
		}
	}
	for ctx, context_index in contexts {
		if ctx.id == 0 { return .Zero_Context_ID }
		for previous in contexts[:context_index] {
			if previous.id == ctx.id { return .Duplicate_Context_ID }
		}
		if len(ctx.rules) > STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS {
			return .Too_Many_Definitions
		}
		for rule, rule_index in ctx.rules {
			_, recipe_found, recipe_duplicate := style_button_composition_recipe_lookup(recipes, rule.recipe)
			if recipe_duplicate { return .Duplicate_Recipe_ID }
			if !recipe_found { return .Missing_Context_Recipe }
			for previous in ctx.rules[:rule_index] {
				if previous.recipe == rule.recipe { return .Duplicate_Context_Rule }
			}
			_, fragment_found, fragment_duplicate := style_button_composition_fragment_lookup(fragments, rule.fragment)
			if fragment_duplicate { return .Duplicate_Fragment_ID }
			if !fragment_found { return .Missing_Fragment }
		}
	}
	return .None
}

@(private)
style_button_composition_apply_patch :: proc(
	result: ^Style_Button_Composition_Resolved,
	patch: Style_Button_Composition_Patch,
	source: Style_Button_Composition_Source,
) {
	for field in Style_Button_Composition_Field {
		if field == .Count || field not_in patch.fields { continue }
		switch field {
		case .Height: result.layout.height = patch.values.height
		case .Padding: result.layout.padding = patch.values.padding
		case .Font_Size: result.text.font_size = patch.values.font_size
		case .Shape: result.recipe.shape = patch.values.shape
		case .Surface_Role: result.recipe.surface_role = patch.values.surface_role
		case .Text_Role: result.recipe.text_role = patch.values.text_role
		case .Surface_Visible: result.recipe.surface_visible = patch.values.surface_visible
		case .Selected_Indicator: result.recipe.selected_indicator = patch.values.selected_indicator
		case .Focus_Indicator_Mode: result.recipe.focus_indicator_mode = patch.values.focus_indicator_mode
		case .Count: continue
		}
		result.provenance[int(field)] = source
	}
}

@(private)
style_button_composition_reject :: proc(
	result: Style_Button_Composition_Resolved,
	failure: Style_Button_Composition_Failure,
) -> Style_Button_Composition_Resolved {
	rejected := result
	rejected.valid = false
	rejected.failure = failure
	return rejected
}

@(private)
style_button_composition_resolve :: proc(
	theme: Style_Theme,
	theme_id: Style_Theme_ID,
	base_variant: Button_Variant,
	recipes: []Style_Button_Composition_Recipe,
	fragments: []Style_Button_Composition_Fragment,
	contexts: []Style_Button_Composition_Context,
	recipe_id: Style_Button_Composition_Recipe_ID,
	active_contexts: []Style_Button_Composition_Context_ID,
	instance: Style_Button_Composition_Patch = {},
) -> Style_Button_Composition_Resolved {
	result := Style_Button_Composition_Resolved{layout=DEFAULT_STYLE, text=DEFAULT_BUTTON_TEXT_STYLE}
	if failure := style_button_composition_catalog_validate(recipes, fragments, contexts); failure != .None {
		return style_button_composition_reject(result, failure)
	}
	if !style_button_variant_is_valid(base_variant) {
		return style_button_composition_reject(result, .Invalid_Base_Variant)
	}
	chain: [STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS]Style_Button_Composition_Recipe
	chain_count := 0
	current_id := recipe_id
	for current_id != 0 {
		if chain_count >= STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS {
			return style_button_composition_reject(result, .Too_Many_Definitions)
		}
		definition, found, duplicate := style_button_composition_recipe_lookup(recipes, current_id)
		if duplicate { return style_button_composition_reject(result, .Duplicate_Recipe_ID) }
		if !found { return style_button_composition_reject(result, .Missing_Recipe) }
		chain[chain_count] = definition
		chain_count += 1
		current_id = definition.parent
	}
	if chain_count == 0 { return style_button_composition_reject(result, .Missing_Recipe) }
	base_recipe := theme.button_recipes.recipes[int(base_variant)]
	if !base_recipe.defined {
		fallbacks := DEFAULT_BUTTON_RECIPES
		base_recipe = fallbacks.recipes[int(base_variant)]
	}
	result.recipe = base_recipe
	for field in Style_Button_Composition_Field {
		if field == .Count { continue }
		result.provenance[int(field)] = Style_Button_Composition_Source{
			kind=.Core_Default,
			recipe=recipe_id,
		}
	}
	paint_fields := [?]Style_Button_Composition_Field{
		.Shape, .Surface_Role, .Text_Role, .Surface_Visible, .Selected_Indicator, .Focus_Indicator_Mode,
	}
	for field in paint_fields {
		result.provenance[int(field)] = Style_Button_Composition_Source{
			kind=.Theme,
			theme=theme_id,
			variant=base_variant,
			recipe=recipe_id,
		}
	}

	// Recipes extend parents. The most distant parent is applied first; each
	// recipe's fragments apply in declaration order, then its direct patch.
	for depth := chain_count-1; depth >= 0; depth -= 1 {
		definition := chain[depth]
		for fragment_id in definition.fragments {
			fragment, found, duplicate := style_button_composition_fragment_lookup(fragments, fragment_id)
			if duplicate { return style_button_composition_reject(result, .Duplicate_Fragment_ID) }
			if !found { return style_button_composition_reject(result, .Missing_Fragment) }
			style_button_composition_apply_patch(&result, fragment.patch,
				Style_Button_Composition_Source{kind=.Fragment, recipe=definition.id, fragment=fragment.id})
		}
		style_button_composition_apply_patch(&result, definition.patch,
			Style_Button_Composition_Source{kind=.Recipe, recipe=definition.id})
	}

	if len(active_contexts) > STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS {
		return style_button_composition_reject(result, .Too_Many_Definitions)
	}
	seen_contexts: [STYLE_BUTTON_COMPOSITION_MAX_DEFINITIONS]Style_Button_Composition_Context_ID
	seen_count := 0
	for context_id in active_contexts {
		for seen in seen_contexts[:seen_count] {
			if seen == context_id { return style_button_composition_reject(result, .Duplicate_Context_ID) }
		}
		seen_contexts[seen_count] = context_id
		seen_count += 1
		ctx, found, duplicate := style_button_composition_context_lookup(contexts, context_id)
		if duplicate { return style_button_composition_reject(result, .Duplicate_Context_ID) }
		if !found { return style_button_composition_reject(result, .Missing_Context) }
		for rule in ctx.rules {
			if rule.recipe != recipe_id { continue }
			fragment, fragment_found, fragment_duplicate := style_button_composition_fragment_lookup(fragments, rule.fragment)
			if fragment_duplicate { return style_button_composition_reject(result, .Duplicate_Fragment_ID) }
			if !fragment_found { return style_button_composition_reject(result, .Missing_Fragment) }
			style_button_composition_apply_patch(&result, fragment.patch,
				Style_Button_Composition_Source{kind=.Context, recipe=recipe_id, fragment=fragment.id, ctx=ctx.id})
		}
	}
	style_button_composition_apply_patch(&result, instance,
		Style_Button_Composition_Source{kind=.Instance, recipe=recipe_id})
	result.valid = true
	return result
}

@(private)
style_button_composition_theme_prototype :: proc(
	base: Style_Theme,
	variant: Button_Variant,
	resolved: Style_Button_Composition_Resolved,
) -> (candidate: Style_Theme, ok: bool) {
	if !resolved.valid || !style_button_variant_is_valid(variant) { return {}, false }
	candidate = base
	candidate.button_recipes.recipes[int(variant)] = resolved.recipe
	return candidate, true
}

@(private)
style_button_composition_callsite_test :: proc(
	ui: ^UI,
	key: UI_Key,
	resolved: Style_Button_Composition_Resolved,
) {
	_ = button(ui, "Export", key=key, style=resolved.layout, text_style=resolved.text, variant=.Default)
}

@(test)
test_style_button_composition_prototype_precedence_and_provenance :: proc(t: ^testing.T) {
	control_fragment_ids := [?]Style_Button_Composition_Fragment_ID{Style_Button_Composition_Fragment_ID(1)}
	compact_fragment_ids := [?]Style_Button_Composition_Fragment_ID{Style_Button_Composition_Fragment_ID(2)}
	primary_fragment_ids := [?]Style_Button_Composition_Fragment_ID{Style_Button_Composition_Fragment_ID(3)}
	fragments := [?]Style_Button_Composition_Fragment{
		{
			id=Style_Button_Composition_Fragment_ID(1),
			patch=Style_Button_Composition_Patch{
				fields={.Height, .Padding, .Font_Size, .Shape, .Surface_Role, .Text_Role},
				values=Style_Button_Composition_Values{
					height=36, padding=8, font_size=14,
					shape=Surface_Shape{kind=.Rounded_Rectangle, corner_radius=6},
					surface_role=.Surface, text_role=.Text,
				},
			},
		},
		{
			id=Style_Button_Composition_Fragment_ID(2),
			patch=Style_Button_Composition_Patch{
				fields={.Height, .Padding, .Font_Size},
				values=Style_Button_Composition_Values{height=28, padding=4, font_size=12},
			},
		},
		{
			id=Style_Button_Composition_Fragment_ID(3),
			patch=Style_Button_Composition_Patch{
				fields={.Surface_Role, .Text_Role, .Surface_Visible},
				values=Style_Button_Composition_Values{
					surface_role=.Accent, text_role=.Accent_Text, surface_visible=true,
				},
			},
		},
		{
			id=Style_Button_Composition_Fragment_ID(4),
			patch=Style_Button_Composition_Patch{
				fields={.Height, .Padding, .Surface_Role},
				values=Style_Button_Composition_Values{height=26, padding=3, surface_role=.Border},
			},
		},
		{
			id=Style_Button_Composition_Fragment_ID(5),
			patch=Style_Button_Composition_Patch{
				fields={.Height, .Padding, .Surface_Role},
				values=Style_Button_Composition_Values{height=42, padding=10, surface_role=.Danger},
			},
		},
	}
	recipes := [?]Style_Button_Composition_Recipe{
		{id=Style_Button_Composition_Recipe_ID(1), fragments=control_fragment_ids[:]},
		{id=Style_Button_Composition_Recipe_ID(2), parent=Style_Button_Composition_Recipe_ID(1), fragments=compact_fragment_ids[:]},
		{
			id=Style_Button_Composition_Recipe_ID(3),
			parent=Style_Button_Composition_Recipe_ID(2),
			fragments=primary_fragment_ids[:],
			patch=Style_Button_Composition_Patch{
				fields={.Focus_Indicator_Mode},
				values=Style_Button_Composition_Values{focus_indicator_mode=.Keyboard_Only},
			},
		},
	}
	toolbar_rules := [?]Style_Button_Composition_Context_Rule{{
		recipe=Style_Button_Composition_Recipe_ID(3), fragment=Style_Button_Composition_Fragment_ID(4),
	}}
	dialog_rules := [?]Style_Button_Composition_Context_Rule{{
		recipe=Style_Button_Composition_Recipe_ID(3), fragment=Style_Button_Composition_Fragment_ID(5),
	}}
	contexts := [?]Style_Button_Composition_Context{
		{id=Style_Button_Composition_Context_ID(1), rules=toolbar_rules[:]},
		{id=Style_Button_Composition_Context_ID(2), rules=dialog_rules[:]},
	}
	toolbar_context := [?]Style_Button_Composition_Context_ID{Style_Button_Composition_Context_ID(1)}
	dialog_context := [?]Style_Button_Composition_Context_ID{Style_Button_Composition_Context_ID(2)}
	nested_contexts := [?]Style_Button_Composition_Context_ID{
		Style_Button_Composition_Context_ID(1), Style_Button_Composition_Context_ID(2),
	}
	base_theme := DEFAULT_STYLE_THEME
	base_theme_id := DEFAULT_STYLE_THEME_ID

	toolbar := style_button_composition_resolve(base_theme, base_theme_id, .Default, recipes[:], fragments[:], contexts[:],
		Style_Button_Composition_Recipe_ID(3), toolbar_context[:])
	dialog := style_button_composition_resolve(base_theme, base_theme_id, .Default, recipes[:], fragments[:], contexts[:],
		Style_Button_Composition_Recipe_ID(3), dialog_context[:])
	instance_patch := Style_Button_Composition_Patch{
		fields={.Surface_Role},
		values=Style_Button_Composition_Values{surface_role=.Focus},
	}
	toolbar_instance := style_button_composition_resolve(base_theme, base_theme_id, .Default, recipes[:], fragments[:], contexts[:],
		Style_Button_Composition_Recipe_ID(3), toolbar_context[:], instance_patch)
	nested := style_button_composition_resolve(base_theme, base_theme_id, .Default, recipes[:], fragments[:], contexts[:],
		Style_Button_Composition_Recipe_ID(3), nested_contexts[:])

	testing.expect(t, toolbar.valid && dialog.valid && toolbar_instance.valid,
		"typed definitions should compile into complete Button arguments")
	testing.expect(t, toolbar.layout.height == 26 && toolbar.layout.padding == 3 && toolbar.text.font_size == 12,
		"the toolbar context should override selected fields while inheriting compact typography")
	testing.expect(t, dialog.layout.height == 42 && dialog.layout.padding == 10 && dialog.text.font_size == 12,
		"the dialog context should resolve independently over the same recipe inheritance chain")
	testing.expect(t, toolbar.recipe.surface_role == .Border && dialog.recipe.surface_role == .Danger &&
		toolbar.recipe.text_role == .Accent_Text && toolbar.recipe.surface_visible,
		"later context values should override recipe fragments while omitted fields remain inherited")
	testing.expect(t, nested.recipe.surface_role == .Danger && nested.layout.height == 42 &&
		nested.provenance[int(Style_Button_Composition_Field.Surface_Role)].ctx == Style_Button_Composition_Context_ID(2),
		"explicit context order should resolve outer-to-inner, with the inner context winning")
	testing.expect(t, toolbar.provenance[int(Style_Button_Composition_Field.Height)].ctx == Style_Button_Composition_Context_ID(1),
		"height provenance should identify its context")
	testing.expect(t, toolbar.provenance[int(Style_Button_Composition_Field.Font_Size)].fragment == Style_Button_Composition_Fragment_ID(2),
		"font-size provenance should identify its fragment")
	testing.expect(t, toolbar.provenance[int(Style_Button_Composition_Field.Text_Role)].fragment == Style_Button_Composition_Fragment_ID(3),
		"text-role provenance should identify its fragment")
	testing.expect(t, toolbar.provenance[int(Style_Button_Composition_Field.Focus_Indicator_Mode)].kind == .Recipe,
		"direct recipe provenance should identify its recipe")
	testing.expect(t, toolbar.provenance[int(Style_Button_Composition_Field.Selected_Indicator)].theme == base_theme_id &&
		toolbar.provenance[int(Style_Button_Composition_Field.Selected_Indicator)].variant == .Default,
		"theme provenance should identify its theme and variant")
	testing.expect(t, toolbar_instance.recipe.surface_role == .Focus &&
		toolbar_instance.provenance[int(Style_Button_Composition_Field.Surface_Role)].kind == .Instance,
		"explicit per-instance values should have the highest precedence and retain their source")
	if candidate, ok := style_button_composition_theme_prototype(base_theme, .Default, dialog); ok {
		testing.expect(t, candidate.button_recipes.recipes[int(Button_Variant.Default)] == dialog.recipe,
			"the resolved typed paint recipe should adapt to Alicorn's existing theme contract")
	} else {
		testing.expect(t, false, "a valid composition should materialize through the current Style_Theme contract")
	}

	cyclic_recipes := [?]Style_Button_Composition_Recipe{
		{id=Style_Button_Composition_Recipe_ID(10), parent=Style_Button_Composition_Recipe_ID(11)},
		{id=Style_Button_Composition_Recipe_ID(11), parent=Style_Button_Composition_Recipe_ID(10)},
	}
	testing.expect(t, style_button_composition_catalog_validate(cyclic_recipes[:], fragments[:], contexts[:]) == .Recipe_Cycle,
		"recipe inheritance cycles should be rejected during setup")
	duplicate_recipes := [?]Style_Button_Composition_Recipe{
		{id=Style_Button_Composition_Recipe_ID(20)},
		{id=Style_Button_Composition_Recipe_ID(20)},
	}
	testing.expect(t, style_button_composition_catalog_validate(duplicate_recipes[:], fragments[:], contexts[:]) == .Duplicate_Recipe_ID,
		"identity collisions should be rejected before a composed style can be used")
	duplicate_rule := [?]Style_Button_Composition_Context_Rule{
		{recipe=Style_Button_Composition_Recipe_ID(3), fragment=Style_Button_Composition_Fragment_ID(4)},
		{recipe=Style_Button_Composition_Recipe_ID(3), fragment=Style_Button_Composition_Fragment_ID(5)},
	}
	invalid_contexts := [?]Style_Button_Composition_Context{{
		id=Style_Button_Composition_Context_ID(3), rules=duplicate_rule[:],
	}}
	testing.expect(t, style_button_composition_catalog_validate(recipes[:], fragments[:], invalid_contexts[:]) == .Duplicate_Context_Rule,
		"a context must have one deterministic rule for a typed recipe")

	// Materialize the two resolved contexts through today's public theme and
	// environment mechanisms, then call the same Button helper for both. This
	// verifies the prototype reaches actual retained paint and geometry while
	// keeping Alicorn's Button owner and semantics intact.
	toolbar_theme, toolbar_theme_ok := style_button_composition_theme_prototype(base_theme, .Default, toolbar)
	dialog_theme, dialog_theme_ok := style_button_composition_theme_prototype(base_theme, .Default, dialog)
	rt := new_runtime(Rect{0, 0, 360, 140})
	defer destroy_runtime(&rt)
	toolbar_theme_id := style_theme_register(&rt, toolbar_theme)
	dialog_theme_id := style_theme_register(&rt, dialog_theme)
	testing.expect(t, toolbar_theme_ok && dialog_theme_ok && toolbar_theme_id != 0 && dialog_theme_id != 0,
		"context-specific theme adapters should register once during setup")
	ui, should_build := begin_frame(&rt)
	if should_build {
		root_style := DEFAULT_STYLE
		root_style.width = 360
		root_style.height = 140
		_ = container_begin(&ui, .Root, key=key_string("composition-prototype-root"), style=root_style)
		context_container_style := DEFAULT_STYLE
		context_container_style.width = 340
		context_container_style.height = 56
		_ = container_begin(&ui, .Container, key=key_string("composition-prototype-toolbar"), style=context_container_style)
		toolbar_scope := style_environment_push(&ui, Style_Environment{theme=toolbar_theme_id})
		style_button_composition_callsite_test(&ui, key_string("composition-prototype-toolbar-button"), toolbar)
		style_environment_pop(&ui, toolbar_scope)
		container_end(&ui)
		_ = container_begin(&ui, .Container, key=key_string("composition-prototype-dialog"), style=context_container_style)
		dialog_scope := style_environment_push(&ui, Style_Environment{theme=dialog_theme_id})
		style_button_composition_callsite_test(&ui, key_string("composition-prototype-dialog-button"), dialog)
		style_environment_pop(&ui, dialog_scope)
		container_end(&ui)
		container_end(&ui)
		end_frame(&ui)
		toolbar_button_id, toolbar_found := node_by_key(&rt, key_string("composition-prototype-toolbar-button"), .Button)
		dialog_button_id, dialog_found := node_by_key(&rt, key_string("composition-prototype-dialog-button"), .Button)
		toolbar_node := rt.nodes[toolbar_button_id]
		dialog_node := rt.nodes[dialog_button_id]
		if toolbar_found && dialog_found {
			toolbar_paint := style_button_resolve_retained(&rt, toolbar_node, Button_Visual_State{})
			dialog_paint := style_button_resolve_retained(&rt, dialog_node, Button_Visual_State{})
			testing.expect(t, toolbar_node.bounds.h == 26 && dialog_node.bounds.h == 42 &&
				toolbar_node.text_style.font_size == 12 && dialog_node.text_style.font_size == 12,
				"resolved context metrics and typography should feed the current Button arguments")
			testing.expect(t, toolbar_paint.surface != dialog_paint.surface &&
				toolbar_node.label == dialog_node.label && toolbar_node.kind == .Button && dialog_node.kind == .Button,
				"the same Button callsite should keep its semantics while context themes change its appearance")
		} else {
			testing.expect(t, false, "both context-specific Buttons should be retained by the shared callsite")
		}
	} else {
		testing.expect(t, false, "the composition prototype should build its retained Button comparison")
	}
}
