#+build linux
package main

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"

import "nabla:agent"
import "nabla:agent/journal"
import input "nabla:input"

// menu_begin publishes a freshly built list. The caller owns choices until this
// takes them; false means the title could not be copied, and the list stays with
// the caller rather than being shown without a title.
menu_begin :: proc(app: ^App, kind: Menu_Kind, title: string, choices: [dynamic]Choice, required: bool) -> bool {
	cloned_title, clone_error := strings.clone(title, app.run.alloc)
	if clone_error != nil {
		snap_append(app, .Warning, "the menu could not be built: out of memory")
		return false
	}
	menu_destroy(&app.menu, app.run.alloc)
	app.menu = Menu {
		kind     = kind,
		title    = cloned_title,
		choices  = choices,
		required = required,
	}
	app.menu_open = true
	app.completion_active = false
	prompt_clear(app)
	return true
}

// menu_choices_destroy releases a choice list the menu did not take.
menu_choices_destroy :: proc(choices: ^[dynamic]Choice, allocator: mem.Allocator) {
	for &choice in choices^ { choice_destroy(&choice, allocator) }
	delete(choices^)
	choices^ = nil
}

menu_close :: proc(app: ^App) {
	app.menu_open = false
	menu_destroy(&app.menu, app.run.alloc)
}

// menu_pick places the cursor on the first choice whose label names the current
// value, so a menu opens where the user already is.
menu_pick :: proc(app: ^App, label: string) {
	for choice, index in app.menu.choices {
		if choice.label == label {
			app.menu.cursor = index
			return
		}
	}
}

// menu_open_model lists every usable configured model, with the provider as the
// second column. The catalog's own order follows the loader's table iteration,
// which varies between runs, so the list is sorted.
menu_open_model :: proc(app: ^App) {
	catalog_refresh_request(app)
	menu_rebuild_model(app)
}

menu_rebuild_model :: proc(app: ^App) {
	// Catalog publication has its own lock. The current selection is snapshot
	// state, so it is read under the lock the worker writes it with.
	sync.mutex_lock(&app.run.mu)
	current_provider, provider_error := strings.clone(app.run.snap.status.provider_id, context.temp_allocator)
	current_model, model_error := strings.clone(app.run.snap.status.model_id, context.temp_allocator)
	sync.mutex_unlock(&app.run.mu)
	if provider_error != nil || model_error != nil {
		// The list is still usable; only the cursor cannot be placed on the
		// selection that could not be copied.
		snap_append(app, .Warning, "the current model could not be read for its menu")
	}

	models, models_error := make([dynamic]Model_Choice, 0, 16, context.temp_allocator)
	if models_error != nil {
		snap_append(app, .Warning, "the model menu could not be built")
		return
	}
	defer delete(models)
	defer for model in models {
		delete(model.provider_id, context.temp_allocator)
		delete(model.model_id, context.temp_allocator)
	}
	failed := false
	sync.mutex_lock(&app.catalog_mu)
	for &provider in app.setup.catalog.providers {
		if !agent.provider_usable(&provider) || !provider_configured(app, provider.id) { continue }
		for &model in app.setup.catalog.models {
			if model.provider_id != provider.id { continue }
			// The names are copied while the lock is held: a publication releases the
			// catalog they were read from, and the list below outlives this scope.
			provider_id, provider_id_error := strings.clone(provider.id, context.temp_allocator)
			model_id, model_id_error := strings.clone(model.id, context.temp_allocator)
			if provider_id_error != nil || model_id_error != nil {
				delete(provider_id, context.temp_allocator)
				delete(model_id, context.temp_allocator)
				failed = true
				break
			}
			if _, append_error := append(&models, Model_Choice{provider_id = provider_id, model_id = model_id}); append_error != nil {
				delete(provider_id, context.temp_allocator)
				delete(model_id, context.temp_allocator)
				failed = true
				break
			}
		}
		if failed { break }
	}
	sync.mutex_unlock(&app.catalog_mu)
	if failed {
		snap_append(app, .Warning, "the model menu could not be built")
		return
	}
	slice.sort_by(models[:], model_choice_less)

	choices, choices_error := make([dynamic]Choice, 0, len(models), app.run.alloc)
	if choices_error != nil {
		snap_append(app, .Warning, "the model menu could not be built")
		return
	}
	taken := false
	defer if !taken { menu_choices_destroy(&choices, app.run.alloc) }
	for model in models {
		choice, choice_ok := model_choice_make(app, model)
		if !choice_ok {
			snap_append(app, .Warning, "the model menu could not be built")
			return
		}
		if _, append_error := append(&choices, choice); append_error != nil {
			choice_destroy(&choice, app.run.alloc)
			snap_append(app, .Warning, "the model menu could not be built")
			return
		}
	}
	menu_title := "select a model"
	if current_model != "" {
		menu_title = fmt.tprintf("models (current: %s / %s)", current_provider, current_model)
	}
	if !menu_begin(app, .Model, menu_title, choices, false) { return }
	taken = true
	for choice, index in app.menu.choices {
		action := choice.action.(Model_Choice)
		if action.provider_id == current_provider && action.model_id == current_model {
			app.menu.cursor = index
			break
		}
	}
}

