# The async.nvim Concurrency Model

async.nvim gives Lua a structured concurrency model for cooperative tasks. It is
not a parallel runtime: Lua code still runs cooperatively on the event loop. The
goal is to make concurrent work follow clear ownership rules, so tasks do not
leak, errors do not disappear, and cancellation reaches the work it owns.

This document describes the semantics of the model. The implementation lives in
`lua/async/_core.lua`; the public API is exported from `lua/async.lua`.

## Runtime and Event Loop

async.nvim needs three event-loop operations:

```lua
local async = require('async')

async.init({
  wait = my_wait_implementation,
  schedule = my_schedule_implementation,
  new_timer = my_timer_factory,
})
```

In Neovim this is initialized automatically from `vim.wait`, `vim.schedule`,
and `vim.uv.new_timer`.

The runtime hooks have distinct jobs:

- `schedule(callback)` posts work to a later event-loop turn.
- `wait(timeout, predicate)` pumps the event loop while synchronous code waits
  for a task.
- `new_timer()` creates timers for `sleep(...)` and `timeout(...)`.

Only one task executes Lua code at a time. A running task keeps control until it
returns, errors, or reaches an async.nvim checkpoint.

## Checkpoints

A checkpoint is a point where async.nvim regains control of the current task.
At a checkpoint, the runtime may suspend the task, start pending child tasks,
deliver cancellation or child failures, and later resume the same Lua stack.

Inside a task, these are checkpoints:

- `await(...)`
- `pawait(...)`
- `checkpoint()`
- successful return from the task function, which is the final checkpoint for
  child management

Convenience APIs such as `sleep(...)` and `timeout(...)` may also checkpoint
because they call one of these internally.

There are no preemptive checkpoints. Synchronous Lua code is never interrupted
in the middle of a stack frame.

```lua
vim.async.run(function()
  print("runs now")
  vim.async.await(vim.schedule)
  print("runs after the event loop resumes this task")
end)
```

## Stackful Coroutines and Function Coloring

Tasks are backed by Lua coroutines. Lua coroutines are stackful, so a task has
its own call stack and can suspend from deep inside regular Lua function calls:

```lua
local function fetch_user(id)
  return do_fetch("/users/" .. id)
end

local function display_user(id)
  local user = fetch_user(id)
  print(user.name)
end

vim.async.run(function()
  display_user(123)
end)
```

Only the boundary needs to create an async task. Helper functions do not need an
`async` keyword just because something deeper in the call stack may await. This
avoids much of the function-coloring pressure common in stackless async systems
such as JavaScript, Python, Swift, and Kotlin.

## Tasks and Scopes

`vim.async.run(fn)` creates a task. A task is both:

- a handle for one async operation
- a scope that owns child tasks created inside it

```lua
local parent = vim.async.run(function()
  local child = vim.async.run(worker)
  vim.async.await(child)
end)
```

The parent-child relationship is determined by where a task is created, not
where it is awaited. A task created inside another task is attached to that
parent: the parent owns it, waits for it, and closes it if the parent is closed.
A task created outside any task is top-level.

Ownership follows the task that is currently executing Lua code. If a normal Lua
callback is called synchronously inside a task, it is still part of that task's
stack, so tasks created there are attached children.

```lua
vim.async.run(function()
  for_each(items, function(item)
    vim.async.run(function()
      process(item)
    end)
  end)
end)
```

Callbacks invoked later by the event loop are different. By then the parent task
has yielded, so no task stack is executing the callback. A task started from that
callback is top-level.

```lua
vim.async.run(function()
  vim.async.await(function(done)
    vim.schedule(function()
      vim.async.run(background_work) -- top-level
      done()
    end)
  end)
end)
```

```lua
local top_level = vim.async.run(function()
  vim.async.sleep(50)
end)

local parent = vim.async.run(function()
  local child = vim.async.run(function()
    vim.async.sleep(100)
  end)

  vim.async.await(child)
  vim.async.await(top_level)
end)
```

`top_level` is not owned by `parent`, even though `parent` awaits it. Awaiting a
task observes its result; it does not change ownership.

## Starting Tasks

Top-level tasks start immediately.

Attached child tasks are different: `run()` attaches the child immediately, but
the child's function does not run until the parent reaches a [checkpoint](#checkpoints).
This gives the parent a chance to decide how it will observe the child before
child code can fail.

If the parent reaches its final checkpoint by returning successfully, any
remaining pending children start before the parent implicitly waits for attached
child work.

If the parent errors or closes before a pending child starts, that child is
closed without running user code.

```lua
vim.async.run(function()
  local child = vim.async.run(function()
    error("optional child failed")
  end)

  local ok, err = vim.async.pawait(child)
  if not ok then
    use_fallback(err)
  end
end)
```

Here the child starts after `pawait(child)` has claimed the task boundary, so
the child failure is returned as data instead of becoming an unhandled parent
failure.

Other APIs interact with task start, but they are not parent start checkpoints:

- `task:detach()` removes a pending child from its parent and schedules it as
  top-level work.
- `task:wait(...)` is a synchronous edge. It starts the task being waited on and
  pumps the event loop.
- `task:close()` marks a task as closing.

## Parent Scope Rules

Task ownership matters because attached children are part of their parent's
scope. That scope gives the parent three guarantees about lifetime, failure, and
cancellation.

### Parents Wait For Children

A parent task cannot complete while attached children are still running.

```lua
local parent = vim.async.run(function()
  vim.async.run(function()
    vim.async.sleep(100)
  end)

  vim.async.run(function()
    vim.async.sleep(50)
  end)

  print("body done")
end)

parent:wait() -- waits for both children
```

The parent function body returns quickly, but the parent task completes only
after both children complete.

### Errors Propagate Up

The first unhandled child failure marks the parent as failed. The parent closes
remaining child work, waits for cleanup, and then completes with the child
failure.

```lua
vim.async.run(function()
  vim.async.run(function()
    vim.async.sleep(10)
    error("child failed")
  end)

  vim.async.run(function()
    vim.async.sleep(1000)
  end)

  vim.async.sleep(100)
end)
```

`sleep(100)` calls `await(...)`, so it gives child work a checkpoint to run. If
the first child fails, that failure is delivered to the parent and the
long-running sibling is closed.

If the parent function itself fails, the same cleanup rule applies. Started
attached children are closed and awaited for cleanup. Pending attached children
are closed without running user code.

### Cancellation Propagates Down

Closing a task closes its attached children.

```lua
local parent = vim.async.run(function()
  vim.async.run(function()
    vim.async.sleep(1000)
    print("not reached")
  end)

  vim.async.sleep(100)
end)

parent:close()
```

Cancellation is cooperative. `close()` marks a task as closing; it is not a
preemptive interrupt. Since only one task runs Lua at a time, one task cannot
stop another task in the middle of a function call.

