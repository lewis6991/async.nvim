# The async.nvim Concurrency Model

This document explains how async.nvim implements structured concurrency for Lua.
If you've used async/await in JavaScript, Python, or other languages, some concepts will be familiar, but there are important differences in how tasks are organized and managed.

## Event Loop Integration

async.nvim is built on Lua coroutines and requires integration with an event loop.
In Neovim, this integration happens automatically using `vim.wait` and `vim.schedule`.

For non-Neovim environments, you'll need to provide equivalent functions via `async.init()`:

```lua
local async = require('async')

async.init({
  wait = my_wait_implementation,
  schedule = my_schedule_implementation,
  new_timer = my_timer_factory,
})
```

The rest of this document uses Neovim examples (`vim.async.*`), but the concepts
apply equally to generic Lua usage with the `async.*` namespace.
The `schedule` hook posts callbacks to a later event-loop turn, `wait` pumps the
event loop for synchronous `task:wait(...)`, and `new_timer` powers timer APIs
such as `sleep(...)` and `timeout(...)`.

## Event Loop and Checkpoints

async.nvim is cooperative, not parallel.
Neovim runs Lua on one thread, so only one task executes Lua code at a time.
The event loop decides when suspended tasks can resume, but a running task keeps
control until it returns, errors, or enters async.nvim.

A **checkpoint** is a point where async.nvim can regain control of the task.
At a checkpoint, the library may suspend the current task, start pending child
tasks, deliver cancellation or child failures, and later resume the task from the
same stack frame.

Inside a task, `await(...)` and `pawait(...)` are checkpoints:

```lua
vim.async.run(function()
  print("runs now")
  vim.async.await(vim.schedule)
  print("runs after the scheduler resumes this task")
end)
```

Successful return from the task function is also a final checkpoint for child
management.
At that point, the parent starts any pending children and waits for attached
child work before completing.

Because checkpoints are cooperative, synchronous Lua code is never interrupted in
the middle of a stack frame.
Cancellation and child failures are delivered when the task reaches a checkpoint.

## What is Structured Concurrency?

Most async programming models let you start operations that run independently.
In JavaScript, you can fire off a Promise and forget about it.
In Go, you launch a goroutine with no inherent parent-child relationship.
This flexibility comes at a cost: it's easy to leak resources, lose track of running operations, and end up with unpredictable program behavior.

Structured concurrency takes a different approach.
Every async operation has a clear owner and lifetime.
When you start a task inside another task, you create a parent-child relationship.
The parent automatically waits for its children to complete, and cancelling the parent cancels all its children.
This creates a tree structure where the control flow is always clear.

async.nvim implements structured concurrency inspired by Python's Trio library and similar systems in Kotlin and Swift.
The key idea is simple: concurrent operations should follow the same scoping rules as regular code.
Just as you can't return from a function while a nested block is still running, a task can't complete while it still has running children.

## The Task Tree

In async.nvim, a task is both:

- a handle to one running operation
- a scope that owns child operations

When you call `vim.async.run()`, you create a task:

```lua
local task = vim.async.run(function()
  -- Any tasks created here become children of `task`
  local child = vim.async.run(worker_function)
end)
```

The parent-child relationship is determined by where a task is created, not where it is awaited.
If you create a task outside another task, it has no parent:

```lua
-- Top-level task with no parent
local t1 = vim.async.run(function()
  vim.async.sleep(50)
end)

local main = vim.async.run(function()
  -- This task's parent is `main`
  local child = vim.async.run(function()
    vim.async.sleep(100)
  end)

  -- t1 has no parent, so we must explicitly await it
  vim.async.await(t1)
end)
```

This is different from Python's Trio, which uses explicit nursery objects.
In async.nvim, the task itself is the nursery.
It is also different from JavaScript promises, which have no automatic parent-child relationship.

Tasks can be detached from their parent when you really need fire-and-forget behavior:

```lua
local parent = vim.async.run(function()
  local background = vim.async.run(function()
    -- Long-running background work
  end):detach()

  -- Parent completes without waiting for background
end)
```

