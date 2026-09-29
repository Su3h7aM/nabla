package agent

import "core:crypto/hash"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:thread"
import "core:time"

import "nabla:agent/journal"
import "nabla:ai"

// --- the request chain ---------------------------------------------------------
//
// One logical request is a chain of bounded attempts. The chain is session state because
// the driver performs one effect at a time and returns to its loop between them: a retry
// is request state under Awaiting_Model, not a nested loop. Each attempt is one worker
// thread, and the chain owns the prepared request, the frozen bytes, the worker's handle,
// and the last attempt's error. chat_chain_release is the one place they are freed.

// Chat_Request_Stage is where a chain is between attempts. Only the stages that must
// survive a return to the driver are here, and each stage names exactly one effect.
Chat_Request_Stage :: enum {
	// Ready: the next attempt may be sent.
	Ready,
	// Sending: the attempt was claimed, its row is written, and its worker is live. The
	// owner collects what the worker has published and waits for its terminal outcome; the
	// stage changes only once the owner has that outcome.
	Sending,
	// Backoff: the chain waits out the delay before its next attempt.
	Backoff,
	// Repairing: the provider refused the payload as too large, so the chain waits for or
	// starts a summary before rebuilding the request.
	Repairing,
	// Committing: the chain has stopped and its response must be recorded.
	Committing,
}

// Chat_Request_Chain is one logical request's attempt chain. connection, observer and
// options are borrowed from the turn that owns them and stay valid for the chain's life.
Chat_Request_Chain :: struct {
	active:                    bool,
	stage:                     Chat_Request_Stage,
	connection:                ai.Provider_Connection,
	policy:                    Chat_Retry_Policy,
	observer:                  Chat_Observer,
	options:                   ai.Provider_Operation_Options,
	// worker is the thread running the current attempt, nil when none is live. worker_data
	// is the argument the owner allocated for it, freed only after the join.
	worker:                    ^thread.Thread,
	worker_data:               ^Chat_Request_Worker,
	// mailbox is where the attempt's worker publishes: the events it received, and the one
	// terminal it ends with. It belongs to the chain rather than to the session, so an attempt
	// whose worker ignored its stop can keep publishing into it after the chain is released,
	// while the next request uses a mailbox of its own and never sees those facts. It lives in
	// scratch, which is the arena an abandoned attempt is retained with.
	mailbox:                   ^Owner_Mailbox,
	// stop_at is when the owner first saw that this attempt should have stopped, and the stop
	// patience is measured from it. abandoned records that its worker had not published by the
	// end of that patience, or was still in flight at teardown: the release then retains
	// everything that worker can still reach rather than joining it.
	stop_at:                   Maybe(time.Tick),
	abandoned:                 bool,
	// scratch is the arena the chain builds its request in: the context read out of the
	// store, the messages the projection makes, the entries it points at, the frozen bytes it
	// sends, the worker's argument, and the mailbox the worker publishes through. Releasing the
	// chain returns all of it in one unmap, and an abandoned attempt is retained with it. A
	// zero arena is inert, so a chain that never ran holds nothing.
	scratch:                   virtual.Arena,
	prep:                      Chat_Request_Prep,
	encoded:                   ai.Provider_Encoded_Request,
	websocket_request:         bool,
	// attempts counts the sends this chain has made, including one whose row just landed.
	attempts:                  int,
	// operation_error is the last attempt's error, owned until the chain releases it or
	// a retry discards it.
	operation_error:           ai.Provider_Operation_Error,
	finish_reason:             ai.Provider_Finish_Reason,
	text_exposed:              bool,
	completion_accepted:       bool,
	// assistant_open records that the observer was told a response is streaming. A resend
	// closes it, because the response it showed part of is dropped and the resend is a new one.
	assistant_open:            bool,
	// source is the event source of the last attempt, which its staged output commits under.
	source:                    Chat_Event_Source,
	// request is the id every attempt of this chain is recorded under, allocated by the
	// first claim.
	request:                   journal.Request_Id,
	recovery_kind:             Chat_Recovery_Kind,
	// repaired records that this chain has used its one context repair. It never resets,
	// because the bound belongs to the chain rather than to the payload it sends.
	repaired:                  bool,
	// repair_compaction_started records that this repair started its one compaction. A
	// terminal compaction failure must not start another job for the same refused request.
	repair_compaction_started: bool,
	// retries counts the scheduled resends this chain made, which the policy bounds.
	retries:                   int,
	// cache_hints_omitted records that this chain resent its request without the cache
	// hints after a refusal, which it does once.
	cache_hints_omitted:       bool,
	// settled records that the last row was finished for a retry, so the response commit
	// must not finish it twice.
	settled:                   bool,
	// decision is what the harness decided about the last send, and, once the chain has
	// stopped, why it stopped.
	decision:                  Chat_Recovery_Decision,
}

// Chat_Abandoned_Attempt is one attempt whose worker had not published when the chain was
// released: a worker that ignored its stop for the whole patience, or one still in flight at
// teardown. The owner never joins it and frees nothing it can reach, so everything the worker
// touches is here instead: its thread handle, its mailbox, and the arena that holds its
// argument, the request it was built from, and the frozen bytes it is sending. What it
// publishes later is dropped, because the send already has the outcome it was recorded with.
Chat_Abandoned_Attempt :: struct {
	worker:    ^thread.Thread,
	mailbox:   ^Owner_Mailbox,
	arena:     virtual.Arena,
	// websocket records that the worker may still be using the session's WebSocket, which
	// teardown therefore leaves allocated instead of destroying it under the worker.
	websocket: bool,
}

