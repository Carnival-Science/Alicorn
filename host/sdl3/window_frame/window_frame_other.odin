#+build !windows

package sdl3_window_frame

// The topmost-promotion hook only exists on Windows: SDL's mouse-entry
// promotion and the WM_NCCALCSIZE conflict it works around are Win32
// behavior. macOS and Linux hosts never call into this package.
