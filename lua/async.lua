local core = require('async.core')
local validate = require('async._compat').validate
local runtime = core._runtime

local M = require('async.nvim')

-- bind_nvim_runtime()

--- Initialize async runtime for non-Neovim environments.
---
--- In Neovim, initialization happens automatically. Only call this if you're
--- using the library outside of Neovim or you want to override the detected
--- runtime bindings.
---
--- See README.md for details on using async in non-Neovim environments.
---
--- @param opts table Configuration table with fields:
---   - wait (function): Block main thread and run event loop until predicate
---     returns true or timeout. Signature: wait(timeout, predicate) -> boolean
---   - schedule (function): Defer callback to next event loop iteration.
---     Signature: schedule(callback) -> nil
---   - new_timer (function, optional): Create a new timer handle.
---     The returned object must have `:start(ms, repeat, callback)` and
---     `:close(callback?)` methods (compatible with libuv timer interface).
---     Required for `async.sleep()` and `async.timeout()`.
function M.init(opts)
  validate('opts', opts, 'table')
  validate('opts.wait', opts.wait, 'callable')
  validate('opts.schedule', opts.schedule, 'callable')

  if opts.new_timer ~= nil then
    validate('opts.new_timer', opts.new_timer, 'callable')
  end

  runtime.wait = opts.wait
  runtime.schedule = opts.schedule
  runtime.new_timer = opts.new_timer
end

return M
