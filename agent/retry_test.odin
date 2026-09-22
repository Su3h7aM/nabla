#+test
package agent

import "core:testing"
import "core:time"

import "nabla:ai"

// The decision follows the failure class: a class a second send can plausibly repair is
// retried, and everything else stops. The test names the action and the reason, because
// a stop nobody can explain is what the reasons exist to prevent.
@(test)
test_recovery_decision_follows_the_failure_class :: proc(t: ^testing.T) {
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
		{"credentials", .HTTP, .Authentication, .Stop, .Terminal_Failure},
		{"quota", .HTTP, .Quota, .Stop, .Terminal_Failure},
		{"context overflow", .HTTP, .Context_Overflow, .Repair_Context, .Context_Exhausted},
		{"payload too large", .HTTP, .Payload_Too_Large, .Stop, .Terminal_Failure},
		{"invalid request", .HTTP, .Invalid_Request, .Stop, .Terminal_Failure},
		{"content policy", .HTTP, .Content_Policy, .Stop, .Terminal_Failure},
		{"invalid output", .Stream, .Invalid_Output, .Stop, .Terminal_Failure},
		{"unknown refusal", .HTTP, .Unknown, .Stop, .Terminal_Failure},
	}
	for c in cases {
		decision := chat_recovery_decide(policy, {attempts = 1, error = {kind = c.kind, failure_class = c.class}}, 0.5)
		testing.expectf(t, decision.action == c.action, "%s: action is %v", c.name, decision.action)
		testing.expectf(t, decision.reason == c.reason, "%s: reason is %v", c.name, decision.reason)
	}
}

// A fact that is not about the provider wins over the class. A stop that could have been
// a retry is the case worth naming: it says the chain stopped for a reason the provider
// had nothing to do with.
@(test)
test_recovery_decision_stops_for_its_own_facts :: proc(t: ^testing.T) {
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
		{"cancelled", {attempts = 1, error = transient, cancelled = true}, .Stop, .Cancelled},
		{"store failed", {attempts = 1, error = transient, storage_failed = true}, .Stop, .Storage_Failed},
		{"harness failed the send", {attempts = 1, error = transient, failed = true}, .Stop, .Harness_Failure},
		{"text was published", {attempts = 1, error = transient, text_exposed = true}, .Stop, .Output_Exposed},
		{"a completion was accepted", {attempts = 1, error = transient, completion_accepted = true}, .Stop, .Output_Exposed},
		{
			"model send was ambiguous",
			{attempts = 1, error = {kind = .Transport, failure_class = .Provider_Unavailable, delivery = .Model_Send_Started, delivery_present = true}},
			.Stop,
			.Ambiguous_Delivery,
		},
		{"last send allowed", {attempts = policy.max_attempts, error = transient}, .Stop, .Attempts_Exhausted},
		{"operation finished", {attempts = 1, error = {kind = .None}}, .Stop, .Completed},
		// The one repair is the chain's whole allowance: a second refusal is terminal,
		// and so is one that arrives when the chain has no send left.
		{"overflow repaired once", {attempts = 2, error = {kind = .HTTP, failure_class = .Context_Overflow}, repaired = true}, .Stop, .Context_Exhausted},
		{"overflow on the last send", {attempts = policy.max_attempts, error = {kind = .HTTP, failure_class = .Context_Overflow}}, .Stop, .Attempts_Exhausted},
	}
	for c in cases {
		decision := chat_recovery_decide(policy, c.facts, 0.5)
		testing.expectf(t, decision.action == c.action, "%s: action is %v", c.name, decision.action)
		testing.expectf(t, decision.reason == c.reason, "%s: reason is %v", c.name, decision.reason)
	}
}

