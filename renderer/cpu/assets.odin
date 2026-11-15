package cpu_renderer

import alicorn "../../runtime"

Image_Quad :: proc(vertices: ^[dynamic]Vertex, draw: alicorn.Paint_Command, scale_x, scale_y: f32, target_w, target_h: int) -> bool {
	_, ok := draw.payload.(alicorn.Image_Paint)
	if !ok || scale_x <= 0 || scale_y <= 0 { return false }
	bounds := draw.bounds
	bounds.x += draw.translation[0]; bounds.y += draw.translation[1]
	x0, y0, x1, y1 := Logical_To_Pixel_Bounds(bounds, scale_x, scale_y)
	if x1 <= x0 || y1 <= y0 { return false }
	cx0, cy0, cx1, cy1 := Logical_To_Pixel_Bounds(draw.clip, scale_x, scale_y)
	left, top := max(x0, cx0, 0), max(y0, cy0, 0)
	right, bottom := min(x1, cx1, int(target_w)), min(y1, cy1, int(target_h))
	if right <= left || bottom <= top { return false }
	u0, v0 := f32(left-x0)/f32(x1-x0), f32(top-y0)/f32(y1-y0)
	u1, v1 := f32(right-x0)/f32(x1-x0), f32(bottom-y0)/f32(y1-y0)
	color := [4]f32{1, 1, 1, draw.opacity}
	a := Vertex{{f32(left), f32(top), 0}, color, {u0,v0}}
	b := Vertex{{f32(right), f32(top), 0}, color, {u1,v0}}
	c := Vertex{{f32(right), f32(bottom), 0}, color, {u1,v1}}
	d := Vertex{{f32(left), f32(bottom), 0}, color, {u0,v1}}
	append(vertices, a,b,c,a,c,d)
	return true
}

Hash_Image_Handle :: proc(h: u64, handle: alicorn.Image_Handle) -> u64 {
	return alicorn.hash_mix(h, u64(handle))
}


Image_Mesh_Fingerprint :: proc(display: []alicorn.Paint_Command, scale_x, scale_y: f32, target_w, target_h: int) -> u64 {
	h := alicorn.hash_mix(1469598103934665603, u64(len(display)))
	h = alicorn.hash_mix(h, u64(transmute(u32)scale_x)); h = alicorn.hash_mix(h, u64(transmute(u32)scale_y))
	h = alicorn.hash_mix(h, u64(target_w)); h = alicorn.hash_mix(h, u64(target_h))
	for command, index in display {
		paint, ok := command.payload.(alicorn.Image_Paint)
		if !ok { continue }
		h = Hash_Image_Handle(h, paint.image); h = alicorn.hash_mix(h, u64(index))
		h = Hash_Rect(h, command.bounds); h = Hash_Rect(h, command.clip)
		h = alicorn.hash_mix(h, u64(transmute(u32)command.opacity))
		h = alicorn.hash_mix(h, u64(transmute(u32)command.translation[0])); h = alicorn.hash_mix(h, u64(transmute(u32)command.translation[1]))
	}
	return h
}
Icon_Quad :: proc(vertices: ^[dynamic]Vertex, draw: alicorn.Paint_Command, scale_x, scale_y: f32, target_w, target_h: int) -> (entry: alicorn.Icon_Atlas_Entry, added: bool) {
    icon, ok := draw.payload.(alicorn.Icon_Paint)
    if !ok || scale_x <= 0 || scale_y <= 0 { return }
    bounds := draw.bounds
    bounds.x += draw.translation[0]; bounds.y += draw.translation[1]
    x0, y0, x1, y1 := Logical_To_Pixel_Bounds(bounds, scale_x, scale_y)
    if x1 <= x0 || y1 <= y0 { return }
    entry, ok = alicorn.icon_atlas_lookup(icon.id, max(x1-x0, y1-y0))
    if !ok { return }
    cx0, cy0, cx1, cy1 := Logical_To_Pixel_Bounds(draw.clip, scale_x, scale_y)
    left, top := max(x0, cx0, 0), max(y0, cy0, 0)
    right, bottom := min(x1, cx1, int(target_w)), min(y1, cy1, int(target_h))
    if right <= left || bottom <= top { return }
    page := alicorn.ICON_ATLAS_PAGES[entry.page]
    u0 := (f32(entry.x)+f32(left-x0)*f32(entry.size)/f32(x1-x0))/f32(page.width)
    v0 := (f32(entry.y)+f32(top-y0)*f32(entry.size)/f32(y1-y0))/f32(page.height)
    u1 := (f32(entry.x)+f32(right-x0)*f32(entry.size)/f32(x1-x0))/f32(page.width)
    v1 := (f32(entry.y)+f32(bottom-y0)*f32(entry.size)/f32(y1-y0))/f32(page.height)
    color := [4]f32{icon.color.r, icon.color.g, icon.color.b, icon.color.a*draw.opacity}
    a := Vertex{{f32(left), f32(top), 0}, color, {u0,v0}}
    b := Vertex{{f32(right), f32(top), 0}, color, {u1,v0}}
    c := Vertex{{f32(right), f32(bottom), 0}, color, {u1,v1}}
    d := Vertex{{f32(left), f32(bottom), 0}, color, {u0,v1}}
    append(vertices, a,b,c,a,c,d)
    return entry, true
}

Icon_Mesh_Fingerprint :: proc(display: []alicorn.Paint_Command, scale_x, scale_y: f32, target_w, target_h: int) -> u64 {
    h := alicorn.hash_mix(1469598103934665603, u64(len(display)))
    h = alicorn.hash_mix(h, u64(transmute(u32)scale_x)); h = alicorn.hash_mix(h, u64(transmute(u32)scale_y))
    h = alicorn.hash_mix(h, u64(target_w)); h = alicorn.hash_mix(h, u64(target_h))
    for draw, index in display {
        icon, ok := draw.payload.(alicorn.Icon_Paint)
        if !ok { continue }
        h = alicorn.hash_mix(h, u64(index)); h = alicorn.hash_mix(h, u64(icon.id))
        h = Hash_Rect(h, draw.bounds); h = Hash_Rect(h, draw.clip)
        h = Hash_Color(h, icon.color)
        h = alicorn.hash_mix(h, u64(transmute(u32)draw.opacity))
        for axis in draw.translation { h = alicorn.hash_mix(h, u64(transmute(u32)axis)) }
    }
    return h
}
