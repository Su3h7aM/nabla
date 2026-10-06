#+test
package ai

import "base:runtime"

import "core:strings"
import "core:testing"
import "core:time"

import "nabla:http"

// Classification is a pure decision over the facts a failed attempt observed, so
// these cases name the facts and the class they must produce. Nothing here asserts
// a message: wording is presentation, and the decision is the behavior.
Classification_Case :: struct {
	name:     string,
	evidence: Provider_Evidence,
	expected: Provider_Failure_Class,
}

@(test)
test_failure_classification :: proc(t: ^testing.T) {
	cases := []Classification_Case {
		// A code beats the status that carried it.
		{
			"quota inside a 429",
			{api = .OpenAI_Chat_Completions, kind = .HTTP, head_seen = true, status = 429, rejection = {code = "insufficient_quota"}},
			.Quota,
		},
		{
			"context limit inside a 400",
			{api = .OpenAI_Chat_Completions, kind = .HTTP, head_seen = true, status = 400, rejection = {code = "context_length_exceeded"}},
			.Context_Overflow,
		},
		{
			"policy refusal",
			{api = .OpenAI_Responses, kind = .HTTP, head_seen = true, status = 400, rejection = {code = "content_policy_violation"}},
			.Content_Policy,
		},
		{
			"anthropic overload",
			{api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 529, rejection = {code = "overloaded_error"}},
			.Provider_Unavailable,
		},
		{
			"anthropic rate limit",
			{api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 429, rejection = {code = "rate_limit_error"}},
			.Rate_Limited,
		},
		{"anthropic billing error", {api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 402, rejection = {code = "billing_error"}}, .Quota},
		{
			"anthropic missing resource",
			{api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 404, rejection = {code = "not_found_error"}},
			.Not_Found,
		},
		{
			"anthropic request conflict",
			{api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 409, rejection = {code = "conflict_error"}},
			.Provider_Unavailable,
		},
		{
			"anthropic API error",
			{api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 500, rejection = {code = "api_error"}},
			.Provider_Unavailable,
		},
		{
			"anthropic timeout",
			{api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 504, rejection = {code = "timeout_error"}},
			.Provider_Unavailable,
		},
		{
			"anthropic oversized request",
			{api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 413, rejection = {code = "request_too_large"}},
			.Payload_Too_Large,
		},
		{
			"anthropic permission is authentication",
			{api = .Anthropic_Messages, kind = .HTTP, head_seen = true, status = 403, rejection = {code = "permission_error"}},
			.Authentication,
		},
		// One code covers several causes, so the wording is read for the one case it
		// can name.
		{
			"anthropic prompt too long",
			{
				api = .Anthropic_Messages,
				kind = .HTTP,
				head_seen = true,
				status = 400,
				rejection = {code = "invalid_request_error", message = "prompt is too long: 210000 tokens > 200000 maximum"},
			},
			.Context_Overflow,
		},
		{
			"anthropic invalid request",
			{
				api = .Anthropic_Messages,
				kind = .HTTP,
				head_seen = true,
				status = 400,
				rejection = {code = "invalid_request_error", message = "max_tokens: field required"},
			},
			.Invalid_Request,
		},
		{
			"anthropic API spend limit",
			{
				api = .Anthropic_Messages,
				kind = .HTTP,
				head_seen = true,
				status = 400,
				rejection = {code = "invalid_request_error", message = "You have reached your specified API usage limits this month"},
			},
			.Quota,
		},
		{
			"anthropic workspace spend limit",
			{
				api = .Anthropic_Messages,
				kind = .HTTP,
				head_seen = true,
				status = 400,
				rejection = {code = "invalid_request_error", message = "You have reached your specified workspace API usage limits this month"},
			},
			.Quota,
		},
		{
			"anthropic spend-limit wording not at the start",
			{
				api = .Anthropic_Messages,
				kind = .HTTP,
				head_seen = true,
				status = 400,
				rejection = {code = "invalid_request_error", message = "Error: You have reached your specified API usage limits"},
			},
			.Invalid_Request,
		},
		// A mention of tokens is not evidence of overflow.
		{
			"generic 400 that mentions tokens",
			{
				api = .OpenAI_Chat_Completions,
				kind = .HTTP,
				head_seen = true,
				status = 400,
				rejection = {message = "max_output_tokens must be at least 16 tokens"},
			},
			.Invalid_Request,
		},
		{"rate limit", {kind = .HTTP, head_seen = true, status = 429}, .Rate_Limited},
		{"unauthenticated", {kind = .HTTP, head_seen = true, status = 401}, .Authentication},
		{"forbidden", {kind = .HTTP, head_seen = true, status = 403}, .Authentication},
		{"payment required", {kind = .HTTP, head_seen = true, status = 402}, .Quota},
		{"armored envelope", {kind = .HTTP, head_seen = true, status = 413}, .Payload_Too_Large},
		{"conflict is transient", {kind = .HTTP, head_seen = true, status = 409}, .Provider_Unavailable},
		{"not found", {kind = .HTTP, head_seen = true, status = 404}, .Not_Found},
		{"provider error", {kind = .HTTP, head_seen = true, status = 500}, .Provider_Unavailable},
		{"unrecognized redirect", {kind = .HTTP, head_seen = true, status = 302}, .Unknown},
		{"outside the defined classes", {kind = .HTTP, head_seen = true, status = 999}, .Unknown},
		{"no head", {kind = .HTTP, status = 429}, .Unknown},
		// A refusal inside a stream that opened successfully.
		{
			"an error event with a known code",
			{
				api = .OpenAI_Responses,
				kind = .Stream,
				head_seen = true,
				status = 200,
				event = Provider_Error_Kind.API_Error,
				rejection = {code = "context_length_exceeded"},
			},
			.Context_Overflow,
		},
		{
			"an error event with nothing recognized",
			{api = .OpenAI_Responses, kind = .Stream, head_seen = true, status = 200, event = Provider_Error_Kind.API_Error},
			.Unknown,
		},
		{"unusable output", {kind = .Stream, event = Provider_Error_Kind.Invalid_Data}, .Invalid_Output},
		{"unsupported tool output", {kind = .Stream, event = Provider_Error_Kind.Unsupported_Tool_Output}, .Invalid_Output},
		{"a stream without its marker", {kind = .Stream, event = Provider_Error_Kind.Stream_Truncated}, .Incomplete_Stream},
		{"a stream with no event at all", {kind = .Stream}, .Unknown},
		// The transport.
		{"a connection that broke", {kind = .Transport, cause = .IO}, .Provider_Unavailable},
		{"a peer that was never reachable", {kind = .Transport, cause = .Connection}, .Provider_Unavailable},
		{"a peer that did not authenticate", {kind = .Transport, cause = .Trust}, .Untrusted_Connection},
		{"a local TLS configuration", {kind = .Transport, cause = .Configuration}, .Untrusted_Connection},
		{"a TLS failure", {kind = .TLS, cause = .Trust}, .Untrusted_Connection},
		// A local outcome keeps its own meaning whatever a provider wrote.
		{"cancellation with provider text", {kind = .Cancelled, head_seen = true, status = 500, rejection = {code = "insufficient_quota"}}, .None},
		{"an expired deadline", {kind = .Timed_Out, head_seen = true, status = 429}, .None},
		{"a request this client refused", {kind = .Invalid_Request}, .None},
	}

	for test_case in cases {
		got := provider_classify_failure(test_case.evidence)
		testing.expectf(t, got == test_case.expected, "%s: expected %v, got %v", test_case.name, test_case.expected, got)
	}
}

