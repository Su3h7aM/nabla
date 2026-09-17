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

// CHAT_OUTPUT_PERCENT bounds what one request may generate. A model's stated
// maximum is a capability rather than a per-request need: reserving it whole starves
// a small window, and a model whose maximum is larger than its own window would
// leave no input room at all.
CHAT_OUTPUT_PERCENT :: 25
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
model_capacity :: proc(model: Catalog_Model) -> Model_Capacity {
	window := model.context_window
	if !model.context_window_present { window = CHAT_DEFAULT_CONTEXT_WINDOW }
	if window <= 0 { return {} }

	output := model.max_output_tokens
	if !model.max_output_tokens_present || output <= 0 { output = CHAT_DEFAULT_OUTPUT_TOKENS }
	output = min(output, max(window * CHAT_OUTPUT_PERCENT / 100, CHAT_OUTPUT_MIN_TOKENS))

	margin := max(window * CHAT_MARGIN_PERCENT / 100, CHAT_MARGIN_MIN_TOKENS)
	return {window = window, output = output, margin = margin, usable = max(window - output - margin, 0)}
}

// model_capacity_admits reports whether an input of this size fits. It is the one
// predicate admission and the compaction thresholds answer with, so a request the
// harness will send and a context it considers full are the same size.
model_capacity_admits :: proc(capacity: Model_Capacity, estimate: int) -> bool {
	return capacity.window > 0 && estimate <= capacity.usable
}
