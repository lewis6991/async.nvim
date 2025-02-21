
local pcall = copcall or pcall

--- @param ... any
--- @return {[integer]: any, n: integer}
local function pack_len(...)
  return { n = select('#', ...), ... }
end

--- like unpack() but use the length set by F.pack_len if present
--- @param t? { [integer]: any, n?: integer }
--- @return ...any
local function unpack_len(t)
  if t then
    return unpack(t, 1, t.n or table.maxn(t))
  end
end

--- @class async
local M = {}

--- Weak table to keep track of running tasks
--- @type table<thread,async.Task?>
local threads = setmetatable({}, { __mode = 'k' })

--- @return async.Task?
local function running()
  local task = threads[coroutine.running()]
  if task and not (task:_completed() or task._closing) then
    return task
  end
end

--- Base class for async tasks. Async functions should return a subclass of
--- this. This is designed specifically to be a base class of uv_handle_t
--- @class async.Handle
--- @field close fun(self: async.Handle, callback: fun())
--- @field is_closing? fun(self: async.Handle): boolean

--- @alias vim.async.CallbackFn fun(...: any): async.Handle?

--- @class async.Task : async.Handle
--- @field private _callbacks table<integer,fun(err?: any, ...: any)>
--- @field private _thread thread
---
--- Tasks can call other async functions (task of callback functions)
--- when we are waiting on a child, we store the handle to it here so we can
--- cancel it.
--- @field private _current_child? async.Handle
---
--- Error result of the task is an error occurs.
--- Must use `await` to get the result.
--- @field private _err? any
---
--- Result of the task.
--- Must use `await` to get the result.
--- @field private _result? any[]
local Task = {}
Task.__index = Task

--- @private
--- @param func function
--- @return async.Task
function Task._new(func)
  local thread = coroutine.create(func)

  local self = setmetatable({
    _closing = false,
    _thread = thread,
    _callbacks = {},
  }, Task)

  threads[thread] = self

  return self
end

--- @param callback fun(err?: any, ...: any)
function Task:await(callback)
  if self._closing then
    callback('closing')
  elseif self:_completed() then -- TODO(lewis6991): test
    -- Already finished or closed
    callback(self._err, unpack_len(self._result))
  else
    table.insert(self._callbacks, callback)
  end
end

--- @package
function Task:_completed()
  return (self._err or self._result) ~= nil
end

-- Use max 32-bit signed int value to avoid overflow on 32-bit systems.
-- Do not use `math.huge` as it is not interpreted as a positive integer on all
-- platforms.
local MAX_TIMEOUT = 2 ^ 31 - 1

--- Synchronously wait (protected) for a task to finish (blocking)
---
--- If an error is returned, `Task:traceback()` can be used to get the
--- stack trace of the error.
---
--- Example:
---
---   local ok, err_or_result = task:pwait(10)
---
---   local _, result = assert(task:pwait(10), task:traceback())
---
--- Can be called if a task is closing.
--- @param timeout? integer
--- @return boolean status
--- @return any ... result or error
function Task:pwait(timeout)
  local done = vim.wait(timeout or MAX_TIMEOUT, function()
    -- Note we use self:_completed() instead of self:await() to avoid creating a
    -- callback. This avoids having to cleanup/unregister any callback in the
    -- case of a timeout.
    return self:_completed()
  end)

  if not done then
    return false, 'timeout'
  elseif self._err then
    return false, self._err
  else
    -- TODO(lewis6991): test me
    return true, unpack_len(self._result)
  end
end

--- Synchronously wait for a task to finish (blocking)
--- @param timeout? integer
--- @return any ... result
function Task:wait(timeout)
  local res = pack_len(self:pwait(timeout))

  local stat = table.remove(res, 1)
  res.n = res.n - 1

  if not stat then
    error(res[1])
  end

  return unpack_len(res)
end

--- @private
--- @param msg? string
--- @param _lvl? integer
--- @return string
function Task:_traceback(msg, _lvl)
  _lvl = _lvl or 0

  local thread = ('[%s] '):format(self._thread)

  local child = self._current_child
  if getmetatable(child) == Task then
    --- @cast child async.Task
    msg = child:_traceback(msg , _lvl + 1)
  end

  local tblvl = getmetatable(child) == Task and 2 or nil
  msg = msg .. debug.traceback(self._thread, '', tblvl):gsub('\n\t', '\n\t'..thread)

  if _lvl == 0 then
    --- @type string
    msg = msg
      :gsub('\nstack traceback:\n', '\nSTACK TRACEBACK:\n', 1)
      :gsub("\nstack traceback:\n", '\n')
      :gsub('\nSTACK TRACEBACK:\n', '\nstack traceback:\n', 1)
  end

  return msg
end

--- @param msg? string
--- @return string
function Task:traceback(msg)
  return self:_traceback(msg)
end

--- @package
--- @param err? any
--- @param result? {[integer]: any, n: integer}
function Task:_finish(err, result)
  self._current_child = nil
  self._err = err
  self._result = result
  threads[self._thread] = nil
  for _, cb in pairs(self._callbacks) do
    -- Needs to be pcall as step() (who calls this function) cannot error
    pcall(cb, err, unpack_len(result))
  end
