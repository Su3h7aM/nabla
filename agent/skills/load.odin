package skills

import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

// load reads a skill body and verifies it against its catalog metadata.
@(require_results)
load :: proc(skill: Skill, root: Root, allocator := context.allocator) -> (Loaded, Load_Error) {
	if skill.root_index < 0 { return {}, error_make(.Outside_Authority, detail = "skill has no source root", allocator = allocator) }
	if root.source == .Local && !path_within(skill.directory, root.authority) {
		return {}, error_make(.Outside_Authority, detail = "skill directory is outside the workspace scope", allocator = allocator)
	}

	path, path_error := filepath.join({skill.directory, "SKILL.md"}, allocator)
	if path_error != nil { return {}, error_make(.Allocation, allocator = allocator) }
	defer delete(path, allocator)
	file, open_error := os.open(path)
	if open_error != nil {
		kind: Error_Kind = .Unreadable
		if open_error == os.General_Error.Not_Exist { kind = .Missing }
		return {}, error_make(kind, detail = os.error_string(open_error), allocator = allocator)
	}
	// The read is what this call is about; a close that fails changes nothing about it.
	defer os.close(file)
	before, stat_error := os.fstat(file, allocator)
	if stat_error != nil { return {}, error_make(.Unreadable, detail = os.error_string(stat_error), allocator = allocator) }
	defer os.file_info_delete(before, allocator)
	if before.type != .Regular { return {}, error_make(.Not_Regular, detail = "SKILL.md is not a regular file", allocator = allocator) }

	data, read_error := os.read_entire_file(file, allocator)
	if read_error != nil { return {}, error_make(.Unreadable, detail = os.error_string(read_error), allocator = allocator) }
	defer delete(data, allocator)
	after, after_error := os.fstat(file, allocator)
	if after_error != nil { return {}, error_make(.Unreadable, detail = os.error_string(after_error), allocator = allocator) }
	defer os.file_info_delete(after, allocator)
	if before.device != after.device || before.inode != after.inode || before.size != after.size || before.modification_time != after.modification_time {
		return {}, error_make(.Changed_During_Read, detail = "SKILL.md changed while it was read", allocator = allocator)
	}

	suffix := "/SKILL.md"
	if !strings.has_suffix(skill.logical_path, suffix) {
		return {}, error_make(.Invalid_Metadata, detail = "skill provenance is invalid", allocator = allocator)
	}
	directory_name := filepath.base(skill.logical_path[:len(skill.logical_path) - len(suffix)])
	metadata, metadata_error := parse_metadata(data, directory_name, allocator)
	if metadata_error.kind != .None { return {}, metadata_error }
	defer metadata_destroy(&metadata, allocator)
	if metadata.digest != skill.metadata_digest {
		return {}, error_make(.Stale_Metadata, detail = "skill metadata changed; start a new session", allocator = allocator)
	}
	body := string(data)[metadata.body_offset:]
	if !skill_body_valid(body) { return {}, error_make(.Invalid_Text, detail = "skill body is empty or contains invalid text", allocator = allocator) }
	owned, clone_error := strings.clone(body, allocator)
	if clone_error != nil { return {}, error_make(.Allocation, allocator = allocator) }
	return Loaded{body = owned, content_digest = content_digest(owned)}, {}
}

// path_within reports whether path is authority itself or a directory inside it. An empty
// authority holds nothing, and a prefix that stops inside a name does not count.
@(require_results)
path_within :: proc(path, authority: string) -> bool {
	if authority == "" || path == authority { return path == authority }
	if !strings.has_prefix(path, authority) { return false }
	return len(path) > len(authority) && path[len(authority)] == filepath.SEPARATOR
}

@(require_results)
skill_body_valid :: proc(body: string) -> bool {
	has_content := false
	for index := 0; index < len(body); {
		character, width := utf8.decode_rune_in_string(body[index:])
		if character == utf8.RUNE_ERROR && width == 1 { return false }
		if character == 0 ||
		   character == 0x1b ||
		   character == 0x7f ||
		   character < 0x20 && character != '\t' && character != '\n' && character != '\r' { return false }
		if character != ' ' && character != '\t' && character != '\n' && character != '\r' { has_content = true }
		index += width
	}
	return has_content
}

content_digest :: proc(content: string) -> [32]u8 {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)content)
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	return digest
}

@(require_results)
find :: proc(skills: []Skill, name: string) -> (int, bool) {
	low, high := 0, len(skills)
	for low < high {
		middle := low + (high - low) / 2
		if skills[middle].name < name { low = middle + 1 } else { high = middle }
	}
	return low, low < len(skills) && skills[low].name == name
}

error_text :: proc(load_error: Load_Error) -> string {
	if load_error.detail != "" { return load_error.detail }
	return fmt.tprintf("skill load failed: %s", load_error.kind)
}
