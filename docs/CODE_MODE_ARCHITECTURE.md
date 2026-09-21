# Lua Code Mode

Status: target contract with sequential composition as the baseline. The prototype
already executes sequential Lua child calls. Public task handles, discovery helpers,
and filtered advertisement are future additions, not prerequisites for keeping Code
Mode useful. See [implementation status](ARCHITECTURE_STATUS.md).

Code Mode is one tool, `builtin_code({code = ...})`, that composes ordinary tools in
one model invocation. Its benefit is fewer model round trips and less intermediate
context. It is not a second agent, workflow engine, persistent notebook, or plugin
runtime. Native Odin owns execution policy and durability; embedded `vendor:lua/5.4`
executes the script. No second scripting language or runtime service.

## Sequential contract

A fresh restricted Lua state executes a text-only chunk. Tool wrappers take exactly
one argument object, with no arguments normalized to an empty object. They yield to
the owner, which admits an ordinary child call, runs it, commits its result, and
resumes Lua with the complete common envelope.

```lua
local file = tools.builtin_read({path = "README.md", limit = 100})
if file.status ~= "success" then
    return file
end
return file.data
```

The script looks sequential; the session owner never blocks waiting for the child.
The waiting parent occupies no worker slot or backend lane. Only an owner-selected
Lua-slice effect calls `lua_resume`. A tool wrapper or completion callback cannot
recursively drive the tool machine or make a model request.

Each invocation has private globals. Return zero or one value; no return means JSON
null, and multiple values fail explicitly. The parent returns selected output,
bounded printed logs, truncation facts and compact child-call references. It does
not concatenate every child's output. Errors retain the references to effects already
performed, including an omitted-reference count if the summary itself is bounded.

A child failure is a value the script may inspect. Syntax, runtime, conversion or
resource failure ends the script with a typed Code Mode diagnostic inside the ordinary
tool envelope. Failure after earlier children ran is not Invalid_Arguments for the
whole parent. A script cannot undo those effects by throwing or returning a failure.

## Shared job and durability rules

Use [execution](EXECUTION_ARCHITECTURE.md) and [tool admission](TOOLS_MCP_ARCHITECTURE.md)
unchanged. The only extra durable relationship is child call to earlier parent call
in the same session and turn. Child dispatch/result records refer to that child's
call. Internal child IDs cannot collide with provider IDs.

The provider sees the root Code Mode call and result. Hidden child calls/results stay
in the same store for inspection, paging and crash recovery. Filter them using their
own relationship, including when the parent lies outside the loaded context tail.
Do not invent assistant messages for host-program calls.

Child commit enables parent resumption. Parent settlement follows child settlement;
root ordering still follows the model's call order. There is no single global ordinal
that puts a waiting parent before its child. Retirement of producer storage remains
separate from result availability. Keep parent/child references as identities rather
than pointers into released execution records.

On restart, close unanswered calls from dispatch evidence and never resume or replay
the chunk. Tool outcomes survive; the Lua stack does not. Persisting instructions is
not sufficient to replay side effects safely.

## Lua and Odin ownership

One main state and a registry-rooted coroutine belong to one Code Mode execution.
The owner alone accesses Lua. Configuration evaluation uses a different state and
capability set. A shared binding implementation is useful; a shared mutable VM is not.

C callbacks yield a small typed host request. After `lua_resume` returns, host code
validates/copies its data before the next resume. Tool execution and SQLite writes
happen outside callbacks. Lua errors and yields can bypass Odin stack cleanup, so
callbacks hold no Odin resources that depend on `defer` unwinding.

Every allocation-capable host entry needs a protected error path: state setup,
compilation, helper installation, argument/result conversion and error formatting.
A fixed emergency reserve can make a bounded error report more likely, but is not
proof of recoverable OOM. Prove the protected paths with allocator-failure tests.
Do not use a panic handler as an exception bridge into Odin.

Copy Lua strings by explicit length. Do not retain pointers to Lua storage through
mutation or collection. Worker input owns its arguments and immutable execution
facts until retirement. Result injection consumes committed result bytes with explicit
presence and error values; an empty string is not an allocation-failure sentinel.

Use separate accounting for Lua-managed memory and Odin conversion/queued output.
A Lua heap limit does not bound host memory, child output or kernel resources.

## Boundary values

One checked Lua/JSON conversion serves arguments, tool results and the parent return.
Use `core:encoding/json` rather than a parallel host object model. Validate strict
JSON where the parser accepts broader syntax.