end

--- @return boolean
function Task:is_closing()
  return self._closing
end

--- @param callback? fun()
function Task:close(callback)
  if self:_completed() then
    if callback then
      callback()
    end
    return
  end

  if callback then
    self:await(function()
      callback()
    end)
  end

  if self._closing then
    return
  end

  self._closing = true

  if self._current_child then
    self._current_child:close(function()
      self:_finish('closed')
    end)
  else
    self:_finish('closed')
  end
end

--- @param callback function
--- @param ... any
--- @return fun()
local function wrap_cb(callback, ...)
  local args = pack_len(...)
  return function()
    return callback(unpack_len(args))
  end
end

--- @param obj any
--- @return boolean
local function is_async_handle(obj)
  local ty = type(obj)
  return (ty == 'table' or ty == 'userdata') and vim.is_callable(obj.close)
end

function Task:_resume(...)
  --- @type [string|vim.async.CallbackFn]
  local ret = pack_len(coroutine.resume(self._thread, ...))
  local stat = table.remove(ret, 1) --- @type boolean

  ---@diagnostic disable-next-line: inject-field,no-unknown
  ret.n = ret.n - 1

  if not stat then
    -- Coroutine had error
    self:_finish(ret[1])
  elseif coroutine.status(self._thread) == 'dead' then
    --- @cast ret {[integer]: any, n: integer}
    -- Coroutine finished
    self:_finish(nil, ret)
  else
    --- @cast ret [vim.async.CallbackFn]

    local fn = ret[1]

    -- TODO(lewis6991): refine error handler to be more specific
    local ok, r
    ok, r = pcall(fn, function(...)
      if is_async_handle(r) then
        --- @cast r async.Handle
        -- We must close children before we resume to ensure
        -- all resources are collected.
        r:close(wrap_cb(self._resume, self, ...))
      else
        self:_resume(...)
      end
    end)

    if not ok then
      self:_finish(r)
    elseif is_async_handle(r) then
      self._current_child = r
    end
  end
end

--- @package
function Task:_log(...)
  print(self._thread, ...)
end

--- @return 'running'|'suspended'|'normal'|'dead'?
function Task:status()
  return coroutine.status(self._thread)
end

--- @param func function
--- @param ... any
--- @return async.Task
function M.arun(func, ...)
  local task = Task._new(func)
  task:_resume(...)
  return task
end

--- @class async.TaskFun
--- @field package _fun fun(...: any): any
local TaskFun = {}
TaskFun.__index = TaskFun

function TaskFun:__call(...)
  return M.arun(self._fun, ...)
end

--- Create an async function
function M.async(fun)
  return setmetatable({ _fun = fun }, TaskFun)
end

--- Returns the status of a task’s thread.
---
--- @param task? async.Task
--- @return 'running'|'suspended'|'normal'|'dead'?
function M.status(task)
  task = task or running()
  if task then
    assert(getmetatable(task) == Task, 'Expected Task')
    return task:status()
  end
end

--- @generic R1, R2, R3, R4
--- @param fun fun(callback: fun(r1: R1, r2: R2, r3: R3, r4: R4)): any?
--- @return R1, R2, R3, R4
local function yield(fun)
  assert(type(fun) == 'function', 'Expected function')
  return coroutine.yield(fun)
end

--- @param task async.Task
--- @return any ...
local function await_task(task)
  --- @param callback fun(err?: string, result?: any[])
  --- @return function
  local err, result = yield(function(callback)
    task:await(function(err, ...)
      callback(err, pack_len(...))
    end)
    return task
  end)

  if err then
    -- TODO(lewis6991): what is the correct level to pass?
    error(err, 0)
  end
  assert(result)

  return unpack_len(result)
end

--- Asynchronous blocking wait
--- @param argc integer
--- @param fun vim.async.CallbackFn
--- @param ... any func arguments
--- @return any ...
local function await_cbfun(argc, fun, ...)
  local args = pack_len(...)

  --- @param callback fun(success: boolean, result: any[])
  --- @return any?
  return yield(function(callback)
    args[argc] = callback
    args.n = math.max(args.n, argc)
    return fun(unpack_len(args))
  end)
end

--- @param taskfun async.TaskFun
--- @param ... any
--- @return any ...
local function await_taskfun(taskfun, ...)
  return taskfun._fun(...)
end

