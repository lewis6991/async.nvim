local M = {}

local nil_error = 'error(nil)'

--- Normalize a failed Lua operation for async error slots, where `nil`
--- already means success.
--- @param err any
--- @return any
function M.normalize(err)
  return err == nil and nil_error or err
end

return M
