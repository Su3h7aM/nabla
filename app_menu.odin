#+build linux
package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"

import "nabla:agent"
import "nabla:agent/session"
import input "nabla:input"
import "nabla:tui/widgets"

menu_begin :: proc(app: ^App, title: string, choices: [dynamic]Choice, required: bool) {
	menu_destroy(&app.menu, app.run.alloc)
	app.menu = Menu {
		title    = strings.clone(title, app.run.alloc),
		choices  = choices,
		required = required,
	}
	app.menu_open = true
	app.completion_active = false
	widgets.input_clear(&app.input)
}

// menu_close drops the open menu and returns the prompt.
menu_close :: proc(app: ^App) {
	app.menu_open = false
	menu_destroy(&app.menu, app.run.alloc)
}

// menu_pick places the cursor on the first choice whose label names the current
// value, so a menu opens where the user already is.
menu_pick :: proc(app: ^App, label: string) {
	for choice, index in app.menu.choices {
		if choice.label == label { app.menu.cursor = index; return }
	}
}

// menu_open_model lists every usable configured model, with the provider as the
// second column. The catalog's own order follows the loader's table iteration,
// which varies between runs, so the list is sorted.
menu_open_model :: proc(app: ^App) {
	// The catalog is read-only after startup. The current selection is snapshot
	// state, so it is read under the lock the worker writes it with.
	sync.mutex_lock(&app.run.mu)
	current_provider := strings.clone(app.run.snap.status.provider_id, context.temp_allocator)
	current_model := strings.clone(app.run.snap.status.model_id, context.temp_allocator)
	sync.mutex_unlock(&app.run.mu)

	models := make([dynamic]Model_Choice, 0, 16, context.temp_allocator)
	defer delete(models)
	for &provider in app.setup.catalog.providers {
		if !provider_usable(&provider) || !provider_configured(app, provider.id) { continue }
		for &model in app.setup.catalog.models {
			if model.provider_id != provider.id { continue }
			append(&models, Model_Choice{provider_id = provider.id, model_id = model.id})
		}
	}
	slice.sort_by(models[:], model_choice_less)

	choices := make([dynamic]Choice, 0, len(models), app.run.alloc)
	for model in models {
		append(
			&choices,
			Choice {
				label = strings.clone(model.model_id, app.run.alloc),
				detail = strings.clone(model.provider_id, app.run.alloc),
				action = Model_Choice{provider_id = strings.clone(model.provider_id, app.run.alloc), model_id = strings.clone(model.model_id, app.run.alloc)},
			},
		)
	}
	menu_title := "select a model"
	if current_model != "" {
		menu_title = fmt.tprintf("models (current: %s / %s)", current_provider, current_model)
	}
	menu_begin(app, menu_title, choices, false)
	for choice, index in app.menu.choices {
		action := choice.action.(Model_Choice)
		if action.provider_id == current_provider && action.model_id == current_model {
			app.menu.cursor = index
			break
		}
	}
}

model_choice_less :: proc(a, b: Model_Choice) -> bool {
	order := strings.compare(a.provider_id, b.provider_id)
	if order == 0 { order = strings.compare(a.model_id, b.model_id) }
	return order < 0
}

// menu_open_effort lists the levels the model allows, plus the provider default.
// The levels are snapshot state, because only the worker owns the session, and
// their strings belong to the worker, so they are copied while the lock that
// protects them is held.
menu_open_effort :: proc(app: ^App) {
	sync.mutex_lock(&app.run.mu)
	current := strings.clone(app.run.snap.status.effort, context.temp_allocator)
	levels := make([dynamic]string, 0, len(app.run.snap.status.effort_levels) + 1, context.temp_allocator)
	append(&levels, "provider default")
	for level in app.run.snap.status.effort_levels { append(&levels, strings.clone(level, context.temp_allocator)) }
	sync.mutex_unlock(&app.run.mu)
	defer delete(levels)

	choices := make([dynamic]Choice, 0, len(levels), app.run.alloc)
	for level in levels {
		value := "" if level == "provider default" else level
		append(&choices, Choice{label = strings.clone(level, app.run.alloc), action = Effort_Choice{level = strings.clone(value, app.run.alloc)}})
	}
	menu_begin(app, "reasoning effort", choices, false)
	menu_pick(app, "provider default" if current == "" else current)
}

