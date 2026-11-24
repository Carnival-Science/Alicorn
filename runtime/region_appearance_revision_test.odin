package alicorn

import "core:testing"

Region_Appearance_Test_App :: struct {
	theme: Style_Theme_ID,
	content_revision: u64,
	accessibility_override: Accessibility_Appearance_Preferences,
	accessibility_override_set: bool,
	region: Node_ID,
	text: Node_ID,
	secondary_region: Node_ID,
	secondary_text: Node_ID,
	body_runs: int,
	secondary_body_runs: int,
	region_reused: bool,
	secondary_region_reused: bool,
	appearance_revision: Style_Appearance_Revision,
}

region_appearance_test_theme :: proc(text: Color) -> Style_Theme {
	theme := DEFAULT_STYLE_THEME
	theme.colors[int(Style_Color_Role.Text)] = text
	return theme
}

region_appearance_test_render :: proc(rt: ^Runtime, app: ^Region_Appearance_Test_App) -> u64 {
	ui, build := begin_frame(rt)
	if !build { return 0 }
	container_begin(&ui, .Root, key=key_string("appearance-revision-root"),
		style=layout_style(.Column, width=320, height=120))
	scope := style_environment_push(&ui, Style_Environment{
		theme=app.theme,
		accessibility=app.accessibility_override,
		accessibility_set=app.accessibility_override_set,
	})
	app.appearance_revision = style_appearance_revision(rt)
	region, reused := region_begin(&ui, "appearance-revision-region", app.content_revision)
	app.region = region
	app.region_reused = reused
	if region != 0 && !reused {
		app.body_runs += 1
		// Deliberately resolve ink in application code. This is the value that a
		// cached region cannot repair through Alicorn's retained theme-bound text
		// color provenance unless the region body runs again.
		app.text = text(&ui, "resolved appearance", key=key_string("appearance-revision-text"),
			style=layout_style(.Row, width=280, height=28), color=style_color(&ui, .Text))
		region_end(&ui, region, false, 0)
	} else if retained_text, found := node_by_key(rt, key_string("appearance-revision-text"), .Text); found {
		app.text = retained_text
	}
	style_environment_pop(&ui, scope)
	secondary_container_style := layout_style(.Column, width=320, height=40)
	_ = container_begin(&ui, .Container, key=key_string("appearance-revision-secondary-container"), style=secondary_container_style)
	secondary_scope := style_environment_push(&ui, Style_Environment{theme=DEFAULT_STYLE_THEME_ID})
	secondary_region, secondary_reused := region_begin(&ui, "appearance-revision-secondary-region", app.content_revision)
	app.secondary_region = secondary_region
	app.secondary_region_reused = secondary_reused
	if secondary_region != 0 && !secondary_reused {
		app.secondary_body_runs += 1
		app.secondary_text = text(&ui, "unrelated theme region", key=key_string("appearance-revision-secondary-text"),
			style=layout_style(.Row, width=280, height=28), color=style_color(&ui, .Text))
		region_end(&ui, secondary_region, false, 0)
	} else if retained_text, found := node_by_key(rt, key_string("appearance-revision-secondary-text"), .Text); found {
		app.secondary_text = retained_text
	}
	style_environment_pop(&ui, secondary_scope)
	container_end(&ui)
	container_end(&ui)
	end_frame(&ui)
	return rt.frame_cause.id
}

region_appearance_test_fresh_color :: proc(
	theme: Style_Theme,
	preferences: Accessibility_Appearance_Preferences,
	accessibility_override: Accessibility_Appearance_Preferences = {},
	accessibility_override_set := false,
) -> (Color, bool) {
	fresh := new_runtime(Rect{0, 0, 320, 120})
	defer destroy_runtime(&fresh)
	theme_id := style_theme_register(&fresh, theme)
	if theme_id == 0 { return {}, false }
	if !accessibility_override_set {
		_ = style_root_accessibility_observation_set(&fresh, Accessibility_Appearance_Observation{
			preferences=preferences,
			known={.Increased_Contrast, .Reduce_Motion, .Reduce_Transparency, .Differentiate_Without_Color},
		})
	}
	app := Region_Appearance_Test_App{
		theme=theme_id,
		content_revision=1,
		accessibility_override=accessibility_override,
		accessibility_override_set=accessibility_override_set,
	}
	_ = region_appearance_test_render(&fresh, &app)
	if text_node, found := fresh.nodes[app.text]; found { return text_node.color, true }
	return {}, false
}

