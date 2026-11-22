package alicorn_sdl_gpu

// Focused retained-effects GPU validation. Readbacks reuse draw_display_list
// and its existing shaders.
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import alicorn "../../runtime"
import cpu_renderer "../../renderer/cpu"
import "vendor:sdl3"

EFFECT_PROBE_WIDTH :: 384
EFFECT_PROBE_HEIGHT :: 256
EFFECT_PROBE_BUDGET :: 16*1024*1024
EFFECT_PROBE_BACKGROUND :: sdl3.FColor{0.08,0.12,0.18,0.4}

Effect_Probe_Timing :: struct { encode_ns, submit_wait_ns: i64, render_passes: int }

// Samples are sorted before this nearest-rank percentile helper is called.
effect_probe_percentile :: proc(samples: []i64, fraction: f64) -> i64 {
    if len(samples) == 0 { return 0 }
    index := int(math.ceil(f64(len(samples))*fraction))-1
    if index < 0 { index = 0 }
    if index >= len(samples) { index = len(samples)-1 }
    return samples[index]
}

// This fixture contains only Surface/Text commands. Count actual populated
// renderer runs, including clip culling, without adding production telemetry.
effect_probe_draw_passes :: proc(renderers:^Blend_Validation_Renderers, display:[]alicorn.Paint_Command) -> int {
    count,index,text_command_index:=0,0,0
    for index<len(display) {
        kind,end:=native_paint_run(display,index)
        if kind==.Text {
            for draw in renderers.text.draws {
                if draw.text_command_index==text_command_index { count+=1; break }
            }
            text_command_index+=1
        } else if kind==.Surface {
            for draw in renderers.solid.draws[index:end] {
                if draw.vertex_count>0 { count+=1; break }
            }
        }
        index=end
    }
    return count
}

effect_probe_scene :: proc(rt: ^alicorn.Runtime, text: ^Native_Text_Renderer, shadow: bool) -> []alicorn.Paint_Command {
    commands := make([dynamic]alicorn.Paint_Command, allocator=context.temp_allocator)
    clip := alicorn.Rect{0,0,EFFECT_PROBE_WIDTH,EFFECT_PROBE_HEIGHT}
    for i in 0..<12 {
        color := alicorn.Color{0.12+f32(i%3)*0.15,0.3,0.52,0.7}
        append(&commands, alicorn.paint_surface_command(1, {f32(i*32),0,16,EFFECT_PROBE_HEIGHT},clip,color))
    }
    handle := native_text_host_handle(text, 1)
    for i in 0..<9 {
        append(&commands, alicorn.paint_text_command(2,{14,f32(18+i*25),350,22},clip,handle,{0.95,0.85,0.48,0.8}))
    }
    if shadow {
        material := alicorn.style_material_register(rt, {.Analytic_Relief,0,0,0,0.7,8})
        append(&commands, alicorn.paint_surface_command(3,{96,56,192,144},clip,{0,0,0,0},
        shape=alicorn.surface_shape_uniform_corner_radius(10),material=material,physical_height=1))
    }
    return commands[:]
}

effect_probe_local_stream :: proc(display: []alicorn.Paint_Command, origin: alicorn.Rect) -> []alicorn.Paint_Command {
    result := make([]alicorn.Paint_Command,len(display),allocator=context.temp_allocator)
    for draw,i in display {
        result[i] = draw
        result[i].bounds.x -= origin.x; result[i].bounds.y -= origin.y
        result[i].clip.x -= origin.x; result[i].clip.y -= origin.y
    }
    return result
}

effect_probe_clear :: proc(command: ^sdl3.GPUCommandBuffer, target: ^sdl3.GPUTexture, color: sdl3.FColor) -> bool {
    info := make_color_target(target,color,false)
    pass := sdl3.BeginGPURenderPass(command,&info,1,nil)
    if pass == nil { return false }
    sdl3.EndGPURenderPass(pass)
    return true
}

// A fence round trip is reported as such: SDL_GPU exposes no portable GPU
// timestamp query here, so this is not mislabeled as hardware GPU execution time.
effect_probe_frame :: proc(
    renderers: ^Blend_Validation_Renderers, cache: ^Native_Effect_Cache,
    plan: Native_Effect_Plan, display: []alicorn.Paint_Command,
    target: ^sdl3.GPUTexture, download: ^sdl3.GPUTransferBuffer,
    pixels, source_pixels: []u8, use_effect, overlay: bool, backdrop := false,
) -> (timing: Effect_Probe_Timing, ok: bool) {
    started := time.now()
    status := Native_Effect_Status.Inactive
    if use_effect { status = native_effect_prepare(cache,plan) }
    apply_effect:=use_effect && status!=.Fallback && status!=.Inactive
    device := renderers.solid.device
    command := sdl3.AcquireGPUCommandBuffer(device)
    if command == nil { return }
    submitted := false
    defer if !submitted { _ = sdl3.CancelGPUCommandBuffer(command); native_effect_abort(cache) }
    background:=EFFECT_PROBE_BACKGROUND
    if backdrop { background.a=1 }
    if !effect_probe_clear(command,target,background) { return }
    timing.render_passes+=1
    if backdrop {
        if !draw_display_list(command,target,EFFECT_PROBE_WIDTH,EFFECT_PROBE_HEIGHT,
            &renderers.text,&renderers.geometry,&renderers.solid,display,plan.scale,plan.scale,clear_background=false) { return }
        timing.render_passes+=effect_probe_draw_passes(renderers,display)
    }
    if apply_effect {
        if status == .Render {
            source_clear:=sdl3.FColor{}
            // This candidate captures a known opaque paint prefix. Its alpha
            // stays one, replacing the original backdrop without double-over.
            // Transparent isolated-layer behavior is tested separately below.
            if backdrop { source_clear=background }
            if !effect_probe_clear(command,cache.source,source_clear) { return }
            timing.render_passes+=1
            local := effect_probe_local_stream(display,plan.source_bounds)
            if !draw_display_list(command,cache.source,plan.width,plan.height,
                &renderers.text,&renderers.geometry,&renderers.solid,local,plan.scale,plan.scale,clear_background=false) { return }
            timing.render_passes+=effect_probe_draw_passes(renderers,local)
            if !native_effect_encode(cache,command) { return }
            timing.render_passes+=2
        }
        if !native_effect_composite(cache,command,target,EFFECT_PROBE_WIDTH,EFFECT_PROBE_HEIGHT) { return }
        timing.render_passes+=1
    } else if !backdrop {
        if !draw_display_list(command,target,EFFECT_PROBE_WIDTH,EFFECT_PROBE_HEIGHT,
            &renderers.text,&renderers.geometry,&renderers.solid,display,plan.scale,plan.scale,clear_background=false) { return }
        timing.render_passes+=effect_probe_draw_passes(renderers,display)
    }
    if overlay {
        foreground := [1]alicorn.Paint_Command{alicorn.paint_surface_command(4,{40,36,20,16},{0,0,384,256},{1,0,0,0.5})}
        if !draw_display_list(command,target,EFFECT_PROBE_WIDTH,EFFECT_PROBE_HEIGHT,
            &renderers.text,&renderers.geometry,&renderers.solid,foreground[:],plan.scale,plan.scale,clear_background=false) { return }
        timing.render_passes+=effect_probe_draw_passes(renderers,foreground[:])
    }
    if backdrop {
        foreground:=[4]alicorn.Paint_Command{
            alicorn.paint_surface_command(5,{96,56,192,144},{0,0,384,256},{0.14,0.18,0.26,0.78}),
            alicorn.paint_text_command(6,{112,76,160,24},{96,56,192,144},native_text_host_handle(&renderers.text,2),{1,1,1,1}),
            alicorn.paint_surface_command(7,{108,118,168,30},{96,56,192,144},{0.2,0.36,0.58,0.95}),
            alicorn.paint_text_command(8,{116,122,150,24},{96,56,192,144},native_text_host_handle(&renderers.text,3),{1,1,1,1}),
        }
        if !draw_display_list(command,target,EFFECT_PROBE_WIDTH,EFFECT_PROBE_HEIGHT,
            &renderers.text,&renderers.geometry,&renderers.solid,foreground[:],1,1,clear_background=false) { return }
        timing.render_passes+=effect_probe_draw_passes(renderers,foreground[:])
    }
    if len(pixels)>0 || len(source_pixels)>0 {
        copy_pass := sdl3.BeginGPUCopyPass(command)
        if copy_pass == nil { return }
        if len(pixels)>0 {
            sdl3.DownloadFromGPUTexture(copy_pass,
                {texture=target,w=EFFECT_PROBE_WIDTH,h=EFFECT_PROBE_HEIGHT,d=1},
                {transfer_buffer=download,pixels_per_row=EFFECT_PROBE_WIDTH,rows_per_layer=EFFECT_PROBE_HEIGHT})
        }
        if len(source_pixels)>0 {
            sdl3.DownloadFromGPUTexture(copy_pass,{texture=cache.source,w=plan.width,h=plan.height,d=1},
                {transfer_buffer=download,offset=EFFECT_PROBE_WIDTH*EFFECT_PROBE_HEIGHT*4,pixels_per_row=((plan.width+63)/64)*64,rows_per_layer=plan.height})
        }
        sdl3.EndGPUCopyPass(copy_pass)
    }
    timing.encode_ns = time.duration_nanoseconds(time.since(started))
    submit_start := time.now()
    fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
    submitted = true
    if fence == nil { native_effect_abort(cache); return }
    defer sdl3.ReleaseGPUFence(device,fence)
    native_text_commit_submission(&renderers.text)
    native_surface_commit_submission(&renderers.geometry)
    native_solid_commit_submission(&renderers.solid)
    native_effect_commit(cache)
    fences := [1]^sdl3.GPUFence{fence}
    if !sdl3.WaitForGPUFences(device,true,&fences[0],1) { return }
    timing.submit_wait_ns = time.duration_nanoseconds(time.since(submit_start))
    if len(pixels)>0 || len(source_pixels)>0 {
        mapped := sdl3.MapGPUTransferBuffer(device,download,false)
        if mapped == nil { return }
        bytes := cast([^]u8)mapped
        copy(pixels,bytes[:len(pixels)])
        if len(source_pixels)>0 {
            stride:=int(((plan.width+63)/64)*64)*4
            row_bytes:=int(plan.width)*4
            for y in 0..<int(plan.height) {
                copy(source_pixels[y*row_bytes:][:row_bytes],bytes[EFFECT_PROBE_WIDTH*EFFECT_PROBE_HEIGHT*4+y*stride:][:row_bytes])
            }
        }
        sdl3.UnmapGPUTransferBuffer(device,download)
    }
    return timing,true
}

