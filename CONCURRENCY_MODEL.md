# The async.nvim Concurrency Model

async.nvim is for writing asynchronous Lua code in a structured way. Async work
runs inside tasks. A task can pause while it waits for timers, I/O,
subprocesses, or other tasks, then resume later on the event loop.

That scheduling flexibility has a cost. Work can fail after the function that
started it has moved on. Work can also keep running after its result no longer
matters. async.nvim handles both cases with task ownership: a task owns the
child tasks it starts, waits for them before it finishes, receives unhandled
child failures, and closes child work when it is closed.

Examples assume `local async = require('async')`. They use one editor-shaped
workflow: loading `notes.txt`, reading `settings.json`, and refreshing a
project index.

The model builds in layers. First, the event loop explains when Lua code can
run. Then tasks explain ownership. Checkpoints explain when a task yields, when
child work starts, and when cancellation or failure is delivered. Scope behavior
follows from those pieces.

## Event Loop Model

An event loop lets one thread track many operations that finish later. The
program starts a timer, file read, or subprocess, then returns to the loop
instead of blocking. When the operation is ready, the loop runs its registered
callback.

That lets many waits be pending at once without a thread for each wait. It also
keeps other work moving while one operation waits. In an editor or other UI, a
file operation, subprocess, or timer can wait in the background without blocking
the interface.

Only one callback runs at a time. The event loop takes one ready callback, runs
it until it returns, then moves to the next ready callback. That keeps Lua
execution single-threaded and predictable, but a long-running callback still
blocks everything else until it returns.

async.nvim tasks run on that callback loop. When a task awaits a timer, I/O
operation, or another task, async.nvim saves its Lua stack and returns control to
the loop. Other ready callbacks can run while the task is paused. When the
awaited work completes, async.nvim schedules the saved stack to resume.

