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

---Creates an async function with a callback style function.
---@param func function A callback style function to be converted. The last argument must be the callback.
---@param argc number The number of arguments of func. Must be included.
---@param protected boolean call the function in protected mode (like pcall)
---@return function Returns an async function
function M.wrap(func, argc, protected)
  assert(argc)
  return function(...)
    if coroutine.running() == main_co_or_nil then
      return func(...)
    end
    return coroutine.yield(func, argc, protected, ...)
  end
end

---Create a function which executes in an async context but
---called from a non-async context. Inherently this cannot return anything
---since it is non-blocking
---@param func function
function M.void(func)
  return function(...)
    if coroutine.running() ~= main_co_or_nil then
      return func(...)
    end

    local co = coroutine.create(func)

    local function step(...)
      local ret = {coroutine.resume(co, ...)}
      local stat, err_or_fn, nargs, protected = unpack(ret)

      if not stat then
        error(string.format("The coroutine failed with this message: %s\n%s",
          err_or_fn, debug.traceback(co)))
      end

      if coroutine.status(co) == 'dead' then
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
end

---An async function that when called will yield to the Neovim scheduler to be
---able to call the API.
M.scheduler = M.wrap(vim.schedule, 1, false)

return M