// Dense CPU Gaussian oracle. The GPU uses bilinear-paired taps and half-float
// accumulation; this reference uses every integer kernel coefficient directly.
effect_probe_reference :: proc(plan: Native_Effect_Plan, source, actual: []u8, overlay: bool) -> bool {
    w,h := int(plan.width),int(plan.height)
    weights, radius, weights_ok := native_effect_gaussian_weights(plan.sigma_pixels)
    if !weights_ok { return false }
    center := NATIVE_EFFECT_MAX_GAUSSIAN_RADIUS_PIXELS
    normalized := make([]f32,len(source),allocator=context.temp_allocator)
    ping := make([]f32,len(source),allocator=context.temp_allocator)
    filtered := make([]f32,len(source),allocator=context.temp_allocator)
    for value,index in source { normalized[index]=f32(value)/255 }
    for axis in 0..<2 {
        input,output := normalized,ping
        if axis==1 { input,output=ping,filtered }
        for y in 0..<h { for x in 0..<w { for c in 0..<4 {
            sum := f32(0)
            for offset in -radius..<(radius+1) {
                sx,sy := x,y
                if axis==0 { sx=clamp(x+offset,0,w-1) } else { sy=clamp(y+offset,0,h-1) }
                sum += input[(sy*w+sx)*4+c]*weights[center+offset]
            }
            output[(y*w+x)*4+c]=sum
        } } }
    }
    clip := plan.output_clip
    x0,y0,x1,y1 := cpu_renderer.Logical_To_Pixel_Bounds(clip,plan.scale,plan.scale)
    ox,oy := int(math.round(plan.source_bounds.x*plan.scale)),int(math.round(plan.source_bounds.y*plan.scale))
    background := [4]f32{0.08,0.12,0.18,0.4}
    worst := 0
    for y in 0..<EFFECT_PROBE_HEIGHT { for x in 0..<EFFECT_PROBE_WIDTH {
        expected:=background
        effect_index := -1
        if x>=x0 && x<x1 && y>=y0 && y<y1 {
            index:=((y-oy)*w+x-ox)*4
            effect_index = index
            a:=filtered[index+3]
            for c in 0..<4 { expected[c]=filtered[index+c]+background[c]*(1-a) }
        }
        if overlay && x>=int(40*plan.scale) && x<int(60*plan.scale) && y>=int(36*plan.scale) && y<int(52*plan.scale) {
            expected=blend_validation_over(expected,{1,0,0,0.5})
        }
        for c in 0..<4 {
            delta:=abs(int(actual[(y*EFFECT_PROBE_WIDTH+x)*4+c])-int(math.round(expected[c]*255)))
            worst=max(worst,delta)
            if delta>3 {
                if effect_index >= 0 {
                    fmt.println("effects_pixel_mismatch","scale",plan.scale,"pixel",x,y,"channel",c,"error",delta,
                        "actual",actual[(y*EFFECT_PROBE_WIDTH+x)*4+c],"expected",expected[c],
                        "expected_byte",math.round(expected[c]*255),"filtered_rgba",filtered[effect_index:effect_index+4])
                } else {
                    fmt.println("effects_pixel_mismatch","scale",plan.scale,"pixel",x,y,"channel",c,"error",delta,
                        "actual",actual[(y*EFFECT_PROBE_WIDTH+x)*4+c],"expected",expected[c])
                }
                return false
            }
        }
    } }
    fmt.println("effects_gaussian_readback","scale",plan.scale,"sigma_pixels",plan.sigma_pixels,
        "kernel_radius",radius,"paired_taps",plan.filter_tap_count,"worst_rgba8_error",worst,"painter_order",overlay)
    return true
}

effect_probe_ppm :: proc(path: string, pixels: []u8) -> bool {
    builder:=strings.builder_make(allocator=context.temp_allocator)
    fmt.sbprintf(&builder,"P6\n%d %d\n255\n",EFFECT_PROBE_WIDTH,EFFECT_PROBE_HEIGHT)
    for i in 0..<EFFECT_PROBE_WIDTH*EFFECT_PROBE_HEIGHT {
        for c in 0..<3 { strings.write_byte(&builder,pixels[i*4+c]) }
    }
    return os.write_entire_file(path,strings.to_string(builder))==nil
}

effect_probe_geometry_surface :: proc(rt: ^alicorn.Runtime) -> (owner: alicorn.Node_ID, draw: alicorn.Paint_Command, ok: bool) {
	ui, build := alicorn.begin_frame(rt)
	if !build { return }
	alicorn.container_begin(&ui, .Root, label="effect-payload-root")
	owner = alicorn.gpu_geometry_surface(&ui, "effect-payload-surface",
		alicorn.layout_style(width=EFFECT_PROBE_WIDTH, height=EFFECT_PROBE_HEIGHT))
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	node, found := rt.nodes[owner]
	if !found || node == nil { return }
	handle := alicorn.paint_geometry_handle_for_node(node)
	if handle.resource == 0 || handle.generation == 0 { return }
	draw = alicorn.paint_geometry_command(owner, node.bounds, node.clip, handle)
	return owner, draw, true
}

