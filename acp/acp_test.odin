package acp
import "core:testing"
@(test)
test_frame_chunk_boundaries_and_multiple_frames :: proc(t: ^testing.T) {
	decoder := frame_decoder_init(128)
	defer frame_decoder_destroy(&decoder)
	frames: [dynamic]string
	defer frame_strings_destroy(&frames)
	part_a := []byte {
		'{',
		'\"',
		'j',
		's',
		'o',
		'n',
		'r',
		'p',
		'c',
		'\"',
		':',
		'\"',
		'2',
		'.',
		'0',
		'\"',
		',',
		'\"',
		'm',
		'e',
		't',
		'h',
		'o',
		'd',
		'\"',
		':',
		'\"',
		'o',
		'n',
		'e',
		'\"',
		'}',
	}
	part_b := []byte {
		'\n',
		'{',
		'\"',
		'j',
		's',
		'o',
		'n',
		'r',
		'p',
		'c',
		'\"',
		':',
		'\"',
		'2',
		'.',
		'0',
		'\"',
		',',
		'\"',
		'm',
		'e',
		't',
		'h',
		'o',
		'd',
		'\"',
		':',
		'\"',
		't',
		'w',
		'o',
		'\"',
		'}',
		'\n',
	}
	testing.expect_value(t, frame_decoder_feed(&decoder, part_a[:10], &frames), Frame_Error.None)
	testing.expect_value(t, frame_decoder_feed(&decoder, part_a[10:], &frames), Frame_Error.None)
	testing.expect_value(t, frame_decoder_feed(&decoder, part_b, &frames), Frame_Error.None)
	testing.expect_value(t, len(frames), 2)
	testing.expect_value(t, frames[0], "{\"jsonrpc\":\"2.0\",\"method\":\"one\"}")
	testing.expect_value(t, frames[1], "{\"jsonrpc\":\"2.0\",\"method\":\"two\"}")
}
@(test)
test_frame_oversized_and_invalid_utf8 :: proc(t: ^testing.T) {
	decoder := frame_decoder_init(4)
	defer frame_decoder_destroy(&decoder)
	frames: [dynamic]string
	defer frame_strings_destroy(&frames)
	testing.expect_value(t, frame_decoder_feed(&decoder, []byte{'1', '2', '3', '4', '5'}, &frames), Frame_Error.Frame_Too_Large)
	frame_decoder_destroy(&decoder)
	decoder = frame_decoder_init(4)
	testing.expect_value(t, frame_decoder_feed(&decoder, []byte{0xff, '\n'}, &frames), Frame_Error.Invalid_UTF8)
	frame_decoder_destroy(&decoder)
}
@(test)
test_envelope_kinds_and_validation :: proc(t: ^testing.T) {
	request, request_err := parse_envelope("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"prompt\",\"params\":{}}")
	testing.expect_value(t, request_err, Envelope_Error.None)
	testing.expect_value(t, request.kind, Envelope_Kind.Request)
	testing.expect(t, request.id_present)
	destroy_envelope(&request)
	notification, notification_err := parse_envelope("{\"jsonrpc\":\"2.0\",\"method\":\"cancel\"}")
	testing.expect_value(t, notification_err, Envelope_Error.None)
	testing.expect_value(t, notification.kind, Envelope_Kind.Notification)
	destroy_envelope(&notification)
	response, response_err := parse_envelope("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":null}")
	testing.expect_value(t, response_err, Envelope_Error.None)
	testing.expect_value(t, response.kind, Envelope_Kind.Response)
	testing.expect(t, response.result_present)
	destroy_envelope(&response)
	_, invalid_json_err := parse_envelope("not-json")
	testing.expect_value(t, invalid_json_err, Envelope_Error.Invalid_JSON)
	_, invalid_version_err := parse_envelope("{\"jsonrpc\":\"1.0\",\"method\":\"x\"}")
	testing.expect_value(t, invalid_version_err, Envelope_Error.Invalid_Version)
	_, invalid_id_err := parse_envelope("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"x\"}")
	testing.expect_value(t, invalid_id_err, Envelope_Error.Invalid_ID)
	_, invalid_result_err := parse_envelope("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1,\"error\":{}}")
	testing.expect_value(t, invalid_result_err, Envelope_Error.Invalid_Result)
}