// chat_chain_release frees everything the chain owns, joining a worker that published. The
// zero chain is inert, so releasing one that never ran is safe. It retires the operation the
// chain began: a release that is not a commit, such as one after an attempt row that could not
// be written, is the only thing left that can, and an operation left running would leave the
// turn with no stage it can reach a terminal from.
//
// A worker that has not published is asked to stop and abandoned: the owner frees nothing it
// can still reach, and a release reached by teardown or by a failed commit never waits on a
// worker that ignores its stop.
chat_chain_release :: proc(chat: ^Chat_Session) {
	chain := &chat.chain
	chat_session_retire_operation(chat)
	if !chain.abandoned && chain.worker != nil {
		// The terminal is the worker's last act, so a worker that published it is done. One a
		// release takes here belongs to a send whose outcome is already recorded, and it is
		// dropped rather than waited on.
		terminal, published := mailbox_take_terminal(chain.mailbox)
		ai.Provider_Operation_Error_Destroy(&terminal.error, chain.mailbox.allocator)
		if !published {
			ai.interrupt_request(chain.options.interrupt)
			chat_chain_abandon(chat)
		}
	}
	if chain.abandoned {
		chat_chain_retain_attempt(chat)
		chain^ = {}
		return
	}
	chat_chain_join(chat)
	// The request the chain built came from its arena, so there is one release for it rather
	// than a walk over the context it read, the bytes it sent, and the projection it made.
	if chain.mailbox != nil { mailbox_destroy(chain.mailbox) }
	// A worker's payloads come from the process heap, which is where the mailbox put them.
	ai.Provider_Operation_Error_Destroy(&chain.operation_error, os.heap_allocator())
	virtual.arena_destroy(&chain.scratch)
	chain^ = {}
}

// chat_chain_join waits for the attempt's worker to finish and drops its argument,
// which came from the chain's arena. The worker's last mailbox access is its
// terminal publication, so after the join what it was sending is the owner's to release.
@(private)
chat_chain_join :: proc(chat: ^Chat_Session) {
	if chat.chain.worker != nil {
		thread.join(chat.chain.worker)
		thread.destroy(chat.chain.worker)
		chat.chain.worker = nil
	}
	chat.chain.worker_data = nil
}

// chat_chain_stop latches why the chain stopped and moves it to its commit. Selection
// only reads, so the transition lives here and in the effect that observed the stop.
@(private)
chat_chain_stop :: proc(chat: ^Chat_Session, reason: Request_Recovery_Reason) {
	chat.chain.decision = {
		action = .Stop,
		reason = reason,
	}
	chat.chain.stage = .Committing
}

// chat_chain_note_stop records when the owner first saw that the attempt in flight should
// have stopped, which is where the patience it is given to confirm is measured from. Only a
// worker that was asked to stop can be abandoned, and only the owner's own observation can
// start the patience: nothing else reads the clock on the chain's behalf.
chat_chain_note_stop :: proc(chat: ^Chat_Session, now: time.Tick) {
	chain := &chat.chain
	if chain.stop_at != nil || !chain.active || chain.stage != .Sending || chain.worker == nil { return }
	if !ai.interrupt_requested(chain.options.interrupt) { return }
	chain.stop_at = now
	fields := [1]Log_Field{{key = "patience_ms", value = Log_Duration_Milliseconds(TOOL_JOBS_STOP_PATIENCE)}}
	log_emit({level = .Warning, category = .Provider, event = "provider.attempt_stopping", fields = fields[:]})
}

// chat_chain_patience_deadline is when the owner stops waiting for an attempt that was asked
// to stop and has not confirmed. It is nil while no stop was asked for, because a provider
// attempt carries cancellation alone: model deliberation has no harness deadline.
@(private)
chat_chain_patience_deadline :: proc(chain: ^Chat_Request_Chain) -> Maybe(time.Tick) {
	at, started := chain.stop_at.?
	if !started { return nil }
	return time.tick_add(at, TOOL_JOBS_STOP_PATIENCE)
}

// chat_chain_overdue reports whether the attempt's worker has ignored its stop for the whole
// patience, which is as long as the owner waits for a worker that has not published.
@(private)
chat_chain_overdue :: proc(chain: ^Chat_Request_Chain) -> bool {
	at, started := chain.stop_at.?
	if !started { return false }
	return time.tick_since(at) >= TOOL_JOBS_STOP_PATIENCE
}

// chat_chain_abandon gives up on an attempt whose worker has not confirmed its stop. The send
// may still be running, so it is answered with the cancellation that asked it to stop: the
// commit that follows records that outcome, and the release retains everything the worker can
// still reach instead of joining it.
@(private)
chat_chain_abandon :: proc(chat: ^Chat_Session) {
	chain := &chat.chain
	chain.decision = {
		action = .Stop,
		reason = .Cancelled,
	}
	chain.stage = .Committing
	chain.abandoned = true
	waited: time.Duration
	if at, started := chain.stop_at.?; started { waited = time.tick_since(at) }
	fields := [2]Log_Field {
		{key = "waited_ms", value = i64(waited / time.Millisecond)},
		{key = "patience_ms", value = Log_Duration_Milliseconds(TOOL_JOBS_STOP_PATIENCE)},
	}
	log_emit({level = .Error, category = .Provider, event = "provider.attempt_abandoned", fields = fields[:]})
}