Detached tasks become top-level tasks.
They are no longer cancelled or awaited by the original parent.

## Task Start and Checkpoints

Top-level tasks start immediately.

For attached child tasks, creation and first execution are separate.
`run()` attaches the child to the current parent immediately, but the child's function does not run yet.
This lets the parent choose whether to observe the child with `await()` or `pawait()` before child code can fail.

An attached child starts at the parent's next start checkpoint:

- `await(...)` or `pawait(...)`
- successful return from the parent function, before the parent implicitly waits for children

If the parent errors, closes, or is completed with `task:complete(...)`, pending children are closed without running their function.

Other APIs interact with this rule, but they are not parent start checkpoints:

- `task:detach()` removes a child from its parent; if it was pending, it is scheduled as top-level work
- `task:wait(...)` is a synchronous edge; it starts the task being waited on and pumps the event loop
- `task:close()` marks a task as closing and interrupts its current awaitable
- `task:complete(...)` finishes a task early and closes remaining child work

This gives the parent a chance to decide how it wants to observe a new child:

```lua
vim.async.run(function()
  local child = vim.async.run(function()
    error("optional child failed")
  end)

  -- The child starts after pawait has claimed the task boundary, so the
  -- expected failure is returned as data instead of failing the parent.
  local ok, err = vim.async.pawait(child)
end)
```

Once the parent awaits or returns successfully, any remaining attached children start so the tree can make progress.
This keeps task creation cheap and predictable without allowing forgotten children.

## Three Core Guarantees

The structured concurrency model rests on three rules.

### Parents Wait For Children

When you create a task inside another task, the parent cannot complete until all attached children finish.
This is automatic:

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

