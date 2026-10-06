#+build linux
package main

import "core:mem"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"

import "nabla:agent"

CATALOG_REFRESH_CAPACITY :: 1
Catalog_Refresh_Chan :: chan.Chan(bool)

// CATALOG_REFRESH_COOLDOWN is how long the published catalog is left alone after a
// refresh was asked for. The count starts when the refresh is asked for and not when it
// finishes, so a burst of asks is one refresh.
CATALOG_REFRESH_COOLDOWN :: 10 * time.Minute

// MODELS_DEV_INGEST_COOLDOWN is how long a run keeps the models.dev sources it already
// read. It is not a fetch window: whether the document is fetched or read from the cache
// is the cache's own freshness decision.
MODELS_DEV_INGEST_COOLDOWN :: 24 * time.Hour

@(require_results)
catalog_refresh_start :: proc(app: ^App, sources: []agent.Catalog_Provider_Source) -> bool {
	app.catalog_sources = sources
	refresh, channel_err := chan.create_buffered(Catalog_Refresh_Chan, CATALOG_REFRESH_CAPACITY, app.run.alloc)
	if channel_err != nil { return false }
	app.catalog_refresh = refresh
	worker := thread.create(catalog_refresh_worker, name = "nabla-catalog-refresh")
	if worker == nil {
		chan.destroy(&app.catalog_refresh)
		return false
	}
	worker.data = app
	app.catalog_worker = worker
	thread.start(worker)
	catalog_refresh_request(app)
	return true
}

catalog_refresh_request :: proc(app: ^App) {
	if app.catalog_worker == nil { return }
	if !catalog_refresh_due(app) { return }
	if chan.try_send(app.catalog_refresh, true) {
		catalog_refresh_note(app)
	}
}

// catalog_refresh_note records that a refresh was asked for, which is what the cooldown
// counts from.
@(private)
catalog_refresh_note :: proc(app: ^App) {
	app.catalog_refresh_at = time.tick_now()
	app.catalog_refreshed = true
}

// catalog_refresh_due reports whether the catalog may be rebuilt again. A refresh that
// was never asked for is due, and one that was asked for within the cooldown is not.
@(require_results)
catalog_refresh_due :: proc(app: ^App) -> bool {
	if !app.catalog_refreshed { return true }
	return time.tick_since(app.catalog_refresh_at) >= CATALOG_REFRESH_COOLDOWN
}

// models_dev_read_due reports whether the run's models.dev sources are old enough to read
// again. A run that holds none is due, so a launch that found no cached document still
// reads one.
@(require_results)
models_dev_read_due :: proc(app: ^App) -> bool {
	if len(app.models_dev_sources) == 0 { return true }
	return time.tick_since(app.models_dev_read_at) >= MODELS_DEV_INGEST_COOLDOWN
}

catalog_refresh_worker :: proc(thread_handle: ^thread.Thread) {
	app := cast(^App)thread_handle.data
	defer sync.one_shot_event_signal(&app.catalog_worker_done)
	// The worker adopts the run's allocator, so what it allocates belongs to the run
	// rather than to the process default a fresh thread context starts with.
	context.allocator = app.setup.alloc
	for {
		_, open := chan.recv(app.catalog_refresh)
		if !open { return }
		catalog_refresh(app)
		free_all(context.temp_allocator)
	}
}

catalog_refresh :: proc(app: ^App) {
	catalog_refresh_with(app, agent.provider_models_fetch, agent.models_dev_fetch)
}

catalog_refresh_with :: proc(app: ^App, provider_fetch: agent.Provider_Models_Fetch, models_dev_fetch: agent.Models_Dev_Fetch) {
	allocator := app.run.alloc
	names, names_error := make([]string, len(app.catalog_sources), context.temp_allocator)
	if names_error != nil {
		snap_append(app, .Warning, "the catalog refresh could not run: out of memory")
		return
	}
	defer delete(names, context.temp_allocator)
	for source, index in app.catalog_sources { names[index] = source.id }

	// The three stages run in order here, on this thread, and only the complete
	// result is published: the user's configuration, then the provider listing,
	// then models.dev. The harness keeps running on the catalog published before
	// this refresh until it finishes.
	providers, providers_ok := agent.provider_models_refresh(app.catalog_sources, provider_fetch, &app.run.stopping, allocator)
	if !providers_ok {
		// The listings could not be held: the catalog already published stays.
		agent.catalog_sources_destroy(&providers, allocator)
		return
	}
	catalog_sources_merge(&app.provider_sources, &providers, allocator)

	// models.dev is read on its own, much longer cooldown: the records a re-read would
	// produce are the ones the run already holds, and parsing the cached document is
	// the largest thing one refresh does.
	if models_dev_read_due(app) {
		models_dev, models_dev_err := agent.models_dev_sources(models_dev_fetch, &app.run.stopping, names, allocator)
		// A refresh that produced nothing leaves the enrichment already published in
		// place, so a failed request cannot remove models.dev data from the catalog.
		if models_dev_err == .None && len(models_dev) > 0 {
			catalog_sources_replace(&app.models_dev_sources, &models_dev, allocator)
			app.models_dev_read_at = time.tick_now()
		} else {
			agent.catalog_sources_destroy(&models_dev, allocator)
		}
	}
	catalog_publish(app, app.provider_sources[:], app.models_dev_sources[:])
}

