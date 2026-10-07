package agent

// Recovery policy for one response chain: what happens to a send that did not produce a
// usable response. The decision is a function of its facts alone, so the same failure is
// always handled the same way.

import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// CHAT_RETRY_DELAYS is the wait before each of five resends of a retried request.
@(rodata)
CHAT_RETRY_DELAYS := [5]time.Duration{1 * time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second}

// Chat_Retry_Policy is the schedule one chain resends a failed request on. delays is
// borrowed and outlives every chain that uses it.
Chat_Retry_Policy :: struct {
	delays: []time.Duration,
}

// chat_retry_policy_default is the policy a session runs with unless its caller says otherwise.
chat_retry_policy_default :: proc() -> Chat_Retry_Policy {
	return {delays = CHAT_RETRY_DELAYS[:]}
}

// Request_Recovery_Action is what the chain does with a send that did not complete.
Request_Recovery_Action :: enum {
	Stop,
	Retry,
	// Repair_Context makes room for a rebuilt request. The provider refused the payload
	// itself as too large, so sending it again is pointless and waiting changes nothing.
	Repair_Context,
	// Omit_Optional_Feature resends the request without its first optional feature.
	// The feature order chooses one repair at a time when a request carries several.
	Omit_Optional_Feature,
}

// Request_Recovery_Reason names why the chain stopped or waited.
Request_Recovery_Reason :: enum {
	// Completed is a send whose operation finished and whose completion the harness accepted.
	Completed,
	// Harness_Failure is a send the harness failed itself, by rejecting the completion
	// or by not recording the response.
	Harness_Failure,
	// Storage_Failed is a durable write that did not land.
	Storage_Failed,
	// Cancelled is a turn the user or the driver stopped.
	Cancelled,
	// Output_Exposed is a failure after the harness had accepted the response's completion.
	Output_Exposed,
	// Context_Exhausted is a refusal because the input does not fit.
	Context_Exhausted,
	// Terminal_Failure is a failure only the user can fix.
	Terminal_Failure,
	// Transient_Failure is a failure the chain resends after the scheduled delay.
	Transient_Failure,
	// Adaptive_Thinking_Refused is an invalid request carrying adaptive thinking.
	Adaptive_Thinking_Refused,
	// Cache_Hints_Refused is an invalid request carrying the harness's cache hints.
	Cache_Hints_Refused,
	// Retries_Exhausted is a transient failure that outlasted every scheduled resend.
	Retries_Exhausted,
}

// OPTIONAL_FEATURE_REFUSED_REASONS is why a chain drops each optional feature.
OPTIONAL_FEATURE_REFUSED_REASONS := [Optional_Request_Feature]Request_Recovery_Reason {
	.Adaptive_Thinking = .Adaptive_Thinking_Refused,
	.Cache_Hints       = .Cache_Hints_Refused,
}

// request_recovery_reason_name is the stable spelling a journal record keeps for a reason.
request_recovery_reason_name :: proc(reason: Request_Recovery_Reason) -> string {
	switch reason {
	case .Completed:
		return "completed"
	case .Harness_Failure:
		return "harness_failure"
	case .Storage_Failed:
		return "storage_failed"
	case .Cancelled:
		return "cancelled"
	case .Output_Exposed:
		return "output_exposed"
	case .Context_Exhausted:
		return "context_exhausted"
	case .Terminal_Failure:
		return "terminal_failure"
	case .Transient_Failure:
		return "transient_failure"
	case .Adaptive_Thinking_Refused:
		return "adaptive_thinking_refused"
	case .Cache_Hints_Refused:
		return "cache_hints_refused"
	case .Retries_Exhausted:
		return "retries_exhausted"
	}
	return "unknown"
}

chat_retry_record_scheduled :: proc(
	chat: ^Chat_Session,
	request: journal.Request_Id,
	attempt: int,
	purpose: journal.Request_Purpose,
	reason: Request_Recovery_Reason,
	next_attempt: int,
	delay: time.Duration,
) {
	chat_record(
		chat,
		{kind = .Retry_Scheduled, request = request, attempt = journal.Attempt_No(attempt)},
		journal.Retry_Scheduled {
			purpose = journal.REQUEST_PURPOSE_NAMES[purpose],
			reason = request_recovery_reason_name(reason),
			next_attempt = next_attempt,
			delay_ms = i64(delay / time.Millisecond),
		},
	)
}

