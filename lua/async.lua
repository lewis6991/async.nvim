local M = require('async.core')

if type(vim) == 'table' then
  M.init({
    wait = vim.wait,
    schedule = vim.schedule,
    new_timer = vim.uv.new_timer,
  })
end

return M
