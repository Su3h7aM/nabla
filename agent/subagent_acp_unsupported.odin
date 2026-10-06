#+build !linux
package agent

import "core:os"

// Targets without the socket-pair backend cannot start an ACP agent: every open fails
// and no path counts as executable.

@(private, require_results)
acp_input_open :: proc() -> (input: ACP_Input, ok: bool) {
	return {}, false
}

@(private)
acp_input_close :: proc(input: ^ACP_Input) {
	if input.theirs != nil { _ = os.close(input.theirs) }
	input^ = {}
}

@(private)
acp_input_send :: proc(input: ^ACP_Input, p: []byte) -> (n: int, ok: bool) {
	return 0, false
}

@(private, require_results)
subagent_executable :: proc(path: string) -> bool {
	return false
}