// chat_chain_retain_attempt moves everything an abandoned attempt's worker can still reach out
// of the chain and into a record the owner never joins. A record that cannot be allocated
// retains nothing, and the release that follows frees nothing either: leaving the worker's
// storage where it is is the only release that cannot free memory the worker is still using.
@(private)
chat_chain_retain_attempt :: proc(chat: ^Chat_Session) {
	chain := &chat.chain
	attempt, allocation_error := new(Chat_Abandoned_Attempt, os.heap_allocator())
	if allocation_error != nil {
		log_emit({level = .Error, category = .Provider, event = "provider.attempt_leaked"})
		return
	}
	attempt^ = {
		worker    = chain.worker,
		mailbox   = chain.mailbox,
		arena     = chain.scratch,
		websocket = chain.websocket_request,
	}
	if append(&chat.abandoned_attempts, attempt) != 1 {
		// The record exists and the list could not grow, so the attempt stays with the record
		// rather than being released: nothing the worker can reach is freed either way.
		log_emit({level = .Error, category = .Provider, event = "provider.attempt_leaked"})
	}
}

// chat_chain_attempts_reclaim releases every abandoned attempt whose worker has published
// since. What it published is dropped, because the send already has the outcome it was
// recorded with, and the worker is joined only now, when joining cannot block on it.
chat_chain_attempts_reclaim :: proc(attempts: ^[dynamic]^Chat_Abandoned_Attempt) {
	for index := len(attempts) - 1; index >= 0; index -= 1 {
		attempt := attempts[index]
		terminal, published := mailbox_take_terminal(attempt.mailbox)
		if !published { continue }
		ai.Provider_Operation_Error_Destroy(&terminal.error, attempt.mailbox.allocator)
		thread.destroy(attempt.worker)
		mailbox_destroy(attempt.mailbox)
		virtual.arena_destroy(&attempt.arena)
		free(attempt, os.heap_allocator())
		unordered_remove(attempts, index)
		log_emit({level = .Info, category = .Provider, event = "provider.attempt_reclaimed"})
	}
}

// chat_chain_websocket_retained reports whether an abandoned attempt may still be using the
// session's WebSocket, which teardown therefore leaves allocated.
@(private)
chat_chain_websocket_retained :: proc(chat: ^Chat_Session) -> bool {
	for attempt in chat.abandoned_attempts {
		if attempt.websocket { return true }
	}
	return false
}

// chat_body_digest returns the hex SHA-256 of body, written into buffer of
// journal.DIGEST_HEX_LENGTH bytes and aliasing it, and the body's length. An empty body is "" and 0.
@(private)
chat_body_digest :: proc(body: []u8, buffer: []u8) -> (digest: string, bytes: int) {
	if len(body) == 0 { return "", 0 }
	raw: journal.Digest
	hash.hash_bytes_to_buffer(.SHA256, body, raw[:])
	return journal.digest_to_hex(raw, buffer), len(body)
}

// chat_record_attempt commits request.sent for one send before it goes out, with the digest
// and the size of the exact bytes that send will carry. It reports false after latching a
// storage failure, which stops the turn: a send whose record did not land is not sent.
@(private, require_results)
chat_record_attempt :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, request: journal.Request_Id, attempt: Chat_Attempt, body: []u8) -> bool {
	header := journal.Record {
		kind     = .Request_Sent,
		request  = request,
		attempt  = journal.Attempt_No(attempt.number),
		provider = chat.provider_id,
		model    = chat.model_id,
	}
	digest_buffer: [journal.DIGEST_HEX_LENGTH]u8
	body_digest, body_bytes := chat_body_digest(body, digest_buffer[:])
	sent := journal.Request_Sent {
		purpose         = journal.REQUEST_PURPOSE_NAMES[.Response],
		api             = chat_api_name(connection.API),
		model_requested = chat.model_id,
		recovery        = CHAT_RECOVERY_KIND_NAMES[attempt.recovery],
		body_digest     = body_digest,
		body_bytes      = body_bytes,
	}
	chat_record(chat, header, sent)
	return chat_commit(chat, "the request could not be recorded")
}

// chat_try_context_repair makes room for a payload the provider refused as too large.
// It returns None when a summary was installed and the request rebuilt, Summary_Running
// while a compaction is running or in backoff, and otherwise the typed repair result.
@(private, require_results)
chat_try_context_repair :: proc(
	chat: ^Chat_Session,
	connection: ai.Provider_Connection,
	observer: Chat_Observer,
	prep: ^Chat_Request_Prep,
	encoded: ^ai.Provider_Encoded_Request,
	websocket_request: bool,
	attempts: int,
) -> Chat_Repair_Refusal {
	previous_estimate := prep.estimate
	refusal := chat_repair_context(
		chat,
		connection,
		observer,
		prep,
		encoded,
		previous_estimate,
		websocket_request,
		virtual.arena_allocator(&chat.chain.scratch),
	)
	if refusal == .No_Candidate && chat.compact.state == .Idle && !chat.chain.repair_compaction_started {
		chat.chain.repair_compaction_started = true
		if chat_compact_request(chat, .Provider_Overflow) != .Unavailable {
			chat_compact_consider(chat, observer, connection, prep)
		}
		if chat.compact.state == .Running || chat.compact.state == .Backoff {
			return .Summary_Running
		}
	}
	if refusal != .None {
		return refusal
	}
	repaired := [4]Log_Field {
		{key = "covers", value = i64(prep.projection.covers)},
		{key = "estimate_before", value = i64(previous_estimate)},
		{key = "estimate_after", value = i64(prep.estimate)},
		{key = "next_attempt", value = i64(attempts + 1)},
	}
	log_emit({level = .Info, category = .Provider, event = "request.context_repaired", fields = repaired[:]})
	return .None
}

