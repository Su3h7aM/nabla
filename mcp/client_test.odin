#+test
package mcp

import "core:strings"
import "core:testing"
import "core:time"

// CLIENT_TEST_BOUND is a deadline no passing test comes near: a listing that never
// ends fails as a timeout instead of hanging the suite.
CLIENT_TEST_BOUND :: 10 * time.Second

// A server that answers every page with the cursor it was just given would ask for a
// page that has already been read, so the listing could never end. The repeated
// cursor is refused, and the refusal is a protocol error rather than a page count.
@(test)
test_tools_list_refuses_a_repeated_cursor :: proc(t: ^testing.T) {
	// One process stands in for a server: it answers every request with the same
	// cursor, which is the only way a listing can fail to end.
	server := `
i=1
while read line; do
  printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","nextCursor":"same","tools":[]}}\n' "$i"
  i=$((i+1))
done
`
	client: Client
	start_error := client_start(&client, {executable = "/bin/sh", arguments = {"-c", server}})
	defer client_destroy(&client)
	if !testing.expect_value(t, start_error.kind, Error_Kind.None) { error_destroy(&start_error); return }
	error_destroy(&start_error)
	client.version = .V2026_07_28

	control := Control {
		deadline_at  = time.tick_add(time.tick_now(), CLIENT_TEST_BOUND),
		has_deadline = true,
	}
	page, err := client_tools_list(&client, {control = control})
	defer tool_page_destroy(&page)
	defer error_destroy(&err)
	testing.expect_value(t, err.kind, Error_Kind.Malformed_Message)
	testing.expect(t, strings.contains(err.message, "cursor"), err.message)
}
