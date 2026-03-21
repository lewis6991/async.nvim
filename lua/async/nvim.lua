local core = require('async.core')
local runtime = core._runtime

runtime.wait = function(timeout, predicate)
  return vim.wait(timeout, predicate)
end

runtime.schedule = function(callback)
  vim.schedule(callback)
end

runtime.new_timer = function()
  return vim.uv.new_timer()
end

local M = {}
for k, v in pairs(core) do
  if k ~= '_runtime' then
    M[k] = v
  end
end

return M --[[@as vim.async]]