// --- effect handlers -----------------------------------------------------------

// chat_request_begin is the request boundary and the freeze that follows it: it claims the
// request, installs any finished compaction, prepares the projection, admits it, and
// freezes the exact bytes. It creates the chain and returns; the driver sends the first
// attempt as its own effect, so a boundary that stopped the turn claims nothing.
@(private)
chat_request_begin :: proc(chat: ^Chat_Session, connection: ai.Provider_Connection, policy: Chat_Retry_Policy, observer: Chat_Observer) {
	if !chat_session_begin_request(chat) { return }
	if chat.skill_instructions == "" && !chat_ensure_instructions(chat) { return }
	// This request has no id yet, and the one the previous request left behind is not its
	// own; the first claim allocates it.
	chat.request = 0
	binding: Log_Binding
	previous_logger := context.logger
	defer context.logger = previous_logger
	context.logger = log_rebind(&binding, log_correlation(chat))

	// A finished summary is installed at a request boundary, so the context the request is
	// built from is the one this session will actually send.
	// The result only says whether the context changed; the request below is prepared from
	// the context as it is now either way.
	_ = chat_compact_service(chat, observer)
	// A boundary whose own durable write failed has nothing to prepare from: the record and
	// the conversation have diverged, and no request may be built on that.
	if chat_session_storage_failed(chat) { return }

	// Request data borrows this arena, so initialize it at the address the chain keeps
	// through every attempt. Until the chain is ready, this scope releases it on failure.
	chain := &chat.chain
	if arena_error := virtual.arena_init_growing(&chain.scratch); arena_error != nil {
		chat_session_fail_turn(chat, "the request scratch could not be allocated")
		return
	}
	scratch_owned := true
	defer {
		if scratch_owned {
			virtual.arena_destroy(&chain.scratch)
			chain^ = {}
		}
	}
	scratch_allocator := virtual.arena_allocator(&chain.scratch)

	prep, prep_err := chat_prepare(chat, connection, scratch_allocator)
	if prep_err != nil {
		chat_session_record_failure(chat, "the request context could not be read", prep_err)
		return
	}

	// The exact request about to be sent is what a compaction freezes, so it is considered
	// here, after the boundary above and before admission decides anything. Compaction never
	// runs in the foreground: this only starts a background job for a filling context.
	chat_compact_consider(chat, observer, connection, &prep)

	// A request that does not fit is refused unless a summary that already finished can be
	// installed right now. Nothing waits for compaction: a request that still does not fit
	// fails explicitly, and the turn is told why.
	message, admitted := chat_admission_check(chat, prep.estimate, prep.sizes)
	if !admitted {
		if chat_compact_relieve(chat, observer) && !chat_session_cancelled(chat) {
			if !chat_rebuild_prep(chat, connection, &prep, scratch_allocator) { return }
			message, admitted = chat_admission_check(chat, prep.estimate, prep.sizes)
		}
		if !admitted {
			// The request never reached a provider, so the turn ends with the reason
			// admission refused it rather than with a send that did not happen.
			chat.turn_recovery = .Context_Exhausted
			if chat_session_cancelled(chat) {
				chat_session_note_cancel(chat)
			} else {
				chat_session_fail_turn(chat, message)
			}
			return
		}
	}
	if chat_session_cancelled(chat) {
		chat_session_note_cancel(chat)
		return
	}

	// The request carries interruption only. No deadline is set: it stays open as long as
	// the provider keeps it open, and ends when the provider, the transport, or
	// cancellation ends it.
	options := ai.Provider_Operation_Options {
		interrupt = &chat.stop,
	}
	// The bytes this request sends are frozen once, before the first attempt, so every
	// attempt of the chain sends exactly what the first would have sent instead of a fresh
	// encoding that has to be assumed equal.
	encoded, websocket_request, transport_ok := chat_request_transport(chat, connection, &prep, options)
	if !transport_ok { return }
	// The bytes this attempt sends must outlive the chain, because a worker that ignores its
	// stop may still be sending them after the chain is released. The transport freezes through
	// the session's encode cache, whose next encode writes over them, so the attempt gets its
	// own copy in the arena the chain owns and an abandoned attempt is retained with.
	body, body_error := make([]u8, len(encoded.Body), scratch_allocator)
	if body_error != nil {
		chat_session_fail_turn(chat, "the request body could not be kept for the attempt")
		return
	}
	copy(body, encoded.Body)
	if !encoded.Body_Borrowed { delete(encoded.Body, chat.allocator) }
	encoded.Body = body
	encoded.Body_Borrowed = false

	// What the harness intends to send is recorded before it is stored, so a request that
	// never reaches the store still says what it was going to carry.
	prepared := [10]Log_Field {
		{key = "purpose", value = journal.REQUEST_PURPOSE_NAMES[.Response]},
		{key = "provider", value = chat.provider_id},
		{key = "model", value = chat.model_id},
		{key = "api", value = chat_api_name(connection.API)},
		{key = "transport", value = websocket_request ? "websocket" : "http"},
		{key = "estimate", value = i64(prep.estimate)},
		{key = "context_window", value = i64(chat.capacity.window)},
		{key = "messages", value = i64(len(prep.projection.items))},
		{key = "tools", value = i64(len(prep.tools))},
		// The endpoint's own records this request did not carry: a prefix change the
		// conversation's content survived, and the only trace a contradictory or
		// unreadable record leaves.
		{key = "replay_refused", value = i64(prep.replay_refused)},
	}
	context.logger = log_rebind(&binding, log_correlation(chat))
	log_emit({level = .Info, category = .Provider, event = "request.prepared", fields = prepared[:]})

	chat.last_estimate = prep.estimate
	chain.active = true
	chain.stage = .Ready
	chain.connection = connection
	chain.policy = policy
	chain.observer = observer
	chain.options = options
	chain.prep = prep
	chain.encoded = encoded
	chain.websocket_request = websocket_request
	chain.recovery_kind = .Transient_Retry
	scratch_owned = false
}

