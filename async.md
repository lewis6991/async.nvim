# async

This library provides a set of utilities for asynchronous programming in Lua.
It includes support for tasks, events, queues, semaphores, and more, enabling developers to write non-blocking, asynchronous code.

Small async library for Neovim plugins

## Library

### Core functions

#### `async.async(fun)`
Create an asynchronous function.

- **Parameters**:
  - `fun` (function): The function to wrap as asynchronous.
- **Returns**: `async.TaskFun`

---

#### `async.await(...)`
Await the result of a task, callback function, or task function.

- **Parameters**:
  - `...` (any): Task, callback function, or task function to await.
- **Returns**: Results of the awaited operation.

---

#### `async.run(func, ...)`
Run a function in an asynchronous context.

- **Parameters**:
  - `func` (function): The function to run asynchronously.
  - `...` (any): Arguments to pass to the function.
- **Returns**: `async.Task`

---

#### `async.wrap(argc, func)`
Create an asynchronous function from a callback-style function.

Must be run in an async context.

- **Parameters**:
  - `argc` (integer): Number of arguments before the callback.
  - `func` (function): The callback-style function.
- **Returns**: `async function`

---

### `async.iter(tasks)`

Must be run in an async context.

#### Returns:

Iterator function that yields the results of each task.

---

### `async.join(tasks)`

Run a collection of async functions (`thunks`) concurrently and return when
 all have finished.

---

### `async.schedule()`

An async function that when called will yield to the Neovim scheduler to be
 able to call the API.

Must be run in an async context.

---

### Task Management

#### `async.Task`

##### `Task:await(callback)`
Await the completion of a task.

- **Parameters**:
  - `callback` (function): Callback to invoke when the task completes.

##### `Task:wait(timeout?)`
Synchronously wait for a task to finish.

- **Parameters**:
  - `timeout` (integer, optional): Timeout in milliseconds.
- **Returns**: Results of the task.

##### `Task:close(callback?)`
Close the task and all its children.

- **Parameters**:
  - `callback` (function, optional): Callback to invoke after closing.

##### `Task:traceback(msg?)`
Get the traceback of a task.

- **Parameters**:
  - `msg` (string, optional): Additional message to include in the traceback.
- **Returns**: `string`



### Utilities

#### `async.event()`
Create a new event.

- **Returns**: `async.Event`

#### `async.queue(max_size?)`
Create a new FIFO queue with async support.

- **Parameters**:
  - `max_size` (integer, optional): Maximum number of items in the queue.
- **Returns**: `async.Queue`

#### `async.semaphore(permits)`
Create an async semaphore.

- **Parameters**:
  - `permits` (integer): Number of permits for the semaphore.
- **Returns**: `async.Semaphore`

---

## Examples

### Running an Asynchronous Task

```lua
local async = require('async')

local task = async.run(function()
  print("Task started")
  async.await(1, vim.schedule)
  print("Task finished")
end)

task:wait()
```

### Using an Event

```lua
local async = require('async')

local event = async.event()

async.run(function()
  print("Waiting for event...")
  event:wait()
  print("Event triggered!")
end)

vim.schedule(function()
  event:set()
end)
```

### Using a Queue

```lua
local async = require('async')

local queue = async.queue(5)

async.run(function()
  for i = 1, 5 do
    queue:put(i)
  end
  queue:put(nil) -- Signal end
end)

async.run(function()
  while true do
    local value = queue:get()
    if value == nil then break end
    print("Got value:", value)
  end
end)
```

### Using a Semaphore

```lua
local async = require('async')

local semaphore = async.semaphore(2)

for i = 1, 5 do
  async.run(function()
    semaphore:with(function()
      print("Task", i, "started")
      async.await(1, vim.schedule)
      print("Task", i, "finished")
    end)
  end)
end
```

