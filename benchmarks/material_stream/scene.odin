package main

// The material-stream fixture describes one retained scene twice: once as an
// ordinary ui description for a real window (SDL_GPU and hosted WebGPU), and
// once as the resolved Paint_Command stream that the offscreen GPU sweep
// submits. Both forms contain exactly MATERIAL_STREAM_CARDS visible surface
// commands plus MATERIAL_STREAM_ROWS visible scrolling-row commands.
//
// A treatment changes only the paint's shape, material, and physical height.
// Bounds, clip, opacity, translation, stroke (absent in every treatment), and
// painter order are identical across treatments.

import "core:time"
import alicorn "alicorn:runtime"
import ui "alicorn:ui"

MATERIAL_STREAM_CARDS          :: 500
MATERIAL_STREAM_ROWS           :: 28
MATERIAL_STREAM_COLUMNS        :: 20
MATERIAL_STREAM_GRID_ROWS      :: 25
MATERIAL_STREAM_CARD_WIDTH     :: 46
MATERIAL_STREAM_CARD_HEIGHT    :: 20
MATERIAL_STREAM_CARD_GAP       :: 2
MATERIAL_STREAM_CARD_RADIUS    :: 8
MATERIAL_STREAM_WIDTH          :: 960
MATERIAL_STREAM_HEIGHT         :: 640
MATERIAL_STREAM_CARD_VIEWPORT  :: 550
MATERIAL_STREAM_ROW_HEIGHT     :: 3
MATERIAL_STREAM_ROW_TOP        :: 552
MATERIAL_STREAM_ROW_VIEWPORT   :: 81
MATERIAL_STREAM_SCROLL_ITEMS   :: 200

MATERIAL_STREAM_PASSES         :: 24
MATERIAL_STREAM_SCALES         :: [4]f32{1, 1.25, 1.5, 2}

Treatment :: struct {
	name:    string,
	rounded: bool,
	relief:  bool,
	height:  f32,
}

TREATMENTS :: [?]Treatment{
	{"rect-flat-h0",        false, false, 0},
	{"rect-flat-h05",       false, false, 0.5},
	{"rect-relief-h0",      false, true,  0},
	{"rect-relief-h05",     false, true,  0.5},
	{"rounded-flat-h0",     true,  false, 0},
	{"rounded-flat-h05",    true,  false, 0.5},
	{"rounded-relief-h0",   true,  true,  0},
	{"rounded-relief-h05",  true,  true,  0.5},
}

treatment_from_name :: proc(name: string) -> (Treatment, bool) {
	for treatment in TREATMENTS {
		if treatment.name == name { return treatment, true }
	}
	return {}, false
}

Condition :: enum {
	Cold_Mount,
	Warm_Steady,
	Resize_Sweep,
	Theme_Change,
	Rapid_Hover,
	Scroll,
	Idle,
}

CONDITIONS :: [?]Condition{
	.Cold_Mount, .Warm_Steady, .Resize_Sweep, .Theme_Change, .Rapid_Hover, .Scroll, .Idle,
}

condition_from_name :: proc(name: string) -> (Condition, bool) {
	switch name {
	case "cold": return .Cold_Mount, true
	case "warm": return .Warm_Steady, true
	case "resize": return .Resize_Sweep, true
	case "theme": return .Theme_Change, true
	case "hover": return .Rapid_Hover, true
	case "scroll": return .Scroll, true
	case "idle": return .Idle, true
	}
	return .Warm_Steady, false
}

condition_name :: proc(condition: Condition) -> string {
	switch condition {
	case .Cold_Mount: return "cold"
	case .Warm_Steady: return "warm"
	case .Resize_Sweep: return "resize"
	case .Theme_Change: return "theme"
	case .Rapid_Hover: return "hover"
	case .Scroll: return "scroll"
	case .Idle: return "idle"
	}
	return "warm"
}

condition_passes :: proc(condition: Condition) -> int {
	switch condition {
	case .Cold_Mount, .Idle: return 1
	case .Warm_Steady, .Resize_Sweep, .Theme_Change, .Rapid_Hover, .Scroll: return MATERIAL_STREAM_PASSES
	}
	return MATERIAL_STREAM_PASSES
}

CARD_COLOR_A      :: alicorn.Color{0.20, 0.26, 0.34, 1}
CARD_COLOR_B      :: alicorn.Color{0.29, 0.35, 0.43, 1}
CARD_HOVER_COLOR  :: alicorn.Color{0.55, 0.62, 0.30, 1}
ROW_COLOR         :: alicorn.Color{0.16, 0.20, 0.26, 1}
ROW_COLOR_ALT     :: alicorn.Color{0.23, 0.29, 0.36, 1}

