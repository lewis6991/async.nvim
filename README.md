# async.nvim
Small async library for Neovim plugins

[API documentation](async.md)

## Example

Take the current function that uses a callback style function to run a system process.

```lua
local function run_job(cmd, args, callback)
  local handle
  handle = vim.loop.spawn(cmd, { args  = args, },
    function(code)
      s.handle:close()
      callback(code)
    end
  )
end
```

If we want to emulate something like:

```bash
echo 'foo' && echo 'bar' && echo 'baz'
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

local a = require'async'

local run_job_a = a.wrap(run_job, 3)
```

Now we need to create a top level function to initialize the async context. To do this we can use `void` or `sync`.

Note: the main difference between `void` and `sync` is that `sync` functions can be called with a callback, like the original `run_job` in a non-async context, however the user must provide the number of arguments.

For this example we will use `void`:

```lua
local main = a.void(function()
  local code1 = run_job_a('echo', {'foo'})
  if code1 ~= 0 then
    return
  end

  local code2 = run_job_a('echo', {'bar'})
  if code2 ~= 0 then
    return
  end

  run_job_a('echo', {'baz'})
end)

main()
```

We can now call `run_job_a` in linear imperative fashion without needing to define callbacks.
The arguments provided to the callback in the original function are simply returned by the async version.

## The `async_t` handle

This library supports cancelling async functions that are currently running. This is done via the `async_t` handle interface.
The handle must provide the methods `cancel()` and `is_cancelled()`, and the purpose of these is to allow the cancelled async function to run any cleanup and free any resources it has created.

### Example use with `vim.loop.spawn`:

Typically applications to `vim.loop.spawn` make use of `stdio` pipes for communicating. This involves creating `uv_pipe_t` objects.
If a job is cancelled then these objects must be closed.

```lua
local function run_job = async.wrap(function(cmd, args, callback)
  local stdout = vim.loop.new_pipe(false)

  local raw_handle
  raw_handle = vim.loop.spawn(cmd, { args  = args, stdio = { nil, stdout }},
    function(code)
      stdout:close()
      raw_handle:close()
      callback(code)
    end
  )

  local handle = {}

  handle.is_cancelled = function(_)
    return raw_handle.is_closing()
  end

  handle.cancel = function(_, cb)
    raw_handle:close(function()
        stdout:close(cb)
    end)
  end

  return handle
end)
```

So even if `run_job` is called in a deep function stack, calling `cancel()` on any parent async function will allow the job to be cancelled safely.

