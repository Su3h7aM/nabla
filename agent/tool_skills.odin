package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:agent/skills"

TOOL_LIST_SKILLS_NAME :: "builtin_list_skills"
TOOL_LIST_SKILLS_DESCRIPTION :: "List available skills by metadata. Returns name and description records with stable pagination; metadata is not the complete instructions."
TOOL_LIST_SKILLS_SCHEMA :: `{"type":"object","properties":{"query":{"type":["string","null"],"description":"Whitespace-separated terms; every term must occur in the name or description."},"offset":{"type":["integer","null"],"description":"First match to return."},"limit":{"type":["integer","null"],"description":"Maximum matches to return."}},"additionalProperties":false}`
TOOL_LIST_SKILLS_FIELDS :: []string{"query", "offset", "limit"}
TOOL_LIST_SKILLS_DEFAULT_LIMIT :: 20

TOOL_LOAD_SKILL_NAME :: "builtin_load_skill"
TOOL_LOAD_SKILL_DESCRIPTION :: "Load one skill's complete instructions by name. Returns the full body in a single tool result."
TOOL_LOAD_SKILL_SCHEMA :: `{"type":"object","properties":{"name":{"type":"string","description":"The skill name from the catalog."}},"required":["name"],"additionalProperties":false}`
TOOL_LOAD_SKILL_FIELDS :: []string{"name"}

TOOL_LIST_SKILLS_DEFINITION :: Tool_Definition {
	name = TOOL_LIST_SKILLS_NAME,
	description = TOOL_LIST_SKILLS_DESCRIPTION,
	input_schema = TOOL_LIST_SKILLS_SCHEMA,
	hints = {read_only = .Yes, destructive = .No, idempotent = .Yes, open_world = .No},
	kind = .List_Skills,
	execute = tool_list_skills_execute,
}

TOOL_LOAD_SKILL_DEFINITION :: Tool_Definition {
	name = TOOL_LOAD_SKILL_NAME,
	description = TOOL_LOAD_SKILL_DESCRIPTION,
	input_schema = TOOL_LOAD_SKILL_SCHEMA,
	hints = {read_only = .Yes, destructive = .No, idempotent = .Yes, open_world = .No},
	kind = .Load_Skill,
	execute = tool_load_skill_execute,
}

tool_list_skills_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: List_Skills_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_LIST_SKILLS_FIELDS, allocator = ctx.allocator) or_return
	args.query = tool_field_optional_string(arguments, "query", allocator = ctx.allocator) or_return
	args.offset = tool_field_optional_int(arguments, "offset", 0, 0, max(int) / 2, &ctx.repairs, allocator = ctx.allocator) or_return
	args.limit = tool_field_optional_int(
		arguments,
		"limit",
		TOOL_LIST_SKILLS_DEFAULT_LIMIT,
		1,
		max(int) / 2,
		&ctx.repairs,
		allocator = ctx.allocator,
	) or_return
	return
}

tool_list_skills_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(List_Skills_Args)
	query, offset, limit := args.query, args.offset, args.limit
	if ctx.skills == nil {
		return tool_result_failure(ctx, .Unavailable, "skills are unavailable in this session", "unavailable")
	}
	matches, matched := list_skills_match(ctx.skills.skills, query, ctx.allocator)
	if !matched {
		return tool_result_failure(ctx, .Tool_Failed, "the skill listing could not be built", "too large")
	}
	defer delete(matches, ctx.allocator)
	page_end := len(matches)
	if offset <= len(matches) && limit <= len(matches) - offset { page_end = offset + limit }
	page := matches[offset:page_end] if offset <= len(matches) else matches[len(matches):]
	records := make([]Skill_Record, len(page), ctx.allocator)
	if len(page) > 0 && records == nil {
		return tool_result_failure(ctx, .Tool_Failed, "the skill listing could not be allocated", "allocation failed")
	}
	defer delete(records, ctx.allocator)
	for match, index in page {
		records[index] = Skill_Record {
			name        = match.name,
			description = match.description,
			source      = skill_source_label(ctx.skills, match^),
		}
	}
	next_offset: Maybe(int)
	if page_end < len(matches) { next_offset = page_end }
	data := Skills_Output {
		skills        = records,
		total_matches = len(matches),
		next_offset   = next_offset,
	}
	return tool_result_success(ctx, data, fmt.tprintf("%d of %d skills", len(records), len(matches)))
}

tool_load_skill_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Load_Skill_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_LOAD_SKILL_FIELDS, allocator = ctx.allocator) or_return
	args.name = tool_field_string(arguments, "name", allocator = ctx.allocator) or_return
	return
}

tool_load_skill_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(Load_Skill_Args)
	name := args.name
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
	loaded, load_error := skills.load(skill, root, ctx.allocator)
	defer skills.loaded_destroy(&loaded, ctx.allocator)
	defer skills.load_error_destroy(&load_error, ctx.allocator)
	if load_error.kind != .None {
		return tool_result_failure(ctx, .Tool_Failed, skills.error_text(load_error), "load failed")
	}
	digest, digest_error := skill_digest_text(loaded.content_digest, ctx.allocator)
	if digest_error != nil { return tool_result_failure(ctx, .Tool_Failed, "the skill digest could not be allocated", "encoding failed") }
	defer delete(digest, ctx.allocator)
	primary, primary_error := skill_primary_path(skill, ctx.allocator)
	if primary_error != nil { return tool_result_failure(ctx, .Tool_Failed, "the skill path could not be allocated", "encoding failed") }
	defer delete(primary, ctx.allocator)
	data := Skill_Output {
		name           = skill.name,
		path           = primary,
		directory      = skill.directory,
		content_digest = digest,
		instructions   = loaded.body,
	}
	result := tool_result_success(ctx, data, fmt.tprintf("loaded skill %s", skill.name))
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

list_skills_matches :: proc(skill: ^skills.Skill, terms: []string) -> bool {
	// The folded copies exist to be searched and are released with the answer.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
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

skill_digest_text :: proc(digest: [32]u8, allocator := context.allocator) -> (string, mem.Allocator_Error) {
	out, out_error := make([]u8, 64, allocator)
	if out_error != nil { return "", out_error }
	for value, index in digest {
		high, low := skill_hex_nibbles(value)
		out[index * 2] = high
		out[index * 2 + 1] = low
	}
	return string(out), nil
}

skill_hex_nibbles :: proc(value: u8) -> (u8, u8) {
	return skill_hex_digit(value >> 4), skill_hex_digit(value & 0x0f)
}

skill_hex_digit :: proc(nibble: u8) -> u8 {
	if nibble < 10 { return '0' + nibble }
	return 'a' + (nibble - 10)
}

skill_primary_path :: proc(skill: skills.Skill, allocator := context.allocator) -> (string, mem.Allocator_Error) {
	if strings.has_suffix(skill.directory, "/") { return strings.concatenate({skill.directory, "SKILL.md"}, allocator) }
	return strings.concatenate({skill.directory, "/SKILL.md"}, allocator)
}
