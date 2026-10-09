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