parent:wait()  -- waits about 100ms
```

The parent function body returns quickly, but the parent task does not complete until both children finish.

### Errors Propagate Up

The first unhandled child failure marks the parent as failed.
The parent closes any remaining children, waits for cleanup, and then completes with the child error:

```lua
vim.async.run(function()
  vim.async.run(function()
    vim.async.sleep(10)
    error("child failed")
  end)

  vim.async.run(function()
    vim.async.sleep(1000)
  end)

  -- At this await checkpoint, child work can run. The first child failure is
  -- delivered here and the long-running sibling is closed.
  vim.async.sleep(100)
end)
```

### Cancellation Propagates Down

When you close a task, its attached children are closed too:

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

These rules prevent common concurrency bugs.

## Task Status and Coroutine Safety

A task can be in several states.
It is "running" when actively executing code, "awaiting" when suspended for an operation or children, "normal" when active but not running, and "completed" when finished.
You can check this with `task:status()`.

User code should not call raw `coroutine.yield()` or `coroutine.resume()` in a task.
Tasks must suspend and resume through async.nvim operations.

## Error Handling

Errors propagate upward through the task tree.
The first unhandled child failure marks the parent task as failed.
The parent closes any remaining children, waits for cleanup, and then completes
with the child error.

```lua
vim.async.run(function()
  vim.async.run(function()
    vim.async.sleep(10)
    error("child failed")
  end)

  -- The child can run at this await checkpoint. If it fails, this await is
  -- interrupted and the parent becomes failed.
  vim.async.sleep(100)
end)
```

### `pcall` and Async Code

Lua's usual recovery boundary is `pcall`.
In synchronous code, an error unwinds to the nearest protected call; `pcall`
turns that into `false, err`, and the caller continues after the protected call.
That works well when the failure belongs to the stack you protected.

Awaitable code changes what can reach that boundary.
At an `await()` checkpoint, the protected function has paused.
While it is paused, other child tasks in the same scope can run.
If one of those children fails, that failure is delivered when the parent
resumes.
A raw `pcall` around the await can therefore catch an error from outside the code
it appears to protect.
In this example, the `pcall` looks like it protects `sleep(100)`, but the error
comes from a child task created earlier in the same scope:

```lua
vim.async.run(function()
  local _child = vim.async.run(function()
    vim.async.sleep(10)
    error("child failed")
  end)

  pcall(function()
    vim.async.sleep(100)
  end)

  -- The child failure is still pending on the parent task.
  vim.async.sleep(1)
end)
```

async.nvim deliberately keeps child failure and cancellation level-triggered so
this accidental catch cannot accidentally recover the parent task.
Once the parent is failed or closing, later checkpoints continue to observe that
state.
`pawait()` also observes checkpoint errors, but it returns them as data instead
of raising them.
If the error belongs to the awaited operation, `pawait()` can be a recovery
boundary; if the current task is already failed or closing, the task still
finishes that way after cleanup runs.

### Recovery Patterns

Use task boundaries for recoverable async work.
Use `pawait()` for protected async checkpoints and cancellation-aware cleanup.
Keep `pcall` for synchronous work and synchronous API edges.

**1. Put recoverable async work in a child task**

If an async section is optional, run that section in its own task and await it
with `pawait()`.
The child task becomes the failure boundary, so its failure is returned as data
instead of failing the parent:

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

`pawait(run(...))` creates an explicit task boundary.
Failures inside that child task become `false, err` instead of failing the
parent task.
If `pawait()` returns `false` because the current task is closing or already
failed, that state remains terminal.
Use `is_closing()` to distinguish cancellation from ordinary awaited-operation
failure.

**2. Return expected failures as data**

If an async operation can fail as part of normal control flow, return that
failure instead of raising:

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

This keeps ordinary control flow in return values and reserves `error()` for task
failure.

**3. Catch only synchronous work**

Raw `pcall` is still fine around code that cannot suspend:

```lua
vim.async.run(function()
  local text = load_text()          -- May suspend
  local ok, config = pcall(vim.json.decode, text)  -- Pure sync code

  if not ok then
    config = default_config()
  end
end)
```

**4. Use `pcall` for synchronous cleanup, then rethrow**

When you need `try` / `finally` behavior, `pcall` can guard a section so cleanup
runs before the task fails.
This pattern is only for work that cannot suspend.
Do not treat the error as recovered:

```lua
vim.async.run(function()
  local file = assert(io.open('data.txt', 'r'))

  local ok, result = pcall(function()
    return process(file:read('*all'))
  end)

  file:close()

  if not ok then error(result, 0) end
  return result
end)
```

**5. Use `pwait()` at synchronous edges**

From synchronous code, `task:pwait()` is the method-friendly spelling of
`pcall(task.wait, task, timeout)`. It turns `wait()` failure into a boolean
result without making you pass `self` by hand:

```lua
local task = vim.async.run(function()
  error("failed")
end)

local ok, result = task:pwait(1000)
if not ok then
  print("Task failed:", result)
end
```

**6. Use `pawait()` for cancellation cleanup around async work**

Cancellation is persistent state, not a recoverable local exception.
`pawait()` lets cleanup code observe cancellation without raising, but it does
not clear the task's closing state.
Put the suspendable work in a child task, await it with `pawait()`, then clean
up:

```lua
vim.async.run(function()
  local worker = vim.async.run(function()
    while true do
      do_work()
      vim.async.sleep(10)
    end
  end)

  local ok, err = vim.async.pawait(worker)
  cleanup()

  if not ok and not vim.async.is_closing() then
    error(err, 0)
  end
end)
```

If cancellation produced the `false` result, returning after cleanup is fine; the
task still completes as closed.
If ordinary child failure produced it, rethrow after cleanup unless the failure
is intentionally recoverable.

The library includes special handling for tracebacks across task boundaries.
When you have nested async operations, `task:traceback()` will show you the call
stack across all the coroutines involved, making debugging much easier.

## Cancellation

Cancellation flows downward through the task tree.
When you close a task with `task:close()`, the task enters a persistent closing state.
What happens next depends on where the task is.

If the task is suspended on an awaitable, `close()` closes that awaitable and resumes the task with `"closed"`:

```lua
local task = vim.async.run(function()
  vim.async.sleep(1000)
  print("not reached")
end)

