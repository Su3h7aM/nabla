// Package agent is Nabla's harness: the owner loop that runs one session, the request
// chain it sends through a provider, the tool calls a model asks for, the Lua runtime
// those calls run on, the subagents a session may delegate to, and the configuration and
// model catalog it runs with.
//
// It is the boundary of the harness in three directions. The durable record belongs to
// `agent/journal`, which the agent reads and writes through but never extends; the
// terminal, the renderer, and process lifetime belong to the executable above it; the
// skills and instruction material it reads are parsed by `agent/skills`. Nothing here
// writes to a screen or produces formatted output: what is user-visible leaves through
// Chat_Observer, and a front-end may leave every callback unset.
//
// # The owner loop
//
// Chat_Session is the running half of a session: the turn in flight, its request chain,
// its tool jobs, and its tool registry. No conversation is kept here. Committed history
// lives in the journal, and the caller opens that journal and claims the session before
// it calls chat_session_init; chat_session_destroy releases the session again.
//
// One thread runs a session, and it is the only writer to that session's journal and the
// only thread that mutates Chat_Session. Each pass of the loop applies the facts that
// arrived from outside with chat_session_observe, selects the one effect the state now
// wants with chat_session_advance, which only reads state, and performs it. Chat_Effect is
// a closed set, and every step a turn takes is one of its members.
//
// Work that blocks on the outside world runs on a worker thread that publishes its result
// into a handoff slot and wakes the owner: the owner decides, the worker executes. No lock
// is held across I/O or a wait. A worker that ignores its stop is abandoned, the call it
// was running records the outcome as unknown, and the session keeps admitting turns; what
// that worker may still touch stays allocated until it publishes.
//
// # Turns and requests
//
// At most one turn runs in a session. Chat_State is the control state of that turn, moving
// between preparing, requesting, executing tools, cancelling, and finalizing. A turn is
// accepted as a prompt or as a steering line and runs to its terminal status inside
// chat_run_turn_steered, which owns the process signal handler, or chat_turn_drive, which
// does not and is what a subagent's thread runs.
//
// A logical request is a chain of attempts. The request is prepared from the committed
// projection, frozen to exact bytes, committed before it is sent, and attempted on its own
// worker. A transient failure is sent again only while the delivery evidence proves the
// model never received the request, and a delay the provider asked for is honored as given;
// there is no attempt count. A response that cannot be decoded, is incomplete, is cut off by
// the model's output limit, or carries defective call identities is committed with a
// Chat_Notice that says what was wrong and that nothing ran, and the turn continues.
//
// # The projection
//
// A request is built from Projection: the covering checkpoint's summary, then every step
// committed after it, in node order. Provider-native records are replayed where they can
// be, and a repaired call projects the arguments it actually ran with.
//
// # Tools
//
// A Tool_Definition pairs the schema a model is shown with the executor that runs it, the
// placement that says which thread runs it, its static behavior hints, its timeout when the
// model gives none, and the lane that serializes it. Tool_Registry holds the definitions a
// session may dispatch; a registry is replaced as a whole, and a running turn borrows the
// one its calls were advertised with.
//
// Every call, whether a provider response proposed it or a Lua child made it, passes the
// same admission: the argument document is parsed, repaired where its intent has exactly one
// reading, and validated into typed arguments. A call that cannot be repaired and validated
// still gets a committed result saying what was wrong, and its siblings run.
//
// A call becomes a Tool_Job before it becomes an execution. The job is the owner's record of
// one call from admission to retirement, and the owner runs the earliest queued job whose
// lane is free, up to the worker slots available.
//
// # Code Mode
//
// The Code Mode tool runs a Lua program on an embedded `vendor:lua/5.4` state created for
// that run. A run executes in slices on the owner thread and suspends when it starts a
// child, waits for one, or calls a tool, which becomes an ordinary tool job. A script may
// hold any number of unfinished children, and one that ends with children still running has
// them stopped, each still committing its own result. Values cross the boundary as Lua
// values or as JSON text, and a value that cannot be represented is refused with the path it
// failed at. The run owns its state, its scratch arena, and its answer, and they are
// released when its job retires.
//
// # Material and instructions
//
// The bytes a request begins with are the workspace `AGENTS.md`, the user's own instruction
// files, and the skill catalog, rendered once into an instruction snapshot. The snapshot and
// the manifest of what went into it are stored as artifacts, and a session restores the
// snapshot its latest turn recorded rather than rendering a different one. Skill metadata is
// disclosed inline or through a catalog lookup, and a skill body is read on demand and
// verified against the catalog it was selected with.
//
// # Subagents
//
// A session delegates through the agent tool. A native child runs as the owner of its own
// session on its own thread in the same process, with its own registry and its own inherited
// selection; an ACP child runs a configured program in a child process and is spoken to over
// the protocol. The parent keeps one Agent_Team holding the children it must reap and the
// messages that pass between a parent and its children, which are delivered at a settled
// boundary.
//
// # Context and compaction
//
// Model_Capacity is computed once per model when the catalog is resolved, so no two parts of
// the harness disagree about how much context a model holds. When a conversation reaches the
// window's pressure point, a compaction job summarizes a frozen prefix on another thread
// while the turn keeps sending requests over the unchanged projection. The summary installs
// as a checkpoint at a request boundary, and every node committed while it ran survives in
// the projection after it.
//
// # Catalog and configuration
//
// A configuration file is evaluated by a Lua state under its own small bounds, and what it
// returns is validated into plain data. Provider and model metadata resolves from the user's
// configuration, each provider's own model listing, and the models.dev catalog, in that
// order, with the first present value winning; a field that is absent stays distinguishable
// from one that is present and false, zero, or empty. A session reads the resolved catalog
// and the resolved configuration rather than the sources behind them.
//
// # Failures and diagnostics
//
// A failure the model can act on becomes feedback to the model and the turn continues; a
// failure that leaves the model unreachable ends the turn and is reported to the user. A
// durable write that fails latches the session, which accepts no further work, because
// continuing would let the conversation diverge from what was stored.
//
// A process diagnostic is a runtime.message record that the thread owning the journal
// writes through chat_runtime_message. Worker threads never write the journal; they report
// to their owner through the mailbox.
//
// # Memory
//
// A session owns everything it holds with the allocator it was initialized with: the
// projection, the frozen request, the registry, and the turn's buffers. A request prepared
// for one attempt lives in the chain's arena, and each pass of the loop releases its own
// scratch with the temporary allocator guard.
package agent