chat_retry_record_completed :: proc(
	chat: ^Chat_Session,
	request: journal.Request_Id,
	attempt: int,
	purpose: journal.Request_Purpose,
	outcome: journal.Retry_Outcome,
) {
	chat_record(
		chat,
		{kind = .Retry_Completed, request = request, attempt = journal.Attempt_No(attempt)},
		journal.Retry_Completed{purpose = journal.REQUEST_PURPOSE_NAMES[purpose], outcome = journal.RETRY_OUTCOME_NAMES[outcome]},
	)
}

// Chat_Attempt_Facts is one send as the policy sees it.
Chat_Attempt_Facts :: struct {
	// retries counts the scheduled resends this chain has already made. A repair is not one.
	retries:             int,
	error:               ai.Provider_Operation_Error,
	// failed records that the harness failed this send itself.
	failed:              bool,
	// repaired records that this chain has already used its one context repair.
	repaired:            bool,
	// optional_features records which optional features the refused request carried.
	optional_features:   Optional_Request_Features,
	storage_failed:      bool,
	completion_accepted: bool,
	cancelled:           bool,
}

// Chat_Recovery_Decision is what to do, why, and how long to wait.
Chat_Recovery_Decision :: struct {
	action:  Request_Recovery_Action,
	reason:  Request_Recovery_Reason,
	// feature is the one to leave out when action is Omit_Optional_Feature.
	feature: Optional_Request_Feature,
	// delay is what the chain waits before its next send, and zero when it does not wait.
	delay:   time.Duration,
}

// Chat_Failure_Recovery is what a failure class allows: a resend, a repair, or a stop.
Chat_Failure_Recovery :: enum {
	Stop,
	Retry,
	Repair,
}

// chat_failure_recovery maps a failure class to its recovery. A class nobody names is
// retried: the schedule bounds what that costs.
chat_failure_recovery :: proc(class: ai.Provider_Failure_Class) -> Chat_Failure_Recovery {
	switch class {
	case .Unknown, .Rate_Limited, .Provider_Unavailable, .Incomplete_Stream, .Invalid_Output:
		return .Retry
	case .Context_Overflow, .Payload_Too_Large, .Invalid_Request:
		return .Repair
	case .None, .Authentication, .Quota, .Not_Found, .Content_Policy, .Untrusted_Connection:
		return .Stop
	}
	return .Stop
}

// chat_recovery_decide answers what happens after one send. It is a function of its
// arguments alone, so the same facts always produce the same decision. Own facts
// (cancellation, a failed write, a harness failure, a completion) are read before the
// failure class and the provider's retry directive.
chat_recovery_decide :: proc(policy: Chat_Retry_Policy, facts: Chat_Attempt_Facts) -> Chat_Recovery_Decision {
	if facts.cancelled || facts.error.kind == .Cancelled { return {action = .Stop, reason = .Cancelled} }
	if facts.storage_failed { return {action = .Stop, reason = .Storage_Failed} }
	if facts.failed { return {action = .Stop, reason = .Harness_Failure} }
	if facts.error.kind == .None { return {action = .Stop, reason = .Completed} }
	if facts.completion_accepted { return {action = .Stop, reason = .Output_Exposed} }

	class := facts.error.failure_class
	recovery := chat_failure_recovery(class)
	switch facts.error.retry_directive {
	case .Forbid:
		if recovery == .Retry { recovery = .Stop }
	case .Allow:
		// An allowed resend never reopens a failure a resend cannot fix.
		if recovery == .Stop && class == .Not_Found { recovery = .Retry }
	case .Unspecified:
	}

	switch recovery {
	case .Stop:
		return {action = .Stop, reason = .Terminal_Failure}
	case .Repair:
		if class == .Invalid_Request {
			for feature in Optional_Request_Feature {
				if feature in facts.optional_features {
					return {action = .Omit_Optional_Feature, reason = OPTIONAL_FEATURE_REFUSED_REASONS[feature], feature = feature}
				}
			}
			return {action = .Stop, reason = .Terminal_Failure}
		}
		// A rejected payload is never resent. The chain repairs the context once.
		if facts.repaired { return {action = .Stop, reason = .Context_Exhausted} }
		return {action = .Repair_Context, reason = .Context_Exhausted}
	case .Retry:
		if facts.retries >= len(policy.delays) { return {action = .Stop, reason = .Retries_Exhausted} }
		delay := policy.delays[facts.retries]
		if asked, present := facts.error.retry_after.?; present { delay = max(delay, asked) }
		return {action = .Retry, reason = .Transient_Failure, delay = delay}
	}
	return {action = .Stop, reason = .Terminal_Failure}
}