task:close()
```

If the task is attached but has not started, closing it completes it with `"closed"` before user code runs:

```lua
vim.async.run(function()
  local task = vim.async.run(function()
    print("not reached")
  end)

  task:close()
  vim.async.await(task)  -- raises "closed"
end)
```

If the task is currently running synchronous Lua code, cancellation cannot interrupt that stack.
The close signal is delivered at the next checkpoint.

When a parent is closed, attached children are cancelled recursively:

```lua
local parent = vim.async.run(function()
  local child1 = vim.async.run(function()
    local grandchild = vim.async.run(function()
      while true do
        vim.async.sleep(10)
      end
    end)
    vim.async.await(grandchild)
  end)

  local child2 = vim.async.run(function()
    while true do
      vim.async.sleep(10)
    end
  end)

  -- Parent does some work
  vim.async.sleep(100)
end)

parent:close()
```

Tasks can run cleanup during cancellation by awaiting the suspendable work from
a small child task:

```lua
vim.async.run(function()
  local resource = acquire_resource()

  local worker = vim.async.run(function()
    while true do
      do_work(resource)
      vim.async.sleep(10)
    end
  end)

  local ok, err = vim.async.pawait(worker)
  resource:cleanup()

  if not ok and not vim.async.is_closing() then
    error(err, 0)
  end
end)
```

When a task is waiting on an async operation, and that operation returns a handle with a `close()` method, the library will automatically close it if the task is cancelled.
This ensures resources like timers and file handles are cleaned up even when a task is cancelled.

## Resource Management

Any object with a `close(callback)` method can be automatically cleaned up by the task system.
When you return such an object from an awaited callback, the task tracks it and ensures it's closed when the task completes or is cancelled:

```lua
vim.async.run(function()
  vim.async.await(function(callback)
    local timer = vim.uv.new_timer()
    timer:start(1000, 0, callback)

    -- Return the timer - it will be closed automatically
    return timer
  end)
end)
```

This works with any libuv handle, or any custom object that provides a close method.
The cleanup happens regardless of whether the task completes normally, errors, or is cancelled.

For resources that don't auto-close, keep cleanup synchronous and put the
failure boundary around the smallest section you can.
For pure synchronous work, `pcall` is still the right `try/finally` tool:

```lua
vim.async.run(function()
  local file = io.open('data.txt', 'r')

  local ok, result = pcall(function()
    return process(file:read('*all'))
  end)

  file:close()

  if not ok then error(result) end
  return result
end)
```

The structured concurrency model helps here too.
Because parents wait for children, you can acquire a resource in the parent and
explicitly await child work before cleanup.
If child work can fail or suspend during cancellation, use a child task plus
`pawait()`:

```lua
vim.async.run(function()
  local db = connect_to_database()

  local worker = vim.async.run(function()
    local workers = {}

    for i = 1, 10 do
      workers[i] = vim.async.run(function()
        process_batch(db, i)
      end)
    end

    vim.async.await_all(workers)
  end)

  local ok, err = vim.async.pawait(worker)
  db:close()

  if not ok and not vim.async.is_closing() then
    error(err, 0)
  end
end)
```

## Semaphores

A semaphore limits how many tasks can enter a section at once.
This is useful for bounding external concurrency such as requests, processes, or
file operations.
Lua code is still cooperative and single-threaded; the limit controls how many
tasks may be suspended inside the section at the same time.

```lua
vim.async.run(function()
  local semaphore = vim.async.semaphore(3)
  local tasks = {}

  for i = 1, 10 do
    tasks[i] = vim.async.run(function()
      semaphore:with(function()
        -- At most 3 tasks can be inside this section at once.
        expensive_operation(i)
      end)
    end)
  end

  vim.async.await_all(tasks)
end)
```

## Background: Stackful Coroutines and Function Coloring

One of async.nvim's key advantages comes from Lua's stackful coroutines.
In most languages with async/await, the async keyword is viral.
If function C is async, then function B that calls C must be async, and function A that calls B must be async, and so on:

```javascript
// JavaScript - async is viral
async function fetchUser(id) {
  return await fetch(`/users/${id}`)
}

