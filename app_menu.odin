#+build linux
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

import "nabla:agent"
import "nabla:agent/journal"
import "nabla:fuzzy"
import input "nabla:input"
import "nabla:tui/widgets"

// menu_begin publishes a freshly built list. The caller owns choices until this
// takes them; false means the title could not be copied, and the list stays with
// the caller rather than being shown without a title.
@(require_results)
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

// menu_select selects the first choice whose action is action and marks it as
// the choice in use. It leaves the selection alone when none matches, so a menu
// opens where the user already is.
menu_select :: proc(app: ^App, action: Choice_Action) {
	for choice, index in app.menu.choices {
		if choice.action == action {
			app.menu.current = index
			widgets.list_select_index(&app.menu.list, len(app.menu.choices), index)
			return
		}
	}
	// The choice in use may be disabled, which the user bypasses, so fall back
	// to the first enabled row.
	menu_first_enabled(&app.menu)
}

// menu_visible_count is how many choices the menu shows: every choice while the filter is empty.
@(require_results)
menu_visible_count :: proc(menu: ^Menu) -> int {
	if len(menu.filter) == 0 { return len(menu.choices) }
	return len(menu.shown)
}

// menu_choice_index maps a visible row to its index in menu.choices.
@(require_results)
menu_choice_index :: proc(menu: ^Menu, visible: int) -> int {
	if len(menu.filter) == 0 { return visible }
	return menu.shown[visible]
}

// menu_filter_type appends a typed character to the filter and filters the choices again.
menu_filter_type :: proc(app: ^App, character: rune) {
	encoded, width := utf8.encode_rune(character)
	if _, append_error := append_elems(&app.menu.filter, ..encoded[:width]); append_error != nil {
		snap_append(app, .Warning, "the filter could not be extended")
		return
	}
	menu_filter_refresh(app)
}

// menu_filter_backspace removes the last character of the filter and filters the choices again.
menu_filter_backspace :: proc(app: ^App) {
	menu := &app.menu
	if len(menu.filter) == 0 { return }
	_, width := utf8.decode_last_rune_in_bytes(menu.filter[:])
	_ = resize(&menu.filter, len(menu.filter) - max(width, 1))
	menu_filter_refresh(app)
}

// menu_filter_refresh shows the choices the filter keeps, best match first, and selects the first of them. A
// failed allocation keeps the list it had and reports it.
menu_filter_refresh :: proc(app: ^App) {
	menu := &app.menu
	shown, ok := menu_filter_matches(app)
	if !ok {
		snap_append(app, .Warning, "the filter could not be applied")
		return
	}
	delete(menu.shown)
	menu.shown = shown
	menu.list.offset = 0
	menu_first_enabled(menu)
}

// menu_next_enabled returns the next visible row forward of direction that is
// not disabled, or the selected row if none exists. Navigation skips disabled
// rows because a disabled model cannot be selected.
@(private, require_results)
menu_next_enabled :: proc(menu: ^Menu, direction: int) -> int {
	count := menu_visible_count(menu)
	if count <= 0 { return -1 }
	if menu.list.selected < 0 { return 0 }
	for step in 0 ..< count {
		index := menu.list.selected + direction * (step + 1)
		if index < 0 || index >= count { break }
		if !menu.choices[menu_choice_index(menu, index)].disabled { return index }
	}
	return menu.list.selected
}

// menu_select_enabled moves the selection forward by direction, skipping
// disabled rows. It keeps it where it is when only disabled rows could be reached.
menu_select_enabled :: proc(menu: ^Menu, direction: int) {
	if next := menu_next_enabled(menu, direction); next >= 0 {
		widgets.list_select_index(&menu.list, menu_visible_count(menu), next)
	}
}

// menu_select_any moves the selection by one visible row, disabled rows included.
// Shift with an arrow uses it, so a disabled model can be reached and reactivated.
menu_select_any :: proc(menu: ^Menu, direction: int) {
	count := menu_visible_count(menu)
	if count <= 0 { return }
	next := 0 if menu.list.selected < 0 else clamp(menu.list.selected + direction, 0, count - 1)
	widgets.list_select_index(&menu.list, count, next)
}

