#+test
package main

import "core:strings"
import "core:sync"
import "core:testing"

import "nabla:acp"
import "nabla:agent"

@(test)
test_acp_refuses_to_replace_an_escaped_session :: proc(t: ^testing.T) {
	server: Acp_Server
	server.alloc = context.allocator
	server.app.setup.alloc = context.allocator
	server.app.setup.session.worker_escaped = true
	sync.atomic_store(&server.busy, true)

	output := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&output)
	writer, writer_err := acp.writer_init(strings.to_writer(&output), context.allocator)
	if writer_err != nil { testing.fail_now(t, "the ACP writer could not be created") }
	server.writer = writer
	defer acp.writer_destroy(&server.writer)

	work := Acp_Work {
		kind = .Open_Session,
		id   = i64(1),
	}
	acp_run_work(&server, work)
	acp_work_destroy(&work, server.alloc)

	testing.expect(t, sync.atomic_load(&server.busy), "an escaped session must stay latched")
	testing.expect(t, strings.contains(strings.to_string(output), agent.CHAT_WORKER_ESCAPED_NOTICE))
}