effect_probe_device :: proc(driver: cstring) -> bool {
    device:=sdl3.CreateGPUDevice({.DXIL,.MSL,.SPIRV},true,driver)
    if device==nil { return false }
    defer sdl3.DestroyGPUDevice(device)
    fmt.println("effects_gpu_validation","driver",sdl3.GetGPUDeviceDriver(device),"sdl_version",sdl3.GetVersion(),
        "source_format","RGBA8_UNORM","filter_format","RGBA16_FLOAT","color_space","encoded SDR (not linear-light blur)")
    rt:=alicorn.new_runtime({0,0,384,256})
    defer alicorn.destroy_runtime(&rt)
    renderers:Blend_Validation_Renderers
    ok:=false
    renderers.text,ok=native_text_make(device,.R8G8B8A8_UNORM,&rt)
    if !ok { return false }; defer native_text_destroy(&renderers.text)
    renderers.geometry,ok=native_surface_make(device,.R8G8B8A8_UNORM,&rt)
    if !ok { return false }; defer native_surface_destroy(&renderers.geometry)
    renderers.solid,ok=native_solid_make(device,.R8G8B8A8_UNORM,&rt)
    if !ok { return false }; defer native_solid_destroy(&renderers.solid)
    if !alicorn.text_engine_load_font(&rt.text_engine,NATIVE_UI_FONT_DATA) { return false }
    run,shaped:=alicorn.text_run_build(&rt.text_engine,"Retained UI: source / palette / selection",14)
    if !shaped || !native_text_register_host_run(&renderers.text,1,run) { return false }
    title,title_ok:=alicorn.text_run_build(&rt.text_engine,"Quick Open",18)
    if !title_ok || !native_text_register_host_run(&renderers.text,2,title) { return false }
    entry,entry_ok:=alicorn.text_run_build(&rt.text_engine,"notes.md",14)
    if !entry_ok || !native_text_register_host_run(&renderers.text,3,entry) { return false }
    display:=effect_probe_scene(&rt,&renderers.text,false)
    analytic:=effect_probe_scene(&rt,&renderers.text,true)
    target:=sdl3.CreateGPUTexture(device,{type=.D2,format=.R8G8B8A8_UNORM,usage={.COLOR_TARGET},width=384,height=256,layer_count_or_depth=1,num_levels=1,sample_count=._1})
    if target==nil { return false }; defer sdl3.ReleaseGPUTexture(device,target)
    download:=sdl3.CreateGPUTransferBuffer(device,{usage=.DOWNLOAD,size=EFFECT_PROBE_WIDTH*EFFECT_PROBE_HEIGHT*4+EFFECT_PROBE_BUDGET})
    if download==nil { return false }; defer sdl3.ReleaseGPUTransferBuffer(device,download)
    pixels:=make([]u8,EFFECT_PROBE_WIDTH*EFFECT_PROBE_HEIGHT*4,allocator=context.temp_allocator)
    cache:=native_effect_make(device,EFFECT_PROBE_BUDGET)
    defer native_effect_reset(&cache)
    // Initial disabled scene never initializes an effect pipeline or texture.
    for _ in 0..<100 { if native_effect_prepare(&cache,{})!=.Inactive { return false } }
    if cache.allocations!=0 || cache.filter_passes!=0 || cache.live_bytes!=0 { return false }
    request:=Native_Effect_Request{enabled=true,key=1,source_generation=1,region={16,16,128,96},clip={24,20,116,92},scale=1,sigma=4,depth=1}
    plan:Native_Effect_Plan
    for sigma in ([3]f32{1,4,8}) {
        request.sigma=sigma
        for scale in ([3]f32{1,1.5,2}) {
            request.scale=scale
            plan,ok=native_effect_plan(request)
            if !ok { return false }
            source:=make([]u8,int(plan.width*plan.height*4),allocator=context.temp_allocator)
            _,ok=effect_probe_frame(&renderers,&cache,plan,display,target,download,pixels,source,true,true)
            if !ok || !effect_probe_reference(plan,source,pixels,true) { return false }
        }
    }

	// A retained custom geometry surface keeps the same geometry handle while
	// its pixels change. The effect key must include the resolved payload
	// revision, causing a fresh capture/filter pass for the replacement data.
	geometry_owner, geometry_draw, geometry_ok := effect_probe_geometry_surface(&rt)
	if !geometry_ok { return false }
	geometry_segments := [1]alicorn.GPU_Surface_Line_Segment{{
		start={18, 34}, end={176, 34}, thickness=48, color={0.92, 0.12, 0.16, 1},
	}}
	if !alicorn.gpu_surface_update_geometry(&rt, geometry_owner, geometry_segments[:], nil) { return false }
	geometry_handle := alicorn.paint_geometry_handle_for_node(rt.nodes[geometry_owner])
	geometry_prefix := [1]alicorn.Paint_Command{geometry_draw}
	geometry_region := alicorn.Rect{12, 10, 180, 90}
	geometry_clip := alicorn.Rect{0, 0, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT}
	geometry_generation := native_effect_prefix_generation_for_runtime(
		&rt, geometry_prefix[:], geometry_region, geometry_clip, 1, 1, 4)
	geometry_request := Native_Effect_Request{
		enabled=true, key=73, source_generation=geometry_generation,
		region=geometry_region, clip=geometry_clip, scale=1, sigma=4, depth=1,
	}
	geometry_plan, geometry_plan_ok := native_effect_plan(geometry_request)
	if !geometry_plan_ok { return false }
	geometry_source := make([]u8, int(geometry_plan.width*geometry_plan.height*4), allocator=context.temp_allocator)
	geometry_cache := native_effect_make(device, EFFECT_PROBE_BUDGET)
	defer native_effect_reset(&geometry_cache)
	geometry_passes_before := geometry_cache.filter_passes
	geometry_output_before := geometry_cache.output_generation
	_, ok = effect_probe_frame(&renderers, &geometry_cache, geometry_plan, geometry_prefix[:],
		target, download, pixels, geometry_source, true, false, backdrop=true)
	if !ok || geometry_cache.filter_passes < geometry_passes_before+2 ||
		geometry_cache.output_generation != geometry_output_before+1 { return false }
	first_pixels := make([]u8, len(pixels), allocator=context.temp_allocator)
	first_source := make([]u8, len(geometry_source), allocator=context.temp_allocator)
	copy(first_pixels, pixels)
	copy(first_source, geometry_source)

	// Identical content should re-use the completed capture and filtered result.
	stable_generation := native_effect_prefix_generation_for_runtime(
		&rt, geometry_prefix[:], geometry_region, geometry_clip, 1, 1, 4)
	if stable_generation != geometry_generation { return false }
	stable_hits, stable_passes := geometry_cache.cache_hits, geometry_cache.filter_passes
	_, ok = effect_probe_frame(&renderers, &geometry_cache, geometry_plan, geometry_prefix[:],
		target, download, pixels, geometry_source, true, false, backdrop=true)
	if !ok || geometry_cache.cache_hits != stable_hits+1 || geometry_cache.filter_passes != stable_passes { return false }
	for value, index in pixels { if value != first_pixels[index] { return false } }
	for value, index in geometry_source { if value != first_source[index] { return false } }

	old_payload, old_payload_ok := alicorn.gpu_surface_payload_resolve(&rt, geometry_handle)
	geometry_segments[0].color = {0.1, 0.28, 0.96, 1}
	if !alicorn.gpu_surface_update_geometry(&rt, geometry_owner, geometry_segments[:], nil) { return false }
	new_handle := alicorn.paint_geometry_handle_for_node(rt.nodes[geometry_owner])
	new_payload, new_payload_ok := alicorn.gpu_surface_payload_resolve(&rt, new_handle)
	if !old_payload_ok || !new_payload_ok || new_handle != geometry_handle || new_payload.revision <= old_payload.revision { return false }
	updated_generation := native_effect_prefix_generation_for_runtime(
		&rt, geometry_prefix[:], geometry_region, geometry_clip, 1, 1, 4)
	if updated_generation == geometry_generation { return false }
	geometry_request.source_generation = updated_generation
	updated_plan, updated_plan_ok := native_effect_plan(geometry_request)
	if !updated_plan_ok || updated_plan.width != geometry_plan.width || updated_plan.height != geometry_plan.height { return false }
	updated_passes_before, updated_output_before := geometry_cache.filter_passes, geometry_cache.output_generation
	_, ok = effect_probe_frame(&renderers, &geometry_cache, updated_plan, geometry_prefix[:],
		target, download, pixels, geometry_source, true, false, backdrop=true)
	if !ok || geometry_cache.filter_passes < updated_passes_before+2 ||
		geometry_cache.output_generation != updated_output_before+1 { return false }
	source_changed, output_changed := false, false
	for value, index in geometry_source { if value != first_source[index] { source_changed = true; break } }
	for value, index in pixels { if value != first_pixels[index] { output_changed = true; break } }
	if !source_changed || !output_changed { return false }
	copy(first_pixels, pixels)
	copy(first_source, geometry_source)
	updated_hits, updated_passes := geometry_cache.cache_hits, geometry_cache.filter_passes
	_, ok = effect_probe_frame(&renderers, &geometry_cache, updated_plan, geometry_prefix[:],
		target, download, pixels, geometry_source, true, false, backdrop=true)
	if !ok || geometry_cache.cache_hits != updated_hits+1 || geometry_cache.filter_passes != updated_passes { return false }
	for value, index in pixels { if value != first_pixels[index] { return false } }
	for value, index in geometry_source { if value != first_source[index] { return false } }
	fmt.println("effects_geometry_payload_revision PASS", "stable_handle", true,
		"payload_revision", old_payload.revision, new_payload.revision,
		"capture_refreshed", source_changed, "output_changed", output_changed, "unchanged_cache_hit", true)

    generation,allocations,passes:=cache.output_generation,cache.allocations,cache.filter_passes
    uploads:=cache.vertex_upload_bytes
    for _ in 0..<100 { if native_effect_prepare(&cache,plan)!=.Cached { return false } }
    if cache.output_generation!=generation || cache.allocations!=allocations || cache.filter_passes!=passes { return false }
    fmt.println("effects_unchanged","attempts",100,"new_passes",0,"new_allocations",0,"new_submissions",0)
    previous:=make([]u8,len(pixels),allocator=context.temp_allocator)
    copy(previous,pixels)
    changed:=make([]alicorn.Paint_Command,len(display),allocator=context.temp_allocator)
    copy(changed,display)
    changed[2].payload=alicorn.Surface_Paint{fill={0,1,0,0.6}}
    plan.source_generation+=1
    source:=make([]u8,int(plan.width*plan.height*4),allocator=context.temp_allocator)
    _,ok=effect_probe_frame(&renderers,&cache,plan,changed,target,download,pixels,source,true,true)
    if !ok || !effect_probe_reference(plan,source,pixels,true) { return false }
    if cache.vertex_upload_bytes!=uploads { fmt.println("effects_source_change_reuploaded_filter_mesh"); return false }
    difference:=false
    for value,i in pixels { if value!=previous[i] { difference=true; break } }
    if !difference { fmt.println("effects_source_change_was_invisible"); return false }
    copy(previous,pixels)
    // Retained and freshly repainted output must agree byte-for-byte.
    _,ok=effect_probe_frame(&renderers,&cache,plan,changed,target,download,pixels,nil,true,true)
    if !ok { return false }
    for value,i in pixels { if value!=previous[i] { return false } }
    native_effect_reset(&cache)
    _,ok=effect_probe_frame(&renderers,&cache,plan,changed,target,download,pixels,nil,true,true)
    if !ok { return false }
    for value,i in pixels { if value!=previous[i] { return false } }
    // An abandoned generation must not become a valid retained output.
    plan.source_generation+=1
    if native_effect_prepare(&cache,plan)!=.Render { return false }
    native_effect_abort(&cache)
    if native_effect_prepare(&cache,plan)!=.Render { return false }
    native_effect_abort(&cache)
    native_effect_reset(&cache)
    fmt.println("effects_retirement","live_bytes",cache.live_bytes)
    request.scale=1; request.sigma=4; request.region={96,56,192,144}; request.clip=request.region
    plan,ok=native_effect_plan(request)
    if !ok { return false }
    for mode in 0..<4 {
        encodes,waits: [40]i64
        native_effect_reset(&cache)
        cache=native_effect_make(device,EFFECT_PROBE_BUDGET)
        before_allocations,before_passes:=cache.allocations,cache.filter_passes
        warm_render_passes:=0
        for i in 0..<41 {
            if mode==2 { plan.source_generation+=1 }
            scene:=display
            if mode==1 { scene=analytic }
            var_output:[]u8
            if i==0 { var_output=pixels }
            timing,rendered:=effect_probe_frame(&renderers,&cache,plan,scene,target,download,var_output,nil,mode>=2,false,backdrop=true)
            if !rendered { return false }
            if i==0 {
                fmt.println("effects_first_frame","mode",mode,"encode_ns",timing.encode_ns,"submit_wait_ns",timing.submit_wait_ns,"render_passes",timing.render_passes)
                names:=[4]string{"flat","analytic-shadow","blur-cold","blur-retained"}
                if !effect_probe_ppm(fmt.tprintf("out/retained-effects/%s.ppm",names[mode]),pixels) { return false }
            } else { encodes[i-1]=timing.encode_ns; waits[i-1]=timing.submit_wait_ns; warm_render_passes=timing.render_passes }
        }
        slice.sort(encodes[:]); slice.sort(waits[:])
        fmt.println("effects_warm","mode",mode,"samples",len(encodes),
            "encode_p50_ns",effect_probe_percentile(encodes[:],0.50),
            "encode_p95_ns",effect_probe_percentile(encodes[:],0.95),
            "encode_p99_ns",effect_probe_percentile(encodes[:],0.99),
            "submit_wait_p50_ns",effect_probe_percentile(waits[:],0.50),
            "submit_wait_p95_ns",effect_probe_percentile(waits[:],0.95),
            "submit_wait_p99_ns",effect_probe_percentile(waits[:],0.99),
            "render_passes",warm_render_passes,"allocations",cache.allocations-before_allocations,"filter_passes",cache.filter_passes-before_passes,
            "live_bytes",cache.live_bytes,"peak_bytes",cache.peak_bytes,"effect_upload_bytes_total",cache.vertex_upload_bytes)
    }
    tiny:=native_effect_make(device,1)
    defer native_effect_reset(&tiny)
    if native_effect_prepare(&tiny,plan)!=.Fallback || tiny.live_bytes!=0 { return false }
    _,ok=effect_probe_frame(&renderers,&cache,plan,display,target,download,previous,nil,false,false)
    if !ok { return false }
    _,ok=effect_probe_frame(&renderers,&tiny,plan,display,target,download,pixels,nil,true,false)
    if !ok { return false }
    for value,i in pixels { if value!=previous[i] { return false } }
    fmt.println("effects_gpu_validation PASS","dense_gaussian_reference_cases",9,"cache_equals_fresh",true,"budget_fallback",true,"nesting_limit",1)

    // Issue #105: optional scene-local lighting above paint.
    _ = os.make_directory("out/lighting")
    scaled_target := sdl3.CreateGPUTexture(device, {type=.D2, format=.R8G8B8A8_UNORM,
        usage={.COLOR_TARGET}, width=EFFECT_PROBE_WIDTH*2, height=EFFECT_PROBE_HEIGHT*2,
        layer_count_or_depth=1, num_levels=1, sample_count=._1})
    if scaled_target == nil { return false }
    defer sdl3.ReleaseGPUTexture(device, scaled_target)
    scaled_download := sdl3.CreateGPUTransferBuffer(device, {usage=.DOWNLOAD,
        size=EFFECT_PROBE_WIDTH*EFFECT_PROBE_HEIGHT*4*4})
    if scaled_download == nil { return false }
    defer sdl3.ReleaseGPUTransferBuffer(device, scaled_download)
    native_renderers := Native_Validation_Renderers{text=renderers.text, geometry=renderers.geometry, solid=renderers.solid}
    if !effect_probe_lighting_validation(&native_renderers, &rt, device, target, scaled_target, download, scaled_download) {
        return false
    }
    return true
}