// The wait before a transient retry: it doubles per retry, it never exceeds the policy
// ceiling, and the sample only moves it inside the upper half of that ceiling.
@(test)
test_retry_backoff_delay_doubles_and_sampled :: proc(t: ^testing.T) {
	policy := Chat_Retry_Policy {
		max_attempts       = CHAT_REQUEST_MAX_ATTEMPTS,
		base_delay         = CHAT_RETRY_BASE_DELAY,
		max_delay          = CHAT_RETRY_MAX_DELAY,
		max_provider_delay = CHAT_RETRY_MAX_PROVIDER_DELAY,
	}
	testing.expect_value(t, chat_retry_backoff_delay(policy, 1, 0), CHAT_RETRY_BASE_DELAY / 2)
	testing.expect_value(t, chat_retry_backoff_delay(policy, 1, 1), CHAT_RETRY_BASE_DELAY)
	testing.expect_value(t, chat_retry_backoff_delay(policy, 2, 0), CHAT_RETRY_BASE_DELAY)
	testing.expect_value(t, chat_retry_backoff_delay(policy, 3, 1), 4 * CHAT_RETRY_BASE_DELAY)
	// The ceiling is clamped, and the sample still spreads the wait under it.
	testing.expect_value(t, chat_retry_backoff_delay(policy, 9, 1), CHAT_RETRY_MAX_DELAY)
	testing.expect_value(t, chat_retry_backoff_delay(policy, 9, 0), CHAT_RETRY_MAX_DELAY / 2)
}

// A wait the provider asked for by name is waited on, and one longer than the policy
// allows stops the chain instead of being shortened. Both are the same request: only the
// provider's own instruction differs.
@(test)
test_recovery_decision_waits_for_the_provider :: proc(t: ^testing.T) {
	policy := test_retry_policy()
	policy.max_provider_delay = 5 * time.Second
	rate_limited := ai.Provider_Operation_Error {
		kind          = .HTTP,
		failure_class = .Rate_Limited,
	}

	asked := rate_limited
	asked.retry_after = 2 * time.Second
	decision := chat_recovery_decide(policy, {attempts = 1, error = asked}, 0)
	testing.expect_value(t, decision.action, Request_Recovery_Action.Retry)
	testing.expect_value(t, decision.delay, 2 * time.Second)

	// A reported zero is a value, not an absence: the provider said to send again now,
	// and the harness still spreads the retry.
	immediate := rate_limited
	immediate.retry_after = 0
	decision = chat_recovery_decide(policy, {attempts = 1, error = immediate}, 0)
	testing.expect_value(t, decision.action, Request_Recovery_Action.Retry)
	testing.expect_value(t, decision.delay, policy.base_delay / 2)

	too_long := rate_limited
	too_long.retry_after = 30 * time.Second
	decision = chat_recovery_decide(policy, {attempts = 1, error = too_long}, 0)
	testing.expect_value(t, decision.action, Request_Recovery_Action.Stop)
	testing.expect_value(t, decision.reason, Request_Recovery_Reason.Provider_Delay_Too_Long)
}

// A provider directive to stop is authoritative within the transient classes, and a
// directive to continue never widens them.
@(test)
test_recovery_decision_reads_the_provider_directive :: proc(t: ^testing.T) {
	policy := test_retry_policy()

	forbidden := ai.Provider_Operation_Error {
		kind            = .HTTP,
		failure_class   = .Rate_Limited,
		retry_directive = .Forbid,
	}
	decision := chat_recovery_decide(policy, {attempts = 1, error = forbidden}, 0.5)
	testing.expect_value(t, decision.action, Request_Recovery_Action.Stop)
	testing.expect_value(t, decision.reason, Request_Recovery_Reason.Terminal_Failure)

	allowed := ai.Provider_Operation_Error {
		kind            = .HTTP,
		failure_class   = .Unknown,
		retry_directive = .Allow,
	}
	decision = chat_recovery_decide(policy, {attempts = 1, error = allowed}, 0.5)
	testing.expect_value(t, decision.action, Request_Recovery_Action.Stop)
	testing.expect_value(t, decision.reason, Request_Recovery_Reason.Terminal_Failure)
}
