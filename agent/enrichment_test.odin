#+test
package agent

import "core:testing"

// The enrichment pipeline is strictly three sources, applied in this order: user
// configuration, then the provider's own model report, then models.dev. Earlier
// sources win, and a later source can only fill a field nothing has stated. There
// is no fourth source and nothing is inferred from a model's name.

// catalog_source builds one source's statement about a provider's single model.
// The model list is allocated because a source outlives the call that builds it.
catalog_source :: proc(provider_id, model_id: string, model: Catalog_Model_Source, allocator := context.temp_allocator) -> Catalog_Provider_Source {
	stated := model
	stated.id = model_id
	models := make([]Catalog_Model_Source, 1, allocator)
	models[0] = stated
	return Catalog_Provider_Source{id = provider_id, models = models}
}

@(test)
test_enrichment_user_value_is_used_wherever_it_is_stated :: proc(t: ^testing.T) {
	// The user states a window, an output limit, and tool support. The provider and
	// models.dev both disagree, and neither may change what the user chose.
	user := []Catalog_Provider_Source {
		catalog_source(
			"proxy",
			"gpt-4",
			Catalog_Model_Source {
				context_window_present = true,
				context_window = 500000,
				max_output_tokens_present = true,
				max_output_tokens = 16000,
				tools_present = true,
				tools = false,
			},
		),
	}
	provider := []Catalog_Provider_Source {
		catalog_source(
			"proxy",
			"gpt-4",
			Catalog_Model_Source {
				context_window_present = true,
				context_window = 1000000,
				max_output_tokens_present = true,
				max_output_tokens = 32000,
				tools_present = true,
				tools = true,
			},
		),
	}
	models_dev := []Catalog_Provider_Source {
		catalog_source(
			"proxy",
			"gpt-4",
			Catalog_Model_Source {
				context_window_present = true,
				context_window = 2000000,
				max_output_tokens_present = true,
				max_output_tokens = 65536,
				tools_present = true,
				tools = true,
			},
		),
	}

	resolved, err := resolve_catalog(user, provider, models_dev)
	testing.expect_value(t, err, Catalog_Error.None)
	defer catalog_destroy(&resolved)

	model := catalog_test_find(resolved, "proxy", "gpt-4")
	testing.expect(t, model != nil)
	testing.expect_value(t, model.context_window, 500000)
	testing.expect_value(t, model.max_output_tokens, 16000)
	// An explicit false is a stated value, so a later source cannot turn tools on.
	testing.expect(t, model.tools_present)
	testing.expect(t, !model.tools)
}

@(test)
test_enrichment_later_sources_fill_only_what_is_missing :: proc(t: ^testing.T) {
	// Each source states a different field, so each stage is the one that resolves
	// its own field while leaving the earlier values alone.
	user := []Catalog_Provider_Source{catalog_source("proxy", "gpt-4", Catalog_Model_Source{display_name_present = true, display_name = "Configured Name"})}
	provider := []Catalog_Provider_Source{catalog_source("proxy", "gpt-4", Catalog_Model_Source{context_window_present = true, context_window = 131072})}
	models_dev := []Catalog_Provider_Source {
		catalog_source(
			"proxy",
			"gpt-4",
			Catalog_Model_Source {
				max_output_tokens_present = true,
				max_output_tokens = 32768,
				tools_present = true,
				tools = true,
				display_name_present = true,
				display_name = "Catalog Name",
			},
		),
	}

	resolved, err := resolve_catalog(user, provider, models_dev)
	testing.expect_value(t, err, Catalog_Error.None)
	defer catalog_destroy(&resolved)

	model := catalog_test_find(resolved, "proxy", "gpt-4")
	testing.expect(t, model != nil)
	testing.expect_value(t, model.display_name, "Configured Name") // the user's, not models.dev's
	testing.expect_value(t, model.context_window, 131072) // the provider's
	testing.expect_value(t, model.max_output_tokens, 32768) // models.dev's
	testing.expect(t, model.tools_present && model.tools)

	// A model only the provider reports is still resolvable: the provider stage can
	// introduce a model, not just fill fields on one the user named.
	provider_only, provider_err := resolve_catalog({}, provider, models_dev)
	testing.expect_value(t, provider_err, Catalog_Error.None)
	defer catalog_destroy(&provider_only)
	discovered := catalog_test_find(provider_only, "proxy", "gpt-4")
	testing.expect(t, discovered != nil)
	testing.expect_value(t, discovered.context_window, 131072)
	testing.expect_value(t, discovered.display_name, "Catalog Name") // user stated nothing here
}

