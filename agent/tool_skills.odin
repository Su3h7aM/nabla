package agent

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import "nabla:agent/session"
import "nabla:agent/skills"
import "nabla:ai"

TOOL_LIST_SKILLS_NAME :: "list_skills"
TOOL_LIST_SKILLS_DESCRIPTION :: "List available skills by metadata. Returns name and description records with stable pagination; metadata is not the complete instructions."
TOOL_LIST_SKILLS_SCHEMA :: `{"type":"object","properties":{"query":{"type":["string","null"],"description":"Whitespace-separated terms; every term must occur in the name or description."},"offset":{"type":["integer","null"],"description":"First match to return."},"limit":{"type":["integer","null"],"description":"Maximum matches to return."}},"additionalProperties":false}`
TOOL_LIST_SKILLS_FIELDS :: []string{"query", "offset", "limit"}
TOOL_LIST_SKILLS_DEFAULT_LIMIT :: 20
TOOL_LIST_SKILLS_MAX_LIMIT :: 100
TOOL_LIST_SKILLS_MAX_QUERY_BYTES :: 4096

TOOL_LOAD_SKILL_NAME :: "load_skill"
TOOL_LOAD_SKILL_DESCRIPTION :: "Load one skill's complete instructions by name. Returns the full body in a single tool result."
TOOL_LOAD_SKILL_SCHEMA :: `{"type":"object","properties":{"name":{"type":"string","description":"The skill name from the catalog."}},"required":["name"],"additionalProperties":false}`
TOOL_LOAD_SKILL_FIELDS :: []string{"name"}

List_Skills_Record :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	source:      string `json:"source"`,
}

List_Skills_Data :: struct {
	skills:        []List_Skills_Record `json:"skills"`,
	total_matches: int `json:"total_matches"`,
	next_offset:   Maybe(int) `json:"next_offset"`,
}

Load_Skill_Data :: struct {
	name:           string `json:"name"`,
	path:           string `json:"path"`,
	directory:      string `json:"directory"`,
	content_digest: string `json:"content_digest"`,
	complete:       bool `json:"complete"`,
	instructions:   string `json:"instructions"`,
}

TOOL_LIST_SKILLS_DEFINITION :: Tool_Definition {
	name         = TOOL_LIST_SKILLS_NAME,
	description  = TOOL_LIST_SKILLS_DESCRIPTION,
	input_schema = TOOL_LIST_SKILLS_SCHEMA,
	execute      = tool_list_skills_execute,
}

TOOL_LOAD_SKILL_DEFINITION :: Tool_Definition {
	name         = TOOL_LOAD_SKILL_NAME,
	description  = TOOL_LOAD_SKILL_DESCRIPTION,
	input_schema = TOOL_LOAD_SKILL_SCHEMA,
	execute      = tool_load_skill_execute,
}

tool_list_skills_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	if known_error := tool_fields_known(arguments, TOOL_LIST_SKILLS_FIELDS, allocator = ctx.allocator); known_error.kind != .None {
		return tool_result_refused(ctx, &known_error)
	}
	query, query_error := tool_field_optional_string(arguments, "query", allocator = ctx.allocator)
	if query_error.kind != .None { return tool_result_refused(ctx, &query_error) }
	offset, offset_error := tool_field_optional_int(arguments, "offset", 0, 0, max(int) / 2, allocator = ctx.allocator)
	if offset_error.kind != .None { return tool_result_refused(ctx, &offset_error) }
	limit, limit_error := tool_field_optional_int(arguments, "limit", TOOL_LIST_SKILLS_DEFAULT_LIMIT, 1, TOOL_LIST_SKILLS_MAX_LIMIT, allocator = ctx.allocator)
	if limit_error.kind != .None { return tool_result_refused(ctx, &limit_error) }
	if ctx.skills == nil {
		return tool_result_failure(ctx, .Unavailable, "skills are unavailable in this session", "unavailable")
	}
	if len(query) > TOOL_LIST_SKILLS_MAX_QUERY_BYTES {
		oversized := tool_argument_error(.Too_Large, "query", "at most 4096 bytes", ctx.allocator)
		return tool_result_refused(ctx, &oversized)
	}
	matches, matched := list_skills_match(ctx.skills.skills, query, ctx.allocator)
	if !matched {
		return tool_result_failure(ctx, .Tool_Failed, "the skill listing could not be built", "too large")
	}
	defer delete(matches, ctx.allocator)
	// The listing shares the global result budget with every other tool. When
	// the requested page does not fit, the page shrinks instead of bypassing
	// the bound: the caller pages forward with next_offset as usual.
	page_limit := limit
	for {
		page_end := len(matches)
		if offset <= len(matches) && page_limit <= len(matches) - offset { page_end = offset + page_limit }
		page := matches[offset:page_end] if offset <= len(matches) else matches[len(matches):]
		records := make([]List_Skills_Record, len(page), ctx.allocator)
		if len(page) > 0 && records == nil {
			return tool_result_failure(ctx, .Tool_Failed, "the skill listing could not be built", "too large")
		}
		for match, index in page {
			records[index] = List_Skills_Record {
				name        = match.name,
				description = match.description,
				source      = skill_source_label(ctx.skills, match^),
			}
		}
		next_offset: Maybe(int)
		if page_end < len(matches) { next_offset = page_end }
		data := List_Skills_Data {
			skills        = records,
			total_matches = len(matches),
			next_offset   = next_offset,
		}
		result := tool_result_success(ctx, data, fmt.tprintf("%d of %d skills", len(records), len(matches)))
		delete(records, ctx.allocator)
		if result.content == "" {
			tool_result_destroy(&result)
			return tool_result_failure(ctx, .Tool_Failed, "the skill listing could not be encoded", "encoding failed")
		}
		if len(result.content) <= TOOL_MAX_RESULT_BYTES { return result }
		tool_result_destroy(&result)
		if page_limit <= 1 {
			return tool_result_failure(ctx, .Tool_Failed, "the skill listing exceeds the result limit; narrow the query or use a smaller limit", "too large")
		}
		page_limit /= 2
	}
}