// ---------------------------------------------------------------------------
// Issue #105: experimental scene-local lighting above paint.
//
// The probe drives the production path: the Runtime emits the boundary, the
// effects compositor captures the prefix, and draw_display_list composites at
// the marker. The analytic-relief scene is the baseline under the same camera.
// ---------------------------------------------------------------------------

EFFECT_LIGHTING_GROUP :: alicorn.Material_Group_ID(7)
EFFECT_LIGHTING_SAMPLES :: 40
EFFECT_LIGHTING_WARMUP :: 4

effect_probe_ppm_sized :: proc(path: string, pixels: []u8, width, height: int) -> bool {
	builder := strings.builder_make(allocator=context.temp_allocator)
	fmt.sbprintf(&builder, "P6\n%d %d\n255\n", width, height)
	for i in 0..<width*height {
		for c in 0..<3 { strings.write_byte(&builder, pixels[i*4+c]) }
	}
	return os.write_entire_file(path, strings.to_string(builder)) == nil
}

effect_probe_pixel_at :: proc(pixels: []u8, width, x, y: int) -> [3]u8 {
	index := (y*width+x)*4
	return {pixels[index], pixels[index+1], pixels[index+2]}
}

effect_probe_pixels_differ :: proc(a, b: []u8) -> (count: int, worst: int) {
	for index := 0; index+3 < len(a) && index+3 < len(b); index += 4 {
		delta := 0
		for c in 0..<3 {
			d := int(a[index+c])-int(b[index+c])
			if d < 0 { d = -d }
			if d > delta { delta = d }
		}
		if delta > 0 { count += 1 }
		if delta > worst { worst = delta }
	}
	return
}

