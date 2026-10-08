package agent

import "base:runtime"
import "core:mem"

import "nabla:agent/journal"
import "nabla:ai"

// Projection is the conversation a request is built from: the covering
// checkpoint's summary, then every step after it up to head. Everything it
// holds is allocated in the arena it was loaded with and released with that
// arena; nothing in it is freed on its own.
Projection :: struct {
	summary:    string, // "" without a checkpoint
	checkpoint: journal.Node_Id,
	covers:     journal.Node_Id,
	head:       journal.Node_Id,
	items:      []Projection_Item,
	// unanswered answers the calls of items that have a committed Tool_Completed but no
	// Results node yet, in item order. It is display only: the provider conversation
	// never reads it.
	unanswered: []Projected_Result,
	nested:     []Projected_Nested_Call, // display only, in proposal order
}

// Projection_Item is one step of the conversation. request names the response
// an Assistant node's items came from, and is 0 for anything else. turn is
// the turn that committed the node.
Projection_Item :: struct {
	node:    journal.Node_Id,
	turn:    journal.Turn_Id,
	request: journal.Request_Id,
	payload: Projection_Payload,
}

Projection_Payload :: union {
	Projected_User,
	Projected_Assistant,
	Projected_Response,
	Projected_Call,
	Projected_Result,
}

// Projected_User is user-role text: the user's input, a harness notice, or
// harness-inserted context.
Projected_User :: struct {
	text:        string,
	origin:      journal.User_Origin,
	attachments: []ai.Provider_Attachment,
}

Projected_Assistant :: struct {
	text: string,
}

// Projected_Response is the endpoint's native output items, exactly as returned,
// and the API, provider, and model that returned them: they replay only to that
// combination.
Projected_Response :: struct {
	output:   string,
	api:      string,
	provider: string,
	model:    string,
}

// Projected_Call is a proposed call. admitted is the arguments it ran with,
// "" when it was never admitted. parent_call is the Code Mode call that ran it,
// or zero for a call the model made directly.
Projected_Call :: struct {
	call:        journal.Call_Id,
	parent_call: journal.Call_Id,
	provider_id: string,
	item_id:     string,
	name:        string,
	proposed:    string,
	admitted:    string,
}

// Projected_Result answers a call. content is the rendered result, or the
// harness's account when the call produced none, as after recovery.
// parent_call is the Code Mode call that ran it, or zero for a call the model
// made directly, so a replay tells an inner call like the live view does.
Projected_Result :: struct {
	call:        journal.Call_Id,
	parent_call: journal.Call_Id,
	outcome:     journal.Tool_Outcome,
	content:     string,
	attachments: []ai.Provider_Attachment,
}

// Projected_Nested_Call is a child of a call in items, running or settled. It is
// display-only and never contributes to the provider conversation. content and outcome
// are set only once settled. Its strings borrow the arena.
Projected_Nested_Call :: struct {
	call:        journal.Call_Id,
	parent_call: journal.Call_Id,
	name:        string,
	proposed:    string,
	content:     string,
	outcome:     journal.Tool_Outcome,
	settled:     bool,
}

// PROJECTION_RECORD_KINDS are the records an Assistant node's response and
// calls are read from.
PROJECTION_RECORD_KINDS :: bit_set[journal.Record_Kind;u128]{.Response_Committed, .Tool_Proposed, .Tool_Admitted, .Tool_Completed}