OpenAI_Failure_Code_Case :: struct {
	code:     string,
	expected: Provider_Failure_Class,
}

@(test)
test_openai_failure_codes :: proc(t: ^testing.T) {
	cases := []OpenAI_Failure_Code_Case {
		{"context_length_exceeded", .Context_Overflow},
		{"insufficient_quota", .Quota},
		{"credit_balance_exhausted", .Quota},
		{"usage_limit_exceeded", .Quota},
		{"organization_usage_limit_exceeded", .Quota},
		{"organization_spend_limit_exceeded", .Quota},
		{"project_spend_limit_exceeded", .Quota},
		{"invalid_api_key", .Authentication},
		{"authentication_error", .Authentication},
		{"model_not_found", .Not_Found},
		{"not_found_error", .Not_Found},
		{"content_policy_violation", .Content_Policy},
		{"bio_policy", .Content_Policy},
		{"cyber_policy", .Content_Policy},
		{"misalignment_policy_violation", .Content_Policy},
		{"image_content_policy_violation", .Content_Policy},
		{"server_error", .Provider_Unavailable},
		{"server_is_overloaded", .Provider_Unavailable},
		{"vector_store_timeout", .Provider_Unavailable},
		{"service_unavailable_error", .Provider_Unavailable},
		{"rate_limit_exceeded", .Rate_Limited},
		{"slow_down", .Rate_Limited},
		{"rate_limit_error", .Rate_Limited},
		{"invalid_prompt", .Invalid_Request},
		{"data_residency_mismatch", .Invalid_Request},
		{"invalid_image", .Invalid_Request},
		{"invalid_image_format", .Invalid_Request},
		{"invalid_base64_image", .Invalid_Request},
		{"invalid_image_url", .Invalid_Request},
		{"image_too_large", .Invalid_Request},
		{"image_too_small", .Invalid_Request},
		{"image_parse_error", .Invalid_Request},
		{"invalid_image_mode", .Invalid_Request},
		{"image_file_too_large", .Invalid_Request},
		{"unsupported_image_media_type", .Invalid_Request},
		{"empty_image_file", .Invalid_Request},
		{"failed_to_download_image", .Invalid_Request},
		{"image_file_not_found", .Invalid_Request},
		{"invalid_request_error", .Invalid_Request},
	}
	apis := []API_Kind{.OpenAI_Chat_Completions, .OpenAI_Responses}
	for api in apis {
		for test_case in cases {
			got := provider_classify_failure(Provider_Evidence{api = api, kind = .HTTP, head_seen = true, status = 400, rejection = {code = test_case.code}})
			testing.expectf(t, got == test_case.expected, "%s: expected %v, got %v", test_case.code, test_case.expected, got)
		}
	}
}