If the task is waiting at a checkpoint, that wait is interrupted. If async.nvim
owns a closable operation for that wait, such as a timer or attached child task,
it closes that operation first (see [Resource Cleanup](#resource-cleanup)). Then
the checkpoint reports cancellation with the Lua error value `"closed"`.

If the task has not started yet, it is closed without running its function.

## Awaiting

`await(...)` suspends the current task until an operation completes. It accepts:

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

```lua
vim.async.run(function()
  local stat = vim.async.await(2, vim.uv.fs_stat, "file.txt")
  print(stat and stat.type)
end)
```

`await(task)` fails with a Lua error if the awaited task failed or was closed.

`pawait(...)` is protected await: the async counterpart to `pcall`. It accepts
the same forms as `await(...)` and returns a leading `ok` boolean instead of
failing the task for an awaited-operation failure:

```lua
local ok, value_or_err = vim.async.pawait(task)
```

Use `pawait()` when the awaited task or operation is allowed to fail and the
current task should keep running. It does not protect cancellation or already
pending failure from the current task.

`checkpoint()` explicitly yields at a checkpoint without waiting for another
operation. Use it after cleanup to re-deliver persistent task failure or
cancellation.

From synchronous code, use `task:wait(...)` or `task:pwait(...)`. `wait()` fails
with a Lua error on task failure or timeout. `pwait()` is the method-friendly
form of `pcall(task.wait, task, timeout)`.

## `pcall` and Async Code

In ordinary synchronous Lua, `pcall` is the main recovery tool. An error unwinds
the stack until it reaches the protected call; `pcall` returns `false, err`, and
execution continues after the protected call.

Async errors are different. A task is coroutine-backed and has its own stack,
but a child failure does not unwind the child stack into the parent's current
Lua stack. async.nvim records the failure on the parent task scope and delivers
it when the parent reaches a checkpoint. `await()` maps awaited-operation and
current-task failure into Lua's error channel; `pawait()` protects only
awaited-operation failure.

This makes raw `pcall` unsafe across code that can await. When a function
awaits, its Lua stack is paused. While it is paused, other child tasks in the
same scope may run. If one of those children fails, that failure is delivered
when the parent reaches a checkpoint. A raw `pcall` around the await can
therefore catch an unrelated child failure:

```lua
vim.async.run(function()
  local _child = vim.async.run(function()
    vim.async.sleep(10)
    error("child failed")
  end)

  pcall(function()
    vim.async.sleep(100)
  end)

  vim.async.sleep(1)
end)
```

The `pcall` appears to protect `sleep(100)`, but the error may come from
`_child`. async.nvim keeps child failure and cancellation level-triggered:
catching one delivery does not clear the parent task's failed or closing state.
Later checkpoints still observe that state.

Use `pcall` for synchronous work, and for cleanup that must run after current
task cancellation or failure. Use a child task plus protected await (`pawait()`)
for recoverable async work.

## Recovery Patterns

### Optional Async Work

Put recoverable async work in its own task and await that task with protected
await (`pawait()`).

```lua
vim.async.run(function()
  local ok, result_or_err = vim.async.pawait(vim.async.run(function()
    local user = fetch_user()
    local profile = fetch_profile(user.id)
    return build_view(profile)
  end))

  if not ok then
    use_fallback(result_or_err)
    return
  end

  render(result_or_err)
end)
```

The child task is the failure boundary. Its failure becomes `false, err` instead
of failing the parent.

### Expected Failures as Values

If failure is part of normal control flow, return it as data instead of raising:

```lua
local function load_config()
  local text, err = read_config_file()
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

### Synchronous Cleanup

`pcall` is still useful for non-suspending cleanup. Treat it like
`try/finally`: clean up, then rethrow.

```lua
vim.async.run(function()
  local file = assert(io.open("data.txt", "r"))

  local ok, result = pcall(function()
    return process(file:read("*all"))
  end)

  file:close()

  if not ok then
    error(result, 0)
  end
  return result
end)
```

### Failure and Cancellation Cleanup

Task failure and cancellation are persistent task state, not local exceptions to
recover. Use `pcall` to catch their delivery long enough to run cleanup, then
call `checkpoint()` to re-deliver the persistent state.

```lua
vim.async.run(function()
  local worker = vim.async.run(function()
    while true do
      do_work()
      vim.async.sleep(10)
    end
  end)

  local ok, err = pcall(function()
    vim.async.await(worker)
  end)
  cleanup()

  vim.async.checkpoint()

  if not ok then
    error(err, 0)
  end
end)
```

If the current task is closing or already failed, `checkpoint()` fails before the
manual rethrow. The final `error(err, 0)` handles ordinary body failures that
are not persistent task state.

## Resource Cleanup

When an awaited callback starts cancellable work, return that work's handle. A
handle is closable when it provides a `close` method that accepts a callback to
run after closing completes. async.nvim owns that handle while the task is
suspended at the checkpoint; if the task is cancelled before the operation
completes, async.nvim closes the handle before resuming the task.

```lua
vim.async.run(function()
  vim.async.await(function(callback)
    local timer = vim.uv.new_timer()
    timer:start(1000, 0, callback)
    return timer
  end)
end)
```

## Detached and Background Work

Child tasks are attached to their parent by default. `detach()` removes that
parent ownership.

```lua
local background = vim.async.run(function()
  while true do
    do_background_work()
    vim.async.sleep(1000)
  end
end):detach()
```

After `detach()`, the task is top-level. Its original parent no longer waits for
it, cancels it, or receives its failures.

## Coordination Utilities

`iter(tasks)` waits for existing task handles and yields them in completion
order. Use `await(task)` or `pawait(task)` to get each completed task's result.
This example races two tasks by taking the first completion:

```lua
vim.async.run(function()
  local cache = vim.async.run(fetch_from_cache)
  local network = vim.async.run(fetch_from_network)

  local next_task = vim.async.iter({ cache, network })
  local winner = next_task()
  local ok, result_or_err = vim.async.pawait(winner)

  if winner == cache then
    network:close()
  else
    cache:close()
  end

  if not ok then
    error(result_or_err, 0)
  end

  return result_or_err
end)
```

`timeout(duration, task)` awaits a task with a deadline. If the deadline wins,
the task is closed and `timeout()` fails with the Lua error value `"timeout"`.

```lua
local result = vim.async.run(function()
  local task = vim.async.run(long_operation)
  return vim.async.timeout(5000, task)
end):wait()
```

`semaphore(permits)` bounds how many tasks can enter a section at once:

```lua
vim.async.run(function()
  local semaphore = vim.async.semaphore(3)
  local tasks = {}

  for i = 1, 10 do
    tasks[i] = vim.async.run(function()
      semaphore:with(function()
        process_item(i)
      end)
    end)
  end

  for task in vim.async.iter(tasks) do
    vim.async.await(task)
  end
end)
```

Lua code is still single-threaded. The semaphore limits how many tasks may be
suspended inside the section at the same time, which is useful for external
work such as requests, processes, or file operations.

## Relationship to Other Models

async.nvim is closest in spirit to Python Trio, Kotlin `coroutineScope`, and
Swift task groups: child work is owned by a scope, parents wait for children,
errors propagate, and cancellation flows down.

The shape is different because Lua has stackful coroutines and no async
syntax. `vim.async.run()` creates both the task and the scope; there is no
separate nursery object.

JavaScript promises and Go goroutines are more unstructured by default. Work can
outlive the function that started it unless the programmer manually tracks it.
async.nvim makes ownership the default and uses `detach()` for the cases that
really need unowned background work.

## Semantic Invariants

The model depends on a few invariants:

- An attached child has exactly one parent until it completes or detaches.
- A parent does not complete before attached children complete.
- Top-level tasks start immediately; attached children start at parent
  checkpoints.
- The first unhandled child failure marks the parent as failed.
- Cancellation is persistent and is delivered at checkpoints.
- Awaiting a task observes its result but does not change its owner.
- Closable operations owned by a checkpoint are closed when that task is
  cancelled.
