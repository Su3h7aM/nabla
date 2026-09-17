#+test
package agent

import "core:testing"

// capacity_of builds the capacity of a model that states a window and, optionally,
// an output bound. It is the test's way of naming a model rather than arithmetic.
@(private)
capacity_of :: proc(window: int, output := 0, window_stated := true) -> Model_Capacity {
	return model_capacity(
		Catalog_Model{context_window_present = window_stated, context_window = window, max_output_tokens_present = output > 0, max_output_tokens = output},
	)
}

@(test)
test_a_model_that_states_no_window_gets_the_default_capacity :: proc(t: ^testing.T) {
	capacity := capacity_of(0, 0, false)
	testing.expect_value(t, capacity.window, CHAT_DEFAULT_CONTEXT_WINDOW)
	testing.expect(t, capacity.trigger > 0, "an undescribed model still has a trigger")
	testing.expect(t, capacity.trigger < capacity.window)
}

@(test)
test_a_stated_zero_window_admits_nothing :: proc(t: ^testing.T) {
	// Presence is the whole point of the catalog's flags: a stated zero is a fact,
	// and admission refusing it is better than quietly running with the default.
	capacity := capacity_of(0)
	testing.expect_value(t, capacity.window, 0)
	testing.expect(t, !model_capacity_admits(capacity, 1))
}

@(test)
test_the_answer_bound_shrinks_as_the_context_fills :: proc(t: ^testing.T) {
	// The window is one budget, not an input budget plus a reserved output budget. A
	// request asks for the room that is left, so a fuller context asks for a smaller
	// answer instead of being refused.
	capacity := capacity_of(32_000, 8_000)
	testing.expect_value(t, capacity.margin, 3_200)

	// With the whole window free, the model's own maximum is what is asked for.
	roomy, roomy_fits := chat_request_output_bound(capacity, 2_000)
	testing.expect(t, roomy_fits)
	testing.expect_value(t, roomy, 8_000)

	// Past the trigger the bound is whatever is left, and it is still a usable answer.
	tight, tight_fits := chat_request_output_bound(capacity, 27_000)
	testing.expect(t, tight_fits)
	testing.expect_value(t, tight, 1_800)

	// One token too far and there is nowhere for an answer to go.
	_, impossible := chat_request_output_bound(capacity, 28_000)
	testing.expect(t, !impossible)
	testing.expect(t, !model_capacity_admits(capacity, 28_000))
}

@(test)
test_a_context_past_the_trigger_is_still_sendable :: proc(t: ^testing.T) {
	// The trigger starts background work; it is not a limit. This is the point of the
	// split: an agent whose summary has not arrived yet keeps working on the window it
	// has, and only the window itself stops it.
	capacity := capacity_of(32_000, 8_000)
	testing.expect(t, capacity.trigger < chat_capacity_input_ceiling(capacity))
	for estimate in ([]int{capacity.trigger, 25_000, 27_000}) {
		testing.expectf(t, model_capacity_admits(capacity, estimate), "an estimate of %d must still send", estimate)
	}
	testing.expect_value(t, chat_capacity_input_ceiling(capacity), 27_776)
}

@(test)
test_the_input_ceiling_leaves_only_the_margin_and_one_answer :: proc(t: ^testing.T) {
	// The only room held back is the estimator's margin and the smallest answer worth
	// asking for, which is what makes the ceiling the window rather than a share of it.
	capacity := capacity_of(1_000_000, 128 * 1_024)
	testing.expect_value(t, chat_capacity_input_ceiling(capacity), 1_000_000 - 100_000 - CHAT_OUTPUT_MIN_TOKENS)

	// A model's stated maximum still caps what a request asks for, however empty the
	// window is, and a model that cannot generate the harness's floor is not asked for
	// more than it allows.
	modest, _ := chat_request_output_bound(capacity, 0)
	testing.expect_value(t, modest, CHAT_OUTPUT_MAX_TOKENS)
	small_maximum := capacity_of(1_000_000, 512)
	tiny, tiny_fits := chat_request_output_bound(small_maximum, 0)
	testing.expect(t, tiny_fits, "an empty window has room whatever the model can generate")
	testing.expect_value(t, tiny, 512)
	testing.expect_value(t, chat_capacity_input_ceiling(small_maximum), 1_000_000 - 100_000 - 512)
}

@(test)
test_a_summarization_request_is_given_more_room_than_an_answer :: proc(t: ^testing.T) {
	// A summary carries the prefix rather than the whole context, so the same rule gives
	// it more room than the request that started it. That is all that keeps a summary
	// from being a special case, and it is what keeps it complete.
	capacity := capacity_of(32_000, 8_000)
	answer, _ := chat_request_output_bound(capacity, 24_000)
	summary, summary_fits := chat_request_output_bound(capacity, 20_000)
	testing.expect(t, summary_fits)
	testing.expect(t, summary > answer)
}

@(test)
test_the_trigger_lies_between_the_margin_and_the_ceiling :: proc(t: ^testing.T) {
	for capacity in ([]Model_Capacity{capacity_of(8_000, 4_000), capacity_of(32_000, 8_000), capacity_of(200_000, 8_000), capacity_of(1_000_000, 128 * 1_024)}) {
		testing.expect(t, capacity.trigger > 0)
		testing.expect(t, capacity.trigger < chat_capacity_input_ceiling(capacity), "a summary is started before the window runs out")
		testing.expect(t, capacity.trigger > capacity.margin)
	}
}
