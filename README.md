# async.nvim

Structured concurrency for Lua 5.1, built on stackful coroutines.

async.nvim lets you write callback-driven work in a direct style while keeping
clear task ownership: parents wait for attached children, unhandled child errors
propagate upward, and cancellation propagates downward.

For the full semantics, read [CONCURRENCY_MODEL.md](CONCURRENCY_MODEL.md).
For a tour through similar async models in other languages, read
[ASYNC_COMPARISONS.md](ASYNC_COMPARISONS.md).

The design is heavily influenced by Nathaniel J. Smith's
[Notes on structured concurrency, or: Go statement considered harmful](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/).

## Installation

In Neovim, you can install with the built-in package manager:

```lua
vim.pack.add({ 'https://github.com/lewis6991/async.nvim' })
```

Then require the module:

```lua
local async = require('async')
```

In Neovim, async.nvim initializes itself from `vim.wait`, `vim.schedule`, and
`vim.uv.new_timer`.

Outside Neovim, provide event-loop bindings:

```lua
local async = require('async')

async.init({
  wait = my_wait,
  schedule = my_schedule,
  new_timer = my_new_timer,
})
```

`wait(timeout, predicate)` must pump the event loop until `predicate()` returns
true or the timeout expires. `schedule(callback)` must run `callback` on a later
event-loop turn. `new_timer()` must create a libuv-compatible timer.

## Waiting And Awaiting

| API | Context | Behavior |
| --- | --- | --- |
| `async.await(...)` | Inside a task | Suspend at an async checkpoint. |
| `async.pawait(...)` | Inside a task | Protected await for recoverable awaited failures. |
| `task:wait(timeout)` | Synchronous code | Pump the event loop until the task completes or times out. |
| `task:pwait(timeout)` | Synchronous code | Protected synchronous wait. |
| `task:on_complete(cb)` | Any context | Observe completion without blocking or starting a pending child task. |

## Quick Start

Create a task with `run()`:

```lua
local async = require('async')

async.run(function()
  async.sleep(100)
  print('ran after 100ms')
end)
```

From synchronous code, use `task:wait()`:

```lua
local result = async.run(function()
  async.sleep(100)
  return 'done'
end):wait()
```

Inside a task, use `await()`:

```lua
async.run(function()
  local child = async.run(function()
    async.sleep(100)
    return 'done'
  end)

  local result = async.await(child)
  print(result)
end)
```

## Wrapping Callbacks

`wrap(argc, func)` turns a callback-taking function into an async function. The
first argument is the callback position.

```lua
local fs_stat = async.wrap(2, vim.uv.fs_stat)

async.run(function()
  local err, stat = fs_stat('README.md')
  assert(not err, err)
  print(stat and stat.type)
end)
```

You can also await a callback-taking function directly:

```lua
async.run(function()
  local err, stat = async.await(2, vim.uv.fs_stat, 'README.md')
  assert(not err, err)
  print(stat and stat.type)
end)
```

If the callback function returns a closable handle, async.nvim closes that handle
when the awaiting task is cancelled.

## Task Scopes

Tasks created inside another task are attached children. The parent waits for
them before completing. If a child fails without being handled, the parent fails
and closes remaining child work.

```lua
async.run(function()
  local user = async.run(fetch_user)
  local prefs = async.run(fetch_preferences)

  render(async.await(user), async.await(prefs))
end)
```

Use `detach()` for background work that should no longer be owned by the parent:

```lua
async.run(function()
  async.run(background_loop):detach()
end)
```

## Handling Errors

`await(task)` raises if the awaited task fails or is closed. Use `pawait(task)`
when the awaited task is allowed to fail and the current task should continue.

```lua
async.run(function()
  local ok, result_or_err = async.pawait(async.run(load_optional_config))

  if ok then
    apply_config(result_or_err)
  else
    use_defaults(result_or_err)
  end
end)
```

`pawait()` protects awaited-operation failures. It does not hide cancellation or
already-pending failure on the current task.

## Coordination

`iter(tasks)` yields completed task handles in completion order. Use
`await(task)` or `pawait(task)` to read each result.

```lua
async.run(function()
  local tasks = {
    async.run(fetch_from_cache),
    async.run(fetch_from_network),
  }

  local winner = async.iter(tasks)()
  local ok, result_or_err = async.pawait(winner)

  for _, task in ipairs(tasks) do
    if task ~= winner then
      task:close()
    end
  end

  if not ok then
    error(result_or_err, 0)
  end

  return result_or_err
end)
```

`timeout(duration, task)` closes a task if it does not finish before the
deadline:

```lua
async.run(function()
  local task = async.run(fetch_from_network)
  return async.timeout(5000, task)
end)
```

`semaphore(permits)` limits how many tasks can enter a section at once:

```lua
async.run(function()
  local sem = async.semaphore(4)

  for _, item in ipairs(items) do
    local item = item
    async.run(function()
      sem:with(function()
        process(item)
      end)
    end)
  end
end)
```

## API Reference

- `:help vim.async` or [doc/lua-async.txt](doc/lua-async.txt) for generated API
  docs.
- [CONCURRENCY_MODEL.md](CONCURRENCY_MODEL.md) for task ownership, checkpoints,
  error propagation, and cancellation semantics.
- [ASYNC_COMPARISONS.md](ASYNC_COMPARISONS.md) for examples from other async
  ecosystems.
