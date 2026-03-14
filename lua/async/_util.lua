local M = {}

--- @param ... any
--- @return {[integer]: any, n: integer}
function M.pack_len(...)
  return { n = select('#', ...), ... }
end

--- like unpack() but use the length set by F.pack_len if present
--- @param t? { [integer]: any, n?: integer }
--- @param first? integer
--- @return any...
function M.unpack_len(t, first)
  if t then
    return unpack(t, first or 1, t.n or table.maxn(t))
  end
end

--- is_callable helper - uses vim.is_callable when available, custom impl otherwise
local is_callable
if vim and vim.is_callable then
  is_callable = vim.is_callable
else
  is_callable = function(obj)
    local t = type(obj)
    if t == 'function' then
      return true
    end
    if t == 'table' then
      local mt = getmetatable(obj)
      return mt and type(mt.__call) == 'function'
    end
    return false
  end
end

--- validate helper - uses vim.validate when available, custom impl otherwise
local validate
if vim and vim.validate then
  validate = vim.validate
else
  --- @param name string
  --- @param value any
  --- @param expected_type string
  --- @param optional? boolean
  validate = function(name, value, expected_type, optional)
    if optional and value == nil then
      return
    end

    local actual_type = type(value)
    local valid = false

    if expected_type == 'callable' then
      valid = is_callable(value)
    elseif expected_type == 'table' then
      valid = actual_type == 'table'
    elseif expected_type == 'number' then
      valid = actual_type == 'number'
    else
      error(string.format('validate: unsupported type "%s"', expected_type), 2)
    end

    if not valid then
      local got = expected_type == 'callable' and (is_callable(value) and 'callable' or actual_type)
        or actual_type
      error(string.format('%s: expected %s, got %s', name, expected_type, got), 2)
    end
  end
end

--- @param obj any
--- @return boolean
--- @return_cast obj function
function M.is_callable(obj)
  return is_callable(obj)
end

M.validate = validate

--- Create a function that runs a function when it is garbage collected.
--- @generic F : function
--- @param f F
--- @param gc fun()
--- @return F
function M.gc_fun(f, gc)
  local proxy = newproxy(true)
  local proxy_mt = getmetatable(proxy)
  proxy_mt.__gc = gc
  proxy_mt.__call = function(_, ...)
    return f(...)
  end

  return proxy
end

return M
