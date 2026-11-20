package alicorn_sdl_gpu

import "core:testing"
import alicorn "../../runtime"

@(test)
test_native_appearance_snapshot_merges_only_known_fields :: proc(t: ^testing.T) {
	previous := Native_Appearance_Snapshot{
		preferences=alicorn.Accessibility_Appearance_Preferences{
			increased_contrast=true,
			reduce_motion=true,
		},
		known=Native_Appearance_Known_Fields{.Increased_Contrast, .Reduce_Motion},
	}
	observed := Native_Appearance_Snapshot{
		preferences=alicorn.Accessibility_Appearance_Preferences{reduce_transparency=true},
		known=Native_Appearance_Known_Fields{.Reduce_Transparency},
	}
	merged, changed := native_appearance_snapshot_merge(previous, observed)
	testing.expect(t, changed && merged.preferences.increased_contrast && merged.preferences.reduce_motion &&
		merged.preferences.reduce_transparency && !merged.preferences.differentiate_without_color,
		"unsupported or failed preference reads must preserve known values while new supported fields update")
	testing.expect(t, Native_Appearance_Field.Increased_Contrast in merged.known &&
		Native_Appearance_Field.Reduce_Motion in merged.known &&
		Native_Appearance_Field.Reduce_Transparency in merged.known &&
		Native_Appearance_Field.Differentiate_Without_Color not_in merged.known,
		"the normalized snapshot must retain per-field support/query knowledge")

	merged_again, changed_again := native_appearance_snapshot_merge(merged, observed)
	testing.expect(t, !changed_again && merged_again.preferences == merged.preferences,
		"identical native preference notifications must not produce a normalized change")
	cleared := Native_Appearance_Snapshot{
		preferences=alicorn.Accessibility_Appearance_Preferences{},
		known=Native_Appearance_Known_Fields{.Increased_Contrast},
	}
	merged_cleared, changed_cleared := native_appearance_snapshot_merge(merged, cleared)
	testing.expect(t, changed_cleared && !merged_cleared.preferences.increased_contrast &&
		merged_cleared.preferences.reduce_motion && merged_cleared.preferences.reduce_transparency,
		"a known false preference must update without clearing unrelated known fields")

	scaled := Native_Appearance_Snapshot{text_scale=1.5, text_scale_known=true}
	merged_scaled, scale_changed := native_appearance_snapshot_merge(merged, scaled)
	unknown_scale, unknown_changed := native_appearance_snapshot_merge(
		merged_scaled,
		Native_Appearance_Snapshot{preferences=merged_scaled.preferences, known=merged_scaled.known},
	)
	unchanged_scale, unchanged_scale_changed := native_appearance_snapshot_merge(merged_scaled, scaled)
	testing.expect(t, scale_changed && merged_scaled.text_scale == 1.5 && merged_scaled.text_scale_known &&
		!unknown_changed && unknown_scale.text_scale == 1.5 && unknown_scale.text_scale_known &&
		!unchanged_scale_changed && unchanged_scale.text_scale == 1.5,
		"a supported text scale should update once and remain intact when a later native query cannot report it")
}

@(test)
test_native_text_scale_updates_root_once_and_preserves_unknown_reads :: proc(t: ^testing.T) {
	rt := alicorn.new_runtime(alicorn.Rect{0, 0, 320, 180})
	defer alicorn.destroy_runtime(&rt)
	monitor := Native_Appearance_Monitor{}
	observed := Native_Appearance_Snapshot{text_scale=1.75, text_scale_known=true}
	testing.expect(t, native_appearance_monitor_apply_snapshot(&monitor, &rt, observed),
		"a changed native text scale should update the persistent Alicorn root input")
	root := alicorn.style_root_accessibility_observation_get(&rt)
	testing.expect(t, root.text_scale == 1.75 && root.text_scale_known,
		"the host should pass the observed system scale through to Alicorn")

	rt.invalidated = false
	testing.expect(t, !native_appearance_monitor_apply_snapshot(&monitor, &rt, observed) && !rt.invalidated,
		"repeated identical text-scale notifications should not schedule UI work")
	unknown := Native_Appearance_Snapshot{}
	testing.expect(t, !native_appearance_monitor_apply_snapshot(&monitor, &rt, unknown) && !rt.invalidated,
		"a failed native scale query should preserve the prior value without scheduling work")
	root = alicorn.style_root_accessibility_observation_get(&rt)
	testing.expect(t, root.text_scale == 1.75 && root.text_scale_known,
		"unavailable native scale reads must preserve the last known system setting")
}