@(test)
test_enrichment_unknown_model_assumes_the_default_window :: proc(t: ^testing.T) {
	// No source describes the model at all.
	resolved, err := resolve_catalog({}, {}, {})
	testing.expect_value(t, err, Catalog_Error.None)
	defer catalog_destroy(&resolved)
	testing.expect_value(t, len(resolved.providers), 0)
	testing.expect_value(t, len(resolved.models), 0)

	// A model no source described still gets a capacity, derived from the assumed window
	// rather than left at zero.
	assumed := model_capacity(Catalog_Model{})
	testing.expect_value(t, assumed.window, CHAT_DEFAULT_CONTEXT_WINDOW)
	testing.expect_value(t, CHAT_DEFAULT_CONTEXT_WINDOW, 128 * 1024)
	testing.expect(t, chat_capacity_input_ceiling(assumed) > 0)

	// A window a source stated is used as stated, including an explicit zero, which
	// stays zero and is refused by admission rather than becoming the default.
	stated := model_capacity(Catalog_Model{context_window_present = true, context_window = 8192})
	testing.expect_value(t, stated.window, 8192)
	zeroed := model_capacity(Catalog_Model{context_window_present = true, context_window = 0})
	testing.expect_value(t, zeroed.window, 0)
	testing.expect_value(t, chat_capacity_input_ceiling(zeroed), 0)
}

@(test)
test_enrichment_unknown_model_sends_no_reasoning :: proc(t: ^testing.T) {
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)

	_test_accept(t, chat, "hello")
	prep, prep_err := chat_prepare(chat, tool_loop_connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)

	// Nothing provider-specific is asserted about reasoning: the provider applies
	// its own default.
	testing.expect(t, !prep.request.Reasoning_Effort_Present)
	testing.expect_value(t, prep.request.Reasoning_Effort, "")

	// No level could be chosen either, because the model states none.
	testing.expect(t, !chat_session_set_effort(chat, "high"))
	testing.expect_value(t, chat.effort, "")

	// The assumed window is still enough to admit an ordinary request.
	_, admitted := chat_admission_check(chat, prep.estimate)
	testing.expect(t, admitted)
}

@(test)
test_enrichment_stated_levels_send_the_chosen_effort :: proc(t: ^testing.T) {
	// The contrast that makes the silence above meaningful: when a source does state
	// a level, the chosen one is sent.
	fixture: Chat_Test
	chat_test_begin(t, &fixture, tool_loop_workspace(t))
	defer chat_test_end(t, &fixture)
	chat := &fixture.chat
	chat_test_capacity(chat, CHAT_DEFAULT_CONTEXT_WINDOW)
	testing.expect(t, !chat_session_set_effort(chat, "high"))
	append(&chat.effort_levels, chat_clone_string("high", chat.allocator))
	testing.expect(t, chat_session_set_effort(chat, "high"))

	_test_accept(t, chat, "hello")
	prep, prep_err := chat_prepare(chat, tool_loop_connection)
	if prep_err != nil { testing.fail_now(t, "chat_prepare failed") }
	defer chat_request_prep_destroy(&prep, chat.allocator)
	testing.expect(t, prep.request.Reasoning_Effort_Present)
	testing.expect_value(t, prep.request.Reasoning_Effort, "high")
}
