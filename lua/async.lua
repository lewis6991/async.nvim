--- Small async library for Neovim plugins
--- @module async

local M = {}

-- Coroutine.running() was changed between Lua 5.1 and 5.2:
-- - 5.1: Returns the running coroutine, or nil when called by the main thread.
-- - 5.2: Returns the running coroutine plus a boolean, true when the running
--   coroutine is the main one.
--
-- For LuaJIT, 5.2 behaviour is enabled with LUAJIT_ENABLE_LUA52COMPAT
--
-- We need to handle both.
local main_co_or_nil = coroutine.running()

local function execute(func, callback, ...)
  local co = coroutine.create(func)

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
      local ok, err = pcall(err_or_fn, unpack(args, 1, nargs))
      if not ok then
        step(false, err)
      end
    else
      args[nargs] = step
      err_or_fn(unpack(args, 1, nargs))
    end
  end

  step(...)
end

--- Use this to create a function which executes in an async context but
--- called from a non-async context. Inherently this cannot return anything
--- since it is non-blocking
--- @tparam function func
--- @tparam number argc The number of arguments of func. Defaults to 0
function M.create(func, argc)
  argc = argc or 0
  return function(...)
    if coroutine.running() ~= main_co_or_nil then
      return func(...)
    end
    local callback = select(argc+1, ...)
    execute(func, callback, unpack({...}, 1, argc))
  end
end

--- Create a function which executes in an async context but
--- called from a non-async context.
--- @tparam function func
function M.void(func)
  return function(...)
    if coroutine.running() ~= main_co_or_nil then
      return func(...)
    end
    execute(func, nil, ...)
  end
end

--- Creates an async function with a callback style function.
--- @tparam function func A callback style function to be converted. The last argument must be the callback.
--- @tparam integer argc The number of arguments of func. Must be included.
--- @tparam boolean protected call the function in protected mode (like pcall)
--- @return function Returns an async function
function M.wrap(func, argc, protected)
  assert(argc)
  return function(...)
    if coroutine.running() == main_co_or_nil then
      return func(...)
    end
    return coroutine.yield(argc, protected, func, ...)
  end
end

--- Run a collection of async functions (`thunks`) concurrently and return when
--- all have finished.
--- @tparam integer n Max number of thunks to run concurrently
--- @tparam function interrupt_check Function to abort thunks between calls
--- @tparam function[] thunks
function M.join(n, interrupt_check, thunks)
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