effect_probe_pixels_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) { return false }
	for value, index in a { if value != b[index] { return false } }
	return true
}

effect_probe_pixel_hash :: proc(pixels: []u8) -> u64 {
	hash := u64(1469598103934665603)
	for value in pixels { hash = alicorn.hash_mix(hash, u64(value)) }
	return hash
}

// effect_probe_lighting_scene describes the same two-surface dogfood scene in
// three presentation modes:
// - lighting: flat material fills plus one declared lighting group and light set
// - relief: the existing per-surface analytic relief material, no declaration
// Text lives inside both panels so the capture proves glyph legibility.
effect_probe_lighting_scene :: proc(
	rt: ^alicorn.Runtime,
	light_center: [2]f32,
	light_count: int,
	relief_material: alicorn.Material_ID,
	lighting: bool,
	lighting_shadows := true,
) -> bool {
	alicorn.invalidate_root(rt, "lighting probe scene")
	ui, build := alicorn.begin_frame(rt)
	if !build { return false }
	alicorn.container_begin(
		&ui, .Root, label="lighting-probe-root",
		style=alicorn.layout_style(.Column,
			width=EFFECT_PROBE_WIDTH, height=EFFECT_PROBE_HEIGHT, padding=14, gap=12),
		color=alicorn.Color{0.105, 0.125, 0.17, 1},
	)
	alicorn.text(&ui, "Scene-local lighting prototype",
		style=alicorn.layout_style(.Row, width=EFFECT_PROBE_WIDTH-28, height=24),
		color=alicorn.Color{0.87, 0.91, 0.99, 1})
	if lighting {
		lights: [alicorn.LIGHTING_MAX_LIGHTS]alicorn.Lighting_Light
		offsets := [alicorn.LIGHTING_MAX_LIGHTS][2]f32{
			{0, 0}, {48, 34}, {-42, 30}, {24, -30},
		}
		for index in 0..<min(light_count, alicorn.LIGHTING_MAX_LIGHTS) {
			lights[index] = alicorn.Lighting_Light{
				position={light_center[0]+offsets[index][0], light_center[1]+offsets[index][1]},
				height=5.0,
				color={1.0, 0.94, 0.84, 1},
				intensity=1.8,
				radius=18,
			}
		}
		if !alicorn.lighting_group(&ui, EFFECT_LIGHTING_GROUP, lights[:max(light_count, 1)], ambient=0.48, shadows=lighting_shadows) {
			return false
		}
	}
	// The raised card is nested inside the recessed well: the card occludes a
	// wedge of the well, which is exactly the cross-surface shadow the current
	// per-surface analytic relief cannot express.
	raised_material := relief_material if !lighting else alicorn.MATERIAL_FLAT
	well := alicorn.surface_begin(
		&ui, .Surface, label="lighting-recessed-well",
		style=alicorn.layout_style(.Column, width=EFFECT_PROBE_WIDTH-28, height=160, padding=18, gap=8),
		shape=alicorn.surface_shape_uniform_corner_radius(16),
		material=raised_material,
		physical_height=-0.9,
		material_group=EFFECT_LIGHTING_GROUP,
		fill=alicorn.Color{0.17, 0.21, 0.29, 1},
	)
	if well == 0 { return false }
	alicorn.text(&ui, "Recessed well",
		style=alicorn.layout_style(.Row, width=EFFECT_PROBE_WIDTH-64, height=20),
		color=alicorn.Color{0.84, 0.89, 0.98, 1})
	alicorn.container_begin(&ui, .Container, label="lighting-probe-row",
		style=alicorn.layout_style(.Row, width=EFFECT_PROBE_WIDTH-64, height=92, gap=14, align=.Start))
	card := alicorn.surface_begin(
		&ui, .Surface, label="lighting-raised-card",
		style=alicorn.layout_style(.Column, width=160, height=88, padding=12, gap=6),
		shape=alicorn.surface_shape_uniform_corner_radius(12),
		material=raised_material,
		physical_height=2.0,
		material_group=EFFECT_LIGHTING_GROUP,
		fill=alicorn.Color{0.33, 0.39, 0.52, 1},
	)
	if card == 0 { return false }
	alicorn.text(&ui, "Raised card",
		style=alicorn.layout_style(.Row, width=136, height=20),
		color=alicorn.Color{0.97, 0.98, 1, 1})
	alicorn.text(&ui, "casts a shadow",
		style=alicorn.layout_style(.Row, width=136, height=18),
		color=alicorn.Color{0.78, 0.84, 0.94, 1})
	alicorn.surface_end(&ui)
	alicorn.text(&ui,
		"The raised card occludes the\nrecessed well below and to its\nright. Text stays crisp.",
		style=alicorn.layout_style(.Column, width=140, height=80),
		color=alicorn.Color{0.72, 0.79, 0.9, 1})
	alicorn.container_end(&ui)
	alicorn.surface_end(&ui)
	alicorn.text(&ui, "Ordinary paint outside the group stays unmodulated.",
		style=alicorn.layout_style(.Row, width=EFFECT_PROBE_WIDTH-28, height=20),
		color=alicorn.Color{0.62, 0.7, 0.84, 1})
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	return true
}

