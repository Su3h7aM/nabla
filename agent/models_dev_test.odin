package agent

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// models_dev_state_test points the XDG state directory at a fresh temporary root
// for the duration of one test, so no test touches the real user state and the
// environment is restored even when a check fails.
models_dev_state_test :: proc(t: ^testing.T, name: string, body: proc(t: ^testing.T, root: string)) {
	root := fmt.tprintf("/tmp/nabla-xdg-%s-%d", name, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)

	previous, had_previous := os.lookup_env("XDG_STATE_HOME", context.temp_allocator)
	defer if had_previous {
		os.set_env("XDG_STATE_HOME", previous)
	} else {
		os.unset_env("XDG_STATE_HOME")
	}
	testing.expect(t, os.set_env("XDG_STATE_HOME", root) == nil)

	body(t, root)
}

Models_Dev_Stub :: struct {
	body:  string,
	calls: int,
}

models_dev_stub_fetch :: proc(user_data: rawptr, allocator: mem.Allocator) -> ([]u8, bool) {
	stub := cast(^Models_Dev_Stub)user_data
	stub.calls += 1
	if stub.body == "" { return nil, false }
	bytes := make([]u8, len(stub.body), allocator)
	copy(bytes, stub.body)
	return bytes, true
}

@(test)
test_models_dev_cache_path_is_lowercase_xdg_state :: proc(t: ^testing.T) {
	models_dev_state_test(
		t,
		"path",
		proc(t: ^testing.T, root: string) {
			path, err := models_dev_cache_path(context.temp_allocator)
			testing.expect_value(t, err, Models_Dev_Error.None)
			testing.expect_value(t, path, fmt.tprintf("%s/nabla/%s", root, MODELS_DEV_CACHE_FILE))

			// The application directory is created so a caller can read and write the
			// cache, its name is the lowercase application name, and the state variable
			// is where it came from.
			testing.expect(t, os.is_directory(fmt.tprintf("%s/nabla", root)))
			testing.expect_value(t, filepath.base(filepath.dir(path)), XDG_APP_NAME)
		},
	)
}

@(test)
test_xdg_state_resolution_ignores_an_unusable_variable :: proc(t: ^testing.T) {
	// A relative or empty value is invalid and ignored, and the specification's
	// default under the home directory then applies -- which is the state
	// directory, never an application directory directly under the home directory.
	previous, had_previous := os.lookup_env("XDG_STATE_HOME", context.temp_allocator)
	defer if had_previous {
		os.set_env("XDG_STATE_HOME", previous)
	} else {
		os.unset_env("XDG_STATE_HOME")
	}

	home, home_err := os.user_home_dir(context.temp_allocator)
	expected := fmt.tprintf("%s/.local/state/%s", home, XDG_APP_NAME)
	for value in ([]string{"", "relative/state", "./state"}) {
		testing.expect(t, os.set_env("XDG_STATE_HOME", value) == nil)
		directory, err := xdg_directory(.State, context.temp_allocator)
		testing.expect_value(t, err, XDG_Error.None)
		if home_err == nil && home != "" {
			testing.expectf(t, directory == expected, "XDG_STATE_HOME=%q resolved to %s", value, directory)
		}
		testing.expectf(
			t,
			!strings.has_prefix(directory, fmt.tprintf("%s/%s", home, XDG_APP_NAME)),
			"%s is an application directory under the home directory",
			directory,
		)
	}

	testing.expect(t, os.unset_env("XDG_STATE_HOME"))
	directory, unset_err := xdg_directory(.State, context.temp_allocator)
	testing.expect_value(t, unset_err, XDG_Error.None)
	if home_err == nil && home != "" { testing.expect_value(t, directory, expected) }

	// An absolute value wins over the home directory entirely.
	testing.expect(t, os.set_env("XDG_STATE_HOME", "/tmp/absolute-state") == nil)
	absolute, absolute_err := xdg_directory(.State, context.temp_allocator)
	testing.expect_value(t, absolute_err, XDG_Error.None)
	testing.expect_value(t, absolute, "/tmp/absolute-state/nabla")
}

