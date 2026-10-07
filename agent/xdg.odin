package agent

import "base:runtime"
import "core:os"
import "core:path/filepath"

// XDG Base Directory resolution. The environment variable wins when it names an absolute
// path; otherwise the specification's default under the home directory applies. The runtime
// directory has no default and is unresolved then.

XDG_APP_NAME :: "nabla"

// XDG_APP_PERMISSIONS keep a created application directory private to its owner.
XDG_APP_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}

// SESSION_LOCK_DIRECTORY_NAME is the directory, inside the runtime directory, that
// holds one claim lock file per session.
SESSION_LOCK_DIRECTORY_NAME :: "locks"

XDG_Kind :: enum {
	// User configuration.
	Config,
	// Data the user may delete at any time without breaking anything.
	Cache,
	// History and logs that persist across restarts and are not configuration.
	State,
	// Small files for synchronization that do not outlive the user's login.
	Runtime,
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
	case .Runtime:
		variable, fallback = "XDG_RUNTIME_DIR", ""
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
		if fallback == "" { return "", .Unresolved }
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

// session_lock_directory resolves the directory that holds session claim locks:
// locks under the runtime directory, so they vanish at logout and reboot. Without
// a runtime directory it is locks under the state directory, which the
// specification's replacement rule allows because it supports file locking and is
// private to the user; replaced reports that, so the caller can warn. It does not
// touch the filesystem. The result is owned by the caller.
@(require_results)
session_lock_directory :: proc(allocator := context.allocator) -> (path: string, replaced: bool, error: XDG_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)
	base, base_error := xdg_directory(.Runtime, context.temp_allocator)
	if base_error != .None {
		replaced = true
		base, base_error = xdg_directory(.State, context.temp_allocator)
		if base_error != .None { return "", replaced, base_error }
	}
	joined, join_error := filepath.join({base, SESSION_LOCK_DIRECTORY_NAME}, allocator)
	if join_error != nil { return "", replaced, .Unresolved }
	return joined, replaced, .None
}

// xdg_directory_create creates a resolved directory and its parents when it is
// missing. An existing directory keeps its permissions.
@(require_results)
xdg_directory_create :: proc(path: string) -> XDG_Error {
	make_err := os.make_directory_all(path, XDG_APP_PERMISSIONS)
	if make_err != nil && make_err != .Exist { return .Create }
	return .None
}
