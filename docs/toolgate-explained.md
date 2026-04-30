# `Agent.ToolGate` — explained for a Zig junior

This is a deep dive on **one struct**: `Agent.ToolGate` in
`franky/src/agent/agent.zig`. It's only ~10 lines of code, but it
quietly solves several thorny problems at once. Understanding it
will teach you a couple of patterns you'll see again and again in
real-world Zig systems code.

---

## 1. The problem it solves

Franky's `Agent` runs a loop:

```
┌─────────┐  prompt  ┌──────────┐  tool call  ┌────────┐
│  user   │ ───────▶ │  Agent   │ ──────────▶ │  tool  │
└─────────┘          │  (loop)  │ ◀────────── └────────┘
                     └──────────┘   result
```

When the model says "call `write` with these args", the loop is
**about** to invoke the tool function — but maybe the user wants
to *intercept* that and decide first. Maybe:

- the CLI wants a Yes/No prompt in the terminal
- franky-do wants to post a Slack message and wait for an emoji
  reaction
- a future test harness wants to record every attempt
- a security wrapper wants to deny `bash` outside a sandbox

The Agent class **must not know about any of those**. It should
just say: *"Hey, anyone watching? This tool is about to run. Block
it or let me through."*

That "anyone watching" object is `ToolGate`.

---

## 2. The struct itself

```zig
pub const ToolGate = struct {
    userdata: ?*anyopaque = null,
    before_tool_call: ?loop_mod.BeforeToolCallFn = null,
    role_denied: ?loop_mod.RoleDeniedFn = null,
};
```

Three fields:

1. **`userdata`** — an opaque pointer to *whatever object you want
   to carry along*. The Agent treats it as a black box.
2. **`before_tool_call`** — a function pointer. Gets called before
   each tool execution. Returns "block / allow".
3. **`role_denied`** — a function pointer. Called when the model
   names a tool that doesn't exist (or is forbidden) so the caller
   can produce a structured error.

Both function-pointer fields are `?` (optional). You can wire one,
both, or neither.

The function signatures (from `loop.zig`):

```zig
pub const BeforeToolCallFn = *const fn (
    userdata: ?*anyopaque,
    tool: *const at.AgentTool,
    call_id: []const u8,
    args_json: []const u8,
) HookDecision;

pub const RoleDeniedFn = *const fn (
    userdata: ?*anyopaque,
    tool_name: []const u8,
) ?RoleDenial;
```

Notice both functions take `userdata` as their **first argument**.
That's the key.

---

## 3. The pattern: "C-style callback with closure"

Zig has function pointers (`*const fn(...)`) but it does **not**
have closures the way JavaScript or Python do. You can't write:

```zig
const slack_channel = "C123";
const cb = fn(tool) {
    // capture slack_channel from outer scope ← NOT POSSIBLE IN ZIG
    postToSlack(slack_channel, tool);
};
```

So how do you pass *state* into a callback? You use the **userdata
trick**, which is the dominant pattern in C and in low-level Zig.
It works like this:

1. The callback signature always has `userdata: ?*anyopaque` as
   its first parameter.
2. The caller registers `(callback, userdata)` together as a pair.
3. When the framework calls the callback, it hands `userdata` back
   verbatim. The callback casts it to a known struct type and now
   has access to all the state it needs.

```zig
// Define your state.
const SlackContext = struct {
    channel: []const u8,
    api_client: *SlackClient,
};

// Allocate it somewhere with a stable address.
var ctx = try allocator.create(SlackContext);
ctx.* = .{ .channel = "C123", .api_client = &api };

// Define a *static* callback that knows how to unpack the context.
fn myCallback(
    userdata: ?*anyopaque,
    tool: *const AgentTool,
    call_id: []const u8,
    args_json: []const u8,
) HookDecision {
    const self: *SlackContext = @ptrCast(@alignCast(userdata.?));
    self.api_client.post(self.channel, tool.name);
    return .{ .block = false };
}

// Register them together.
agent.tool_gate = .{
    .userdata = @ptrCast(ctx),
    .before_tool_call = myCallback,
};
```

**The pattern**: function pointer + `void*` context = poor man's
closure. C has used it since 1972. Zig embraces it because the
alternative — heap-allocating closure environments — clashes with
the "explicit allocator" philosophy.

You will see this pattern in:

- `pthread_create(thread, attr, fn, arg)` — POSIX threads
- `qsort(base, n, sz, comparator)` — actually `qsort_r` for the
  context version
- `glfwSetKeyCallback(window, fn)` plus `glfwGetWindowUserPointer`
- All of GTK, GLib, and Linux kernel callbacks

It's *the* C ecosystem callback ABI. Master it and you can read
any of those.

