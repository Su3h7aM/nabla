package agent

import "core:fmt"
import "core:strings"

// Config_Edit_Error says why an edit of the configuration source was refused. A refused
// edit leaves the file as it was.
Config_Edit_Error :: enum {
	None,
	Allocation,
	// The file has no providers table to hold the model's entry.
	No_Providers,
	// A part the edit must pass through is not the table or literal it expects, so the
	// edit could change what the user wrote.
	Unsupported_Layout,
}

Config_Token_Kind :: enum u8 {
	Name,
	String,
	Punct,
	Other, // a number
}

// Config_Token is one Lua token as a byte range of the source. Comments and whitespace
// are not tokens.
Config_Token :: struct {
	kind:  Config_Token_Kind,
	start: int,
	end:   int, // exclusive
}

// Config_Field is one entry of a table constructor. key is borrowed from the source
// and empty for a positional entry; first and last are the value's tokens, inclusive.
Config_Field :: struct {
	key:     string,
	has_key: bool,
	first:   int,
	last:    int,
}

// config_model_set_disabled sets the disabled flag of one model in the source of a Lua
// configuration and returns the edited source, allocated with allocator. Only the value
// of the model's disabled field changes, or that field is added to the model's entry.
// The entry, its other fields, and the comments stay as the user wrote them, so an
// override is never touched. A model with no entry gets one when it is disabled.
// Enabling a model with no entry changes nothing, because it is enabled already.
// changed is false when the source already says so, and edited is then empty.
config_model_set_disabled :: proc(
	source, provider_id, model_id: string,
	disabled: bool,
	allocator := context.allocator,
) -> (
	edited: string,
	changed: bool,
	err: Config_Edit_Error,
) {
	tokens := make([dynamic]Config_Token, context.temp_allocator)
	if lex_err := config_edit_lex(source, &tokens); lex_err != .None { return "", false, lex_err }
	token_list := tokens[:]

	root_open, root_ok := config_edit_returned_table(source, token_list)
	if !root_ok { return "", false, .Unsupported_Layout }
	_, root_fields, root_err := config_edit_table(source, token_list, root_open)
	if root_err != .None { return "", false, root_err }
	providers_index, has_providers := config_edit_find(root_fields, "providers")
	if !has_providers { return "", false, .No_Providers }
	providers_open, providers_fields, providers_err := config_edit_field_table(source, token_list, root_fields[providers_index])
	if providers_err != .None { return "", false, providers_err }

	provider_index, has_provider := config_edit_find(providers_fields, provider_id)
	if !has_provider {
		if !disabled { return "", false, .None }
		text, text_err := strings.concatenate(
			{"[", config_edit_quoted(provider_id), "] = { models = { [", config_edit_quoted(model_id), "] = { disabled = true } } }"},
			context.temp_allocator,
		)
		if text_err != nil { return "", false, .Allocation }
		edited, err = config_edit_insert_field(source, token_list, providers_open, text, allocator)
		return edited, err == .None, err
	}
	provider_open, provider_fields, provider_err := config_edit_field_table(source, token_list, providers_fields[provider_index])
	if provider_err != .None { return "", false, provider_err }

	models_index, has_models := config_edit_find(provider_fields, "models")
	if !has_models {
		if !disabled { return "", false, .None }
		text, text_err := strings.concatenate({"models = { [", config_edit_quoted(model_id), "] = { disabled = true } }"}, context.temp_allocator)
		if text_err != nil { return "", false, .Allocation }
		edited, err = config_edit_insert_field(source, token_list, provider_open, text, allocator)
		return edited, err == .None, err
	}
	models_open, models_fields, models_err := config_edit_field_table(source, token_list, provider_fields[models_index])
	if models_err != .None { return "", false, models_err }

	model_index, has_model := config_edit_find(models_fields, model_id)
	if !has_model {
		if !disabled { return "", false, .None }
		text, text_err := strings.concatenate({"[", config_edit_quoted(model_id), "] = { disabled = true }"}, context.temp_allocator)
		if text_err != nil { return "", false, .Allocation }
		edited, err = config_edit_insert_field(source, token_list, models_open, text, allocator)
		return edited, err == .None, err
	}
	model_open, model_fields, model_err := config_edit_field_table(source, token_list, models_fields[model_index])
	if model_err != .None { return "", false, model_err }

	wanted := "false"
	if disabled { wanted = "true" }
	disabled_index, has_disabled := config_edit_find(model_fields, "disabled")
	if !has_disabled {
		if !disabled { return "", false, .None }
		edited, err = config_edit_insert_field(source, token_list, model_open, "disabled = true", allocator)
		return edited, err == .None, err
	}
	value := model_fields[disabled_index]
	if value.first != value.last || token_list[value.first].kind != .Name { return "", false, .Unsupported_Layout }
	value_token := token_list[value.first]
	current := source[value_token.start:value_token.end]
	if current != "true" && current != "false" { return "", false, .Unsupported_Layout }
	if current == wanted { return "", false, .None }
	edited, err = config_edit_splice(source, value_token.start, value_token.end, wanted, allocator)
	return edited, err == .None, err
}

