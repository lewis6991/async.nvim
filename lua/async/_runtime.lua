local validate = require('async._compat').validate

--- @class vim.async.Timer: vim.async.Closable
--- @field start fun(self, timeout: integer, repeat_interval: integer, callback: fun())

--- @alias vim.async.TimerFactory fun(): vim.async.Timer

--- @class vim.async.InitOpts
--- @field wait fun(timeout: integer, predicate: fun(): boolean): boolean Run the event loop until the predicate succeeds or the timeout expires.
--- @field schedule fun(callback: fun()) Run a callback on the next event loop turn.
--- @field new_timer vim.async.TimerFactory Create libuv-compatible timers for `sleep()` and `timeout()`.

--- @class vim.async.Runtime
--- @field wait fun(timeout: integer, predicate: fun(): boolean): boolean
--- @field schedule fun(callback: fun())
--- @field new_timer vim.async.TimerFactory
local M = {}

--- @param opts vim.async.InitOpts
function M.init(opts)
  validate('opts', opts, 'table')
  validate('opts.wait', opts.wait, 'callable')
  validate('opts.schedule', opts.schedule, 'callable')
  validate('opts.new_timer', opts.new_timer, 'callable')

  M.wait = opts.wait
  M.schedule = opts.schedule
  M.new_timer = opts.new_timer
end

return M