tool_load_skill_execute :: proc(ctx: ^Tool_Context, arguments: json.Object) -> Tool_Result {
	if known_error := tool_fields_known(arguments, TOOL_LOAD_SKILL_FIELDS, allocator = ctx.allocator); known_error.kind != .None {
		return tool_result_refused(ctx, &known_error)
	}
	name, name_error := tool_field_string(arguments, "name", allocator = ctx.allocator)
	if name_error.kind != .None { return tool_result_refused(ctx, &name_error) }
	if ctx.skills == nil {
		return tool_result_failure(ctx, .Unavailable, "skills are unavailable in this session", "unavailable")
	}
	if !skills.skill_name_valid(name) {
		invalid := tool_argument_error(.Invalid_Value, "name", "a canonical skill name", ctx.allocator)
		return tool_result_refused(ctx, &invalid)
	}
	index, found := skills.find(ctx.skills.skills, name)
	if !found {
		return tool_result_failure(ctx, .Tool_Failed, tool_skill_suggestions(ctx.skills, name, ctx.allocator), "unknown skill")
	}
	skill := ctx.skills.skills[index]
	if skill.root_index < 0 || skill.root_index >= len(ctx.skills.roots) {
		return tool_result_failure(ctx, .Tool_Failed, "the skill catalog is invalid", "unavailable")
	}
	root := ctx.skills.roots[skill.root_index]
	control := skills.Read_Control {
		deadline     = ctx.control.deadline.at,
		has_deadline = ctx.control.deadline.active,
		// Cancel_Check carries no context, so the check reads the process-wide
		// turn token directly: one turn runs at a time, and the token is reset
		// when a turn starts.
		cancelled    = tool_skill_cancel_check,
	}
	loaded, load_error := skills.load(skill, root, control, ctx.allocator)
	defer skills.loaded_destroy(&loaded, ctx.allocator)
	defer skills.load_error_destroy(&load_error, ctx.allocator)
	if load_error.kind != .None {
		return tool_result_failure(ctx, tool_skill_outcome(load_error.kind), skills.error_text(load_error), "load failed")
	}
	digest := skill_digest_text(loaded.content_digest, ctx.allocator)
	defer delete(digest, ctx.allocator)
	primary := skill_primary_path(skill, ctx.allocator)
	defer delete(primary, ctx.allocator)
	data := Load_Skill_Data {
		name           = skill.name,
		path           = primary,
		directory      = skill.directory,
		content_digest = digest,
		complete       = true,
		instructions   = loaded.body,
	}
	result := tool_result_success(ctx, data, fmt.tprintf("loaded skill %s", skill.name))
	if result.content == "" {
		tool_result_destroy(&result)
		return tool_result_failure(ctx, .Tool_Failed, "the skill result could not be encoded", "encoding failed")
	}
	// A single body has no smaller page to shrink to, so an oversized skill is
	// an explicit bounded failure until pagination or another deliberate design
	// exists. It must not bypass the global result budget.
	if len(result.content) > TOOL_MAX_RESULT_BYTES {
		tool_result_destroy(&result)
		return tool_result_failure(ctx, .Tool_Failed, "the skill exceeds the result limit", "too large")
	}
	return result
}