// chat_chain_claim_send claims the next attempt: it retires the previous operation, begins
// a new one, and writes the durable row, all before the network work. Repeated claims fail
// because the stage no longer allows them, which is what keeps a proposal from launching
// twice.
@(private)
chat_chain_claim_send :: proc(chat: ^Chat_Session) -> bool {
	chain := &chat.chain
	if !chain.active || chain.stage != .Ready { return false }
	// A turn stopped since the last attempt must not start another send.
	if chat_session_cancelled(chat) {
		chat_chain_stop(chat, .Cancelled)
		return false
	}
	// A latched storage failure means the record and the conversation have diverged, so no
	// further send may be launched against it.
	if chat_session_storage_failed(chat) {
		chat_chain_stop(chat, .Storage_Failed)
		return false
	}
	number := chain.attempts + 1
	// Each send is its own operation: the attempt before it retires as this one begins, so
	// the cancellation gate, the event source, and the usage reports name exactly one send.
	chat_session_retire_operation(chat)
	chat_session_begin_operation(chat)
	chain.source = chat_session_event_source(chat)
	chain.settled = false
	// Exposure and acceptance belong to one attempt: a retry that produces nothing must not
	// inherit the exposure or the accepted completion of the attempt before it.
	chain.text_exposed = false
	chain.completion_accepted = false
	attempt := Chat_Attempt {
		number   = number,
		recovery = number == 1 ? .Initial : chain.recovery_kind,
	}
	if chain.request == 0 { chain.request = journal.next_request(chat.store) }
	if !chat_record_attempt(chat, chain.connection, chain.request, attempt, chain.encoded.Body) {
		// The record did not land, so nothing is sent. The session already latched the
		// storage failure; the chain stops with it and commits nothing, because no attempt began.
		chat_chain_stop(chat, .Storage_Failed)
		return false
	}
	chain.attempts = number
	chat.request = chain.request
	chain.stage = .Sending
	return true
}

// chat_chain_launch_send starts the worker for a claimed attempt: the claim wrote the row,
// and this hands the frozen bytes to the transport and returns without waiting. Selection
// never sees the send; the owner collects the worker's facts and awaits its outcome under
// Await_Provider.
@(private)
chat_chain_launch_send :: proc(chat: ^Chat_Session) {
	chain := &chat.chain
	if !chain.active || chain.stage != .Sending { return }
	// This attempt's correlation: the request number became durable in the claim, and the
	// attempt number is counted there too.
	binding: Log_Binding
	previous_logger := context.logger
	defer context.logger = previous_logger
	context.logger = log_rebind(&binding, log_correlation_for(chat, chain.attempts))

	recorded := [1]Log_Field{{key = "purpose", value = journal.REQUEST_PURPOSE_NAMES[.Response]}}
	log_emit({level = .Info, category = .Storage, event = "request.recorded", fields = recorded[:]})
	// A send that repeats the same bytes after a failure is a retry, so a reader learns the
	// chain resumed without diffing attempt numbers. A repaired send is a new payload, and
	// it says so itself.
	if chain.attempts > 1 && chain.recovery_kind == .Transient_Retry {
		log_emit({level = .Info, category = .Provider, event = "request.retry_started"})
	}
	// The input size is settled and this send has not gone out yet, so this is where a
	// front-end learns what the context now holds, and how a front-end showing a scheduled
	// retry clears it: the send it waited for is about to happen.
	chat.last_estimate = chain.prep.estimate
	_observer_request_prepared(chain.observer)

	// The attempt runs on its own thread so the owner can keep observing while the send
	// blocks, and its facts reach the owner through the chain's own mailbox. Its payloads come
	// from the process heap, because a worker allocates while the owner may be allocating
	// through the session's allocator at the same time. The worker borrows the frozen bytes and
	// the mailbox; an abandoned attempt is retained with both.
	if chain.mailbox == nil {
		new_mailbox, mailbox_error := new(Owner_Mailbox, virtual.arena_allocator(&chain.scratch))
		if mailbox_error != nil {
			chat_session_fail_turn(chat, "the request worker could not be allocated")
			chat_chain_stop(chat, .Harness_Failure)
			return
		}
		mailbox_init(new_mailbox, os.heap_allocator())
		chain.mailbox = new_mailbox
	}
	worker, worker_error := new(Chat_Request_Worker, virtual.arena_allocator(&chain.scratch))
	if worker_error != nil {
		chat_session_fail_turn(chat, "the request worker could not be allocated")
		chat_chain_stop(chat, .Harness_Failure)
		return
	}
	worker^ = Chat_Request_Worker {
		allocator         = chain.mailbox.allocator,
		mailbox           = chain.mailbox,
		interrupt         = chain.options.interrupt,
		source            = chain.source,
		connection        = chain.connection,
		websocket         = chat.provider_websocket,
		websocket_request = chain.websocket_request,
		encoded           = chain.encoded,
		options           = chain.options,
		logging           = binding,
	}
	// The handle comes from the process heap, because an attempt whose worker ignores its stop
	// keeps it and the session's allocator may already be released by then.
	previous_allocator := context.allocator
	context.allocator = os.heap_allocator()
	new_thread := thread.create(chat_request_worker_main, name = "nabla-request")
	context.allocator = previous_allocator
	if new_thread == nil {
		// No producer exists, so nothing will send. The row that was already written stays
		// as the record of a send that was attempted but not performed.
		chat_session_fail_turn(chat, "the request worker could not be started")
		chat_chain_stop(chat, .Harness_Failure)
		return
	}
	new_thread.data = worker
	thread.start(new_thread)
	chain.worker = new_thread
	chain.worker_data = worker
}

