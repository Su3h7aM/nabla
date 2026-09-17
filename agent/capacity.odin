package agent

// How much context a model has and how it is divided for one request.
//
// The resolved catalog carries the answer: Model_Capacity is computed once, by
// model_capacity, while the catalog is resolved. Nothing downstream recomputes the
// window arithmetic, so no two features can disagree about what a model can hold.
//
// A model's window is shared between what a request sends and what it may generate, so
// it is divided once:
//
//	window            the model's stated context window, or the assumed default
//	model_max_output  what the model states it can generate
//	output            what an ordinary request asks for
//	margin            what the estimator's error may cost
//	usable            the largest input the harness will send
//
// with usable = window - output - margin. A summarization request asks for more output
// than `output`, and chat_compact_summary_output derives that bound from the same
// record rather than from a second copy of these numbers.
Model_Capacity :: struct {
	window:           int,
	model_max_output: int,
	output:           int,
	margin:           int,
	usable:           int,
}

// CHAT_DEFAULT_CONTEXT_WINDOW is the window assumed for a model that no
// enrichment source described. It is a runtime default rather than a metadata
// source: it applies only after user configuration, provider discovery, and
// models.dev have all left the window unstated, and it never replaces a stated one.
CHAT_DEFAULT_CONTEXT_WINDOW :: 128 * 1024

// CHAT_DEFAULT_OUTPUT_TOKENS is what a request may generate for a model that states
// no maximum of its own.
CHAT_DEFAULT_OUTPUT_TOKENS :: 4096

// CHAT_OUTPUT_MAX_TOKENS is the most one request asks the model to generate. A
// model's stated maximum is a capability, not a per-request need: one that can emit
// 128K tokens in a single response almost never does, and reserving all of it would
// hold a large part of the window against input that needs it. This ceiling covers a
// long answer, a large file written through a tool call, and a reasoning model's
// thinking.
CHAT_OUTPUT_MAX_TOKENS :: 32 * 1024

// CHAT_OUTPUT_WINDOW_MIN_PERCENT and CHAT_OUTPUT_WINDOW_MAX_PERCENT bound the share of
// the window an ordinary request may reserve for its own output, and
// CHAT_OUTPUT_WINDOW_RAMP_TOKENS is the window at which that share reaches its maximum.
// The share grows with the window because input is the scarce resource on a small one:
// a constant share made a 32K window give up a quarter of itself for output while a
// megatoken window gave up a thirtieth, which is the wrong way round.
CHAT_OUTPUT_WINDOW_MIN_PERCENT :: 12
CHAT_OUTPUT_WINDOW_MAX_PERCENT :: 25
CHAT_OUTPUT_WINDOW_RAMP_TOKENS :: 256 * 1024

// CHAT_OUTPUT_MIN_TOKENS keeps a window too small to have a share of its own from
// asking for an output bound too small to answer with. The model's own maximum still
// wins, because a request never asks for more than the model allows.
CHAT_OUTPUT_MIN_TOKENS :: 1024

// chat_output_window_percent is that share at one window size: the smallest at nothing,
// rising to the largest at the ramp's end.
chat_output_window_percent :: proc(window: int) -> int {
	ramp := min(window, CHAT_OUTPUT_WINDOW_RAMP_TOKENS)
	span := CHAT_OUTPUT_WINDOW_MAX_PERCENT - CHAT_OUTPUT_WINDOW_MIN_PERCENT
	return CHAT_OUTPUT_WINDOW_MIN_PERCENT + span * ramp / CHAT_OUTPUT_WINDOW_RAMP_TOKENS
}

// CHAT_MARGIN_PERCENT and CHAT_MARGIN_MIN_TOKENS bound what the estimator's error
// may cost. The estimate divides characters by CHAT_CHARS_PER_TOKEN, which holds for
// prose; a dense payload, and a tool result is dense, carries more tokens per
// character. A share of the window absorbs that, and the floor keeps the share from
// vanishing on a small window.
CHAT_MARGIN_PERCENT :: 10
CHAT_MARGIN_MIN_TOKENS :: 1024

// model_capacity divides one resolved model's window. Presence decides the window:
// a stated one is used as stated, including an explicit zero, which admission then
// refuses rather than quietly running with the default.
//
// The ordinary output bound is the smallest of three limits, each answering a different
// question: what the model allows, what the harness will ask for, and what the window
// can spare for one request's own output.
model_capacity :: proc(model: Catalog_Model) -> Model_Capacity {
	window := model.context_window
	if !model.context_window_present { window = CHAT_DEFAULT_CONTEXT_WINDOW }
	if window <= 0 { return {} }

	stated := model.max_output_tokens
	if !model.max_output_tokens_present || stated <= 0 { stated = CHAT_DEFAULT_OUTPUT_TOKENS }
	share := max(window * chat_output_window_percent(window) / 100, CHAT_OUTPUT_MIN_TOKENS)
	ordinary := min(stated, CHAT_OUTPUT_MAX_TOKENS, share)

	margin := max(window * CHAT_MARGIN_PERCENT / 100, CHAT_MARGIN_MIN_TOKENS)
	return {window = window, model_max_output = stated, output = ordinary, margin = margin, usable = max(window - ordinary - margin, 0)}
}

// model_capacity_admits_output reports whether an input fits when the request reserves
// this much for its own output. A summarization request carries a bound of its own, so
// admission cannot assume one output bound for every request.
model_capacity_admits_output :: proc(capacity: Model_Capacity, estimate, output: int) -> bool {
	return capacity.window > 0 && estimate + output + capacity.margin <= capacity.window
}

// model_capacity_admits is the ordinary case: the request reserves what the capacity
// set aside for output. It is the one predicate admission and the compaction trigger
// answer with, so a request the harness will send and a context it considers full are
// the same size.
model_capacity_admits :: proc(capacity: Model_Capacity, estimate: int) -> bool {
	return model_capacity_admits_output(capacity, estimate, capacity.output)
}