This is cooperative scheduling: a task gives control back only when it returns,
errors, or reaches a [checkpoint](#checkpoints). At a checkpoint, async.nvim can
suspend the current stack, start child work, deliver cancellation or child
failures, and later resume the task on another event-loop turn.

Nothing interrupts synchronous Lua code in the middle of a stack frame.

```lua
async.run(function()
  print("runs now")
  async.sleep(1)
  print("runs after the event loop resumes this task")
end)
```

## Tasks and Child Tasks

`async.run(fn)` creates a task. A task is both a handle for one async operation
and a scope that owns child tasks created inside it.

Keep three boundaries separate:

- creating a task decides who owns it
- reaching a parent checkpoint decides when an attached child starts
- awaiting a task observes its result, but does not change who owns it

```lua
local open_notes = async.run(function()
  local notes = async.run(load_file, "notes.txt")
  async.await(notes)
end)
```

A task created while another task is running is attached to the running task as
a child, but its function does not run right away. It first runs when the parent
reaches a checkpoint. Top-level tasks are not attached to a parent, so no parent
checkpoint delays them; they start immediately. Attachment creates ownership:
the parent waits for each child, receives unhandled child failures, and closes
child work when the parent closes.

Ownership follows the task that is currently executing Lua code. A synchronous
Lua callback still runs on the current task stack, so tasks created there are
attached children:

```lua
async.run(function()
  for_each(paths, function(path)
    async.run(function()
      load_file(path)
    end)
  end)
end)
```

Callbacks invoked later by the event loop are different. By then the original
task stack has returned to the loop, so tasks created there are top-level:

```lua
async.run(function()
  async.await(function(done)
    schedule_later(function()
      async.run(refresh_index) -- top-level
      done()
    end)
  end)
end)
```

Awaiting a task waits for and observes its result; it does not attach the task
to the awaiter or change ownership.

```lua
-- Created outside `open_notes`, so this is top-level work.
local top_level = async.run(function()
  refresh_index()
end)

local open_notes = async.run(function()
  -- Created inside `open_notes`, so this is an attached child.
  local notes = async.run(function()
    load_file("notes.txt")
  end)

  async.await(notes)
  -- Awaiting observes `top_level`; it does not make it a child of `open_notes`.
  async.await(top_level)
end)
```

`top_level` is not attached to or owned by `open_notes`, even though
`open_notes` awaits it.

Use `detach()` when work should no longer be owned by the current parent. The
detached task becomes top-level work. The original parent no longer waits for
it, closes it, or receives its failures.

```lua
local index_refresh = async.run(function()
  while true do
    refresh_index()
    async.sleep(1000)
  end
end):detach()
```

## Checkpoints

A checkpoint is the only place where a running task yields back to async.nvim.
For attached children, the parent's next checkpoint is also the start point.
Checkpoints are where cancellation is observed and unhandled child failures are
delivered.

Inside a task, these operations are checkpoints:

- `await(...)`
- `pawait(...)`
- `checkpoint()`
- successful return from the task function, which is the final checkpoint for
  child management

Convenience APIs such as `sleep(...)` and `timeout(...)` may also checkpoint
because they call one of these internally.

Attached child tasks are owned immediately, but their function does not run
until the parent reaches a checkpoint. This gives the parent a chance to set the
failure boundary before child code can fail.

```lua
async.run(function()
  local child = async.run(function()
    return load_cached_file("notes.txt")
  end)

  local ok, text = async.pawait(child)
  if not ok then
    text = read_file("notes.txt")
  end
  show_buffer(text)
end)
```

Here `pawait(child)` is the parent checkpoint that controls both child start and
failure observation. The order is:

1. The parent creates `child`. The child is owned by the parent, but its body
   has not run yet.
2. The parent calls `pawait(child)`. That call is a checkpoint.
3. async.nvim starts `child` at the checkpoint and suspends the parent until
   `child` completes.
4. Because the checkpoint is `pawait(child)`, a child failure is returned as
   `false, err` instead of becoming an unhandled parent failure.

If a parent returns successfully, any remaining pending children start before
the parent implicitly waits for attached child work. If the parent errors or
closes before a pending child starts, that child is closed without running user
code.

Other APIs interact with task start, but they are not parent checkpoints:

- `task:detach()` removes a pending child from its parent and schedules it as
  top-level work.
- `task:wait(...)` is a synchronous edge. It starts the task being waited on and
  pumps the event loop.
- `task:close()` marks a task as closing.

## Scope Behavior

Attached children are part of their parent's scope. Once attached, child work is
managed by that parent: the parent waits for children, unhandled child failures
fail the parent, and closing the parent closes its children.

### Parents Wait for Children

A parent task cannot complete while attached children are still running.

```lua
local open_notes = async.run(function()
  async.run(function()
    local text = load_file("notes.txt")
    show_buffer(text)
  end)

  async.run(function()
    local text = read_file("settings.json")
    apply_config(parse_config(text))
  end)

  print("started editor setup")
end)

open_notes:wait() -- waits for both children
```

The parent body reaches the end after `print(...)`, but `open_notes` completes
only after the file load and config read complete.

### Child Failures Fail the Parent

The first child failure that is not handled by the parent marks the parent as
failed. The parent closes remaining child work, waits for cleanup, and completes
with that child failure.

```lua
async.run(function()
  async.run(function()
    async.sleep(10)
    error("notes.txt changed while loading")
  end)

  async.run(function()
    while true do
      refresh_index()
      async.sleep(1000)
    end
  end)

  async.sleep(100)
end)
```

`sleep(100)` calls `await(...)`, so it gives child work a checkpoint to run. If
the notes child fails, that failure is delivered to the parent and the index
refresh child is closed.

If the parent function itself fails, the same cleanup rule applies. Started
children are closed and awaited for cleanup. Pending children are closed without
running user code.

### Closing Flows Down

Closing a task closes its attached children.

```lua
local open_notes = async.run(function()
  local notes = async.run(load_file, "notes.txt")

  async.run(function()
    while true do
      refresh_index()
      async.sleep(1000)
    end
  end)

  async.await(notes)
end)

open_notes:close()
```

Closing `open_notes` closes any load or refresh work that is still attached to
it.

Cancellation is cooperative. `close()` marks a task as closing; it does not
interrupt another task in the middle of a function call.

If the task is waiting at a checkpoint, that wait is interrupted. If async.nvim
owns a closable operation for that wait, such as a timer or attached child task,
it closes that operation first. If cleanup succeeds, the checkpoint reports
cancellation with the Lua error value `"closed"`; if cleanup fails, the cleanup
error is reported instead.

If the task has not started yet, it is closed without running its function.

## Awaiting Work

Awaiting is an observation boundary, not an ownership boundary. `await(...)`
suspends the current task until an operation completes. It accepts:

- another task
- a callback-taking function
- an argument position plus a callback-taking function

The API keeps async checkpoints separate from synchronous waits:

| API | Context | Behavior |
| --- | --- | --- |
| `async.await(...)` | Inside a task | Suspend at an async checkpoint. |
| `async.pawait(...)` | Inside a task | Protected await for recoverable awaited failures. |
| `task:wait(timeout)` | Synchronous code | Pump the event loop until the task completes or times out. |
| `task:pwait(timeout)` | Synchronous code | Protected synchronous wait. |
| `task:on_complete(cb)` | Any context | Observe completion without blocking or starting a pending child task. |

`await(task)` fails with a Lua error if the awaited task failed or was closed.

`pawait(...)` is protected await: the async counterpart to `pcall`. It accepts
the same forms as `await(...)` and returns a leading `ok` boolean instead of
failing the task for an awaited-operation failure:

```lua
local ok, value_or_err = async.pawait(task)
```

On success it returns `true` followed by the awaited values. On failure it
returns `false, err`. Use `pawait()` when awaited work may fail and the current
task should keep running.

`pawait()` only protects the awaited operation. It does not protect
cancellation or already pending failure from the current task; those are task
state and are still delivered at checkpoints.

### Callback APIs

`await(...)` can adapt callback APIs directly. The argument-position form inserts
async.nvim's callback at a specific argument position:

```lua
async.run(function()
  local err, stat = async.await(2, fs_stat, "notes.txt")
  assert(not err, err)
  print(stat and stat.type)
end)
```

Callback results are returned unchanged, so error-first callbacks expose their
leading error slot to the caller.

When an awaited callback starts cancellable work, return that work's handle. A
handle is closable when it provides a `close` method that accepts a callback to
run after closing completes. async.nvim owns that handle while the task is
suspended at the checkpoint.

```lua
async.run(function()
  local err, text = async.await(function(done)
    local handle = read_file_async("notes.txt", done)
    return handle
  end)
  assert(not err, err)
  show_buffer(text)
end)
```

### Explicit Checkpoints and Synchronous Waits

`checkpoint()` explicitly yields at a checkpoint without waiting for another
operation. Use it after cleanup to re-deliver persistent task failure or
cancellation.

From synchronous code, use `task:wait(...)` or `task:pwait(...)`. `wait()` fails
with a Lua error on task failure or timeout. `pwait()` is the method-friendly
form of `pcall(task.wait, task, timeout)`.

## Recovering from Failure

Put recoverable async work in its own task and await that task with protected
await (`pawait()`). The child task becomes the failure boundary.

```lua
async.run(function()
  local ok, result_or_err = async.pawait(async.run(function()
    local text = read_file("settings.json")
    return parse_config(text)
  end))

  if not ok then
    use_fallback(result_or_err)
    return
  end

  apply_config(result_or_err)
end)
```

Its failure becomes `false, err` instead of failing the parent.

If failure is part of normal control flow, return it as data instead of raising:

```lua
local function load_config()
  local text, err = read_config_file("settings.json")
  if not text then
    return nil, err
  end

  local ok, config = pcall(vim.json.decode, text)
  if not ok then
    return nil, config
  end

  return config
end
```

Raw `pcall` is still useful for synchronous work, but it is not the right
boundary for recoverable async work. While a task is paused at an await, other
children in the same scope may run. If one fails, that failure is delivered to
the parent at a checkpoint, where a surrounding `pcall` can catch it even though
the error came from another child.

```lua
async.run(function()
  local _index = async.run(function()
    async.sleep(10)
    error("index reload failed")
  end)

  pcall(function()
    async.sleep(100)
  end)

  async.sleep(1)
end)
```

async.nvim keeps child failure and cancellation level-triggered: catching one
delivery does not clear the parent task's failed or closing state. Later
checkpoints still observe that state.

Use `pcall` for cleanup after current task cancellation or failure. Treat it
like `try/finally`: clean up, then call `checkpoint()` to re-deliver persistent
task state.

```lua
async.run(function()
  local index_refresh = async.run(function()
    while true do
      refresh_index()
      async.sleep(10)
    end
  end)

  local ok, err = pcall(function()
    async.await(index_refresh)
  end)
  stop_index_status()

  async.checkpoint()

  if not ok then
    error(err, 0)
  end
end)
```

If the current task is closing or already failed, `checkpoint()` fails before the
manual rethrow. The final `error(err, 0)` handles ordinary body failures that
are not persistent task state.

## Coordinating Tasks

The coordination helpers operate on task handles. They do not change the
ownership rules from earlier sections.

### Completion Order with iter()

`iter(tasks)` waits for existing task handles and yields the handles in
completion order. It does not return task values or raise task failures. Use
`await(task)` or `pawait(task)` to get each completed task's result.

For recoverable fan-out, use detached tasks so each yielded handle is the
failure boundary.

```lua
async.run(function()
  local cache = async.run(load_cached_file, "notes.txt"):detach()
  local disk = async.run(read_file, "notes.txt"):detach()

  local next_task = async.iter({ cache, disk })
  local winner = next_task()
  local ok, result_or_err = async.pawait(winner)

  if winner == cache then
    disk:close()
  else
    cache:close()
  end

  if not ok then
    error(result_or_err, 0)
  end

  return result_or_err
end)
```

### Deadlines with timeout()

`timeout(duration, task)` awaits a task with a deadline. If the task completes
first, `timeout()` returns or raises the task result as a normal await would. If
the deadline wins, the task is closed and `timeout()` fails with the Lua error
value `"timeout"`.

```lua
local result = async.run(function()
  local task = async.run(read_file, "notes.txt")
  return async.timeout(5000, task)
end):wait()
```

### Limits with semaphore()

`semaphore(permits)` bounds how many tasks can enter a section at once:

```lua
async.run(function()
  local semaphore = async.semaphore(3)
  local paths = list_project_files()
  local tasks = {}

  for i = 1, 10 do
    tasks[i] = async.run(function()
      semaphore:with(function()
        read_file(paths[i])
      end)
    end)
  end

  for task in async.iter(tasks) do
    async.await(task)
  end
end)
```

Lua code is still single-threaded. The semaphore limits how many tasks may be
suspended inside the section at the same time, which is useful for external
work such as requests, processes, or file operations.

## Runtime Integration

In Neovim, async.nvim is initialized automatically from `vim.wait`,
`vim.schedule`, and `vim.uv.new_timer`.

Outside Neovim, configure the event-loop hooks explicitly:

```lua
local async = require('async')

async.config({
  wait = my_wait_implementation,
  schedule = my_schedule_implementation,
  new_timer = my_timer_factory,
})
```

The runtime hooks do separate jobs:

- `schedule(callback)` posts work to a later event-loop turn.
- `wait(timeout, predicate)` pumps the event loop while synchronous code waits
  for a task.
- `new_timer()` creates timers for `sleep(...)` and `timeout(...)`.

## Relationship to Other Models

Tasks are backed by stackful Lua coroutines, so a task can suspend from deep
inside regular Lua function calls. Only the boundary needs to create an async
task; helper functions do not need an `async` keyword just because something
deeper in the call stack may await.

async.nvim is closest in spirit to Python Trio, Kotlin `coroutineScope`, and
Swift task groups: child work is owned by a scope, parents wait for children,
errors propagate, and cancellation flows down.

The shape is different because Lua has stackful coroutines and no async syntax.
`async.run()` creates both the task and the scope; there is no separate nursery
object.

JavaScript promises and Go goroutines are more unstructured by default. Work can
outlive the function that started it unless the programmer manually tracks it.
async.nvim makes ownership the default and uses `detach()` for the cases that
really need unowned background work.

## Semantic Invariants

The model depends on these invariants:

- An attached child has exactly one parent until that child completes or
  detaches.
- A parent does not complete before its attached children complete.
- Top-level tasks start immediately. Attached children start at parent
  checkpoints.
- The first unhandled child failure marks the parent as failed.
- Cancellation is persistent and is delivered at checkpoints.
- Awaiting a task observes its result but does not change its owner.
- A checkpoint owns the closable operation it is awaiting. If the task is
  cancelled while suspended there, async.nvim closes that operation.
