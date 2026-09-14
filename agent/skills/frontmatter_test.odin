#+test
package skills

import "core:testing"

@(test)
test_parse_metadata_plain_and_body_boundary :: proc(t: ^testing.T) {
	text := "---\r\nname: pdf\r\ndescription: Inspect PDF forms # catalog text\r\nlicense: MIT\r\n---\r\n\r\n# PDF\r\n"
	data := transmute([]u8)text
	metadata, load_error := parse_metadata(data, "pdf")
	defer metadata_destroy(&metadata)
	defer load_error_destroy(&load_error)
	testing.expect_value(t, load_error.kind, Error_Kind.None)
	testing.expect_value(t, metadata.name, "pdf")
	testing.expect_value(t, metadata.description, "Inspect PDF forms")
	testing.expect_value(t, string(data)[metadata.body_offset:], "\r\n# PDF\r\n")
}

@(test)
test_parse_metadata_quotes_and_folded_description :: proc(t: ^testing.T) {
	cases := []struct {
		data:        string,
		description: string,
	} {
		{"---\nname: 'pdf'\ndescription: \"Inspect\\u0020PDFs\"\n---\nbody", "Inspect PDFs"},
		{"---\nname: pdf\ndescription: >-\n  Inspect PDF files,\n  including forms.\n---\nbody", "Inspect PDF files, including forms."},
		{"---\nname: pdf\ndescription: |\n  Inspect PDFs.\n  Read forms.\n---\nbody", "Inspect PDFs. Read forms."},
	}
	for test_case in cases {
		metadata, load_error := parse_metadata(transmute([]u8)test_case.data, "pdf")
		testing.expect_value(t, load_error.kind, Error_Kind.None)
		testing.expect_value(t, metadata.description, test_case.description)
		metadata_destroy(&metadata)
		load_error_destroy(&load_error)
	}
}

@(test)
test_parse_metadata_rejects_invalid_identity_and_duplicates :: proc(t: ^testing.T) {
	cases := []struct {
		data: string,
		kind: Error_Kind,
	} {
		{"---\nname: PDF\ndescription: docs\n---\nbody", .Invalid_Metadata},
		{"---\nname: pdf\nname: pdf\ndescription: docs\n---\nbody", .Invalid_Metadata},
		{"---\nname: pdf\ndescription: [docs]\n---\nbody", .Unsupported_Metadata},
		{"---\nname: pdf\ndescription: docs", .Invalid_Metadata},
	}
	for test_case in cases {
		metadata, load_error := parse_metadata(transmute([]u8)test_case.data, "pdf")
		testing.expect_value(t, load_error.kind, test_case.kind)
		metadata_destroy(&metadata)
		load_error_destroy(&load_error)
	}
}

@(test)
test_skill_name_validation :: proc(t: ^testing.T) {
	valid := []string{"pdf", "code-review", "x1"}
	for name in valid { testing.expect(t, skill_name_valid(name)) }
	invalid := []string{"", "PDF", "-pdf", "pdf-", "pdf--forms", "pdf/forms"}
	for name in invalid { testing.expect(t, !skill_name_valid(name)) }
}
