#+build linux
package main

import "core:fmt"

import "nabla:agent"
import "nabla:agent/journal"

// serve_environment_seq returns the seq of the session's latest session.environment
// record, 0 when it has none. The record is scratch; the caller resets temp memory.
@(require_results)
serve_environment_seq :: proc(app: ^App) -> (seq: journal.Journal_Seq, error: journal.Error) {
	chat := &app.setup.session
	record, found, read_error := journal.read_latest(chat.store, {session = chat.session, kinds = {.Session_Environment}}, context.temp_allocator)
	if read_error != nil { return 0, read_error }
	if !found { return 0, nil }
	defer journal.record_destroy(&record, context.temp_allocator)
	return record.seq, nil
}

// serve_environment_sync applies the latest session.environment record when it is
// newer than the last one applied, the way an ACP open applies the values it
// carries: the standing instructions, then the MCP servers over the launch's own
// list. It runs only while the session is idle, so a running turn keeps its setup;
// a record that lands mid-turn waits for the next wake. False means the session can
// no longer be served and the reason was printed.
@(require_results)
serve_environment_sync :: proc(app: ^App) -> bool {
	setup := &app.setup
	chat := &setup.session
	environment, seq, found, read_error := journal.read_session_environment(chat.store, chat.session, context.temp_allocator)
	if read_error != nil {
		fmt.eprintln("nabla: cannot read the session environment:", journal.error_text(read_error, context.temp_allocator))
		return false
	}
	if !found || seq <= setup.environment_applied { return true }
	if chat.state != .Idle { return true }
	configs, configs_error := agent.session_environment_to_configs(environment, setup.alloc)
	if configs_error != .None {
		// A record the server cannot use is refused and marked, as an ACP refusal
		// is: running it again would fail the same way.
		fmt.eprintln("nabla: the session environment could not be used and was skipped")
		setup.environment_applied = seq
		return true
	}
	if !agent.chat_session_set_client_instructions(chat, environment.instructions) {
		agent.MCP_Server_Configs_Destroy(&configs, setup.alloc)
		fmt.eprintln("nabla: the session instructions could not be stored")
		return false
	}
	if serve_environment_mcp_conflict(setup.environment_base, configs) {
		agent.MCP_Server_Configs_Destroy(&configs, setup.alloc)
		fmt.eprintln("nabla: the session environment names an MCP server the launch already configures and was skipped")
		setup.environment_applied = seq
		return true
	}
	if !serve_environment_apply_mcp(setup, configs) {
		fmt.eprintln("nabla: the session MCP configuration could not be installed")
		return false
	}
	setup.environment_applied = seq
	return true
}

// serve_environment_mcp_conflict reports whether a requested server repeats an id,
// its own or the launch's. The launch refuses those too, so the record is skipped
// instead of replacing a server the session already runs.
serve_environment_mcp_conflict :: proc(base: []agent.MCP_Server_Config, requested: [dynamic]agent.MCP_Server_Config) -> bool {
	for first, i in requested {
		for second, j in requested {
			if i != j && first.id == second.id { return true }
		}
		for entry in base {
			if entry.id == first.id { return true }
		}
	}
	return false
}

// serve_environment_apply_mcp installs the requested servers over the launch's own
// list and takes ownership of them. The old runtime owns processes and bindings the
// new list no longer borrows, so it stops before the configuration list changes,
// and a fresh runtime is reserved for the combined list. False means an allocation
// failed and the launch's own list is what's running.
@(require_results)
serve_environment_apply_mcp :: proc(setup: ^Run_Setup, requested: [dynamic]agent.MCP_Server_Config) -> bool {
	servers := requested
	mcp_runtime_destroy(&setup.mcp)
	agent.MCP_Server_Configs_Destroy(&setup.environment_owned, setup.alloc)
	setup.mcp_servers = setup.environment_base
	if len(servers) == 0 {
		built, ok := mcp_runtime_make(setup.mcp_servers, setup.alloc)
		setup.mcp = built
		delete(servers)
		return ok
	}
	combined, clone_error := agent.MCP_Server_Configs_Clone(setup.environment_base, setup.alloc)
	if clone_error != .None {
		serve_environment_restore_base(setup)
		agent.MCP_Server_Configs_Destroy(&servers, setup.alloc)
		return false
	}
	failed := true
	defer if failed {
		agent.MCP_Server_Configs_Destroy(&combined, setup.alloc)
		agent.MCP_Server_Configs_Destroy(&servers, setup.alloc)
	}
	for server, index in servers {
		appended := append(&combined, server)
		if appended != 1 {
			if appended == 0 {
				agent.MCP_Server_Config_Destroy(&servers[index], setup.alloc)
				servers[index] = {}
			}
			serve_environment_restore_base(setup)
			return false
		}
		servers[index] = {}
	}
	delete(servers)
	servers = nil
	built, runtime_ok := mcp_runtime_make(combined[:], setup.alloc)
	if !runtime_ok {
		serve_environment_restore_base(setup)
		return false
	}
	setup.environment_owned = combined
	setup.mcp_servers = combined[:]
	setup.mcp = built
	failed = false
	return true
}

// serve_environment_restore_base reserves a runtime for the launch's own servers
// after a failed install. A failed restore leaves the zero runtime: no MCP servers.
serve_environment_restore_base :: proc(setup: ^Run_Setup) {
	restored, _ := mcp_runtime_make(setup.environment_base, setup.alloc)
	setup.mcp = restored
}