// menu_first_enabled selects the first enabled visible row, or nothing when none
// is enabled.
menu_first_enabled :: proc(menu: ^Menu) {
	for index in 0 ..< menu_visible_count(menu) {
		if !menu.choices[menu_choice_index(menu, index)].disabled {
			widgets.list_select_index(&menu.list, menu_visible_count(menu), index)
			return
		}
	}
	widgets.list_select_index(&menu.list, 0, 0)
}

// menu_last_enabled selects the last enabled visible row, or nothing when none
// is enabled.
menu_last_enabled :: proc(menu: ^Menu) {
	count := menu_visible_count(menu)
	for index := count - 1; index >= 0; index -= 1 {
		if !menu.choices[menu_choice_index(menu, index)].disabled {
			widgets.list_select_index(&menu.list, count, index)
			return
		}
	}
	widgets.list_select_index(&menu.list, 0, 0)
}

// menu_page_enabled moves the selection by page rows, landing only on an enabled
// row. With nothing selected it selects the first enabled row going forward and
// the last enabled row going back.
menu_page_enabled :: proc(menu: ^Menu, page: int) {
	count := menu_visible_count(menu)
	if count <= 0 || page == 0 { return }
	step := 1 if page > 0 else -1
	if menu.list.selected < 0 {
		if page > 0 { menu_first_enabled(menu) } else { menu_last_enabled(menu) }
		return
	}
	target := clamp(menu.list.selected + page, 0, count - 1)
	if !menu.choices[menu_choice_index(menu, target)].disabled {
		widgets.list_select_index(&menu.list, count, target)
		return
	}
	for index in 0 ..< count {
		candidate := target + step * (index + 1)
		if candidate < 0 || candidate >= count { break }
		if !menu.choices[menu_choice_index(menu, candidate)].disabled {
			widgets.list_select_index(&menu.list, count, candidate)
			return
		}
	}
	widgets.list_select_index(&menu.list, count, menu.list.selected)
}

// menu_staged_disabled returns the staged flag for a model, and the catalog flag
// when it has none staged.
@(private, require_results)
menu_staged_disabled :: proc(app: ^App, provider_id, model_id: string, catalog_disabled: bool) -> bool {
	for staged in app.menu.staged {
		if staged.provider_id == provider_id && staged.model_id == model_id { return staged.disabled }
	}
	return catalog_disabled
}

// menu_staged_clear releases every staged disabled flag the menu holds.
menu_staged_clear :: proc(app: ^App) {
	for staged in app.menu.staged {
		delete(staged.provider_id, app.run.alloc)
		delete(staged.model_id, app.run.alloc)
	}
	clear(&app.menu.staged)
}

// menu_toggle_disabled flips the staged flag of the model under the cursor. It
// only changes memory: nothing is written until menu_save_staged runs.
menu_toggle_disabled :: proc(app: ^App) {
	selected := app.menu.list.selected
	if selected < 0 || selected >= menu_visible_count(&app.menu) { return }
	choice_index := menu_choice_index(&app.menu, selected)
	action, ok := app.menu.choices[choice_index].action.(Model_Choice)
	if !ok { return }
	catalog_disabled := app.menu.choices[choice_index].disabled
	for &staged in app.menu.staged {
		if staged.provider_id == action.provider_id && staged.model_id == action.model_id {
			staged.disabled = !staged.disabled
			app.menu.choices[choice_index].disabled = staged.disabled
			return
		}
	}
	provider_id, provider_error := strings.clone(action.provider_id, app.run.alloc)
	model_id, model_id_error := strings.clone(action.model_id, app.run.alloc)
	if provider_error != nil || model_id_error != nil {
		delete(provider_id, app.run.alloc)
		delete(model_id, app.run.alloc)
		snap_append(app, .Warning, "the staged change could not be recorded: out of memory")
		return
	}
	if _, append_error := append(&app.menu.staged, Model_Disable_Staged{provider_id = provider_id, model_id = model_id, disabled = !catalog_disabled});
	   append_error != nil {
		delete(provider_id, app.run.alloc)
		delete(model_id, app.run.alloc)
		snap_append(app, .Warning, "the staged change could not be recorded: out of memory")
		return
	}
	app.menu.choices[choice_index].disabled = !catalog_disabled
}

