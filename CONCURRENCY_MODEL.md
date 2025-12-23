# The async.nvim Concurrency Model

This document explains how async.nvim implements structured concurrency for Neovim.
If you've used async/await in JavaScript, Python, or other languages, some concepts will be familiar, but there are important differences in how tasks are organized and managed.

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

## Three Core Guarantees

The structured concurrency model rests on three fundamental rules:

### Parents wait for children.

When you create a task inside another task, the parent will not complete until all its children finish.
This is automatic-you don't need to explicitly wait.
Consider this code:

```lua
local parent = vim.async.run(function()
  local child1 = vim.async.run(function()
    vim.async.sleep(100)
  end)

  local child2 = vim.async.run(function()
    vim.async.sleep(50)
  end)

  print("done")  -- This runs immediately
end)

parent:wait()  -- But this waits ~100ms
```

The print happens right away because the parent's function body completes quickly.
However, the parent task itself doesn't complete until both children finish.
You can't have orphaned tasks in this model.

### Errors propagate up

When a child task errors, that error automatically propagates to its parent.
The parent will then cancel any other running children and fail with the child's error.

```lua
local parent = vim.async.run(function()
  local child1 = vim.async.run(function()
    vim.async.sleep(10)
    error("child1 failed")  -- child1 errors and completes
  end)

  local child2 = vim.async.run(function()
    vim.async.sleep(1000)  -- Long running
  end)

  -- Parent continues running synchronously
  -- While parent runs, children are suspended until the sleep is finished
  local x = compute_something()

  -- Parent suspends here, giving children a chance to run
  -- When parent resumes, the error from child1 is delivered:
  vim.async.sleep(100)  -- Error surfaces when parent resumes here
  -- child2 is cancelled when parent receives the error
end)
```

### Cancellation propagates down

When you cancel a task, all its children are cancelled too.

```lua
local parent = vim.async.run(function()
  local child = vim.async.run(function()
    vim.async.sleep(1000)
    print("This won't run if parent is closed")
  end)

  vim.async.sleep(100)
  print("Parent completed normally")
end)

-- Calling close() from outside resumes parent with cancellation
parent:close()  -- Both parent and child cancelled immediately
```

These three rules work together to prevent common concurrency bugs.
You can't forget to cancel a task, you can't lose track of errors, and you can't have tasks outlive their intended scope.

## Tasks and Scopes

In async.nvim, a task serves dual purposes.
It's both a handle to a running operation and a scope for child operations.
When you call `vim.async.run()`, you create a new task that establishes a concurrency scope:

```lua
local task = vim.async.run(function()
  -- Any tasks created here become children of `task`
  local child = vim.async.run(worker_function)
end)
```

This is different from Python's Trio, which has separate nursery objects for managing child tasks.
In async.nvim, the task itself is the nursery.
It's also different from JavaScript, where there's no automatic parent-child relationship at all.

The parent-child relationship is determined by where a task is created, not where it's awaited.
If you create a task outside a concurrency scope, it has no parent:

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

Tasks can be detached from their parent if you really need fire-and-forget behavior:

```lua
local parent = vim.async.run(function()
  local background = vim.async.run(function()
    -- Long-running background work
  end):detach()

  -- Parent completes without waiting for background
end)
```


## Stackful Coroutines and Function Coloring

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

## How Tasks Execute

When you call `vim.async.run()`, several things happen immediately.
A new coroutine is created, a Task object wraps it, and if there's a currently running task, the new task becomes its child.
The task starts executing right away:

```lua
local task = vim.async.run(function()
  print("This prints immediately")
  vim.async.await(vim.schedule)
  print("This prints after a scheduler tick")
end)

print("This might print first or second")
```

Tasks execute until they hit an await operation.
At that point, they suspend and yield control back to the event loop.
When the awaited operation completes, the task resumes from where it left off.

A task can be in several states.
It's "running" when actively executing code, "awaiting" when suspended for an operation, "normal" when active but not running (this happens when it's starting another task), and "completed" when finished.
You can check this with `task:status()`.

You can't accidentally call `coroutine.yield()` or `coroutine.resume()` on a task as the library enforces that all yielding and resuming goes through the proper async mechanisms.

## Error Handling

Errors flow upward through the task tree.
When a child task errors, that error propagates immediately to its parent.
The parent will cancel any other running children and then fail with the child's error.

