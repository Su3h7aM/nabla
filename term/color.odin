package term

// ANSI_16 is the classic 16-color ANSI palette (dark 0-7, bright 8-15), the
// reference palette for the 16/8-color reductions (ECMA-48 SGR 30-37/40-47
// and 90-97/100-107).
ANSI_16 :: [16][3]u8 {
	{0, 0, 0},
	{128, 0, 0},
	{0, 128, 0},
	{128, 128, 0},
	{0, 0, 128},
	{128, 0, 128},
	{0, 128, 128},
	{192, 192, 192},
	{128, 128, 128},
	{255, 0, 0},
	{0, 255, 0},
	{255, 255, 0},
	{0, 0, 255},
	{255, 0, 255},
	{0, 255, 255},
	{255, 255, 255},
}

// CUBE_LEVELS are the channel values of the xterm 6x6x6 color cube.
CUBE_LEVELS :: [6]u8{0, 95, 135, 175, 215, 255}

// _rgb_to_256 maps an RGB triple to the nearest xterm-256 entry by squared
// distance: the closest color cube entry or, when nearer, a grayscale ramp step.
_rgb_to_256 :: proc(color: RGB_Color) -> u8 {
	levels := CUBE_LEVELS
	nearest_level :: proc(levels: [6]u8, channel: u8) -> int {
		best := 0
		for level, i in levels {
			if abs(int(level) - int(channel)) < abs(int(levels[best]) - int(channel)) {
				best = i
			}
		}
		return best
	}
	cube := u8(16 + 36 * nearest_level(levels, color[0]) + 6 * nearest_level(levels, color[1]) + nearest_level(levels, color[2]))
	average := (int(color[0]) + int(color[1]) + int(color[2])) / 3
	ramp := u8(232 + clamp((average - 3) / 10, 0, 23))
	if _rgb_distance(color, _xterm_256_to_rgb(ramp)) < _rgb_distance(color, _xterm_256_to_rgb(cube)) {
		return ramp
	}
	return cube
}

_rgb_distance :: proc(a, b: RGB_Color) -> int {
	red := int(a[0]) - int(b[0])
	green := int(a[1]) - int(b[1])
	blue := int(a[2]) - int(b[2])
	return red * red + green * green + blue * blue
}

// _xterm_256_to_rgb decodes an xterm-256 palette index to its RGB triple:
// 0-15 the ANSI_16 palette, 16-231 the 6x6x6 color cube, 232-255 the
// 24-step grayscale ramp.
_xterm_256_to_rgb :: proc(index: u8) -> RGB_Color {
	switch {
	case index < 16:
		palette := ANSI_16
		return RGB_Color(palette[index])
	case index < 232:
		cube := int(index) - 16
		levels := CUBE_LEVELS
		return RGB_Color{levels[cube / 36], levels[(cube % 36) / 6], levels[cube % 6]}
	case:
		gray := u8(8 + (int(index) - 232) * 10)
		return RGB_Color{gray, gray, gray}
	}
}

// _nearest_ansi maps an RGB triple to the nearest of the first count ANSI
// colors (8 = basic, 16 = basic + bright), by squared distance.
_nearest_ansi :: proc(color: RGB_Color, count: int) -> u8 {
	palette := ANSI_16
	best := u8(0)
	best_distance := max(int)
	for i in 0 ..< count {
		red_delta := int(color[0]) - int(palette[i][0])
		green_delta := int(color[1]) - int(palette[i][1])
		blue_delta := int(color[2]) - int(palette[i][2])
		distance := red_delta * red_delta + green_delta * green_delta + blue_delta * blue_delta
		if distance < best_distance {
			best_distance = distance
			best = u8(i)
		}
	}
	return best
}

// _ansi_4bit maps an ANSI palette index (0-15) to its SGR code: 30-37/90-97
// for foreground, 40-47/100-107 for background.
_ansi_4bit :: proc(prefix: u8, index: u8) -> u8 {
	base: u8
	if prefix == 38 {
		base = 30
	} else {
		base = 40
	}
	if index >= 8 {
		return base + 60 + (index - 8)
	}
	return base + index
}
