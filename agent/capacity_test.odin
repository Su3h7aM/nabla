#+test
package agent

import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "nabla:ai"

// capacity_of builds the capacity of a model that states a window and, optionally,
// an output bound. It is the test's way of naming a model rather than arithmetic.
@(private)
capacity_of :: proc(window: int, output := 0, window_stated := true) -> Model_Capacity {
	return model_capacity(Catalog_Model{context_window = window_stated ? window : nil, max_output_tokens = output > 0 ? output : nil})
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
	testing.expect_value(t, capacity.margin, 1_600)

	// With the whole window free, the model's own maximum is what is asked for.
	roomy, roomy_fits := chat_request_output_bound(capacity, 2_000)
	testing.expect(t, roomy_fits)
	testing.expect_value(t, roomy, 8_000)

	// Past the trigger the bound is whatever is left, and it is still a usable answer.
	tight, tight_fits := chat_request_output_bound(capacity, 27_000)
	testing.expect(t, tight_fits)
	testing.expect_value(t, tight, 3_400)

	// One token too far and there is nowhere for an answer to go.
	_, impossible := chat_request_output_bound(capacity, 29_377)
	testing.expect(t, !impossible)
	testing.expect(t, !model_capacity_admits(capacity, 29_377))
}

@(test)
test_a_context_past_the_trigger_is_still_sendable :: proc(t: ^testing.T) {
	// The trigger starts background work; it is not a limit. This is the point of the
	// split: an agent whose summary has not arrived yet keeps working on the window it
	// has, and only the window itself stops it.
	capacity := capacity_of(32_000, 8_000)
	testing.expect(t, capacity.trigger < chat_capacity_input_ceiling(capacity))
	for estimate in ([]int{capacity.trigger, 27_000, 29_000}) {
		testing.expectf(t, model_capacity_admits(capacity, estimate), "an estimate of %d must still send", estimate)
	}
	testing.expect_value(t, chat_capacity_input_ceiling(capacity), 29_376)
	testing.expect_value(t, capacity.trigger, 26_176)
}

@(test)
test_the_ceiling_and_trigger_follow_the_window :: proc(t: ^testing.T) {
	// W = 200k: margin 10k, ceiling 200k - 10k - 1024, trigger 20k below the ceiling.
	capacity := capacity_of(200_000, 8_000)
	testing.expect_value(t, capacity.margin, 10_000)
	testing.expect_value(t, chat_capacity_input_ceiling(capacity), 188_976)
	testing.expect_value(t, capacity.trigger, 168_976)

	// A small window keeps the margin floor, and a model that cannot answer 1024 tokens
	// holds back only what it can.
	small := capacity_of(8_000, 512)
	testing.expect_value(t, small.margin, CHAT_MARGIN_MIN_TOKENS)
	testing.expect_value(t, chat_capacity_input_ceiling(small), 8_000 - CHAT_MARGIN_MIN_TOKENS - 512)
}

@(test)
test_a_provider_report_calibrates_admission :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 32_000, 8_000)
	_test_accept(t, chat, strings.repeat("x", 130_000, context.temp_allocator))

	// By bytes alone the request is far past the ceiling.
	raw_arena: virtual.Arena
	raw := request_test_prepare(t, chat, tool_loop_connection, &raw_arena)
	defer virtual.arena_destroy(&raw_arena)
	testing.expect_value(t, raw.estimate, raw.raw_estimate)
	_, raw_admitted := chat_admission_check(chat, raw.estimate, raw.sizes)
	testing.expect(t, !raw_admitted, "the raw estimate must be refused")

	// The provider counts the same request at a third of that, so the next estimate admits it.
	chat.chain.prep.raw_estimate = raw.raw_estimate
	usages := make([dynamic]Chat_Request_Usage, 0, context.temp_allocator)
	chat_session_observe_usage(chat, &usages, ai.Provider_Usage_Event{Input_Tokens = i64(raw.raw_estimate / 3), Input_Tokens_Present = true})
	calibrated_arena: virtual.Arena
	calibrated := request_test_prepare(t, chat, tool_loop_connection, &calibrated_arena)
	defer virtual.arena_destroy(&calibrated_arena)
	testing.expect(t, calibrated.estimate < raw.raw_estimate / 2, "the estimate follows the provider's count")
	_, calibrated_admitted := chat_admission_check(chat, calibrated.estimate, calibrated.sizes)
	testing.expect(t, calibrated_admitted, "the calibrated estimate must be admitted")
}

@(test)
test_the_input_ceiling_leaves_only_the_margin_and_one_answer :: proc(t: ^testing.T) {
	// The only room held back is the estimator's margin and the smallest answer worth
	// asking for, which is what makes the ceiling the window rather than a share of it.
	capacity := capacity_of(1_000_000, 128 * 1_024)
	testing.expect_value(t, chat_capacity_input_ceiling(capacity), 1_000_000 - 50_000 - CHAT_OUTPUT_MIN_TOKENS)

	// A model's stated maximum still caps what a request asks for, however empty the
	// window is, and a model that cannot generate the harness's floor is not asked for
	// more than it allows.
	modest, _ := chat_request_output_bound(capacity, 0)
	testing.expect_value(t, modest, 128 * 1_024)
	small_maximum := capacity_of(1_000_000, 512)
	tiny, tiny_fits := chat_request_output_bound(small_maximum, 0)
	testing.expect(t, tiny_fits, "an empty window has room whatever the model can generate")
	testing.expect_value(t, tiny, 512)
	testing.expect_value(t, chat_capacity_input_ceiling(small_maximum), 1_000_000 - 50_000 - 512)
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
