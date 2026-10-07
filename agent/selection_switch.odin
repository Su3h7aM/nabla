package agent

import "core:mem/virtual"

import "nabla:agent/journal"
import "nabla:ai"

Selection_Status :: enum {
	Ready,
	Pending,
	Refused,
}

Selection_Transition_Phase :: enum {
	None,
	Awaiting_Start,
	Awaiting_Job,
	Needs_Recheck,
	Ready,
	Refused,
}

// Selection_Transition is caller-owned progress for one selection intent. It owns no
// resources and stores no target identity; the caller retains and resupplies the selection.
Selection_Transition :: struct {
	phase:      Selection_Transition_Phase,
	generation: u64,
	checkpoint: journal.Node_Id,
	estimate:   int,
}

// chat_selection_check projects committed history for target, journals each decision, and
// reuses the current session's background compaction. target and transition are borrowed;
// problem is a temporary view. Storage and projection errors are returned as journal.Error.
@(require_results)
chat_selection_check :: proc(
	chat: ^Chat_Session,
	target: Model_Selection,
	transition: ^Selection_Transition,
	allow_compact: bool,
	current_connection: ai.Provider_Connection,
) -> (
	status: Selection_Status,
	problem: string,
	error: journal.Error,
) {
	switch transition.phase {
	case .Ready:
		return .Ready, "", nil
	case .Refused:
		return .Refused, "the requested model selection was refused", nil
	case .Awaiting_Start, .Awaiting_Job, .Needs_Recheck:
	case .None:
	}

	_ = chat_compact_service(chat, {})
	if transition.phase == .Awaiting_Job && chat.compact.checkpoint != transition.checkpoint {
		transition.phase = .Needs_Recheck
	}
	if transition.phase == .Awaiting_Job {
		if chat.compact.completed_generation == transition.generation {
			switch chat.compact.completed_outcome {
			case .Failed:
				transition.phase = .Refused
				return .Refused, "the requested model switch could not be prepared because compaction failed", nil
			case .Canceled:
				transition.phase = .Refused
				return .Refused, "the requested model switch could not be prepared because compaction was canceled", nil
			case .None, .Installed:
			}
		}
		if chat.compact.job_generation == transition.generation &&
		   (chat.compact.state == .Running || chat.compact.state == .Ready || chat.compact.state == .Backoff || chat.compact.state == .Retiring) {
			return .Pending, "", nil
		}
		if chat.compact.state == .Idle && chat.compact.checkpoint == transition.checkpoint {
			transition.phase = .Refused
			return .Refused, "the requested model switch could not start compaction", nil
		}
	}
	if transition.phase == .Awaiting_Start {
		if chat.compact.job_generation > transition.generation {
			transition.generation = chat.compact.job_generation
			transition.phase = .Awaiting_Job
			transition.checkpoint = chat.compact.checkpoint
			return .Pending, "", nil
		}
		if chat.compact.state == .Running || chat.compact.state == .Ready || chat.compact.state == .Backoff {
			transition.generation = chat.compact.job_generation
			transition.phase = .Awaiting_Job
			transition.checkpoint = chat.compact.checkpoint
			return .Pending, "", nil
		}
		transition.phase = .Refused
		return .Refused, "the requested model switch could not start compaction", nil
	}

	arena: virtual.Arena
	if arena_error := virtual.arena_init_growing(&arena); arena_error != nil {
		return .Refused, "the target request could not be prepared", arena_error
	}
	defer virtual.arena_destroy(&arena)
	projection, projection_error := projection_load(chat.store, chat.session, chat.head, virtual.arena_allocator(&arena))
	if projection_error != nil { return .Refused, "", projection_error }

	same_identity := target.provider_id == chat.provider_id && target.model_id == chat.model_id && target.connection.API == chat.model_api
	effort := model_selection_effort(target, chat.effort)
	refused_features: Optional_Request_Features
	if same_identity {
		refused_features = chat.refused_features
	}
	// The pair describes the current selection only; a different target starts raw.
	calibration := chat.calibration if same_identity else Chat_Calibration{}
	prep: Chat_Request_Prep
	build_error := chat_build_request_selection_into(
		chat,
		&prep,
		projection.items,
		projection.summary,
		target.connection,
		target.provider_id,
		target.model_id,
		target.capacity,
		target.tools,
		effort,
		refused_features,
		calibration,
		"",
		virtual.arena_allocator(&arena),
	)
	if build_error != nil { return .Refused, "the target request could not be prepared", build_error }

	ceiling := chat_capacity_input_ceiling(target.capacity)
	part_too_large := target.capacity.window <= 0 || prep.sizes.instructions > ceiling || prep.sizes.tools > ceiling
	_, fits := chat_request_output_bound(target.capacity, prep.estimate)
	decision := journal.Selection_Fit_Decision.Compact
	reason := "the target estimate exceeds its admission budget"
	if fits {
		decision = .Fits
		reason = ""
	} else if part_too_large || !allow_compact {
		decision = .Refused
		switch {
		case target.capacity.window <= 0:
			reason = "the target has no usable context window"
		case prep.sizes.instructions > ceiling:
			reason = "the instructions alone exceed the target admission budget"
		case prep.sizes.tools > ceiling:
			reason = "the tool schemas alone exceed the target admission budget"
		case:
			reason = "the target estimate exceeds its admission budget and compact_on_switch is disabled"
		}
	}
	if transition.phase == .Needs_Recheck && prep.estimate >= transition.estimate {
		decision = .Refused
		reason = "compaction did not reduce the target estimate"
	}
	output, _ := chat_request_output_bound(target.capacity, prep.estimate)
	recheck := transition.phase == .Needs_Recheck
	// A session nobody prompted has no row to carry the decision; its first turn records the
	// selection it starts with instead.
	if chat_journal_writable(chat) {
		chat_record(
			chat,
			{kind = .Selection_Fit, provider = target.provider_id, model = target.model_id},
			journal.Selection_Fit {
				version = 1,
				api = chat_api_name(target.connection.API),
				recheck = recheck,
				decision = journal.SELECTION_FIT_DECISION_NAMES[decision],
				estimate = prep.estimate,
				context_window = target.capacity.window,
				margin = target.capacity.margin,
				output = output,
				reason = reason,
			},
		)
		if _, commit_error := journal.commit(chat.store); commit_error != nil {
			chat_session_record_failure(chat, "the target selection decision could not be recorded", commit_error)
			return .Refused, "", commit_error
		}
	}
	if decision == .Fits {
		transition.phase = .Ready
		return .Ready, "", nil
	}
	if decision == .Refused {
		transition.phase = .Refused
		return .Refused, reason, nil
	}
	transition.estimate = prep.estimate
	transition.checkpoint = projection.checkpoint
	transition.generation = chat.compact.job_generation
	transition.phase = .Awaiting_Start
	if chat_compact_request(chat, .Model_Switch) == .Unavailable {
		transition.phase = .Refused
		return .Refused, "compaction is unavailable for the requested model switch", nil
	}
	if chat.compact.state == .Idle {
		current_prep, current_prep_error := chat_prepare(chat, current_connection, virtual.arena_allocator(&arena))
		if current_prep_error != nil {
			transition.phase = .Refused
			return .Refused, "the current context could not be prepared for compaction", current_prep_error
		}
		chat_compact_consider(chat, {}, current_connection, &current_prep)
		if chat.compact.job_generation > transition.generation {
			transition.generation = chat.compact.job_generation
			transition.checkpoint = chat.compact.checkpoint
			transition.phase = .Awaiting_Job
		} else if chat.compact.state == .Running || chat.compact.state == .Ready || chat.compact.state == .Backoff {
			transition.generation = chat.compact.job_generation
			transition.checkpoint = chat.compact.checkpoint
			transition.phase = .Awaiting_Job
		} else {
			transition.phase = .Refused
			return .Refused, "compaction could not start for the requested model switch", nil
		}
	} else {
		transition.generation = chat.compact.job_generation
		transition.checkpoint = chat.compact.checkpoint
		transition.phase = .Awaiting_Job
	}
	return .Pending, "", nil
}

