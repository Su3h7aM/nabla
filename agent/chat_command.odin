package agent

import "core:fmt"

import "nabla:agent/journal"

// chat_effort_change_note is what a caller reports after changing the effort.
// An empty level means the default.
chat_effort_change_note :: proc(level: string) -> string {
	if level == "" { return "effort cleared to provider default; the prompt prefix is read again from the start" }
	return fmt.tprintf("effort set to %s for the next request; the prompt prefix is read again from the start", level)
}

// chat_notice_status reports what the session is and what it is doing: who it is,
// where it runs, how long it has run, which model and effort it uses, and the
// context and usage numbers the harness already measured.
chat_notice_status :: proc(chat: ^Chat_Session, observer: Chat_Observer, now_ms: i64) {
	summaries, list_error := journal.list_sessions(chat.store, {session = chat.session, limit = 1}, context.temp_allocator)
	defer journal.session_summaries_destroy(summaries, context.temp_allocator)
	summary: journal.Session_Summary
	have_summary := list_error == nil && len(summaries) > 0
	if have_summary { summary = summaries[0] }

	chat_status_line(observer, "session", chat_session_text(chat))
	if have_summary {
		title := summary.title if summary.title != "" else "(untitled)"
		chat_status_line(observer, "title", title)
	}
	chat_status_line(observer, "cwd", chat.workspace)
	if have_summary {
		// The age counts from creation, which includes the time the harness was not
		// running, so it is called age rather than time spent working.
		age := chat_age_text(now_ms - summary.created_ms)
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
	totals, totals_error := journal.usage_totals(chat.store, chat.session)
	if totals_error != nil {
		chat_status_line(observer, "cache", fmt.tprintf("unavailable: %s", journal.error_text(totals_error, context.temp_allocator)))
		return
	}
	rate_text := ""
	if rate, rate_measured := journal.cache_hit_rate(totals); rate_measured {
		if share, coverage_measured := journal.cache_coverage(totals); coverage_measured && share < 1 {
			rate_text = fmt.tprintf(" (%.1f%% hit over %.0f%% of input)", rate * 100, share * 100)
		} else {
			rate_text = fmt.tprintf(" (%.1f%% hit)", rate * 100)
		}
	}
	chat_status_line(
		observer,
		"cache",
		fmt.tprintf(
			"input %d, read %d, write %d, output %d over %d responses%s",
			totals.input,
			totals.cache_read,
			totals.cache_write,
			totals.output,
			totals.requests,
			rate_text,
		),
	)

	// A session whose responses were never priced says so rather than showing a
	// total that silently ignores them, and one priced only in part names how many
	// responses the total covers.
	cost := "unknown: the model has no price in the catalog"
	if totals.priced_requests > 0 {
		cost = fmt.tprintf("$%.4f", totals.cost)
		if totals.priced_requests < totals.requests {
			cost = fmt.tprintf("%s over %d of %d responses", cost, totals.priced_requests, totals.requests)
		}
	}
	chat_status_line(observer, "cost", cost)
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
