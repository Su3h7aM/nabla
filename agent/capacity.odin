package agent

// How much context a model has and where its limits are.
//
// The resolved catalog carries the answer: Model_Capacity is computed once, by
// model_capacity, while the catalog is resolved. Nothing downstream recomputes the
// arithmetic, so no two features can disagree about what a model can hold.
//
// The provider enforces one limit: the input plus the output a request asks for must fit
// the window. The harness therefore asks for whatever room is left instead of reserving
// a share of the window for output in advance:
//
//	window            the model's stated context window, or the assumed default
//	model_max_output  what the model states it can generate
//	margin            what the estimator's error may cost
//	trigger           where background compaction starts
//
// There is no reserved output and no separate input budget. A request asks for as much
// output as the window has left once its input and the margin are charged, so a context
// that is nearly full still sends, with a small bound, rather than being refused. The
// trigger is policy for starting background work and is not a limit: the only limit is
// the window itself.
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

// CHAT_OUTPUT_MAX_TOKENS is the most a request asks the model to generate. A model's
// stated maximum is a capability, not a per-request need: one that can emit 128K tokens
// in a single response almost never does, and asking for it would say nothing useful.
// This ceiling covers a long answer, a large file written through a tool call, and a
// reasoning model's thinking.
CHAT_OUTPUT_MAX_TOKENS :: 32 * 1024

// CHAT_OUTPUT_MIN_TOKENS is the smallest answer worth asking for. A request that cannot
// leave this much room is refused, because an answer with nowhere to go is not worth
// sending; the window less this and the margin is therefore the real input limit.
CHAT_OUTPUT_MIN_TOKENS :: 1024

// CHAT_MARGIN_PERCENT and CHAT_MARGIN_MIN_TOKENS bound what the estimator's error may
// cost. The estimate divides characters by CHAT_CHARS_PER_TOKEN, which holds for prose;
// a dense payload, and a tool result is dense, carries more tokens per character. A
// share of the window absorbs that, and the floor keeps the share from vanishing on a
// small window.
CHAT_MARGIN_PERCENT :: 10
CHAT_MARGIN_MIN_TOKENS :: 1024

// CHAT_COMPACT_RESERVE_PERCENT is the share of the window background compaction leaves
// for the foreground to keep working in. A summary has to be written and installed
// before the window is full, so it is started while this much room remains, and that
// room is what it has to finish inside.
CHAT_COMPACT_RESERVE_PERCENT :: 20

// model_capacity divides one resolved model's window. Presence decides the window:
// a stated one is used as stated, including an explicit zero, which admission then
// refuses rather than quietly running with the default.
model_capacity :: proc(model: Catalog_Model) -> Model_Capacity {
	window := model.context_window
	if !model.context_window_present { window = CHAT_DEFAULT_CONTEXT_WINDOW }
	if window <= 0 { return {} }

	stated := model.max_output_tokens
	if !model.max_output_tokens_present || stated <= 0 { stated = CHAT_DEFAULT_OUTPUT_TOKENS }

	margin := max(window * CHAT_MARGIN_PERCENT / 100, CHAT_MARGIN_MIN_TOKENS)
	reserve := window * CHAT_COMPACT_RESERVE_PERCENT / 100
	return {window = window, model_max_output = stated, margin = margin, trigger = max(window - margin - reserve, 0)}
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
model_capacity_admits :: proc(capacity: Model_Capacity, estimate: int) -> bool {
	return capacity.window > 0 && estimate <= chat_capacity_input_ceiling(capacity)
}

// chat_request_output_bound is what a request may ask the model to generate: the room the
// window has left once the input and the margin are charged, bounded by what the model
// allows and by what the harness will ever ask for.
//
// The bound shrinks as the context fills, which is the point. The window is one budget
// rather than an input budget plus a reserved output budget, so a fuller context asks for
// a smaller answer instead of being refused. Only when even the smallest useful answer no
// longer fits is the request refused, and that is where the window actually ends.
//
// fits is false when the room left cannot hold that smallest answer. The bound is then
// whatever room there is, so the request is still encodable and its record still says
// what it would have carried.
chat_request_output_bound :: proc(capacity: Model_Capacity, estimate: int) -> (output: int, fits: bool) {
	room := capacity.window - estimate - capacity.margin
	output = min(room, min(capacity.model_max_output, CHAT_OUTPUT_MAX_TOKENS))
	if output < 1 { output = 1 }
	return output, room >= chat_capacity_answer_floor(capacity)
}