@(test)
test_keyed_region_tracks_host_and_scoped_appearance_and_same_id_theme_replacement :: proc(t: ^testing.T) {
	rt := new_runtime(Rect{0, 0, 320, 120})
	defer destroy_runtime(&rt)
	theme := region_appearance_test_theme(Color{0.28, 0.31, 0.36, 0.44})
	theme_id := style_theme_register(&rt, theme)
	app := Region_Appearance_Test_App{theme=theme_id, content_revision=1}
	_ = region_appearance_test_render(&rt, &app)
	initial_color := rt.nodes[app.text].color
	previous_appearance := app.appearance_revision

	appearance_states := [?]Accessibility_Appearance_Preferences{
		{increased_contrast=true},
		{reduce_transparency=true},
		{differentiate_without_color=true},
		{reduce_motion=true},
	}
	for preferences in appearance_states {
		observation := Accessibility_Appearance_Observation{
			preferences=preferences,
			known={.Increased_Contrast, .Reduce_Motion, .Reduce_Transparency, .Differentiate_Without_Color},
		}
		if !style_root_accessibility_observation_set(&rt, observation) {
			testing.expect(t, false, "a changed host appearance observation must be accepted")
			continue
		}
		before_runs := app.body_runs
		_ = region_appearance_test_render(&rt, &app)
		fresh_color, fresh_ok := region_appearance_test_fresh_color(theme, preferences)
		retained_color := rt.nodes[app.text].color
		testing.expect(t, !app.region_reused && app.body_runs == before_runs+1,
			"a cached region must describe again when resolved host appearance changes")
		testing.expect(t, !app.secondary_region_reused,
			"host appearance changes must also reach regions using the inherited accessibility appearance")
		testing.expect(t, app.appearance_revision != previous_appearance,
			"the public appearance snapshot must change for each resolved host appearance")
		testing.expect(t, fresh_ok && retained_color == fresh_color,
			"appearance-dependent text ink must match a fresh runtime after a host setting change")
		previous_appearance = app.appearance_revision
	}

	// App-scoped accessibility overrides are resolved inputs too, even though
	// the host preference bundle remains unchanged.
	app.accessibility_override = Accessibility_Appearance_Preferences{differentiate_without_color=true}
	app.accessibility_override_set = true
	invalidate_root(&rt, "fixture changed scoped appearance override")
	secondary_runs_before_scope_override := app.secondary_body_runs
	before_runs := app.body_runs
	_ = region_appearance_test_render(&rt, &app)
	testing.expect(t, !app.region_reused && app.body_runs == before_runs+1 &&
		app.appearance_revision.accessibility.differentiate_without_color,
		"a keyed region must follow explicit subtree appearance overrides")
	testing.expect(t, app.secondary_region_reused && app.secondary_body_runs == secondary_runs_before_scope_override,
		"a scoped appearance override must leave regions outside that scope reusable")

	// A same-ID palette replacement changes the opaque theme generation and
	// schedules a description because a cached region was described under the theme.
	app.accessibility_override = {}
	app.accessibility_override_set = false
	default_observation := Accessibility_Appearance_Observation{
		known={.Increased_Contrast, .Reduce_Motion, .Reduce_Transparency, .Differentiate_Without_Color},
	}
	_ = style_root_accessibility_observation_set(&rt, default_observation)
	_ = region_appearance_test_render(&rt, &app)
	before_runs = app.body_runs
	secondary_runs_before_theme_replace := app.secondary_body_runs
	previous_appearance = app.appearance_revision
	replacement := region_appearance_test_theme(Color{0.78, 0.22, 0.17, 0.62})
	testing.expect(t, style_theme_replace(&rt, theme_id, replacement) == .Replaced && rt.invalidated,
		"replacing the selected theme must schedule cached app-authored region appearance resolution")
	cause_id := region_appearance_test_render(&rt, &app)
	fresh_color, fresh_ok := region_appearance_test_fresh_color(replacement, {})
	retained_color := rt.nodes[app.text].color
	testing.expect(t, !app.region_reused && app.body_runs == before_runs+1 && app.appearance_revision != previous_appearance,
		"same-ID theme replacement must invalidate the keyed region appearance snapshot")
	testing.expect(t, app.secondary_region_reused && app.secondary_body_runs == secondary_runs_before_theme_replace,
		"same-ID theme replacement must preserve cached regions that use a different theme")
	testing.expect(t, fresh_ok && retained_color == fresh_color,
		"same-ID theme replacement must match a fresh runtime's application-resolved text ink")
	testing.expect(t, retained_color != initial_color,
		"the regression fixture must distinguish the old cached palette from its replacement")
	if frontier_capture_enabled() {
		capture, found := frontier_capture(&rt, cause_id)
		text_changed := false
		for node in capture.changed_nodes[.Description][:capture.changed_node_count[.Description]] {
			if node == app.text { text_changed = true; break }
		}
		testing.expect(t, found && capture.root_invalidations == 1 && capture.changed[.Description] > 0 && text_changed,
			"the invalidation-frontier capture must attribute the changed keyed-region text to the appearance-triggered description")
	}

	// A no-op host observation and an unchanged theme are cache-neutral.
	_ = style_root_accessibility_observation_set(&rt, default_observation)
	_ = region_appearance_test_render(&rt, &app)
	runs_before_idle := app.body_runs
	previous_appearance = app.appearance_revision
	testing.expect(t, style_theme_replace(&rt, theme_id, replacement) == .Unchanged && !rt.invalidated,
		"replacing a theme with identical contents should not advance its appearance generation or schedule work")
	invalidate_root(&rt, "fixture repeated an unchanged description")
	_ = region_appearance_test_render(&rt, &app)
	testing.expect(t, app.region_reused && app.body_runs == runs_before_idle &&
		app.appearance_revision == previous_appearance,
		"unchanged appearance inputs should preserve region reuse")
}
