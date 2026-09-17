package agent

import "core:time"

import "nabla:agent/session"
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
	user_data:        rawptr,
	assistant_begin:  proc(user_data: rawptr),
	assistant_text:   proc(user_data: rawptr, text: string),
	assistant_flush:  proc(user_data: rawptr),
	assistant_end:    proc(user_data: rawptr),
	user_text:        proc(user_data: rawptr, text: string),
	tool_result:      proc(user_data: rawptr, name: string, result: ^Tool_Result),
	message:          proc(user_data: rawptr, kind: Chat_Message_Kind, text: string),
	usage:            proc(user_data: rawptr, operation: u64, usage: ai.Provider_Usage_Event),
	// request_prepared is called once for each provider request the turn is about to
	// send, after the request is built and its input size is known. It is a different
	// moment from request_finished because the context has already grown by then: a
	// front-end that shows the context can report the new size while the model is still
	// answering, rather than a round trip later.
	request_prepared: proc(user_data: rawptr),
	// request_finished is called once for each provider request the turn made, after its
	// outcome is recorded. The provider's own accounting of it is in the store by then, so
	// a front-end that shows the session totals can refresh here instead of waiting for
	// the turn to end.
	request_finished: proc(user_data: rawptr),
	// retry_scheduled is called once for each retry the harness schedules, after the
	// failed send's row is finished and before the chain waits. Nothing about the
	// decision needs the front-end; this is how a front-end says that a turn is waiting
	// rather than stalled. A chain whose sends all succeeded, and one that stops, calls
	// it not at all, and the send that follows clears whatever the front-end showed.
	retry_scheduled:  proc(user_data: rawptr, event: Chat_Retry_Event),
}

// Chat_Retry_Event is one retry the harness scheduled: which send failed, which one is
// next, how many the chain may make, what the provider's failure meant, and how long the
// harness waits before sending again. It is the decision the failed request's own row
// records, reported in time for a front-end to act on it while the turn is waiting.
Chat_Retry_Event :: struct {
	request_no:    session.Request_No,
	next_attempt:  int,
	max_attempts:  int,
	failure_class: ai.Provider_Failure_Class,
	delay:         time.Duration,
}

// Chat_Message_Kind classifies a diagnostic line. The agent decides how serious
// it is; the front-end decides where it goes and what it looks like.
Chat_Message_Kind :: enum {
	Notice,
	Warning,
	Error,
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
_observer_usage :: proc(observer: Chat_Observer, operation: u64, usage: ai.Provider_Usage_Event) {
	if observer.usage != nil { observer.usage(observer.user_data, operation, usage) }
}

@(private)
_observer_request_prepared :: proc(observer: Chat_Observer) {
	if observer.request_prepared != nil { observer.request_prepared(observer.user_data) }
}

@(private)
_observer_request_finished :: proc(observer: Chat_Observer) {
	if observer.request_finished != nil { observer.request_finished(observer.user_data) }
}

@(private)
_observer_retry_scheduled :: proc(observer: Chat_Observer, event: Chat_Retry_Event) {
	if observer.retry_scheduled != nil { observer.retry_scheduled(observer.user_data, event) }
}
