package agent

// Recovery policy for one response chain: whether a failed send is sent again, and how
// long the chain waits first. A transient failure is resent for as long as delivery
// evidence proves the model never received it; there is no attempt count, and a delay the
// provider asks for is honored as given.

import "core:math/rand"
import "core:time"

import "nabla:ai"

// CHAT_RETRY_BASE_DELAY is the first backoff ceiling. Each retry after it doubles the
// ceiling until CHAT_RETRY_BACKOFF_CEILING.
CHAT_RETRY_BASE_DELAY :: 500 * time.Millisecond

// CHAT_RETRY_BACKOFF_CEILING bounds computed backoff. It never shortens a wait the
// provider asked for.
CHAT_RETRY_BACKOFF_CEILING :: 60 * time.Second

// Chat_Retry_Policy is the backoff one chain waits with.
Chat_Retry_Policy :: struct {
	base_delay: time.Duration,
	max_delay:  time.Duration,
}

// chat_retry_policy_default is the policy a session runs with unless its caller says
// otherwise. A caller that wants only a shorter wait starts from this and changes the
// fields it means to change.
chat_retry_policy_default :: proc() -> Chat_Retry_Policy {
	return {base_delay = CHAT_RETRY_BASE_DELAY, max_delay = CHAT_RETRY_BACKOFF_CEILING}
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
	// Ambiguous_Delivery is a failed operation after model-send bytes may have
	// reached the provider, or an operation that established nothing about delivery.
	// Replaying could create a second response even when no output reached the caller.
	Ambiguous_Delivery,
	// Output_Exposed is a failure after the attempt had already published text or an
	// accepted completion. Sending again could publish a second answer, so the chain
	// stops and keeps what was published as partial.
	Output_Exposed,
	// Context_Exhausted is a provider-confirmed refusal because the input does not fit.
	// Ordinary backoff cannot make it fit, so the chain either repairs the context once
	// or the turn ends here with the cause of the refusal.
	Context_Exhausted,
	// Terminal_Failure is a failure class, or a provider directive, that says sending the
	// same request again cannot help.
	Terminal_Failure,
	// Transient_Failure is a failure the chain retries after the reported delay.
	Transient_Failure,
	// Cache_Hints_Refused is a request refused as invalid while it carried the harness's
	// optional cache hints, which the chain drops before sending it again.
	Cache_Hints_Refused,
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
	case .Ambiguous_Delivery:
		return "ambiguous_delivery"
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
	}
	return "unknown"
}

// Chat_Attempt_Facts is one send as the policy sees it. Every field is a fact from the
// layer that observed it: the operation reports its own failure, the runtime knows what
// the attempt exposed, and the session knows whether the turn was stopped or whether a
// write landed.
Chat_Attempt_Facts :: struct {
	// attempts counts the sends this chain has made, including this one.
	attempts:            int,
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
	text_exposed:        bool,
	completion_accepted: bool,
	cancelled:           bool,
}

// Chat_Recovery_Decision is the whole answer: what to do, why, and how long to wait.
Chat_Recovery_Decision :: struct {
	action: Request_Recovery_Action,
	reason: Request_Recovery_Reason,
	// delay is what the chain waits before its next send, and zero when it stops.
	delay:  time.Duration,
}

