local core = require('async._core')
local compat = require('async._compat')
local new_queue = require('async._queue')
local runtime = require('async._runtime')
local util = require('async._util')

--- Public async API.
---
--- See `CONCURRENCY_MODEL.md` for the structured concurrency semantics.
--- @class vim.async: vim.async._core
local M = setmetatable({}, { __index = core })

M.semaphore = require('async._semaphore')

--- @param unsubscribe fun()[]
local function unsubscribe_all(unsubscribe)
  for _, unsub in ipairs(unsubscribe) do
    unsub()
  end
end

--- Initialize async runtime for non-Neovim environments.
---
--- In Neovim, initialization happens automatically. Only call this if you're
--- using the library outside of Neovim or you want to override the detected
--- runtime bindings.
---
--- `opts.wait(timeout, predicate)` must run the event loop until `predicate`
--- returns true or the timeout expires. `opts.schedule(callback)` must defer a
--- callback to the next event loop turn. `opts.new_timer()` must create
--- libuv-compatible timers.
---
--- @param opts vim.async.InitOpts
function M.init(opts)
  runtime.init(opts)
end

--- Create an async function from a callback-style function.
---
--- The callback is inserted at argument position `argc`. If `func` returns a
--- closable handle, it is closed when the awaiting task is cancelled.
---
--- @generic T, R
--- @param argc integer
--- @param func fun(...: T..., callback: fun(...: R...)): vim.async.Closable?
--- @return async fun(...: T...): R...
function M.wrap(argc, func)
  compat.validate('argc', argc, 'number')
  compat.validate('func', func, 'callable')
  --- @async
  return function(...)
    return M.await(argc, func, ...)
  end
end

--- Iterate completed tasks in completion order.
---
--- The iterator yields task handles. Use `await(task)` or `pawait(task)` to
--- retrieve each task's result.
--- @async
--- @generic R
--- @param tasks vim.async.Task<R>[] A list of tasks to wait for and iterate over.
--- @return async fun(): vim.async.Task<R>? iterator that yields each completed task.
function M.iter(tasks)
  compat.validate('tasks', tasks, 'table')

  local remaining = #tasks
  local queue = new_queue()
  local unsubscribe = {} --- @type fun()[]

  if remaining == 0 then
    queue:put_nowait()
  else
    for _, task in ipairs(tasks) do
      unsubscribe[#unsubscribe + 1] = task:on_complete(function()
        remaining = remaining - 1
        queue:put_nowait(task)
        if remaining == 0 then
          queue:put_nowait()
        end
      end)
    end
  end

  --- @async
  local function next_task()
    return queue:get()
  end

  return util.gc_fun(next_task, function()
    unsubscribe_all(unsubscribe)
  end)
end

--- Asynchronously sleep for a given duration.
---
--- Blocks the current task for the given duration, but does not block the main
--- thread.
--- @async
--- @param duration integer ms
function M.sleep(duration)
  compat.validate('duration', duration, 'number')
  M.await(function(callback)
    local timer = runtime.new_timer()
    timer:start(duration, 0, callback)
    return timer
  end)
end

--- Run a task with a timeout.
---
--- If the task does not complete within the specified duration, it is closed
--- and an error is thrown.
--- @async
--- @generic R
--- @param duration integer Timeout duration in milliseconds
--- @param task vim.async.Task<R>
--- @return R
function M.timeout(duration, task)
  compat.validate('duration', duration, 'number')
  compat.validate('task', task, 'table')

  local timed_out = false
  local timer = M.run('__timeout', function()
    M.sleep(duration)
    timed_out = true
    task:close()
  end)
  --- @diagnostic disable-next-line: access-invisible
  timer._hidden = true

  local result = util.pack_len(M.pawait(task))
  timer:close()
  M.pawait(timer)

  if timed_out then
    error('timeout')
  end

  if not result[1] then
    error(result[2], 0)
  end

  return util.unpack_len(result, 2)
end

if type(vim) == 'table' then
  M.init({
    wait = vim.wait,
    schedule = vim.schedule,
    new_timer = vim.uv.new_timer,
  })
end

return M
