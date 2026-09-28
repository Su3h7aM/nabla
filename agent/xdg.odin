package agent

import "base:runtime"
import "core:os"
import "core:path/filepath"

// XDG Base Directory resolution.
//
// The environment variable wins when it names an absolute path; an unset, empty, or
// relative one is invalid and the specification's default under the home directory
// applies instead. The application directory name is lowercase.

XDG_APP_NAME :: "nabla"

// The specification asks for an application directory that has to be created to
// be readable, writable, and searchable by its owner alone.
XDG_APP_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}

XDG_Kind :: enum {
	// User configuration.
	Config,
	// Regenerable data whose loss does not remove user state.
	Cache,
	// State that persists across restarts and is not configuration.
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
	case .Cache:
		variable, fallback = "XDG_CACHE_HOME", ".cache"
	case .State:
		variable, fallback = "XDG_STATE_HOME", ".local/state"
	}
	return
}

// xdg_directory resolves this application's directory for one XDG category
// without touching the filesystem. The result is owned by the caller.
@(require_results)
xdg_directory :: proc(kind: XDG_Kind, allocator := context.allocator) -> (string, XDG_Error) {
	// The environment lookup and the base it falls back to are scratch, but the
	// directory handed back may be the caller's temp memory itself, so a caller
	// that asks for temp keeps it: only its own arena is left alone.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
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
@(require_results)
xdg_directory_create :: proc(path: string) -> XDG_Error {
	make_err := os.make_directory_all(path, XDG_APP_PERMISSIONS)
	if make_err != nil && make_err != .Exist { return .Create }
	return .None
}
