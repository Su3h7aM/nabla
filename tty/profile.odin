package tty

// Target_Profile materializes the capability model the serialization uses:
// the color depth. The default comes from the environment through the
// package's startup detection (NO_COLOR / COLORTERM / TERM — the core
// copy's @(init) sets color_depth and color_enabled); an explicit override
// wins by constructing or editing a Target_Profile.
//
// The bottom-right cell is always reserved: the serializer never writes it
// (writing the corner can trigger autowrap scroll on some terminals). The
// draft's alternative policies were never implemented and are gone.
Target_Profile :: struct {
	color_depth: Color_Depth,
}

// profile_default materializes a Target_Profile from the environment,
// following the package's startup detection (NO_COLOR / COLORTERM / TERM).
// NO_COLOR (color_enabled == false) collapses the depth to .None so the
// serialization emits no color.
profile_default :: proc() -> Target_Profile {
	depth := color_depth
	if !color_enabled {
		depth = .None
	}
	return {color_depth = depth}
}