Understanding error propagation requires understanding the execution model.
As Nvim's Lua runtime is single-threaded, only one task executes at a time and all others are suspended.
When a task is actively running synchronous code, no other tasks can run.
When a task suspends (via `await`, `sleep`, etc.), control returns to the event loop, which can resume other tasks.

When a child errors, the parent's pending operation is cancelled and the parent resumes immediately with the error:

```lua
local parent = vim.async.run(function()
  local child1 = vim.async.run(function()
    vim.async.sleep(50)
    error("something broke")  -- child1 errors at 50ms
  end)

  local child2 = vim.async.run(function()
    while true do
      vim.async.sleep(10)
    end
  end)

  -- Parent is running synchronously here
  -- child1 and child2 are suspended, cannot run yet
  print("Still running...")
  local x = 1 + 1

  -- Parent suspends here, event loop takes over
  -- Event loop resumes child1, which sleeps 50ms then errors
  -- The parent's sleep is cancelled at 50ms
  -- Parent resumes immediately (not after 100ms) and receives the error
  vim.async.sleep(100)  -- Cancelled at 50ms, error delivered on resume
end)
```

Here's what happens step by step:

1. Parent runs synchronously, creating children (children are suspended when they execute `await` calls)
2. Parent suspends (e.g., calls `sleep`), event loop takes over
3. Event loop resumes child tasks, giving them a chance to run
4. If a child errors while parent is suspended, the parent's pending operation is cancelled
5. Parent resumes immediately with the error

Another example showing this flow:

```lua
vim.async.run(function()
  local child = vim.async.run(function()
    vim.async.sleep(10)
    error("child failed")
  end)

  -- This entire synchronous block runs uninterrupted
  -- child is suspended, cannot run during this
  for i = 1, 1000000 do
    math.sqrt(i)
  end

  -- Parent suspends here (wants to wait 1000ms)
  -- Event loop resumes child
  -- child sleeps 10ms, then errors
  -- Parent's sleep is cancelled at 10ms
  -- Parent resumes immediately with the error
  vim.async.sleep(1000)  -- Cancelled at 10ms, error delivered on resume
end)
```

The key insight: errors are delivered "on resume", but the resume happens immediately because the parent's pending operation is cancelled when a child errors.

You can catch errors with standard Lua pcall:

```lua
vim.async.run(function()
  local child = vim.async.run(risky_operation)

  local x = compute_something()  -- Runs synchronously while child suspended

  local ok, result = pcall(function()
    -- Parent suspends, event loop runs child
    -- If child errors, sleep is cancelled and parent resumes with error
    vim.async.sleep(1)
  end)

  if not ok then
    print("Caught error:", result)
  end
end)
```

### Edge-Triggered Errors, Level-Triggered Cancellations

async.nvim uses different propagation models for errors versus cancellations:

- **Edge-triggered (errors)**: An event fires once when a condition transitions from false to true (e.g., OK → Error). Once delivered, the error is consumed.
- **Level-triggered (cancellations)**: The condition persists and is checked repeatedly at each suspension point.

**Normal errors are edge-triggered.** When a child task fails, the error is delivered once to the parent at the next suspension point. After catching the error with `pcall`, you can continue execution normally:

```lua
vim.async.run(function()
  local child = vim.async.run(function()
    vim.async.sleep(10)
    error("child failed")
  end)

  -- First await - error is caught
  local ok, err = pcall(function()
    vim.async.sleep(100)  -- Child error delivered here
  end)
  
  if not ok then
    print("Caught error:", err)
    -- Error has been consumed, can continue safely
  end
  
  -- Second await - no error re-issued
  vim.async.sleep(1)  -- This works fine
  print("Continued after handling error")
end)
```

**Cancellations are level-triggered.** When a task is being closed, the cancellation condition persists. If you catch a "closed" error with `pcall` but continue execution, subsequent suspension points will continue to receive the "closed" error:

```lua
vim.async.run(function()
  local task = vim.async.run(function()
    local ok, err = pcall(function()
      vim.async.sleep(100)
    end)
    
    if not ok and err == "closed" then
      print("Caught first cancellation")
      -- Cancellation state persists
    end
    
    -- Second await - cancellation re-issued!
    vim.async.sleep(1)  -- Throws "closed" again
  end)
  
  task:close()
end)
```

This design makes sense because:

1. **Errors represent transient events** - once a child has failed and you've handled that failure, you may want to continue with error recovery or cleanup logic.

