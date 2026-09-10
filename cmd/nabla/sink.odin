package main

import "core:io"

import "nabla:agent"
import "nabla:ai"

// The plain-text front-end.
//
// agent reports what happened; this decides how to show it. It owns the two
// things the agent must not: the output stream and the streaming sanitizer
// state, which is what lets a control sequence split across two stream
// fragments be dropped even though the fragments arrive as separate callbacks.
//
// This is the interim front-end. A full-screen one replaces it by supplying a
// different Chat_Observer; the agent does not change.
Display_Sink :: struct {
	output: io.Writer,
	san:    Display_Sanitizer,
}

display_observer :: proc(sink: ^Display_Sink) -> agent.Chat_Observer {
	return {
		user_data = sink,
		assistant_begin = sink_assistant_begin,
		assistant_text = sink_assistant_text,
		assistant_flush = sink_assistant_flush,
		assistant_end = sink_assistant_end,
		user_text = sink_user_text,
		tool_result = sink_tool_result,
		message = sink_message,
		queue = sink_queue,
		usage = sink_usage,
	}
}

sink_assistant_begin :: proc(user_data: rawptr) {
	display_assistant_begin()
}

sink_assistant_text :: proc(user_data: rawptr, text: string) {
	sink := cast(^Display_Sink)user_data
	display_stream_text(sink.output, &sink.san, text)
}

sink_assistant_flush :: proc(user_data: rawptr) {
	sink := cast(^Display_Sink)user_data
	display_stream_flush(sink.output, &sink.san)
}

sink_assistant_end :: proc(user_data: rawptr) {
	sink := cast(^Display_Sink)user_data
	display_assistant_end(sink.output)
}

sink_user_text :: proc(user_data: rawptr, text: string) {
	display_user(text)
}

sink_tool_result :: proc(user_data: rawptr, name: string, result: ^agent.Tool_Result) {
	display_tool(name, tool_display_summary(result))
}

sink_message :: proc(user_data: rawptr, kind: agent.Chat_Message_Kind, text: string) {
	switch kind {
	case .Notice:
		display_notice(text)
	case .Warning:
		display_warning(text)
	case .Error:
		display_error(text)
	}
}

sink_queue :: proc(user_data: rawptr, event: agent.Chat_Queue_Event, depth: int) {
	switch event {
	case .Queued:
		display_queue_ack(depth)
	case .Full:
		display_queue_full()
	}
}

sink_usage :: proc(user_data: rawptr, operation: u64, usage: ai.Provider_Usage_Event) {
	display_usage(operation, usage)
}
