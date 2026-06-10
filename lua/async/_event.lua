local async = require('async._core')

--- An event can be used to notify multiple tasks that some event has
--- happened. An Event object manages an internal flag that can be set to true
--- with the `set()` method and reset to `false` with the `clear()` method.
--- The `wait()` method blocks until the flag is set to `true`. The flag is
--- set to `false` initially.
--- @class vim.async.Event
--- @field private _is_set boolean
--- @field private _waiters function[]
local Event = {}
Event.__index = Event

--- Set the event.
---
--- All tasks waiting for event to be set will be immediately awakened.
---
--- If `max_woken` is provided, only up to `max_woken` waiters will be woken.
--- The event will be reset to `false` if there are more waiters remaining.
--- @param max_woken? integer
function Event:set(max_woken)
  if self._is_set then
    return
  end
  self._is_set = true
  local waiters = self._waiters
  local waiters_to_notify = {} --- @type function[]
  max_woken = max_woken or #waiters
  while #waiters > 0 and #waiters_to_notify < max_woken do
    waiters_to_notify[#waiters_to_notify + 1] = table.remove(waiters, 1)
  end
  if #waiters > 0 then
    self._is_set = false
  end
  for _, waiter in ipairs(waiters_to_notify) do
    waiter()
  end
end

--- Wait until the event is set.
---
--- If the event is set, return immediately. Otherwise block until another
--- task calls set().
--- @async
function Event:wait()
  async.await(function(callback)
    if self._is_set then
      callback()
    else
      table.insert(self._waiters, callback)
    end
  end)
end

--- Clear (unset) the event.
---
--- Tasks awaiting on wait() will now block until the set() method is called
--- again.
function Event:clear()
  self._is_set = false
end

--- Create a new event.
---
--- An event can signal to multiple listeners to resume execution.
--- The event can be set from a non-async context.
--- @return vim.async.Event
return function()
  return setmetatable({
    _waiters = {},
    _is_set = false,
  }, Event)
end
