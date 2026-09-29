#+test
package agent

import "core:strings"
import "core:sync"
import "core:testing"

import "nabla:agent/journal"
import "nabla:ai"

selection_test_target :: proc(test: ^testing.T, api: ai.API_Kind, window: int) -> Model_Selection {
	selection := Model_Selection {
		provider_id = strings.clone("target-provider", context.allocator) or_else "",
		model_id = strings.clone("target-model", context.allocator) or_else "",
		connection = {API = api, Endpoint = strings.clone("https://target.invalid", context.allocator) or_else ""},
		capacity = model_capacity(
			Catalog_Model{context_window_present = true, context_window = window, max_output_tokens_present = true, max_output_tokens = 1024},
		),
		tools = false,
	}
	if selection.provider_id == "" || selection.model_id == "" || selection.connection.Endpoint == "" {
		testing.fail_now(test, "the target selection could not be held")
	}
	return selection
}

@(test)
test_selection_fit_projects_target_api_without_mutating_session :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 100_000)
	_ = _test_user(test, chat, "neutral conversation", .Prompt)

	target := selection_test_target(test, .Anthropic_Messages, 100_000)
	defer model_selection_destroy(&target, context.allocator)
	original_provider := chat.provider_id
	original_model := chat.model_id
	original_api := chat.model_api
	original_window := chat.capacity.window
	transition: Selection_Transition
	status, problem, error := chat_selection_check(chat, target, &transition, false, {API = chat.model_api})
	if error != nil { testing.fail_now(test, "selection projection failed") }
	testing.expect_value(test, status, Selection_Status.Ready)
	testing.expect_value(test, problem, "")
	testing.expect_value(test, chat.provider_id, original_provider)
	testing.expect_value(test, chat.model_id, original_model)
	testing.expect_value(test, chat.model_api, original_api)
	testing.expect_value(test, chat.capacity.window, original_window)

	records := _test_records(test, chat, {.Selection_Fit})
	if !testing.expect_value(test, len(records), 1) { return }
	testing.expect_value(test, records[0].provider, "target-provider")
	testing.expect_value(test, records[0].model, "target-model")
	fit: journal.Selection_Fit
	if decode_error := journal.payload_decode(records[0].data, &fit, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the target fit record could not be decoded")
	}
	testing.expect_value(test, fit.api, chat_api_name(.Anthropic_Messages))
	testing.expect_value(test, fit.decision, journal.SELECTION_FIT_DECISION_NAMES[.Fits])
}

@(test)
test_selection_gate_refuses_oversized_default_without_compaction :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 100_000)
	large := strings.repeat("work ", 3000, context.temp_allocator) or_else ""
	_ = _test_user(test, chat, large, .Prompt)

	target := selection_test_target(test, .OpenAI_Responses, 4096)
	defer model_selection_destroy(&target, context.allocator)
	before_head := chat.head
	before_model := chat.model_id
	transition: Selection_Transition
	status, problem, error := chat_selection_check(chat, target, &transition, false, {API = chat.model_api})
	if error != nil { testing.fail_now(test, "selection projection failed") }
	testing.expect_value(test, status, Selection_Status.Refused)
	testing.expect(test, problem != "", "a refusal must explain why")
	testing.expect_value(test, chat.head, before_head)
	testing.expect_value(test, chat.model_id, before_model)
	testing.expect_value(test, chat.compact.state, Compact_State.Idle)
	records := _test_records(test, chat, {.Selection_Fit})
	if !testing.expect_value(test, len(records), 1) { return }
	fit: journal.Selection_Fit
	if decode_error := journal.payload_decode(records[0].data, &fit, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the target fit record could not be decoded")
	}
	testing.expect_value(test, fit.decision, journal.SELECTION_FIT_DECISION_NAMES[.Refused])
}

@(test)
test_model_selection_effort_preserves_supported_level_and_falls_back :: proc(test: ^testing.T) {
	target: Model_Selection
	target.effort_levels = []string{"low", "high"}
	testing.expect_value(test, model_selection_effort(target, "high"), "high")
	testing.expect_value(test, model_selection_effort(target, "unsupported"), "low")
	target.effort_levels = nil
	testing.expect_value(test, model_selection_effort(target, "unsupported"), "")
}