async function getUserName(id) {
  const user = await fetchUser(id)  // Must be async
  return user.name
}

async function displayUser(id) {
  const name = await getUserName(id)  // Must be async
  console.log(name)
}
```

This is called the "function coloring" problem.
You end up with two types of functions that don't mix well, and the async keyword spreads through your codebase like a virus.

Lua's stackful coroutines avoid this.
A coroutine has its own call stack, and it can be suspended from anywhere in that stack:

```lua
-- Regular Lua functions - no special marking
local function fetch_user(id)
  return do_fetch('/users/' .. id)
end

local function get_user_name(id)
  local user = fetch_user(id)
  return user.name
end

local function display_user(id)
  local name = get_user_name(id)
  print(name)
end

-- Only the top level needs to be async
vim.async.run(function()
  display_user(123)
  -- Suspension happens deep in do_fetch, but we don't
  -- need to mark intermediate functions as async
end)
```

The await can happen anywhere inside the call stack.
You still need an explicit boundary (the `vim.async.run()` call) to create the async context, but once you're inside that context, regular functions can call other regular functions that eventually call async operations.

This is similar to how Go handles concurrency.
You use the `go` keyword to start a goroutine, but once you're inside that goroutine, you don't need special syntax for blocking operations.

## Background: Comparing with Other Languages

**JavaScript** has unstructured concurrency.
Promises are independent entities with no automatic parent-child relationship.
You can easily forget to await a promise, leading to orphaned work:

```javascript
async function parent() {
  fetch('/api/1')  // Forgotten await - promise orphaned
  fetch('/api/2')  // Forgotten await - promise orphaned
  return "done"    // Parent completes immediately
}
```

Cancellation requires manual AbortController management.
There's no automatic cleanup when a function exits.

In async.nvim, you can't forget to wait for children.
They're automatically awaited when the parent scope ends.
Cancellation and cleanup are automatic.

**Python's Trio** is the closest equivalent.
Trio has explicit nursery objects:

```python
async with trio.open_nursery() as nursery:
    nursery.start_soon(child1)
    nursery.start_soon(child2)
