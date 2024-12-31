--- @brief `vim.async` is a module that provides a way to run and manage
--- asynchronous functions.
---

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
  local co = coroutine.running()
  local task = threads[co]
  if task and not (task._closed or task._closing) then
    return task
  end
end

--- Base class for async tasks. Async functions should return a subclass of
--- this. This is designed specifically to be a base class of uv_handle_t
--- @class vim.async.Handle
--- @field close fun(self: any, callback: fun())

--- @alias vim.async.CallbackFn fun(...: any): vim.async.Handle?

--- @class vim.async.Task : vim.async.Handle
--- @field private _callbacks table<integer,fun(err?: any, result?: any[])>
--- @field package _thread thread
--- @field package _current_obj? {close: fun(self, callback: fun())}
--- @field package _closed boolean
--- @field package _err? any
--- @field package _result? any[]
local Task = {}

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
  }, { __index = Task })

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

--- Synchronous wait
--- @param timeout integer
--- @return any ...
function Task:wait(timeout)
  self:log('WAIT')

  local done = vim.wait(timeout, function()
    return self:_completed()
  end)

  if not done then
    self:close()
    error('Timeout waiting for async task')
  elseif self._closed then
    error('Task is closed')
  elseif self._err then
    error('Task has error: ' .. self._err)
  end

  -- TODO(lewis6991): test me
  return unpack_len(assert(self._result))
end

--- @package
--- @param err? any
--- @param result? any[]
function Task:_finish(err, result)
  self:log('FINISH', err)
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

  self:log('closing')
  self._closing = true

  local function close0()
    self._closed = true
    self:_finish('closed')
    if callback then
      callback()
    end
  end

  if self._current_obj then
    self:log('closing obj', self._current_obj)
    self._current_obj:close(close0)
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
  --   self:log('resume dead')
  --   -- Callback function had error
  --   self:_finish(...)
  --   return
  -- end

  --- @type [boolean, string|vim.async.CallbackFn]
  local ret = { coroutine.resume(self._thread, ...) }
  local stat = table.remove(ret, 1) --- @type boolean
  --- @cast ret [string|vim.async.CallbackFn]

  if not stat then
    self:log('resume error')
    -- Coroutine had error
    self:_finish(ret[1])
  elseif coroutine.status(self._thread) == 'dead' then
    self:log('resume finish')
    -- Coroutine finished
    self:_finish(nil, ret)
  else
    --- @cast ret [vim.async.CallbackFn]

    self:log('resume step')

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
      self._current_obj = obj_or_err
    end
  end
end

--- @package
function Task:log(...)
  -- print(self._thread, ...)
end

---@param func function
---@return vim.async.Task
function M.arun(func)
  local task = Task._new(func)
  task:_resume()
  return task
end

--- Create an async function
function M.async(func)
  return function(...)
    return M.arun(wrap_cb(func, ...))
  end
end

--- Returns the status of a task’s thread.
---
--- @param task vim.async.Task
--- @return 'running'|'suspended'|'normal'|'dead'?
function M.status(task)
  task = task or running()
  if task then
    return coroutine.status(task._thread)
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
  if not running() then
    error('Cannot await in non-async context')
  end

  local arg1 = select(1, ...)

  if type(arg1) == 'table' then
    return await_task(...)
  elseif type(arg1) == 'number' then
    return await_cbfun(...)
  end

  error('Invalid arguments, expected Task or (argc, func)')
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
