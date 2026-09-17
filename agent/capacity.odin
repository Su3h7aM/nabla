package agent

// How much context a model has and how it is divided for one request.
//
// The resolved catalog carries the answer: Model_Capacity is computed once, by
// model_capacity, while the catalog is resolved. Nothing downstream recomputes the
// window arithmetic, so no two features can disagree about what a model can hold.
//
// A model's window is shared between what a request sends and what it may
// generate, so it is divided once:
//
//	window   the model's stated context window, or the assumed default
//	output   what one request may generate
//	margin   what the estimator's error may cost
//	usable   the largest input the harness will send
//
// with usable = window - output - margin.
Model_Capacity :: struct {
	window: int,
	output: int,
	margin: int,
	usable: int,
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

// CHAT_OUTPUT_WINDOW_PERCENT is the share of the window one request may reserve for
// its own output. A request whose output bound leaves no room for input cannot be
// sent at all, so the larger part of the window is always kept for input.
CHAT_OUTPUT_WINDOW_PERCENT :: 25

// CHAT_OUTPUT_MIN_TOKENS keeps a window too small to have a share of its own from
// asking for an output bound too small to answer with. The model's own maximum still
// wins, because a request never asks for more than the model allows.
CHAT_OUTPUT_MIN_TOKENS :: 1024

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
// The output bound is the smallest of three limits, each answering a different
// question: what the model allows, what the harness will ask for, and what the window
// can spare for one request's own output.
model_capacity :: proc(model: Catalog_Model) -> Model_Capacity {
	window := model.context_window
	if !model.context_window_present { window = CHAT_DEFAULT_CONTEXT_WINDOW }
	if window <= 0 { return {} }

	output := model.max_output_tokens
	if !model.max_output_tokens_present || output <= 0 { output = CHAT_DEFAULT_OUTPUT_TOKENS }
	share := max(window * CHAT_OUTPUT_WINDOW_PERCENT / 100, CHAT_OUTPUT_MIN_TOKENS)
	output = min(output, CHAT_OUTPUT_MAX_TOKENS, share)

	margin := max(window * CHAT_MARGIN_PERCENT / 100, CHAT_MARGIN_MIN_TOKENS)
	return {window = window, output = output, margin = margin, usable = max(window - output - margin, 0)}
}

// model_capacity_admits reports whether an input of this size fits. It is the one
// predicate admission and the compaction thresholds answer with, so a request the
// harness will send and a context it considers full are the same size.
model_capacity_admits :: proc(capacity: Model_Capacity, estimate: int) -> bool {
	return capacity.window > 0 && estimate <= capacity.usable
}