// effect_probe_lighting_frame drives the production host path for one frame.
effect_probe_lighting_frame :: proc(
	renderers: ^Native_Validation_Renderers,
	effects: ^Native_Retained_Effects,
	display: []alicorn.Paint_Command,
	target: ^sdl3.GPUTexture,
	width, height: sdl3.Uint32,
	scale: f32,
	download: ^sdl3.GPUTransferBuffer,
	pixels: []u8,
	serial: u64,
) -> (timing: Effect_Probe_Timing, ok: bool) {
	device := renderers.solid.device
	command := sdl3.AcquireGPUCommandBuffer(device)
	if command == nil {
		fmt.println("lighting_frame_fail", "step", "acquire")
		return
	}
	submitted := false
	defer if !submitted { _ = sdl3.CancelGPUCommandBuffer(command); native_retained_effects_abort(effects) }
	started := time.now()
	clear := make_color_target(target, sdl3.FColor{0.055, 0.07, 0.1, 1}, false)
	clear_pass := sdl3.BeginGPURenderPass(command, &clear, 1, nil)
	if clear_pass == nil {
		fmt.println("lighting_frame_fail", "step", "clear")
		return
	}
	sdl3.EndGPURenderPass(clear_pass)
	timing.render_passes += 1
	if !draw_display_list(
		command, target, width, height,
		&renderers.text, &renderers.geometry, &renderers.solid,
		display, scale, scale,
		clear_background=false,
		retained_effects=effects,
	) {
		fmt.println("lighting_frame_fail", "step", "draw")
		return
	}
	blend_renderers := Blend_Validation_Renderers{text=renderers.text, geometry=renderers.geometry, solid=renderers.solid}
	timing.render_passes += effect_probe_draw_passes(&blend_renderers, display)
	if len(pixels) > 0 {
		copy_pass := sdl3.BeginGPUCopyPass(command)
		if copy_pass == nil { return }
		sdl3.DownloadFromGPUTexture(copy_pass, {texture=target, w=width, h=height, d=1},
			{transfer_buffer=download, pixels_per_row=width, rows_per_layer=height})
		sdl3.EndGPUCopyPass(copy_pass)
	}
	timing.encode_ns = time.duration_nanoseconds(time.since(started))
	submit_start := time.now()
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command)
	submitted = true
	if fence == nil { native_retained_effects_abort(effects); return }
	defer sdl3.ReleaseGPUFence(device, fence)
	native_text_commit_submission(&renderers.text)
	native_surface_commit_submission(&renderers.geometry)
	native_solid_commit_submission(&renderers.solid)
	native_retained_effects_commit(effects, serial)
	fences := [1]^sdl3.GPUFence{fence}
	if !sdl3.WaitForGPUFences(device, true, &fences[0], 1) { return }
	native_retained_effects_note_completed(effects, serial)
	timing.submit_wait_ns = time.duration_nanoseconds(time.since(submit_start))
	if len(pixels) > 0 {
		mapped := sdl3.MapGPUTransferBuffer(device, download, false)
		if mapped == nil { return }
		bytes := cast([^]u8)mapped
		copy(pixels, bytes[:len(pixels)])
		sdl3.UnmapGPUTransferBuffer(device, download)
	}
	return timing, true
}

Effect_Probe_Lighting_Mode :: struct {
	name:        string,
	lighting:    bool,
	light_count: int,
	scale:       f32,
	shadows:     bool,
}

effect_probe_lighting_capture :: proc(
	renderers: ^Native_Validation_Renderers,
	rt: ^alicorn.Runtime,
	device: ^sdl3.GPUDevice,
	relief_material: alicorn.Material_ID,
	mode: Effect_Probe_Lighting_Mode,
	light_center: [2]f32,
	target: ^sdl3.GPUTexture,
	download: ^sdl3.GPUTransferBuffer,
	width, height: sdl3.Uint32,
	pixels: []u8,
	serial: u64,
) -> (ok: bool) {
	if !effect_probe_lighting_scene(rt, light_center, mode.light_count, relief_material, mode.lighting, mode.shadows) {
		fmt.println("lighting_probe_fail", "step", "scene", "mode", mode.name)
		return false
	}
	view, view_ok := alicorn.paint_display_list(rt)
	if !view_ok {
		fmt.println("lighting_probe_fail", "step", "display list", "mode", mode.name)
		return false
	}
	if !effect_probe_lighting_capture_display(renderers, device, view.commands, mode, target, download,
		width, height, pixels, serial) {
		fmt.println("lighting_probe_fail", "step", "capture frame", "mode", mode.name)
		return false
	}
	return true
}

// effect_probe_lighting_capture_display renders one already-composed display
// list through a fresh effects cache. Using the same retained list twice
// isolates compositor determinism from description/layout settling.
effect_probe_lighting_capture_display :: proc(
	renderers: ^Native_Validation_Renderers,
	device: ^sdl3.GPUDevice,
	display: []alicorn.Paint_Command,
	mode: Effect_Probe_Lighting_Mode,
	target: ^sdl3.GPUTexture,
	download: ^sdl3.GPUTransferBuffer,
	width, height: sdl3.Uint32,
	pixels: []u8,
	serial: u64,
) -> (ok: bool) {
	effects := native_retained_effects_make(device, composite_format=.R8G8B8A8_UNORM)
	defer native_retained_effects_destroy(&effects, device_already_idle=true)
	_, ok = effect_probe_lighting_frame(renderers, &effects, display, target, width, height,
		mode.scale, download, pixels, serial)
	return ok
}

