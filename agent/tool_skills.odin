package agent

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

import "nabla:agent/skills"

TOOL_LIST_SKILLS_NAME :: "builtin_list_skills"
TOOL_LIST_SKILLS_DESCRIPTION :: "Search the available skills by name and description. Use it to find which skill fits a task when your instructions do not already list them; it returns metadata only, so load the one you need with builtin_load_skill. query holds whitespace-separated terms, all of which must appear in the name or description (case-insensitive); a skill whose name equals the query comes first; leave query out to list every skill. The result gives total_matches, next_offset when more matches remain (pass it as offset for the next page), and for each skill its name, source, and description. limit defaults to 20 and offset to 0."
TOOL_LIST_SKILLS_SCHEMA :: `{"type":"object","properties":{"query":{"type":["string","null"],"description":"Whitespace-separated terms; every term must occur in the name or description. Leave out to list all."},"offset":{"type":["integer","null"],"description":"Index of the first match to return, counting from 0. Default: 0. Use next_offset from the previous result."},"limit":{"type":["integer","null"],"description":"Maximum matches to return. Default: 20."}},"additionalProperties":false}`
TOOL_LIST_SKILLS_FIELDS :: []string{"query", "offset", "limit"}
TOOL_LIST_SKILLS_DEFAULT_LIMIT :: 20

TOOL_LOAD_SKILL_NAME :: "builtin_load_skill"
TOOL_LOAD_SKILL_DESCRIPTION :: "Load one skill's complete instructions by its exact name, before doing work the skill covers. The name comes from your instructions or builtin_list_skills; an unknown name fails and suggests names that start with it. The result gives name, path (the skill's SKILL.md), directory (the skill's folder), and content_digest, and the instructions follow after a blank line."
TOOL_LOAD_SKILL_SCHEMA :: `{"type":"object","properties":{"name":{"type":"string","description":"The exact skill name, as listed in your instructions or by builtin_list_skills."}},"required":["name"],"additionalProperties":false}`
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

@(require_results)
tool_list_skills_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: List_Skills_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_LIST_SKILLS_FIELDS, allocator = ctx.allocator) or_return
	args.query = tool_field_optional_string(arguments, "query", allocator = ctx.allocator) or_return
	args.offset = tool_field_optional_int(arguments, "offset", 0, 0, TOOL_PAGE_MAX_VALUE, &ctx.repairs, allocator = ctx.allocator) or_return
	args.limit = tool_field_optional_int(
		arguments,
		"limit",
		TOOL_LIST_SKILLS_DEFAULT_LIMIT,
		1,
		TOOL_PAGE_MAX_VALUE,
		&ctx.repairs,
		allocator = ctx.allocator,
	) or_return
	return
}

