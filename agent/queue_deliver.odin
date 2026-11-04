package agent

import "base:runtime"
import "core:fmt"
import "core:os"

import "nabla:agent/journal"
import "nabla:ai"

// chat_queue_ready returns the idle queue kind to deliver, preferring steering.
// A held entry blocks later entries of its kind. Only the session owner calls it.
@(require_results)
chat_queue_ready :: proc(chat: ^Chat_Session) -> (kind: Maybe(journal.Queue_Kind), ok: bool) {
	if !chat_journal_writable(chat) { return nil, true }
	if chat.queue_delivery_pending { return chat.queue_delivery_kind, true }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	entries, error := journal.queue_list(chat.store, chat.session, context.temp_allocator)
	if error != nil {
		if !journal.error_is_busy(error) { chat_session_record_failure(chat, "the prompt queue could not be read", error) }
		return nil, journal.error_is_busy(error)
	}
	blocked: bit_set[journal.Queue_Kind]
	for entry in entries {
		if entry.held { blocked += {entry.kind} }
		if entry.kind in blocked { continue }
		if entry.kind == .Steering { return .Steering, true }
		kind = .Follow_Up
	}
	return kind, true
}

// chat_queue_deliver_ready commits all ready steering entries, or one follow-up.
// False means a busy commit or a changed row needs another wake, or storage failed.
// The pending result belongs to chat and must remain live until its journal closes.
@(require_results)
chat_queue_deliver_ready :: proc(chat: ^Chat_Session, kinds: bit_set[journal.Queue_Kind]) -> bool {
	if chat.storage_failed || !chat_journal_writable(chat) { return !chat.storage_failed }
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if chat.queue_delivery_pending {
		if !chat_queue_delivery_commit(chat) { return false }
		if chat.queue_delivery_kind == .Follow_Up { return true }
	}
	entries, error := journal.queue_list(chat.store, chat.session, context.temp_allocator)
	if error != nil {
		if !journal.error_is_busy(error) { chat_session_record_failure(chat, "the prompt queue could not be read", error) }
		return false
	}
	blocked: bit_set[journal.Queue_Kind]
	for entry in entries {
		if entry.held { blocked += {entry.kind} }
		if entry.kind not_in kinds || entry.kind in blocked { continue }
		attachments, allocation_error := make([]ai.Provider_Attachment, len(entry.attachments), context.temp_allocator)
		if allocation_error != nil {
			chat_session_fail(chat, "the queued attachments could not be allocated")
			return false
		}
		count := 0
		for path in entry.attachments {
			data, read_error := os.read_entire_file(path, context.temp_allocator)
			if read_error != nil {
				chat_runtime_message(
					chat,
					.Warning,
					fmt.tprintf("queued attachment %s could not be read: %s; delivering the prompt text", path, os.error_string(read_error)),
				)
				continue
			}
			media, recognized := ai.Provider_Media_Detect(data)
			if !recognized {
				chat_runtime_message(chat, .Warning, fmt.tprintf("queued attachment %s has an unsupported format; delivering the prompt text", path))
				continue
			}
			_, name := os.split_path(path)
			attachments[count] = {
				Media = media,
				Name  = name,
				Data  = data,
			}
			count += 1
		}
		chat.queue_delivery_kind = entry.kind
		chat.queue_delivery_pending = true
		journal.queue_deliver(chat.store, chat.session, entry.id, attachments[:count], &chat.queue_delivery)
		if !chat_queue_delivery_commit(chat) { return false }
		if entry.kind == .Follow_Up { return true }
	}
	return true
}

@(private, require_results)
chat_queue_delivery_commit :: proc(chat: ^Chat_Session) -> bool {
	if !chat.queue_delivery.completed {
		_, error := journal.commit(chat.store)
		if error != nil {
			if !journal.error_is_busy(error) { chat_session_record_failure(chat, "the queued prompt could not be delivered", error) }
			return false
		}
	}
	if !chat.queue_delivery.completed { return false }
	chat.queue_delivery_pending = false
	return chat.queue_delivery.seq != 0
}
