# Subagent architecture

Companion to `AI_HARNESS_ARCHITECTURE.md` §12, which states the requirement. This is the
detailed design.

Status: **documented, not implemented.** No part of this exists in the code yet.

---

## 1. Invariants

1. A subagent is a **tool call**, not a configured entity.
2. **No Markdown-defined agents.** No `reviewer.md`, `coder.md`, or `planner.md`, and no fixed
   taxonomy of roles. Specialisation is expressed in the instruction.
3. Subagents run in **separate OS processes**. Threads are not isolation.
4. The invoking agent chooses `provider`, `model`, `reasoning`, and `instruction`.
5. The lifecycle supports **`spawn → handle → await`** even if the first interface awaits
   immediately.
6. A subagent's permission **cannot exceed** the parent's.
7. The public result type is **not designed before the lifecycle is implemented**.

---

## 2. Invocation

`subagent` is an ordinary tool. It appears in the tool list, its arguments are buffered and
validated before dispatch like any other call, and its result enters the conversation as an
ordinary tool result. Nothing in the loop treats it specially except that it takes a long time
and owns a process.

Arguments (validated, bounded):

| field | required | meaning |
|---|---|---|
| `instruction` | yes | The task. This is the entire role definition. |
| `provider` | no | Defaults to the parent's provider. |
| `model` | no | Defaults to the parent's model. |
| `reasoning` | no | A level validated against the resolved catalog for the chosen model. |

The instruction is the whole specialisation mechanism. "Review this patch for API compatibility"
and "Investigate this failing test and determine the likely root cause" are two different
subagents with no harness code between them.

Provider/model resolution goes through the resolved catalog exactly as a top-level selection
does. A subagent never hardcodes a provider or model.

---

## 3. Process model

```
harness process
    │  spawns
    ├── subagent process  ── framed messages over a pipe ──▶  parent
    └── subagent process
```

**The subprocess runs the harness binary in a subagent mode.** It is not a bespoke program: it
has the same tool loop, the same provider stack, and the same compaction. The parent owns only
the transport and the supervision.

Why this shape:

- **Fault isolation is the point.** A crash, panic, abort, or wedged runtime in the child must
  not take down the parent. Only a separate process gives that; a thread gives none of it.
- **`execve` rather than `fork` alone.** A bare fork duplicates the parent's threads and
  allocator state and inherits a partially initialised runtime. Executing the same binary with a
  subagent argument yields a clean address space and a single-threaded start.
- **A process-local working directory falls out for free.** The old Codegraff lesson — thread
  `agent_cwd` per call instead of calling `chdir` process-wide — is automatic when the working
  directory belongs to a process. The child may `chdir`; the parent must not.

Communication is **framed messages over a pipe**: a length-prefixed JSON object per message, both
directions. One frame format, versioned, so a mismatched child is rejected rather than
misparsed. Frames are bounded on both sides.

The parent never reads the child's conversation directly. The child owns its session; the parent
receives status, a bounded result, and optional progress.

---

## 4. Lifecycle

```
  spawn ──▶ Running ──┬──▶ Completed
    │                 ├──▶ Failed        (child reported a normal error)
    │                 ├──▶ Crashed       (abnormal termination: signal, nonzero exit, bad frame)
    │                 ├──▶ Cancelled     (we asked it to stop and it did)
    │                 └──▶ Timed_Out     (deadline passed)
    │
    └──▶ Handle (pid, pipes, deadline, parent turn identity)
```

`spawn` returns a handle. `await(handle)` returns the outcome. The first tool-facing interface
calls `spawn` and then `await` immediately, so it is synchronous from the model's point of view,
but the two are separate operations and nothing about the handle assumes the await follows at
once. That is what makes concurrency later a scheduling change rather than a redesign.

**The job record** carries, at minimum:

- parent session and turn identity
- the child's declared provider/model/reasoning, as resolved at spawn
- process id, pipe ends, and start time
- a deadline and a status
- a bounded result, or a reference to an artifact when the result is large

