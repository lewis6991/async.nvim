# async.nvim

Async library for Neovim plugins

🚧 WIP and Under Construction 🚧

## Example

Take the current function that uses a callback style function to run a system process.

```lua
local function run_job(cmd, args, callback)
  return vim.uv.spawn(cmd, { args = args }, callback)
end
```

If we want to emulate something like:

```lua
echo foo && echo bar && echo baz
```

Would need to be implemented as:

```lua

run_job('echo', {'foo'},
  function(code1)
    if code1 ~= 0 then
      return
    end
    run_job('echo', {'bar'},
      function(code2)
        if code2 ~= 0 then
          return
        end
        run_job('echo', {'baz'})
      end
    )
  end
)

```

As you can see, this quickly gets unwieldy the more jobs we want to run.

`async.nvim` simplifies this significantly.

First we turn this into an async function using `wrap`:

```lua

local async = require('async')

local run_job_a = async.wrap(3, run_job)
```

Now we need to create a top level function to initialize the async context. To do this we can use `void` or `sync`.

Note: the main difference between `void` and `sync` is that `sync` functions can be called with a callback (like the `run_job` in a non-async context, however the user must provide the number of agurments.

For this example we will use `void`:

```lua
local code = async.run(function()
  local code1 = run_job_a('echo', {'foo'})
  if code1 ~= 0 then
    return
  end

  local code2 = run_job_a('echo', {'bar'})
  if code2 ~= 0 then
    return
  end

  return run_job_a('echo', {'baz'})
end):wait()
```

We can now call `run_job_a` in linear imperative fashion without needing to define callbacks.
The arguments provided to the callback in the original function are simply returned by the async version.

Additionally because `run_job_a` returns an object with a `close()` method (as a `uv_process_t`), `asrync.run` will automatically `close` the handle if either the task completes or is interuppted,

## Kinds of async functions

async.nvim supports two kinds of async function signatures.

Utility functions are available to convert one type to another.

### Callback functions as used by `vim.uv`

These are regular function that accept a callback argument that will provide the result
as arguments to the callback.

Callback functions can also use the omission of a callback argument to run the function
synchronously.

In order to support cancellation, callback functions can return a handle
with methods to cancel/close the function.

Pros:
- simple use cases are less verbose

Cons:
- more difficult to type annotate

### Task functions

Functions which return an object with methods for operating on the task.

Pros:
- allows cancellation
- timeouts
- allows for multiple consumers of the result
- generally more versatile

Cons:
- Can be more verbose

## Async function nesting

Unlike Python or Javascript, in async.nvim not all functions need to be defined/created as such.
Instead async functions can be regular functions but they must be executed in an async context (via `async.run()`).
If a function is created with `async.async()` then when it is called it execute in a new async context and therefore will be non-blocking.

```lua
-- Declare an async function
local foo = async.async(function(a, b) ... end)

--- @async
--- Async function created as regular function
local bar = function(a, b) ... end

bar(a, b)
-- illegal, needs to execute in an async context

foo(a, b)
-- async, non-blocking

foo(a, b):wait()
-- sync, blocking

-- use async.run to create an async context
async.run(function()

  bar(a, b)
  -- async, blocking

  foo(a, b)
  -- async, non-blocking
  -- new async context is created

  async.await(foo(a, b)
  -- async blocking
  -- new async context is created
  -- current context will be suspended until the task finishes

end)
```

## Task objects

Tasks in `async.lua` are objects that represent asynchronous operations.

They provide a way to handle asynchronous code execution in a more manageable and readable manner.
Tasks can be awaited, allowing the code to pause execution until the task is complete, and they can also be cancelled if needed.
This makes them versatile for handling complex asynchronous workflows, as they support features like cancellation, timeouts, and multiple consumers of the result.
Tasks are generally more versatile and easier to type annotate compared to callback functions.

The `Task` class in the provided Lua code is a base class for managing asynchronous tasks.
It is designed to handle the lifecycle of an asynchronous operation, including starting, awaiting, and closing tasks.
The class provides methods to create new tasks, wait for their completion, handle errors, and manage callbacks.
It uses Lua's coroutine mechanism to manage asynchronous execution and allows tasks to be composed and controlled in a non-blocking manner.

# Other async libs

- [coop.nvim](https://github.com/gregorias/coop.nvim)
- [nvim-nio](https://github.com/nvim-neotest/nvim-nio)
