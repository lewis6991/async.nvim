--- @type fun(...: any): { [integer]: any, n: integer }
local pack_len = vim.F.pack_len

--- @type fun(t: { [integer]: any, n: integer })
local unpack_len = vim.F.unpack_len

--- @class vim.async
local M = {}

--- Weak table to keep track of running tasks
--- @type table<thread,vim.async.Task?>
local threads = setmetatable({}, { __mode = 'k' })

--- @return vim.async.Task?
local function running()
  local task = threads[coroutine.running()]
  if task and not (task._closed or task._closing) then
    return task
  end
end

--- Base class for async tasks. Async functions should return a subclass of
--- this. This is designed specifically to be a base class of uv_handle_t
--- @class vim.async.Handle
--- @field close fun(self: vim.async.Handle, callback: fun())
--- @field is_closing? fun(self: vim.async.Handle): boolean

--- @alias vim.async.CallbackFn fun(...: any): vim.async.Handle?

--- @class vim.async.Task : vim.async.Handle
--- @field private _callbacks table<integer,fun(err?: any, result?: any[])>
--- @field private _thread thread
---
--- Tasks can call other async functions (task of callback functions)
--- when we are waiting on a child, we store the handle to it here so we can
--- cancel it.
--- @field private _current_child? {close: fun(self, callback: fun())}
---
--- @field package _closed boolean
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
--- @return vim.async.Task
function Task._new(func)
  local thread = coroutine.create(func)

  local self = setmetatable({
    _closing = false,
    _closed = false,
    _thread = thread,
    _callbacks = {},
  }, Task)

  threads[thread] = self

  return self
end

--- @param callback fun(err?: any, result?: any[])
function Task:await(callback)
  if self._closing then
    callback('closing')
  elseif self._closed then
    callback('closed')
  elseif not threads[self._thread] then
    -- Already finished
    callback(self._err, self._result)
  else
    table.insert(self._callbacks, callback)
  end
end

--- @private
function Task:_completed()
  return self._closed or (self._err or self._result) ~= nil
end

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
  local done = vim.wait(timeout or math.huge, function()
    -- Note we use self:_completed() instead of self:await() to avoid creating a
    -- callback. This avoids having to cleanup/unregister any callback in the
    -- case of a timeout.
    return self:_completed()
  end)

  if not done then
    return false, 'timeout'
  elseif self._closed then
    return false, 'closed'
  elseif self._err then
    return false, self._err
  else
    -- TODO(lewis6991): test me
    return true, unpack_len(assert(self._result))
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
    error(self:traceback(res[2]))
  end

  return unpack_len(res)
end

--- @param msg? string
--- @return string
function Task:traceback(msg)
  return debug.traceback(self._thread, msg)
end

--- @package
--- @param err? any
--- @param result? any[]
function Task:_finish(err, result)
  self._err = err
  self._result = result
  threads[self._thread] = nil
  for _, cb in pairs(self._callbacks) do
    -- Needs to be pcall as step() (who calls this function) cannot error
    pcall(cb, err, result)
  end
end

--- @return boolean
function Task:is_closing()
  return self._closing
end

--- @param callback? fun()
function Task:close(callback)
  if
    self._closing
    or self._closed
    or not threads[self._thread]
    or coroutine.status(self._thread) == 'dead'
  then
    if callback then
      callback()
    end
    return
  end

  self._closing = true

  local function close0()
    self._closed = true
    self:_finish('closed')
    if callback then
      callback()
    end
  end

  if self._current_child then
    self._current_child:close(close0)
  else
    close0()
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

function Task:_resume(...)
  -- TODO(lewis6991): can this happen?
  -- if coroutine.status(self._thread) == 'dead' then
  --   -- Callback function had error
  --   self:_finish(...)
  --   return
  -- end

  --- @type [boolean, string|vim.async.CallbackFn]
  local ret = { coroutine.resume(self._thread, ...) }
  local stat = table.remove(ret, 1) --- @type boolean
  --- @cast ret [string|vim.async.CallbackFn]

  if not stat then
    -- Coroutine had error
    self:_finish(ret[1])
  elseif coroutine.status(self._thread) == 'dead' then
    -- Coroutine finished
    self:_finish(nil, ret)
  else
    --- @cast ret [vim.async.CallbackFn]

    local fn = ret[1]

    -- TODO(lewis6991): refine error handler to be more specific
    local ok, obj_or_err
    ok, obj_or_err = xpcall(fn, debug.traceback, function(...)
      local obj = obj_or_err --[[@as vim.async.Task]]
      if obj then
        obj:close(wrap_cb(self._resume, self, ...))
      else
        self:_resume(...)
      end
    end)

    if not ok then
      self:_finish(obj_or_err)
    elseif obj_or_err and not obj_or_err.close then
      self:_finish('Invalid object returned: ' .. vim.inspect(obj_or_err))
    else
      self._current_child = obj_or_err
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

