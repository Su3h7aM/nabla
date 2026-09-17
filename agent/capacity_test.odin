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
test_a_model_that_states_no_window_gets_the_default_budget :: proc(t: ^testing.T) {
	capacity := capacity_of(0, 0, false)
	testing.expect_value(t, capacity.window, CHAT_DEFAULT_CONTEXT_WINDOW)
	testing.expect(t, capacity.usable > 0, "an undescribed model still has a usable budget")
	testing.expect(t, capacity.output <= capacity.window)
}

@(test)
test_a_stated_zero_window_admits_nothing :: proc(t: ^testing.T) {
	// Presence is the whole point of the catalog's flags: a stated zero is a fact,
	// and admission refusing it is better than quietly running with the default.
	capacity := capacity_of(0)
	testing.expect_value(t, capacity.window, 0)
	testing.expect_value(t, capacity.usable, 0)
	testing.expect(t, !model_capacity_admits(capacity, 1))
}

@(test)
test_the_output_bound_is_capped_by_what_one_request_needs :: proc(t: ^testing.T) {
	// A model that can emit 128K tokens in one response almost never does, and this
	// window is not asked to hold that much against input on the chance that it might.
	large := capacity_of(1_000_000, 128 * 1_024)
	testing.expect_value(t, large.output, CHAT_OUTPUT_MAX_TOKENS)
	testing.expect(t, large.output < 128 * 1_024)
	testing.expect(t, large.usable > large.window * 80 / 100, "almost all of the window is left for input")

	// The cap never asks for more than the model allows.
	modest := capacity_of(1_000_000, 8_000)
	testing.expect_value(t, modest.output, 8_000)
}

@(test)
test_the_output_reservation_never_takes_the_window :: proc(t: ^testing.T) {
	// The model's stated maximum is a capability, not a per-request need. Reserving
	// it whole is what starved a 32K window: the model states an 8K maximum, and the
	// harness reserved 8K of output plus a fixed 8K margin before admitting any input.
	capacity := capacity_of(32_000, 8_000)
	testing.expect_value(t, capacity.model_max_output, 8_000)
	testing.expect_value(t, capacity.output, 4_160)
	testing.expect_value(t, capacity.margin, 3_200)
	testing.expect_value(t, capacity.usable, 24_640)
	testing.expect(t, capacity.usable > 16_236, "the estimate that was refused now fits")

	// A model whose maximum output is its whole window cannot reserve all of it, or
	// there would be nothing left to send.
	whole := capacity_of(64_000, 64_000)
	testing.expect_value(t, whole.output, 9_600)
	testing.expect(t, whole.usable > 0)
	testing.expect(t, whole.output + whole.margin + whole.usable == whole.window)
}

@(test)
test_a_small_window_claims_less_of_what_the_model_can_generate :: proc(t: ^testing.T) {
	// A constant share of the window made a small one claim the model's whole capability:
	// an 8K maximum against a 32K window reserved all 8000 of it, while the same model on
	// a megatoken window would have reserved a fraction. The share grows with the window
	// so that what a request claims of the model's maximum grows with it too.
	small := capacity_of(32_000, 128 * 1_024)
	large := capacity_of(1_000_000, 128 * 1_024)
	testing.expect(t, small.output * 100 / small.model_max_output < large.output * 100 / large.model_max_output)

	// A model that states a small maximum still has it claimed whole, because a share
	// never raises what the model allows.
	modest := capacity_of(32_000, 2_048)
	testing.expect_value(t, modest.output, 2_048)

	// The share only rises, so a bigger window never asks for proportionally less.
	previous := 0
	for window in ([]int{8_000, 32_000, 64_000, 128_000, 256_000, 1_000_000}) {
		percent := chat_output_window_percent(window)
		testing.expect(t, percent >= previous)
		previous = percent
		testing.expect(t, percent >= CHAT_OUTPUT_WINDOW_MIN_PERCENT)
		testing.expect(t, percent <= CHAT_OUTPUT_WINDOW_MAX_PERCENT)
	}
}

@(test)
test_a_summarization_request_takes_the_room_that_is_left :: proc(t: ^testing.T) {
	capacity := capacity_of(32_000, 8_000)

	// A prefix with room to spare gets the ceiling, which is what makes a summary
	// complete rather than cut off.
	roomy, roomy_fits := chat_compact_summary_output(capacity, 8_000)
	testing.expect(t, roomy_fits)
	testing.expect_value(t, roomy, capacity.model_max_output)
	testing.expect(t, roomy > capacity.output, "a summary is given more than an answer")

	// A prefix with little room left still compacts, on a smaller bound, rather than
	// being refused exactly when the context most needs it.
	tight, tight_fits := chat_compact_summary_output(capacity, 22_000)
	testing.expect(t, tight_fits)
	testing.expect(t, tight < roomy)
	testing.expect(t, model_capacity_admits_output(capacity, 22_000, tight))

	// A prefix that leaves no usable room is the one case that cannot be summarized.
	_, impossible := chat_compact_summary_output(capacity, capacity.window)
	testing.expect(t, !impossible)
}

@(test)
test_the_output_bound_never_exceeds_the_models_own :: proc(t: ^testing.T) {
	small := capacity_of(200_000, 512)
	// A share never raises what the model allows.
	testing.expect_value(t, small.output, 512)
}

@(test)
test_the_margin_is_a_share_and_a_floor :: proc(t: ^testing.T) {
	large := capacity_of(200_000, 8_000)
	testing.expect_value(t, large.margin, 20_000)

	// A window too small to have a share of its own still holds back a floor, so a
	// dense payload cannot slip past admission and come back as a provider refusal.
	tiny := capacity_of(8_000, 4_000)
	testing.expect_value(t, tiny.margin, CHAT_MARGIN_MIN_TOKENS)
	testing.expect(t, tiny.usable > 0)
}

@(test)
test_the_compaction_reserve_leaves_a_sendable_window :: proc(t: ^testing.T) {
	for capacity in ([]Model_Capacity{capacity_of(8_000, 4_000), capacity_of(32_000, 8_000), capacity_of(200_000, 8_000)}) {
		reserve := chat_compact_reserve(capacity)
		trigger := capacity.usable - reserve
		testing.expect(t, trigger > 0, "compaction must trigger before the window is unusable")
		testing.expect(t, trigger <= capacity.usable)
		testing.expect(t, reserve > 0)
	}
}