// chat_chain_await collects the facts the attempt's worker has published and adopts its
// terminal outcome. Nothing is decided while the producer can still publish: the worker's
// last act is the terminal, so every fact it observed arrives before the decision, and the
// join that follows is what lets the frozen bytes be released.
//
// A worker that has not published by the end of the patience it was given to confirm its stop
// is abandoned instead: the wait ends there, and the owner's next observation abandons it. An
// attempt nothing asked to stop keeps waiting, because model deliberation has no deadline.
@(private)
chat_chain_await :: proc(chat: ^Chat_Session, usages: ^[dynamic]Chat_Request_Usage) {
	chain := &chat.chain
	if !chain.active || chain.stage != .Sending { return }
	seen := owner_wake_seen()
	// The terminal is taken first: the worker publishes it after its last event.
	terminal, published := mailbox_take_terminal(chain.mailbox)
	events := mailbox_take_all(chain.mailbox)
	defer delete(events)
	for &event in events {
		chat_chain_apply_event(chat, usages, &event)
		chat_event_destroy(&event, chain.mailbox.allocator)
	}
	if published {
		chat_chain_join(chat)
		chain.operation_error = terminal.error
		chain.finish_reason = terminal.finish_reason
		chat_chain_settle(chat, usages)
		return
	}
	if chat_chain_overdue(chain) {
		chat_chain_abandon(chat)
		return
	}
	if len(events) == 0 { owner_wake_wait(seen, chat_chain_patience_deadline(chain)) }
}

// chat_chain_apply_event gives one collected provider fact to state and tells the observer
// about text the turn took. Only the owner applies events, so this is where an external
// fact changes turn state; the worker that received it decided nothing.
@(private)
chat_chain_apply_event :: proc(chat: ^Chat_Session, usages: ^[dynamic]Chat_Request_Usage, event: ^Chat_Event) {
	if usage, is_usage := event^.(Chat_Usage_Event); is_usage {
		// The endpoint's own accounting of the request, kept against its usage log.
		chat_session_observe_usage(chat, usages, usage.usage)
		return
	}
	chain := &chat.chain
	applied := chat_session_apply(chat, event)
	if applied.completion_accepted { chain.completion_accepted = true }
	if !applied.text_exposed { return }
	if !chain.assistant_open {
		_observer_assistant_begin(chain.observer)
		chain.assistant_open = true
	}
	if text, is_text := event^.(Chat_Text_Event); is_text {
		_observer_assistant_text(chain.observer, text.text)
	}
}

// chat_session_observe_usage records the endpoint's own accounting of the running request:
// the last input measurement, and one usage entry per report for the request's usage log.
@(private)
chat_session_observe_usage :: proc(chat: ^Chat_Session, usages: ^[dynamic]Chat_Request_Usage, usage: ai.Provider_Usage_Event) {
	if usage.Input_Tokens_Present { chat.last_input_measured = usage.Input_Tokens }
	if _, append_error := append(usages, Chat_Request_Usage{operation = u64(chat.operation.id), usage = usage}); append_error == nil { return }
	// The record of the send is missing the numbers this report carried, and ending the turn
	// would not bring them back: the log line is what records the loss.
	binding: Log_Binding
	previous_logger := context.logger
	defer context.logger = previous_logger
	context.logger = log_rebind(&binding, log_correlation_for(chat, chat.chain.attempts))
	log_emit({level = .Error, category = .Provider, event = "request.usage_lost"})
}

