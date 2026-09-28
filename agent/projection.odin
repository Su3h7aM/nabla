package agent

import "base:runtime"
import "core:mem"

import "nabla:agent/journal"

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
	text:   string,
	origin: journal.User_Origin,
}

Projected_Assistant :: struct {
	text: string,
}

// Projected_Response is the endpoint's native output items, exactly as returned,
// and the provider and model that returned them: they replay only to that pair.
Projected_Response :: struct {
	output:   string,
	provider: string,
	model:    string,
}

// Projected_Call is a proposed call. admitted is the arguments it ran with,
// "" when it was never admitted.
Projected_Call :: struct {
	call:        journal.Call_Id,
	provider_id: string,
	item_id:     string,
	name:        string,
	proposed:    string,
	admitted:    string,
}

// Projected_Result answers a call. content is the rendered result, or the
// harness's account when the call produced none, as after recovery.
Projected_Result :: struct {
	call:    journal.Call_Id,
	outcome: journal.Tool_Outcome,
	content: string,
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
			journal.payload_decode(node.data, &user, context.temp_allocator) or_return
			origin, known := journal.enum_from_name(journal.USER_ORIGIN_NAMES, user.origin)
			if !known { return {}, journal.Journal_Error.Corrupt }
			append(&items, Projection_Item{node = node.id, turn = node.turn, payload = Projected_User{text = body, origin = origin}}) or_return
		case .Context, .Notice:
			append(&items, Projection_Item{node = node.id, turn = node.turn, payload = Projected_User{text = body, origin = .Harness}}) or_return
		case .Assistant:
			projection_add_assistant(&items, node, responses[node.id][:], admitted, arena) or_return
		case .Results:
			results: journal.Results
			journal.payload_decode(node.data, &results, context.temp_allocator) or_return
			for call in results.calls {
				record, found := completed[call]
				if !found { return {}, journal.Journal_Error.Corrupt }
				completion: journal.Tool_Completed
				journal.payload_decode(record.data, &completion, arena) or_return
				result := Projected_Result {
					call    = call,
					content = string(record.body),
				}
				// A result whose outcome is not a name this build writes is a record it cannot
				// read: left at the zero member it would report an unreadable record as a call
				// whose outcome nobody knows.
				outcome, known := journal.enum_from_name(journal.TOOL_OUTCOME_NAMES, completion.outcome)
				if !known { return {}, journal.Journal_Error.Corrupt }
				result.outcome = outcome
				if result.content == "" { result.content = completion.detail }
				append(&items, Projection_Item{node = node.id, turn = node.turn, payload = result}) or_return
			}
		}
	}
	projection.items = items[:]
	return projection, nil
}

// projection_add_assistant appends one response in the order it is replayed:
// its native output, its finished text, then the calls it proposed.
@(private, require_results)
projection_add_assistant :: proc(
	items: ^[dynamic]Projection_Item,
	node: journal.Node,
	records: []^journal.Record, // the node's response and proposals, in seq order
	admitted: map[journal.Call_Id]string,
	arena: mem.Allocator,
) -> journal.Error {
	assistant: journal.Assistant
	journal.payload_decode(node.data, &assistant, context.temp_allocator) or_return
	item := Projection_Item {
		node    = node.id,
		turn    = node.turn,
		request = assistant.request,
	}
	for record in records {
		if record.kind != .Response_Committed || len(record.body) == 0 { continue }
		item.payload = Projected_Response {
			output   = string(record.body),
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
		journal.payload_decode(record.data, &proposal, arena) or_return
		item.payload = Projected_Call {
			call        = record.call,
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
