# async.nvim
Small async library for Neovim plugins

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

local run_job_a = async.awrap(3, run_job)
```

Now we need to create a top level function to initialize the async context. To do this we can use `void` or `sync`.

Note: the main difference between `void` and `sync` is that `sync` functions can be called with a callback (like the `run_job` in a non-async context, however the user must provide the number of agurments.

For this example we will use `void`:

```lua
local code = async.arun(function()
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

Additionally because `run_job_a` returns an object with a `close()` method (as a `uv_process_t`), `asrync.arun` will automatically `close` the handle if either the task completes or is interuppted,

