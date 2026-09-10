#+build wasi
#+private
package term

// WASI has no terminal concept: the environment-detection machinery in
// internal_os.odin compiles and the color surface degrades to .None. This
// file mirrors the terminal_js.odin stub shape; upstream core:terminal has
// no wasi file (the pinned toolchain dev-2026-07a fails to check the wasi
// target without it), so this is the first platform stub added here.
_is_terminal :: proc "contextless" (handle: any) -> bool {
	return false
}

_init_terminal :: proc "contextless" () {
	color_depth = .None
}

_fini_terminal :: proc "contextless" () {  }
