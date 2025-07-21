# async.nvim

Async library for Neovim plugins

🚧 WIP and Under Construction 🚧

## Example: From Callbacks to Async

Suppose you have a function that runs a system process using callbacks:

```lua
local function run_job(cmd, args, callback)
  return vim.uv.spawn(cmd, { args = args }, callback)
end
```

If we want to emulate something like:

```bash
echo foo && echo bar && echo baz
```

In Lua with callbacks, this becomes deeply nested:

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

This quickly becomes unwieldy as the number of jobs increases.

### With async.nvim

`async.nvim` lets you write this in a linear, readable style:

```lua
-- Wrap the callback-based function (3 = callback position)
local run_job_a = vim.async.wrap(3, run_job)

-- Create an async context
local code = vim.async.run(function()
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

Now, you can call `run_job_a` imperatively, without callbacks. The async version returns the same results as the callback would have received.

Additionally, since `run_job_a` returns a handle (e.g., `uv_process_t`), `vim.async.run` will automatically close it when the task completes or is manually closed.

---

## Callback Functions

Callback functions accept a callback argument, which receives the result. Sometimes, omitting the callback runs the function synchronously. To support cancellation, these functions can return a handle with `cancel` or `close` methods.

---

## Async Function Nesting

Unlike Python or JavaScript, not all functions need to be declared async. Instead, you must execute them in an async context using `async.run()`.

```lua
--- @async
local function foo(a, b) ... end

-- Illegal: must be inside async context
foo(a, b)

-- Start foo as a task
local task = async.run(foo, a, b)

-- Wait for foo to complete
task:wait()

-- Create an async context
async.run(function()
  -- Blocking async call
  foo(a, b)

  -- Non-blocking: new async context
  local task = async.run(foo, a, b)

  -- Await task completion
  async.await(task)
end)
```

---

## Task Objects

Tasks represent asynchronous operations. They can be awaited (pausing execution until completion) or cancelled.
This makes them ideal for complex workflows, supporting cancellation, timeouts, and multiple consumers.

---

## Comparison with Other Languages

### Swift Example

```swift
func longRunningChildTask(id: Int) async {
    print("Child Task \(id): Starting...")
    for i in 1...10 {
        // Option 1: Check `isCancelled` for graceful exit
        guard !Task.isCancelled else {
            print("Child Task \(id): Was cancelled.")
            return
        }

        // Option 2: `checkCancellation()` throws if cancelled
        do {
            try Task.checkCancellation()
        } catch {
            print("Child Task \(id): Cancellation detected by checkCancellation(). Error: \(error.localizedDescription)")
            return
        }

        print("Child Task \(id): Working... step \(i)")
        // Simulate work with a cancellable sleep
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }
    print("Child Task \(id): Completed naturally.")
}

@main
struct SwiftConcurrencyApp {
    static func main() async {
        print("Main Task: Starting...")

        // Create a parent task
        let parentTask = Task {
            print("Parent Task: Launched.")

            // Create child tasks using async let
            async let child1 = longRunningChildTask(id: 1)
            async let child2 = longRunningChildTask(id: 2)

            // Await the async let children. This also implies cancellation propagation.
            _ = await [child1, child2]

            print("Parent Task: All children should be done/cancelled.")
        }

        // Simulate an external cancellation after a short delay
        try? await Task.sleep(nanoseconds: 1_000_000_000) // Wait 1 second
        print("Main: Requesting cancellation of parent task...")
        parentTask.cancel() // Explicitly cancel the parent task

        await parentTask.value // Wait for the parent task (and its children) to finish/cancel
        print("Main Task: Exiting.")
    }
}
```

### Lua with async.nvim

```lua
--- @async
local function longRunningChildTask(id)
  print(('Child Task (%d): Starting...'):format(id))
  for i = 1, 10 do
    -- Unlike swift, calling close() completely stops the thread from resuming
    -- so there is no way to check for cancellation.
    print(('Child Task (%d): Working... step %d'):format(id, i))
    -- Simulate work with a cancellable sleep
    async.sleep(500) -- 0.5 second
  end
  print(('Child Task (%d): Completed naturally'):format(id))
end

--- @async
local main = async.run(function()
  print('Main Task: Starting...')

  -- Create a parent task
  local parentTask = vim.async.run(function()
    print('Parent Task: Launched.')

    -- Create child tasks using async.run
    -- As the tasks are created in the scope of parentTask. This
    -- also implies cancellation propagation.
    local child1 = async.run(longRunningChildTask, 1)
    local child2 = async.run(longRunningChildTask, 2)

    -- Await the children
    _ = async.join({ child1, child2 })

    print('Parent Task: All children should be done/cancelled.')
  end)

  async.sleep(1000) -- Wait 1 second
  parentTask:close() -- Cancel parent task

  async.await(parentTask) -- Wait for the parent task (and its children) to finish/cancel
  print('Main Task: Exiting.')
end)
```

---

## Other Async Libraries

- [coop.nvim](https://github.com/gregorias/coop.nvim)
- [nvim-nio](https://github.com/nvim-neotest/nvim-nio)
- https://gist.github.com/hrsh7th/9751059d72376086b2e4239b21c4ffcd