// chat_chain_settle turns the terminal outcome into the next stage. The row is finished
// before anything is waited on or sent again: how the send failed, and what the harness
// decided to do about it, are in the store before the decision is acted on, with the numbers
// and the usage of the send that produced them.
@(private)
chat_chain_settle :: proc(chat: ^Chat_Session, usages: ^[dynamic]Chat_Request_Usage) {
	chain := &chat.chain
	// A response the provider ended without a usable answer failed like a stream the
	// provider broke off, whatever the operation reported.
	if chain.operation_error.kind == .None && chat.response_unusable != .None {
		chain.operation_error.kind = .Stream
		chain.operation_error.failure_class = chat.response_unusable
	}
	// The send is over, so the policy answers from the facts the layers observed: what the
	// operation reported, what this attempt exposed, and whether the turn or the store had
	// already failed.
	chain.decision = chat_recovery_decide(
		chain.policy,
		{
			retries = chain.retries,
			error = chain.operation_error,
			failed = chat.active_failed && chain.operation_error.kind == .None,
			repaired = chain.repaired,
			cache_hints_sent = chat_request_cache_hints(chain.prep.request),
			storage_failed = chat_session_storage_failed(chat),
			completion_accepted = chain.completion_accepted,
			cancelled = chat_session_cancelled(chat),
		},
	)
	if chain.decision.action == .Stop {
		chain.stage = .Committing
		return
	}
	// The send is recorded as ended before anything is waited on or sent again: how it
	// failed, and what the harness decided to do about it, are in the journal before the
	// decision is acted on.
	chat_finish_send(
		chat,
		chain.request,
		chain.attempts,
		{
			outcome = .Failed,
			error = chain.operation_error,
			error_present = true,
			text_exposed = chain.text_exposed,
			completion_accepted = chain.completion_accepted,
			recovery = chain.decision.reason,
			delay = chain.decision.delay,
		},
	)
	chain.settled = true

	if chain.decision.action == .Repair_Context {
		chain.stage = .Repairing
		return
	}
	if chain.decision.action == .Omit_Cache_Hints {
		chat_request_omit_cache_hints(&chain.prep.request)
		if !chat_request_freeze(chat, &chain.prep, &chain.encoded, chain.websocket_request, virtual.arena_allocator(&chain.scratch)) {
			chat_chain_stop(chat, .Harness_Failure)
			return
		}
		// Later requests leave the hints out too, unless the resend is refused as well.
		chat.cache_hints_refused = true
		chain.cache_hints_omitted = true
		chain.recovery_kind = .Cache_Hints_Omitted
	}
	if chain.decision.action == .Retry { chain.retries += 1 }
	// The failed attempt's state and everything it produced are cleared now, so the turn
	// stays cancellable while it waits and the next attempt starts from a clean runtime. A
	// response the front-end already showed part of is closed there: the resend is a new one.
	chat_session_clear_attempt(chat)
	if chain.assistant_open {
		_observer_assistant_end(chain.observer)
		chain.assistant_open = false
	}
	// The row is in the store before the front-end is told, so a front-end that reads the
	// failure it is told about finds it.
	_observer_retry_scheduled(
		chain.observer,
		{request = chain.request, next_attempt = chain.attempts + 1, failure_class = chain.operation_error.failure_class, delay = chain.decision.delay},
	)
	binding: Log_Binding
	previous_logger := context.logger
	defer context.logger = previous_logger
	context.logger = log_rebind(&binding, log_correlation_for(chat, chain.attempts))
	retry := [5]Log_Field {
		{key = "reason", value = request_recovery_reason_name(chain.decision.reason)},
		{key = "error_kind", value = ai.provider_operation_error_name(chain.operation_error.kind)},
		{key = "failure_class", value = ai.provider_failure_class_name(chain.operation_error.failure_class)},
		{key = "next_attempt", value = i64(chain.attempts + 1)},
		{key = "delay_ms", value = Log_Duration_Milliseconds(chain.decision.delay)},
	}
	log_emit({level = .Warning, category = .Provider, event = "request.retry_scheduled", fields = retry[:]})
	chain.stage = .Backoff
}

// chat_chain_wait waits out the backoff before the next attempt. Cancellation ends the
// chain, and it wins over the failure the wait was for: the send that would have followed
// never happened, so the chain stopped because the turn was cancelled.
@(private)
chat_chain_wait :: proc(chat: ^Chat_Session) {
	chain := &chat.chain
	if !chain.active || chain.stage != .Backoff { return }
	if !chat_retry_wait(chat, chain.decision.delay) {
		chat_chain_stop(chat, .Cancelled)
		return
	}
	// Cancellation can arrive between the last slice of a delay and the send that follows.
	if chat_session_cancelled(chat) {
		chat_chain_stop(chat, .Cancelled)
		return
	}
	// The attempt is over, so the next one owns its own error. The error came from the
	// attempt's worker, so it is released with the allocator the worker allocated it from,
	// which is the process heap the mailbox was given.
	ai.Provider_Operation_Error_Destroy(&chain.operation_error, os.heap_allocator())
	chain.stage = .Ready
}

// chat_chain_repair waits for a summary or starts one for the refused request, then rebuilds
// the frozen payload. The next attempt sends the rebuilt bytes under the same bound.
@(private)
chat_chain_repair :: proc(chat: ^Chat_Session) {
	chain := &chat.chain
	if !chain.active || chain.stage != .Repairing { return }
	seen := owner_wake_seen()
	chat_session_observe_stop(chat)
	if chat_session_cancelled(chat) {
		chat_chain_stop(chat, .Cancelled)
		return
	}
	refusal := chat_try_context_repair(chat, chain.connection, chain.observer, &chain.prep, &chain.encoded, chain.websocket_request, chain.attempts)
	if refusal == .Summary_Running {
		chat_session_observe_stop(chat)
		if chat_session_cancelled(chat) {
			chat_chain_stop(chat, .Cancelled)
			return
		}
		owner_wake_wait(seen, chat_compact_deadline(chat))
		chat_session_observe_stop(chat)
		if chat_session_cancelled(chat) { chat_chain_stop(chat, .Cancelled) }
		return
	}
	if refusal != .None {
		if chat_session_cancelled(chat) {
			chat_session_observe_stop(chat)
			chat_chain_stop(chat, .Cancelled)
			return
		}
		chat.turn_repair_refusal = refusal
		chat_session_fail_turn(chat, fmt.tprintf("the request does not fit the context: %s", chat_repair_refusal_text(refusal)))
		chat_chain_stop(chat, .Context_Exhausted)
		return
	}
	chain.repaired = true
	chain.recovery_kind = .Checkpoint_Repair
	chat_session_clear_attempt(chat)
	ai.Provider_Operation_Error_Destroy(&chain.operation_error, os.heap_allocator())
	chain.stage = .Ready
}