// chat_recovery_decide answers what happens after one send. It is a function of its
// arguments alone, so the same facts always produce the same decision.
//
// The facts are read in the order they matter:
//
//  1. Cancellation, then a failed write, then a turn the harness already failed. None of
//     these is about the provider, and none can be repaired by sending again.
//  2. A send whose operation finished and whose completion was accepted.
//  3. Published output, because a retry could publish a second answer.
//  4. Confirmed overflow, which ordinary backoff cannot fix.
//  5. An invalid request that carried the harness's optional cache hints, resent without them.
//  6. A failure class, or a provider directive, that says the same request cannot work.
//  7. A transient class, after the backoff or the provider's own delay, whichever is longer.
chat_recovery_decide :: proc(policy: Chat_Retry_Policy, facts: Chat_Attempt_Facts, fraction: f64) -> Chat_Recovery_Decision {
	if facts.cancelled || facts.error.kind == .Cancelled { return {action = .Stop, reason = .Cancelled} }
	if facts.storage_failed { return {action = .Stop, reason = .Storage_Failed} }
	if facts.failed { return {action = .Stop, reason = .Harness_Failure} }
	if facts.error.kind == .None { return {action = .Stop, reason = .Completed} }
	if facts.text_exposed || facts.completion_accepted {
		return {action = .Stop, reason = .Output_Exposed}
	}
	if facts.error.delivery_present && facts.error.delivery != .None {
		return {action = .Stop, reason = .Ambiguous_Delivery}
	}
	if facts.error.failure_class == .Context_Overflow {
		// A rejected payload is never resent. The chain either makes room for a rebuilt
		// request, once, or the turn ends as context exhaustion.
		if facts.repaired { return {action = .Stop, reason = .Context_Exhausted} }
		return {action = .Repair_Context, reason = .Context_Exhausted}
	}
	if facts.error.failure_class == .Invalid_Request && facts.cache_hints_sent {
		return {action = .Omit_Cache_Hints, reason = .Cache_Hints_Refused}
	}
	if facts.error.retry_directive == .Forbid { return {action = .Stop, reason = .Terminal_Failure} }
	if !chat_failure_transient(facts.error.failure_class) {
		return {action = .Stop, reason = .Terminal_Failure}
	}
	delay := chat_retry_backoff_delay(policy, facts.attempts, fraction)
	if asked, present := facts.error.retry_after.?; present { delay = max(delay, asked) }
	return {action = .Retry, reason = .Transient_Failure, delay = delay}
}

// chat_failure_transient names the classes a second send can plausibly repair. Every
// other class is terminal here: it either needs a change the harness cannot make
// (credentials, quota, configuration, the request itself), or it is a refusal nobody has
// named, and guessing is what the classification exists to avoid.
chat_failure_transient :: proc(class: ai.Provider_Failure_Class) -> bool {
	switch class {
	case .Rate_Limited, .Provider_Unavailable, .Incomplete_Stream:
		return true
	case .None, .Unknown, .Authentication, .Quota, .Context_Overflow, .Payload_Too_Large, .Invalid_Request, .Content_Policy, .Invalid_Output:
		return false
	}
	return false
}

// chat_failure_model_reachable reports whether a terminal class still lets the model be
// reached, so the refusal is feedback: every class except the ones that need the user
// (credentials, quota) or were already repaired (context overflow).
chat_failure_model_reachable :: proc(class: ai.Provider_Failure_Class) -> bool {
	switch class {
	case .Unknown, .Payload_Too_Large, .Invalid_Request, .Content_Policy, .Invalid_Output:
		return true
	case .None, .Authentication, .Quota, .Context_Overflow, .Rate_Limited, .Provider_Unavailable, .Incomplete_Stream:
		return false
	}
	return false
}

// chat_retry_backoff_delay is the computed wait before transient retry number `attempt`,
// which starts at 1:
//
//	ceiling = min(max_delay, base_delay * 2^(attempt - 1))
//	delay   = ceiling * (1 + fraction) / 2
//
// So the wait is never shorter than half the ceiling, and `fraction`, a uniform sample
// in [0, 1), spreads retries that failed together so they do not arrive together.
// Sampling is the caller's step, which keeps this a function of its inputs.
chat_retry_backoff_delay :: proc(policy: Chat_Retry_Policy, attempt: int, fraction: f64) -> time.Duration {
	ceiling := policy.base_delay
	for _ in 1 ..< attempt {
		if ceiling >= policy.max_delay { break }
		ceiling += ceiling
	}
	ceiling = min(ceiling, policy.max_delay)
	share := (1 + clamp(fraction, 0, 1)) / 2
	return time.Duration(f64(ceiling) * share)
}

// chat_retry_fraction samples the jitter fraction a wait is computed from, using the
// thread's generator. It is sampled in one place, so the decision procedure stays pure
// and a test can state the fraction it means.
chat_retry_fraction :: proc() -> f64 {
	return rand.float64_range(0.0, 1.0)
}
