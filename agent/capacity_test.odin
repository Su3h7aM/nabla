#+test
package agent

import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "nabla:ai"

// capacity_of builds the capacity of a model that states a window and, optionally,
// an output bound. It is the test's way of naming a model rather than arithmetic.
@(private)
capacity_of :: proc(window: int, output := 0, window_stated := true, trigger := 0) -> Model_Capacity {
	return model_capacity(
		Catalog_Model {
			context_window = window_stated ? window : nil,
			max_output_tokens = output > 0 ? output : nil,
			compaction_trigger = trigger > 0 ? trigger : nil,
		},
	)
}

@(test)
test_a_model_that_states_no_window_gets_the_default_capacity :: proc(t: ^testing.T) {
	capacity := capacity_of(0, 0, false)
	testing.expect_value(t, capacity.window, CHAT_DEFAULT_CONTEXT_WINDOW)
	testing.expect_value(t, capacity.trigger, CHAT_DEFAULT_CONTEXT_WINDOW / 2)
}

@(test)
test_the_default_trigger_is_half_the_window :: proc(t: ^testing.T) {
	testing.expect_value(t, capacity_of(32_000, 8_000).trigger, 16_000)
	testing.expect_value(t, capacity_of(200_000, 8_000).trigger, 100_000)
}

@(test)
test_a_configured_trigger_wins_whether_lower_or_higher_than_half :: proc(t: ^testing.T) {
	testing.expect_value(t, capacity_of(32_000, 8_000, true, 10_000).trigger, 10_000)
	testing.expect_value(t, capacity_of(32_000, 8_000, true, 30_000).trigger, 30_000)
	testing.expect_value(t, capacity_of(32_000, 8_000, true, 50_000).trigger, 50_000)
}

_admits_nothing :: proc(t: ^testing.T) {
	// Presence is the whole point of the catalog's flags: a stated zero is a fact,
	// and admission refusing it is better than quietly running with the default.
	capacity := capacity_of(0)
	testing.expect_value(t, capacity.window, 0)
	testing.expect(t, !model_capacity_admits(capacity, 1))
}

@(test)
test_admission_uses_the_raw_window :: proc(t: ^testing.T) {
	capacity := capacity_of(32_000, 8_000)
	testing.expect(t, model_capacity_admits(capacity, 2_000))
	testing.expect(t, model_capacity_admits(capacity, 31_000))
	testing.expect(t, model_capacity_admits(capacity, 31_999))
	testing.expect(t, !model_capacity_admits(capacity, 32_000))
	testing.expect(t, !model_capacity_admits(capacity, 40_000))
}

_admission :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 32_000, 8_000)
	_test_accept(t, chat, strings.repeat("x", 130_000, context.temp_allocator))

	// By bytes alone the request is past the window.
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
test_a_stated_maximum_is_the_models_output_maximum :: proc(t: ^testing.T) {
	capacity := capacity_of(1_000_000, 128 * 1_024)
	testing.expect_value(t, capacity.model_max_output, 128 * 1_024)
	testing.expect_value(t, capacity_of(1_000_000, 512).model_max_output, 512)
	testing.expect_value(t, capacity_of(1_000_000).model_max_output, CHAT_DEFAULT_OUTPUT_TOKENS)
}