// projection_load reads the projection of session from head into arena, which
// the caller releases whether or not the load succeeds.
@(require_results)
projection_load :: proc(
	store: ^journal.Journal,
	session: journal.Session_Id,
	head: journal.Node_Id,
	arena: mem.Allocator,
) -> (
	projection: Projection,
	error: journal.Error,
) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = arena == context.temp_allocator)
	projection.head = head
	nodes := journal.read_ancestry(store, session, head, arena) or_return

	assistants := make([dynamic]journal.Node_Id, context.temp_allocator) or_return
	for node in nodes {
		if node.kind == .Assistant { append(&assistants, node.id) or_return }
	}
	records: []journal.Record
	if len(assistants) > 0 {
		filter := journal.Filter {
			session = session,
			kinds   = PROJECTION_RECORD_KINDS,
			nodes   = assistants[:],
		}
		records, _ = journal.read_records(store, filter, 0, 0, arena) or_return
	}

	// A response's records, a call's admission, and its completion are looked
	// up when the Assistant node and the Results node are reached.
	responses := make(map[journal.Node_Id][dynamic]^journal.Record, allocator = context.temp_allocator)
	admitted := make(map[journal.Call_Id]string, allocator = context.temp_allocator)
	completed := make(map[journal.Call_Id]^journal.Record, allocator = context.temp_allocator)
	answered := make(map[journal.Call_Id]bool, allocator = context.temp_allocator)
	for &record in records {
		// The filter reads PROJECTION_RECORD_KINDS only.
		#partial switch record.kind {
		case .Response_Committed, .Tool_Proposed:
			list := responses[record.node]
			if list == nil { list = make([dynamic]^journal.Record, context.temp_allocator) or_return }
			append(&list, &record) or_return
			responses[record.node] = list
		case .Tool_Admitted:
			admitted[record.call] = string(record.body)
		case .Tool_Completed:
			completed[record.call] = &record
		}
	}

	items := make([dynamic]Projection_Item, arena) or_return
	for node in nodes {
		body := string(node.body)
		switch node.kind {
		case .Checkpoint:
			projection.summary = body
			projection.checkpoint = node.id
			projection.covers = node.covers
		case .User:
			user: journal.User
			journal.payload_decode(node.data, &user, arena, corruption_journal = store, session = node.session, seq = node.seq) or_return
			origin, known := journal.enum_from_name(journal.USER_ORIGIN_NAMES, user.origin)
			if !known { return {}, journal.Journal_Error.Corrupt }
			attachments := projection_attachments(store, user.attachments, arena) or_return
			append(
				&items,
				Projection_Item{node = node.id, turn = node.turn, payload = Projected_User{text = body, origin = origin, attachments = attachments}},
			) or_return
		case .Context, .Notice:
			append(&items, Projection_Item{node = node.id, turn = node.turn, payload = Projected_User{text = body, origin = .Harness}}) or_return
		case .Assistant:
			projection_add_assistant(store, &items, node, responses[node.id][:], admitted, arena) or_return
		case .Results:
			results: journal.Results
			journal.payload_decode(node.data, &results, context.temp_allocator, corruption_journal = store, session = node.session, seq = node.seq) or_return
			for call in results.calls {
				record, found := completed[call]
				if !found { return {}, journal.Journal_Error.Corrupt }
				result := projection_result(store, record, arena) or_return
				answered[call] = true
				append(&items, Projection_Item{node = node.id, turn = node.turn, payload = result}) or_return
			}
		}
	}
	projection.items = items[:]
	unanswered := make([dynamic]Projected_Result, arena) or_return
	parents := make(map[journal.Call_Id]bool, allocator = context.temp_allocator)
	for item in items {
		call, is_call := item.payload.(Projected_Call)
		if !is_call { continue }
		if call.name == TOOL_CODEMODE_NAME { parents[call.call] = true }
		if record, found := completed[call.call]; found && !answered[call.call] {
			// The entry is display only, so a completion that cannot be read is left out
			// instead of failing the projection the provider conversation comes from.
			result, result_error := projection_result(store, record, arena)
			if result_error != nil { continue }
			append(&unanswered, result) or_return
		}
	}
	projection.unanswered = unanswered[:]
	if len(parents) > 0 {
		children, _ := journal.read_records(store, {session = session, kinds = {.Tool_Proposed, .Tool_Completed}, only_children = true}, 0, 0, arena) or_return
		positions := make(map[journal.Call_Id]int, allocator = context.temp_allocator)
		nested := make([dynamic]Projected_Nested_Call, arena) or_return
		for &record in children {
			if !parents[record.parent_call] { continue }
			if record.kind == .Tool_Proposed {
				proposal: journal.Tool_Proposed
				journal.payload_decode(record.data, &proposal, arena, corruption_journal = store, session = session, seq = record.seq) or_return
				positions[record.call] = len(nested)
				append(
					&nested,
					Projected_Nested_Call{call = record.call, parent_call = record.parent_call, name = proposal.name, proposed = string(record.body)},
				) or_return
				continue
			}
			position, found := positions[record.call]
			if !found { return {}, journal.Journal_Error.Corrupt }
			result := projection_result(store, &record, arena) or_return
			nested[position].content = result.content
			nested[position].outcome = result.outcome
			nested[position].settled = true
		}
		projection.nested = nested[:]
	}
	return projection, nil
}