The record is what the parent tracks. It is not the child's conversation.

A child that produces no terminal frame and exits is `Crashed`, not `Completed`. A nonzero exit
after a well-formed failure frame is `Failed`. The distinction matters because `Crashed`
warrants reporting abnormal termination to the user while `Failed` is an ordinary result.

---

## 5. Result model

Deliberately underspecified here. The distinctions the implementation must be able to make:

- **completed** with a result
- **failed** with a normal error, distinct from a crash
- **cancelled**, distinct from a timeout
- **timed out**
- **crashed**, with the signal or exit status

What the model sees should be small: the result text, or a short failure description. Whatever
else the parent needs (exit status, timings, frame counts) belongs in diagnostics, not in the
tool result the model reads.

Do not design the public type before these are implemented and their real distinctions are
known. See §9.

---

## 6. Cancellation and escalation

Cancellation follows the existing rule: it is a **request**, and the turn settles only once the
work has retired.

```
cancel requested
      │
      ├─ tell the child to stop (frame), which lets it settle its own turn
      │
      ├─ await prompt settlement, bounded
      │
      └─ if it has not exited, terminate the process tree it owns
```

Prompt cancellation first, then forced termination, then reap. Never leave an unreaped child: a
zombie holds a process slot for the lifetime of the harness.

Parent cancellation propagates to every child the parent owns. A child that outlives its parent
turn is a bug; the deadline and the escalation path both exist to prevent it.

Children own their own subprocesses (tools they run). Terminating a child means terminating what
it started, so children are placed in their own process group at spawn.

---

## 7. Permissions

A child's authority is **at most** the parent's. Concretely:

- The child inherits the parent's policy, narrowed, never widened.
- A child cannot grant itself a capability the parent lacked, and the parent does not re-ask for
  authority it already refused.
- Approval that the parent holds for an action applies to the child only within the same scope: 
  same action, same resource, same workspace, same session.
- An instruction is not authorization. A child running an assistant-authored task cannot
  establish user intent the parent did not have.

Prompts are not isolation. If a child must be more constrained than "whatever the parent could
do", that is a sandbox decision (see §10), not a prompt.

---

## 8. Bounds and concurrency

Every one of these is bounded, and exceeding a bound fails that subagent rather than the turn:

- concurrent children
- total children spawned per turn and per session
- wall-clock deadline per child
- instruction size, frame size, and result size
- output retained per child

**Concurrency starts at serial.** Run one child at a time until there is evidence that a second
one helps. The handle design already permits more; a first version that spawns a batch and
awaits them in order is a scheduling change, not an architecture change.

The old design notes recorded the same position: local tools serially, external-agent jobs
concurrently with caps and parent/child identities.

---

## 9. What not to build

- Markdown-defined agents, agent files, or a roles directory.
- A fixed role taxonomy (`reviewer`, `coder`, `planner`) in code or configuration.
- An in-process "subagent" that is really just another thread or coroutine.
- Automatic recursive delegation. A child does not spawn children in the first version.
- A workflow engine, a job scheduler, or a process pool.
- A rich public result type before the lifecycle's real distinctions are implemented.

---

## 10. Open decisions

1. **How the parent and child authenticate.** Same environment credentials, or an explicit
   handoff of the resolved credential? The second is safer but needs a rule for what a child may
   receive. Note that credentials are resolved at connection time today and never stored in the
   catalog, so a child resolving independently from the same configuration is the simplest
   option and avoids passing secrets at all.

2. **Whether a child shares the workspace or is isolated.** Isolation in a child *process* is
   about crashes, not about files. A child editing the same files as the parent can corrupt
   parallel work. Sharing by default and making isolation explicit is the likely answer, but it
   is a product decision.

3. **OS sandboxing.** Prompts do not isolate. If a child's tools must be constrained below the
   parent's, that needs a real sandbox mechanism. Still an open decision, and deliberately out of
   scope for the first implementation.

4. **What crosses back besides the result.** Progress frames would let a long child show
   activity. Not designed here; the frame format should be versioned so it can grow.