@(test)
test_models_dev_cache_freshness_window :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/nabla-fresh-%d", os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	_ = os.make_directory_all(root)
	path := fmt.tprintf("%s/catalog.json", root)

	// Missing.
	testing.expect(t, !models_dev_cache_fresh(path, time.now()))
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("{}")) == nil)
	now := time.now()
	testing.expect(t, models_dev_cache_fresh(path, now))

	// Beyond the window.
	testing.expect(t, !models_dev_cache_fresh(path, time.time_add(now, MODELS_DEV_FRESH)))
	testing.expect(t, models_dev_cache_fresh(path, time.time_add(now, MODELS_DEV_FRESH - time.Second)))

	// A timestamp ahead of the clock is stale rather than fresh forever.
	testing.expect(t, !models_dev_cache_fresh(path, time.time_add(now, -time.Hour)))
}

@(test)
test_models_dev_cache_write_is_atomic :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/nabla-write-%d", os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	_ = os.make_directory_all(root)
	path := fmt.tprintf("%s/catalog.json", root)

	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("old")) == nil)
	testing.expect(t, models_dev_cache_write(path, transmute([]u8)string("new")))
	body, read_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(body), "new")

	// A successful write leaves no temporary file behind, so nothing partial is
	// ever visible beside the cache.
	testing.expect(t, !os.exists(fmt.tprintf("%s.%d.tmp", path, os.get_pid())))

	// A write that cannot happen publishes nothing at all.
	missing := fmt.tprintf("%s/absent/catalog.json", root)
	testing.expect(t, !models_dev_cache_write(missing, transmute([]u8)string("new")))
	testing.expect(t, !os.exists(missing))

	// A path whose parent is a file fails at the temporary write, leaving the
	// original cache readable.
	blocking := fmt.tprintf("%s/blocking", root)
	testing.expect(t, os.write_entire_file(blocking, transmute([]u8)string("file")) == nil)
	testing.expect(t, !models_dev_cache_write(fmt.tprintf("%s/catalog.json", blocking), transmute([]u8)string("new")))
	still, still_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, still_err == nil)
	testing.expect_value(t, string(still), "new")
}

@(test)
test_models_dev_uses_a_fresh_cache_without_fetching :: proc(t: ^testing.T) {
	models_dev_state_test(t, "fresh", proc(t: ^testing.T, _: string) {
		path, path_err := models_dev_cache_path(context.temp_allocator)
		testing.expect_value(t, path_err, Models_Dev_Error.None)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)string("cached")) == nil)

		stub := Models_Dev_Stub {
			body = "fetched",
		}
		body, err := models_dev_catalog(models_dev_stub_fetch, &stub, context.temp_allocator)
		testing.expect_value(t, err, Models_Dev_Error.None)
		testing.expect_value(t, string(body), "cached")
		testing.expect_value(t, stub.calls, 0)
	})
}

@(test)
test_models_dev_refresh_failure_keeps_the_stale_cache :: proc(t: ^testing.T) {
	models_dev_state_test(
		t,
		"stale",
		proc(t: ^testing.T, _: string) {
			path, path_err := models_dev_cache_path(context.temp_allocator)
			testing.expect_value(t, path_err, Models_Dev_Error.None)
			testing.expect(t, os.write_entire_file(path, transmute([]u8)string("cached")) == nil)

			// A clock far enough ahead makes the entry stale, so the policy must
			// refresh; the refresh fails, and the cached copy survives.
			stale_at := time.time_add(time.now(), MODELS_DEV_FRESH * 2)
			stub := Models_Dev_Stub{}
			body, err := models_dev_catalog_at(stale_at, models_dev_stub_fetch, &stub, context.temp_allocator)
			testing.expect_value(t, stub.calls, 1)
			testing.expect_value(t, err, Models_Dev_Error.None)
			testing.expect_value(t, string(body), "cached")

			// The failed refresh did not disturb the file.
			still, still_err := os.read_entire_file(path, context.temp_allocator)
			testing.expect(t, still_err == nil)
			testing.expect_value(t, string(still), "cached")
		},
	)
}

