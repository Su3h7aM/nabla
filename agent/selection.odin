package agent

// Selection is the front-end's last chosen serving identity and reasoning
// effort, persisted under the state directory so the next launch restores it.
// It is runtime state about which model the session runs with, not conversation
// history: no messages live here, and a missing or unusable file is simply no
// selection rather than an error.
//
// The fields are owned by whoever holds the Selection; release them with
// selection_destroy.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"

SELECTION_FILE :: "selection.json"

Selection :: struct {
	provider: string `json:"provider"`,
	model:    string `json:"model"`,
	effort:   string `json:"effort"`,
}

Selection_Error :: enum {
	None,
	// The state directory could not be resolved or created.
	State_Directory,
	// The file exists but is not a usable selection.
	Invalid,
}

// selection_destroy releases a selection's strings and zeroes it.
selection_destroy :: proc(selection: ^Selection, allocator := context.allocator) {
	delete(selection.provider, allocator)
	delete(selection.model, allocator)
	delete(selection.effort, allocator)
	selection^ = {}
}

// selection_path resolves the persisted-selection file and creates the state
// directory, mirroring the models.dev cache location. The result is owned by
// the caller.
selection_path :: proc(allocator := context.allocator) -> (string, Selection_Error) {
	directory, directory_err := xdg_directory(.State, allocator)
	if directory_err != .None { return "", .State_Directory }
	defer delete(directory, allocator)
	if create_err := xdg_directory_create(directory); create_err != .None { return "", .State_Directory }
	path, join_err := filepath.join([]string{directory, SELECTION_FILE}, allocator)
	if join_err != nil { return "", .State_Directory }
	return path, .None
}

// selection_load returns the persisted selection. A missing, unreadable, or
// malformed file yields ok = false with the zero selection: a launch without a
// previous choice is normal, so it is not reported as a failure. A loaded
// selection's strings are owned by the caller, so a rejection after the
// document parsed still releases them.
selection_load :: proc(allocator := context.allocator) -> (selection: Selection, ok: bool) {
	path, path_err := selection_path(context.temp_allocator)
	if path_err != .None { return {}, false }
	defer delete(path, context.temp_allocator)
	body, read_err := os.read_entire_file(path, allocator)
	if read_err != nil { return {}, false }
	defer delete(body, allocator)
	if json.unmarshal(body, &selection, allocator = allocator) != nil {
		selection_destroy(&selection, allocator)
		return {}, false
	}
	if selection.provider == "" || selection.model == "" {
		selection_destroy(&selection, allocator)
		return {}, false
	}
	return selection, true
}

// selection_save publishes the selection through a temporary file in the same
// directory and renames it into place, so an interrupted write never leaves a
// half-written selection behind.
selection_save :: proc(selection: Selection) -> bool {
	path, path_err := selection_path(context.temp_allocator)
	if path_err != .None { return false }
	defer delete(path, context.temp_allocator)
	body, marshal_err := json.marshal(selection, allocator = context.temp_allocator)
	if marshal_err != nil { return false }
	defer delete(body, context.temp_allocator)
	temporary := fmt.aprintf("%s.%d.tmp", path, os.get_pid(), allocator = context.temp_allocator)
	defer delete(temporary, context.temp_allocator)
	if os.write_entire_file(temporary, body) != nil { return false }
	if os.rename(temporary, path) != nil {
		os.remove(temporary)
		return false
	}
	return true
}
