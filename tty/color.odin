package tty

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

// _rgb_to_256 maps an RGB triple to the nearest xterm-256 cube entry (the
// 6x6x6 color cube; the grayscale ramp is not approximated).
_rgb_to_256 :: proc(c: RGB_Color) -> u8 {
	step :: proc(v: u8) -> int {
		return (int(v) * 5 + 127) / 255
	}
	return u8(16 + 36 * step(c[0]) + 6 * step(c[1]) + step(c[2]))
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
		level :: proc(v: int) -> u8 {
			if v == 0 {
				return 0
			}
			return u8(55 + v * 40)
		}
		return RGB_Color{level(cube / 36), level((cube % 36) / 6), level(cube % 6)}
	case:
		gray := u8(8 + (int(index) - 232) * 10)
		return RGB_Color{gray, gray, gray}
	}
}

// _nearest_ansi maps an RGB triple to the nearest of the first count ANSI
// colors (8 = basic, 16 = basic + bright), by squared distance.
_nearest_ansi :: proc(c: RGB_Color, count: int) -> u8 {
	palette := ANSI_16
	best := u8(0)
	best_distance := max(int)
	for i in 0 ..< count {
		dr := int(c[0]) - int(palette[i][0])
		dg := int(c[1]) - int(palette[i][1])
		db := int(c[2]) - int(palette[i][2])
		distance := dr * dr + dg * dg + db * db
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