list_skills_match :: proc(catalog: []skills.Skill, query: string, allocator := context.allocator) -> ([]^skills.Skill, bool) {
	terms, terms_ok := list_skills_terms(query, allocator)
	if !terms_ok { return nil, false }
	defer {
		for term in terms { delete(term, allocator) }
		delete(terms, allocator)
	}
	matches := make([dynamic]^skills.Skill, 0, len(catalog), allocator)
	for &skill in catalog {
		if list_skills_matches(&skill, terms) { append(&matches, &skill) }
	}
	exact: ^skills.Skill
	rest := make([dynamic]^skills.Skill, 0, len(matches), allocator)
	defer delete(rest)
	for match in matches {
		if exact == nil && match.name == strings.trim_space(query) { exact = match } else { append(&rest, match) }
	}
	ordered := make([dynamic]^skills.Skill, 0, len(matches), allocator)
	if exact != nil { append(&ordered, exact) }
	for match in rest { append(&ordered, match) }
	delete(matches)
	return ordered[:], true
}

list_skills_terms :: proc(query: string, allocator := context.allocator) -> ([]string, bool) {
	fields := strings.fields(query, allocator)
	defer delete(fields, allocator)
	terms := make([dynamic]string, 0, len(fields), allocator)
	for field in fields { append(&terms, strings.to_lower(field, allocator)) }
	return terms[:], true
}

tool_skill_cancel_check :: proc() -> bool {
	return ai.interrupt_requested(&chat_cancel)
}

list_skills_matches :: proc(skill: ^skills.Skill, terms: []string) -> bool {
	if len(terms) == 0 { return true }
	name := strings.to_lower(skill.name, context.temp_allocator)
	description := strings.to_lower(skill.description, context.temp_allocator)
	for term in terms {
		if !strings.contains(name, term) && !strings.contains(description, term) { return false }
	}
	return true
}

skill_source_label :: proc(catalog: ^skills.Catalog, skill: skills.Skill) -> string {
	if skill.root_index < 0 || skill.root_index >= len(catalog.roots) { return "unknown" }
	switch catalog.roots[skill.root_index].source {
	case .Nabla_User:
		return "nabla user"
	case .Local:
		return "local"
	case .Generic_User:
		return "generic user"
	case .Unknown:
		return "unknown"
	}
	return "unknown"
}

tool_skill_suggestions :: proc(catalog: ^skills.Catalog, name: string, allocator := context.allocator) -> string {
	suggestions := make([dynamic]string, 0, 3, allocator)
	defer delete(suggestions)
	for &skill in catalog.skills {
		if len(suggestions) >= 3 { break }
		if strings.has_prefix(skill.name, name) { append(&suggestions, skill.name) }
	}
	if len(suggestions) == 0 { return fmt.tprintf("no skill named %q is available", name) }
	joined := strings.join(suggestions[:], ", ", allocator)
	defer delete(joined, allocator)
	return fmt.tprintf("no skill named %q is available; did you mean %s", name, joined)
}

tool_skill_outcome :: proc(kind: skills.Error_Kind) -> session.Tool_Outcome {
	switch kind {
	case .Cancelled:
		return .Cancelled
	case .Timed_Out:
		return .Timed_Out
	case .None,
	     .Missing,
	     .Unreadable,
	     .Not_Regular,
	     .Invalid_Metadata,
	     .Unsupported_Metadata,
	     .Stale_Metadata,
	     .Invalid_Text,
	     .Too_Large,
	     .Outside_Authority,
	     .Changed_During_Read,
	     .Allocation:
		return .Tool_Failed
	}
	return .Tool_Failed
}

skill_digest_text :: proc(digest: [32]u8, allocator := context.allocator) -> string {
	out := make([]u8, 64, allocator)
	for value, index in digest {
		high, low := skill_hex_nibbles(value)
		out[index * 2] = high
		out[index * 2 + 1] = low
	}
	return string(out)
}

skill_hex_nibbles :: proc(value: u8) -> (u8, u8) {
	return skill_hex_digit(value >> 4), skill_hex_digit(value & 0x0f)
}

skill_hex_digit :: proc(nibble: u8) -> u8 {
	if nibble < 10 { return '0' + nibble }
	return 'a' + (nibble - 10)
}

skill_primary_path :: proc(skill: skills.Skill, allocator := context.allocator) -> string {
	if strings.has_suffix(skill.directory, "/") { return strings.concatenate({skill.directory, "SKILL.md"}, allocator) }
	return strings.concatenate({skill.directory, "/SKILL.md"}, allocator)
}