// menu_save_staged writes every staged disabled flag to the configuration in one
// atomic temp-file write, then reloads and republishes the catalog so the menu
// and every other consumer see the new flags. On any failure the configuration
// is left unchanged and the staged list is kept.
menu_save_staged :: proc(app: ^App) {
	if len(app.menu.staged) == 0 { return }
	// The file is re-read on save: the in-memory sources are borrowed and the
	// interactive edits target the file the user last wrote.
	source, read_err := os.read_entire_file(app.config_path, context.temp_allocator)
	if read_err != nil {
		snap_append(app, .Warning, "the configuration could not be read for the save")
		return
	}
	edited := string(source)
	for staged in app.menu.staged {
		next, changed, edit_err := agent.config_model_set_disabled(edited, staged.provider_id, staged.model_id, staged.disabled, app.run.alloc)
		if edit_err != .None {
			snap_append(app, .Warning, "the staged change could not be applied to the configuration")
			if changed { delete(next, app.run.alloc) }
			return
		}
		if changed {
			if edited != string(source) { delete(edited, app.run.alloc) }
			edited = next
		}
	}
	if edited == string(source) {
		menu_staged_clear(app)
		return
	}
	temp_path := fmt.tprintf("%s.tmp", app.config_path)
	if write_err := os.write_entire_file(temp_path, transmute([]u8)edited); write_err != nil {
		snap_append(app, .Warning, "the configuration could not be written")
		return
	}
	if rename_err := os.rename(temp_path, app.config_path); rename_err != nil {
		snap_append(app, .Warning, "the configuration could not be saved")
		return
	}
	delete(edited, app.run.alloc)
	menu_staged_clear(app)
	// The refresh worker reloads the file before it publishes, so the saved
	// flags reach the catalog without any reload here.
	_ = catalog_refresh_force(app)
	snap_append(app, .Notice, "disabled flags saved to the configuration")
}

// menu_rebuild_open_model rebuilds the open model list after the catalog changed. The typed filter and the
// required flag survive the rebuild, and the filter is applied to the new list.
menu_rebuild_open_model :: proc(app: ^App) {
	filter := app.menu.filter
	required := app.menu.required
	app.menu.filter = {}
	menu_rebuild_model(app, true)
	app.menu.required = required
	app.menu.filter = filter
	menu_filter_refresh(app)
}

// menu_refresh_models asks the catalog thread to refresh now, ignoring the cooldown. The published catalog
// rebuilds the open list through menu_rebuild_open_model.
menu_refresh_models :: proc(app: ^App) {
	if catalog_refresh_force(app) {
		snap_append(app, .Notice, "refreshing the model catalog")
		return
	}
	snap_append(app, .Warning, "the model catalog could not be queued for refresh")
}

// menu_filter_matches returns the indices of the choices the filter matches, best first, owned by the run's
// allocator. Each choice is matched by its label and provider, so a typo still finds it and an uppercase letter
// makes the match case-sensitive. An empty filter returns nil, because every choice shows.
@(private, require_results)
menu_filter_matches :: proc(app: ^App) -> ([dynamic]int, bool) {
	menu := &app.menu
	if len(menu.filter) == 0 { return nil, true }
	labels, labels_error := make([]string, len(menu.choices), context.temp_allocator)
	if labels_error != nil { return nil, false }
	for choice, index in menu.choices {
		label, label_error := strings.concatenate({choice.label, " ", choice.detail}, context.temp_allocator)
		if label_error != nil { return nil, false }
		labels[index] = label
	}
	pattern, pattern_error := fuzzy.pattern_compile(string(menu.filter[:]), allocator = context.temp_allocator)
	if pattern_error != nil { return nil, false }
	defer fuzzy.pattern_destroy(&pattern, context.temp_allocator)
	hits, hits_error := fuzzy.match_list(&pattern, labels, len(labels), context.temp_allocator)
	if hits_error != nil { return nil, false }
	shown, shown_error := make([dynamic]int, 0, len(hits), app.run.alloc)
	if shown_error != nil { return nil, false }
	for hit in hits {
		if _, append_error := append(&shown, hit.index); append_error != nil {
			delete(shown)
			return nil, false
		}
	}
	return shown, true
}