local function is_task(obj)
  return type(obj) == 'table' and getmetatable(obj) == Task
end

--- @param func function
--- @param ... any
--- @return vim.async.Task
function M.arun(func, ...)
  local task = Task._new(func)
  task:_resume(...)
  return task
end

--- Create an async function
function M.async(func)
  return function(...)
    return M.arun(func, ...)
  end
end


--- Returns the status of a task’s thread.
---
--- @param task? vim.async.Task
--- @return 'running'|'suspended'|'normal'|'dead'?
function M.status(task)
  task = task or running()
  if task then
    assert(is_task(task), 'Expected Task')
    return task:status()
  end
end

-- TODO(lewis6991): do we need pyeild
-- There’s also `pyield` variant of `yield` that returns `success, results`
-- instead of throwing an error.

--- @generic R1, R2, R3, R4
--- @param fun fun(callback: fun(r1: R1, r2: R2, r3: R3, r4: R4)): any?
--- @return R1, R2, R3, R4
local function yield(fun)
  assert(type(fun) == 'function', 'Expected function')
  return coroutine.yield(fun)
end

local function validate_task(task)
  if not task or not task._thread then
    error('Invalid task')
  end
end

--- @param task vim.async.Task
--- @return any ...
local function await_task(task)
  validate_task(task)

  --- @param callback fun(err?: string, result?: any[])
  --- @return function
  local err, result = yield(function(callback)
    task:await(callback)
    return task
  end)

  if err then
    error(('Task function failed: %s\n%s'):format(err))
  end
  assert(result)

  return (unpack(result, 1, table.maxn(result)))
end

--- Asynchronous blocking wait
--- @param argc integer
--- @param func vim.async.CallbackFn
--- @param ... any func arguments
--- @return any ...
local function await_cbfun(argc, func, ...)
  local args = pack_len(...)
  args.n = math.max(args.n, argc)

  --- @param callback fun(success: boolean, result: any[])
  --- @return any?
  return yield(function(callback)
    args[argc] = callback
    return func(unpack_len(args))
  end)
end

--- Asynchronous blocking wait
--- @overload fun(task: vim.async.Task): any ...
--- @overload fun(argc: integer, func: vim.async.CallbackFn, ...:any): any ...
function M.await(...)
  assert(running(), 'Cannot await in non-async context')

  local arg1 = select(1, ...)

  if type(arg1) == 'number' then
    return await_cbfun(...)
  elseif is_task(arg1) then
    return await_task(...)
  else
    error('Invalid arguments, expected Task or (argc, func) got: '.. type(arg1), 2)
  end
end

--- Creates an async function with a callback style function.
--- @param argc integer
--- @param func vim.async.CallbackFn
--- @return function
function M.awrap(argc, func)
  assert(type(argc) == 'number')
  assert(type(func) == 'function')
  return function(...)
    return M.await(argc, func, ...)
  end
end

-- TODO(lewis6991): joinall, joinany

if vim.schedule then
  --- An async function that when called will yield to the Neovim scheduler to be
  --- able to call the API.
  M.schedule = M.awrap(1, vim.schedule)
end

--- @param tasks vim.async.Task[]
--- @return fun(): (integer?, any?, any[]?)
function M.iter(tasks)
  local results = {} --- @type [integer, any, any[]][]

  -- Iter shuold block in an async context so only one waiter is needed
  local waiter = nil

  local remaining = #tasks
  for i, task in ipairs(tasks) do
    task:await(function(err, result)
      local callback = waiter

      -- Clear waiter before calling it
      waiter = nil

      remaining = remaining - 1
      if callback then
        -- Iterator is waiting, yield to it
        callback(i, err, result)
      else
        -- Task finished before Iterator was called. Store results.
        table.insert(results, { i, err, result })
      end
    end)
  end

  --- @param callback fun(i?: integer, err?: any, result?: any)
  return M.awrap(1, function(callback)
    if next(results) then
      local res = table.remove(results, 1)
      callback(unpack(res, 1, table.maxn(res)))
    elseif remaining == 0 then
      callback() -- finish
    else
      assert(not waiter, 'internal error: waiter already set')
      waiter = callback
    end
  end)
end

return M
