#+test
package agent

import "core:testing"
import "core:time"

import "nabla:ai"

// The decision follows the failure class: every class has one recovery, and the test names
// the action and the reason, because a stop nobody can explain is what the reasons exist to
// prevent.
@(test)
test_recovery_decision_follows_the_failure_class :: proc(test: ^testing.T) {
	policy := test_retry_policy()
	Case :: struct {
		name:   string,
		kind:   ai.Provider_Operation_Error_Kind,
		class:  ai.Provider_Failure_Class,
		action: Request_Recovery_Action,
		reason: Request_Recovery_Reason,
	}
	cases := []Case {
		{"rate limited", .HTTP, .Rate_Limited, .Retry, .Transient_Failure},
		{"provider unavailable", .HTTP, .Provider_Unavailable, .Retry, .Transient_Failure},
		{"incomplete stream", .Stream, .Incomplete_Stream, .Retry, .Transient_Failure},
		{"connection lost", .Transport, .Provider_Unavailable, .Retry, .Transient_Failure},
		{"unreadable output", .Stream, .Invalid_Output, .Retry, .Transient_Failure},
		{"unnamed failure", .HTTP, .Unknown, .Retry, .Transient_Failure},
		{"context overflow", .HTTP, .Context_Overflow, .Repair_Context, .Context_Exhausted},
		{"payload too large", .HTTP, .Payload_Too_Large, .Repair_Context, .Context_Exhausted},
		{"invalid request", .HTTP, .Invalid_Request, .Stop, .Terminal_Failure},
		{"credentials", .HTTP, .Authentication, .Stop, .Terminal_Failure},
		{"quota", .HTTP, .Quota, .Stop, .Terminal_Failure},
		{"missing model", .HTTP, .Not_Found, .Stop, .Terminal_Failure},
		{"content policy", .HTTP, .Content_Policy, .Stop, .Terminal_Failure},
		{"untrusted peer", .TLS, .Untrusted_Connection, .Stop, .Terminal_Failure},
	}
	for entry in cases {
		decision := chat_recovery_decide(policy, {error = {kind = entry.kind, failure_class = entry.class}})
		testing.expectf(test, decision.action == entry.action, "%s: action is %v", entry.name, decision.action)
		testing.expectf(test, decision.reason == entry.reason, "%s: reason is %v", entry.name, decision.reason)
	}
}

// A fact that is not about the provider wins over the class, and each repair is used once.
@(test)
test_recovery_decision_stops_for_its_own_facts :: proc(test: ^testing.T) {
	policy := test_retry_policy()
	transient := ai.Provider_Operation_Error {
		kind          = .HTTP,
		failure_class = .Provider_Unavailable,
	}
	Case :: struct {
		name:   string,
		facts:  Chat_Attempt_Facts,
		action: Request_Recovery_Action,
		reason: Request_Recovery_Reason,
	}
	cases := []Case {
		{"cancelled", {error = transient, cancelled = true}, .Stop, .Cancelled},
		{"store failed", {error = transient, storage_failed = true}, .Stop, .Storage_Failed},
		{"harness failed the send", {error = transient, failed = true}, .Stop, .Harness_Failure},
		{"a completion was accepted", {error = transient, completion_accepted = true}, .Stop, .Output_Exposed},
		{"operation finished", {error = {kind = .None}}, .Stop, .Completed},
		{"overflow repaired once", {error = {kind = .HTTP, failure_class = .Context_Overflow}, repaired = true}, .Stop, .Context_Exhausted},
		{
			"refused with cache hints",
			{error = {kind = .HTTP, failure_class = .Invalid_Request}, optional_features = {.Cache_Hints}},
			.Omit_Optional_Feature,
			.Cache_Hints_Refused,
		},
		{
			"adaptive thinking is omitted before cache hints",
			{error = {kind = .HTTP, failure_class = .Invalid_Request}, optional_features = {.Adaptive_Thinking, .Cache_Hints}},
			.Omit_Optional_Feature,
			.Adaptive_Thinking_Refused,
		},
	}
	for entry in cases {
		decision := chat_recovery_decide(policy, entry.facts)
		testing.expectf(test, decision.action == entry.action, "%s: action is %v", entry.name, decision.action)
		testing.expectf(test, decision.reason == entry.reason, "%s: reason is %v", entry.name, decision.reason)
	}
}

// A retried class waits each scheduled delay in turn, or the provider's own delay when it is
// longer, and stops once the schedule is spent.
@(test)
test_recovery_decision_follows_the_schedule :: proc(test: ^testing.T) {
	policy := chat_retry_policy_default()
	unavailable := ai.Provider_Operation_Error {
		kind          = .HTTP,
		failure_class = .Provider_Unavailable,
	}
	for delay, retries in CHAT_RETRY_DELAYS {
		decision := chat_recovery_decide(policy, {retries = retries, error = unavailable})
		testing.expect_value(test, decision.action, Request_Recovery_Action.Retry)
		testing.expect_value(test, decision.delay, delay)
	}
	decision := chat_recovery_decide(policy, {retries = len(CHAT_RETRY_DELAYS), error = unavailable})
	testing.expect_value(test, decision.action, Request_Recovery_Action.Stop)
	testing.expect_value(test, decision.reason, Request_Recovery_Reason.Retries_Exhausted)

	asked := unavailable
	asked.retry_after = time.Hour
	decision = chat_recovery_decide(policy, {error = asked})
	testing.expect_value(test, decision.delay, time.Hour)
	shorter := unavailable
	shorter.retry_after = 0
	decision = chat_recovery_decide(policy, {error = shorter})
	testing.expect_value(test, decision.delay, CHAT_RETRY_DELAYS[0])
}

// The provider's own directive overrides the class: a retried class stops when it forbids a
// resend, and a class that stops is retried when it says a resend can help.
@(test)
test_recovery_decision_reads_the_provider_directive :: proc(test: ^testing.T) {
	policy := test_retry_policy()
	forbidden := ai.Provider_Operation_Error {
		kind            = .HTTP,
		failure_class   = .Rate_Limited,
		retry_directive = .Forbid,
	}
	decision := chat_recovery_decide(policy, {error = forbidden})
	testing.expect_value(test, decision.action, Request_Recovery_Action.Stop)
	testing.expect_value(test, decision.reason, Request_Recovery_Reason.Terminal_Failure)

	allowed := ai.Provider_Operation_Error {
		kind            = .HTTP,
		failure_class   = .Not_Found,
		retry_directive = .Allow,
	}
	decision = chat_recovery_decide(policy, {error = allowed})
	testing.expect_value(test, decision.action, Request_Recovery_Action.Retry)
	testing.expect_value(test, decision.reason, Request_Recovery_Reason.Transient_Failure)
}
