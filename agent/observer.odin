package agent

import "core:time"

import "nabla:agent/journal"
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
	// turn_finished runs after the turn's final events. No call from that turn can
	// report afterward. Followers report it in journal order, before a later turn.
	turn_finished:    proc(user_data: rawptr),
	assistant_begin:  proc(user_data: rawptr),
	assistant_text:   proc(user_data: rawptr, text: string),
	assistant_flush:  proc(user_data: rawptr),
	assistant_end:    proc(user_data: rawptr),
	// user_text reports one user-role text with the origin that produced it, so
	// the front-end can show what another agent sent apart from the user's own
	// lines.
	user_text:        proc(user_data: rawptr, text: string, origin: journal.User_Origin),
	// tool_call is called once when the harness admits a call, before the call runs and
	// before its result exists. It reports a call the model made and a call a Code Mode
	// script made alike. A call that is refused or cancelled announces itself here too and
	// still reports a result, so a front-end sees every committed call exactly once as
	// pending and exactly once as settled. The event borrows its strings for the duration
	// of the callback. The session's own calls have nonzero ids; zero means unknown and
	// identifies nothing.
	tool_call:        proc(user_data: rawptr, event: Chat_Tool_Event),
	// tool_result reports one committed result. call is the call's own journal id and
	// parent_call the Code Mode call that ran it, or zero for a call the model made
	// directly. name and the proposed arguments are borrowed for the duration of the
	// callback.
	tool_result:      proc(user_data: rawptr, call, parent_call: journal.Call_Id, name, arguments: string, result: ^Tool_Result),
	message:          proc(user_data: rawptr, kind: Chat_Message_Kind, text: string),
	usage:            proc(user_data: rawptr, operation: u64, usage: ai.Provider_Usage_Event),
	// request_prepared is called once for each provider request the turn is about to
	// send, after the request is built.
	request_prepared: proc(user_data: rawptr),
	// request_finished is called once for each provider request the turn made, after its
	// outcome is recorded.
	request_finished: proc(user_data: rawptr),
	// retry_scheduled is called once for each retry the harness schedules, before the
	// chain waits.
	retry_scheduled:  proc(user_data: rawptr, event: Chat_Retry_Event),
}

// Chat_Tool_Event is one tool call the harness admitted. call is the call's own journal
// id and parent_call the Code Mode call that ran it, or zero for a call the model made
// directly; the later tool_result names the same call. The strings are borrowed for the
// duration of the callback.
Chat_Tool_Event :: struct {
	call:        journal.Call_Id,
	parent_call: journal.Call_Id,
	call_id:     string,
	name:        string,
	arguments:   string, // the argument text the model sent, before any repair
}

// Chat_Retry_Event is one retry the harness scheduled.
Chat_Retry_Event :: struct {
	request:       journal.Request_Id,
	next_attempt:  int,
	failure_class: ai.Provider_Failure_Class,
	reason:        Request_Recovery_Reason,
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
_observer_turn_finished :: proc(observer: Chat_Observer) {
	if observer.turn_finished != nil { observer.turn_finished(observer.user_data) }
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
_observer_user_text :: proc(observer: Chat_Observer, text: string, origin: journal.User_Origin) {
	if observer.user_text != nil { observer.user_text(observer.user_data, text, origin) }
}

@(private)
_observer_tool_call :: proc(observer: Chat_Observer, event: Chat_Tool_Event) {
	if observer.tool_call != nil { observer.tool_call(observer.user_data, event) }
}

@(private)
_observer_tool_result :: proc(observer: Chat_Observer, call, parent_call: journal.Call_Id, name, arguments: string, result: ^Tool_Result) {
	if observer.tool_result != nil { observer.tool_result(observer.user_data, call, parent_call, name, arguments, result) }
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
