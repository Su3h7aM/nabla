package agent

// Recovery policy for one response chain: what happens to a send that did not produce a
// usable response. Every failure class has exactly one recovery: the request is resent after
// a fixed schedule of waits, repaired once and resent, or stopped because only the user can
// fix what failed. The decision is a function of documented facts alone, so the same failure
// is always handled the same way.

import "core:time"

import "nabla:ai"

// CHAT_RETRY_DELAYS is the wait before each resend of a request that failed for a reason the
// provider calls temporary or nobody names. Once they are spent the request stops: a failure
// that outlasts them is not the passing kind.
@(rodata)
CHAT_RETRY_DELAYS := [3]time.Duration{1 * time.Second, 3 * time.Second, 5 * time.Second}

// Chat_Retry_Policy is the schedule one chain resends a failed request on: delays[n] is the
// wait before resend n + 1. delays is borrowed and outlives every chain that uses it.
Chat_Retry_Policy :: struct {
	delays: []time.Duration,
}

// chat_retry_policy_default is the policy a session runs with unless its caller says
// otherwise.
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
	// Omit_Cache_Hints sends the request again without the cache hints the harness added.
	// They are optional, so a request refused while carrying them is resent without them
	// before the refusal is treated as the request's own.
	Omit_Cache_Hints,
}

// Request_Recovery_Reason names why the chain stopped or waited. A stop is always
// explained: an unexplained false is not something a record, a log line, or a
// front-end can act on.
Request_Recovery_Reason :: enum {
	// Completed is a send whose operation finished and whose completion the harness
	// accepted. There was nothing to recover.
	Completed,
	// Harness_Failure is a turn the harness failed for its own reasons: a completion it
	// rejected, or a response it could not record. Retrying cannot repair that.
	Harness_Failure,
	// Storage_Failed is a durable write that did not land. What failed is the store, not
	// the provider, and a retry would repeat a send whose result is already unrecorded.
	Storage_Failed,
	// Cancelled is a turn the user or the driver stopped.
	Cancelled,
	// Output_Exposed is a failure after the harness had accepted the response's completion.
	// The completion is the response, so the chain stops and keeps it.
	Output_Exposed,
	// Context_Exhausted is a provider-confirmed refusal because the input does not fit.
	// Ordinary backoff cannot make it fit, so the chain either repairs the context once
	// or the turn ends here with the cause of the refusal.
	Context_Exhausted,
	// Terminal_Failure is a failure only the user can fix: credentials, quota, a model the
	// provider does not serve, a content policy, or a refusal nothing left can repair.
	Terminal_Failure,
	// Transient_Failure is a failure the chain resends after the scheduled delay.
	Transient_Failure,
	// Cache_Hints_Refused is a request refused as invalid while it carried the harness's
	// optional cache hints, which the chain drops before sending it again.
	Cache_Hints_Refused,
	// Retries_Exhausted is a transient failure that outlasted every scheduled resend.
	Retries_Exhausted,
}

// request_recovery_reason_name is the stable spelling a record and a log line keep for a
// reason. A name outlives the build that wrote it.
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
	case .Cache_Hints_Refused:
		return "cache_hints_refused"
	case .Retries_Exhausted:
		return "retries_exhausted"
	}
	return "unknown"
}

// Chat_Attempt_Facts is one send as the policy sees it. Every field is a fact from the
// layer that observed it: the operation reports its own failure, the runtime knows what
// the attempt produced, and the session knows whether the turn was stopped or whether a
// write landed.
Chat_Attempt_Facts :: struct {
	// retries counts the scheduled resends this chain has already made. A repair is not one.
	retries:             int,
	error:               ai.Provider_Operation_Error,
	// failed records that the harness failed this send itself rather than the provider
	// refusing it, which happens when it rejected the completion or could not record it.
	failed:              bool,
	// repaired records that this chain has already used its one context repair. A second
	// refusal is terminal even when another candidate appears, and the bound does not
	// reset because the payload changed.
	repaired:            bool,
	// cache_hints_sent records that the refused request carried the harness's optional
	// cache hints, which a resend can leave out.
	cache_hints_sent:    bool,
	storage_failed:      bool,
	completion_accepted: bool,
	cancelled:           bool,
}

// Chat_Recovery_Decision is the whole answer: what to do, why, and how long to wait.
Chat_Recovery_Decision :: struct {
	action: Request_Recovery_Action,
	reason: Request_Recovery_Reason,
	// delay is what the chain waits before its next send, and zero when it does not wait.
	delay:  time.Duration,
}

// Chat_Failure_Recovery is what a failure class allows: a resend of the same request, a
// repair of what the harness added to it, or nothing short of the user.
Chat_Failure_Recovery :: enum {
	Stop,
	Retry,
	Repair,
}

// chat_failure_recovery is the one table from failure class to recovery. A class nobody
// names is retried, because the schedule bounds what that costs and stopping would end work
// a resend may finish.
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
// arguments alone, so the same facts always produce the same decision.
//
// The facts are read in the order they matter:
//
//  1. Cancellation, then a failed write, then a turn the harness already failed. None of
//     these is about the provider, and none can be repaired by sending again.
//  2. A send that completed, or whose completion was accepted before a later failure.
//  3. The recovery the failure class allows, overridden by the provider's own directive
//     where it gave one: a class that is retried is stopped when the provider forbids it,
//     and a class that stops is retried when the provider says a resend can help.
//  4. A repair is used once; a resend waits the scheduled delay or the provider's own
//     delay, whichever is longer, until the schedule is spent.
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
		if recovery == .Stop && class != .None { recovery = .Retry }
	case .Unspecified:
	}

	switch recovery {
	case .Stop:
		return {action = .Stop, reason = .Terminal_Failure}
	case .Repair:
		if class == .Invalid_Request {
			if facts.cache_hints_sent { return {action = .Omit_Cache_Hints, reason = .Cache_Hints_Refused} }
			return {action = .Stop, reason = .Terminal_Failure}
		}
		// A rejected payload is never resent. The chain either makes room for a rebuilt
		// request, once, or the turn ends as context exhaustion.
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
