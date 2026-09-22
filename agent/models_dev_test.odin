#+test
package agent

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// models_dev_state_test points the XDG cache directory at a fresh temporary root
// for the duration of one test, so no test touches the real user cache and the
// environment is restored even when a check fails.
models_dev_state_test :: proc(t: ^testing.T, name: string, body: proc(t: ^testing.T, root: string)) {
	root := fmt.tprintf("/tmp/nabla-xdg-%s-%d", name, os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)

	previous, had_previous := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator)
	defer if had_previous {
		os.set_env("XDG_CACHE_HOME", previous)
	} else {
		os.unset_env("XDG_CACHE_HOME")
	}
	testing.expect(t, os.set_env("XDG_CACHE_HOME", root) == nil)

	body(t, root)
}

Models_Dev_Stub :: struct {
	body:  string,
	calls: int,
}

// Two documents that both parse, so a test can tell a replaced cache from a kept
// one. A body that does not parse is refused as a cache replacement, which is why
// these cannot be arbitrary text.
MODELS_DEV_STUB_OLD: string : `{"stub": {"id": "stub", "models": {"stub/old": {"id": "stub/old"}}}}`
MODELS_DEV_STUB_NEW: string : `{"stub": {"id": "stub", "models": {"stub/new": {"id": "stub/new"}}}}`

models_dev_stub_fetch :: proc(user_data: rawptr, allocator: mem.Allocator) -> ([]u8, bool) {
	stub := cast(^Models_Dev_Stub)user_data
	stub.calls += 1
	if stub.body == "" { return nil, false }
	bytes := make([]u8, len(stub.body), allocator)
	copy(bytes, stub.body)
	return bytes, true
}

@(test)
test_xdg_state_resolution_ignores_an_unusable_variable :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
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
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(t, "fresh", proc(t: ^testing.T, _: string) {
		path, path_err := models_dev_cache_path(context.temp_allocator)
		testing.expect_value(t, path_err, Models_Dev_Error.None)
		testing.expect(t, os.write_entire_file(path, transmute([]u8)MODELS_DEV_STUB_OLD) == nil)

		stub := Models_Dev_Stub {
			body = MODELS_DEV_STUB_NEW,
		}
		body, err := models_dev_catalog(models_dev_stub_fetch, &stub, {}, context.temp_allocator)
		testing.expect_value(t, err, Models_Dev_Error.None)
		testing.expect_value(t, string(body), MODELS_DEV_STUB_OLD)
		testing.expect_value(t, stub.calls, 0)
	})
}

@(test)
test_models_dev_refresh_failure_keeps_the_stale_cache :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(
		t,
		"stale",
		proc(t: ^testing.T, _: string) {
			path, path_err := models_dev_cache_path(context.temp_allocator)
			testing.expect_value(t, path_err, Models_Dev_Error.None)
			testing.expect(t, os.write_entire_file(path, transmute([]u8)MODELS_DEV_STUB_OLD) == nil)

			// A clock far enough ahead makes the entry stale, so the policy must
			// refresh; the refresh fails, and the cached copy survives.
			stale_at := time.time_add(time.now(), MODELS_DEV_FRESH * 2)
			stub := Models_Dev_Stub{}
			body, err := models_dev_catalog_at(stale_at, models_dev_stub_fetch, &stub, {}, context.temp_allocator)
			testing.expect_value(t, stub.calls, 1)
			testing.expect_value(t, err, Models_Dev_Error.None)
			testing.expect_value(t, string(body), MODELS_DEV_STUB_OLD)

			// The failed refresh did not disturb the file.
			still, still_err := os.read_entire_file(path, context.temp_allocator)
			testing.expect(t, still_err == nil)
			testing.expect_value(t, string(still), MODELS_DEV_STUB_OLD)
		},
	)
}

