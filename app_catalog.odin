#+build linux
package main

import "core:mem"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"

import "nabla:agent"

CATALOG_REFRESH_CAPACITY :: 1
Catalog_Refresh_Chan :: chan.Chan(bool)

catalog_refresh_start :: proc(app: ^App, sources: []agent.Catalog_Provider_Source) -> bool {
	app.catalog_sources = sources
	app.retired_catalogs.allocator = app.run.alloc
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
	_ = chan.try_send(app.catalog_refresh, true)
}

catalog_refresh_worker :: proc(thread_handle: ^thread.Thread) {
	app := cast(^App)thread_handle.data
	context.logger = agent.log_logger(&app.setup.log_binding)
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
	names := make([]string, len(app.catalog_sources), context.temp_allocator)
	defer delete(names, context.temp_allocator)
	for source, index in app.catalog_sources { names[index] = source.id }

	// The three stages run in order here, on this thread, and only the complete
	// result is published: the user's configuration, then the provider listing,
	// then models.dev. The harness keeps running on the catalog published before
	// this refresh until it finishes.
	providers := agent.provider_models_refresh(app.catalog_sources, provider_fetch, &app.run.stopping, allocator)
	catalog_sources_merge(&app.provider_sources, &providers, allocator)

	models_dev, models_dev_err := agent.models_dev_sources(models_dev_fetch, &app.run.stopping, names, allocator)
	// A refresh that produced nothing leaves the enrichment already published in
	// place, so a failed request cannot remove models.dev data from the catalog.
	if models_dev_err == .None && len(models_dev) > 0 {
		catalog_sources_replace(&app.models_dev_sources, &models_dev, allocator)
	} else {
		agent.catalog_sources_destroy(&models_dev, allocator)
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
			append(current, source)
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
	if resolve_err != .None { return }

	sync.mutex_lock(&app.catalog_mu)
	append(&app.retired_catalogs, app.setup.catalog)
	app.setup.catalog = catalog
	sync.mutex_unlock(&app.catalog_mu)
	sync.atomic_add(&app.catalog_revision, 1)
}

catalog_selection_refresh_request :: proc(app: ^App) {
	if runtime_stopping(app) || app.run.work == {} { return }
	_ = chan.try_send(app.run.work, Work{kind = .Catalog})
}

// catalog_selection_sync reapplies catalog-derived fields to the selected model.
// A model can be selected from provider discovery before models.dev arrives, so
// replacing the catalog must also update the session's capacity, tools, routing,
// and reasoning controls. The worker owns those values; this procedure runs only
// on that worker, including at request boundaries inside a turn.
catalog_selection_sync :: proc(app: ^App) {
	revision := sync.atomic_load(&app.catalog_revision)
	if revision == app.run.catalog_applied_revision { return }
	if app.setup.provider_id == "" || app.setup.model_id == "" {
		app.run.catalog_applied_revision = revision
		return
	}
	provider_id := strings.clone(app.setup.provider_id, context.temp_allocator)
	model_id := strings.clone(app.setup.model_id, context.temp_allocator)
	if apply_selection(app, provider_id, model_id, "", false) {
		app.run.catalog_applied_revision = revision
	}
}

// catalog_refresh_stop ends the catalog thread and releases its channel. False means the
// thread did not retire, so neither the channel it reads nor the sources it read may be
// released.
catalog_refresh_stop :: proc(app: ^App, patience := SHUTDOWN_JOIN_PATIENCE) -> bool {
	if app.catalog_worker == nil { return true }
	chan.close(&app.catalog_refresh)
	if !join_retiring(app.catalog_worker, "nabla-catalog-refresh", patience) { return false }
	app.catalog_worker = nil
	chan.destroy(&app.catalog_refresh)
	return true
}

catalog_retired_destroy :: proc(app: ^App) {
	agent.catalog_sources_destroy(&app.provider_sources, app.run.alloc)
	agent.catalog_sources_destroy(&app.models_dev_sources, app.run.alloc)
	for &catalog in app.retired_catalogs { agent.catalog_destroy(&catalog) }
	delete(app.retired_catalogs)
	app.retired_catalogs = nil
}

catalog_changed :: proc(app: ^App) -> bool {
	revision := sync.atomic_load(&app.catalog_revision)
	if revision == app.catalog_seen { return false }
	app.catalog_seen = revision
	return true
}