@(test)
test_selection_pending_keeps_foreground_tail_and_rechecks_it :: proc(test: ^testing.T) {
	setup: Compact_Setup
	if !compact_setup_begin(test, &setup) { return }
	defer compact_setup_end(test, &setup)
	chat := &setup.chat.chat
	current := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.background, context.temp_allocator),
	}
	foreground_connection := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.foreground, context.temp_allocator),
	}
	target := selection_test_target(test, .OpenAI_Chat_Completions, 10_000)
	defer model_selection_destroy(&target, context.allocator)

	transition: Selection_Transition
	status, problem, error := chat_selection_check(chat, target, &transition, true, current)
	if error != nil { testing.fail_now(test, "the switch compaction could not start") }
	if status != .Pending { testing.fail_now(test, problem) }
	testing.expect_value(test, status, Selection_Status.Pending)
	testing.expect_value(test, chat.compact.state, Compact_State.Running)
	testing.expect_value(test, chat.compact.trigger, Compact_Trigger.Model_Switch)
	if !sync.sema_wait_with_timeout(&setup.background.reached, COMPACT_TEST_BOUND) {
		testing.fail_now(test, "the current-selection compaction request was not sent")
	}
	initial_records := _test_records(test, chat, {.Selection_Fit})
	if !testing.expect_value(test, len(initial_records), 1) { return }
	status, _, error = chat_selection_check(chat, target, &transition, true, current)
	if error != nil { testing.fail_now(test, "the pending selection check failed") }
	testing.expect_value(test, status, Selection_Status.Pending)
	unchanged_records := _test_records(test, chat, {.Selection_Fit})
	testing.expect_value(test, len(unchanged_records), len(initial_records))

	// The pending intent does not stop the original turn or change its serving model.
	if !testing.expect(test, chat_run_turn(chat, foreground_connection, test_retry_policy(), {})) { return }

	large_tail := strings.repeat("new foreground work ", 8_000, context.temp_allocator) or_else ""
	if large_tail == "" { testing.fail_now(test, "the foreground tail could not be allocated") }
	_ = _test_response(test, chat, 0, large_tail)
	if !testing.expect_value(test, chat.model_id, "test-model") { return }
	sync.sema_post(&setup.background.release)
	if !compact_service_until(test, chat, .Idle) { return }
	final_status, final_problem, final_error := chat_selection_check(chat, target, &transition, true, current)
	if final_error != nil { testing.fail_now(test, "the post-checkpoint selection projection failed") }
	testing.expect_value(test, final_status, Selection_Status.Refused)
	testing.expect(test, final_problem != "", "the committed foreground tail must prevent installing the target")
	testing.expect_value(test, chat.model_id, "test-model")
	records := _test_records(test, chat, {.Selection_Fit})
	if !testing.expect_value(test, len(records), 2) { return }
	recheck: journal.Selection_Fit
	if decode_error := journal.payload_decode(records[1].data, &recheck, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the post-checkpoint fit record could not be decoded")
	}
	testing.expect(test, recheck.recheck, "the installed summary must trigger a recheck")
	testing.expect(test, recheck.estimate > transition.estimate, "the projection must include the growing foreground tail")
	testing.expect_value(test, recheck.decision, journal.SELECTION_FIT_DECISION_NAMES[.Refused])
}

@(test)
test_selection_compaction_failure_is_terminal :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	large_prompt := strings.repeat("context ", 4_000, context.temp_allocator) or_else ""
	if large_prompt == "" { testing.fail_now(test, "the selection fixture prompt could not be allocated") }
	_test_accept(test, chat, large_prompt)
	for text in ([]string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}) {
		_test_response(test, chat, 0, text)
	}
	provider: Agent_Provider
	if !agent_provider_start(test, &provider, []string{compact_test_final_refusal()}) { return }
	defer agent_provider_stop(&provider)
	current := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(current.Endpoint, chat.allocator)
	target := selection_test_target(test, .OpenAI_Chat_Completions, 10_000)
	defer model_selection_destroy(&target, context.allocator)
	transition: Selection_Transition
	status, _, error := chat_selection_check(chat, target, &transition, true, current)
	if error != nil { testing.fail_now(test, "the failure test could not start compaction") }
	if !testing.expect_value(test, status, Selection_Status.Pending) { return }
	if !compact_service_until(test, chat, .Idle) { return }
	status, _, error = chat_selection_check(chat, target, &transition, true, current)
	if error != nil { testing.fail_now(test, "the failed selection could not be observed") }
	testing.expect_value(test, status, Selection_Status.Refused)
	testing.expect_value(test, chat.compact.completed_outcome, Compact_Outcome.Failed)
	testing.expect_value(test, len(_test_records(test, chat, {.Selection_Fit})), 1)
}