@(require_results)
tool_list_skills_execute :: proc(ctx: ^Tool_Context, arguments: Tool_Args) -> Tool_Result {
	args := arguments.(List_Skills_Args)
	query, offset, limit := args.query, args.offset, args.limit
	if ctx.skills == nil {
		return tool_result_failure(ctx, .Unavailable, "skills are unavailable in this session", "unavailable")
	}
	matches, match_error := list_skills_match(ctx.skills.skills, query, ctx.allocator)
	if match_error != nil {
		return tool_result_failure(ctx, .Tool_Failed, "the skill listing could not be built: out of memory", "out of memory")
	}
	defer delete(matches, ctx.allocator)
	page_end := len(matches)
	if offset <= len(matches) && limit <= len(matches) - offset { page_end = offset + limit }
	page := matches[offset:page_end] if offset <= len(matches) else matches[len(matches):]
	records, record_error := make([]Skill_Record, len(page), ctx.allocator)
	if record_error != nil {
		return tool_result_failure(ctx, .Tool_Failed, "the skill listing could not be allocated: out of memory", "out of memory")
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

@(require_results)
tool_load_skill_args :: proc(ctx: ^Tool_Context, arguments: json.Object) -> (args: Load_Skill_Args, err: Tool_Argument_Error) {
	tool_fields_known(arguments, TOOL_LOAD_SKILL_FIELDS, allocator = ctx.allocator) or_return
	args.name = tool_field_string(arguments, "name", allocator = ctx.allocator) or_return
	return
}

@(require_results)
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
		suggestions, suggestion_error := tool_skill_suggestions(ctx.skills, name, context.temp_allocator)
		if suggestion_error != nil {
			return tool_result_failure(ctx, .Tool_Failed, "the available skills could not be listed: out of memory", "out of memory")
		}
		return tool_result_failure(ctx, .Tool_Failed, suggestions, "unknown skill")
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

// list_skills_match returns the matching skills in name order, owned by allocator, with the
// skill whose name is exactly the query first. It reports an allocator error when the
// listing could not be built.
@(require_results)
list_skills_match :: proc(catalog: []skills.Skill, query: string, allocator := context.allocator) -> ([]^skills.Skill, mem.Allocator_Error) {
	terms, terms_error := list_skills_terms(query, allocator)
	if terms_error != nil { return nil, terms_error }
	defer {
		for term in terms { delete(term, allocator) }
		delete(terms, allocator)
	}
	matches, matches_error := make([dynamic]^skills.Skill, 0, len(catalog), allocator)
	if matches_error != nil { return nil, matches_error }
	defer delete(matches)
	for &skill in catalog {
		matched, match_error := list_skills_matches(&skill, terms)
		if match_error != nil { return nil, match_error }
		if !matched { continue }
		if _, append_error := append(&matches, &skill); append_error != nil { return nil, append_error }
	}
	exact: ^skills.Skill
	for match in matches {
		if exact == nil && match.name == strings.trim_space(query) { exact = match }
	}
	// The exact match is hoisted in one pass, so the answer is a single owned slice.
	ordered, ordered_error := make([]^skills.Skill, len(matches), allocator)
	if ordered_error != nil { return nil, ordered_error }
	position := 0
	if exact != nil {
		ordered[position] = exact
		position += 1
	}
	for match in matches {
		if match == exact { continue }
		ordered[position] = match
		position += 1
	}
	return ordered, nil
}

// list_skills_terms returns the query's whitespace-separated terms, folded to lower case and
// owned by allocator. It reports an allocator error when the terms could not be built.
@(require_results)
list_skills_terms :: proc(query: string, allocator := context.allocator) -> ([]string, mem.Allocator_Error) {
	fields, fields_error := strings.fields(query, allocator)
	if fields_error != nil { return nil, fields_error }
	defer delete(fields, allocator)
	terms, terms_error := make([dynamic]string, 0, len(fields), allocator)
	if terms_error != nil { return nil, terms_error }
	transferred := false
	defer if !transferred {
		for term in terms { delete(term, allocator) }
		delete(terms)
	}
	for field in fields {
		lowered, lower_error := strings.to_lower(field, allocator)
		if lower_error != nil { return nil, lower_error }
		if _, append_error := append(&terms, lowered); append_error != nil {
			delete(lowered, allocator)
			return nil, append_error
		}
	}
	transferred = true
	return terms[:], nil
}

// list_skills_matches reports whether every term occurs in the skill's name or description.
@(require_results)
list_skills_matches :: proc(skill: ^skills.Skill, terms: []string) -> (bool, mem.Allocator_Error) {
	// The folded copies exist to be searched and are released with the answer.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if len(terms) == 0 { return true, nil }
	name, name_error := strings.to_lower(skill.name, context.temp_allocator)
	if name_error != nil { return false, name_error }
	description, description_error := strings.to_lower(skill.description, context.temp_allocator)
	if description_error != nil { return false, description_error }
	for term in terms {
		if !strings.contains(name, term) && !strings.contains(description, term) { return false, nil }
	}
	return true, nil
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

// tool_skill_suggestions names the skills whose names begin with an unknown name, owned by
// allocator. It reports an allocator error when the suggestion line could not be built.
@(require_results)
tool_skill_suggestions :: proc(catalog: ^skills.Catalog, name: string, allocator := context.allocator) -> (string, mem.Allocator_Error) {
	suggestions, suggestions_error := make([dynamic]string, 0, 3, allocator)
	if suggestions_error != nil { return "", suggestions_error }
	defer delete(suggestions)
	for &skill in catalog.skills {
		if len(suggestions) >= 3 { break }
		if !strings.has_prefix(skill.name, name) { continue }
		if _, append_error := append(&suggestions, skill.name); append_error != nil { return "", append_error }
	}
	if len(suggestions) == 0 { return fmt.aprintf("no skill named %q is available", name, allocator = allocator), nil }
	joined, join_error := strings.join(suggestions[:], ", ", allocator)
	if join_error != nil { return "", join_error }
	defer delete(joined, allocator)
	return fmt.aprintf("no skill named %q is available; did you mean %s", name, joined, allocator = allocator), nil
}

@(require_results)
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

@(require_results)
skill_primary_path :: proc(skill: skills.Skill, allocator := context.allocator) -> (string, mem.Allocator_Error) {
	if strings.has_suffix(skill.directory, "/") { return strings.concatenate({skill.directory, "SKILL.md"}, allocator) }
	return strings.concatenate({skill.directory, "/SKILL.md"}, allocator)
}
