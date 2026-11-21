#+build !windows

package dpi_transition

import "core:fmt"

// The hosted DPI transition acceptance injects Win32 window messages, so it is
// Windows-only. Other platforms still need the fixture package to compile.
main :: proc() {
	fmt.println("dpi_transition SKIP (Windows-only fixture)")
}
