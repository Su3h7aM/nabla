#+test
package ai

import "core:testing"

@(test)
test_media_detect_names_the_format_by_signature :: proc(t: ^testing.T) {
	Case :: struct {
		data:  string,
		media: Provider_Media,
		ok:    bool,
	}
	cases := []Case {
		{"\x89PNG\r\n\x1a\nrest", .PNG, true},
		{"\xff\xd8\xff\xe0rest", .JPEG, true},
		{"GIF87arest", .GIF, true},
		{"GIF89arest", .GIF, true},
		{"RIFF\x00\x00\x00\x00WEBPrest", .WebP, true},
		{"RIFF\x00\x00\x00\x00WAVErest", {}, false},
		{"%PDF-1.7", .PDF, true},
		{"RIFF", {}, false},
		{"", {}, false},
		{"plain text", {}, false},
	}
	for c in cases {
		media, ok := Provider_Media_Detect(transmute([]u8)c.data)
		testing.expect_value(t, ok, c.ok)
		testing.expect_value(t, media, c.media)
	}
}

@(test)
test_validate_request_checks_attachments :: proc(t: ^testing.T) {
	file := Provider_Attachment {
		Media = .PNG,
		Name  = "a.png",
		Data  = transmute([]u8)string("abc"),
	}
	no_data := Provider_Attachment {
		Media = .PNG,
		Name  = "a.png",
	}
	no_name := Provider_Attachment {
		Media = .PNG,
		Data  = transmute([]u8)string("abc"),
	}
	files := []Provider_Attachment{file}
	Case :: struct {
		message: Provider_Message,
		want:    Provider_Request_Error,
	}
	cases := []Case {
		{{Role = .User, Attachments = files}, .None},
		{{Role = .User, Content = "look", Attachments = files}, .None},
		{{Role = .Tool, Tool_Call_ID = "c1", Attachments = files}, .None},
		{{Role = .User, Content = "look", Attachments = {no_data}}, .Invalid_Message},
		{{Role = .User, Content = "look", Attachments = {no_name}}, .Invalid_Message},
		{{Role = .Assistant, Content = "text", Attachments = files}, .Invalid_Message},
		{{Role = .User}, .Invalid_Message},
	}
	for c in cases {
		messages := []Provider_Message{c.message}
		request := Provider_Request {
			API              = .OpenAI_Chat_Completions,
			Model_Present    = true,
			Model            = "m",
			Messages_Present = true,
			Messages         = messages,
		}
		testing.expect_value(t, Provider_Validate_Request(request), c.want)
	}
}
