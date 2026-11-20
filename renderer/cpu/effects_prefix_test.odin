#+build !js
package cpu_renderer

import "core:testing"
import alicorn "../../runtime"

@(test)
test_backdrop_effect_prefix_ends_at_first_marker_and_hashes_only_prefix :: proc(t: ^testing.T) {
	region := alicorn.Rect{80, 60, 400, 300}
	clip := alicorn.Rect{0, 0, 1000, 700}
	background := alicorn.paint_surface_command(
		alicorn.Node_ID(1), alicorn.Rect{0, 0, 1000, 700}, clip, alicorn.Color{0.1, 0.12, 0.16, 1},
	)
	marker := alicorn.paint_backdrop_effect_command(alicorn.Node_ID(2), region, clip, alicorn.backdrop_blur(4))
	after := alicorn.paint_surface_command(
		alicorn.Node_ID(4), alicorn.Rect{100, 130, 88, 32}, clip, alicorn.Color{0.18, 0.24, 0.35, 1},
	)
	display := [3]alicorn.Paint_Command{background, marker, after}
	prefix, found_marker, marker_index, found := Backdrop_Effect_Prefix_Before_First_Marker(display[:])
	found_effect, found_effect_ok := found_marker.payload.(alicorn.Backdrop_Effect_Paint)
	marker_effect, marker_effect_ok := marker.payload.(alicorn.Backdrop_Effect_Paint)
	testing.expect(t, found && marker_index == 1 && len(prefix) == 1 &&
		found_marker.owner == marker.owner && found_marker.bounds == marker.bounds &&
		found_effect_ok && marker_effect_ok && found_effect.sigma == marker_effect.sigma,
		"the first backdrop marker should split the paint prefix from later commands")
	if !found { return }
	generation := Backdrop_Effect_Prefix_Generation(prefix, region, clip, 1, 1, 4)
	after.payload = alicorn.Surface_Paint{shape={kind=.Rectangle}, fill={0.9, 0.1, 0.2, 1}}
	display[2] = after
	prefix_after, _, _, _ := Backdrop_Effect_Prefix_Before_First_Marker(display[:])
	testing.expect(t, Backdrop_Effect_Prefix_Generation(prefix_after, region, clip, 1, 1, 4) == generation,
		"paint after the boundary must not invalidate the retained backdrop")
	background.payload = alicorn.Surface_Paint{shape={kind=.Rectangle}, fill={0.2, 0.12, 0.16, 1}}
	display[0] = background
	prefix_changed, _, _, _ := Backdrop_Effect_Prefix_Before_First_Marker(display[:])
	testing.expect(t, Backdrop_Effect_Prefix_Generation(prefix_changed, region, clip, 1, 1, 4) != generation,
		"paint behind the boundary must invalidate the retained backdrop")
}

@(test)
test_later_backdrop_prefix_hash_includes_earlier_effect_parameters :: proc(t: ^testing.T) {
	clip := alicorn.Rect{0, 0, 400, 240}
	background := alicorn.paint_surface_command(
		alicorn.Node_ID(1), clip, clip, alicorn.Color{0.1, 0.12, 0.16, 1},
	)
	first := alicorn.paint_backdrop_effect_command(
		alicorn.Node_ID(2), alicorn.Rect{20, 24, 80, 60}, clip, alicorn.backdrop_blur(3),
	)
	first_surface := alicorn.paint_surface_command(
		alicorn.Node_ID(3), alicorn.Rect{20, 24, 80, 60}, clip, alicorn.Color{0.8, 0.7, 0.2, 0.3},
	)
	second := alicorn.paint_backdrop_effect_command(
		alicorn.Node_ID(4), alicorn.Rect{40, 36, 90, 64}, clip, alicorn.backdrop_blur(5),
	)
	display := [4]alicorn.Paint_Command{background, first, first_surface, second}
	second_payload, ok := second.payload.(alicorn.Backdrop_Effect_Paint)
	if !ok { testing.expect(t, false, "the second effect fixture should contain a valid marker"); return }
	before := Backdrop_Effect_Prefix_Generation(display[:3], second.bounds, second.clip, 1, 1, second_payload.sigma)
	first.payload = alicorn.Backdrop_Effect_Paint{sigma=7, fallback=.Direct}
	display[1] = first
	after := Backdrop_Effect_Prefix_Generation(display[:3], second.bounds, second.clip, 1, 1, second_payload.sigma)
	testing.expect(t, before != after,
		"a later backdrop cache key must change when an earlier marker changes its filtering parameters")
}

@(test)
test_backdrop_effect_local_prefix_moves_only_bounds_and_clip :: proc(t: ^testing.T) {
	clip := alicorn.Rect{1, 2, 90, 80}
	draw := alicorn.paint_text_command(
		alicorn.Node_ID(7), alicorn.Rect{11, 22, 30, 40}, clip,
		alicorn.Text_Run_Handle{source=.Retained, resource=17, generation=3},
		alicorn.Color{0.8, 0.7, 0.6, 1},
	)
	draw.translation = {4, 5}
	display := [1]alicorn.Paint_Command{draw}
	local := Backdrop_Effect_Local_Prefix(display[:], {10, 20, 1, 1}, context.temp_allocator)
	testing.expect(t, len(local) == 1, "local prefix should preserve the command count")
	if len(local) != 1 { return }
	original_text, original_is_text := draw.payload.(alicorn.Text_Paint)
	local_text, local_is_text := local[0].payload.(alicorn.Text_Paint)
	testing.expect(t, len(local) == 1 && local[0].bounds == alicorn.Rect{1, 2, 30, 40} &&
		local[0].clip == alicorn.Rect{-9, -18, 90, 80} && local[0].translation == draw.translation &&
		local[0].owner == draw.owner && original_is_text && local_is_text &&
		local_text.run == original_text.run && local_text.color == original_text.color &&
		len(local_text.spans) == len(original_text.spans),
		"localizing capture geometry must preserve paint identity and translation semantics")
	testing.expect(t, display[0].bounds == alicorn.Rect{11, 22, 30, 40} && display[0].clip == clip,
		"localizing a backdrop prefix must not mutate the retained source paint")
}