effect_probe_lighting_validation :: proc(
	renderers: ^Native_Validation_Renderers,
	rt: ^alicorn.Runtime,
	device: ^sdl3.GPUDevice,
	target: ^sdl3.GPUTexture,
	scaled_target: ^sdl3.GPUTexture,
	download: ^sdl3.GPUTransferBuffer,
	scaled_download: ^sdl3.GPUTransferBuffer,
) -> bool {
	relief_material := alicorn.style_material_register(rt, alicorn.Style_Material{
		kind=.Analytic_Relief, bevel_width=5, bevel_strength=0.8,
		inner_shadow_strength=0.45, outer_shadow_strength=0.5, outer_shadow_radius=10,
	})
	if relief_material == alicorn.MATERIAL_FLAT {
		fmt.println("lighting_probe_fail", "step", "material")
		return false
	}
	light_center := [2]f32{70, 60}

	std := make([]u8, EFFECT_PROBE_WIDTH*EFFECT_PROBE_HEIGHT*4, allocator=context.temp_allocator)
	second := make([]u8, len(std), allocator=context.temp_allocator)
	relief := make([]u8, len(std), allocator=context.temp_allocator)
	contrast := make([]u8, len(std), allocator=context.temp_allocator)
	reduced := make([]u8, len(std), allocator=context.temp_allocator)
	scaled_pixels := make([]u8, EFFECT_PROBE_WIDTH*EFFECT_PROBE_HEIGHT*4*4, allocator=context.temp_allocator)
	scaled_relief := make([]u8, len(scaled_pixels), allocator=context.temp_allocator)

	standard := Effect_Probe_Lighting_Mode{name="lighting-1light-1x", lighting=true, light_count=1, scale=1, shadows=true}
	relief_mode := Effect_Probe_Lighting_Mode{name="relief-1x", lighting=false, light_count=0, scale=1, shadows=false}
	// Warm the lighting pipeline and shared text atlas once. The measured
	// determinism contract starts from a created pipeline, exactly like the
	// steady-state host.
	warmup := make([]u8, len(std), allocator=context.temp_allocator)
	if !effect_probe_lighting_capture(renderers, rt, device, relief_material, standard, light_center,
		target, download, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT, warmup, 0) { return false }
	if !effect_probe_lighting_capture(renderers, rt, device, relief_material, standard, light_center,
		target, download, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT, std, 1) { return false }
	// The identical retained display list through a second independent cache
	// must reproduce the first capture byte for byte.
	stable_view, stable_ok := alicorn.paint_display_list(rt)
	if !stable_ok { return false }
	stable_display := make([]alicorn.Paint_Command, len(stable_view.commands), allocator=context.temp_allocator)
	copy(stable_display, stable_view.commands)
	if !effect_probe_lighting_capture_display(renderers, device, stable_display, standard,
		target, download, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT, second, 3) { return false }
	third := make([]u8, len(std), allocator=context.temp_allocator)
	if !effect_probe_lighting_capture_display(renderers, device, stable_display, standard,
		target, download, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT, third, 4) { return false }
	if !effect_probe_pixels_equal(second, third) {
		diff_count, diff_worst := effect_probe_pixels_differ(second, third)
		fmt.println("lighting_determinism FAIL", "reason", "second and third captures differed",
			"changed_pixels", diff_count, "worst", diff_worst)
		return false
	}
	if !effect_probe_lighting_capture(renderers, rt, device, relief_material, relief_mode, light_center,
		target, download, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT, relief, 2) { return false }
	if !effect_probe_pixels_equal(std, second) {
		_ = effect_probe_ppm_sized("out/lighting/debug-std.ppm", std, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT)
		_ = effect_probe_ppm_sized("out/lighting/debug-second.ppm", second, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT)
		diff_count, diff_worst := effect_probe_pixels_differ(std, second)
		for index := 0; index+3 < len(std); index += 4 {
			if std[index] != second[index] || std[index+1] != second[index+1] || std[index+2] != second[index+2] {
				pixel := index/4
				fmt.println("lighting_determinism FAIL", "reason", "independent caches differed",
					"changed_pixels", diff_count, "worst", diff_worst,
					"first_pixel", pixel%EFFECT_PROBE_WIDTH, pixel/EFFECT_PROBE_WIDTH,
					"a", effect_probe_pixel_at(std, EFFECT_PROBE_WIDTH, pixel%EFFECT_PROBE_WIDTH, pixel/EFFECT_PROBE_WIDTH),
					"b", effect_probe_pixel_at(second, EFFECT_PROBE_WIDTH, pixel%EFFECT_PROBE_WIDTH, pixel/EFFECT_PROBE_WIDTH))
				break
			}
		}
		return false
	}
	lighting_vs_relief, lighting_worst := effect_probe_pixels_differ(std, relief)
	if lighting_vs_relief < 400 || lighting_worst < 8 {
		fmt.println("lighting_visual FAIL", "changed_pixels", lighting_vs_relief, "worst_channel", lighting_worst)
		return false
	}

	// Accessibility: increased contrast hardens penumbra and strengthens the
	// bevel; reduced motion removes moving shadow cues entirely.
	rt.root_accessibility_appearance.increased_contrast = true
	if !effect_probe_lighting_capture(renderers, rt, device, relief_material, standard, light_center,
		target, download, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT, contrast, 4) { return false }
	rt.root_accessibility_appearance.increased_contrast = false
	rt.root_accessibility_appearance.reduce_motion = true
	if !effect_probe_lighting_capture(renderers, rt, device, relief_material, standard, light_center,
		target, download, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT, reduced, 5) { return false }
	rt.root_accessibility_appearance.reduce_motion = false
	contrast_changed, _ := effect_probe_pixels_differ(std, contrast)
	reduced_changed, _ := effect_probe_pixels_differ(std, reduced)
	if contrast_changed == 0 || reduced_changed == 0 {
		fmt.println("lighting_accessibility FAIL", "contrast_changed", contrast_changed, "reduced_changed", reduced_changed)
		return false
	}

	// 2x device scale exercises the same logical scene at physical size.
	scaled := Effect_Probe_Lighting_Mode{name="lighting-1light-2x", lighting=true, light_count=1, scale=2, shadows=true}
	scaled_relief_mode := Effect_Probe_Lighting_Mode{name="relief-2x", lighting=false, light_count=0, scale=2, shadows=false}
	if !effect_probe_lighting_capture(renderers, rt, device, relief_material, scaled, light_center,
		scaled_target, scaled_download, EFFECT_PROBE_WIDTH*2, EFFECT_PROBE_HEIGHT*2, scaled_pixels, 6) { return false }
	if !effect_probe_lighting_capture(renderers, rt, device, relief_material, scaled_relief_mode, light_center,
		scaled_target, scaled_download, EFFECT_PROBE_WIDTH*2, EFFECT_PROBE_HEIGHT*2, scaled_relief, 7) { return false }
	scaled_diff, scaled_worst := effect_probe_pixels_differ(scaled_pixels, scaled_relief)
	if scaled_diff < 1200 || scaled_worst < 8 {
		fmt.println("lighting_visual_2x FAIL", "changed_pixels", scaled_diff, "worst_channel", scaled_worst)
		return false
	}

	// Zero-cost when unused: a flat scene without a declaration emits no marker
	// and performs no compositor work.
	lighting_emits_before := rt.lighting_emits
	if !effect_probe_lighting_scene(rt, light_center, 0, alicorn.Material_ID(relief_material), false) {
		// A scene without lighting also has no marker; the scene builder
		// reports marker presence, so reaching here means a marker leaked.
		fmt.println("lighting_zero_cost FAIL", "reason", "flat scene reported a boundary")
		return false
	}
	_ = lighting_emits_before
	if rt.lighting_marker_present {
		fmt.println("lighting_zero_cost FAIL", "reason", "flat scene kept a boundary")
		return false
	}
	{
		effects := native_retained_effects_make(device, composite_format=.R8G8B8A8_UNORM)
		defer native_retained_effects_destroy(&effects, device_already_idle=true)
		view, view_ok := alicorn.paint_display_list(rt)
		if !view_ok { return false }
		flat_pixels := make([]u8, len(std), allocator=context.temp_allocator)
		if _, frame_ok := effect_probe_lighting_frame(renderers, &effects, view.commands, target,
			EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT, 1, download, flat_pixels, 8); !frame_ok { return false }
		for &slot in effects.slots {
			if slot.allocations != 0 || slot.lighting_prepares != 0 || slot.lighting_composites != 0 ||
			   slot.filter_passes != 0 || slot.live_bytes != 0 {
				fmt.println("lighting_zero_cost FAIL", "reason", "unused effects cache did work")
				return false
			}
		}
	}

	// A declared group with no qualifying surface emits nothing.
	invalidate_lighting_declaration_only(rt)
	{
		ui, build := alicorn.begin_frame(rt)
		if !build { return false }
		alicorn.container_begin(&ui, .Root, label="lighting-empty-root",
			style=alicorn.layout_style(.Column, width=EFFECT_PROBE_WIDTH, height=EFFECT_PROBE_HEIGHT),
			color=alicorn.Color{0.05, 0.06, 0.09, 1})
		lights := [1]alicorn.Lighting_Light{{
			position={80, 60}, height=2, color={1, 1, 1, 1}, intensity=1, radius=6,
		}}
		if !alicorn.lighting_group(&ui, EFFECT_LIGHTING_GROUP, lights[:], ambient=0.4) { return false }
		alicorn.text(&ui, "No surfaces for the declared group.",
			style=alicorn.layout_style(.Row, width=300, height=20))
		alicorn.container_end(&ui)
		alicorn.end_frame(&ui)
		if rt.lighting_marker_present { return false }
	}

	fmt.println("lighting_validation PASS",
		"deterministic", true,
		"lighting_vs_relief_changed_pixels", lighting_vs_relief,
		"lighting_vs_relief_worst_channel", lighting_worst,
		"scaled_changed_pixels", scaled_diff,
		"contrast_changed_pixels", contrast_changed,
		"reduced_motion_changed_pixels", reduced_changed,
		"pixel_hash", effect_probe_pixel_hash(std),
		"relief_pixel_hash", effect_probe_pixel_hash(relief))

	if !effect_probe_ppm_sized("out/lighting/lighting-1light-1x.ppm", std, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT) { return false }
	if !effect_probe_ppm_sized("out/lighting/lighting-1light-1x-run2.ppm", second, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT) { return false }
	if !effect_probe_ppm_sized("out/lighting/relief-1x.ppm", relief, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT) { return false }
	if !effect_probe_ppm_sized("out/lighting/lighting-contrast-1x.ppm", contrast, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT) { return false }
	if !effect_probe_ppm_sized("out/lighting/lighting-reduced-motion-1x.ppm", reduced, EFFECT_PROBE_WIDTH, EFFECT_PROBE_HEIGHT) { return false }
	if !effect_probe_ppm_sized("out/lighting/lighting-1light-2x.ppm", scaled_pixels, EFFECT_PROBE_WIDTH*2, EFFECT_PROBE_HEIGHT*2) { return false }
	if !effect_probe_ppm_sized("out/lighting/relief-2x.ppm", scaled_relief, EFFECT_PROBE_WIDTH*2, EFFECT_PROBE_HEIGHT*2) { return false }

	// Idle contract: after the host acknowledges the last submission, the
	// runtime must not request another description or submission while the
	// application is unchanged.
	alicorn.gpu_surface_frame_consumed(rt)
	alicorn.frame_submission_succeeded(rt)
	if alicorn.frame_needs_submission(rt) {
		fmt.println("lighting_idle FAIL", "reason", "runtime still wants a submission at rest")
		return false
	}
	if ui, build := alicorn.begin_frame(rt); build {
		alicorn.end_frame(&ui)
		fmt.println("lighting_idle FAIL", "reason", "runtime rebuilt an unchanged description")
		return false
	}
	fmt.println("lighting_idle PASS", "pending_submission", false, "idle_rebuild", false,
		"gpu_submits", rt.stats.gpu_submits)

	// Cost matrix: 1x/2x with one and four lights against the relief baseline.
	modes := [8]Effect_Probe_Lighting_Mode{
		{name="relief-1x", lighting=false, light_count=0, scale=1},
		{name="relief-2x", lighting=false, light_count=0, scale=2},
		{name="lighting-1light-1x", lighting=true, light_count=1, scale=1, shadows=true},
		{name="lighting-4light-1x", lighting=true, light_count=4, scale=1, shadows=true},
		{name="lighting-1light-2x", lighting=true, light_count=1, scale=2, shadows=true},
		{name="lighting-4light-2x", lighting=true, light_count=4, scale=2, shadows=true},
		{name="lighting-1light-2x-noshadow", lighting=true, light_count=1, scale=2},
		{name="lighting-4light-2x-noshadow", lighting=true, light_count=4, scale=2},
	}
	for mode in modes {
		effects := native_retained_effects_make(device, composite_format=.R8G8B8A8_UNORM)
		defer native_retained_effects_destroy(&effects, device_already_idle=true)
		width := sdl3.Uint32(EFFECT_PROBE_WIDTH)*sdl3.Uint32(mode.scale)
		height := sdl3.Uint32(EFFECT_PROBE_HEIGHT)*sdl3.Uint32(mode.scale)
		mode_target := target
		mode_download := download
		mode_pixels := std
		if mode.scale == 2 {
			mode_target, mode_download = scaled_target, scaled_download
			mode_pixels = scaled_pixels
		}
		encodes: [EFFECT_LIGHTING_SAMPLES]i64
		waits: [EFFECT_LIGHTING_SAMPLES]i64
		serial := u64(100)
		allocations_before := 0
		for &slot in effects.slots { allocations_before += int(slot.allocations) }
		for sample in 0..<EFFECT_LIGHTING_SAMPLES+EFFECT_LIGHTING_WARMUP {
			// Move the light every frame so the matrix reports the full
			// capture + encode cost, not only cached rest frames.
			light := [2]f32{light_center[0]+f32(sample%7)*2.5, light_center[1]+f32(sample%5)*1.5}
			if !effect_probe_lighting_scene(rt, light, mode.light_count, alicorn.Material_ID(relief_material), mode.lighting, mode.shadows) {
				return false
			}
			view, view_ok := alicorn.paint_display_list(rt)
			if !view_ok { return false }
			serial += 1
			timing, frame_ok := effect_probe_lighting_frame(renderers, &effects, view.commands,
				mode_target, width, height, mode.scale, mode_download, nil, serial)
			if !frame_ok { return false }
			if sample >= EFFECT_LIGHTING_WARMUP {
				encodes[sample-EFFECT_LIGHTING_WARMUP] = timing.encode_ns
				waits[sample-EFFECT_LIGHTING_WARMUP] = timing.submit_wait_ns
			}
		}
		slice.sort(encodes[:])
		slice.sort(waits[:])
		// Cached rest: the same declaration and content must not re-encode. The
		// moving loop ended on another light position, so settle once before
		// measuring the cached frame.
		serial += 1
		if !effect_probe_lighting_scene(rt, light_center, mode.light_count, alicorn.Material_ID(relief_material), mode.lighting, mode.shadows) {
			return false
		}
		settle_view, settle_ok := alicorn.paint_display_list(rt)
		if !settle_ok { return false }
		if _, settle_frame_ok := effect_probe_lighting_frame(renderers, &effects, settle_view.commands,
			mode_target, width, height, mode.scale, mode_download, nil, serial); !settle_frame_ok { return false }
		if !effect_probe_lighting_scene(rt, light_center, mode.light_count, alicorn.Material_ID(relief_material), mode.lighting, mode.shadows) {
			return false
		}
		view, view_ok := alicorn.paint_display_list(rt)
		if !view_ok { return false }
		composites_before := effects.slots[0].composites+effects.slots[1].composites
		captures_before := effects.slots[0].lighting_captures+effects.slots[1].lighting_captures
		serial += 1
		rest_timing, rest_ok := effect_probe_lighting_frame(renderers, &effects, view.commands,
			mode_target, width, height, mode.scale, mode_download, nil, serial)
		if !rest_ok { return false }
		rest_composites := effects.slots[0].composites+effects.slots[1].composites - composites_before
		rest_captures := effects.slots[0].lighting_captures+effects.slots[1].lighting_captures - captures_before
		allocations_after := 0
		live_bytes := u64(0)
		peak_bytes := u64(0)
		for &slot_state in effects.slots {
			allocations_after += int(slot_state.allocations)
			live_bytes += slot_state.live_bytes
			peak_bytes = max(peak_bytes, slot_state.peak_bytes)
		}
		_ = mode_pixels
		fmt.println("lighting_cost", "mode", mode.name, "scale", mode.scale, "lights", mode.light_count,
			"shadow_cues", mode.shadows,
			"encode_p50_ns", effect_probe_percentile(encodes[:], 0.50),
			"encode_p95_ns", effect_probe_percentile(encodes[:], 0.95),
			"submit_wait_p50_ns", effect_probe_percentile(waits[:], 0.50),
			"submit_wait_p95_ns", effect_probe_percentile(waits[:], 0.95),
			"effect_passes_per_frame", effect_probe_lighting_mode_passes(mode),
			"rest_encode_ns", rest_timing.encode_ns,
			"rest_submit_wait_ns", rest_timing.submit_wait_ns,
			"rest_render_passes", rest_timing.render_passes,
			"rest_capture_reused", rest_captures == 0, "rest_composites", rest_composites,
			"allocations", allocations_after-allocations_before,
			"live_bytes", live_bytes, "peak_bytes", peak_bytes)
	}
	return true
}

