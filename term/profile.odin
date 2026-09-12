package term

import "core:terminal"

// Target_Profile materializes the capability model the serialization uses:
// the color depth. The default comes from core:terminal's startup detection
// (NO_COLOR / COLORTERM / TERM — its @(init) sets color_depth and
// color_enabled); an explicit override wins by constructing or editing a
// Target_Profile.
Target_Profile :: struct {
	color_depth: Color_Depth,
}

// Color_Depth is core:terminal's capability enum. The package uses the same
// values so a profile is expressible without a second vocabulary, and the
// terminal-detection work stays in the package that owns it.
Color_Depth :: terminal.Color_Depth

// profile_default materializes a Target_Profile from core:terminal's
// startup detection. NO_COLOR (color_enabled == false) collapses the depth
// to .None so the serialization emits no color.
profile_default :: proc() -> Target_Profile {
	depth := terminal.color_depth
	if !terminal.color_enabled {
		depth = .None
	}
	return {color_depth = depth}
}
