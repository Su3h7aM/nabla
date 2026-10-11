#+test
#+private file
package acp

import "core:bufio"
import "core:strings"
import "core:testing"

// scan_frames reads every frame of wire the way a caller does and returns each frame with
// the reason frame_check gives for it. The frames are cloned out of the scanner's buffer.
scan_frames :: proc(t: ^testing.T, wire: string, frames: ^[dynamic]string, refusals: ^[dynamic]Frame_Error) {
	reader: strings.Reader
	scanner: bufio.Scanner
	frame_scanner_init(&scanner, strings.to_reader(&reader, wire), context.allocator)
	defer bufio.scanner_destroy(&scanner)
	for bufio.scan(&scanner) {
		text := bufio.scanner_text(&scanner)
		append(refusals, frame_check(text))
		append(frames, strings.clone(text))
	}
	testing.expect_value(t, bufio.scanner_error(&scanner), nil)
}

@(test)
test_frames_end_at_newline_and_drop_carriage_return :: proc(t: ^testing.T) {
	frames: [dynamic]string
	refusals: [dynamic]Frame_Error
	defer frame_strings_destroy(&frames)
	defer delete(refusals)

	scan_frames(t, "{\"method\":\"one\"}\r\n{\"method\":\"two\"}\n", &frames, &refusals)
	testing.expect_value(t, len(frames), 2)
	testing.expect_value(t, frames[0], "{\"method\":\"one\"}")
	testing.expect_value(t, frames[1], "{\"method\":\"two\"}")
	testing.expect_value(t, refusals[0], Frame_Error.None)
	testing.expect_value(t, refusals[1], Frame_Error.None)
}

@(test)
test_frame_larger_than_the_scanner_buffer_arrives_whole :: proc(t: ^testing.T) {
	frames: [dynamic]string
	refusals: [dynamic]Frame_Error
	defer frame_strings_destroy(&frames)
	defer delete(refusals)

	// Far larger than the first buffer and the default token limit: nothing truncates or refuses it.
	body, body_error := strings.repeat("a", 300 * 1024)
	testing.expect_value(t, body_error, nil)
	defer delete(body)
	wire := strings.concatenate({body, "\n"})
	defer delete(wire)
	scan_frames(t, wire, &frames, &refusals)
	testing.expect_value(t, len(frames), 1)
	testing.expect(t, len(frames) == 1 && frames[0] == body)
}

@(test)
test_refused_frames_do_not_hide_the_frames_behind_them :: proc(t: ^testing.T) {
	frames: [dynamic]string
	refusals: [dynamic]Frame_Error
	defer frame_strings_destroy(&frames)
	defer delete(refusals)

	scan_frames(t, "\xff\n\n{}\n", &frames, &refusals)
	testing.expect_value(t, len(refusals), 3)
	testing.expect(t, len(refusals) == 3 && refusals[0] == .Invalid_UTF8 && refusals[1] == .Empty_Frame && refusals[2] == .None)
	testing.expect(t, len(frames) == 3 && frames[2] == "{}")
}

@(test)
test_unterminated_tail_is_not_a_frame :: proc(t: ^testing.T) {
	frames: [dynamic]string
	refusals: [dynamic]Frame_Error
	defer frame_strings_destroy(&frames)
	defer delete(refusals)

	scan_frames(t, "{}\n{\"method\":\"cut", &frames, &refusals)
	testing.expect(t, len(frames) == 1 && frames[0] == "{}")
}