# Nursery waits for all children
```

async.nvim unifies the task and nursery concepts.
The task returned by `vim.async.run()` serves both purposes.
This feels more natural in Lua and reduces boilerplate.

**Swift** has structured concurrency with TaskGroups:

```swift
await withTaskGroup(of: Void.self) { group in
    group.addTask { await child1() }
    group.addTask { await child2() }
}
```

This is similar to async.nvim's model, but Swift uses stackless coroutines (function coloring applies) while Lua uses stackful coroutines.

**Kotlin** has coroutineScope:

```kotlin
coroutineScope {
    launch { child1() }
    launch { child2() }
}
```

Again, similar structure but with stackless coroutines.

**Go** has unstructured concurrency.
Goroutines are launched with no implicit parent-child relationship:

```go
go worker1()  // Fire and forget
go worker2()  // Fire and forget
```

You manually track them with WaitGroups and pass context objects for cancellation.
async.nvim automates all of this.

The key insight is that structured concurrency isn't about syntax-it's about semantics.
The parent-child relationship, automatic waiting, error propagation, and cascading cancellation are what matter.
async.nvim brings these benefits to Lua/Neovim while leveraging stackful coroutines to avoid function coloring.

## Implementation Notes

Under the hood, each task wraps a Lua coroutine.
When you await, the task yields an awaitable function to the scheduler.
That awaitable receives a resume callback.
When the callback is invoked, the task resumes from where it left off.

The implementation is built around a few invariants:

- coroutine resumes are guarded by private marker values, so raw coroutine misuse fails loudly
- child tasks are attached before they start, and attached children first run at await checkpoints or successful parent finish
- a future completes exactly once
- parent failure from a child is recorded through one child-failure path
- finalization owns child cleanup, so a dead parent coroutine is not resumed again while its children are being collected

Tasks track children in an array to preserve cleanup order.
When a task completes, finalization either awaits children after success or closes them after failure.
This is what maintains the parent-child invariants.

The library uses weak tables to allow garbage collection of completed tasks.
Once a task finishes and nobody holds a reference to it, the coroutine can be collected.

For performance, the implementation avoids creating unnecessary stack frames.
When a callback completes synchronously, the task resumes in a loop without recursion.
This allows deep recursion in user code without stack overflow.

## Examples

Here are some common patterns that work well with this concurrency model.

**Racing tasks:** Start multiple child tasks, take the first result, and close
the loser:

```lua
local result = vim.async.run(function()
  local cache = vim.async.run(fetch_from_cache)
  local network = vim.async.run(fetch_from_network)

  local next_result = vim.async.iter({ cache, network })
  local winner, result = next_result()

  if winner == 1 then
    network:close()
  else
    cache:close()
  end

  return result
end):wait()
```

**Limited concurrency:** Process many items with a concurrency limit:

```lua
vim.async.run(function()
  local semaphore = vim.async.semaphore(5)
  local tasks = {}

  for i = 1, 100 do
    tasks[i] = vim.async.run(function()
      semaphore:with(function()
        process_item(i)
      end)
    end)
  end

  vim.async.await_all(tasks)
end):wait()
```

**Timeouts:** Wrap operations with a timeout:

```lua
local result = vim.async.run(function()
  local task = vim.async.run(long_operation)
  return vim.async.timeout(5000, task)
end):wait()
```

**Background work with cancellation:** Long-running tasks that clean up when
cancelled:

```lua
local background = vim.async.run(function()
  local worker = vim.async.run(function()
    while true do
      local work = get_next_work()
      if work then
        process(work)
      end
      vim.async.sleep(100)
    end
  end)

  local ok, err = vim.async.pawait(worker)
  cleanup()

  if not ok and not vim.async.is_closing() then
    error(err, 0)
  end
end)

-- Later: cancel gracefully
background:close()
```

**Optional operations:** Try something but fall back if it fails or times out:

```lua
vim.async.run(function()
  local ok, result = vim.async.pawait(vim.async.run(function()
    local optional = vim.async.run(fetch_optional_data)
    return vim.async.timeout(100, optional)
  end))

  if ok then
    use_optional_data(result)
  else
    use_default_data()
  end
end):wait()
```

The structured model makes these patterns safe by default.
You don't need to worry about leaking tasks or forgetting cleanup-the structure enforces correctness.

## Final Thoughts

Structured concurrency is more than just a nice-to-have feature.
It changes how you think about concurrent code.
Instead of managing a soup of independent operations, you work with a clear tree structure.
Every task has an owner, every operation has a bounded lifetime, and resource cleanup is automatic.

The model catches bugs that would be silent in unstructured systems.
Forgetting to await an attached child task is not silent; the parent waits for it anyway.
Forgetting to cancel an attached child task is not silent either; parent cancellation propagates.
Forgetting to handle an error makes it propagate to the parent.

These guarantees come with minimal syntactic overhead.
You create tasks with `vim.async.run()`, await with `vim.async.await()`, and the rest is automatic.
The stackful coroutine model means you don't need to mark every function in your call chain as async.

For Neovim plugins, this is particularly valuable.
Plugins often manage complex async workflows-LSP requests, file operations, user interactions.
Having a robust concurrency model prevents the subtle bugs that creep into async code.
When you close a buffer, you can cancel all tasks associated with it and know that cleanup will happen correctly.
When an error occurs, you get a clear stack trace across async boundaries.

The model isn't perfect for everything.
Sometimes you genuinely want fire-and-forget behavior, though you can use `detach()` for that.
Sometimes you want tasks that outlive their lexical scope, though top-level tasks provide that.
But for the vast majority of concurrent code, structured concurrency is a better default than the unstructured alternative.