@(test)
test_models_dev_refresh_replaces_a_stale_cache :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(
		t,
		"replace",
		proc(t: ^testing.T, _: string) {
			path, path_err := models_dev_cache_path(context.temp_allocator)
			testing.expect_value(t, path_err, Models_Dev_Error.None)
			testing.expect(t, os.write_entire_file(path, transmute([]u8)MODELS_DEV_STUB_OLD) == nil)

			stale_at := time.time_add(time.now(), MODELS_DEV_FRESH * 2)
			stub := Models_Dev_Stub {
				body = MODELS_DEV_STUB_NEW,
			}
			body, err := models_dev_catalog_at(stale_at, models_dev_stub_fetch, &stub, {}, context.temp_allocator)
			testing.expect_value(t, stub.calls, 1)
			testing.expect_value(t, err, Models_Dev_Error.None)
			testing.expect_value(t, string(body), MODELS_DEV_STUB_NEW)

			// The refresh was persisted, so the next resolution reads it without a
			// request.
			stored, stored_err := os.read_entire_file(path, context.temp_allocator)
			testing.expect(t, stored_err == nil)
			testing.expect_value(t, string(stored), MODELS_DEV_STUB_NEW)
			second := Models_Dev_Stub {
				body = MODELS_DEV_STUB_OLD,
			}
			again, again_err := models_dev_catalog(models_dev_stub_fetch, &second, {}, context.temp_allocator)
			testing.expect_value(t, again_err, Models_Dev_Error.None)
			testing.expect_value(t, string(again), MODELS_DEV_STUB_NEW)
			testing.expect_value(t, second.calls, 0)
		},
	)
}

@(test)
test_models_dev_reports_an_unusable_cache_directory :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	// A cache directory that cannot be created is an explicit error, never a
	// silent fallback to a path under the home directory.
	root := fmt.tprintf("/tmp/nabla-blocked-%d", os.get_pid())
	os.remove_all(root)
	defer os.remove_all(root)
	_ = os.make_directory_all(root)
	blocking := fmt.tprintf("%s/blocking", root)
	testing.expect(t, os.write_entire_file(blocking, transmute([]u8)string("file")) == nil)

	previous, had_previous := os.lookup_env("XDG_CACHE_HOME", context.temp_allocator)
	defer if had_previous {
		os.set_env("XDG_CACHE_HOME", previous)
	} else {
		os.unset_env("XDG_CACHE_HOME")
	}
	testing.expect(t, os.set_env("XDG_CACHE_HOME", blocking) == nil)

	_, path_err := models_dev_cache_path(context.temp_allocator)
	testing.expect_value(t, path_err, Models_Dev_Error.Cache_Directory)

	stub := Models_Dev_Stub {
		body = MODELS_DEV_STUB_NEW,
	}
	body, err := models_dev_catalog(models_dev_stub_fetch, &stub, {}, context.temp_allocator)
	testing.expect_value(t, err, Models_Dev_Error.Cache_Directory)
	testing.expect(t, body == nil)
	// Nothing was fetched or written once the location was refused.
	testing.expect_value(t, stub.calls, 0)
}

@(test)
test_models_dev_replaces_a_fresh_cache_that_cannot_answer :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(
		t,
		"unanswered",
		proc(t: ^testing.T, _: string) {
			path, path_err := models_dev_cache_path(context.temp_allocator)
			testing.expect_value(t, path_err, Models_Dev_Error.None)
			// A document that parses and is within the freshness window, but names
			// none of the providers asked for. It cannot enrich a single model, so it
			// must not be served as the catalog.
			testing.expect(t, os.write_entire_file(path, transmute([]u8)MODELS_DEV_STUB_OLD) == nil)

			stub := Models_Dev_Stub {
				body = MODELS_DEV_FIXTURE,
			}
			sources, err := models_dev_sources(models_dev_stub_fetch, &stub, []string{"acme"}, context.allocator)
			testing.expect_value(t, err, Models_Dev_Error.None)
			defer catalog_sources_destroy(&sources)
			testing.expect_value(t, stub.calls, 1)
			testing.expect_value(t, len(sources), 1)
			testing.expect_value(t, sources[0].id, "acme")

			// The replacement is what the next resolution reads, so the document that
			// could not answer is not consulted again.
			second := Models_Dev_Stub {
				body = MODELS_DEV_STUB_NEW,
			}
			again, again_err := models_dev_sources(models_dev_stub_fetch, &second, []string{"acme"}, context.allocator)
			testing.expect_value(t, again_err, Models_Dev_Error.None)
			defer catalog_sources_destroy(&again)
			testing.expect_value(t, second.calls, 0)
			testing.expect_value(t, len(again), 1)
			stored, stored_err := os.read_entire_file(path, context.temp_allocator)
			testing.expect(t, stored_err == nil)
			testing.expect_value(t, string(stored), MODELS_DEV_FIXTURE)
		},
	)
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

