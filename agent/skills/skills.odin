package skills

import "core:strings"

SKILL_MAX_FRONTMATTER_BYTES :: 64 * 1024
SKILL_MAX_NAME_BYTES :: 64
SKILL_MAX_DESCRIPTION_RUNES :: 1024
SKILL_MAX_FILE_BYTES :: 256 * 1024

// Source_Kind names where a skill root comes from. The session orders roots by
// priority; discovery itself only needs to know which roots are scope-bound
// (Local) and which are user-owned.
Source_Kind :: enum {
	Unknown,
	Nabla_User,
	Local,
	Generic_User,
}

Root :: struct {
	source:       Source_Kind,
	logical_path: string,
	path:         string,
	authority:    string,
}

Skill :: struct {
	name:            string,
	description:     string,
	logical_path:    string,
	directory:       string,
	root_index:      int,
	metadata_digest: [32]u8,
}

Loaded :: struct {
	body:           string,
	content_digest: [32]u8,
}

Error_Kind :: enum {
	None,
	Missing,
	Unreadable,
	Not_Regular,
	Invalid_Metadata,
	Unsupported_Metadata,
	Stale_Metadata,
	Invalid_Text,
	Too_Large,
	Outside_Authority,
	Changed_During_Read,
	Cancelled,
	Timed_Out,
	Allocation,
}

Load_Error :: struct {
	kind:   Error_Kind,
	line:   int,
	field:  string,
	detail: string,
}

Metadata :: struct {
	name:        string,
	description: string,
	body_offset: int,
	digest:      [32]u8,
}

metadata_destroy :: proc(metadata: ^Metadata, allocator := context.allocator) {
	if metadata == nil { return }
	delete(metadata.name, allocator)
	delete(metadata.description, allocator)
	metadata^ = {}
}

loaded_destroy :: proc(loaded: ^Loaded, allocator := context.allocator) {
	if loaded == nil { return }
	delete(loaded.body, allocator)
	loaded^ = {}
}

load_error_destroy :: proc(load_error: ^Load_Error, allocator := context.allocator) {
	if load_error == nil { return }
	delete(load_error.field, allocator)
	delete(load_error.detail, allocator)
	load_error^ = {}
}

error_make :: proc(kind: Error_Kind, line: int = 0, field: string = "", detail: string = "", allocator := context.allocator) -> Load_Error {
	return Load_Error{kind = kind, line = line, field = strings.clone(field, allocator), detail = strings.clone(detail, allocator)}
}
