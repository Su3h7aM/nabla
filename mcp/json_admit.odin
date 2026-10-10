package mcp

import "core:encoding/json"

// Document_Problem names why a JSON document the server sent cannot be used.
Document_Problem :: enum {
	None,
	Too_Deep,
	Syntax,
	Duplicate_Key,
	Not_Object,
	Allocation,
}

// document_admit reports the first structural defect in a document a server
// sent. The document must be one complete JSON value, with no repeated field name
// at any depth and no nesting past depth_limit.
//
// A repeated field name is refused rather than resolved: a reply whose meaning
// depends on which of two identical keys the reader picked is not a reply the
// harness can act on. The depth is checked before the parser runs, because the
// parser recurses once per nesting level and would reach the stack before a later
// check could refuse it. How large a document may be is the caller's rule to
// enforce, not this one's.
@(require_results)
document_admit :: proc(text: string, depth_limit: int, root_object: bool) -> Document_Problem {
	if text == "" { return .Syntax }

	tokenizer := json.make_tokenizer(text, .JSON, true)
	token, token_err := json.get_token(&tokenizer)
	if mcp_token_bad(token, token_err) { return .Syntax }
	if token.kind != .Open_Brace && token.kind != .Open_Bracket { return .Syntax }
	if root_object && token.kind != .Open_Brace { return .Not_Object }

	problem: Document_Problem
	if token.kind == .Open_Brace {
		problem = mcp_admit_object(&tokenizer, 1, depth_limit)
	} else {
		problem = mcp_admit_array(&tokenizer, 1, depth_limit)
	}
	if problem != .None { return problem }

	token, token_err = json.get_token(&tokenizer)
	if (token_err != nil && token_err != .EOF) || token.kind != .EOF { return .Syntax }
	return .None
}

// mcp_token_bad reports a token that cannot be used: a tokenizer failure, or an
// end of input where the document still owes structure.
@(private, require_results)
mcp_token_bad :: proc(token: json.Token, err: json.Error) -> bool {
	return (err != nil && err != .EOF) || token.kind == .EOF
}

@(private, require_results)
mcp_admit_object :: proc(tokenizer: ^json.Tokenizer, depth, depth_limit: int) -> Document_Problem {
	if depth > depth_limit { return .Too_Deep }
	seen, allocation_error := make(map[string]bool, 0, context.temp_allocator)
	if allocation_error != nil { return .Allocation }
	defer {
		for key in seen { delete(key, context.temp_allocator) }
		delete(seen)
	}

	comma := false
	for {
		token, token_err := json.get_token(tokenizer)
		if mcp_token_bad(token, token_err) { return .Syntax }
		if token.kind == .Close_Brace {
			if comma { return .Syntax }
			return .None
		}
		if token.kind != .String { return .Syntax }

		key, key_err := json.unquote_string(token, .JSON, context.temp_allocator)
		if key_err != nil {
			if key_err == .Out_Of_Memory || key_err == .Invalid_Allocator { return .Allocation }
			return .Syntax
		}
		_, _, inserted, insertion_error := map_entry(&seen, key)
		if insertion_error != nil {
			delete(key, context.temp_allocator)
			return .Allocation
		}
		if !inserted {
			delete(key, context.temp_allocator)
			return .Duplicate_Key
		}

		colon, colon_err := json.get_token(tokenizer)
		if mcp_token_bad(colon, colon_err) || colon.kind != .Colon { return .Syntax }

		value, value_err := json.get_token(tokenizer)
		if mcp_token_bad(value, value_err) { return .Syntax }
		if problem := mcp_admit_value(tokenizer, value, depth, depth_limit); problem != .None { return problem }

		separator, separator_err := json.get_token(tokenizer)
		if mcp_token_bad(separator, separator_err) { return .Syntax }
		#partial switch separator.kind {
		case .Comma:
			comma = true
			continue
		case .Close_Brace:
			return .None
		case:
			return .Syntax
		}
	}
}

@(private, require_results)
mcp_admit_array :: proc(tokenizer: ^json.Tokenizer, depth, depth_limit: int) -> Document_Problem {
	if depth > depth_limit { return .Too_Deep }
	comma := false
	for {
		token, token_err := json.get_token(tokenizer)
		if mcp_token_bad(token, token_err) { return .Syntax }
		if token.kind == .Close_Bracket {
			if comma { return .Syntax }
			return .None
		}
		if problem := mcp_admit_value(tokenizer, token, depth, depth_limit); problem != .None { return problem }

		separator, separator_err := json.get_token(tokenizer)
		if mcp_token_bad(separator, separator_err) { return .Syntax }
		#partial switch separator.kind {
		case .Comma:
			comma = true
			continue
		case .Close_Bracket:
			return .None
		case:
			return .Syntax
		}
	}
}

// mcp_admit_value continues from a token that has already been read, which is
// what keeps a container's first element from being read twice.
@(private, require_results)
mcp_admit_value :: proc(tokenizer: ^json.Tokenizer, token: json.Token, depth, depth_limit: int) -> Document_Problem {
	#partial switch token.kind {
	case .Open_Brace:
		return mcp_admit_object(tokenizer, depth + 1, depth_limit)
	case .Open_Bracket:
		return mcp_admit_array(tokenizer, depth + 1, depth_limit)
	case .String, .Integer, .Float, .True, .False, .Null:
		return .None
	}
	return .Syntax
}