@(test)
test_openai_error_type_fallback :: proc(t: ^testing.T) {
	cases := []struct {
		body:     string,
		expected: Provider_Failure_Class,
	} {
		{`{"error":{"code":"unknown_error","type":"authentication_error","message":"bad key"}}`, .Authentication},
		{`{"error":{"code":null,"type":"not_found_error","message":"missing"}}`, .Not_Found},
	}
	for test_case in cases {
		rejection, parse_error := provider_rejection_parse(.OpenAI_Responses, transmute([]u8)test_case.body, context.allocator)
		if !testing.expect_value(t, parse_error, nil) { return }
		class := provider_classify_failure(Provider_Evidence{api = .OpenAI_Responses, kind = .HTTP, head_seen = true, status = 400, rejection = rejection})
		testing.expect_value(t, class, test_case.expected)
		provider_rejection_destroy(&rejection, context.allocator)
	}
}

@(test)
test_anthropic_retry_directive :: proc(t: ^testing.T) {
	cases := []struct {
		line:     string,
		expected: Provider_Retry_Directive,
	}{{"x-should-retry: false", .Forbid}, {"x-should-retry: TRUE", .Allow}, {"x-should-retry: sometimes", .Unspecified}}
	for test_case in cases {
		headers: http.Headers
		http.headers_init(&headers, context.temp_allocator)
		_, parsed := http.header_parse(&headers, test_case.line)
		if !testing.expect(t, parsed) {
			http.headers_destroy(&headers)
			return
		}
		testing.expect_value(t, provider_retry_directive(.Anthropic_Messages, headers), test_case.expected)
		http.headers_destroy(&headers)
	}
}

// Retry-After is the provider asking for a delay. The three formats a recipient
// must read are accepted, and everything a value can be instead of one is refused
// rather than guessed at.
@(test)
test_retry_after :: proc(t: ^testing.T) {
	// A decimal number of seconds, including zero, which asks to send again now.
	expect_delay(t, "7", 7 * time.Second)
	expect_delay(t, "0", 0)
	expect_delay(t, " 30 ", 30 * time.Second)

	// An HTTP-date, in each of the three formats RFC 9110 5.6.1 defines.
	future := time.time_add(time.now(), 60 * time.Second)
	date, date_err := http.date_string(future, context.temp_allocator)
	if !testing.expect_value(t, date_err, runtime.Allocator_Error.None) { return }
	expect_delay_range(t, date, 50 * time.Second, 60 * time.Second)
	expect_delay(t, "Sunday, 06-Nov-94 08:49:37 GMT", 0)
	expect_delay(t, "Sun Nov  6 08:49:37 1994", 0)

	// Not a value this client reads as an instruction.
	expect_no_delay(t, "")
	expect_no_delay(t, "   ")
	expect_no_delay(t, "-1")
	expect_no_delay(t, "+5")
	expect_no_delay(t, "1.5")
	expect_no_delay(t, "soon")
	expect_no_delay(t, "5, 5")
	// The field is not a list, so a comma from a repeated field is not read as two.
	expect_no_delay(t, "5, 10")
	// An RFC 3339 timestamp is not an HTTP date.
	expect_no_delay(t, "2030-01-01T00:00:00Z")

	// Neither form has a length bound: a long digit string is scanned in full.
	// A delay the provider stated is honored however long it is, and one past
	// what a Duration can carry is reported as the longest delay that type has
	// rather than as no delay at all, because a caller that read it as silence
	// would send again.
	expect_delay(t, "31536001", 365 * 24 * time.Hour + time.Second)
	expect_max_delay(t, strings.repeat("1", 300, context.temp_allocator))
	// Leading zeros do not overflow: this is seven seconds, not a huge one.
	expect_delay(t, strings.concatenate({strings.repeat("0", 300, context.temp_allocator), "7"}, context.temp_allocator), 7 * time.Second)

	// Larger than a Duration, in either direction: the longest delay there is.
	expect_max_delay(t, "99999999999999999999")
}

expect_delay :: proc(t: ^testing.T, value: string, expected: time.Duration) {
	delay, present := provider_retry_after(value).?
	if !testing.expectf(t, present, "%q should be a delay", value) { return }
	testing.expectf(t, delay == expected, "%q: expected %v, got %v", value, expected, delay)
}

expect_delay_range :: proc(t: ^testing.T, value: string, low, high: time.Duration) {
	delay, present := provider_retry_after(value).?
	if !testing.expectf(t, present, "%q should be a delay", value) { return }
	testing.expectf(t, delay >= low && delay <= high, "%q: expected %v..%v, got %v", value, low, high, delay)
}

expect_no_delay :: proc(t: ^testing.T, value: string) {
	testing.expectf(t, provider_retry_after(value) == nil, "%q should ask for no delay", value)
}

expect_max_delay :: proc(t: ^testing.T, value: string) {
	delay, present := provider_retry_after(value).?
	if !testing.expectf(t, present, "%q should ask for a delay", value) { return }
	testing.expectf(t, delay == max(time.Duration), "%q: expected the longest delay, got %v", value, delay)
}
