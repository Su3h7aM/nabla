package agent

import "core:fmt"
import "core:strings"

import "nabla:agent/session"

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

	if chat.context_window > 0 {
		reserved := chat.max_output_tokens
		if reserved <= 0 { reserved = CHAT_DEFAULT_OUTPUT_RESERVE_TOKENS }
		usable := chat.context_window - reserved - CHAT_ADMISSION_MARGIN_TOKENS
		chat_status_line(
			observer,
			"context",
			fmt.tprintf("%d window, %d reserved, %d margin (%d usable)", chat.context_window, reserved, CHAT_ADMISSION_MARGIN_TOKENS, usable),
		)
	} else {
		chat_status_line(observer, "context", "not configured for this model")
	}

	estimate := "none"
	if chat.last_estimate > 0 { estimate = fmt.tprintf("%d", chat.last_estimate) }
	measured := "none"
	if chat.last_input_measured_present { measured = fmt.tprintf("%d", chat.last_input_measured) }
	chat_status_line(observer, "usage", fmt.tprintf("estimate %s, measured %s", estimate, measured))

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
	if rate, measured := session.cache_hit_rate(totals); measured {
		rate_text = fmt.tprintf(" (%.1f%% hit)", rate * 100)
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
// caller sends anything else as a turn or a steering line. /quit during a turn
// quits after it settles, so shutdown never strands tool children.
chat_handle_command :: proc(chat: ^Chat_Session, observer: Chat_Observer, queue: ^Steer_Queue, text, provider_id, model_id: string, quit: ^bool) -> bool {
	if text == "/quit" {
		if chat.state != .Idle { _observer_message(observer, .Notice, "quitting after this turn finishes") }
		if quit != nil { quit^ = true }
		return true
	}
	if text == "/effort" {
		chat_notice_effort(chat, observer, provider_id, model_id)
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
			_observer_message(observer, .Notice, "effort cleared to provider default")
		} else if chat_session_set_effort(chat, level) {
			_observer_message(observer, .Notice, fmt.tprintf("effort set to %s for the next request", level))
		} else {
			_observer_message(observer, .Notice, fmt.tprintf("effort %s is not allowed for this model", level))
			chat_notice_effort(chat, observer, provider_id, model_id)
		}
		return true
	}
	return false
}

// chat_drain_steering injects queued lines at a request boundary. Commands
// run immediately, so /effort still lands before the request is read from the
// store; anything else becomes a user entry for the next request. A quit
// discards what was never sent.
chat_drain_steering :: proc(chat: ^Chat_Session, observer: Chat_Observer, steer: ^Steer_Context) {
	for {
		line, ok := steer_pop(steer.queue)
		if !ok { break }
		if line == "/quit" {
			steer_line_free(steer.queue, line)
			if steer.quit != nil { steer.quit^ = true }
			dropped := steer_clear(steer.queue)
			if dropped > 0 {
				_observer_message(observer, .Notice, fmt.tprintf("quitting after this turn finishes; dropped %d queued line(s)", dropped))
			} else {
				_observer_message(observer, .Notice, "quitting after this turn finishes")
			}
			return
		}
		if !chat_handle_command(chat, observer, steer.queue, line, steer.provider_id, steer.model_id, steer.quit) {
			if line == "/compact" {
				chat_command_compact(chat, observer, steer.connection, steer.usages)
			} else if strings.has_prefix(line, "/") {
				// A slash is a command, never a message. A command this path does not
				// answer to is refused rather than sent to the model as steering text.
				_observer_message(observer, .Notice, fmt.tprintf("%s is not available while a turn is running", line))
			} else if !chat_session_steer(chat, line, session.now_ms()) {
				if chat.last_error != "" {
					_observer_message(observer, .Error, chat.last_error)
				} else {
					_observer_message(observer, .Warning, "steering arrived outside a request boundary; dropped")
				}
			} else {
				_observer_user_text(observer, line)
			}
		}
		steer_line_free(steer.queue, line)
		if steer.quit != nil && steer.quit^ { return }
	}
}
