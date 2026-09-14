package skills

import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

Cancel_Check :: proc() -> bool

Read_Control :: struct {
	cancelled:    Cancel_Check,
	deadline:     time.Tick,
	has_deadline: bool,
}

load :: proc(skill: Skill, root: Root, control: Read_Control, allocator := context.allocator) -> (Loaded, Load_Error) {
	if read_control_cancelled(control) { return {}, error_make(.Cancelled, allocator = allocator) }
	if read_control_timed_out(control) { return {}, error_make(.Timed_Out, allocator = allocator) }
	if skill.root_index < 0 { return {}, error_make(.Outside_Authority, detail = "skill has no source root", allocator = allocator) }
	if root.source == .Project && !path_within(skill.directory, root.authority) {
		return {}, error_make(.Outside_Authority, detail = "skill directory is outside the project boundary", allocator = allocator)
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
	defer os.close(file)
	before, stat_error := os.fstat(file, allocator)
	if stat_error != nil { return {}, error_make(.Unreadable, detail = os.error_string(stat_error), allocator = allocator) }
	defer os.file_info_delete(before, allocator)
	if before.type != .Regular { return {}, error_make(.Not_Regular, detail = "SKILL.md is not a regular file", allocator = allocator) }
	if before.size > SKILL_MAX_FILE_BYTES { return {}, error_make(.Too_Large, detail = "SKILL.md exceeds the byte limit", allocator = allocator) }
	if read_control_cancelled(control) { return {}, error_make(.Cancelled, allocator = allocator) }
	if read_control_timed_out(control) { return {}, error_make(.Timed_Out, allocator = allocator) }

	data, read_error := os.read_entire_file(file, allocator)
	if read_error != nil { return {}, error_make(.Unreadable, detail = os.error_string(read_error), allocator = allocator) }
	defer delete(data, allocator)
	if len(data) > SKILL_MAX_FILE_BYTES { return {}, error_make(.Too_Large, detail = "SKILL.md exceeds the byte limit", allocator = allocator) }
	if read_control_cancelled(control) { return {}, error_make(.Cancelled, allocator = allocator) }
	if read_control_timed_out(control) { return {}, error_make(.Timed_Out, allocator = allocator) }
	after, after_error := os.fstat(file, allocator)
	if after_error != nil { return {}, error_make(.Unreadable, detail = os.error_string(after_error), allocator = allocator) }
	defer os.file_info_delete(after, allocator)
	if before.device != after.device || before.inode != after.inode || before.size != after.size || before.modification_time != after.modification_time {
		return {}, error_make(.Changed_During_Read, detail = "SKILL.md changed while it was read", allocator = allocator)
	}

	directory_name := filepath.base(skill.logical_path[:len(skill.logical_path) - len("/SKILL.md")])
	metadata, metadata_error := parse_metadata(data, directory_name, allocator)
	if metadata_error.kind != .None { return {}, metadata_error }
	defer metadata_destroy(&metadata, allocator)
	if metadata.digest != skill.metadata_digest {
		return {}, error_make(.Stale_Metadata, detail = "skill metadata changed; start a new session", allocator = allocator)
	}
	body := string(data)[metadata.body_offset:]
	if !skill_body_valid(body) { return {}, error_make(.Invalid_Text, detail = "skill body is empty or contains invalid text", allocator = allocator) }
	owned := strings.clone(body, allocator)
	return Loaded{body = owned, content_digest = content_digest(owned)}, {}
}

read_control_cancelled :: proc(control: Read_Control) -> bool {
	return control.cancelled != nil && control.cancelled()
}

read_control_timed_out :: proc(control: Read_Control) -> bool {
	return control.has_deadline && time.tick_since(control.deadline) >= 0
}

path_within :: proc(path, authority: string) -> bool {
	if authority == "" || path == authority { return path == authority }
	if !strings.has_prefix(path, authority) { return false }
	return len(path) > len(authority) && path[len(authority)] == filepath.SEPARATOR
}

skill_body_valid :: proc(body: string) -> bool {
	has_content := false
	for index := 0; index < len(body); {
		r, width := utf8.decode_rune_in_string(body[index:])
		if r == utf8.RUNE_ERROR && width == 1 { return false }
		if r == 0 || r == 0x1b || r == 0x7f || r < 0x20 && r != '\t' && r != '\n' && r != '\r' { return false }
		if r != ' ' && r != '\t' && r != '\n' && r != '\r' { has_content = true }
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
