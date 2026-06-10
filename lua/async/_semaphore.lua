local util = require('async._util')
local compat = require('async._compat')
local new_event = require('async._event')

--- A semaphore manages an internal counter which is decremented by each
--- `acquire()` call and incremented by each `release()` call. The counter can
--- never go below zero; when `acquire()` finds that it is zero, it blocks,
--- waiting until some task calls `release()`.
---
--- The preferred way to use a Semaphore is with the `with()` method, which
--- automatically acquires and releases the semaphore around a function call.
--- @class vim.async.Semaphore
--- @field private _permits integer
--- @field private _max_permits integer
--- @field package _event vim.async.Event
local Semaphore = {}
Semaphore.__index = Semaphore

--- Executes a function within the semaphore.
---
--- This acquires the semaphore before running the function and releases it
--- after the function completes, even if it errors.
--- @async
--- @generic R
--- @param fn async fun(): R... # Function to execute within the semaphore's context.
--- @return R... # Result(s) of the executed function.
function Semaphore:with(fn)
  self:acquire()
  -- This pcall is only a try/finally guard for release(); all errors are
  -- immediately rethrown so it is not an async recovery boundary.
  local r = util.pack_len(pcall(fn))
  self:release()
  local stat = r[1]
  if not stat then
    local err = r[2]
    error(err)
  end
  return util.unpack_len(r, 2)
end

--- Acquire a semaphore.
---
--- If the internal counter is greater than zero, decrement it by `1` and
--- return immediately. If it is `0`, wait until a `release()` is called.
--- @async
function Semaphore:acquire()
  self._event:wait()
  self._permits = self._permits - 1
  assert(self._permits >= 0, 'Semaphore value is negative')
  if self._permits == 0 then
    self._event:clear()
  end
end

--- Release a semaphore.
---
--- Increments the internal counter by `1`. Can wake
--- up a task waiting to acquire the semaphore.
function Semaphore:release()
  if self._permits >= self._max_permits then
    error('Semaphore value is greater than max permits', 2)
  end
  self._permits = self._permits + 1
  self._event:set(1)
end

--- Create an async semaphore that allows up to a given number of acquisitions.
--- @param permits? integer (default: 1)
--- @return vim.async.Semaphore
local function new_semaphore(permits)
  compat.validate('permits', permits, 'number', true)
  permits = permits or 1
  local obj = setmetatable({
    _max_permits = permits,
    _permits = permits,
    _event = new_event(),
  }, Semaphore)
  obj._event:set()
  return obj
end

return new_semaphore
