--- @diagnostic disable: global-in-non-module
local helpers = require('nvim-test.helpers')
local exec_lua = helpers.exec_lua

-- TODO: test error message has correct stack trace when:
-- task finishes with no continuation
-- task finishes with synchronous wait
-- nil in results

-- TODO(lewis6991): test for cyclic await
-- - child awaiting an ancestor (not allowed)
-- - cyclic chain with detached tasks

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
      _G.uv_handles = setmetatable({}, { __mode = 'v' })

      --- Keep track of uv handles so we can ensure they are closed
      --- @generic T
      --- @param name string
      --- @param handle T?
      --- @return T - ?
      function _G.add_handle(name, handle)
        uv_handles[name] = assert(handle)
        return handle
      end

      --- Check task eventually completes with an error
      --- @param task vim.async.Task
      --- @param pat string
      --- @return string
      function _G.check_task_err(task, pat)
        local ok, err = task:pwait(10)
        if ok then
          error('Expected task to error, but it completed successfully', 2)
        elseif not err:match('^' .. pat .. '$') then
          error('Unexpected error: ' .. task:traceback(err), 2)
        end
        return err
      end

      --- @param s string
      --- @return { [1]: string, pattern: boolean }
      function _G.p(s)
        return { s, pattern = true }
      end

      --- @param expected any
      --- @param actual any
      --- @param msg? string
      function _G.eq(expected, actual, msg)
        local match
        if
          type(expected) == 'table'
          and type(expected[1]) == 'string'
          and expected.pattern == true
        then
          match = actual:match(expected[1]) ~= nil
          expected = expected[1]
        else
          match = vim.deep_equal(expected, actual)
        end

        if not match then
          if type(actual) == 'string' then
            actual = '\n│  ' .. actual:gsub('\n', '\n│  ')
          else
            actual = vim.inspect(actual)
          end
          if type(expected) == 'string' then
            expected = '\n│  ' .. expected:gsub('\n', '\n│  ')
          else
            expected = vim.inspect(expected)
          end
          error(
            ('%s\n\nactual: %s\n\nexpected: %s'):format(msg or 'Mismatch:', actual, expected),
            2
          )
        end
      end

      --- @async~
      function _G.eternity()
        await(function(_cb)
          -- Never call callback
          return add_handle('timer', vim.uv.new_timer()) --[[@as vim.async.Closable]]
        end)
      end
    end)
  end)

  after_each(function()
    exec_lua(function()
      for k, v in pairs(uv_handles) do
        assert(v:is_closing(), ('uv handle %s is not closing'):format(k))
      end
      collectgarbage('collect')
      assert(not next(uv_handles), 'Resources not collected')
    end)
  end)

  describe('basic operations', function()
    it_exec('can error stack trace on sync wait', function()
      local task = run(function()
        error('SYNC ERR')
      end)
      check_task_err(task, 'test/async_spec.lua:%d+: SYNC ERR')
    end)

    it_exec('can await a uv callback function', function()
      --- @param path string
      --- @param options uv.spawn.options
      --- @param on_exit fun(code: integer, signal: integer)
      --- @return uv.uv_process_t handle
      local function spawn(path, options, on_exit)
        return add_handle('process', vim.uv.spawn(path, options, on_exit))
      end

      local done = run(function()
        local code1 = await(3, spawn, 'echo', { args = { 'foo' } })
        assert(code1 == 0)

        local code2 = await(3, spawn, 'echo', { args = { 'bar' } })
        assert(code2 == 0)
        await(vim.schedule)

        return true
      end):wait(1000)

      eq(true, done)
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

    it_exec('can wait on an empty task', function()
      local did_cb = false
      local a = 1

      local task = run(function()
        -- task does not await anything, should complete immediately
        a = a + 1
      end)

      task:wait(function()
        did_cb = true
      end) -- non-blocking

      task:wait(100) -- blocking

      assert(a == 2)
      assert(did_cb)
    end)

    it_exec('handles tasks that complete', function()
      local task = run(function()
        -- should wait for 1 ms
        await(function(callback)
          local timer = add_handle('timer', vim.uv.new_timer())
          timer:start(1, 0, callback)
          return timer --[[@as vim.async.Closable]]
        end)
        await(vim.schedule)
        return nil, 1
      end)

      local r1, r2 = task:wait(10)
      eq(r1, nil)
      eq(r2, 1)
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

      local err = check_task_err(task, 'test/async_spec.lua:%d+: GOT HERE')

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
  end)

  describe('task cancellation and closing', function()
    it_exec('can close tasks', function()
      local task = run(eternity)
      task:close()
      check_task_err(task, 'closed')
    end)

    it_exec('can close tasks which waiting on a wrapped callback function', function()
      local wfn = wrap(1, function(_callback)
        return add_handle('timer', vim.uv.new_timer()) --[[@as vim.async.Closable]]
      end)

      local task = run(function()
        wfn()
      end)

      task:close()
      check_task_err(task, 'closed')
    end)

    it_exec('gracefully handles when closables are prematurely closed', function()
      local result = run(function()
        await(1, function(callback)
          local timer = add_handle('timer', vim.uv.new_timer())
          timer:close(callback)
          return timer --[[@as vim.async.Closable]]
        end)

        return 'FINISH'
      end):wait()

      eq('FINISH', result)
    end)

    it_exec('callback function can be closed (nested)', function()
      local child --- @type vim.async.Task
      local task = run(function()
        child = run(eternity)
        await(child)
      end)

      task:close()

      check_task_err(task, 'closed')
      check_task_err(child, 'closed')
    end)

    it_exec('can timeout tasks', function()
      local task = run(eternity)
      check_task_err(task, 'timeout')
      task:close()
      check_task_err(task, 'closed')
    end)

    it_exec('can async timeout a test', function()
      local task = run(eternity)
      check_task_err(run(Async.timeout, 10, task), 'timeout')
    end)

    it_exec('closes detached child tasks', function()
      local task1 = run(eternity)
      task1:close()

      local task2 = run(function()
        await(task1)
      end)

      check_task_err(task2, 'closed')
    end)
  end)

  describe('error handling', function()
    it_exec('handles tasks that error', function()
      local task = run(function()
        await(function(callback)
          local timer = add_handle('timer', vim.uv.new_timer())
          timer:start(1, 0, callback)
          return timer --[[@as vim.async.Closable]]
        end)
        await(vim.schedule)
        error('GOT HERE')
      end)

      check_task_err(task, 'test/async_spec.lua:%d+: GOT HERE')
    end)

    it_exec('can handle errors in wrapped functions', function()
      local task = run(function()
        await(function(_callback)
          error('ERROR')
        end)
      end)
      check_task_err(task, 'test/async_spec.lua:%d+: ERROR')
    end)

    it_exec('can pcall errors in wrapped functions', function()
      local task = run(function()
        return pcall(function()
          await(function(_callback)
            error('ERROR')
          end)
        end)
      end)
      local ok, msg = task:wait()
      assert(not ok and msg, 'Expected error, got success')
      assert(msg:match('^test/async_spec.lua:%d+: ERROR$'), 'Got unexpected error: ' .. msg)
    end)

    it_exec('handles when a floating child errors', function()
      local parent = run(function()
        local _child = run(function(...)
          Async.sleep(5)
          error('CHILD ERROR')
        end)
      end)

      check_task_err(parent, 'child error: test/async_spec.lua:%d+: CHILD ERROR')
    end)

    it_exec('handles when a floating child errors and parent errors', function()
      local parent = run(function()
        local _child = run(function(...)
          Async.sleep(5)
          error('CHILD ERROR')
        end)
        error('PARENT ERROR')
      end)

      check_task_err(parent, 'test/async_spec.lua:%d+: PARENT ERROR')
    end)
  end)

  describe('task iteration', function()
    it_exec('can iterate detached tasks', function()
      local tasks = {} --- @type vim.async.Task<any>[]
      local expected = {} --- @type table[]

      for i = 1, 10 do
        tasks[i] = run(function()
          if i % 2 == 0 then
            await(vim.schedule)
          end
          return 'FINISH', i
        end)
        expected[i] = { 'FINISH', i }
      end

      local results = {} --- @type table[]
      run(function()
        for i, r1, r2 in Async.iter(tasks) do
          results[i] = { r1, r2 }
        end
      end):wait(1000)

      eq(expected, results)
    end)

    it_exec('can handle errors when iterating detached tasks', function()
      local results = {} --- @type table[]
      local tasks = {} --- @type vim.async.Task<any>[]

      for i = 1, 10 do
        tasks[i] = run(function()
          await(vim.schedule)
          if i == 3 then
            error('ERROR IN TASK ' .. i)
          end
          return 'FINISH', i
        end)
      end

      local task = run(function()
        for i, r1, r2 in Async.iter(tasks) do
          results[i] = { r1, r2 }
        end
      end)

      check_task_err(task, 'iter error%[index:3%]: test/async_spec.lua:%d+: ERROR IN TASK 3')

      eq({
        { 'FINISH', 1 },
        { 'FINISH', 2 },
      }, results)
    end)

    it_exec('can handle errors when iterating child tasks', function()
      local results = {} --- @type table[]
      local tasks = {} --- @type vim.async.Task<any>[]

      local task = run(function()
        for i = 1, 10 do
          tasks[i] = run(function()
            await(vim.schedule)
            if i == 3 then
              error('ERROR IN TASK ' .. i)
            end
            return 'FINISH', i
          end)
        end

        for i, r1, r2 in Async.iter(tasks) do
          results[i] = { r1, r2 }
        end
      end)

      check_task_err(task, 'child error: test/async_spec.lua:%d+: ERROR IN TASK 3')

      for i = 4, #tasks do
        check_task_err(tasks[i], 'closed')
      end

      eq({
        { 'FINISH', 1 },
        { 'FINISH', 2 },
      }, results)
    end)

    it_exec('can iter tasks followed by error', function()
      local task = run(function()
        await(vim.schedule)
        return 'FINISH', 1
      end)

      local expected = { { 'FINISH', 1 } }
      local results = {} --- @type table[]

      local task2 = run(function()
        for i, r1, r2 in Async.iter({ task }) do
          results[i] = { r1, r2 }
        end
        error('GOT HERE')
      end)

      check_task_err(task2, 'test/async_spec.lua:%d+: GOT HERE')
      eq(expected, results)
    end)

    it_exec('can iter tasks with cancellation', function()
      local tasks = {} --- @type vim.async.Task<any>[]

      for i = 1, 4 do
        tasks[i] = run(function()
          if i == 2 then
            eternity()
          end
          return 'FINISH', i
        end)
      end

      assert(tasks[2]):close()

      local results = {} --- @type table[]
      local task = run(function()
        for i, r1, r2 in Async.iter(tasks) do
          results[i] = { r1, r2 }
        end
      end)

      check_task_err(task, 'iter error%[index:2%]: closed')

      eq({
        [1] = { 'FINISH', 1 },
        [3] = { 'FINISH', 3 },
        [4] = { 'FINISH', 4 },
      }, results)
    end)

    it_exec('can iter tasks with garbage collection', function()
      --- @param task vim.async.Task
      --- @return integer
      local function get_task_callback_count(task)
        --- @diagnostic disable-next-line: access-invisible
        return vim.tbl_count(task._future._callbacks)
      end

      local task = run(eternity)

      local t = run(function()
        local i = Async.iter({ task })()
        eq(get_task_callback_count(task), 1, 'task should have one callback')
        eq(nil, i)
        collectgarbage('collect')
        eq(get_task_callback_count(task), 0, 'task should have no callbacks')
      end)

      task:close()

      check_task_err(t, 'iter error%[index:1%]: closed')
      check_task_err(task, 'closed')
    end)

    it_exec('await_all tasks with cancellation', function()
      local tasks = {} --- @type vim.async.Task<any>[]

      for i = 1, 4 do
        tasks[i] = run(function()
          if i == 2 then
            eternity()
          end
          return 'FINISH', i
        end)
      end

      assert(tasks[2]):close()

      local t = run(Async.await_all, tasks)
      check_task_err(t, 'iter error%[index:2%]: closed')
    end)
  end)

  describe('child task management', function()
    it_exec('does not close child tasks created outside of parent', function()
      local t1 = run(Async.sleep, 10)
      local t2 --- @type vim.async.Task
      local t3 --- @type vim.async.Task

      local parent = run(function()
        t2 = run(Async.sleep, 10)
        t3 = run(Async.sleep, 10):detach()
        await(t1)
      end)

      parent:close()

      check_task_err(parent, 'closed')
      t1:wait()
      check_task_err(t2, 'closed')
      t3:wait()
    end)

    it_exec('automatically awaits child tasks', function()
      local child1, child2 --- @type vim.async.Task, vim.async.Task
      local main = run(function()
        child1 = run(Async.sleep, 10)
        child2 = run(Async.sleep, 10)
      end)

      main:wait()
      assert(child1:completed())
      assert(child2:completed())
    end)

    it_exec('should not fail the parent task if children finish before parent', function()
      local child1 --- @type vim.async.Task
      local child2 --- @type vim.async.Task
      local main = run(function()
        child1 = run(Async.sleep, 5)
        child2 = run(Async.sleep, 5)
        Async.sleep(20)
      end)

      main:wait()
      child1:wait()
      child2:wait()
    end)

    it_exec('automatically closes suspended child tasks', function()
      local forever_child --- @type vim.async.Task

      local main = run(function()
        forever_child = run(function()
          while true do
            Async.sleep(1)
          end
        end)
        Async.sleep(2)
      end)

      eq(forever_child:status(), 'awaiting')
      main:close()
      check_task_err(main, 'closed')
      check_task_err(forever_child, 'closed')
    end)

    it_exec('should not close the parent task when child task is closed', function()
      run(function()
        run(eternity):close()
      end):wait()
    end)
  end)

  describe('semaphore', function()
    it_exec('runs', function()
      local ret = {}
      run(function()
        local semaphore = Async.semaphore(3)
        local tasks = {} --- @type vim.async.Task<nil>[]
        for i = 1, 5 do
          tasks[#tasks + 1] = run(function()
            semaphore:with(function()
              ret[#ret + 1] = 'start' .. i
              await(vim.schedule)
              ret[#ret + 1] = 'end' .. i
            end)
          end)
        end
        Async.await_all(tasks)
      end):wait()

      eq({
        'start1',
        'start2',
        'start3',
        'end1',
        'start4',
        'end2',
        'start5',
        'end3',
        'end4',
        'end5',
      }, ret)
    end)

    it_exec('ping pong', function()
      local msgs = {}
      local ball = { hits = 0 }
      local max_hits = 10

      --- @async
      --- @param name string
      --- @param sem vim.async.Semaphore
      local function player(name, sem)
        while ball.hits < max_hits do
          local ok, err = pcall(sem.acquire, sem)
          if not ok or ball.hits >= max_hits then
            if not ok and not tostring(err):match('closed') then
              error(err)
            end
            break
          end

          ball.hits = ball.hits + 1
          msgs[#msgs + 1] = name
          Async.sleep(2)
          sem:release()
        end
      end

      run(function()
        local sem = Async.semaphore(1)
        local p1 = run(player, 'ping', sem)
        local p2 = run(player, 'pong', sem)
        Async.await_all({ p1, p2 })
      end):wait()

      eq({ 'ping', 'pong', 'ping', 'pong', 'ping', 'pong', 'ping', 'pong', 'ping', 'pong' }, msgs)
    end)
  end)

  describe('coroutine safety', function()
    it_exec('does not allow coroutine.yield', function()
      local task = run(function()
        coroutine.yield('This will cause an error.')
      end)
      check_task_err(task, 'Unexpected coroutine.yield().*')
    end)

    it_exec('does not allow coroutine.resume', function()
      local co --- @type thread
      local task = run(function()
        co = coroutine.running()
        eternity()
      end)

      local status, err = coroutine.resume(co)
      assert(not status, 'Expected coroutine.resume to fail')
      eq(err, 'Unexpected coroutine.resume()')
      check_task_err(task, 'Unexpected coroutine.resume%(%)')
    end)

    it_exec('does not allow coroutine.resume when awaiting detached task', function()
      local t = run(eternity)
      local co --- @type thread
      local task = run(function()
        co = coroutine.running()
        await(t)
      end)

      local status, err = coroutine.resume(co)
      assert(not status, 'Expected coroutine.resume to fail')
      eq(err, 'Unexpected coroutine.resume()')
      check_task_err(task, 'Unexpected coroutine.resume%(%)')
      t:close()
    end)
  end)

  describe('inspect_tree', function()
    it_exec('outside of tasks', function()
      local parent = run('parent', function()
        run('child1', eternity)
        run('child2', eternity)
        run('child3', function(...)
          run('sub_child1', eternity)
          run('sub_child2', eternity)
          run(eternity)
        end)
      end)

      eq(
        p([=[
parent@test/async_spec.lua:%d+ %[awaiting%]
├─ child1@test/async_spec.lua:%d+ %[awaiting%]
├─ child2@test/async_spec.lua:%d+ %[awaiting%]
└─ child3@test/async_spec.lua:%d+ %[awaiting%]
   ├─ sub_child1@test/async_spec.lua:%d+ %[awaiting%]
   ├─ sub_child2@test/async_spec.lua:%d+ %[awaiting%]
   └─ @test/async_spec.lua:%d+ %[awaiting%]]=]),
        Async._inspect_tree()
      )

      parent:close()
      check_task_err(parent, 'closed')
    end)

    it_exec('inside a task', function()
      local inspect
      local parent = run('parent', function()
        run('child1', eternity)
        run('child2', eternity)
        run('child3', function(...)
          run('sub_child1', eternity)
          run('sub_child2', eternity)
          run(eternity)
          inspect = Async._inspect_tree()
        end)
      end)

      eq(
        p([=[
parent@test/async_spec.lua:%d+ %[normal%]
├─ child1@test/async_spec.lua:%d+ %[awaiting%]
├─ child2@test/async_spec.lua:%d+ %[awaiting%]
└─ child3@test/async_spec.lua:%d+ %[running%]
   ├─ sub_child1@test/async_spec.lua:%d+ %[awaiting%]
   ├─ sub_child2@test/async_spec.lua:%d+ %[awaiting%]
   └─ @test/async_spec.lua:%d+ %[awaiting%]]=]),
        inspect
      )

      parent:close()
      check_task_err(parent, 'closed')
    end)
  end)

  describe('task completion', function()
    it_exec('can complete tasks', function()
      local task = run(eternity)
      task:complete('DONE', 123)
      local res1, res2 = task:wait()
      eq('DONE', res1)
      eq(123, res2)
    end)

    it_exec('can complete tasks with children', function()
      local child --- @type vim.async.Task
      local task = run(function()
        child = run(eternity)
        await(child)
      end)
      task:complete('DONE', 123)
      local r1, r2 = task:wait()
      eq('DONE', r1)
      eq(123, r2)
      check_task_err(child, 'closed')
    end)

    it_exec('handles race condition of children completing parent', function()
      local parent_task --- @type vim.async.Task
      local child2_task --- @type vim.async.Task
      parent_task = run(function()
        run(function()
          Async.sleep(10)
          parent_task:complete('child 1 won')
        end)
        child2_task = run(function()
          Async.sleep(50)
          parent_task:complete('child 2 won')
        end)
        eternity()
      end)

      local result = parent_task:wait(100)
      eq('child 1 won', result)
      check_task_err(child2_task, 'closed')
    end)

    it_exec('handles simultaneous calls to :complete() from scheduler', function()
      local task = run(eternity)
      local second_complete_error --- @type string?

      vim.schedule(function()
        task:complete('first call')
      end)
      vim.schedule(function()
        local ok, err = pcall(function()
          task:complete('second call')
        end)
        if not ok then
          second_complete_error = err
        end
      end)

      local result = task:wait(100)
      eq('first call', result)

      assert(second_complete_error ~= nil, 'Second complete() call should have errored')
      assert(
        second_complete_error:match(
          '^test/async_spec.lua:%d+: Task is already completing or completed$'
        ),
        'Unexpected error message: ' .. second_complete_error
      )
    end)
  end)

  describe('edge-triggered errors and level-triggered cancellations', function()
    it_exec('normal errors are edge-triggered (consumed after first catch)', function()
      local results = {}
      local parent = run(function()
        local _child = run(function()
          Async.sleep(5)
          error('CHILD ERROR')
        end)

        local ok1, err1 = pcall(function()
          Async.sleep(100)
        end)

        if not ok1 then
          results[#results + 1] = 'caught_first'
          results[#results + 1] = err1:match('CHILD ERROR') and 'has_error' or 'no_error'
        end

        local ok2, err2 = pcall(function()
          Async.sleep(1)
        end)

        if not ok2 then
          results[#results + 1] = 'caught_second'
          results[#results + 1] = tostring(err2)
        else
          results[#results + 1] = 'no_second_error'
        end

        Async.sleep(1)
        results[#results + 1] = 'completed_normally'
      end)

      parent:wait(200)

      eq({
        'caught_first',
        'has_error',
        'no_second_error',
        'completed_normally',
      }, results)
    end)

    it_exec('cancellations are level-triggered (persist across catches)', function()
      local results = {}
      local task = run(function()
        local ok1, err1 = pcall(function()
          Async.sleep(100)
        end)

        if not ok1 then
          results[#results + 1] = 'caught_first'
          results[#results + 1] = err1 == 'closed' and 'is_closed' or 'other_error'
        end

        local ok2, err2 = pcall(function()
          Async.sleep(1)
        end)

        if not ok2 then
          results[#results + 1] = 'caught_second'
          results[#results + 1] = err2 == 'closed' and 'is_closed' or 'other_error'
        end

        results[#results + 1] = 'should_not_reach'
      end)

      run(function()
        Async.sleep(1)
        task:close()
      end):wait()

      check_task_err(task, 'closed')

      eq({
        'caught_first',
        'is_closed',
        'caught_second',
        'is_closed',
        'should_not_reach',
      }, results)
    end)

    it_exec('can handle error and continue with recovery logic', function()
      local results = {}
      run(function()
        local _child = run(function()
          Async.sleep(5)
          error('SERVICE UNAVAILABLE')
        end)

        local ok = pcall(function()
          Async.sleep(100)
        end)

        if not ok then
          results[#results + 1] = 'error_caught'
          Async.sleep(1)
          results[#results + 1] = 'recovery_step_1'
          Async.sleep(1)
          results[#results + 1] = 'recovery_step_2'
        end

        results[#results + 1] = 'finished'
      end):wait(200)

      eq({
        'error_caught',
        'recovery_step_1',
        'recovery_step_2',
        'finished',
      }, results)
    end)

    it_exec('cancellation persists even after pcall catches it', function()
      local results = {}
      local task = run(function()
        for i = 1, 5 do
          local ok, err = pcall(function()
            Async.sleep(10)
          end)

          if not ok then
            if err == 'closed' then
              results[#results + 1] = ('closed_iteration_%d'):format(i)
            else
              results[#results + 1] = ('error_iteration_%d'):format(i)
            end
          else
            results[#results + 1] = ('success_iteration_%d'):format(i)
          end
        end
      end)

      run(function()
        Async.sleep(1)
        task:close()
      end):wait()

      check_task_err(task, 'closed')

      eq({
        'closed_iteration_1',
        'closed_iteration_2',
        'closed_iteration_3',
        'closed_iteration_4',
        'closed_iteration_5',
      }, results)
    end)

    it_exec('is_closing() reflects level-triggered cancellation state', function()
      local results = {}
      local task = run(function()
        for _ = 1, 3 do
          results[#results + 1] = ('is_closing_%d'):format(Async.is_closing() and 1 or 0)

          local ok = pcall(function()
            Async.sleep(10)
          end)

          if not ok then
            results[#results + 1] = ('after_catch_is_closing_%d'):format(
              Async.is_closing() and 1 or 0
            )
          end
        end
      end)

      run(function()
        Async.sleep(1)
        task:close()
      end):wait()

      check_task_err(task, 'closed')

      eq({
        'is_closing_0',
        'after_catch_is_closing_1',
        'is_closing_1',
        'after_catch_is_closing_1',
        'is_closing_1',
        'after_catch_is_closing_1',
      }, results)
    end)

    it_exec('multiple child errors - each new error propagates', function()
      local results = {}
      local parent = run(function()
        local _child1 = run(function()
          Async.sleep(5)
          error('ERROR_1')
        end)

        local _child2 = run(function()
          Async.sleep(10)
          error('ERROR_2')
        end)

        local ok1, err1 = pcall(function()
          Async.sleep(100)
        end)

        if not ok1 then
          results[#results + 1] = err1:match('ERROR_1') and 'got_error_1' or 'other'
        end

        local ok2, err2 = pcall(function()
          Async.sleep(100)
        end)

        if not ok2 then
          results[#results + 1] = err2:match('ERROR_2') and 'got_error_2' or 'other'
        end

        results[#results + 1] = 'both_errors_handled'
      end)

      parent:wait(200)

      eq({
        'got_error_1',
        'got_error_2',
        'both_errors_handled',
      }, results)
    end)

    it_exec('task error takes precedence over cancellation when both occur', function()
      local task = run(function()
        pcall(function()
          Async.sleep(10)
        end)

        error('TASK_ERROR')
      end)

      run(function()
        Async.sleep(1)
        task:close()
      end):wait()

      local ok, err = task:pwait(100)
      assert(not ok, 'Expected task to error')
      eq(true, err:match('TASK_ERROR') ~= nil, 'Expected TASK_ERROR, got: ' .. tostring(err))
    end)

    it_exec(
      'cancellation takes precedence when task completes successfully while closing',
      function()
        local results = {}
        local task = run(function()
          for i = 1, 3 do
            local ok = pcall(function()
              Async.sleep(5)
            end)
            if not ok then
              results[#results + 1] = ('iteration_%d_cancelled'):format(i)
            else
              results[#results + 1] = ('iteration_%d_success'):format(i)
            end
          end
          results[#results + 1] = 'completed'
          return 'SUCCESS'
        end)

        run(function()
          Async.sleep(1)
          task:close()
        end):wait()

        check_task_err(task, 'closed')

        assert(#results > 0, 'Expected some iterations to run')
        for _, result in ipairs(results) do
          eq(
            true,
            result:match('cancelled') ~= nil or result == 'completed',
            'Expected cancelled or completed, got: ' .. result
          )
        end
      end
    )
  end)
end)
