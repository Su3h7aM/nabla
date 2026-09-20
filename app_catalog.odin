#+build linux
package main

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
	allocator := app.run.alloc
	names := make([]string, len(app.catalog_sources), context.temp_allocator)
	defer delete(names, context.temp_allocator)
	for source, index in app.catalog_sources { names[index] = source.id }

	providers := agent.provider_models_refresh(app.catalog_sources, agent.provider_models_fetch, &app.run.stopping, allocator)
	defer agent.catalog_sources_destroy(&providers, allocator)
	cached_models_dev, _ := agent.models_dev_cached_sources(providers = names, allocator = allocator)
	catalog_publish(app, providers[:], cached_models_dev[:])
	agent.catalog_sources_destroy(&cached_models_dev, allocator)

	models_dev, models_dev_err := agent.models_dev_sources(agent.models_dev_fetch, &app.run.stopping, names, allocator)
	defer agent.catalog_sources_destroy(&models_dev, allocator)
	if models_dev_err == .None { catalog_publish(app, providers[:], models_dev[:]) }
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

catalog_refresh_stop :: proc(app: ^App) {
	if app.catalog_worker == nil { return }
	chan.close(&app.catalog_refresh)
	thread.join(app.catalog_worker)
	thread.destroy(app.catalog_worker)
	app.catalog_worker = nil
	chan.destroy(&app.catalog_refresh)
}

catalog_retired_destroy :: proc(app: ^App) {
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
