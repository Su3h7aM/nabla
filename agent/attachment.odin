package agent

import "core:mem"
import "core:strings"

import "nabla:agent/journal"
import "nabla:ai"

// attachments_record buffers the bytes of attachments as journal artifacts and returns
// the references a User node or a tool.completed record carries, in the same order.
// The references borrow each name and own their digest text and the slice, all
// allocated with allocator; scratch memory suits, since the journal copies the
// references when the record is appended. On an allocation error the references made
// so far are left to allocator.
@(require_results)
attachments_record :: proc(
	store: ^journal.Journal,
	attachments: []ai.Provider_Attachment,
	allocator: mem.Allocator,
) -> (
	recorded: []journal.Attachment,
	err: mem.Allocator_Error,
) {
	if len(attachments) == 0 { return nil, nil }
	recorded = make([]journal.Attachment, len(attachments), allocator) or_return
	for attachment, index in attachments {
		digest := journal.put_artifact(store, journal.ATTACHMENT_ARTIFACT, attachment.Data)
		hex: [journal.DIGEST_HEX_LENGTH]u8
		recorded[index] = {
			media_type = ai.PROVIDER_MEDIA_TYPES[attachment.Media],
			name       = attachment.Name,
			digest     = strings.clone(journal.digest_to_hex(digest, hex[:]), allocator) or_return,
		}
	}
	return recorded, nil
}
