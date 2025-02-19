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
    local done = false
    arun(function()
      --- @type integer
      local code1 = await(3, vim.uv.spawn, 'echo', { args = { 'foo' } })
      assert(code1 == 0)

      --- @type integer
      local code2 = await(3, vim.uv.spawn, 'echo', { args = { 'bar' } })
      assert(code2 == 0)

      done = true
    end):wait(1000)

    assert(done)
  end)

  it_exec('callback function can be closed', function()
    local timer = nil

    local task = arun(function()
      await(1, function(_callback)
        -- Never call callback
        timer = assert(vim.uv.new_timer())
        return timer -- Note timer has a close method
      end)
    end)

    task:close()

    local ok, err = task:pwait(1000)

    assert(not ok and err == 'closed', task:traceback(err))
    assert(timer)
    assert(timer and timer:is_closing())
  end)

  -- Same as test above but uses async and awrap
  it_exec('callback function can be closed (2)', function()
    local timer = nil

    local wfn = awrap(1, function(_callback)
      timer = assert(vim.uv.new_timer())
      -- Never call callback
      return {
        close = function(_, cb)
          timer:close(cb)
        end,
      }
    end)

    local fn = async(function()
      wfn()
    end)

    local task = fn()

    task:close()

    local ok, err = task:pwait(1000)

    assert(not ok and err == 'closed', task:traceback(err))
    assert(timer and timer:is_closing() == true)
  end)

  it_exec('callback function can be closed (nested)', function()
    local timer = nil

    local task = arun(function()
      await(arun(function()
        await(1, function(_callback)
          timer = assert(vim.uv.new_timer())
          -- Never call callback
          return {
            close = function(_, cb)
              timer:close(cb)
            end,
          }
        end)
      end))
    end)

    task:close()

    local ok, err = task:pwait(1000)
    assert(not ok and err == 'closed', task:traceback(err))
    assert(timer and timer:is_closing() == true)
  end)

  it_exec('can timeout tasks', function()
    local timer = nil
    local task = arun(function()
      await(1, function(_callback)
        timer = assert(vim.uv.new_timer())
        -- Never call callback
        return {
          close = function(_, cb)
            timer:close(cb)
          end,
        }
      end)
    end)

    local ok, err = task:pwait(1)

    assert(not ok and err == 'timeout', task:traceback(err))
    task:close()

    -- Can use wait() again to wait for the task to close
    ok, err = task:pwait()

    assert(not ok and err == 'closed', err)
    assert(timer and timer:is_closing() == true)
  end)

  it_exec('handle tasks that error LLL', function()
    local timer = nil
    local task = arun(function()
      await(1, function(callback)
        timer = assert(vim.uv.new_timer())
        timer:start(1, 0, callback)
        return {
          close = function(_, cb)
            timer:close(cb)
          end,
        }
      end)
      schedule()
      error('GOT HERE')
    end)

    local ok, err = task:pwait(10)

    assert(not ok, 'Expected error')
    assert(assert(err):match('GOT HERE'), task:traceback(err))
    assert(timer and timer:is_closing() == true, 'Timer is not closing')
  end)

  it_exec('can wait on an empty task', function()
    local did_cb = false
    local a = 1

    local task = arun(function()
      a = a + 1
    end)

    task:await(function()
      assert(a == 2)
      did_cb = true
    end)

    task:wait(100)

    assert(did_cb)
  end)

  it_exec('can iterate tasks', function()
    local tasks = {} --- @type vim.async.Task[]

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
      for i, err, result in Async.iter(tasks) do
        results[i] = { err, result }
      end
    end):wait(1000)

    assert(
      vim.deep_equal(expected, results),
      ('%s does not equal %s'):format(vim.inspect(results), vim.inspect(expected))
    )
  end)

  it_exec('can await a arun task', function()
    local a = assert(arun(function()
      return await(arun(function()
        await(1, vim.schedule)
        return 'JJ'
      end))
    end):wait(10))

    assert(a == 'JJ')
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
      for i, err, result in Async.iter({ task }) do
        results[i] = { err, result }
      end
      error('GOT HERE')
    end)

    local ok, err = task2:pwait(1000)
    assert(not ok and err:match('GOT HERE'), task:traceback(err))

    assert(
      vim.deep_equal(expected, results),
      ('%s does not equal %s'):format(vim.inspect(results), vim.inspect(expected))
    )
  end)

  -- TODO: test error message has correct stack trace when:
  -- task finishes with no continuation
  -- task finishes with synchronous wait
  -- nil in results
end)