---

## 4. Why `?*anyopaque` and not `*MyType`?

Couldn't we just say `userdata: *SessionGates` and skip the cast?
We could… but only at the cost of one of franky's hard rules:

> **Layering is one-way.** `agent` must not import `coding`.

The `Agent` class lives in `src/agent/`. The `SessionGates` type
lives in `src/coding/permissions/`. If `agent.zig` named
`SessionGates` directly, `agent` would *depend on* `coding` — the
arrow points the wrong way.

By using `?*anyopaque`, the `Agent` says: *"I don't care what type
this is. The caller knows; I just hand it back."* That's a
**type-erasure boundary**. The callback is the only code that
needs to know the real type, and that callback lives in the
caller's module — `coding/permissions.zig` for franky-CLI, or
`bot.zig` for franky-do — not in `agent.zig`.

This is the same trick `std.http.Server` uses for its handler
context, the same trick `std.Thread.spawn` uses, the same trick
basically every C library uses for callback context. Type erasure
is how you decouple modules that need to call each other but must
not know about each other's types.

```
┌─────────────┐                ┌─────────────┐
│   agent/    │                │   coding/   │
│             │  (knows about) │             │
│   Agent ────┼──── ToolGate   │ SessionGates│
│             │                │             │
│             │   ?*anyopaque  │             │
│             │ ◀──────────────┤   (knows    │
│             │  type-erased   │   Agent's   │
│             │  pointer       │   ToolGate) │
└─────────────┘                └─────────────┘
       ▲                              │
       │                              │
       └──────────────────────────────┘
                imports allowed
```

`agent` knows nothing about `coding`. `coding` plugs into
`agent.tool_gate` from the outside. The arrow is one-way.

---

## 5. The "multiple lifetimes" thing

You asked about *why it has multiple lifetimes*. Here's where it
gets interesting.

When franky-do creates an `Agent`, three things have to live long
enough to be safely pointed at:

| Object | Who owns it | How long it lives |
|---|---|---|
| `Agent` | `agent_cache.Cache` (heap-allocated) | until session evicted/hibernated |
| `SessionGates` | per-Agent heap allocation | **same as Agent** |
| `Store` | bot-wide singleton in `cmdRun` | **whole process** |
| `PermissionPrompter` | per-mention worker stack frame (Phase 2) | **just one mention** |

So `tool_gate.userdata` is a pointer to `SessionGates`, which
itself **contains a pointer** to `Store` (process-lifetime) and
optionally a pointer to `PermissionPrompter` (mention-lifetime).
The Agent's gate stays valid because:

- The Agent **outlives** the prompter's stack frame? No — but the
  prompter only writes to `gates.prompter` during a turn that the
  mention worker is *currently blocked on*. The prompter cannot
  disappear while the agent is calling tools, because the mention
  worker is inside `agent.waitForIdle()` waiting for that exact
  call to resolve. Lifetime is **structurally** guaranteed by the
  call graph.
- The Store is a process singleton; it outlives every Agent.
- The `SessionGates` itself lives on the heap, allocated when
  `ensureAgent` mints the Agent and freed when the Agent is
  evicted from the cache (or the cache deinits). Lifetime tied to
  the Agent — exactly what we want.

So three lifetimes coexist behind one `?*anyopaque`:

```
process ──────────────────────────────────────────────────▶
   Store ───────────────────────────────────────────────▶
   
   (per-Agent) ─────────────────────▶
       SessionGates ─────────────────▶  ← this is what userdata points at
           .permissions = &Store     ← long-lived ref
           .prompter   = &P or null
   
   (per-mention)  ─────▶
       PermissionPrompter
```

The **userdata pointer never changes** for the life of the Agent.
What changes is what `gates.prompter` *points at* — but that's
mutation of a field inside the gate, not of the gate's address.
The Agent's `tool_gate.userdata` is set once at `ensureAgent` time
and stays valid until the Agent is freed.

That stability matters because the Agent's worker thread reads
`tool_gate.userdata` from a *different thread* than the one that
set it. If the address could move (e.g. if we stored
`SessionGates` by value on a stack frame that returned), we'd
have a use-after-free. By heap-allocating `SessionGates` and
keeping the heap address stable, we make the cross-thread read
safe without any locking on the pointer itself.

This is a critical Zig habit: **heap-allocate any state that
outlives its creating function and is reachable from multiple
threads via a stable address.** Stack-allocated locals can move
or vanish; heap addresses are stable until you free them.

---

## 6. Why three pointer indirections?

If you're new to systems code, the chain
`tool_gate.userdata → SessionGates → Store` looks fussy. Why
not just put `Store` directly in `userdata`?

Because each indirection earns its keep:

- **`tool_gate.userdata → SessionGates`**: lets *each Agent* have
  its own per-session state (e.g. once-per-session "always allow"
  decisions, the currently-active prompter for *this* mention).
  Two concurrent mentions on different threads each get their own
  `SessionGates` and don't interfere.
- **`SessionGates → Store`**: shares the always-allow / always-deny
  database across all sessions in the workspace. A user typing
  "always allow `read`" in one Slack thread should benefit every
  thread.
- **`SessionGates → PermissionPrompter` (nullable)**: the prompter
  only exists *during a turn*. Outside of a turn, there's nobody
  to ask. The nullable field means the gate can refuse cleanly
  ("permission gate active — no prompter wired") instead of
  null-deref'ing.

Each pointer = one degree of independent lifetime. That is the
shape of real-world ownership in concurrent code.

---

## 7. Putting it all together — the call sequence

Here's a tool call from start to finish:

```
1. Slack user @franky-do "edit /etc/passwd"
2. franky-do mention worker starts a turn:
     agent.prompt("edit /etc/passwd")
3. Agent worker thread runs a turn, model emits:
     tool_use { name: "edit", args: {...} }
4. Loop is about to execute the edit tool. It checks:
     if (cfg.before_tool_call) |fn| {
         const decision = fn(beforeToolCallUserdata(cfg), tool, ...);
         if (decision.block) … emit synthetic error, skip the call
     }
5. `beforeToolCallUserdata(cfg)` returns:
     cfg.before_tool_call_userdata orelse cfg.hook_userdata
   For franky-do, that's the SessionGates pointer.
6. The function pointer is SessionGates.beforeToolCall (a static
   method). It receives the SessionGates via userdata, casts it,
   reads `gates.permissions` (the Store), checks always-allow.
7a. If always-allowed → returns block=false, tool runs.
7b. If always-denied → returns block=true with a deny reason.
7c. If neither, AND gates.prompter is set → calls prompter.ask(...)
    which (Phase 2) posts to Slack and blocks until reaction.
7d. If neither, AND gates.prompter is null → returns the standard
    refusal ("permission gate active — use --yes / --allow-tools").
8. Loop receives HookDecision, acts accordingly.
9. On block, a synthetic error tool result is fed back to the
   model. On allow, the tool runs as normal.
```

Everything from step 4 onward happens **on the Agent worker
thread**, while the original mention worker thread is parked in
`agent.waitForIdle()`. The two threads communicate via:

- the `tool_gate.userdata` pointer (read by Agent worker, written
  by mention worker before `prompt` was called)
- the `prompter.ask()` channel/condvar (Agent worker sends a
  request, Phase-2 mention worker drains the prompt, posts to
  Slack, waits for reaction, calls `prompter.resolve()`)

The whole thing is glued together with one opaque pointer and two
function pointers. No closures, no inheritance, no virtual
methods. Just C-style callbacks done well.

---

## 8. Checklist — recognizing this pattern in the wild

When you see code like this in Zig (or C, or Rust FFI):

```zig
pub const SomeHook = struct {
    userdata: ?*anyopaque = null,
    callback: ?*const fn(?*anyopaque, /* ...args... */) Result = null,
};
```

It's almost always:

- **Type erasure** — the callee doesn't know the caller's type.
- **C-ABI compatible** — could be called from C or another
  language.
- **Decoupled** — the framework module doesn't import the
  consumer module.
- **State-carrying** — `userdata` smuggles closure variables in.
- **Lifetime-flexible** — different fields of `*userdata` can
  point at objects with completely different lifespans.

Once you spot this, you'll see it everywhere. It's the workhorse
extension point of the entire C/Zig ecosystem.

---

## 9. TL;DR

`Agent.ToolGate` is a tiny three-field struct that is a
**callback-with-context** wired into the agent loop. It uses:

- **Type erasure (`?*anyopaque`)** to keep the `agent → coding`
  layering one-way.
- **Function pointers** because Zig has no closures.
- **Heap-allocated `SessionGates`** at a stable address so the
  Agent's worker thread can safely read it from another thread.
- **Nested lifetimes** (process-wide `Store`, per-Agent `Gates`,
  per-mention `Prompter`) glued together by ordinary pointer
  fields, each pointer sized to the lifetime of the thing it
  points at.

Read the implementation in three steps:

1. `agent.zig` lines 116–130 — the struct itself.
2. `loop.zig` lines 133–143 — the function pointer signatures.
3. `coding/permissions.zig`'s `SessionGates.beforeToolCall` — a
   real implementation that downcasts `userdata` and uses it.

Once you grasp those three, every other "callback with userdata"
pattern in Zig will read at sight.
