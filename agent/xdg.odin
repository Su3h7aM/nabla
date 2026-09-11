package agent

import "core:os"
import "core:path/filepath"

// XDG Base Directory resolution.
//
// Every application-specific directory is resolved through the specification
// rather than placed directly under the home directory. The environment variable
// wins when it names an absolute path; when it is unset, empty, or relative the
// specification's documented default under the home directory applies, because a
// relative path in one of these variables is invalid and must be ignored.
//
// The application directory name is lowercase, so a path on a case-sensitive
// filesystem cannot collide with a differently cased application.

XDG_APP_NAME :: "nabla"

// The specification asks for an application directory that has to be created to
// be readable, writable, and searchable by its owner alone.
XDG_APP_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}

XDG_Kind :: enum {
	// User configuration.
	Config,
	// State that persists across restarts and is regenerable, such as a cache.
	State,
}

XDG_Error :: enum {
	None,
	// The environment variable is unusable and no home directory is available, so
	// the specification defines no location. Inventing one would violate it.
	Unresolved,
	// A directory is resolved but could not be created.
	Create,
}

xdg_variable :: proc(kind: XDG_Kind) -> (variable: string, fallback: string) {
	switch kind {
	case .Config:
		variable, fallback = "XDG_CONFIG_HOME", ".config"
	case .State:
		variable, fallback = "XDG_STATE_HOME", ".local/state"
	}
	return
}

// xdg_directory resolves this application's directory for one XDG category
// without touching the filesystem. The result is owned by the caller.
xdg_directory :: proc(kind: XDG_Kind, allocator := context.allocator) -> (string, XDG_Error) {
	variable, fallback := xdg_variable(kind)
	base: string
	if value, found := os.lookup_env(variable, context.temp_allocator); found && filepath.is_abs(value) {
		base = value
	} else {
		home, home_err := os.user_home_dir(context.temp_allocator)
		if home_err != nil || home == "" { return "", .Unresolved }
		joined, join_err := filepath.join([]string{home, fallback}, context.temp_allocator)
		if join_err != nil { return "", .Unresolved }
		base = joined
	}
	path, path_err := filepath.join([]string{base, XDG_APP_NAME}, allocator)
	if path_err != nil { return "", .Unresolved }
	return path, .None
}

// xdg_directory_create creates a resolved directory and its parents when it is
// missing. An existing directory keeps its permissions.
xdg_directory_create :: proc(path: string) -> XDG_Error {
	make_err := os.make_directory_all(path, XDG_APP_PERMISSIONS)
	if make_err != nil && make_err != .Exist { return .Create }
	return .None
}