// config_edit_quoted returns text as a Lua string literal.
@(private = "file")
config_edit_quoted :: proc(text: string) -> string {
	return fmt.tprintf("%q", text)
}

// config_edit_lex splits the source into tokens. A malformed string or long bracket
// is Unsupported_Layout: no edit can locate the tables safely in such a file.
@(private = "file")
config_edit_lex :: proc(source: string, tokens: ^[dynamic]Config_Token) -> Config_Edit_Error {
	i := 0
	for i < len(source) {
		c := source[i]
		start := i
		kind: Config_Token_Kind
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			i += 1
			continue
		} else if c == '-' && i + 1 < len(source) && source[i + 1] == '-' {
			i += 2
			if level, is_long := config_edit_long_level(source, i); is_long {
				end, closed := config_edit_long_end(source, i, level)
				if !closed { return .Unsupported_Layout }
				i = end
			} else {
				for i < len(source) && source[i] != '\n' { i += 1 }
			}
			continue
		} else if c == '"' || c == '\'' {
			end := i + 1
			for {
				if end >= len(source) || source[end] == '\n' { return .Unsupported_Layout }
				if source[end] == '\\' {
					end += 2
					continue
				}
				if source[end] == c { break }
				end += 1
			}
			i = end + 1
			kind = .String
		} else if level, is_long := config_edit_long_level(source, i); is_long {
			end, closed := config_edit_long_end(source, i, level)
			if !closed { return .Unsupported_Layout }
			i = end
			kind = .String
		} else if config_edit_is_name_start(c) {
			for i < len(source) && config_edit_is_name_char(source[i]) { i += 1 }
			kind = .Name
		} else if c >= '0' && c <= '9' {
			for i < len(source) && (config_edit_is_name_char(source[i]) || source[i] == '.') { i += 1 }
			kind = .Other
		} else {
			i += 1
			kind = .Punct
		}
		if _, append_err := append(tokens, Config_Token{kind = kind, start = start, end = i}); append_err != nil {
			return .Allocation
		}
	}
	return .None
}

// config_edit_long_level reports whether a long bracket opens at start, and its level:
// the number of '=' between its two brackets.
@(private = "file")
config_edit_long_level :: proc(source: string, start: int) -> (level: int, ok: bool) {
	if start >= len(source) || source[start] != '[' { return 0, false }
	i := start + 1
	for i < len(source) && source[i] == '=' { i += 1 }
	if i < len(source) && source[i] == '[' { return i - start - 1, true }
	return 0, false
}

// config_edit_long_end returns the index just past the long bracket that closes the one
// opened at start, which has the given level.
@(private = "file")
config_edit_long_end :: proc(source: string, start, level: int) -> (end: int, closed: bool) {
	for j := start + level + 2; j < len(source); j += 1 {
		if source[j] != ']' { continue }
		k := j + 1
		count := 0
		for k < len(source) && source[k] == '=' {
			count += 1
			k += 1
		}
		if count == level && k < len(source) && source[k] == ']' { return k + 1, true }
	}
	return 0, false
}

@(private = "file")
config_edit_is_name_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

@(private = "file")
config_edit_is_name_char :: proc(c: u8) -> bool {
	return config_edit_is_name_start(c) || (c >= '0' && c <= '9')
}

@(private = "file")
config_edit_punct :: proc(source: string, token: Config_Token, char: u8) -> bool {
	return token.kind == .Punct && source[token.start] == char
}

// config_edit_returned_table finds the table the file returns, the first return
// statement's table constructor.
@(private = "file")
config_edit_returned_table :: proc(source: string, tokens: []Config_Token) -> (open: int, ok: bool) {
	for token, index in tokens {
		if token.kind == .Name && source[token.start:token.end] == "return" {
			if index + 1 < len(tokens) && config_edit_punct(source, tokens[index + 1], '{') { return index + 1, true }
			return 0, false
		}
	}
	return 0, false
}

// config_edit_match returns the index of the bracket that closes the one at open.
@(private = "file")
config_edit_match :: proc(source: string, tokens: []Config_Token, open: int) -> (close: int, ok: bool) {
	depth := 0
	for index := open; index < len(tokens); index += 1 {
		token := tokens[index]
		if token.kind != .Punct { continue }
		switch source[token.start] {
		case '{', '(', '[':
			depth += 1
		case '}', ')', ']':
			depth -= 1
			if depth == 0 { return index, true }
		}
	}
	return 0, false
}

// config_edit_table returns the close index and the fields of the table constructor
// opened at open. The fields are temporary.
@(private = "file")
config_edit_table :: proc(source: string, tokens: []Config_Token, open: int) -> (close: int, fields: []Config_Field, err: Config_Edit_Error) {
	if open < 0 || open >= len(tokens) || !config_edit_punct(source, tokens[open], '{') { return 0, nil, .Unsupported_Layout }
	matched, ok := config_edit_match(source, tokens, open)
	if !ok { return 0, nil, .Unsupported_Layout }
	list := make([dynamic]Config_Field, context.temp_allocator)
	if field_err := config_edit_fields(source, tokens, open, matched, &list); field_err != .None { return 0, nil, field_err }
	return matched, list[:], .None
}

