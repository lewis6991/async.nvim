local helpers = require('nvim-test.helpers')
local exec_lua = helpers.exec_lua

--- @param s string
--- @param f fun()
local function it_exec(s, f)
  it(s, function()
    exec_lua(f)
  end)
end

describe('async', function()
  before_each(function()
    helpers.clear()
    exec_lua('package.path = ...', package.path)

    exec_lua(function()
      _G.Async = require('async')
      _G.await = Async.await
      _G.arun = Async.arun
      _G.async = Async.async
      _G.awrap = Async.awrap
      _G.schedule = Async.schedule
    end)
  end)

  it_exec('can await a uv callback function', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local done = false

    local function spawn(...)
      local obj = vim.uv.spawn(...)
      table.insert(weak, obj)
      return obj
    end

    arun(function()
      --- @type integer
      local code1 = await(3, spawn, 'echo', { args = { 'foo' } })
      assert(code1 == 0)

      --- @type integer
      local code2 = await(3, spawn, 'echo', { args = { 'bar' } })
      assert(code2 == 0)

      done = true
    end):wait(1000)

    assert(done)

    collectgarbage('collect')
    assert(not next(weak), 'Resources not collected')
  end)

  it_exec('callback function can be closed', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local task = arun(function()
      await(1, function(_callback)
        -- Never call callback
        local timer = vim.uv.new_timer()
        weak.timer = timer
        return timer
      end)
    end)

    task:close()

    local ok, err = task:pwait(1000)

    assert(not ok and err == 'closed', task:traceback(err))
    assert(weak.timer)
    assert(weak.timer:is_closing())

    collectgarbage('collect')
    assert(not next(weak), 'Resources not collected')
  end)

  -- Same as test above but uses async and awrap
  it_exec('callback function can be closed (2)', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local wfn = awrap(1, function(_callback)
      -- Never call callback
      local timer = vim.uv.new_timer()
      weak.timer = timer
      return timer
    end)

    local fn = async(function()
      wfn()
    end)

    local task = fn()

    task:close()

    local ok, err = task:pwait(1000)

    assert(not ok and err == 'closed', task:traceback(err))
    assert(weak.timer and weak.timer:is_closing() == true)

    collectgarbage('collect')
    assert(not next(weak), 'Resources not collected')
  end)

  it_exec('callback function can be closed (nested)', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local task = arun(function()
      await(arun(function()
        await(1, function(_callback)
          -- Never call callback
          local timer = assert(vim.uv.new_timer())
          weak.timer = timer
          return timer
        end)
      end))
    end)

    task:close()

    local ok, err = task:pwait(1000)
    assert(not ok and err == 'closed', task:traceback(err))
    assert(weak.timer and weak.timer:is_closing() == true)

    collectgarbage('collect')
    assert(not next(weak), 'Resources not collected')
  end)

  it_exec('can timeout tasks', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local task = arun(function()
      await(1, function(_callback)
        -- Never call callback
        local timer = assert(vim.uv.new_timer())
        weak.timer = timer
        return timer
      end)
    end)

    do
      local ok, err = task:pwait(1)
      assert(not ok and err == 'timeout', task:traceback(err))
      task:close()
    end

    -- Can use wait() again to wait for the task to close
    local ok, err = task:pwait(1000)
    assert(not ok and err == 'closed', err)
    assert(weak.timer and weak.timer:is_closing() == true)

    collectgarbage('collect')
    assert(not next(weak), 'Resources not collected')
  end)

  it_exec('handle tasks that error', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local task = arun(function()
      await(1, function(callback)
        local timer = assert(vim.uv.new_timer())
        timer:start(1, 0, callback)
        weak.timer = timer
        return timer
      end)
      schedule()
      error('GOT HERE')
    end)

    local ok, err = task:pwait(10)

    assert(not ok, 'Expected error')
    assert(assert(err):match('GOT HERE'), task:traceback(err))

    assert(weak.timer and weak.timer:is_closing() == true, 'Timer is not closing')

    collectgarbage('collect')
    assert(not next(weak), 'Resources not collected')
  end)

  it_exec('handle tasks that complete', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local task = arun(function()
      await(1, function(callback)
        local timer = assert(vim.uv.new_timer())
        timer:start(1, 0, callback)
        weak.timer = timer
        return timer
      end)
      schedule()
    end)

    task:wait(10)

    assert(weak.timer and weak.timer:is_closing() == true, 'Timer is not closing')

    collectgarbage('collect')
    assert(not next(weak), 'Resources not collected')
  end)

  it_exec('can wait on an empty task', function()
    local did_cb = false
    local a = 1

    local task = arun(function()
      a = a + 1
    end)

    task:await(function()
      did_cb = true
    end)

    task:wait(100)

    assert(a == 2)
    assert(did_cb)
  end)

  it_exec('can iterate tasks', function()
    local tasks = {} --- @type async.Task[]

    local expected = {} --- @type table[]

    for i = 1, 10 do
      tasks[i] = arun(function()
        if i % 2 == 0 then
          schedule()
        end
        return 'FINISH', i
      end)
      expected[i] = { nil, { 'FINISH', i } }
    end

    local results = {} --- @type table[]
    arun(function()
      for i, err, r1, r2 in Async.iter(tasks) do
        results[i] = { err, { r1, r2 } }
      end
    end):wait(1000)

    assert(
      vim.deep_equal(expected, results),
      ('%s does not equal %s'):format(vim.inspect(results), vim.inspect(expected))
    )
  end)

  it_exec('can await a arun task', function()
    local a = arun(function()
      return await(arun(function()
        await(1, vim.schedule)
        return 'JJ'
      end))
    end):wait(10)

    assert(a == 'JJ', 'GOT ' .. tostring(a))
  end)

  it_exec('handle errors in wrapped functions', function()
    local task = arun(function()
      await(1, function(_callback)
        error('ERROR')
      end)
    end)
    local ok, err = task:pwait(100)
    assert(not ok and err:match('ERROR'))
  end)

  it_exec('iter tasks followed by error', function()
    local task = arun(function()
      schedule()
      return 'FINISH', 1
    end)

    local expected = { { nil, { 'FINISH', 1 } } }

    local results = {} --- @type table[]
    local task2 = arun(function()
      for i, err, r1, r2 in Async.iter({ task }) do
        assert(not err, err)
        results[i] = { err, { r1, r2 } }
      end
      error('GOT HERE')
    end)

    local ok, err = task2:pwait(1000)
    assert(not ok and err:match('async_spec.lua:%d+: GOT HERE'), task2:traceback(err))

    assert(
      vim.deep_equal(expected, results),
      ('%s does not equal %s'):format(vim.inspect(results), vim.inspect(expected))
    )
  end)

  it_exec('can provide a traceback for nested tasks', function()
    local function t1()
      await(arun(function()
        error('GOT HERE')
      end))
    end

    local task = arun(function()
      await(arun(function()
        await(arun(function()
          await(arun(function()
            t1()
          end))
        end))
      end))
    end)

    -- Normal tracebacks look like:
    -- > stack traceback:
    -- >         [C]: in function 'error'
    -- >         test/async_spec.lua:312: in function 'a'
    -- >         test/async_spec.lua:315: in function 'b'
    -- >         test/async_spec.lua:318: in function 'c'
    -- >         test/async_spec.lua:320: in function <test/async_spec.lua:310>
    -- >         [C]: in function 'xpcall'
    -- >         test/async_spec.lua:310: in function <test/async_spec.lua:297>
    -- >         [string "<nvim>"]:2: in main chunk

    local ok, err = task:pwait(1000)
    assert(not ok)

    local m = [[test/async_spec.lua:%d+: GOT HERE
stack traceback:
        %[thread: 0x%x+%] %[C%]: in function 'error'
        %[thread: 0x%x+%] test/async_spec.lua:%d+: in function <test/async_spec.lua:%d+>
        %[thread: 0x%x+%] test/async_spec.lua:%d+: in function 't1'
        %[thread: 0x%x+%] test/async_spec.lua:%d+: in function <test/async_spec.lua:%d+>
        %[thread: 0x%x+%] test/async_spec.lua:%d+: in function <test/async_spec.lua:%d+>
        %[thread: 0x%x+%] test/async_spec.lua:%d+: in function <test/async_spec.lua:%d+>
        %[thread: 0x%x+%] test/async_spec.lua:%d+: in function <test/async_spec.lua:%d+>]]

    local tb = task:traceback(err):gsub('\t', '        ')
    assert(tb:match(m), 'ERROR: ' .. tb)
  end)

  -- TODO: test error message has correct stack trace when:
  -- task finishes with no continuation
  -- task finishes with synchronous wait
  -- nil in results
end)