| Value | Contract |
| --- | --- |
| Boolean and string | Preserve; strings/keys must be UTF-8 and retain embedded NUL by escaping |
| Number | Finite and exactly representable through the actual Lua/JSON path; refuse before lossy conversion |
| Object | String-keyed table; empty plain table means object |
| Array | Dense one-based table; preserve empty-array identity with a host marker/helper |
| Null | Host sentinel distinct from Lua nil/missing field |
| Function, thread, arbitrary userdata, future task handle | Refuse at the serialized data boundary |
| Sparse/mixed table, cycle, script metatable | Refuse with a bounded path diagnostic |

Use raw table access so serialization cannot run script code. Shared acyclic tables
may be copied as values, but bound depth, traversed values and expanded bytes so
repeated references cannot explode host work. Lua's integer width alone does not
establish JSON numeric precision. Check the installed parser/encoder at both ends.
Do not opportunistically parse a tool's text field as another JSON result.

## Limits and authority

Keep named limits in concrete harness policy. The current defaults are starting
values, not measurements: 32 KiB source, 32 MiB Lua heap, 10 million instructions,
10,000-instruction slices, 120 seconds including child waits, and 8 KiB retained
print logs. The shared tool result cap includes logs and call summaries. The shared
batch admission and byte limits include all children; no per-script exemption.
Tune values only with representative loop/filter workloads and failure tests.

A count hook returns control to the owner. Cancellation, deadline, memory and
instruction stops latch outside script control. Never resume a stopped run. An
error that user code can catch indefinitely is not enforcement. Instruction hooks
do not bound long C-library calls, and some C frames cannot yield. Restrict or bound
expensive library operations rather than claiming a hard CPU limit from hook counts.

Start from an allowlist of necessary base/string/table/math/UTF-8 functions and
bounded JSON/print helpers. No `io`, `os`, `package`, `debug`, dynamic loading,
bytecode loading/dumping, public coroutine control, user finalizers or metatable
mutation. Any addition must preserve stop and conversion guarantees. Do not open all
libraries and maintain a growing blacklist.

Scripts receive only eligible tool wrappers. Refuse Code Mode recursion at admission,
not just by hiding its name. Keep compaction intent direct-only until a nested use has
a defined boundary; result paging can use the ordinary short owner operation.
Credentials stay in host clients. Exposing shell still exposes shell's process
permissions and environment. Restricted Lua is not an OS sandbox or protection from
a compromised native runtime. For forcible termination or hostile-code isolation,
use a Linux process boundary, not another interpreter or mutex.

## Discovery and advertisement

The baseline may advertise direct tools alongside Code Mode. Changing advertisement
is a configuration policy, not another registry. A future Code-Mode-focused view can
advertise Code Mode plus necessary context controls and expose other capabilities
through bounded `catalog.search` and `catalog.describe` helpers in Lua.

Those helpers must read the frozen registry, page descriptors and include exact
callable names, schemas and eligibility. Use deterministic text matching, not
embeddings, generated type SDKs, or a filesystem tool catalog. Do not promise output
schemas that MCP/native definitions do not supply. Add discovery when inventory size
makes it useful, not as a prerequisite to composing four tools.

Loaded instructions inside Lua are not automatically instructions the model has seen.
A script must return the complete skill body or let the model retrieve it before a
later model-authored action relies on it. Loading a skill and immediately executing
an already-authored action does not establish instruction compliance.

## Future explicit concurrency

Do not implement task handles as part of a cleanup or sequential-runtime fix. If
measured workloads justify them, expose only execution-local start/await/cancel over
the existing jobs. Handles name admitted calls, never raw pointers, serialized values,
background sessions or work that outlives the parent.

Start yields for owner admission and returns a handle. Await resumes only from a
committed result; repeated await cannot execute again. Cancel requests stop and waits
for the backend's settlement/retirement contract. Returning with unconsumed tasks is
an explicit parent failure that drains children. Parent cancellation stops all children.
No parent holds a worker slot needed by its children. Native/backend lanes remain
bounded even when the script claims independence.

There is no detached model-facing wait tool, persistent VM, resumable program format,
second scheduler, or background turn on completion. Future subagents are ordinary
tools through this same path, not special Lua scheduling operations.

## Acceptance

Use separate tests for Lua boundary and shared lifecycle. Cover protected setup and
result injection failure, infinite loops, non-yieldable library work, conversion
precision/cycles, source/output limits, child storage exhaustion, cancellation while
waiting, empty output, script failure after effects, and crash recovery without
replay. Check parent references and provider omission after a checkpoint. Evaluate
valid script generation, task success, tokens and round trips against Nabla's actual
models; results from a TypeScript or fuzz-generation system do not establish Lua quality.
