#!/usr/bin/env -S nvim -l

package.path = vim.fn.getcwd() .. '/lua/?.lua;' .. package.path

local async = require('async')

local hrtime = vim.uv and vim.uv.hrtime or vim.loop.hrtime

local benches = {}

--- @param name string
--- @param count integer
--- @param fn fun()
local function bench(name, count, fn)
  benches[#benches + 1] = {
    name = name,
    count = count,
    fn = fn,
  }
end

local function collect()
  collectgarbage('collect')
  collectgarbage('collect')
end

--- @param count integer
--- @param fn fun()
local function time_case(count, fn)
  collect()
  for _ = 1, math.max(1, math.floor(count / 20)) do
    fn()
  end
  collect()

  local start = hrtime()
  for _ = 1, count do
    fn()
  end
  return (hrtime() - start) / count / 1000
end

--- @param count integer
--- @param fn fun()
local function mem_case(count, fn)
  collect()
  collectgarbage('stop')
  local before = collectgarbage('count')
  for _ = 1, count do
    fn()
  end
  local after = collectgarbage('count')
  collectgarbage('restart')
  collect()
  return (after - before) * 1024 / count
end

local function sync_callback(callback)
  callback()
end

local function sync_callback_value(callback)
  callback(1, 2, 3)
end

local function callback_arg(value, callback)
  callback(value)
end

bench('run empty task', 50000, function()
  async.run(function() end):wait()
end)

bench('run returns values', 50000, function()
  async
    .run(function()
      return 1, 2, 3
    end)
    :wait()
end)

bench('run errors', 30000, function()
  async
    .run(function()
      error('fail', 0)
    end)
    :pwait()
end)

bench('await sync callback x100', 3000, function()
  async
    .run(function()
      for _ = 1, 100 do
        async.await(sync_callback)
      end
    end)
    :wait()
end)

bench('await sync callback values x100', 3000, function()
  async
    .run(function()
      for _ = 1, 100 do
        async.await(sync_callback_value)
      end
    end)
    :wait()
end)

bench('await argc callback x100', 3000, function()
  async
    .run(function()
      for _ = 1, 100 do
        async.await(2, callback_arg, 1)
      end
    end)
    :wait()
end)

local resolved = async.run(function()
  return 1
end)
resolved:wait()

bench('await resolved task x100', 3000, function()
  async
    .run(function()
      for _ = 1, 100 do
        async.await(resolved)
      end
    end)
    :wait()
end)

bench('pawait resolved task x100', 3000, function()
  async
    .run(function()
      for _ = 1, 100 do
        async.pawait(resolved)
      end
    end)
    :wait()
end)

bench('await schedule x20', 1000, function()
  async
    .run(function()
      for _ = 1, 20 do
        async.await(vim.schedule)
      end
    end)
    :wait()
end)

bench('spawn and await children x50', 1000, function()
  async
    .run(function()
      local tasks = {}
      for i = 1, 50 do
        tasks[i] = async.run(function()
          return i
        end)
      end
      for _, task in ipairs(tasks) do
        async.await(task)
      end
    end)
    :wait()
end)

bench('implicit child finalization x50', 1000, function()
  async
    .run(function()
      for i = 1, 50 do
        async.run(function()
          return i
        end)
      end
    end)
    :wait()
end)

print(('%-34s %11s %11s %8s'):format('benchmark', 'us/op', 'B/op', 'n'))
print(
  ('%-34s %11s %11s %8s'):format(
    string.rep('-', 34),
    string.rep('-', 11),
    string.rep('-', 11),
    string.rep('-', 8)
  )
)

for _, case in ipairs(benches) do
  local us = time_case(case.count, case.fn)
  local bytes = mem_case(math.max(10, math.floor(case.count / 10)), case.fn)
  print(('%-34s %11.3f %11.1f %8d'):format(case.name, us, bytes, case.count))
end