effect_probe_lighting_mode_passes :: proc(mode: Effect_Probe_Lighting_Mode) -> int {
	// clear target + ordinary paint runs + (lighting: clear capture, capture
	// paint, composite). The probe reports the compositor delta explicitly.
	if mode.lighting { return 3 }
	return 0
}

invalidate_lighting_declaration_only :: proc(rt: ^alicorn.Runtime) {
	alicorn.invalidate_root(rt, "lighting declaration probe")
}

RunRetainedEffectsValidation :: proc() {
    driver:cstring=nil
    when ODIN_OS==.Darwin { driver="metal" }
    when ODIN_OS==.Windows { driver="direct3d12" }
    when ODIN_OS==.Linux { driver="vulkan" }
    for arg in os.args[1:] {
        switch arg {
        case "--driver=metal": driver="metal"
        case "--driver=vulkan": driver="vulkan"
        case "--driver=direct3d12": driver="direct3d12"
        case: fail("unknown effects-validation argument")
        }
    }
    // SDL GPU requires the video subsystem. No window/swapchain is created,
    // but initialization failure is reported rather than treated as a skip.
    if !sdl3.Init(sdl3.INIT_VIDEO) { fail("effects SDL initialization failed") }
    defer sdl3.Quit()
    if !effect_probe_device(driver) { fail("retained effects experiment failed") }
}