// projection_result reads the answer a Tool_Completed record carries. The record's
// strings are decoded into arena.
@(private, require_results)
projection_result :: proc(store: ^journal.Journal, record: ^journal.Record, arena: mem.Allocator) -> (result: Projected_Result, error: journal.Error) {
	completion: journal.Tool_Completed
	journal.payload_decode(record.data, &completion, arena, corruption_journal = store, session = record.session, seq = record.seq) or_return
	result = Projected_Result {
		call        = record.call,
		parent_call = record.parent_call,
		content     = string(record.body),
	}
	// A result whose outcome is not a name this build writes is a record it cannot
	// read: left at the zero member it would report an unreadable record as a call
	// whose outcome nobody knows.
	outcome, known := journal.enum_from_name(journal.TOOL_OUTCOME_NAMES, completion.outcome)
	if !known { return {}, journal.Journal_Error.Corrupt }
	result.outcome = outcome
	if result.content == "" { result.content = completion.detail }
	result.attachments = projection_attachments(store, completion.attachments, arena) or_return
	return result, nil
}

// projection_attachments reads the files a record names, with their bytes, into arena. An
// unknown media type, a malformed digest, or an artifact the journal no longer has is a
// record it cannot read.
@(private, require_results)
projection_attachments :: proc(
	store: ^journal.Journal,
	stored: []journal.Attachment,
	arena: mem.Allocator,
) -> (
	attachments: []ai.Provider_Attachment,
	error: journal.Error,
) {
	if len(stored) == 0 { return nil, nil }
	attachments = make([]ai.Provider_Attachment, len(stored), arena) or_return
	for file, i in stored {
		media, known := journal.enum_from_name(ai.PROVIDER_MEDIA_TYPES, file.media_type)
		if !known { return nil, journal.Journal_Error.Corrupt }
		digest, valid := journal.digest_from_hex(file.digest)
		if !valid { return nil, journal.Journal_Error.Corrupt }
		data, found := journal.read_artifact(store, digest, arena) or_return
		if !found { return nil, journal.Journal_Error.Corrupt }
		attachments[i] = {
			Media = media,
			Name  = file.name,
			Data  = data,
		}
	}
	return attachments, nil
}

// projection_add_assistant appends one response in the order it is replayed:
// its native output, its finished text, then the calls it proposed.
@(private, require_results)
projection_add_assistant :: proc(
	store: ^journal.Journal,
	items: ^[dynamic]Projection_Item,
	node: journal.Node,
	records: []^journal.Record, // the node's response and proposals, in seq order
	admitted: map[journal.Call_Id]string,
	arena: mem.Allocator,
) -> journal.Error {
	assistant: journal.Assistant
	journal.payload_decode(node.data, &assistant, context.temp_allocator, corruption_journal = store, session = node.session, seq = node.seq) or_return
	item := Projection_Item {
		node    = node.id,
		turn    = node.turn,
		request = assistant.request,
	}
	for record in records {
		if record.kind != .Response_Committed || len(record.body) == 0 { continue }
		response: journal.Response_Committed
		journal.payload_decode(record.data, &response, arena, corruption_journal = store, session = record.session, seq = record.seq) or_return
		item.payload = Projected_Response {
			output   = string(record.body),
			api      = response.api,
			provider = record.provider,
			model    = record.model,
		}
		append(items, item) or_return
	}
	if !assistant.partial && len(node.body) > 0 {
		item.payload = Projected_Assistant {
			text = string(node.body),
		}
		append(items, item) or_return
	}
	for record in records {
		if record.kind != .Tool_Proposed { continue }
		proposal: journal.Tool_Proposed
		journal.payload_decode(record.data, &proposal, arena, corruption_journal = store, session = record.session, seq = record.seq) or_return
		item.payload = Projected_Call {
			call        = record.call,
			parent_call = record.parent_call,
			provider_id = proposal.provider_id,
			item_id     = proposal.item_id,
			name        = proposal.name,
			proposed    = string(record.body),
			admitted    = admitted[record.call],
		}
		append(items, item) or_return
	}
	return nil
}
