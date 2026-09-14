package session

import "core:encoding/json"
import "core:fmt"
import "core:mem"

// The wire structs are the stored JSON shape, kept separate from the payload
// types so that a stored field name and a payload field name can change
// independently, and so that a vocabulary is written as its stable string.
//
// A payload shape belongs to the schema version that wrote it: adding or
// renaming a field is a migration, not a quiet in-place change.

@(private)
User_Wire :: struct {
	text:   string `json:"text"`,
	origin: string `json:"origin"`,
}

@(private)
Assistant_Wire :: struct {
	text:    string `json:"text"`,
	partial: bool `json:"partial"`,
}

@(private)
Reasoning_Wire :: struct {
	id:        string `json:"id"`,
	encrypted: string `json:"encrypted"`,
}

@(private)
Response_Wire :: struct {
	output: string `json:"output"`,
}

@(private)
Tool_Call_Wire :: struct {
	call_id:   string `json:"call_id"`,
	item_id:   string `json:"item_id"`,
	name:      string `json:"name"`,
	arguments: string `json:"arguments"`,
}

@(private)
Tool_Dispatch_Wire :: struct {
	tool:      string `json:"tool"`,
	arguments: string `json:"arguments"`,
	repair:    string `json:"repair"`,
}

@(private)
Tool_Result_Wire :: struct {
	outcome: string `json:"outcome"`,
	error:   string `json:"error"`,
	content: string `json:"content"`,
	origin:  string `json:"origin"`,
}

@(private)
Checkpoint_Wire :: struct {
	summary:      string `json:"summary"`,
	covered_seq:  Maybe(Seq) `json:"covered_seq"`,
	previous_seq: Maybe(Seq) `json:"previous_seq"`,
}

// entry_payload_encode returns the stored JSON for one payload. The result is
// allocated with allocator.
entry_payload_encode :: proc(payload: Entry_Payload, allocator := context.allocator) -> ([]byte, Error) {
	switch value in payload {
	case User_Entry:
		return json_encode(User_Wire{text = value.text, origin = user_origin_name(value.origin)}, allocator)
	case Assistant_Entry:
		return json_encode(Assistant_Wire{text = value.text, partial = value.partial}, allocator)
	case Reasoning_Entry:
		return json_encode(Reasoning_Wire{id = value.id, encrypted = value.encrypted}, allocator)
	case Response_Entry:
		return json_encode(Response_Wire{output = value.output}, allocator)
	case Tool_Call_Entry:
		wire := Tool_Call_Wire {
			call_id   = value.call_id,
			item_id   = value.item_id,
			name      = value.name,
			arguments = value.arguments,
		}
		return json_encode(wire, allocator)
	case Tool_Dispatch_Entry:
		wire := Tool_Dispatch_Wire {
			tool      = value.tool,
			arguments = value.arguments,
			repair    = tool_repair_name(value.repair),
		}
		return json_encode(wire, allocator)
	case Tool_Result_Entry:
		wire := Tool_Result_Wire {
			outcome = tool_outcome_name(value.outcome),
			error   = value.error,
			content = value.content,
			origin  = tool_result_origin_name(value.origin),
		}
		return json_encode(wire, allocator)
	case Checkpoint_Entry:
		wire := Checkpoint_Wire {
			summary      = value.summary,
			covered_seq  = value.covered_seq,
			previous_seq = value.previous_seq,
		}
		return json_encode(wire, allocator)
	}
	return nil, error_make(.Encode, "the entry payload has no variant")
}