@(test)
test_models_dev_refresh_replaces_a_stale_cache :: proc(t: ^testing.T) {
	models_dev_state_test(
		t,
		"replace",
		proc(t: ^testing.T, _: string) {
			path, path_err := models_dev_cache_path(context.temp_allocator)
			testing.expect_value(t, path_err, Models_Dev_Error.None)
			testing.expect(t, os.write_entire_file(path, transmute([]u8)string("cached")) == nil)

			stale_at := time.time_add(time.now(), MODELS_DEV_FRESH * 2)
			stub := Models_Dev_Stub {
				body = "fetched",
			}
			body, err := models_dev_catalog_at(stale_at, models_dev_stub_fetch, &stub, context.temp_allocator)
			testing.expect_value(t, stub.calls, 1)
			testing.expect_value(t, err, Models_Dev_Error.None)
			testing.expect_value(t, string(body), "fetched")

			// The refresh was persisted, so the next resolution reads it without a
			// request.
			stored, stored_err := os.read_entire_file(path, context.temp_allocator)
			testing.expect(t, stored_err == nil)
			testing.expect_value(t, string(stored), "fetched")
			second := Models_Dev_Stub {
				body = "fetched-again",
			}
			again, again_err := models_dev_catalog(models_dev_stub_fetch, &second, context.temp_allocator)
			testing.expect_value(t, again_err, Models_Dev_Error.None)
			testing.expect_value(t, string(again), "fetched")
			testing.expect_value(t, second.calls, 0)
		},
	)
}

@(test)
test_models_dev_reports_an_unusable_state_directory :: proc(t: ^testing.T) {
	// A state directory that cannot be created is an explicit error, never a
	// silent fallback to a path under the home directory.
	root := fmt.tprintf("/tmp/nabla-blocked-%d", os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	_ = os.make_directory_all(root)
	blocking := fmt.tprintf("%s/blocking", root)
	testing.expect(t, os.write_entire_file(blocking, transmute([]u8)string("file")) == nil)

	previous, had_previous := os.lookup_env("XDG_STATE_HOME", context.temp_allocator)
	defer if had_previous {
		os.set_env("XDG_STATE_HOME", previous)
	} else {
		os.unset_env("XDG_STATE_HOME")
	}
	testing.expect(t, os.set_env("XDG_STATE_HOME", blocking) == nil)

	_, path_err := models_dev_cache_path(context.temp_allocator)
	testing.expect_value(t, path_err, Models_Dev_Error.State_Directory)

	stub := Models_Dev_Stub {
		body = "fetched",
	}
	body, err := models_dev_catalog(models_dev_stub_fetch, &stub, context.temp_allocator)
	testing.expect_value(t, err, Models_Dev_Error.State_Directory)
	testing.expect(t, body == nil)
	// Nothing was fetched or written once the location was refused.
	testing.expect_value(t, stub.calls, 0)
}

@(test)
test_models_dev_cache_read_refuses_missing_and_empty_files :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/nabla-read-%d", os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	_ = os.make_directory_all(root)
	path := fmt.tprintf("%s/catalog.json", root)

	_, missing_ok := models_dev_cache_read(path, context.temp_allocator)
	testing.expect(t, !missing_ok)

	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("{}")) == nil)
	body, ok := models_dev_cache_read(path, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, string(body), "{}")
	defer delete(body, context.temp_allocator)

	// An empty file is not a catalog.
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("")) == nil)
	_, empty_ok := models_dev_cache_read(path, context.temp_allocator)
	testing.expect(t, !empty_ok)
}
