#+test
package mcp

import "core:testing"
import "core:time"

// CLIENT_TEST_BOUND is a deadline no passing test comes near: a listing that never
// ends fails as a timeout instead of hanging the suite.
CLIENT_TEST_BOUND :: 10 * time.Second

// Cursor values are opaque: even a repeated value is followed until the server
// omits nextCursor or the caller's control stops the listing.
@(test)
test_tools_list_follows_a_repeated_cursor :: proc(t: ^testing.T) {
	server := `
i=1
while read line; do
  if [ "$i" -lt 3 ]; then
    printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","nextCursor":"same","tools":[]}}\n' "$i"
  else
    printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"finished","description":"d","inputSchema":{"type":"object"}}]}}\n' "$i"
  fi
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
		deadline = time.tick_add(time.tick_now(), CLIENT_TEST_BOUND),
	}
	page, err := client_tools_list(&client, {control = control})
	defer tool_page_destroy(&page)
	defer error_destroy(&err)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect_value(t, len(page.tools), 1)
	testing.expect_value(t, page.tools[0].name, "finished")
}

@(test)
test_tools_list_follows_an_empty_cursor :: proc(t: ^testing.T) {
	server := `
while read line; do
  case "$line" in
    *'"cursor":""'*)
      printf '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","tools":[{"name":"finished","description":"d","inputSchema":{"type":"object"}}]}}\n'
      ;;
    *)
      printf '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","nextCursor":"","tools":[]}}\n'
      ;;
  esac
done
`
	client: Client
	start_error := client_start(&client, {executable = "/bin/sh", arguments = {"-c", server}})
	defer client_destroy(&client)
	if !testing.expect_value(t, start_error.kind, Error_Kind.None) { error_destroy(&start_error); return }
	error_destroy(&start_error)
	client.version = .V2026_07_28

	control := Control {
		deadline = time.tick_add(time.tick_now(), CLIENT_TEST_BOUND),
	}
	page, err := client_tools_list(&client, {control = control})
	defer tool_page_destroy(&page)
	defer error_destroy(&err)
	if !testing.expect_value(t, err.kind, Error_Kind.None) { return }
	testing.expect_value(t, len(page.tools), 1)
	testing.expect_value(t, page.tools[0].name, "finished")
}