2. **Cancellations represent persistent state** - if a task is being shut down, it should stay shut down. The cancellation request doesn't go away just because you caught it once.

To handle cancellations gracefully, check the cancellation state explicitly:

```lua
vim.async.run(function()
  while not vim.async.is_closing() do
    local ok, err = pcall(function()
      do_work()
      vim.async.sleep(10)
    end)
    
    if not ok then
      if err == "closed" then
        break  -- Exit the loop on cancellation
      else
        print("Error occurred:", err)
        -- Handle other errors and continue
      end
    end
  end
  
  cleanup()
  print("Shut down gracefully")
end)
```

Tasks also provide a `pwait()` method that returns a status and result instead of throwing:

```lua
local task = vim.async.run(function()
  error("failed")
end)

local ok, result = task:pwait(1000)
if not ok then
  print("Task failed:", result)
end
```

The library includes special handling for tracebacks across task boundaries.
When you have nested async operations, `task:traceback()` will show you the call stack across all the coroutines involved, making debugging much easier.

## Cancellation

Cancellation flows downward through the task tree.
When you close a task with `task:close()`, the cancellation happens immediately.
Calling `close()` acts as a suspension point-it's a call into the async library stack, which can resume the target task and deliver the cancellation right away:

```lua
local task = vim.async.run(function()
  -- Task suspends here
  vim.async.sleep(1000)
  -- Cancellation delivered here when close() is called below
  print("This won't print if closed during sleep")
end)

-- Calling close() resumes the task immediately with cancellation
task:close()  -- Task cancelled right now, sleep is interrupted
```

If a task isn't currently suspended (for example, it hasn't started yet, or it's in the middle of synchronous code), `close()` marks it for cancellation, which will be delivered at the next suspension point:

```lua
vim.async.run(function()
  local task = vim.async.run(function()
    -- Long synchronous computation runs first
    for i = 1, 10000000 do
      math.sqrt(i)
    end
    -- Cancellation cannot interrupt the loop

    -- Task suspends here
    -- Cancellation is delivered when task resumes from this sleep
    vim.async.sleep(10)
    print("This won't print")
  end)

  -- Parent calls close() immediately
  -- Child task is marked for cancellation
  task:close()

  -- Parent suspends, allowing child to run
  -- Child executes the loop, then suspends at sleep
  -- Cancellation is delivered when child would resume from sleep
  vim.async.sleep(1)
end)
```

When a parent is closed, all its children are cancelled recursively:

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

