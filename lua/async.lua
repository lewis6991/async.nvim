--- Small async library for Neovim plugins
--- @module async

-- Store all the async threads in a weak table so we don't prevent them from
-- being garbage collected
local handles = setmetatable({}, { __mode = 'k' })

local M = {}

-- Note: coroutine.running() was changed between Lua 5.1 and 5.2:
-- - 5.1: Returns the running coroutine, or nil when called by the main thread.
-- - 5.2: Returns the running coroutine plus a boolean, true when the running
--   coroutine is the main one.
--
-- For LuaJIT, 5.2 behaviour is enabled with LUAJIT_ENABLE_LUA52COMPAT
--
-- We need to handle both.

--- Returns whether the current execution context is async.
---
--- @return boolean|nil
function M.running()
  local current = coroutine.running()
  if current and handles[current] then
    return true
  end
end

local function is_async_handle(handle)
  if handle and handle.cancel and handle.is_cancelled then
    return true
  end
end

local function execute(func, callback, ...)
  vim.validate{
    func = { func, 'function' },
    callback = { callback , 'function', true }
  }

  local co = coroutine.create(func)

  -- Handle for an object currently running on the event loop.
  -- The coroutine is paused while this is active.
  -- Must provide methods cancel() and is_cancelled()
  local cur_exec_handle

  -- Handle for the user. Since cur_exec_handle will change every
  -- step() we need to provide access to it through a proxy
  local handle = {}

  -- Analogous to uv.close
  function handle:cancel(cb)
    vim.validate{ callback = { cb , 'function', true } }
    -- Cancel anything running on the event loop
    if cur_exec_handle and not cur_exec_handle:is_cancelled() then
      cur_exec_handle:cancel(cb)
    end
  end

  -- Analogous to uv.is_closing
  function handle:is_cancelled()
    return cur_exec_handle and cur_exec_handle:is_cancelled()
  end

  local function set_executing_handle(h)
    if is_async_handle(h) then
      cur_exec_handle = h
    end
  end

  setmetatable(handle, { __index = handle })
  handles[co] = handle

  local function step(...)
    local ret = {coroutine.resume(co, ...)}
    local stat, nargs, protected, err_or_fn = unpack(ret)

    if not stat then
      error(string.format("The coroutine failed with this message: %s\n%s",
        err_or_fn, debug.traceback(co)))
    end

    if coroutine.status(co) == 'dead' then
      if callback then
        callback(unpack(ret, 4))
      end
      return
    end

    assert(type(err_or_fn) == 'function', "type error :: expected func")

    local args = {select(5, unpack(ret))}

    if protected then
      args[nargs] = function(...)
        step(true, ...)
      end
      local ok, err_or_handle = pcall(err_or_fn, unpack(args, 1, nargs))
      if not ok then
        step(false, err_or_handle)
      else
        set_executing_handle(err_or_handle)
      end
    else
      args[nargs] = step
      set_executing_handle(err_or_fn(unpack(args, 1, nargs)))
    end
  end

  step(...)
  return handle
end

--- Use this to create a function which executes in an async context but
--- called from a non-async context. Inherently this cannot return anything
--- since it is non-blocking
--- @tparam function func
--- @tparam number argc The number of arguments of func. Defaults to 0
function M.create(func, argc)
  vim.validate{
    func = { func , 'function' },
    argc = { argc, 'number', true }
  }
  argc = argc or 0
  return function(...)
    if M.running() then
      return func(...)
    end
    local callback = select(argc+1, ...)
    return execute(func, callback, unpack({...}, 1, argc))
  end
end

--- Create a function which executes in an async context but
--- called from a non-async context.
--- @tparam function func
function M.void(func)
  vim.validate{ func = { func , 'function' } }
  return function(...)
    if M.running() then
      return func(...)
    end
    return execute(func, nil, ...)
  end
end

--- Creates an async function with a callback style function.
--- @tparam function func A callback style function to be converted. The last argument must be the callback.
--- @tparam integer argc The number of arguments of func. Must be included.
--- @tparam boolean protected call the function in protected mode (like pcall)
--- @return function Returns an async function
function M.wrap(func, argc, protected)
  vim.validate{
    argc = { argc, 'number' },
    protected = { protected, 'boolean', true }
  }
  return function(...)
    if not M.running() then
      return func(...)
    end
    return coroutine.yield(argc, protected, func, ...)
  end
end

--- Run a collection of async functions (`thunks`) concurrently and return when
--- all have finished.
--- @tparam function[] thunks
--- @tparam integer n Max number of thunks to run concurrently
--- @tparam function interrupt_check Function to abort thunks between calls
function M.join(thunks, n, interrupt_check )
  local function run(finish)
    if #thunks == 0 then
      return finish()
    end

    local remaining = { select(n + 1, unpack(thunks)) }
    local to_go = #thunks

    local ret = {}

    local function cb(...)
      ret[#ret+1] = {...}
      to_go = to_go - 1
      if to_go == 0 then
        finish(ret)
      elseif not interrupt_check or not interrupt_check() then
        if #remaining > 0 then
          local next_task = table.remove(remaining)
          next_task(cb)
        end
      end
    end

    for i = 1, math.min(n, #thunks) do
      thunks[i](cb)
    end
  end

  if not M.running() then
    return run
  end
  return coroutine.yield(1, false, run)
end

--- Partially applying arguments to an async function
--- @tparam function fn
--- @param ... arguments to apply to `fn`
function M.curry(fn, ...)
  local args = {...}
  local nargs = select('#', ...)
  return function(...)
    local other = {...}
    for i = 1, select('#', ...) do
      args[nargs+i] = other[i]
    end
    fn(unpack(args))
  end
end

--- An async function that when called will yield to the Neovim scheduler to be
--- able to call the API.
M.scheduler = M.wrap(vim.schedule, 1, false)

return M