Material_Scene :: struct {
	treatment: Treatment,
	condition: Condition,
	step:      u64,
	rt:        ^alicorn.Runtime,
	material:  alicorn.Material_ID,
	theme_a:   alicorn.Style_Theme_ID,
	theme_b:   alicorn.Style_Theme_ID,
	scroll_id: alicorn.Node_ID,
	// realized_rows records the virtual list range of the latest description so
	// the harness can prove the scrolling-row count, not assume it.
	realized_rows: int,
	description_ns: u64,
}

material_scene_register :: proc(scene: ^Material_Scene, rt: ^alicorn.Runtime) {
	if scene == nil || rt == nil { return }
	scene.rt = rt
	scene.material = alicorn.style_material_register(rt, alicorn.Style_Material{
		kind=.Analytic_Relief, bevel_width=1, bevel_strength=0.42,
		inner_shadow_strength=0.14, outer_shadow_strength=0.18, outer_shadow_radius=3,
	})
	theme_a := alicorn.DEFAULT_STYLE_THEME
	theme_b := alicorn.DEFAULT_STYLE_THEME
	theme_b.color_tokens = {
		alicorn.Color{0.22, 0.24, 0.30, 1},
		alicorn.Color{0.15, 0.42, 0.52, 1},
	}
	scene.theme_a = alicorn.style_theme_register(rt, theme_a)
	scene.theme_b = alicorn.style_theme_register(rt, theme_b)
}

material_scene_card_color :: proc(scene: ^Material_Scene, index: int) -> alicorn.Color {
	if scene.condition == .Rapid_Hover {
		if index == int(scene.step % MATERIAL_STREAM_CARDS) {
			return CARD_HOVER_COLOR
		}
		return CARD_COLOR_A
	}
	if scene.condition == .Theme_Change && scene.step%2 == 1 {
		return CARD_COLOR_B
	}
	return CARD_COLOR_A
}

material_scene_row_color :: proc(scene: ^Material_Scene) -> alicorn.Color {
	if scene.condition == .Theme_Change && scene.step%2 == 1 { return ROW_COLOR_ALT }
	return ROW_COLOR
}

material_scene_shape :: proc(treatment: Treatment) -> alicorn.Surface_Shape {
	if treatment.rounded {
		return alicorn.surface_shape_uniform_corner_radius(MATERIAL_STREAM_CARD_RADIUS)
	}
	return alicorn.Surface_Shape{kind=.Rectangle}
}

material_scene_material :: proc(scene: ^Material_Scene) -> alicorn.Material_ID {
	if scene.treatment.relief { return scene.material }
	return alicorn.MATERIAL_FLAT
}

material_scene_physical_height :: proc(treatment: Treatment) -> f32 {
	if treatment.relief { return treatment.height }
	return 0
}

// material_scene_describe is the window form. The caller owns the Root scope,
// matching both ui.run and ui/webgpu.run.
material_scene_describe :: proc(scene: ^Material_Scene, ctx: ^ui.UI) {
	if scene == nil || ctx == nil { return }
	started := time.tick_now()
	defer scene.description_ns = u64(time.duration_nanoseconds(time.tick_since(started)))
	theme := scene.theme_a
	if scene.condition == .Theme_Change && scene.step%2 == 1 && scene.theme_b != 0 {
		theme = scene.theme_b
	}
	scope := alicorn.Style_Environment_Scope{}
	if theme != 0 {
		scope = alicorn.style_environment_push(ctx, alicorn.Style_Environment{theme=theme})
	}
	defer if scope.active { alicorn.style_environment_pop(ctx, scope) }

	shape := material_scene_shape(scene.treatment)
	material := material_scene_material(scene)
	physical_height := material_scene_physical_height(scene.treatment)
	if ui.column(ctx, grow=1, gap=2, clip=true, label="material-stream-root") {
		if ui.column(ctx, height=MATERIAL_STREAM_CARD_VIEWPORT, gap=MATERIAL_STREAM_CARD_GAP,
			clip=true, label="material-stream-cards") {
			index := 0
			for row in 0..<MATERIAL_STREAM_GRID_ROWS {
				if ui.row(ctx, key=ui.key_u64(5_000+u64(row)),
					height=MATERIAL_STREAM_CARD_HEIGHT, gap=MATERIAL_STREAM_CARD_GAP,
					label="material-stream-card-row") {
					for _ in 0..<MATERIAL_STREAM_COLUMNS {
						_ = ui.panel(
							ctx,
							key=ui.key_u64(10_000+u64(index)),
							width=MATERIAL_STREAM_CARD_WIDTH,
							height=MATERIAL_STREAM_CARD_HEIGHT,
							fill=material_scene_card_color(scene, index),
							shape=shape,
							material=material,
							physical_height=physical_height,
							label="material-stream-card",
						)
						index += 1
					}
				}
			}
		}
		if list, ok := ui.virtual_list(
			ctx,
			MATERIAL_STREAM_SCROLL_ITEMS,
			MATERIAL_STREAM_ROW_HEIGHT,
			key=ui.key_u64(20),
			width=-1,
			height=MATERIAL_STREAM_ROW_VIEWPORT,
			grow=0,
			label="material-stream-rows",
		); ok {
			scene.scroll_id = list.scroll.id
			scene.realized_rows = list.last-list.first
			for row in list.first..<list.last {
				_ = ui.panel(
					ctx,
					key=ui.key_u64(30_000+u64(row)),
					width=-1,
					height=MATERIAL_STREAM_ROW_HEIGHT,
					fill=material_scene_row_color(scene),
					shape=shape,
					material=material,
					physical_height=physical_height,
					label="material-stream-row",
				)
			}
		}
	}
}

