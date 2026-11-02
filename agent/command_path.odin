package agent

import "core:os"
import "core:strings"

// command_on_path finds the program a bare command name refers to: the first regular file
// called command in an absolute PATH directory. A relative PATH entry is skipped, because it
// would depend on the working directory. path is temp-allocated, and found is false when no
// entry holds such a file.
@(require_results)
command_on_path :: proc(command: string) -> (path: string, found: bool) {
	search := os.get_env("PATH", context.temp_allocator)
	for directory in strings.split_iterator(&search, ":") {
		if !strings.has_prefix(directory, "/") { continue }
		candidate, join_error := strings.concatenate({directory, "/", command}, context.temp_allocator)
		if join_error != nil { return "", false }
		if command_is_file(candidate) { return candidate, true }
	}
	return "", false
}

// command_is_file reports whether path names something that is not a directory.
@(require_results)
command_is_file :: proc(path: string) -> bool {
	return os.exists(path) && !os.is_dir(path)
}
