#+build windows

package sdl3_window_frame

// SDL promotes an ALWAYS_ON_TOP window on mouse entry by re-asserting its
// rectangle through WIN_SetWindowPositionInternal (SDL_windowswindow.c,
// WIN_OnWindowEnter). That call derives the requested origin from the
// standard AdjustWindowRectExForDpi frame because SDL's own WM_NCCALCSIZE
// assumes the system frame is present.
//
// An Alicorn integrated title bar answers WM_NCCALCSIZE with a full-client
// rectangle, so the standard-frame caption and border inset is already part
// of the window rectangle. SDL's adjustment adds it a second time, and the
// window drifts up and to the left on every mouse re-entry. The first fix
// (bae58e9) intercepted that promotion in the native SDL_GPU subclass and
// set SWP_NOMOVE. Native SDL_GPU and hosted SDL3/WebGPU both subclass the
// SDL HWND for menus and chrome, so the predicate lives here once and each
// host calls it from its own WM_WINDOWPOSCHANGING hook before
// DefSubclassProc runs.

import "core:c"
import win "core:sys/windows"
import "vendor:sdl3"

// Context is the integrated-frame window a caller's subclass is protecting.
// frame_enabled is the host's own "custom non-client area is active" flag;
// menu_attached mirrors the bMenu argument SDL's WIN_AdjustWindowRectWithStyle
// derives from GetMenu(hwnd).
Context :: struct {
	hwnd:          win.HWND,
	window:        ^sdl3.Window,
	frame_enabled: bool,
	menu_attached: bool,
}

// standard_frame_inset returns the origin offset SDL's standard-frame
// adjustment would add for this window. The x/y values match the inset the
// integrated frame already covers, so they double as the promotion signature.
standard_frame_inset :: proc(ctx: Context) -> (offset: win.POINT, ok: bool) {
	if ctx.hwnd == nil || !ctx.frame_enabled { return {}, false }
	rect: win.RECT
	style := cast(win.DWORD)win.GetWindowLongW(ctx.hwnd, win.GWL_STYLE)
	ex_style := cast(win.DWORD)win.GetWindowLongW(ctx.hwnd, win.GWL_EXSTYLE)
	if !win.AdjustWindowRectExForDpi(
		&rect, style, win.BOOL(ctx.menu_attached), ex_style, win.GetDpiForWindow(ctx.hwnd),
	) { return {}, false }
	return win.POINT{x=rect.left, y=rect.top}, true
}

// preserve_topmost_promotion_position identifies SDL's automatic topmost
// promotion inside WM_WINDOWPOSCHANGING and applies SWP_NOMOVE so Windows
// keeps the current HWND rectangle.
//
// Discrimination matters more than the fix: a false positive would freeze a
// legitimate move or resize. A promotion is identified by all of:
//
//   * the host's integrated frame is active and the window is ALWAYS_ON_TOP;
//   * the request keeps size (SWP_NOSIZE) and does not activate
//     (SWP_NOACTIVATE), matching WIN_OnWindowEnter's flag set;
//   * the request is not a move (SWP_NOMOVE), resize/z-order-neutral
//     (SWP_NOZORDER), or frame change (SWP_FRAMECHANGED);
//   * the requested origin equals SDL's current position plus the standard
//     frame inset, which is exactly what WIN_AdjustWindowRect computes.
//
// Explicit moves and placements keep SWP_NOZORDER, resizes keep SWP_NOMOVE,
// DPI/frame updates keep SWP_FRAMECHANGED, and WIN_SetWindowAlwaysOnTop
// itself keeps SWP_NOMOVE, so none of them can satisfy the predicate.
// Windows may replace HWND_TOPMOST with an insertion HWND before sending
// WINDOWPOSCHANGING, so the z-order target is deliberately not inspected.
preserve_topmost_promotion_position :: proc(ctx: Context, position: ^win.WINDOWPOS) -> bool {
	if !ctx.frame_enabled || position == nil || ctx.hwnd == nil || ctx.window == nil { return false }
	required := win.UINT(win.SWP_NOSIZE | win.SWP_NOACTIVATE)
	excluded := win.UINT(win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_FRAMECHANGED)
	if (position.flags & required) != required || (position.flags & excluded) != 0 { return false }
	topmost := (sdl3.GetWindowFlags(ctx.window) & sdl3.WindowFlags{.ALWAYS_ON_TOP}) != sdl3.WindowFlags{}
	if !topmost { return false }
	offset, inset_ok := standard_frame_inset(ctx)
	if !inset_ok || (offset.x == 0 && offset.y == 0) { return false }
	x, y: c.int
	if !sdl3.GetWindowPosition(ctx.window, &x, &y) ||
		position.x != x+offset.x || position.y != y+offset.y { return false }
	position.flags |= win.SWP_NOMOVE
	return true
}