// menu_open_model lists every usable configured model, with the provider as the
// second column. The catalog's own order follows the loader's table iteration,
// which varies between runs, so the list is sorted.
menu_open_model :: proc(app: ^App) {
	catalog_refresh_request(app)
	menu_rebuild_model(app, false)
}

// menu_rebuild_model rebuilds the model list from the catalog. The staged
// disabled flags are reapplied to the choices and survive the rebuild; the
// closed-menu variant clears them.
menu_rebuild_model :: proc(app: ^App, keep_staged: bool) {
	if !keep_staged { menu_staged_clear(app) }
	// Catalog publication has its own lock. The current selection is snapshot
	// state, so it is read under the lock the worker writes it with.
	current_provider, current_model := "", ""
	provider_failed := false
	if sync.mutex_guard(&app.run.mu) {
		cloned_provider, provider_error := strings.clone(app.run.snap.status.provider_id, context.temp_allocator)
		cloned_model, model_error := strings.clone(app.run.snap.status.model_id, context.temp_allocator)
		current_provider = cloned_provider
		current_model = cloned_model
		provider_failed = provider_error != nil || model_error != nil
	}
	if provider_failed {
		// The list is still usable; only the cursor cannot be placed on the
		// selection that could not be copied.
		snap_append(app, .Warning, "the current model could not be read for its menu")
	}

	disabled_by_request, disabled_error := make([dynamic]Model_Disable_Staged, 0, len(app.menu.staged), context.temp_allocator)
	if disabled_error != nil {
		snap_append(app, .Warning, "the model menu could not be built")
		return
	}
	defer for staged in disabled_by_request {
		delete(staged.provider_id, context.temp_allocator)
		delete(staged.model_id, context.temp_allocator)
	}
	defer delete(disabled_by_request)
	for staged in app.menu.staged {
		provider_id, provider_error := strings.clone(staged.provider_id, context.temp_allocator)
		model_id, model_id_error := strings.clone(staged.model_id, context.temp_allocator)
		if provider_error != nil || model_id_error != nil {
			delete(provider_id, context.temp_allocator)
			delete(model_id, context.temp_allocator)
			snap_append(app, .Warning, "the model menu could not be built")
			return
		}
		if _, append_error := append(&disabled_by_request, Model_Disable_Staged{provider_id = provider_id, model_id = model_id, disabled = staged.disabled});
		   append_error != nil {
			delete(provider_id, context.temp_allocator)
			delete(model_id, context.temp_allocator)
			snap_append(app, .Warning, "the model menu could not be built")
			return
		}
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
	if sync.mutex_guard(&app.catalog_mu) {
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
	}
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
		// The catalog flag is read in the same locked pass that copied the
		// names, so it comes from the catalog only.
		catalog_disabled := false
		if sync.mutex_guard(&app.catalog_mu) {
			for catalog in app.setup.catalog.models {
				if catalog.provider_id == model.provider_id && catalog.id == model.model_id {
					catalog_disabled = catalog.disabled
					break
				}
			}
		}
		disabled := menu_staged_disabled(app, model.provider_id, model.model_id, catalog_disabled)
		choice, choice_ok := model_choice_make(app, model, disabled)
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
	menu_select(app, Model_Choice{provider_id = current_provider, model_id = current_model})
}

// model_choice_make builds one model menu line, every string owned by the run's
// allocator. False means one of the copies failed, and what was copied is released.
@(private, require_results)
model_choice_make :: proc(app: ^App, model: Model_Choice, disabled := false) -> (Choice, bool) {
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
	return Choice{label = label, detail = detail, disabled = disabled, action = Model_Choice{provider_id = provider_id, model_id = model_id}}, true
}

@(require_results)
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
	if sync.mutex_guard(&app.run.mu) {
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
	}
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
	menu_select(app, Effort_Choice{level = current})
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
	if sync.mutex_guard(&app.run.mu) {
		active = app.run.snap.active_session
		for &row in app.run.snap.sessions {
			label := row.title if row.title != "" else "(untitled)"
			hex_text: [journal.SESSION_ID_HEX_LENGTH]u8
			hex := journal.session_id_to_hex(row.id, hex_text[:])
			row_label, label_error := strings.concatenate({"  " if row.child else "", label}, app.run.alloc)
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
	}
	if failed {
		snap_append(app, .Warning, "the session menu could not be built")
		return
	}

	if !menu_begin(app, .Session, "sessions in this workspace", choices, false) { return }
	taken = true
	menu_select(app, Session_Choice{id = active})
}

// SESSION_ID_SHORT_LENGTH is how many hex digits of an id a listing shows.
SESSION_ID_SHORT_LENGTH :: 8

// menu_submit sends the choice under the cursor as work. The startup chooser
// stays open until its selection applies, because no model is selected yet; a
// menu opened from the prompt closes at once, and a selection that fails is
// reported as a transcript warning.
menu_submit :: proc(app: ^App) {
	selected := app.menu.list.selected
	if selected < 0 || selected >= menu_visible_count(&app.menu) { return }
	choice := app.menu.choices[menu_choice_index(&app.menu, selected)]
	// A disabled row is reached only to be reactivated, so Enter does nothing on it.
	if choice.disabled { return }
	switch action in choice.action {
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

// menu_escape is what escape and ctrl+c both do in a menu: close it, or quit when it is
// the startup chooser, which cannot be dismissed.
menu_escape :: proc(app: ^App) {
	if app.menu.required {
		app.quit = true
		return
	}
	menu_staged_clear(app)
	menu_close(app)
}

// handle_menu_key drives every menu: arrows move, enter chooses, escape and ctrl+c cancel, and typing
// filters the choices.
handle_menu_key :: proc(app: ^App, key: input.Key_Event) {
	page := max(app.menu.rows, 1)
	#partial switch key.code {
	case .Up:
		if .Shift in key.modifiers { menu_select_any(&app.menu, -1) } else { menu_select_enabled(&app.menu, -1) }
	case .Down:
		if .Shift in key.modifiers { menu_select_any(&app.menu, 1) } else { menu_select_enabled(&app.menu, 1) }
	case .Home:
		menu_first_enabled(&app.menu)
	case .End:
		menu_last_enabled(&app.menu)
	case .Page_Up:
		menu_page_enabled(&app.menu, -page)
	case .Page_Down:
		menu_page_enabled(&app.menu, page)
	case .Enter:
		menu_submit(app)
	case .Backspace:
		menu_filter_backspace(app)
	case .Character:
		switch {
		case .Control in key.modifiers:
			switch key.character {
			case 'c':
				menu_escape(app)
			case 'r':
				if app.menu.kind == .Model { menu_refresh_models(app) }
			case 'd':
				if app.menu.kind == .Model { menu_toggle_disabled(app) }
			case 's':
				if app.menu.kind == .Model { menu_save_staged(app) }
			}
		case .Alt in key.modifiers:
		case:
			menu_filter_type(app, key.character)
		}
	case .Escape:
		menu_escape(app)
	case:
	}
}

// resolve_model_reference maps a /model argument onto a serving identity. The
// current provider is preferred, then any single provider serving that model
// id, then an explicit "provider/model" pair.
@(require_results)
resolve_model_reference :: proc(app: ^App, text: string) -> (provider_id, model_id: string, ok: bool) {
	sync.mutex_guard(&app.catalog_mu)
	// The selection is worker state, so it is read through the lock that publishes
	// it rather than from the live session.
	current_provider := runtime_selection_provider(app)
	if index, found := agent.catalog_find_model(&app.setup.catalog, current_provider, text); found && !app.setup.catalog.models[index].disabled {
		return current_provider, text, true
	}
	matches := 0
	found_provider := ""
	for &provider in app.setup.catalog.providers {
		// Kept for the menu, so selection skips it.
		if index, found := agent.catalog_find_model(&app.setup.catalog, provider.id, text); found && !app.setup.catalog.models[index].disabled {
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
		if index, found := agent.catalog_find_model(&app.setup.catalog, qualified_provider, qualified_model);
		   found && !app.setup.catalog.models[index].disabled {
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
