# Future subagent tool

Status: future capability, not an implementation requirement for the current harness.
No subagent scheduler, IPC protocol, role files or persisted handles should be added
until delegation is requested. This contract constrains that future work.

## Invocation and authority

A subagent is an ordinary tool invoked by the main agent with dynamic instructions
and parameters. There are no predefined reviewer/coder/planner identities, Markdown
agent definitions, role directories or agent preset registry. The instruction supplies
the specialization for this one invocation. Skills remain instruction resources, not
agent definitions.

Require bounded task instructions. Permit provider/model/effort selection through the
same resolved catalog, defaulting to the parent's effective selection when omitted.
A model-authored instruction is not authorization. The child receives no more tool,
workspace, credential or configuration authority than the parent can delegate.
Default to no recursive delegation. Do not invent a permission-language subsystem as
a prerequisite; enforce the concrete capability restrictions actually provided.

## Execution

Use the ordinary parent tool job for admission, durable intent, stop, result commit
and retirement. Initially the model gets one bounded terminal result, not a detached
job handle. Internally a process handle is enough to let the owner wait for completion
without occupying a worker slot needed by its children. Lua can invoke this tool through
the same wrappers as any other tool. A future task API does not change its authority.

Run the same Nabla executable in an isolated child process. This is a deliberate
boundary for independent model execution and forcible termination, not a reason to
put every native tool in its own process today. The child runs the same state machine
with its own session and writer. The parent supervises a process; it does not host a
second recursive loop or share mutable conversation memory.

Start with one child at a time. Bound total invocations, process count, instruction
and output bytes, retained child history, and cancellation patience. Child resource
use counts toward the parent's delegated allowance. Require explicit workspace policy:
initially serialize shared-workspace mutations, since process isolation does not isolate
files. Concurrent editing requires a separate workspace or proven coordination, not
just increasing a worker count.

Use the smallest bounded communication contract the implementation requires. Carry
startup identity, stop, terminal status and result; add progress only when consumed.
Choose framing and versioning then, rather than build a general RPC framework now.
The parent consumes the result, not a copied child transcript. Child history remains
separately inspectable with parent correlation.

## Completion and failure

Distinguish a valid completed result, a reported task failure, malformed/missing terminal
output, abnormal exit, cancellation and timeout. Preserve exit/signal evidence in
diagnostics and give the parent a small ordinary tool envelope. Do not postpone these
semantic distinctions until after implementation, but avoid a speculative rich public
result schema.

A child exit alone is not successful completion. Request cooperative stop first, then
terminate and reap within supervision policy. Descendants can create their own process
groups, so killing only the child's initial group is not proof that all its tools
stopped. The implementation must account for that process tree and prove cleanup,
or report remaining uncertainty. No detached children after normal parent settlement.

A stopped child may have changed shared files or invoked remote services. Forced
termination does not roll those effects back. Parent restart treats an unanswered
dispatch as Unknown and never respawns it automatically. Child-produced instructions
cannot widen parent authority or become user messages.

## Implementation gate

Before exposing the tool, prove process startup failure, bounded framing, cancellation
and escalation, descendant cleanup, crash after an effect, result-before-exit races,
retained-output exhaustion, parent restart, and no parent storage mutation from the
child. A thread or coroutine alone cannot establish crash isolation. No agent teams,
process pool, durable continuation format or recursive delegation is implied.
