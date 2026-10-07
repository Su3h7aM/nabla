package agent

// How much context a model has and where its limits are.
//
// Model_Capacity is computed once, by model_capacity, while the catalog is resolved, so no
// two features disagree about what a model can hold. window is the limit; the trigger only
// decides when background compaction starts, and a request asks for whatever room the window
// has left rather than reserving a share of it for output in advance.
Model_Capacity :: struct {
	window:           int,
	model_max_output: int,
	margin:           int,
	trigger:          int,
}

// CHAT_DEFAULT_CONTEXT_WINDOW is the window assumed for a model that no
// enrichment source described. It is a runtime default rather than a metadata
// source: it applies only after user configuration, provider discovery, and
// models.dev have all left the window unstated, and it never replaces a stated one.
CHAT_DEFAULT_CONTEXT_WINDOW :: 128 * 1024

// CHAT_DEFAULT_OUTPUT_TOKENS is what a request may generate for a model that states
// no maximum of its own.
CHAT_DEFAULT_OUTPUT_TOKENS :: 4096

// CHAT_OUTPUT_MIN_TOKENS is the smallest answer worth asking for. A request that cannot
// leave this much room is refused, because an answer with nowhere to go is not worth
// sending; the window less this and the margin is therefore the real input limit.
CHAT_OUTPUT_MIN_TOKENS :: 1024

// CHAT_MARGIN_PERCENT and CHAT_MARGIN_MIN_TOKENS bound what the estimator's error may cost:
// a share of the window, with a floor so it cannot vanish on a small one. The provider's own
// count calibrates the estimate (Chat_Calibration), so the margin only covers what is left.
CHAT_MARGIN_PERCENT :: 5
CHAT_MARGIN_MIN_TOKENS :: 1024

// CHAT_COMPACT_RESERVE_PERCENT is the share of the window between the compaction trigger
// and the input ceiling: the room the foreground keeps working in while a summary is
// written and installed.
CHAT_COMPACT_RESERVE_PERCENT :: 10

// model_capacity divides one resolved model's window. Presence decides the window:
// a stated one is used as stated, including an explicit zero, which admission then
// refuses rather than quietly running with the default.
model_capacity :: proc(model: Catalog_Model) -> Model_Capacity {
	window := model.context_window.? or_else CHAT_DEFAULT_CONTEXT_WINDOW
	if window <= 0 { return {} }

	stated := model.max_output_tokens.? or_else CHAT_DEFAULT_OUTPUT_TOKENS
	if stated <= 0 { stated = CHAT_DEFAULT_OUTPUT_TOKENS }

	capacity := Model_Capacity {
		window           = window,
		model_max_output = stated,
		margin           = max(window * CHAT_MARGIN_PERCENT / 100, CHAT_MARGIN_MIN_TOKENS),
	}
	reserve := window * CHAT_COMPACT_RESERVE_PERCENT / 100
	capacity.trigger = max(chat_capacity_input_ceiling(capacity) - reserve, 0)
	return capacity
}

// Chat_Calibration is the provider's count against the harness's raw estimate for one
// request of the session's current selection. The zero value is no pair: the raw estimate
// stands until the provider reports.
Chat_Calibration :: struct {
	measured:  i64, // input tokens the provider reported for the request
	estimated: i64, // the raw estimate of that same request
}

// chat_calibrated_estimate turns a raw estimate into the one admission, the compaction
// trigger, and the output bound all read: raw * measured / estimated, or raw itself when
// there is no usable pair. The product is computed in i64, so no realistic window overflows.
@(require_results)
chat_calibrated_estimate :: proc(calibration: Chat_Calibration, raw: int) -> int {
	if calibration.measured <= 0 || calibration.estimated <= 0 { return raw }
	return int(i64(raw) * calibration.measured / calibration.estimated)
}

// chat_capacity_input_ceiling is the largest input the harness will send: the window
// less the margin and the smallest answer worth asking for. A model that cannot generate
// that much answers with what it can, so its own maximum is what is held back.
chat_capacity_input_ceiling :: proc(capacity: Model_Capacity) -> int {
	return max(capacity.window - capacity.margin - chat_capacity_answer_floor(capacity), 0)
}

// chat_capacity_answer_floor is the smallest answer worth asking for, which is the
// harness's floor unless the model cannot generate that much.
chat_capacity_answer_floor :: proc(capacity: Model_Capacity) -> int {
	return min(CHAT_OUTPUT_MIN_TOKENS, capacity.model_max_output)
}

// model_capacity_admits reports whether an input of this size can be sent. It is the one
// predicate admission answers with, so what the harness will send and what it considers
// too large are the same size.
@(require_results)
model_capacity_admits :: proc(capacity: Model_Capacity, estimate: int) -> bool {
	return capacity.window > 0 && estimate <= chat_capacity_input_ceiling(capacity)
}

// chat_request_output_bound is what a request may ask the model to generate: the room the
// window has left once the input and the margin are charged, bounded by what the model allows.
//
// The bound shrinks as the context fills, which is the point. The window is one budget
// rather than an input budget plus a reserved output budget, so a fuller context asks for
// a smaller answer instead of being refused. Only when even the smallest useful answer no
// longer fits is the request refused, and that is where the window actually ends.
//
// fits is false when the room left cannot hold that smallest answer. The bound is then
// whatever room there is, so the request is still encodable and its record still says
// what it would have carried.
@(require_results)
chat_request_output_bound :: proc(capacity: Model_Capacity, estimate: int) -> (output: int, fits: bool) {
	room := capacity.window - estimate - capacity.margin
	output = min(room, capacity.model_max_output)
	if output < 1 { output = 1 }
	return output, room >= chat_capacity_answer_floor(capacity)
}