--- Asynchronous blocking wait
---
--- Example:
--- ```lua
--- local task = async.arun(function()
---    return 1, 'a'
--- end)
---
--- local task_fun = async.async(function(arg)
---    return 2, 'b', arg
--- end)
---
--- async.arun(function()
---   do -- await a callback function
---     async.await(1, vim.schedule)
---   end
---
---   do -- await a task (new async context)
---     local n, s = async.await(task)
---     assert(n == 1 and s == 'a')
---   end
---
---   do -- await a started task function (new async context)
---     local n, s, arg = async.await(task_fun('A'))
---     assert(n == 2)
---     assert(s == 'b')
---     assert(args == 'A')
---   end
---
---   do -- await a task function (re-using the current async context)
---     local n, s, arg = async.await(task_fun, 'B')
---     assert(n == 2)
---     assert(s == 'b')
---     assert(args == 'B')
---   end
--- end)
--- ```
--- @overload fun(argc: integer, func: vim.async.CallbackFn, ...:any): any ...
--- @overload fun(task: async.Task): any ...
--- @overload fun(taskfun: async.TaskFun): any ...
function M.await(...)
  assert(running(), 'Not in async context')

  local arg1 = select(1, ...)

  if type(arg1) == 'number' then
    return await_cbfun(...)
  elseif getmetatable(arg1) == Task then
    return await_task(...)
  elseif getmetatable(arg1) == TaskFun then
    return await_taskfun(...)
  end

  error('Invalid arguments, expected Task or (argc, func) got: ' .. type(arg1), 2)
end

--- Creates an async function with a callback style function.
---
--- Example:
---
--- ```lua
--- --- Note the callback argument is not present in the return function
--- --- @type fun(timeout: integer)
--- local sleep = async.awrap(2, function(timeout, callback)
---   local timer = vim.uv.new_timer()
---   timer:start(timeout * 1000, 0, callback)
---   -- uv_timer_t provides a close method so timer will be
---   -- cleaned up when this function finishes
---   return timer
--- end)
---
--- async.arun(function()
---   print('hello')
---   sleep(2)
---   print('world')
--- end)
--- ```
---
--- local atimer = async.awrap(
--- @param argc integer
--- @param func vim.async.CallbackFn
--- @return async function
function M.awrap(argc, func)
  assert(type(argc) == 'number')
  assert(type(func) == 'function')
  return function(...)
    return M.await(argc, func, ...)
  end
end

if vim.schedule then
  --- An async function that when called will yield to the Neovim scheduler to be
  --- able to call the API.
  M.schedule = M.awrap(1, vim.schedule)
end

--- @async
--- Example:
--- ```lua
--- local task1 = async.arun(function()
---   return 1, 'a'
--- end)
---
--- local task2 = async.arun(function()
---   return 1, 'a'
--- end)
---
--- local task3 = async.arun(function()
---   error('task3 error')
--- end)
---
--- async.arun(function()
---   for i, err, r1, r2 in async.iter({task1, task2, task3})
---     print(i, err, r1, r2)
---   end
--- end)
--- ```
---
--- Prints:
--- ```
--- 1 nil 1 'a'
--- 2 nil 2 'b'
--- 3 'task3 error' nil nil
--- ```
---
--- @param tasks async.Task[]
--- @return fun(): (integer?, any?, ...)
function M.iter(tasks)
  assert(running(), 'Not in async context')

  local results = {} --- @type [integer, any, ...][]

  -- Iter blocks in an async context so only one waiter is needed
  local waiter = nil

  local remaining = #tasks
  for i, task in ipairs(tasks) do
    task:await(function(err, ...)
      local callback = waiter

      -- Clear waiter before calling it
      waiter = nil

      remaining = remaining - 1
      if callback then
        -- Iterator is waiting, yield to it
        callback(i, err, ...)
      else
        -- Task finished before Iterator was called. Store results.
        table.insert(results, pack_len(i, err, ...))
      end
    end)
  end

  --- @param callback fun(i?: integer, err?: any, ...: any)
  return M.awrap(1, function(callback)
    if next(results) then
      local res = table.remove(results, 1)
      callback(unpack_len(res))
    elseif remaining == 0 then
      callback() -- finish
    else
      assert(not waiter, 'internal error: waiter already set')
      waiter = callback
    end
  end)
end

do -- join()

  --- @param results table<integer,table>
  --- @param i integer
  --- @param ... any
  --- @return boolean
  local function collect(results, i, ...)
    if i then
      results[i] = pack_len(...)
    end
    return i ~= nil
  end

  --- @param iter fun(): ...
  --- @return table<integer,table>
  local function drain_iter(iter)
    local results = {} --- @type table<integer,table>
    while collect(results, iter()) do
    end
    return results
  end

  --- @async
  --- Wait for all tasks to finish and return their results.
  ---
  --- Example:
  --- ```lua
  --- local task1 = async.arun(function()
  ---   return 1, 'a'
  --- end)
  ---
  --- local task2 = async.arun(function()
  ---   return 1, 'a'
  --- end)
  ---
  --- local task3 = async.arun(function()
  ---   error('task3 error')
  --- end)
  ---
  --- async.arun(function()
  ---   local results = async.join({task1, task2, task3})
  ---   print(vim.inspect(results))
  --- end)
  --- ```
  ---
  --- Prints:
  --- ```
  --- {
  ---   [1] = { nil, 1, 'a' },
  ---   [2] = { nil, 2, 'b' },
  ---   [3] = { 'task2 error' },
  --- }
  --- ```
  --- @param tasks async.Task[]
  --- @return table<integer,[any?,...?]>
  function M.join(tasks)
    assert(running(), 'Not in async context')
    return drain_iter(M.iter(tasks))
  end

end

-- TODO(lewis6991): joinany

return M