// material_scene_advance applies one condition step on the application thread
// before the next description, matching how pointer or wheel input mutates app
// state before a wake. It returns true when it requested a new description.
material_scene_advance :: proc(scene: ^Material_Scene, rt: ^alicorn.Runtime) -> bool {
	if scene == nil || rt == nil { return false }
	scene.step += 1
	switch scene.condition {
	case .Resize_Sweep:
		width := f32(MATERIAL_STREAM_WIDTH + (int(scene.step%4)*60))
		if !alicorn.runtime_set_viewport(rt, alicorn.Rect{0, 0, width, MATERIAL_STREAM_HEIGHT}) {
			alicorn.invalidate_root(rt, "material stream resize sweep")
		}
		return true
	case .Scroll:
		if scene.scroll_id == 0 { return false }
		// Item-aligned offsets keep the realized row count at exactly
		// MATERIAL_STREAM_ROWS while the contents move.
		offset := f32((int(scene.step%40))*MATERIAL_STREAM_ROW_HEIGHT)
		if !alicorn.scroll_region_set_offset(rt, scene.scroll_id, offset, "material stream scroll") {
			alicorn.invalidate_root(rt, "material stream scroll fallback")
		}
		return true
	case .Cold_Mount, .Idle:
		return false
	case .Warm_Steady, .Theme_Change, .Rapid_Hover:
		alicorn.invalidate_root(rt, "material stream condition step")
		return true
	}
	return false
}

// material_scene_commands builds the resolved stream for the offscreen GPU
// sweep. Shapes, clip, opacity, translation, stroke, and order match the window
// description; only the bounds are explicit instead of layout-resolved.
material_scene_commands :: proc(
	scene: ^Material_Scene,
	out: ^[dynamic]alicorn.Paint_Command,
	viewport_width: f32,
) {
	clear(out)
	shape := material_scene_shape(scene.treatment)
	material := material_scene_material(scene)
	physical_height := material_scene_physical_height(scene.treatment)
	card_clip := alicorn.Rect{0, 0, viewport_width, MATERIAL_STREAM_CARD_VIEWPORT}
	row_clip := alicorn.Rect{0, MATERIAL_STREAM_ROW_TOP, viewport_width, MATERIAL_STREAM_ROW_VIEWPORT}
	for index in 0..<MATERIAL_STREAM_CARDS {
		column := index%MATERIAL_STREAM_COLUMNS
		row := index/MATERIAL_STREAM_COLUMNS
		bounds := alicorn.Rect{
			f32(column*(MATERIAL_STREAM_CARD_WIDTH+MATERIAL_STREAM_CARD_GAP)),
			f32(row*(MATERIAL_STREAM_CARD_HEIGHT+MATERIAL_STREAM_CARD_GAP)),
			MATERIAL_STREAM_CARD_WIDTH,
			MATERIAL_STREAM_CARD_HEIGHT,
		}
		append(out, alicorn.paint_surface_command(
			alicorn.Node_ID(index+1),
			bounds,
			card_clip,
			material_scene_card_color(scene, index),
			shape=shape,
			material=material,
			physical_height=physical_height,
		))
	}
	row_offset := f32(0)
	if scene.condition == .Scroll {
		row_offset = f32((int(scene.step%40))*MATERIAL_STREAM_ROW_HEIGHT)
	}
	for row in 0..<MATERIAL_STREAM_ROWS {
		bounds := alicorn.Rect{
			0,
			MATERIAL_STREAM_ROW_TOP+f32(row)*MATERIAL_STREAM_ROW_HEIGHT-row_offset,
			viewport_width,
			MATERIAL_STREAM_ROW_HEIGHT,
		}
		append(out, alicorn.paint_surface_command(
			alicorn.Node_ID(100_000+row),
			bounds,
			row_clip,
			material_scene_row_color(scene),
			shape=shape,
			material=material,
			physical_height=physical_height,
		))
	}
}
