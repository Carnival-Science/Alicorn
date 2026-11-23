package alicorn_sdl_gpu

import "core:testing"

// The primary-window topmost option is generic host policy: the application
// provides a default, and the command line may enable or clear it for a run.
// Parsing is pure so it can be tested without creating a native window.

@(test)
test_always_on_top_follows_application_default :: proc(t: ^testing.T) {
	args := []string{"application.exe"}
	testing.expect(t, !native_always_on_top_requested(args, false),
		"an application that did not request topmost stays plain")
	testing.expect(t, native_always_on_top_requested(args, true),
		"an application default is preserved when no argument is present")
}

@(test)
test_always_on_top_argument_enables_and_clears :: proc(t: ^testing.T) {
	enable := []string{"application.exe", "--always-on-top"}
	testing.expect(t, native_always_on_top_requested(enable, false),
		"--always-on-top should enable a generic host option")

	clear := []string{"application.exe", "--no-always-on-top"}
	testing.expect(t, !native_always_on_top_requested(clear, true),
		"--no-always-on-top should clear an application default")

	// The host parses arguments in order; the last explicit option wins so a
	// launch script can append an override without rewriting the application.
	last_wins := []string{"application.exe", "--always-on-top", "--no-always-on-top"}
	testing.expect(t, !native_always_on_top_requested(last_wins, true),
		"the last explicit option should win")
}
