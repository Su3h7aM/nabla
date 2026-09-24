# ACP frontend

Status: the implemented contract for the Agent Client Protocol frontend. Read it before
changing the `acp` package or `nabla acp`. [Implementation status](ARCHITECTURE_STATUS.md)
records what is still missing.

## What it is

`nabla acp` runs this harness as an ACP agent. An editor (or any other ACP client) starts
the process, initializes it, opens a session for a working directory, and sends prompts.
The conversation is an ordinary harness session: the same store, the same turn loop, the
same cancellation and recovery. The frontend translates and owns nothing else.

Two packages divide the work:

| Piece | Owns |
| --- | --- |
| `acp` | Protocol facts: newline framing, JSON-RPC envelopes, method and notification names, payload shapes, and the outbound writer. It holds no Nabla concept: a session id is opaque, a prompt is content blocks, and an update is a document. |
| root `nabla` (`acp_serve.odin`, `acp_server.odin`) | Adaptation: the stdio loop, session lifecycle, model selection, prompt admission, cancellation, and the translation from harness events to session updates. |

The agent sends no client requests in this version, so the package has no client-side
request plumbing and no pending-response table.

## Pointing a client at it

The client starts `nabla acp` and speaks to the process's standard streams, so the binary
must be on the client's `PATH` and the harness must have a provider configured. Zed, for
example, takes this entry in its settings:

```json
{
  "agent_servers": {
    "nabla": { "type": "custom", "command": "nabla", "args": ["acp"] }
  }
}
```

## Threads and ownership

The reader thread owns the protocol conversation. It reads frames, answers `initialize`
and the errors it can answer alone, and hands session work to the worker. The worker
thread owns the session: it opens sessions, runs turns, selects the model, and writes
everything a turn produces.

The split exists for one protocol requirement: `session/cancel` arrives on the same
stream as the prompt it cancels, so nothing may block the reader while a turn runs.

- `busy` (atomic) is the reader's and the worker's agreement about the requests in
  flight. The reader accepts a session request or a prompt only when it is false; the
  worker clears it once the last queued request is answered. `pending_work`, guarded by
  `queue_mu`, keeps the flag set while a request waits, and `session_generation`
  invalidates requests queued against a session that has since been replaced.
- `cancel_seen` (atomic) carries a cancellation that arrived while the prompt was still
  being recorded. Accepting a prompt clears the process's cancellation token, so the
  worker re-issues the request for the turn that must see it.
- `session_id` (owned, under a mutex) is what the reader matches a prompt or a
  cancellation against, so a request for a session the client never opened cannot reach
  the session the process started with.
- `acp.Writer` serializes frames under its own mutex, because the reader answers
  requests while the worker streams updates. One lock hold covers each frame, so a
  frame a client reads is whole. A write error latches: a client that stopped
  reading will not read the next frame either, and the run stops.
- One JSON-RPC value travels per line, up to 1 MiB. An oversized, invalid, or
  un-storable frame is refused with an error and the conversation continues; broken
  JSON is a parse error, anything else about the envelope is an invalid request.

The harness reports each tool call to the observer once when it is admitted and once when
it settles (`Chat_Observer.tool_call` and `tool_result`), which is what gives the client
the `tool_call` and `tool_call_update` pair. Code Mode children stay hidden, as they are
from every other frontend.

## Session mapping

- `session/new` adopts a session in the client's `cwd`, replacing whatever session the
  process held, and answers with its id and the model selector. The directory must be
  absolute and exist.
- `session/load` adopts the stored session by id and replays its conversation as updates
  before answering. A `cwd` that names a different directory than the stored session is
  refused. Loading the session the process already runs is not a switch. A
  session is stored once it has a conversation, so an id that was never prompted names
  nothing yet and the load is refused rather than answered with an empty session. An
  unreadable store is an internal error, not an unknown id.
- A replayed conversation skips partial assistant entries: they are text from a turn
  that never finished, and replaying them as complete messages would misstate the
  record.
- The client's standing instructions travel on `session/new` and `session/load` as the
  `systemPrompt` field or the `_meta.systemPrompt` forms, with the optional
  `_meta.sessionTitle`. They are stored outside the conversational history and rendered
  into the harness system prompt, so resuming never shows them as chat.
- One session per process. The harness claims one session at a time, and a second
  `session/new` replaces the first. Concurrent sessions would need an owner per session,
  which does not exist.
- Client-provided stdio `mcpServers` are installed for the session and released when a
  later session replaces them. A server needs an absolute command path; any other
  transport is refused. `additionalDirectories` is refused rather than ignored: a
  client that asked for a directory and got silence would believe it was there.
- The model is chosen the way a headless run chooses one: the stored selection, then the
  model the session recorded, then the first configured model that can serve a request.
  Nothing is persisted, because a model chosen for an editor conversation is not the
  user's own last choice for the harness. The `session/set_config_option` method
  switches the model mid-session, and the answer carries the updated selector.

## What a turn reports

| Harness event | Session update |
| --- | --- |
| Assistant text | `agent_message_chunk`, one message id per assistant message |
| Harness notice, warning, error, retry decision | `agent_message_chunk`, one message each |
| A call is admitted | `tool_call`: pending, kind, title, raw input |
| A call settles | `tool_call_update`: completed or failed, with the result preview |
| A request finishes | `usage_update`: measured input (or the harness's estimate) against the model window |

A cancelled turn answers `session/prompt` with the `cancelled` stop reason, which is an
answer rather than an error. A turn the harness could not finish answers with an error,
and the transcript already carries the reason. A turn the store could not record
answers as a failure even when the model finished it: the record is what the answer
may claim.

## Not implemented

Each is a capability a client may use, and the order is roughly what a client misses
first.

1. `session/request_permission`. No tool call is gated: the harness has no admission
   policy hook, so every admitted call runs. This needs a decision seam in `agent`, one
   the owner can hold a call on while the client answers.
2. Client filesystem and terminal (`fs/read_text_file`, `fs/write_text_file`,
   `terminal/*`). Tools run against the local filesystem, which for a local client is the
   same machine.
3. Modes, `session/delete`, and `session/fork`. The model follows the opened session
   through `session/set_config_option`, but nothing else about the session is
   configurable while the process runs.
4. `session/list`, `session/resume`, and `session/close`.
5. Slash commands and `available_commands_update`.