// chat_selection_record commits the selection.applied record of the model a session now
// runs. A session nobody prompted is created by its first prompt, so there is nowhere to
// keep the record yet; its first turn records the selection instead, and this returns nil.
// The error is the journal's commit failure; the caller decides what it stops.
@(require_results)
chat_selection_record :: proc(chat: ^Chat_Session, api: ai.API_Kind, provider, model, effort: string) -> journal.Error {
	if !chat_journal_writable(chat) { return nil }
	chat_record(
		chat,
		{kind = .Selection_Applied, provider = provider, model = model},
		journal.Selection_Applied{version = 1, api = chat_api_name(api), provider = provider, model = model, effort = effort},
	)
	_, commit_error := journal.commit(chat.store)
	return commit_error
}

// chat_selection_install makes target, which fits the session, the model its next request
// runs: the session takes its own copy, a compaction in flight for another serving identity
// is canceled, the provider WebSocket is dropped when the identity or the connection changed,
// the token estimates restart, and the selection.applied record is committed. effort is one of
// the target's levels or "". current_connection is the connection the session's requests have
// used until now. Owner only, with the session idle or at a request boundary; target is
// borrowed.
//
// installed is false when the session could not hold the selection, and then nothing changed.
// applied is false when the effort was not applied. record_error is the failure to commit the
// record, which leaves the model installed; the caller decides what it stops.
@(require_results)
chat_selection_install :: proc(
	chat: ^Chat_Session,
	target: Model_Selection,
	effort: string,
	current_connection: ai.Provider_Connection,
) -> (
	installed: bool,
	applied: bool,
	record_error: journal.Error,
) {
	identity_changed := target.provider_id != chat.provider_id || target.model_id != chat.model_id || target.connection.API != chat.model_api
	connection_changed :=
		current_connection.API != target.connection.API ||
		current_connection.Endpoint != target.connection.Endpoint ||
		chat.provider_transport != target.transport
	refused_features, omitted_features := chat.refused_features, chat.compact.omitted_features
	installed, applied = chat_session_select(chat, target, effort)
	if !installed { return false, false, nil }
	// A different serving identity invalidates a pending summary and what the provider
	// refused. A metadata-only refresh of the same identity keeps both, so a summary in
	// flight and a feature the provider already refused stay as they are.
	if identity_changed {
		chat_compact_cancel(chat)
	} else {
		chat.refused_features, chat.compact.omitted_features = refused_features, omitted_features
	}
	if chat.provider_websocket != nil && (identity_changed || connection_changed) {
		ai.Provider_WebSocket_Session_Destroy(chat.provider_websocket)
		chat.provider_websocket = nil
	}
	chat.last_estimate = 0
	chat.last_input_measured = nil
	record_error = chat_selection_record(chat, target.connection.API, target.provider_id, target.model_id, chat.effort)
	return
}
