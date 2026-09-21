package agent

import "core:fmt"
import "core:strings"

import "nabla:agent/session"

// chat_effort_change_note is what a caller reports after changing the effort.
// The change reaches the provider: reasoning effort is rendered into the prompt
// prefix, so the prefix the provider has cached no longer matches and the next
// request reads it again from the start. An empty level means the default.
chat_effort_change_note :: proc(level: string) -> string {
	if level == "" { return "effort cleared to provider default; the prompt prefix is read again from the start" }
	return fmt.tprintf("effort set to %s for the next request; the prompt prefix is read again from the start", level)
}

chat_notice_effort :: proc(chat: ^Chat_Session, observer: Chat_Observer, provider_id, model_id: string) {
	if chat.effort != "" {
		_observer_message(observer, .Notice, fmt.tprintf("effort for %s / %s is %s", provider_id, model_id, chat.effort))
	} else {
		_observer_message(observer, .Notice, fmt.tprintf("effort for %s / %s is provider default", provider_id, model_id))
	}
	if len(chat.effort_levels) > 0 {
		levels, join_err := strings.join(chat.effort_levels[:], " ", context.temp_allocator)
		if join_err == nil {
			_observer_message(observer, .Notice, fmt.tprintf("allowed: %s", levels))
		}
	} else {
		_observer_message(observer, .Notice, "no effort levels configured for this model")
	}
}

// chat_notice_status reports what the session is and what it is doing: who it is,
// where it runs, how long it has run, which model and effort it uses, and the
// context and usage numbers the harness already measured.
chat_notice_status :: proc(chat: ^Chat_Session, observer: Chat_Observer, now_ms: i64) {
	header, header_err := session.session_load(chat.store, chat.id, context.temp_allocator)
	have_header := header_err == nil
	defer session.session_destroy(&header, context.temp_allocator)

	chat_status_line(observer, "session", string(chat.id))
	if have_header {
		title := header.title if header.title != "" else "(untitled)"
		chat_status_line(observer, "title", title)
	}
	chat_status_line(observer, "cwd", chat.workspace)
	if have_header {
		// The age counts from creation, which includes the time the harness was not
		// running, so it is called age rather than time spent working.
		age := chat_age_text(now_ms - header.created_at_ms)
		chat_status_line(observer, "age", fmt.tprintf("%s%s", age, " (turn active)" if chat.state != .Idle else ""))
	}
	chat_status_line(observer, "model", fmt.tprintf("%s / %s", chat.provider_id, chat.model_id))
	chat_status_line(observer, "effort", chat.effort if chat.effort != "" else "provider default")
	chat_status_line(observer, "tools", "shell" if chat.tools_enabled else "none")

	capacity := chat.capacity
	if capacity.window > 0 {
		chat_status_line(
			observer,
			"context",
			fmt.tprintf(
				"%d window, %d for estimator error, compaction at %d (%d for input)",
				capacity.window,
				capacity.margin,
				capacity.trigger,
				chat_capacity_input_ceiling(capacity),
			),
		)
	} else {
		chat_status_line(observer, "context", "not configured for this model")
	}

	estimate := "none"
	answer_room := "none"
	if chat.last_estimate > 0 {
		estimate = fmt.tprintf("%d", chat.last_estimate)
		output, _ := chat_request_output_bound(capacity, chat.last_estimate)
		answer_room = fmt.tprintf("%d", output)
	}
	measured := "none"
	if value, present := chat.last_input_measured.?; present { measured = fmt.tprintf("%d", value) }
	chat_status_line(observer, "usage", fmt.tprintf("estimate %s, measured %s, answer room %s", estimate, measured, answer_room))

	// Session usage is a query over finished requests, so this line also fails
	// when the store does: a status that hid a storage failure would be lying
	// about the rest of the session too.
	totals, totals_err := session.cache_totals(chat.store, chat.id)
	if totals_err != nil {
		local := totals_err
		chat_status_line(observer, "cache", fmt.tprintf("unavailable: %s", session.error_detail(&local)))
		return
	}
	rate_text := ""
	if rate, rate_measured := session.cache_hit_rate(totals); rate_measured {
		if share, coverage_measured := session.cache_coverage(totals); coverage_measured && share < 1 {
			rate_text = fmt.tprintf(" (%.1f%% hit over %.0f%% of input)", rate * 100, share * 100)
		} else {
			rate_text = fmt.tprintf(" (%.1f%% hit)", rate * 100)
		}
	}
	chat_status_line(
		observer,
		"cache",
		fmt.tprintf(
			"input %d in %d, read %d in %d, write %d in %d, output %d in %d%s",
			totals.input,
			totals.input_requests,
			totals.cache_read,
			totals.cache_read_requests,
			totals.cache_write,
			totals.cache_write_requests,
			totals.output,
			totals.output_requests,
			rate_text,
		),
	)
}

@(private)
chat_status_line :: proc(observer: Chat_Observer, label, value: string) {
	_observer_message(observer, .Notice, fmt.tprintf("%-10s %s", label, value))
}

// chat_age_text says how long ago something happened, in the largest two units
// that keep it readable.
@(private)
chat_age_text :: proc(elapsed_ms: i64) -> string {
	seconds := elapsed_ms / 1_000
	if seconds < 0 { return "unknown" }
	if seconds < 60 { return fmt.tprintf("%ds", seconds) }
	minutes := seconds / 60
	if minutes < 60 { return fmt.tprintf("%dm %ds", minutes, seconds % 60) }
	hours := minutes / 60
	if hours < 24 { return fmt.tprintf("%dh %dm", hours, minutes % 60) }
	return fmt.tprintf("%dd %dh", hours / 24, hours % 24)
}

// chat_handle_command runs one input line as a command. True means handled; the
// caller records anything else as a steering line. /quit during a turn quits after it
// settles, so shutdown never strands tool children.
chat_handle_command :: proc(chat: ^Chat_Session, observer: Chat_Observer, queue: ^Steer_Queue, text: string, quit: ^bool) -> bool {
	if text == "/quit" {
		if chat.state != .Idle { _observer_message(observer, .Notice, "quitting after this turn finishes") }
		if quit != nil { quit^ = true }
		return true
	}
	if text == "/effort" {
		chat_notice_effort(chat, observer, chat.provider_id, chat.model_id)
		return true
	}
	if text == "/status" {
		chat_notice_status(chat, observer, session.now_ms())
		return true
	}
	if text == "/drop" {
		dropped := steer_clear(queue)
		if dropped > 0 {
			_observer_message(observer, .Notice, fmt.tprintf("dropped %d queued line(s)", dropped))
		} else {
			_observer_message(observer, .Notice, "steering queue is empty")
		}
		return true
	}
	if strings.has_prefix(text, "/effort ") {
		level := strings.trim_space(text[len("/effort "):])
		if level == "default" {
			chat_session_set_effort(chat, "")
			_observer_message(observer, .Notice, chat_effort_change_note(""))
		} else if chat_session_set_effort(chat, level) {
			_observer_message(observer, .Notice, chat_effort_change_note(level))
		} else {
			_observer_message(observer, .Notice, fmt.tprintf("effort %s is not allowed for this model", level))
			chat_notice_effort(chat, observer, chat.provider_id, chat.model_id)
		}
		return true
	}
	return false
}