// menu_open_session lists the workspace's recent sessions from the snapshot, with
// a short id as the second column. Only the worker reads the store, so the list
// it built is what the menu shows.
menu_open_session :: proc(app: ^App) {
	choices := make([dynamic]Choice, 0, 8, app.run.alloc)
	active: session.Session_Id

	// The snapshot's rows and their strings belong to the worker, which can replace
	// them the moment the lock is released, so the labels are copied while the lock
	// that protects them is still held.
	sync.mutex_lock(&app.run.mu)
	active = session.Session_Id(strings.clone(string(app.run.snap.active_session), app.run.alloc))
	for &row in app.run.snap.sessions {
		label := row.title if row.title != "" else "(untitled)"
		append(
			&choices,
			Choice {
				label = strings.clone(label, app.run.alloc),
				detail = strings.clone(string(row.id)[:8], app.run.alloc),
				action = Session_Choice{id = session.Session_Id(strings.clone(string(row.id), app.run.alloc))},
			},
		)
	}
	sync.mutex_unlock(&app.run.mu)
	defer delete(string(active), app.run.alloc)

	menu_begin(app, "sessions in this workspace", choices, false)
	menu_pick_session(app, active)
}

// menu_pick_session opens the list on the running session, so the menu shows
// where the user already is.
@(private)
menu_pick_session :: proc(app: ^App, active: session.Session_Id) {
	if active == "" { return }
	for choice, index in app.menu.choices {
		action := choice.action.(Session_Choice)
		if action.id == active {
			app.menu.cursor = index
			return
		}
	}
}

// menu_page is how far one Page_Up/Page_Down moves in a menu.
menu_page :: proc(app: ^App) -> int {
	return max(app.rows - TUI_FOOTER_ROWS - 1, 1)
}

// menu_submit sends the choice under the cursor as work. The startup chooser
// stays open until its selection applies, because no model is selected yet; a
// menu opened from the prompt closes at once, and a selection that fails is
// reported as a transcript warning.
menu_submit :: proc(app: ^App) {
	if len(app.menu.choices) == 0 { return }
	cursor := min(app.menu.cursor, len(app.menu.choices) - 1)
	switch action in app.menu.choices[cursor].action {
	case Model_Choice:
		selection_request(app, action.provider_id, action.model_id)
	case Effort_Choice:
		enqueue(app, .Effort, action.level)
	case Session_Choice:
		enqueue(app, .Resume_Session, string(action.id))
	}
	if !app.menu.required { menu_close(app) }
}

// handle_menu_key drives every menu: arrows move, enter chooses, escape cancels,
// and the startup chooser quits instead because it cannot be dismissed.
handle_menu_key :: proc(app: ^App, key: input.Key_Event) {
	last := len(app.menu.choices) - 1
	#partial switch key.code {
	case .Up:
		app.menu.cursor = max(app.menu.cursor - 1, 0)
	case .Down:
		app.menu.cursor = min(app.menu.cursor + 1, max(last, 0))
	case .Home:
		app.menu.cursor = 0
	case .End:
		app.menu.cursor = max(last, 0)
	case .Page_Up:
		app.menu.cursor = max(app.menu.cursor - menu_page(app), 0)
	case .Page_Down:
		app.menu.cursor = min(app.menu.cursor + menu_page(app), max(last, 0))
	case .Enter:
		menu_submit(app)
	case .Escape:
		if app.menu.required {
			app.quit = true
		} else {
			menu_close(app)
		}
	case:
	}
}

// resolve_model_reference maps a /model argument onto a serving identity. The
// current provider is preferred, then any single provider serving that model
// id, then an explicit "provider/model" pair.
resolve_model_reference :: proc(app: ^App, text: string) -> (provider_id, model_id: string, ok: bool) {
	// The selection is worker state, so it is read through the lock that publishes
	// it rather than from the live session.
	current_provider := runtime_selection_provider(app)
	if _, found := agent.catalog_find_model(&app.setup.catalog, current_provider, text); found {
		return current_provider, text, true
	}
	matches := 0
	found_provider := ""
	for &provider in app.setup.catalog.providers {
		if _, found := agent.catalog_find_model(&app.setup.catalog, provider.id, text); found {
			matches += 1
			found_provider = provider.id
		}
	}
	if matches == 1 {
		return found_provider, text, true
	}
	if slash := strings.index_byte(text, '/'); slash > 0 {
		qualified_provider := text[:slash]
		qualified_model := text[slash + 1:]
		if _, found := agent.catalog_find_model(&app.setup.catalog, qualified_provider, qualified_model); found {
			return qualified_provider, qualified_model, true
		}
	}
	if matches > 1 {
		snap_append(app, .Notice, fmt.tprintf("several providers serve %s; use provider/model", text))
	} else {
		snap_append(app, .Notice, fmt.tprintf("no model %s", text))
	}
	return "", "", false
}

// refresh_status recomputes the status block from the session after a work
// item settles. Estimated input mirrors the agent's estimator over the
// active request span.
