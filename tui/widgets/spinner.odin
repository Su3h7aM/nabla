package widgets

import "core:time"

SPINNER_BRAILLE :: []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// spinner_frame returns the frame of frames shown after elapsed, advancing one
// frame every interval and wrapping. It returns "" when frames is empty or
// interval is not positive. A negative elapsed shows the first frame. The caller
// owns the clock and the result borrows from frames.
spinner_frame :: proc(frames: []string, elapsed, interval: time.Duration) -> string {
	if len(frames) == 0 || interval <= 0 {
		return ""
	}
	return frames[int(max(elapsed, 0) / interval) % len(frames)]
}
