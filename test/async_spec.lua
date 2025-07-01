local helpers = require('nvim-test.helpers')
local exec_lua = helpers.exec_lua

-- TODO: test error message has correct stack trace when:
-- task finishes with no continuation
-- task finishes with synchronous wait
-- nil in results

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
      _G.run = Async.run
      _G.wrap = Async.wrap

      function _G.check_timer(weak)
        assert(weak.timer and weak.timer:is_closing(), 'Timer is not closing')
        collectgarbage('collect')
        assert(not next(weak), 'Resources not collected')
      end

      function _G.check_task_err(task, pat)
        local ok, err = task:pwait(10)
        assert(not ok and err:match(pat), task:traceback(err))
      end

      function _G.eq(expected, actual)
        assert(
          vim.deep_equal(expected, actual),
          ('%s does not equal %s'):format(vim.inspect(actual), vim.inspect(expected))
        )
      end
    end)
  end)

  it_exec('can await a uv callback function', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local done = false

    --- @param path string
    --- @param options uv.spawn.options
    --- @param on_exit fun(code: integer, signal: integer)
    --- @return uv.uv_process_t handle
    local function spawn(path, options, on_exit)
      local obj = vim.uv.spawn(path, options, on_exit)
      table.insert(weak, obj)
      return obj
    end

    run(function()
      local code1 = await(3, spawn, 'echo', { args = { 'foo' } })
      assert(code1 == 0)

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

    local task = run(function()
      await(1, function(_callback)
        -- Never call callback
        local timer = vim.uv.new_timer()
        weak.timer = timer
        return timer --[[@as async.Closable]]
      end)
    end)

    task:close()

    check_task_err(task, 'closed')
    check_timer(weak)
  end)

  it_exec('callback function can be double closed', function()
    --- @type { timer: uv.uv_timer_t? }
    local weak = setmetatable({}, { __mode = 'v' })

    local task = run(function()
      await(1, function(callback)
        -- Never call callback
        local timer = assert(vim.uv.new_timer())
        weak.timer = timer

        -- prematurely close the timer
        timer:close(callback)
        return timer --[[@as vim.async.Closable]]
      end)

      return 'FINISH'
    end)

    check_task_err(task, 'handle .* is already closing')
    check_timer(weak)
  end)

  -- Same as test above but uses async and wrap
  it_exec('callback function can be closed (2)', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local wfn = wrap(1, function(_callback)
      -- Never call callback
      local timer = vim.uv.new_timer()
      weak.timer = timer
      return timer --[[@as vim.async.Closable]]
    end)

    local task = run(function()
      wfn()
    end)

    task:close()

    check_task_err(task, 'closed')
    check_timer(weak)
  end)

  it_exec('callback function can be closed (nested)', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local task = run(function()
      await(run(function()
        await(function(_callback)
          -- Never call callback
          local timer = assert(vim.uv.new_timer())
          weak.timer = timer
          return timer --[[@as vim.async.Closable]]
        end)
      end))
    end)

    task:close()

    check_task_err(task, 'closed')
    check_timer(weak)
  end)

  it_exec('can timeout tasks', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local task = run(function()
      await(function(_callback)
        -- Never call callback
        local timer = assert(vim.uv.new_timer())
        weak.timer = timer
        return timer --[[@as vim.async.Closable]]
      end)
    end)

    check_task_err(task, 'timeout')
    task:close()
    check_task_err(task, 'closed')
    check_timer(weak)
  end)

  it_exec('handle tasks that error', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local task = run(function()
      await(function(callback)
        local timer = assert(vim.uv.new_timer())
        timer:start(1, 0, callback)
        weak.timer = timer
        return timer --[[@as vim.async.Closable]]
      end)
      await(vim.schedule)
      error('GOT HERE')
    end)

    check_task_err(task, 'GOT HERE')
    check_timer(weak)
  end)

  it_exec('handle tasks that complete', function()
    local weak = setmetatable({}, { __mode = 'v' })

    local task = run(function()
      await(function(callback)
        local timer = assert(vim.uv.new_timer())
        timer:start(1, 0, callback)
        weak.timer = timer
        return timer --[[@as vim.async.Closable]]
      end)
      await(vim.schedule)
    end)

    task:wait(10)
    check_timer(weak)
  end)

  it_exec('can wait on an empty task', function()
    local did_cb = false
    local a = 1

    local task = run(function()
      a = a + 1
    end)

    task:wait(function()
      did_cb = true
    end)

    task:wait(100)

    assert(a == 2)
    assert(did_cb)
  end)

  it_exec('can iterate tasks', function()
    local tasks = {} --- @type async.Task<any>[]

    local expected = {} --- @type table[]

    for i = 1, 10 do
      tasks[i] = run(function()
        if i % 2 == 0 then
          await(vim.schedule)
        end
        return 'FINISH', i
      end)
      expected[i] = { nil, { 'FINISH', i } }
    end

    local results = {} --- @type table[]
    run(function()
      for i, err, r1, r2 in Async.iter(tasks) do
        results[i] = { err, { r1, r2 } }
      end
    end):wait(1000)

    eq(expected, results)
  end)

  it_exec('can await a run task', function()
    local a = run(function()
      return await(run(function()
        await(vim.schedule)
        return 'JJ'
      end))
    end):wait(10)

    assert(a == 'JJ', 'GOT ' .. tostring(a))
  end)

  it_exec('handle errors in wrapped functions', function()
    local task = run(function()
      await(function(_callback)
        error('ERROR')
      end)
    end)
    check_task_err(task, 'ERROR')
  end)

  it_exec('iter tasks followed by error', function()
    local task = run(function()
      await(vim.schedule)
      return 'FINISH', 1
    end)

    local expected = { { nil, { 'FINISH', 1 } } }

    local results = {} --- @type table[]
    local task2 = run(function()
      for i, err, r1, r2 in Async.iter({ task }) do
        assert(not err, err)
        results[i] = { err, { r1, r2 } }
      end
      error('GOT HERE')
    end)

    check_task_err(task2, 'async_spec.lua:%d+: GOT HERE')
    eq(expected, results)
  end)

  it_exec('can provide a traceback for nested tasks', function()
    --- @async
    local function t1()
      await(run(function()
        error('GOT HERE')
      end))
    end

    local task = run(function()
      await(run(function()
        await(run(function()
          await(run(function()
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

  describe('semaphore', function()
    it_exec('runs', function()
      local ret = {}
      run(function()
        local semaphore = Async.semaphore(3)
        local tasks = {} --- @type async.Task<nil>[]
        for i = 1, 5 do
          tasks[#tasks + 1] = run(function()
            semaphore:with(function()
              ret[#ret + 1] = 'start' .. i
              await(vim.schedule)
              ret[#ret + 1] = 'end' .. i
            end)
          end)
        end
        Async.join(tasks)
      end):wait()

      eq({
        'start1',
        'start2',
        'start3',
        -- Launch 3 tasks, semaphore now full, now wait for one to finish
        'end1',
        'start4',
        'end2',
        'start5',
        -- All tasks started, now wait for them to finish
        'end3',
        'end4',
        'end5',
      }, ret)
    end)
  end)

  it_exec('can async timeout a test', function()
    local eternity = run(await, function(_cb)
      -- Never call callback
    end)

    check_task_err(run(Async.timeout, 10, eternity), 'timeout')
  end)

  it_exec('does not allow coroutine.yield', function()
    local task = run(function()
      coroutine.yield('This will cause an error.')
    end)
    local ok, res = task.pwait(task, 10)
    assert(not ok, 'Expected error, got: ' .. tostring(res))
    assert(res == 'Unexpected coroutine.yield')
  end)

  it_exec('does not need new stack frame for non-deferred continuations', function()
    --- @async
    local function deep(n)
      if n == 0 then
        return 'done'
      end
      await(function(cb)
        cb()
      end)
      return deep(n - 1)
    end

    local res = run(function()
      return deep(10000)
    end):wait()
    assert(res == 'done')
  end)

  it_exec('does not close child tasks created outside', function()
    local t1 = run(function()
      Async.sleep(10)
    end)

    local t2, t3

    local parent = run(function()
      t2 = run(function()
        Async.sleep(10)
      end)

      t3 = run(function()
        Async.sleep(10)
      end):detach()

      -- t1 create outside parent, cancellation will not propagate to it
      await(t1)

      -- t2 created inside parent, cancellation will propagate to it
      await(t2)

      -- t3 created inside parent, but is detached, cancellation will not
      -- propagate to it
      await(t3)
    end)

    parent:close()

    do
      local ok, err = parent:pwait()
      assert(not ok)
      assert(err == 'closed')
    end

    t1:wait() -- was not closed

    do
      local ok, err = t2:pwait()
      assert(not ok)
      assert(err == 'closed', err)
    end

    t3:wait() -- was not closed
  end)
end)