// entry_payload_decode returns the payload for one stored entry. Every string
// in the result is allocated with allocator, and a payload whose required
// fields are missing is refused as corrupt.
entry_payload_decode :: proc(kind: Entry_Kind, data: string, allocator: mem.Allocator) -> (payload: Entry_Payload, err: Error) {
	// A vocabulary name is converted to its enum immediately and the stored copy
	// is released, because the payload keeps the enum and not the text.
	vocabulary_ok := true
	switch kind {
	case .User:
		wire: User_Wire
		if decode_err := json_decode(data, &wire, allocator); decode_err != nil { return nil, decode_err }
		origin, known := user_origin_from_name(wire.origin)
		delete(wire.origin, allocator)
		vocabulary_ok = known
		payload = User_Entry {
			text   = wire.text,
			origin = origin,
		}
	case .Assistant:
		wire: Assistant_Wire
		if decode_err := json_decode(data, &wire, allocator); decode_err != nil { return nil, decode_err }
		payload = Assistant_Entry {
			text    = wire.text,
			partial = wire.partial,
		}
	case .Reasoning:
		wire: Reasoning_Wire
		if decode_err := json_decode(data, &wire, allocator); decode_err != nil { return nil, decode_err }
		payload = Reasoning_Entry {
			id        = wire.id,
			encrypted = wire.encrypted,
		}
	case .Response:
		wire: Response_Wire
		if decode_err := json_decode(data, &wire, allocator); decode_err != nil { return nil, decode_err }
		payload = Response_Entry {
			output = wire.output,
		}
	case .Tool_Call:
		wire: Tool_Call_Wire
		if decode_err := json_decode(data, &wire, allocator); decode_err != nil { return nil, decode_err }
		payload = Tool_Call_Entry {
			call_id   = wire.call_id,
			item_id   = wire.item_id,
			name      = wire.name,
			arguments = wire.arguments,
		}
	case .Tool_Dispatch:
		wire: Tool_Dispatch_Wire
		if decode_err := json_decode(data, &wire, allocator); decode_err != nil { return nil, decode_err }
		repair, repair_known := tool_repair_from_name(wire.repair)
		// A dispatch written before repairs were recorded has no name at all, which
		// means the same thing as the explicit "none".
		if wire.repair == "" { repair, repair_known = .None, true }
		delete(wire.repair, allocator)
		vocabulary_ok = repair_known
		payload = Tool_Dispatch_Entry {
			tool      = wire.tool,
			arguments = wire.arguments,
			repair    = repair,
		}
	case .Tool_Result:
		wire: Tool_Result_Wire
		if decode_err := json_decode(data, &wire, allocator); decode_err != nil { return nil, decode_err }
		outcome, outcome_known := tool_outcome_from_name(wire.outcome)
		origin, origin_known := tool_result_origin_from_name(wire.origin)
		delete(wire.outcome, allocator)
		delete(wire.origin, allocator)
		vocabulary_ok = outcome_known && origin_known
		payload = Tool_Result_Entry {
			outcome = outcome,
			error   = wire.error,
			content = wire.content,
			origin  = origin,
		}
	case .Checkpoint:
		wire: Checkpoint_Wire
		if decode_err := json_decode(data, &wire, allocator); decode_err != nil { return nil, decode_err }
		payload = Checkpoint_Entry {
			summary      = wire.summary,
			covered_seq  = wire.covered_seq,
			previous_seq = wire.previous_seq,
		}
	}
	if !vocabulary_ok || !entry_payload_complete(kind, payload) {
		entry_payload_destroy(&payload, allocator)
		return nil, error_make(.Corrupt, fmt.tprintf("a stored %s entry is incomplete or names an unknown value", entry_kind_name(kind)))
	}
	return payload, nil
}

@(private)
json_encode :: proc(value: $T, allocator: mem.Allocator) -> ([]byte, Error) {
	data, marshal_err := json.marshal(value, allocator = allocator)
	if marshal_err != nil {
		return nil, error_make(.Encode, fmt.tprintf("the entry payload could not be encoded: %v", marshal_err))
	}
	return data, nil
}

@(private)
json_decode :: proc(data: string, value: ^$T, allocator: mem.Allocator) -> Error {
	if decode_err := json.unmarshal_string(data, value, allocator = allocator); decode_err != nil {
		return error_make(.Corrupt, fmt.tprintf("a stored entry payload could not be decoded: %v", decode_err))
	}
	return nil
}

// entry_payload_complete reports whether a payload carries what its kind
// requires and agrees with the kind it was stored under.
@(private)
entry_payload_complete :: proc(kind: Entry_Kind, payload: Entry_Payload) -> bool {
	switch value in payload {
	case User_Entry:
		return kind == .User && value.text != ""
	case Assistant_Entry:
		return kind == .Assistant
	case Reasoning_Entry:
		return kind == .Reasoning && value.id != ""
	case Response_Entry:
		return kind == .Response && value.output != ""
	case Tool_Call_Entry:
		return kind == .Tool_Call && value.call_id != "" && value.name != ""
	case Tool_Dispatch_Entry:
		return kind == .Tool_Dispatch && value.tool != ""
	case Tool_Result_Entry:
		return kind == .Tool_Result
	case Checkpoint_Entry:
		return kind == .Checkpoint && value.summary != ""
	}
	return false
}
