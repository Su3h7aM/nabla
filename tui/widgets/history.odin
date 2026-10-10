package widgets

import "core:strings"

// History is a list of entries a caller recalls oldest-last, readline style.
// back counts the steps taken from the newest end, and zero means not browsing.
// While browsing, draft holds the text that was current when the first step was
// taken. history_init pins the allocator of the entries and the draft, and
// history_destroy releases them.
History :: struct {
	entries: [dynamic]string,
	back:    int,
	draft:   string,
}

// history_init prepares an uninitialized history with allocator. It must not own entries or a draft.
history_init :: proc(history: ^History, allocator := context.allocator) {
	history.entries = make([dynamic]string, 0, 0, allocator)
}

history_destroy :: proc(history: ^History) {
	history_reset(history)
	for entry in history.entries {
		delete(entry, history.entries.allocator)
	}
	delete(history.entries)
	history^ = {}
}

// history_push appends a clone of entry and returns false on an allocation
// failure, leaving the history unchanged.
@(require_results)
history_push :: proc(history: ^History, entry: string) -> bool {
	cloned, err := strings.clone(entry, history.entries.allocator)
	if err != nil {
		return false
	}
	if _, append_err := append(&history.entries, cloned); append_err != nil {
		delete(cloned, history.entries.allocator)
		return false
	}
	return true
}

// history_previous steps to the next older entry and returns it. The first step
// saves current as the draft. It returns false when there is no older entry or
// the draft could not be saved. The result borrows the history and is valid
// until the next call that changes it.
@(require_results)
history_previous :: proc(history: ^History, current: string) -> (entry: string, ok: bool) {
	if history.back >= len(history.entries) {
		return "", false
	}
	if history.back == 0 {
		draft, err := strings.clone(current, history.entries.allocator)
		if err != nil {
			return "", false
		}
		delete(history.draft, history.entries.allocator)
		history.draft = draft
	}
	history.back += 1
	return history.entries[len(history.entries) - history.back], true
}

// history_next steps to the next newer entry and returns it; past the newest it
// returns the saved draft. It returns false when not browsing. The result borrows
// the history, like history_previous.
@(require_results)
history_next :: proc(history: ^History) -> (entry: string, ok: bool) {
	if history.back == 0 {
		return "", false
	}
	history.back -= 1
	if history.back == 0 {
		return history.draft, true
	}
	return history.entries[len(history.entries) - history.back], true
}

// history_reset ends browsing and drops the draft; the entries stay.
history_reset :: proc(history: ^History) {
	history.back = 0
	delete(history.draft, history.entries.allocator)
	history.draft = ""
}
