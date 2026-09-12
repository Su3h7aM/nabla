#+test
#+private file
package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Every selection test points XDG_STATE_HOME at a fresh temporary directory so
// the real state directory is never touched, and restores the variable when the
// test ends.

@(test)
test_selection_roundtrip :: proc(t: ^testing.T) {
	previous, found := os.lookup_env("XDG_STATE_HOME", context.temp_allocator)
	if found {
		defer os.set_env("XDG_STATE_HOME", previous)
	} else {
		defer os.unset_env("XDG_STATE_HOME")
	}
	os.set_env("XDG_STATE_HOME", fmt.aprintf("/tmp/nabla-selection-test-%d", os.get_pid(), allocator = context.temp_allocator))

	testing.expect(t, selection_save(Selection{provider = "proxy", model = "openai/gpt-5.6-luna", effort = "low"}))
	saved, ok := selection_load(context.temp_allocator)
	defer selection_destroy(&saved, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, saved.provider, "proxy")
	testing.expect_value(t, saved.model, "openai/gpt-5.6-luna")
	testing.expect_value(t, saved.effort, "low")

	// An empty effort is the provider default and round-trips as well.
	testing.expect(t, selection_save(Selection{provider = "proxy", model = "m"}))
	cleared, cleared_ok := selection_load(context.temp_allocator)
	defer selection_destroy(&cleared, context.temp_allocator)
	testing.expect(t, cleared_ok)
	testing.expect_value(t, cleared.effort, "")
}

@(test)
test_selection_missing_file_is_no_selection :: proc(t: ^testing.T) {
	previous, found := os.lookup_env("XDG_STATE_HOME", context.temp_allocator)
	if found {
		defer os.set_env("XDG_STATE_HOME", previous)
	} else {
		defer os.unset_env("XDG_STATE_HOME")
	}
	os.set_env("XDG_STATE_HOME", fmt.aprintf("/tmp/nabla-selection-test-%d", os.get_pid(), allocator = context.temp_allocator))

	_, ok := selection_load(context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_selection_malformed_file_is_no_selection :: proc(t: ^testing.T) {
	previous, found := os.lookup_env("XDG_STATE_HOME", context.temp_allocator)
	if found {
		defer os.set_env("XDG_STATE_HOME", previous)
	} else {
		defer os.unset_env("XDG_STATE_HOME")
	}
	os.set_env("XDG_STATE_HOME", fmt.aprintf("/tmp/nabla-selection-test-%d", os.get_pid(), allocator = context.temp_allocator))

	directory, directory_err := xdg_directory(.State, context.temp_allocator)
	testing.expect(t, directory_err == .None)
	testing.expect(t, xdg_directory_create(directory) == .None)
	path, join_err := strings.concatenate([]string{directory, "/selection.json"}, allocator = context.temp_allocator)
	testing.expect(t, join_err == nil)
	defer delete(path, context.temp_allocator)

	testing.expect(t, os.write_entire_file_from_string(path, "{not json") == nil)
	_, ok := selection_load(context.temp_allocator)
	testing.expect(t, !ok)

	// A structurally valid document without an identity is not a selection.
	testing.expect(t, os.write_entire_file_from_string(path, `{"provider":"","model":"m"}`) == nil)
	_, empty_ok := selection_load(context.temp_allocator)
	testing.expect(t, !empty_ok)
}