parent:close()  -- Cancels entire tree immediately
```

Tasks can check if they're being cancelled and clean up gracefully:

```lua
vim.async.run(function()
  local resource = acquire_resource()

  while not vim.async.is_closing() do
    do_work(resource)
    vim.async.sleep(10)
  end

  resource:cleanup()
  print("Shut down gracefully")
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

For resources that don't auto-close, you can use pcall to ensure cleanup:

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
Because parents wait for children, you can acquire a resource in the parent and be confident that all child tasks finish before the cleanup code runs:

```lua
vim.async.run(function()
  local db = connect_to_database()

  -- Launch multiple workers
  for i = 1, 10 do
    vim.async.run(function()
      process_batch(db, i)
    end)
  end

  -- All workers complete before we get here
  db:close()
end)
```

## Synchronization Primitives

Beyond basic tasks, async.nvim provides several synchronization primitives.

**Futures** bridge callback-based code with async/await.
A Future is a placeholder for a value that will be available later:

```lua
local future = vim.async._future()

some_callback_api(function(result)
  future:complete(nil, result)
end)

-- Later, wait for the result
vim.async.run(function()
  future:wait(function(err, result)
    print("Got:", result)
  end)
end)
```

**Events** let multiple tasks wait for a signal.
An event starts unset, tasks block on `wait()`, and when you call `set()` all waiting tasks wake up:

```lua
local event = vim.async._event()

-- Multiple waiters
for i = 1, 5 do
  vim.async.run(function()
    event:wait()
    print("Task", i, "notified")
  end)
end

-- Signal all
vim.async.run(function()
  vim.async.sleep(100)
  event:set()  -- All 5 tasks wake up
end)
```

**Queues** provide async producer-consumer communication:

```lua
local queue = vim.async._queue(10)  -- Bounded queue

-- Producer
vim.async.run(function()
  for i = 1, 100 do
    queue:put(i)  -- Blocks if queue is full
  end
  queue:put(nil)
end)

-- Consumer
vim.async.run(function()
  while true do
    local item = queue:get()  -- Blocks if queue is empty
    if not item then break end
    process(item)
  end
end)
```

**Semaphores** limit concurrent access to resources:

```lua
local semaphore = vim.async.semaphore(3)  -- Max 3 concurrent

local tasks = {}
for i = 1, 10 do
  tasks[i] = vim.async.run(function()
    semaphore:with(function()
      -- Only 3 tasks can be in this block at once
      -- (though only 1 actually executes at any moment)
      expensive_operation(i)
    end)
  end)
end
```

These primitives compose well.
You might use a queue to distribute work and a semaphore to limit concurrency:

```lua
local queue = vim.async._queue()
local semaphore = vim.async.semaphore(5)

vim.async.run(function()
  -- Producer
  vim.async.run(function()
    for i = 1, 100 do
      queue:put(work_item(i))
    end
  end)

  -- Worker pool
  local workers = {}
  for i = 1, 10 do
    workers[i] = vim.async.run(function()
      while true do
        local item = queue:get()
        if not item then break end

        semaphore:with(function()
          process(item)
        end)
      end
    end)
  end

  vim.async.await_all(workers)
end)
```

## Comparing with Other Languages

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
When you await, the task yields a callback function to the runtime.
The runtime calls this function with a resume callback.
When the resume callback is invoked, the task resumes from where it left off.

The implementation uses marker values to prevent misuse.
A task yields `(yield_marker, callback_function)` and expects to be resumed with `(resume_marker, ...)`.
If these markers don't match, the library throws an error.
This prevents accidental use of raw coroutine operations.

Tasks track their children in an array.
When a task completes, it must first close or await all children (depending on success vs failure).
This ensures the parent-child invariants are maintained.

The library uses weak tables to allow garbage collection of completed tasks.
Once a task finishes and nobody holds a reference to it, the coroutine can be collected.

For performance, the implementation avoids creating unnecessary stack frames.
When a callback completes synchronously (calls its callback immediately), the task resumes in a loop without recursion.
This allows deep recursion in user code without stack overflow.

## Practical Patterns

Here are some common patterns that work well with this concurrency model.

**Racing tasks:** Start multiple tasks and use the first one to complete:

```lua
local parent_task
parent_task = vim.async.run(function()
  vim.async.run(function()
    local result = fetch_from_cache()
    parent_task:complete(result)
  end)

  vim.async.run(function()
    local result = fetch_from_network()
    parent_task:complete(result)
  end)

  -- Wait forever - children will complete the parent
  vim.async.await(function(_) end)
end)

local result = parent_task:wait()
```

**Limited concurrency:** Process many items with a concurrency limit:

```lua
local semaphore = vim.async.semaphore(5)

local tasks = {}
for i = 1, 100 do
  tasks[i] = vim.async.run(function()
    semaphore:with(function()
      process_item(i)
    end)
  end)
end

vim.async.run(function()
  vim.async.await_all(tasks)
end):wait()
```

**Timeouts:** Wrap operations with a timeout:

```lua
local task = vim.async.run(long_operation)

vim.async.run(function()
  vim.async.timeout(5000, task)
end):wait()
```

**Background work with cancellation:** Long-running tasks that can be cancelled cleanly:

```lua
local background = vim.async.run(function()
  while not vim.async.is_closing() do
    local work = get_next_work()
    if work then
      process(work)
    end
    vim.async.sleep(100)
  end

  cleanup()
end)

-- Later: cancel gracefully
background:close()
```

**Optional operations:** Try something but fall back if it times out:

```lua
local optional = vim.async.run(fetch_optional_data)
local ok, result = optional:pwait(100)

if ok then
  use_optional_data(result)
else
  use_default_data()
end
```

The structured model makes these patterns safe by default.
You don't need to worry about leaking tasks or forgetting cleanup-the structure enforces correctness.

## Final Thoughts

Structured concurrency is more than just a nice-to-have feature.
It changes how you think about concurrent code.
Instead of managing a soup of independent operations, you work with a clear tree structure.
Every task has an owner, every operation has a bounded lifetime, and resource cleanup is automatic.

The model catches bugs that would be silent in unstructured systems.
Forgetting to await a task is a compile error (the parent waits anyway).
Forgetting to cancel a task is impossible (cancellation propagates).
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