// config_edit_field_table returns the open index and fields of a field whose value must
// be exactly one table constructor.
@(private = "file")
config_edit_field_table :: proc(source: string, tokens: []Config_Token, field: Config_Field) -> (open: int, fields: []Config_Field, err: Config_Edit_Error) {
	close, table_fields, table_err := config_edit_table(source, tokens, field.first)
	if table_err != .None { return 0, nil, table_err }
	if close != field.last { return 0, nil, .Unsupported_Layout }
	return field.first, table_fields, .None
}

// config_edit_fields reads the entries between open and close into fields.
@(private = "file")
config_edit_fields :: proc(source: string, tokens: []Config_Token, open, close: int, fields: ^[dynamic]Config_Field) -> Config_Edit_Error {
	index := open + 1
	for index < close {
		if config_edit_punct(source, tokens[index], ',') || config_edit_punct(source, tokens[index], ';') {
			index += 1
			continue
		}
		field := Config_Field {
			first = index,
		}
		value := index
		if config_edit_punct(source, tokens[index], '[') {
			if index + 3 >= close ||
			   tokens[index + 1].kind != .String ||
			   !config_edit_punct(source, tokens[index + 2], ']') ||
			   !config_edit_punct(source, tokens[index + 3], '=') {
				return .Unsupported_Layout
			}
			key, quoted := config_edit_unquote(source, tokens[index + 1])
			if !quoted { return .Unsupported_Layout }
			field.key, field.has_key = key, true
			value = index + 4
		} else if tokens[index].kind == .Name && index + 1 < close && config_edit_punct(source, tokens[index + 1], '=') {
			field.key, field.has_key = source[tokens[index].start:tokens[index].end], true
			value = index + 2
		}
		separator := config_edit_value_end(source, tokens, value, close)
		if separator == value { return .Unsupported_Layout }
		field.first, field.last = value, separator - 1
		if _, append_err := append(fields, field); append_err != nil { return .Allocation }
		index = separator + 1
	}
	return .None
}

// config_edit_value_end returns the index of the comma or semicolon that ends the value
// starting at value, or close when the value is the last entry.
@(private = "file")
config_edit_value_end :: proc(source: string, tokens: []Config_Token, value, close: int) -> int {
	depth := 0
	for index := value; index < close; index += 1 {
		token := tokens[index]
		if token.kind != .Punct { continue }
		switch source[token.start] {
		case '{', '(', '[':
			depth += 1
		case '}', ')', ']':
			depth -= 1
		case ',', ';':
			if depth == 0 { return index }
		}
	}
	return close
}

// config_edit_unquote returns the text of a quoted string token. A long string or an
// escaped one is not a plain key and is refused.
@(private = "file")
config_edit_unquote :: proc(source: string, token: Config_Token) -> (text: string, ok: bool) {
	if token.kind != .String || token.end - token.start < 2 { return "", false }
	quote := source[token.start]
	if quote != '"' && quote != '\'' { return "", false }
	inner := source[token.start + 1:token.end - 1]
	if strings.contains_rune(inner, '\\') { return "", false }
	return inner, true
}

@(private = "file")
config_edit_find :: proc(fields: []Config_Field, key: string) -> (index: int, found: bool) {
	for field, position in fields {
		if field.has_key && field.key == key { return position, true }
	}
	return 0, false
}

// config_edit_insert_field adds field_text as the first entry of the table opened at
// open, on its own line indented one step past the line that opens the table.
@(private = "file")
config_edit_insert_field :: proc(
	source: string,
	tokens: []Config_Token,
	open: int,
	field_text: string,
	allocator := context.allocator,
) -> (
	string,
	Config_Edit_Error,
) {
	brace := tokens[open]
	indent := config_edit_line_indent(source, brace.start)
	text := fmt.tprintf("\n%s    %s,", indent, field_text)
	return config_edit_splice(source, brace.end, brace.end, text, allocator)
}

// config_edit_line_indent returns the leading blanks of the line that holds position.
@(private = "file")
config_edit_line_indent :: proc(source: string, position: int) -> string {
	line_start := position
	for line_start > 0 && source[line_start - 1] != '\n' { line_start -= 1 }
	line_end := line_start
	for line_end < len(source) && (source[line_end] == ' ' || source[line_end] == '\t') { line_end += 1 }
	return source[line_start:line_end]
}

@(private = "file")
config_edit_splice :: proc(source: string, start, end: int, text: string, allocator := context.allocator) -> (string, Config_Edit_Error) {
	edited, concat_err := strings.concatenate({source[:start], text, source[end:]}, allocator)
	if concat_err != nil { return "", .Allocation }
	return edited, .None
}
