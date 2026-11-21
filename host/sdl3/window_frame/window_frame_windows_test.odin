#+build windows

package sdl3_window_frame

import "core:c"
import "core:testing"
import win "core:sys/windows"
import "vendor:sdl3"

topmost_test_window :: proc(t: ^testing.T) -> (window: ^sdl3.Window, ctx: Context) {
	window = sdl3.CreateWindow("Alicorn topmost promotion predicate", 320, 240, {.HIDDEN, .RESIZABLE})
	if window == nil {
		testing.expect(t, false, "hidden SDL window creation must succeed")
		return nil, {}
	}
	props := sdl3.GetWindowProperties(window)
	hwnd := cast(win.HWND)sdl3.GetPointerProperty(props, "SDL.window.win32.hwnd", nil)
	if hwnd == nil {
		testing.expect(t, false, "the SDL window must expose its Win32 handle")
		sdl3.DestroyWindow(window)
		return nil, {}
	}
	ctx = Context{hwnd=hwnd, window=window, frame_enabled=true}
	return window, ctx
}

// promotion_flags mirror WIN_OnWindowEnter's SetWindowPos call shape:
// SWP_NOSIZE | SWP_NOACTIVATE, plus SDL's copybits flag when that hint is
// disabled. The predicate must not depend on the extra flag.
promotion_flags :: proc() -> win.UINT {
	return win.UINT(win.SWP_NOSIZE | win.SWP_NOACTIVATE)
}

@(test)
test_topmost_promotion_predicate_matches_sdl_mouse_entry_only :: proc(t: ^testing.T) {
	if !sdl3.Init({.VIDEO}) { testing.expect(t, false, "SDL video initialization failed"); return }
	defer sdl3.Quit()
	window, ctx := topmost_test_window(t)
	if window == nil { return }
	defer sdl3.DestroyWindow(window)
	if !sdl3.SetWindowAlwaysOnTop(window, true) {
		testing.expect(t, false, "topmost transition must succeed")
		return
	}
	offset, inset_ok := standard_frame_inset(ctx)
	if !inset_ok {
		testing.expect(t, false, "the standard frame must be measurable")
		return
	}
	if offset.x == 0 && offset.y == 0 {
		// A system that reports a zero caption/border inset cannot exhibit the
		// drift this predicate protects against; there is nothing to assert.
		return
	}
	x, y: c.int
	if !sdl3.GetWindowPosition(window, &x, &y) {
		testing.expect(t, false, "the SDL window position must be readable")
		return
	}

	// Accepted: the exact request shape SDL's mouse-entry promotion sends.
	promotion := win.WINDOWPOS{
		hwnd=ctx.hwnd,
		x=x+offset.x, y=y+offset.y,
		flags=promotion_flags(),
	}
	testing.expect(t, preserve_topmost_promotion_position(ctx, &promotion),
		"SDL's topmost mouse-entry promotion must be preserved")
	testing.expect(t, (promotion.flags & win.SWP_NOMOVE) != 0,
		"the accepted promotion must stop moving the window")

	// Rejected: explicit placement keeps SWP_NOZORDER.
	explicit_move := win.WINDOWPOS{
		hwnd=ctx.hwnd,
		x=x+offset.x, y=y+offset.y,
		flags=win.UINT(win.SWP_NOSIZE | win.SWP_NOACTIVATE | win.SWP_NOZORDER),
	}
	testing.expect(t, !preserve_topmost_promotion_position(ctx, &explicit_move),
		"an explicit placement must keep its position request")
	// Rejected: a resize keeps SWP_NOMOVE from SDL.
	resize := win.WINDOWPOS{
		hwnd=ctx.hwnd,
		x=x+offset.x, y=y+offset.y,
		flags=win.UINT(win.SWP_NOSIZE | win.SWP_NOACTIVATE | win.SWP_NOMOVE),
	}
	testing.expect(t, !preserve_topmost_promotion_position(ctx, &resize),
		"a resize must not be treated as a promotion")
	// Rejected: a DPI or frame update keeps SWP_FRAMECHANGED.
	frame_change := win.WINDOWPOS{
		hwnd=ctx.hwnd,
		x=x+offset.x, y=y+offset.y,
		flags=win.UINT(win.SWP_NOSIZE | win.SWP_NOACTIVATE | win.SWP_FRAMECHANGED),
	}
	testing.expect(t, !preserve_topmost_promotion_position(ctx, &frame_change),
		"a frame change must not be treated as a promotion")
	// Rejected: the requested origin is not the standard-frame-adjusted one.
	already_client_origin := win.WINDOWPOS{hwnd=ctx.hwnd, x=x, y=y, flags=promotion_flags()}
	testing.expect(t, !preserve_topmost_promotion_position(ctx, &already_client_origin),
		"a request that already uses the client origin is not SDL's promotion")
	half_inset := win.WINDOWPOS{hwnd=ctx.hwnd, x=x+offset.x, y=y, flags=promotion_flags()}
	testing.expect(t, !preserve_topmost_promotion_position(ctx, &half_inset),
		"the promotion signature must match both coordinates")

	// Rejected: the integrated frame is not active.
	non_integrated := Context{hwnd=ctx.hwnd, window=window, frame_enabled=false}
	promotion.flags = promotion_flags()
	testing.expect(t, !preserve_topmost_promotion_position(non_integrated, &promotion),
		"system-decorated windows keep SDL's standard behavior")

	// Rejected: the window is not topmost, so SDL never promotes it this way.
	if !sdl3.SetWindowAlwaysOnTop(window, false) {
		testing.expect(t, false, "topmost rollback must succeed")
		return
	}
	promotion.flags = promotion_flags()
	testing.expect(t, !preserve_topmost_promotion_position(ctx, &promotion),
		"a non-topmost window cannot be promoted on mouse entry")
	if !sdl3.SetWindowAlwaysOnTop(window, true) {
		testing.expect(t, false, "topmost restoration must succeed")
		return
	}

	// Rejected: nil requests must not crash the subclass.
	testing.expect(t, !preserve_topmost_promotion_position(ctx, nil),
		"a nil WINDOWPOS must be ignored")
}
