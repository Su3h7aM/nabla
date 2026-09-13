package session

import "core:strings"

import "nabla:db"

// Selection is the serving identity a launch restores: the provider, model, and
// reasoning effort the user last chose.
//
// It is not conversation history. No session owns it, it has no sequence, and
// nothing about it needs a writer claim, so it is written by whichever process
// last changed it rather than by the process running a session. The database
// holds exactly one, and a launch that finds none is a launch with no previous
// choice, which is normal rather than a failure.
//
// Every string is owned by the allocator it was read with and released by
// selection_destroy.
Selection :: struct {
	provider: string,
	model:    string,
	effort:   string, // "" is the provider default
}

selection_destroy :: proc(selection: ^Selection, allocator := context.allocator) {
	if selection == nil { return }
	delete(selection.provider, allocator)
	delete(selection.model, allocator)
	delete(selection.effort, allocator)
	selection^ = {}
}

// selection_load reads the stored selection. It reports false when nothing has
// been chosen yet, which is not an error; a failure to read is.
selection_load :: proc(store: ^Store, allocator := context.allocator) -> (selection: Selection, found: bool, err: Error) {
	if !store.open { return {}, false, error_make(.Invalid_State, "the store is closed") }

	rows: db.Rows
	if query_err := db.query(&store.conn, &rows, SELECTION_SELECT); query_err != nil {
		return {}, false, storage_error("read the selection", query_err)
	}
	defer db.rows_close(&rows)

	values, has_row, next_err := db.rows_next(&rows)
	if next_err != nil { return {}, false, storage_error("read the selection", next_err) }
	if !has_row { return {}, false, nil }

	complete := false
	defer if !complete { selection_destroy(&selection, allocator) }
	provider, provider_err := db.as_string(values[0])
	if provider_err != nil { return {}, false, corrupt_error("read the selection provider", provider_err) }
	model, model_err := db.as_string(values[1])
	if model_err != nil { return {}, false, corrupt_error("read the selection model", model_err) }
	effort, effort_err := db.as_string(values[2])
	if effort_err != nil { return {}, false, corrupt_error("read the selection effort", effort_err) }

	selection = Selection {
		provider = strings.clone(provider, allocator),
		model    = strings.clone(model, allocator),
		effort   = strings.clone(effort, allocator),
	}
	complete = true
	return selection, true, nil
}

// selection_save records the selection, replacing whatever was stored.
selection_save :: proc(store: ^Store, selection: Selection) -> Error {
	require_writable(store) or_return
	if selection.provider == "" || selection.model == "" {
		return error_make(.Invalid_Argument, "a selection needs a provider and a model")
	}
	args := [?]db.Value{db.Value(selection.provider), db.Value(selection.model), db.Value(selection.effort)}
	if exec_err := db.exec(&store.conn, SELECTION_UPSERT, args[:]); exec_err != nil {
		return storage_error("record the selection", exec_err)
	}
	return nil
}

@(private)
SELECTION_SELECT :: `SELECT provider, model, effort FROM selection WHERE id = 1`

@(private)
SELECTION_UPSERT :: `INSERT INTO selection (id, provider, model, effort) VALUES (1, ?, ?, ?) ON CONFLICT (id) DO UPDATE SET provider = excluded.provider, model = excluded.model, effort = excluded.effort`