@(test)
test_selection_compaction_cancel_is_terminal :: proc(test: ^testing.T) {
	setup: Compact_Setup
	if !compact_setup_begin(test, &setup) { return }
	defer compact_setup_end(test, &setup)
	chat := &setup.chat.chat
	current := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = compact_provider_endpoint(&setup.background, context.temp_allocator),
	}
	target := selection_test_target(test, .OpenAI_Chat_Completions, 10_000)
	defer model_selection_destroy(&target, context.allocator)
	transition: Selection_Transition
	status, _, error := chat_selection_check(chat, target, &transition, true, current)
	if error != nil { testing.fail_now(test, "the cancellation test could not start compaction") }
	if !testing.expect_value(test, status, Selection_Status.Pending) { return }
	if !sync.sema_wait_with_timeout(&setup.background.reached, COMPACT_TEST_BOUND) {
		testing.fail_now(test, "the cancellation compaction request was not sent")
	}
	chat_compact_cancel(chat)
	sync.sema_post(&setup.background.release)
	if !compact_service_until(test, chat, .Idle) { return }
	status, _, error = chat_selection_check(chat, target, &transition, true, current)
	if error != nil { testing.fail_now(test, "the canceled selection could not be observed") }
	testing.expect_value(test, status, Selection_Status.Refused)
	testing.expect_value(test, chat.compact.completed_outcome, Compact_Outcome.Canceled)
	testing.expect_value(test, len(_test_records(test, chat, {.Selection_Fit})), 1)
}

@(test)
test_selection_compacts_again_only_after_target_estimate_decreases :: proc(test: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(test, &fixture, tool_loop_workspace(test))
	defer chat_test_end(test, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, 500_000)
	large_prompt := strings.repeat("context ", 1_000, context.temp_allocator) or_else ""
	large_entry := strings.repeat("history ", 438, context.temp_allocator) or_else ""
	if large_prompt == "" || large_entry == "" { testing.fail_now(test, "the selection fixture history could not be allocated") }
	_test_accept(test, chat, large_prompt)
	for _ in 0 ..< 12 { _test_response(test, chat, 0, large_entry) }
	provider: Agent_Provider
	responses := []string{agent_provider_reply(COMPACT_TEST_SUMMARY), agent_provider_reply(COMPACT_TEST_SUMMARY)}
	if !agent_provider_start(test, &provider, responses) { return }
	defer agent_provider_stop(&provider)
	current := ai.Provider_Connection {
		API      = .OpenAI_Chat_Completions,
		Endpoint = agent_provider_endpoint(&provider, chat.allocator),
	}
	defer delete(current.Endpoint, chat.allocator)
	target := selection_test_target(test, .OpenAI_Chat_Completions, 12_000)
	defer model_selection_destroy(&target, context.allocator)
	transition: Selection_Transition
	status, _, error := chat_selection_check(chat, target, &transition, true, current)
	if error != nil { testing.fail_now(test, "the first compaction could not start") }
	if !testing.expect_value(test, status, Selection_Status.Pending) { return }
	first_estimate := transition.estimate
	// This node lands after the frozen boundary, leaving eleven tail messages for another round.
	_ = _test_response(test, chat, 0, large_entry)
	if !compact_service_until(test, chat, .Idle) { return }
	status, _, error = chat_selection_check(chat, target, &transition, true, current)
	if error != nil { testing.fail_now(test, "the first installed checkpoint could not be rechecked") }
	if !testing.expect_value(test, status, Selection_Status.Pending) { return }
	if !testing.expect(test, transition.estimate < first_estimate, "the first installed checkpoint must reduce the target estimate") { return }
	if !testing.expect_value(test, chat.compact.job_generation, u64(2)) { return }

	if !compact_service_until(test, chat, .Idle) { return }
	status, _, error = chat_selection_check(chat, target, &transition, true, current)
	if error != nil { testing.fail_now(test, "the second installed checkpoint could not be rechecked") }
	testing.expect(test, status != .Pending, "no removable prefix must not leave a pending selection without a job")
	testing.expect(test, transition.estimate < first_estimate, "the transition retains measured progress")
	records := _test_records(test, chat, {.Selection_Fit})
	testing.expect_value(test, len(records), 3)
	first_recheck: journal.Selection_Fit
	if decode_error := journal.payload_decode(records[1].data, &first_recheck, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the first recheck record could not be decoded")
	}
	second_recheck: journal.Selection_Fit
	if decode_error := journal.payload_decode(records[2].data, &second_recheck, context.temp_allocator); decode_error != nil {
		testing.fail_now(test, "the second recheck record could not be decoded")
	}
	testing.expect(test, second_recheck.recheck, "the second installed checkpoint must be a recheck")
	testing.expect(test, second_recheck.estimate < first_recheck.estimate, "each compaction round must strictly reduce the target estimate")
	testing.expect_value(test, chat.compact.job_generation, u64(2))
}