@(test)
test_models_dev_unusable_document_never_replaces_a_valid_cache :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(
		t,
		"unusable",
		proc(t: ^testing.T, _: string) {
			path, path_err := models_dev_cache_path(context.temp_allocator)
			testing.expect_value(t, path_err, Models_Dev_Error.None)
			testing.expect(t, os.write_entire_file(path, transmute([]u8)MODELS_DEV_STUB_OLD) == nil)

			// A refresh that answers with something that cannot become source
			// records is a failed refresh: it must not displace a cache that can
			// still serve.
			stale_at := time.time_add(time.now(), MODELS_DEV_FRESH * 2)
			for unusable in ([]string{"not json", `{"stub": {"models": {}}}`, `[]`, ""}) {
				stub := Models_Dev_Stub {
					body = unusable,
				}
				body, err := models_dev_catalog_at(stale_at, models_dev_stub_fetch, &stub, {}, context.temp_allocator)
				testing.expect_value(t, stub.calls, 1)
				testing.expect_value(t, err, Models_Dev_Error.None)
				testing.expect_value(t, string(body), MODELS_DEV_STUB_OLD)

				stored, stored_err := os.read_entire_file(path, context.temp_allocator)
				testing.expect(t, stored_err == nil)
				testing.expect_value(t, string(stored), MODELS_DEV_STUB_OLD)
			}
		},
	)
}

@(test)
test_models_dev_unusable_document_without_a_cache_is_reported :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(
		t,
		"unusable-only",
		proc(t: ^testing.T, _: string) {
			stub := Models_Dev_Stub {
				body = "not json",
			}
			body, err := models_dev_catalog(models_dev_stub_fetch, &stub, {}, context.temp_allocator)
			testing.expect_value(t, err, Models_Dev_Error.Invalid_Data)
			testing.expect(t, body == nil)

			// Nothing was published, so a later usable refresh starts clean.
			path, path_err := models_dev_cache_path(context.temp_allocator)
			testing.expect_value(t, path_err, Models_Dev_Error.None)
			testing.expect(t, !os.exists(path))
		},
	)
}

@(test)
test_models_dev_sources_are_the_resolver_input :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(
		t,
		"sources",
		proc(t: ^testing.T, _: string) {
			stub := Models_Dev_Stub {
				body = MODELS_DEV_FIXTURE,
			}
			sources, err := models_dev_sources(models_dev_stub_fetch, &stub, {}, context.allocator)
			testing.expect_value(t, err, Models_Dev_Error.None)
			defer catalog_sources_destroy(&sources)
			testing.expect_value(t, stub.calls, 1)

			// The ingestion path hands the resolver exactly what it expects, so a
			// provider the user only named becomes usable through models.dev alone.
			resolved, resolve_err := resolve_catalog({}, {}, sources[:])
			testing.expect_value(t, resolve_err, Catalog_Error.None)
			defer catalog_destroy(&resolved)
			testing.expect_value(t, len(resolved.providers), 2)

			provider := resolved.providers[0]
			testing.expect_value(t, provider.api, "openai_chat_completions")
			testing.expect_value(t, provider.api_key, "${ACME_API_KEY}")
			thinking := catalog_test_find(resolved, "acme", "acme/thinker")
			testing.expect(t, thinking != nil)
			testing.expect_value(t, thinking.context_window, 200000)
			testing.expect_value(t, thinking.thinking.levels[2], "max")
			testing.expect_value(t, thinking.thinking.budget.max, 81920)
		},
	)
}

@(test)
test_models_dev_sources_reports_an_unusable_document :: proc(t: ^testing.T) {
	if !test_isolate_process(t, #procedure) { return }
	models_dev_state_test(
		t,
		"sources-broken",
		proc(t: ^testing.T, _: string) {
			// With no cache to serve, a document that cannot become source records is
			// a failed acquisition, and nothing is published from it.
			broken := Models_Dev_Stub {
				body = `{"stub": {"models": {}}}`,
			}
			sources, err := models_dev_sources(models_dev_stub_fetch, &broken, {}, context.allocator)
			testing.expect_value(t, err, Models_Dev_Error.Invalid_Data)
			testing.expect_value(t, len(sources), 0)
			catalog_sources_destroy(&sources)

			path, path_err := models_dev_cache_path(context.temp_allocator)
			testing.expect_value(t, path_err, Models_Dev_Error.None)
			testing.expect(t, !os.exists(path))

			// A served cache that cannot be parsed is reported by kind, so a damaged
			// document stays distinguishable from an unreachable service.
			testing.expect(t, os.write_entire_file(path, transmute([]u8)string(`{"stub": {"models": {}}}`)) == nil)
			cached, cached_err := models_dev_sources(models_dev_stub_fetch, &broken, {}, context.allocator)
			testing.expect_value(t, cached_err, Models_Dev_Error.Missing_Identity)
			testing.expect_value(t, len(cached), 0)
			catalog_sources_destroy(&cached)
		},
	)
}