// chat_chain_commit records what the chain produced and releases it. It is the only place
// a chain ends, so the prepared request and the frozen bytes cannot outlive the request
// that owned them.
@(private)
chat_chain_commit :: proc(chat: ^Chat_Session, usages: ^[dynamic]Chat_Request_Usage) {
	chain := &chat.chain
	if !chain.active { return }
	observer := chain.observer
	if chain.stage != .Committing {
		// Cancellation reached the chain between attempts. No further send happens, so the
		// chain stops and commits what the last attempt observed.
		chat_chain_stop(chat, .Cancelled)
	}
	if chain.attempts == 0 {
		// No send was made, so there is no response and no row to finish. The turn state
		// the failure set is what the driver acts on next.
		chat_chain_release(chat)
		return
	}
	// Cancellation wins over the failure the chain was recovering from: the send that would
	// have followed never happened.
	reason := chain.decision.reason
	if chat_session_cancelled(chat) { reason = .Cancelled }
	class := chain.operation_error.failure_class
	// The request was refused without its cache hints too, so they were not the cause and
	// later requests carry them again.
	if reason == .Terminal_Failure && chain.cache_hints_omitted && class == .Invalid_Request { chat.cache_hints_refused = false }
	// A response answered with a notice is feedback for the model, not the end of the turn:
	// the turn goes on to another request so the model can correct what it sent.
	turn_continues := chat.pending_notice != .None && !chat_session_cancelled(chat)
	// A chain that stopped says why, which is the one thing the finished request row cannot
	// say: the row reports the outcome of its own send, not the reason the harness stopped.
	if reason != .Completed {
		if !turn_continues { chat.turn_recovery = reason }
		level := log.Level.Warning
		if reason == .Cancelled { level = .Info }
		stopped := [4]Log_Field {
			{key = "reason", value = request_recovery_reason_name(reason)},
			{key = "error_kind", value = ai.provider_operation_error_name(chain.operation_error.kind)},
			{key = "failure_class", value = ai.provider_failure_class_name(chain.operation_error.failure_class)},
			{key = "attempts", value = i64(chain.attempts)},
		}
		log_emit({level = level, category = .Provider, event = "request.recovery_stopped", fields = stopped[:]})
	}
	send := Chat_Send_Result {
		finish_reason       = chain.finish_reason,
		error               = chain.operation_error,
		error_present       = chain.operation_error.kind != .None,
		message             = chat.last_error,
		text_exposed        = chain.text_exposed,
		completion_accepted = chain.completion_accepted,
		recovery            = reason,
		delay               = chain.decision.delay,
	}
	_observer_assistant_flush(observer)
	// Cancellation is the reason the turn ended, so it wins over any error the transport
	// also reported. Any other stop is the user's to act on, so they are told what failed
	// and what would fix it, in the provider's own words where it gave any.
	if chat_session_cancelled(chat) {
		chat_session_note_cancel(chat)
	} else if chain.operation_error.kind != .None && reason != .Output_Exposed && !turn_continues {
		// A stop the provider caused is told in the provider's words, which the operation
		// carries; any other stop keeps the account the harness already gave.
		detail := chat.last_error
		provider_stop := reason == .Terminal_Failure || reason == .Retries_Exhausted
		if detail == "" || (provider_stop && chain.operation_error.detail != "") { detail = chain.operation_error.detail }
		// A failure event may already have finalized the operation with the transport's own
		// words, and then the event is refused; the user is still told the whole account.
		message := chat_failure_message(reason, class, detail)
		if !chat_session_feed_error(chat, chain.source, message) { chat_last_error_set(chat, message) }
	}
	chat_session_retire_operation(chat)
	chat_commit_response(chat, chain.request, chain.attempts, send, usages, finish_send = !chain.settled)
	// The request's outcome is recorded, so the provider's own accounting of it is part of
	// the session the front-end describes.
	_observer_request_finished(observer)
	chat_chain_release(chat)
}

// chat_failure_message is what the user is told about a request the chain stopped: what
// failed and, where only the user can fix it, what would, followed by detail, the provider's
// or the harness's own account. The text is allocated in the temporary allocator, so detail
// may alias memory the caller is about to release.
@(private)
chat_failure_message :: proc(reason: Request_Recovery_Reason, class: ai.Provider_Failure_Class, detail: string) -> string {
	cause := ""
	#partial switch reason {
	case .Retries_Exhausted:
		cause = "the provider kept failing after every scheduled retry"
	case .Terminal_Failure:
		switch class {
		case .Authentication:
			cause = "the provider refused the credentials; check the API key"
		case .Quota:
			cause = "the provider account has no quota or credit left"
		case .Not_Found:
			cause = "the provider does not serve this model; choose another model"
		case .Content_Policy:
			cause = "the provider refused the content under its usage policy"
		case .Untrusted_Connection:
			cause = "the provider's identity could not be verified"
		case .Invalid_Request:
			cause = "the provider refused the request as invalid"
		case .None, .Unknown, .Rate_Limited, .Context_Overflow, .Payload_Too_Large, .Provider_Unavailable, .Incomplete_Stream, .Invalid_Output:
		}
	}
	switch {
	case cause == "":
		return fmt.tprint(detail)
	case detail == "":
		return cause
	}
	return fmt.tprintf("%s: %s", cause, detail)
}
