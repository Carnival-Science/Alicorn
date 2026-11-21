package alicorn

import "core:mem"

// Window decoration and application-authored chrome vocabulary. These names and
// shapes mirror native/sdl_gpu's Application chrome contract exactly so an
// application can move between the reference SDL_GPU host and a Hosted_Runtime
// host without adapting its callbacks.
Window_Decoration_Mode :: enum {
	System,
	Integrated_Title_Bar,
	Content_Title_Bar,
}

// Window_Chrome_Metrics reports measured native geometry for an application-
// authored titlebar header. Rectangles use top-left window-logical points.
Window_Chrome_Metrics :: struct {
	header: Rect,
	native_controls: [3]Rect,
	native_control_count: int,
	content_start_x: f32,
	content_end_x: f32,
	display_scale: f32,
	fullscreen: bool,
}

window_chrome_metrics_equal :: proc(a, b: Window_Chrome_Metrics) -> bool {
	if a.header != b.header || a.native_control_count != b.native_control_count ||
		a.content_start_x != b.content_start_x || a.content_end_x != b.content_end_x ||
		a.display_scale != b.display_scale || a.fullscreen != b.fullscreen { return false }
	for i in 0..<min(max(a.native_control_count, 0), len(a.native_controls)) {
		if a.native_controls[i] != b.native_controls[i] { return false }
	}
	return true
}

Window_Chrome_Metrics_Proc :: proc(state: rawptr, rt: ^Runtime, metrics: Window_Chrome_Metrics)

Window_Chrome_Region_Kind :: enum { Interactive, Window_Drag }

WINDOW_CHROME_REGION_CAPACITY :: 16

// A chrome region references an ordinary retained node. The host resolves its
// finalized bounds after layout and retains only those geometry products. At
// most WINDOW_CHROME_REGION_CAPACITY regions are consumed per layout callback.
Window_Chrome_Region :: struct {
	node: Node_ID,
	kind: Window_Chrome_Region_Kind,
}

Window_Chrome_Layout :: struct {
	header: Node_ID,
	regions: []Window_Chrome_Region,
}

Window_Chrome_Layout_Proc :: proc(state: rawptr, rt: ^Runtime) -> Window_Chrome_Layout

// Window_Chrome_Appearance is optional host presentation policy for integrated
// window chrome. The host keeps ownership of rendering and interaction;
// applications may supply colors resolved from their active theme.
Window_Chrome_Appearance :: struct {
	defined:    bool,
	background: Color,
	foreground: Color,
}

Window_Chrome_Appearance_Proc :: proc(state: rawptr, rt: ^Runtime) -> Window_Chrome_Appearance

// Hosted_Chrome_Paint_Proc appends host-owned chrome paint after application
// paint. width and height are window-logical dimensions including the chrome
// band. The returned commands are borrowed for the current presentation and
// must be allocated from the supplied allocator.
Hosted_Chrome_Paint_Proc :: proc(
	state: rawptr,
	rt: ^Runtime,
	width, height: f32,
	allocator: mem.Allocator,
) -> []Paint_Command

// Host_Text_Run is a shaped text resource owned by the embedding host. It is
// registered through runtime_host_text_run_set so the renderer can resolve
// Text_Run_Source.Host paint commands without exposing Runtime nodes.
Host_Text_Run :: struct {
	id:         u64,
	run:        Text_Run,
	generation: u64,
	valid:      bool,
}

// runtime_host_text_run_set shapes and installs one host text resource. A
// replaced resource destroys the previous run. The allocation is owned by the
// Runtime and released by runtime_host_text_run_release or destroy_runtime.
runtime_host_text_run_set :: proc(
	rt: ^Runtime,
	id: u64,
	value: string,
	size: f32,
	font_role := Font_Role.UI,
	font_weight := FONT_WEIGHT_REGULAR,
	allocator := context.allocator,
) -> (handle: Text_Run_Handle, ok: bool) {
	if rt == nil || id == 0 || size <= 0 { return }
	run, built := text_run_build(
		&rt.text_engine,
		value,
		size,
		allocator=allocator,
		scratch_allocator=rt.scratch_allocator,
		font_role=font_role,
		font_weight=font_weight,
	)
	if !built { return }
	generation := paint_next_resource_generation(rt)
	for i in 0..<len(rt.host_text_runs) {
		entry := &rt.host_text_runs[i]
		if entry.id != id { continue }
		if entry.valid { text_run_destroy(&entry.run) }
		entry.run = run
		entry.generation = generation
		entry.valid = true
		return Text_Run_Handle{.Host, id, generation}, true
	}
	append(&rt.host_text_runs, Host_Text_Run{
		id=id, run=run, generation=generation, valid=true,
	})
	return Text_Run_Handle{.Host, id, generation}, true
}

runtime_host_text_run_release :: proc(rt: ^Runtime, id: u64) {
	if rt == nil || id == 0 { return }
	for i in 0..<len(rt.host_text_runs) {
		entry := &rt.host_text_runs[i]
		if entry.id != id { continue }
		if entry.valid { text_run_destroy(&entry.run) }
		entry^ = {}
		return
	}
}

// runtime_host_text_run_handle returns the current generation for an installed
// host resource. It is zero when the resource does not exist.
runtime_host_text_run_handle :: proc(rt: ^Runtime, id: u64) -> Text_Run_Handle {
	if rt == nil || id == 0 { return {} }
	for entry in rt.host_text_runs {
		if entry.id == id && entry.valid {
			return Text_Run_Handle{.Host, id, entry.generation}
		}
	}
	return {}
}

runtime_host_text_run_resolve :: proc(rt: ^Runtime, handle: Text_Run_Handle) -> (^Text_Run, bool) {
	if rt == nil || handle.source != .Host || handle.resource == 0 || handle.generation == 0 { return nil, false }
	for i in 0..<len(rt.host_text_runs) {
		entry := &rt.host_text_runs[i]
		if entry.id == handle.resource && entry.valid && entry.generation == handle.generation {
			return &entry.run, true
		}
	}
	return nil, false
}

@(private)
host_text_runs_destroy :: proc(rt: ^Runtime) {
	if rt == nil { return }
	for i in 0..<len(rt.host_text_runs) {
		entry := &rt.host_text_runs[i]
		if entry.valid { text_run_destroy(&entry.run) }
		entry^ = {}
	}
	if rt.host_text_runs != nil { delete(rt.host_text_runs) }
}
