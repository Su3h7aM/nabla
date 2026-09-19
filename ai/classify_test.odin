#+test
package ai

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
		{"not found is an invalid request", {kind = .HTTP, head_seen = true, status = 404}, .Invalid_Request},
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
		{"a peer that did not authenticate", {kind = .Transport, cause = .Trust}, .Unknown},
		{"a local TLS configuration", {kind = .Transport, cause = .Configuration}, .Unknown},
		{"a TLS failure", {kind = .TLS, cause = .Trust}, .Unknown},
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
	expect_delay_range(t, http.date_string(future, context.temp_allocator), 50 * time.Second, 60 * time.Second)
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

	// Neither form has a length bound: a long digit string is scanned in full,
	// and one past any policy still asks for a delay rather than asking for
	// nothing, because a caller that read that as silence would send again.
	expect_out_of_policy(t, strings.repeat("1", 300, context.temp_allocator))
	// Leading zeros do not overflow: this is seven seconds, not a huge one.
	expect_delay(t, strings.concatenate({strings.repeat("0", 300, context.temp_allocator), "7"}, context.temp_allocator), 7 * time.Second)

	// Valid but beyond any policy: reported as out of policy rather than as absent,
	// because a caller that read it as silence would send again.
	expect_out_of_policy(t, "99999999999999999999")
	expect_out_of_policy(t, "31536001")
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

expect_out_of_policy :: proc(t: ^testing.T, value: string) {
	delay, present := provider_retry_after(value).?
	if !testing.expectf(t, present, "%q should ask for a delay", value) { return }
	testing.expectf(t, delay == PROVIDER_RETRY_AFTER_TOO_LONG, "%q: expected the out-of-policy delay, got %v", value, delay)
}
