package layout

fit :: proc "contextless" (minimum: Scalar = 0, maximum: Scalar = 0) -> Axis_Size {
	return Axis_Size{mode = .Fit, min = minimum, max = maximum}
}

grow :: proc "contextless" (weight: Scalar = 1, minimum: Scalar = 0, maximum: Scalar = 0) -> Axis_Size {
	return Axis_Size{mode = .Grow, min = minimum, max = maximum, weight = weight}
}

fixed :: proc "contextless" (value: Scalar) -> Axis_Size {
	return Axis_Size{mode = .Fixed, value = value}
}

percent :: proc "contextless" (fraction: Scalar, minimum: Scalar = 0, maximum: Scalar = 0) -> Axis_Size {
	return Axis_Size{mode = .Percent, value = fraction, min = minimum, max = maximum}
}

pad_all :: proc "contextless" (value: Scalar) -> Edges {
	return Edges{left = value, top = value, right = value, bottom = value}
}

pad_xy :: proc "contextless" (horizontal, vertical: Scalar) -> Edges {
	return Edges{left = horizontal, top = vertical, right = horizontal, bottom = vertical}
}

radius_all :: proc "contextless" (value: Scalar) -> Radius {
	return Radius{tl = value, tr = value, br = value, bl = value}
}

rgb :: proc "contextless" (r, g, b: u8) -> Color {
	return Color{r, g, b, 255}
}

rgba :: proc "contextless" (r, g, b, a: u8) -> Color {
	return Color{r, g, b, a}
}

gray :: proc "contextless" (value: u8, alpha: u8 = 255) -> Color {
	return Color{value, value, value, alpha}
}

opaque :: proc "contextless" (color: Color) -> Color {
	return Color{color.r, color.g, color.b, 255}
}

with_alpha :: proc "contextless" (color: Color, alpha: u8) -> Color {
	return Color{color.r, color.g, color.b, alpha}
}

/*
Linearly interpolate between two colors, `t == 0` returning `from` and `t == 1`
returning `to`. `t` outside `[0, 1]` extrapolates rather than clamping, matching
`math.lerp`.

This is the building block for a hover or pressed style: the application blends
toward a target color using `hovered`, rather than the library owning a
subtree-wide tint the way Clay's `overlayColor` does. Keeping the blend a pure
function here, instead of a second paint pass in the core, keeps command
emission a single deterministic walk.
*/
mix :: proc(from, to: Color, t: Scalar) -> Color {
	blend := proc(from, to: u8, t: Scalar) -> u8 {
		value := f32(from) + (f32(to) - f32(from)) * f32(t)
		return u8(clamp(value, 0, 255))
	}
	return Color{blend(from.r, to.r, t), blend(from.g, to.g, t), blend(from.b, to.b, t), blend(from.a, to.a, t)}
}
