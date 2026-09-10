package agent

import "nabla:ai"

// Chat_Observer is where the agent hands user-visible information to whoever
// owns presentation.
//
// The agent owns no formatting, no output stream, no color, and no terminal. It
// reports what happened, in order, and the front-end decides how to show it.
// Every callback is optional -- a nil field is a no-op -- so a front-end that
// only renders assistant text leaves the rest unset.
//
// The observer is borrowed, not retained: the caller keeps it alive for as long
// as the turn it was passed to can still report. `assistant_text` may be called
// any number of times with arbitrarily split fragments, always in the order the
// model produced them.
Chat_Observer :: struct {
	user_data:       rawptr,
	assistant_begin: proc(user_data: rawptr),
	assistant_text:  proc(user_data: rawptr, text: string),
	assistant_flush: proc(user_data: rawptr),
	assistant_end:   proc(user_data: rawptr),
	user_text:       proc(user_data: rawptr, text: string),
	tool_result:     proc(user_data: rawptr, name: string, result: ^Tool_Result),
	message:         proc(user_data: rawptr, kind: Chat_Message_Kind, text: string),
	queue:           proc(user_data: rawptr, event: Chat_Queue_Event, depth: int),
	usage:           proc(user_data: rawptr, operation: u64, usage: ai.Provider_Usage_Event),
}

// Chat_Message_Kind classifies a diagnostic line. The agent decides how serious
// it is; the front-end decides where it goes and what it looks like.
Chat_Message_Kind :: enum {
	Notice,
	Warning,
	Error,
}

// Chat_Queue_Event reports steering-queue activity. The front-end owns the
// input affordance the depth describes.
Chat_Queue_Event :: enum {
	Queued,
	Full,
}

@(private)
_observer_assistant_begin :: proc(observer: Chat_Observer) {
	if observer.assistant_begin != nil { observer.assistant_begin(observer.user_data) }
}

@(private)
_observer_assistant_text :: proc(observer: Chat_Observer, text: string) {
	if observer.assistant_text != nil { observer.assistant_text(observer.user_data, text) }
}

@(private)
_observer_assistant_flush :: proc(observer: Chat_Observer) {
	if observer.assistant_flush != nil { observer.assistant_flush(observer.user_data) }
}

@(private)
_observer_assistant_end :: proc(observer: Chat_Observer) {
	if observer.assistant_end != nil { observer.assistant_end(observer.user_data) }
}

@(private)
_observer_user_text :: proc(observer: Chat_Observer, text: string) {
	if observer.user_text != nil { observer.user_text(observer.user_data, text) }
}

@(private)
_observer_tool_result :: proc(observer: Chat_Observer, name: string, result: ^Tool_Result) {
	if observer.tool_result != nil { observer.tool_result(observer.user_data, name, result) }
}

@(private)
_observer_message :: proc(observer: Chat_Observer, kind: Chat_Message_Kind, text: string) {
	if observer.message != nil { observer.message(observer.user_data, kind, text) }
}

@(private)
_observer_queue :: proc(observer: Chat_Observer, event: Chat_Queue_Event, depth: int) {
	if observer.queue != nil { observer.queue(observer.user_data, event, depth) }
}

@(private)
_observer_usage :: proc(observer: Chat_Observer, operation: u64, usage: ai.Provider_Usage_Event) {
	if observer.usage != nil { observer.usage(observer.user_data, operation, usage) }
}