// model_choice_make builds one model menu line, every string owned by the run's
// allocator. False means one of the copies failed, and what was copied is released.
@(private)
model_choice_make :: proc(app: ^App, model: Model_Choice) -> (Choice, bool) {
	label, label_error := strings.clone(model.model_id, app.run.alloc)
	if label_error != nil { return {}, false }
	detail, detail_error := strings.clone(model.provider_id, app.run.alloc)
	if detail_error != nil {
		delete(label, app.run.alloc)
		return {}, false
	}
	provider_id, provider_error := strings.clone(model.provider_id, app.run.alloc)
	if provider_error != nil {
		delete(label, app.run.alloc)
		delete(detail, app.run.alloc)
		return {}, false
	}
	model_id, model_id_error := strings.clone(model.model_id, app.run.alloc)
	if model_id_error != nil {
		delete(label, app.run.alloc)
		delete(detail, app.run.alloc)
		delete(provider_id, app.run.alloc)
		return {}, false
	}
	return Choice{label = label, detail = detail, action = Model_Choice{provider_id = provider_id, model_id = model_id}}, true
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
	levels, levels_error := make([dynamic]string, 0, 1, context.temp_allocator)
	if levels_error != nil {
		snap_append(app, .Warning, "the effort menu could not be built")
		return
	}
	defer delete(levels)
	current := ""
	failed := false
	sync.mutex_lock(&app.run.mu)
	cloned_current, current_error := strings.clone(app.run.snap.status.effort, context.temp_allocator)
	if current_error != nil {
		failed = true
	}
	current = cloned_current
	if _, append_error := append(&levels, "provider default"); append_error != nil {
		failed = true
	}
	if !failed {
		for level in app.run.snap.status.effort_levels {
			cloned, clone_error := strings.clone(level, context.temp_allocator)
			if clone_error != nil {
				failed = true
				break
			}
			if _, append_error := append(&levels, cloned); append_error != nil {
				delete(cloned, context.temp_allocator)
				failed = true
				break
			}
		}
	}
	sync.mutex_unlock(&app.run.mu)
	if failed {
		snap_append(app, .Warning, "the effort menu could not be built")
		return
	}

	choices, choices_error := make([dynamic]Choice, 0, len(levels), app.run.alloc)
	if choices_error != nil {
		snap_append(app, .Warning, "the effort menu could not be built")
		return
	}
	taken := false
	defer if !taken { menu_choices_destroy(&choices, app.run.alloc) }
	for level in levels {
		value := "" if level == "provider default" else level
		label, label_error := strings.clone(level, app.run.alloc)
		action_level, action_error := strings.clone(value, app.run.alloc)
		if label_error != nil || action_error != nil {
			delete(label, app.run.alloc)
			delete(action_level, app.run.alloc)
			snap_append(app, .Warning, "the effort menu could not be built")
			return
		}
		choice := Choice {
			label = label,
			action = Effort_Choice{level = action_level},
		}
		if _, append_error := append(&choices, choice); append_error != nil {
			choice_destroy(&choice, app.run.alloc)
			snap_append(app, .Warning, "the effort menu could not be built")
			return
		}
	}
	if !menu_begin(app, .Effort, "reasoning effort", choices, false) { return }
	taken = true
	menu_pick(app, "provider default" if current == "" else current)
}

// menu_open_session lists the workspace's sessions, newest activity first, from
// the snapshot, with a short id as the second column. Only the worker reads the
// store, so the list it built is what the menu shows, and the list scrolls.
menu_open_session :: proc(app: ^App) {
	choices, choices_error := make([dynamic]Choice, 0, 8, app.run.alloc)
	if choices_error != nil {
		snap_append(app, .Warning, "the session menu could not be built")
		return
	}
	taken := false
	defer if !taken { menu_choices_destroy(&choices, app.run.alloc) }
	active: journal.Session_Id

	// The snapshot's rows and their strings belong to the worker, which can replace
	// them the moment the lock is released, so the labels are copied while the lock
	// that protects them is still held.
	failed := false
	sync.mutex_lock(&app.run.mu)
	active = app.run.snap.active_session
	for &row in app.run.snap.sessions {
		label := row.title if row.title != "" else "(untitled)"
		hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
		hex := journal.session_id_to_hex(row.id, hex_text[:])
		row_label, label_error := strings.clone(label, app.run.alloc)
		row_detail, detail_error := strings.clone(hex[:SESSION_ID_SHORT_LENGTH], app.run.alloc)
		if label_error != nil || detail_error != nil {
			delete(row_label, app.run.alloc)
			delete(row_detail, app.run.alloc)
			failed = true
			break
		}
		choice := Choice {
			label = row_label,
			detail = row_detail,
			action = Session_Choice{id = row.id},
		}
		if _, append_error := append(&choices, choice); append_error != nil {
			choice_destroy(&choice, app.run.alloc)
			failed = true
			break
		}
	}
	sync.mutex_unlock(&app.run.mu)
	if failed {
		snap_append(app, .Warning, "the session menu could not be built")
		return
	}

	if !menu_begin(app, .Session, "sessions in this workspace", choices, false) { return }
	taken = true
	menu_pick_session(app, active)
}

// SESSION_ID_SHORT_LENGTH is how many hex digits of an id a listing shows.
SESSION_ID_SHORT_LENGTH :: 8

// menu_pick_session opens the list on the running session, so the menu shows
// where the user already is.
@(private)
menu_pick_session :: proc(app: ^App, active: journal.Session_Id) {
	if active == {} { return }
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
		hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
		enqueue(app, .Resume_Session, journal.session_id_to_hex(action.id, hex_text[:]))
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
	sync.mutex_lock(&app.catalog_mu)
	defer sync.mutex_unlock(&app.catalog_mu)
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