// catalog_sources_merge updates only providers for which refresh produced a
// valid listing. Missing providers retain their previous source, so one failed
// endpoint cannot remove models that a prior successful refresh published.
catalog_sources_merge :: proc(current, incoming: ^[dynamic]agent.Catalog_Provider_Source, allocator: mem.Allocator) {
	current.allocator = allocator
	for &source in incoming^ {
		replaced := false
		for &existing in current^ {
			if existing.id != source.id { continue }
			agent.catalog_provider_source_destroy(&existing, allocator)
			existing = source
			source = {}
			replaced = true
			break
		}
		if !replaced {
			if append(current, source) != 1 {
				agent.catalog_provider_source_destroy(&source, allocator)
				continue
			}
			source = {}
		}
	}
	agent.catalog_sources_destroy(incoming, allocator)
}

// models.dev is one complete document, so a successful parse replaces its
// snapshot as a unit. A failed parse never calls this and leaves the old source
// unchanged.
catalog_sources_replace :: proc(current, incoming: ^[dynamic]agent.Catalog_Provider_Source, allocator: mem.Allocator) {
	agent.catalog_sources_destroy(current, allocator)
	current^ = incoming^
	incoming^ = nil
}

catalog_publish :: proc(app: ^App, providers, models_dev: []agent.Catalog_Provider_Source) {
	catalog, resolve_err := agent.resolve_catalog(app.catalog_sources, providers, models_dev, app.run.alloc)
	if resolve_err != .None {
		// The catalog already published stays; the reason the replacement did not
		// take effect is the one thing the user can act on.
		if resolve_err == agent.Catalog_Error.Allocation {
			snap_append(app, .Warning, "the catalog refresh could not be applied: out of memory")
		} else {
			snap_append(app, .Warning, "the catalog refresh could not be applied")
		}
		return
	}

	sync.mutex_lock(&app.catalog_mu)
	replaced := app.setup.catalog
	app.setup.catalog = catalog
	sync.mutex_unlock(&app.catalog_mu)
	// The catalog this one replaces is released rather than kept: everything read out
	// of a catalog is copied while the lock is held, and the running connection owns
	// its endpoint. Nothing borrows a replaced catalog after this returns.
	agent.catalog_destroy(&replaced)
	sync.atomic_add(&app.catalog_revision, 1)
	run_wake(app)
}

catalog_selection_refresh_request :: proc(app: ^App) {
	if runtime_stopping(app) || app.run.work == {} { return }
	// A dropped wake is harmless: a full queue means the worker is already busy,
	// and it syncs the published catalog at its own next boundary.
	_ = work_send(app, Work{kind = .Catalog})
}

// catalog_selection_sync reapplies catalog-derived fields to the selected model, so a
// catalog replacement also updates the session's capacity, tools, routing, and reasoning
// controls. It runs only on the worker, including at request boundaries inside a turn.
catalog_selection_sync :: proc(app: ^App) {
	revision := sync.atomic_load(&app.catalog_revision)
	if revision == app.run.catalog_applied_revision { return }
	sync.mutex_lock(&app.run.mu)
	explicit_pending := app.run.pending.present
	sync.mutex_unlock(&app.run.mu)
	if explicit_pending || app.run.pending_target.present { return }
	if app.setup.provider_id == "" || app.setup.model_id == "" {
		app.run.catalog_applied_revision = revision
		return
	}
	provider_id, provider_error := strings.clone(app.setup.provider_id, context.temp_allocator)
	model_id, model_error := strings.clone(app.setup.model_id, context.temp_allocator)
	if provider_error != nil || model_error != nil {
		snap_append(app, .Warning, "the catalog change could not be applied: out of memory")
		return
	}
	if selection_apply_direct(app, provider_id, model_id, "", false) {
		app.run.catalog_applied_revision = revision
	}
}

// catalog_refresh_stop ends the catalog thread and releases its channel. False means the
// thread did not retire, so neither the channel it reads nor the sources it read may be
// released.
@(require_results)
catalog_refresh_stop :: proc(app: ^App, patience := SHUTDOWN_JOIN_PATIENCE) -> bool {
	if app.catalog_worker == nil { return true }
	chan.close(&app.catalog_refresh)
	if !join_retiring(app.catalog_worker, &app.catalog_worker_done, patience) { return false }
	app.catalog_worker = nil
	chan.destroy(&app.catalog_refresh)
	return true
}

// catalog_run_destroy releases catalog snapshots and connection strings after all
// workers that may borrow them have retired.
catalog_run_destroy :: proc(app: ^App) {
	agent.catalog_sources_destroy(&app.provider_sources, app.run.alloc)
	agent.catalog_sources_destroy(&app.models_dev_sources, app.run.alloc)
	delete(app.endpoint, app.run.alloc)
	app.endpoint = ""
	for value in app.retired_connection_strings { delete(value, app.run.alloc) }
	delete(app.retired_connection_strings)
	app.retired_connection_strings = nil
}

catalog_changed :: proc(app: ^App) -> bool {
	revision := sync.atomic_load(&app.catalog_revision)
	if revision == app.catalog_seen { return false }
	app.catalog_seen = revision
	return true
}
