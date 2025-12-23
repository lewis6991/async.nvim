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

  describe('edge case tests', function()
    it_exec('handles awaiting closable that is already closing', function()
      -- Test for potential issue where is_closing() returns true
      local close_count = 0
      local callback_called = false

      local closable = {
        _closing = false,
        is_closing = function(self)
          return self._closing
        end,
        close = function(self, cb)
          close_count = close_count + 1
          self._closing = true
          if cb then
            vim.schedule(cb)
          end
        end,
      }

      local task = run(function()
        -- Start closing the closable
        closable:close()

        -- Now try to await something that returns this already-closing closable
        local result = await(function(callback)
          vim.schedule(function()
            callback('RESULT')
          end)
          return closable
        end)

        callback_called = true
        return result
      end)

      local result = task:wait(100)
      eq('RESULT', result)
      eq(true, callback_called)
      -- The closable should only be closed once (by the explicit close call)
      -- handle_close_awaiting should detect is_closing and not call close again
      eq(1, close_count)
    end)

    it_exec('_is_completing flag prevents multiple complete calls', function()
      -- Test that _is_completing flag works correctly
      local task = run(eternity)
      local errors = {}

      -- Try to complete twice in quick succession
      vim.schedule(function()
        local ok, err = pcall(function()
          task:complete('FIRST')
        end)
        if not ok then
          table.insert(errors, err)
        end
      end)

      vim.schedule(function()
        local ok, err = pcall(function()
          task:complete('SECOND')
        end)
        if not ok then
          table.insert(errors, err)
        end
      end)

      local result = task:wait(100)

      -- One should succeed
      eq('FIRST', result)

      -- The other should have errored
      eq(1, #errors)
      assert(
        errors[1]:match('Task is already completing or completed'),
        'Expected "already completing" error, got: ' .. errors[1]
      )
    end)

    it_exec('child error during parent finalization is handled', function()
      -- Test the race condition where a child errors while parent is finalizing
      local parent_finalized = false
      local child_error_raised = false

      local parent = run(function()
        local child = run(function()
          -- Child sleeps briefly then errors
          Async.sleep(5)
          error('CHILD_ERROR')
        end)

        -- Parent completes immediately, starting finalization
        -- This should trigger awaiting the child, which will error
      end)

      -- Wait for parent to complete
      local ok, err = parent:pwait(100)

      -- Parent should have gotten the child error
      eq(false, ok)
      assert(err:match('child error:.*CHILD_ERROR'), 'Expected child error, got: ' .. tostring(err))
    end)

    it_exec('callback called multiple times is handled gracefully', function()
      -- Test that calling callback multiple times doesn't break things
      local call_count = 0
      local results = {}

      local task = run(function()
        local result = await(function(callback)
          call_count = call_count + 1
          callback('FIRST_CALL')

          -- Try calling again (should be ignored)
          vim.schedule(function()
            call_count = call_count + 1
            callback('SECOND_CALL')
          end)
        end)

        table.insert(results, result)
        return result
      end)

      local final_result = task:wait(100)

      -- Should only get the first callback result
      eq('FIRST_CALL', final_result)
      eq(1, #results)
      eq('FIRST_CALL', results[1])

      -- Wait a bit for the second callback to potentially fire
      run(function()
        Async.sleep(20)
      end):wait()

      -- Both callbacks should have been called
      eq(2, call_count)

      -- But only the first one should have been processed
      eq(1, #results)
    end)

    it_exec('simultaneous complete() calls in same tick are prevented', function()
      -- This tests the atomic nature of _is_completing
      local task --- @type vim.async.Task
      local complete_results = {}

      task = run(function()
        -- Create two child tasks that will try to complete parent simultaneously
        run(function()
          Async.sleep(10)
          local ok, err = pcall(function()
            task:complete('CHILD_1')
          end)
          table.insert(complete_results, { child = 1, ok = ok, err = err })
        end)

        run(function()
          Async.sleep(10)
          local ok, err = pcall(function()
            task:complete('CHILD_2')
          end)
          table.insert(complete_results, { child = 2, ok = ok, err = err })
        end)

        eternity()
      end)

      local result = task:wait(100)

      -- Exactly one should have succeeded
      local success_count = 0
      local error_count = 0

      for _, res in ipairs(complete_results) do
        if res.ok then
          success_count = success_count + 1
        else
          error_count = error_count + 1
          assert(
            res.err:match('Task is already completing or completed'),
            'Unexpected error: ' .. tostring(res.err)
          )
        end
      end

      eq(1, success_count, 'Expected exactly one successful complete()')
      eq(1, error_count, 'Expected exactly one failed complete()')

      -- Result should be from the winning child
      assert(
        result == 'CHILD_1' or result == 'CHILD_2',
        'Result should be from one of the children'
      )
    end)

    it_exec('task can be closed even when _is_completing is set', function()
      -- Test that setting _is_completing doesn't prevent closing
      local task = run(function()
        Async.sleep(50)
        return 'NORMAL_COMPLETION'
      end)

      -- Start completing the task
      vim.schedule(function()
        task:complete('COMPLETED_EARLY')
      end)

      -- Try to close it immediately after
      vim.schedule(function()
        task:close()
      end)

      local result = task:wait(100)

      -- The complete should win since it was scheduled first
      eq('COMPLETED_EARLY', result)
    end)

    it_exec('closable cleanup happens even if close() errors', function()
      -- Test that if a closable's close() method errors, we handle it gracefully
      local close_called = false

      local task = run(function()
        local result = await(function(callback)
          local closable = {
            close = function()
              close_called = true
              error('CLOSE_ERROR')
            end,
          }

          vim.schedule(function()
            callback('RESULT')
          end)

          return closable
        end)

        return result
      end)

      task:close() -- This should trigger closing the closable

      -- The task should complete with the close error
      local ok, err = task:pwait(100)

      eq(true, close_called, 'close() should have been called')
      assert(not ok, 'Task should have errored')
      assert(err:match('CLOSE_ERROR'), 'Expected CLOSE_ERROR, got: ' .. tostring(err))
    end)
  end)

  describe('async.pcall', function()
    it_exec('catches regular errors', function()
      local result
      local task = run(function()
        local ok, err = Async.pcall(function()
          error('REGULAR_ERROR')
        end)
        result = { ok = ok, err = err }
      end)

      task:wait(100)

      eq(false, result.ok)
      assert(
        result.err:match('REGULAR_ERROR'),
        'Expected REGULAR_ERROR, got: ' .. tostring(result.err)
      )
    end)

    it_exec('returns results on success', function()
      local result
      local task = run(function()
        local ok, a, b, c = Async.pcall(function()
          return 1, 'two', true
        end)
        result = { ok = ok, a = a, b = b, c = c }
      end)

      task:wait(100)

      eq(true, result.ok)
      eq(1, result.a)
      eq('two', result.b)
      eq(true, result.c)
    end)

    it_exec('propagates child task errors', function()
      local parent_task = run(function()
        -- Start a child that will error
        local _child = run(function()
          Async.sleep(5)
          error('CHILD_ERROR')
        end)

        -- Use async.pcall to try to catch errors
        local ok, err = Async.pcall(function()
          Async.sleep(100) -- Wait long enough for child to error
        end)

        -- Should never get here because child error propagates
        error('Should not reach here')
      end)

      local ok, err = parent_task:pwait(100)

      eq(false, ok)
      assert(err:match('child error:.*CHILD_ERROR'), 'Expected child error, got: ' .. tostring(err))
    end)

    it_exec('regular pcall catches child errors (for comparison)', function()
      local caught_error
      local parent_task = run(function()
        -- Start a child that will error
        local _child = run(function()
          Async.sleep(5)
          error('CHILD_ERROR')
        end)

        -- Regular pcall catches child errors
        local ok, err = pcall(function()
          Async.sleep(100)
        end)

        caught_error = { ok = ok, err = err }
      end)

      parent_task:wait(100)

      eq(false, caught_error.ok)
      assert(
        caught_error.err:match('child error:.*CHILD_ERROR'),
        'Expected child error, got: ' .. tostring(caught_error.err)
      )
    end)

    it_exec('propagates cancellation errors', function()
      local task = run(function()
        -- Use async.pcall inside a closing task
        local ok, err = Async.pcall(function()
          Async.sleep(100)
        end)

        -- Should never get here
        error('Should not reach here')
      end)

      -- Close the task immediately
      task:close()

      local ok, err = task:pwait(100)

      eq(false, ok)
      -- With xpcall, we now get a full traceback for cancellation errors
      assert(err:match('closed'), 'Error should contain "closed"')
    end)

    it_exec('catches regular errors but propagates child errors in same task', function()
      local results = {}
      local parent_task = run(function()
        -- Start a child that will error soon
        local _child = run(function()
          Async.sleep(20)
          error('CHILD_ERROR')
        end)

        -- First async.pcall catches a regular error
        local ok1, err1 = Async.pcall(function()
          error('REGULAR_ERROR_1')
        end)
        table.insert(results, { step = 1, ok = ok1, err = err1 })

        -- Second async.pcall also catches a regular error
        local ok2, err2 = Async.pcall(function()
          error('REGULAR_ERROR_2')
        end)
        table.insert(results, { step = 2, ok = ok2, err = err2 })

        -- Third async.pcall will be interrupted by child error
        local ok3, err3 = Async.pcall(function()
          Async.sleep(100) -- Wait for child to error
        end)

        -- Should never get here
        error('Should not reach here')
      end)

      local ok, err = parent_task:pwait(100)

      -- First two pcalls should have succeeded in catching errors
      eq(2, #results)
      eq(false, results[1].ok)
      assert(results[1].err:match('REGULAR_ERROR_1'))
      eq(false, results[2].ok)
      assert(results[2].err:match('REGULAR_ERROR_2'))

      -- Parent should have failed with child error
      eq(false, ok)
      assert(err:match('child error:.*CHILD_ERROR'), 'Expected child error, got: ' .. tostring(err))
    end)

    it_exec('works with async functions that await', function()
      local result
      local task = run(function()
        local ok, value = Async.pcall(function()
          Async.sleep(10)
          return 'SUCCESS'
        end)
        result = { ok = ok, value = value }
      end)

      task:wait(100)

      eq(true, result.ok)
      eq('SUCCESS', result.value)
    end)

    it_exec('propagates child errors even when nested in pcall', function()
      local inner_pcall_result
      local outer_pcall_result
      local parent_task = run(function()
        local _child = run(function()
          Async.sleep(5)
          error('CHILD_ERROR')
        end)

        -- Nested pcalls
        local ok_outer, err_outer = pcall(function()
          local ok_inner, err_inner = Async.pcall(function()
            Async.sleep(100)
          end)
          inner_pcall_result = { ok = ok_inner, err = err_inner }
        end)
        outer_pcall_result = { ok = ok_outer, err = err_outer }

        -- Should not reach here because async.pcall re-throws
        -- but the outer pcall will catch it
      end)

      local ok, err = parent_task:pwait(100)

      -- The outer pcall should have caught the re-thrown child error
      eq(false, outer_pcall_result.ok)
      assert(
        outer_pcall_result.err:match('child error:.*CHILD_ERROR'),
        'Expected child error in outer pcall, got: ' .. tostring(outer_pcall_result.err)
      )

      -- The inner async.pcall shouldn't have returned normally
      eq(nil, inner_pcall_result)

      -- The parent task should complete successfully since outer pcall caught it
      eq(true, ok)
    end)

    it_exec('preserves stack traces when propagating child errors', function()
      local parent_task = run(function()
        local _child = run(function()
          Async.sleep(5)
          error('CHILD_ERROR')
        end)

        -- Use async.pcall which should propagate the child error
        Async.pcall(function()
          Async.sleep(100)
        end)
      end)

      local ok, err = parent_task:pwait(100)

      eq(false, ok)
      -- Check that the error message contains the child error
      assert(err:match('CHILD_ERROR'), 'Expected CHILD_ERROR in: ' .. tostring(err))

      -- Get the full traceback
      local traceback = parent_task:traceback(err)

      -- The error message (not the stack trace) contains the child error location
      -- This is a limitation of Lua's error() - see async.pcall documentation
      assert(traceback:match('CHILD_ERROR'), 'Traceback should contain CHILD_ERROR')
      assert(err:match('test/async_spec.lua:%d+'), 'Error should contain file:line reference')
    end)

    it_exec('compare: traceback without async.pcall shows child location', function()
      local parent_task = run(function()
        local _child = run(function()
          Async.sleep(5)
          error('CHILD_ERROR_DIRECT')
        end)

        -- Don't use async.pcall - let child error propagate naturally
        Async.sleep(100)
      end)

      local ok, err = parent_task:pwait(100)

      eq(false, ok)

      -- Get the full traceback
      local traceback = parent_task:traceback(err)

      -- Both approaches preserve the error message with location
      assert(traceback:match('CHILD_ERROR_DIRECT'), 'Traceback should contain CHILD_ERROR_DIRECT')
      assert(err:match('test/async_spec.lua:%d+'), 'Error should contain file:line reference')
    end)

    it_exec('xpcall can capture full stack trace before unwinding', function()
      local captured_traceback
      local captured_err

      local parent_task = run(function()
        local _child = run(function()
          Async.sleep(5)
          error('CHILD_ERROR_XPCALL')
        end)

        -- Use xpcall to capture the stack trace before unwinding
        local ok, result = xpcall(function()
          Async.sleep(100)
        end, function(err)
          -- This handler runs BEFORE the stack is unwound
          captured_err = err
          captured_traceback = debug.traceback(err, 2)
          return err -- Return the original error
        end)

        -- Should not reach here
        error('Should not reach here')
      end)

      local ok, err = parent_task:pwait(100)

      print('\n=== XPCALL Captured Traceback ===')
      print('Error:', captured_err)
      print('Traceback:', captured_traceback)
      print('=== End ===\n')

      eq(false, ok)
      assert(captured_err:match('CHILD_ERROR_XPCALL'), 'Should capture child error')
      assert(captured_traceback ~= nil, 'Should capture traceback')
    end)
  end)
end)
