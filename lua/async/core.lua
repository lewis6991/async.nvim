local util = require('async._util')
local compat = require('async._compat')

local _maxint = compat._maxint
local gc_fun = util.gc_fun
local is_callable = compat.is_callable
local validate = compat.validate
local pack_len = util.pack_len
local unpack_len = util.unpack_len

--- @class vim.async.Timer: vim.async.Closable
--- @field start fun(self, timeout: integer, repeat_interval: integer, callback: fun())

--- @alias vim.async.TimerFactory fun(): vim.async.Timer

--- @class vim.async.InitOpts
--- @field wait fun(timeout: integer, predicate: fun(): boolean): boolean Run the event loop until the predicate succeeds or the timeout expires.
--- @field schedule fun(callback: fun()) Run a callback on the next event loop turn.
--- @field new_timer? vim.async.TimerFactory Create libuv-compatible timers for `sleep()` and `timeout()`.

--- @class vim.async.Runtime
--- @field wait fun(timeout: integer, predicate: fun(): boolean): boolean
--- @field schedule fun(callback: fun())
--- @field new_timer vim.async.TimerFactory
local _runtime = {}

--- This module implements an asynchronous programming library for Lua,
--- centered around the principle of **Structured Concurrency**. This design
--- makes concurrent programs easier to reason about, more reliable, and less
--- prone to resource leaks.
---
--- The library works seamlessly with Neovim and other Lua environments that
--- provide an event loop.
---
--- ### Core Philosophy: Structured Concurrency
---
--- Every async operation happens within a "concurrency scope", which is represented
--- by a [vim.async.Task] object created with `vim.async.run()`. This creates a
--- parent-child relationship between tasks, with the following guarantees:
---
--- 1.  **Task Lifetime:** A parent task's scope cannot end until all of its
---     child tasks have completed. The parent *implicitly waits* for its children,
---     preventing orphaned or "fire-and-forget" tasks.
---
--- 2.  **Error Propagation:** If a child task fails with an error, the error is
---     propagated up to its parent.
---
--- 3.  **Cancellation Propagation:** If a parent task is cancelled (e.g., via
---     `:close()`), the cancellation is propagated down to all of its children.
---
--- This model ensures that all concurrent tasks form a clean, hierarchical tree,
--- and control flow is always well-defined.
---
--- ### Stackful vs. Stackless Coroutines (Green Threads)
---
--- A key architectural feature of `async.nvim` is that it is built on Lua's
--- native **stackful coroutines**. This provides a significant advantage over the
--- `async/await` implementations in many other popular languages, though it's
--- important to clarify its role in the "function coloring" problem.
---
--- - **Stackful (Lua, Go):** A stackful coroutine has its own dedicated call
---   stack, much like a traditional OS thread (and are often called "green threads"
---   or "virtual threads"). This allows a coroutine to be suspended from deep
---   within a nested function call. When using `async.nvim`, `vim.async.run()`
---   serves as the explicit entry point to an asynchronous context (similar to
---   Go's `go` keyword). However, *within* that `async.run()` context,
---   intermediate synchronous helper functions do *not* need to be specially
---   marked. This means if function `A` calls `B` calls `C`, and `C` performs
---   an `await`, `A` and `B` can remain regular Lua functions as long as they are
---   called from within an `async.run()` context. This significantly reduces the
---   viral spread of "coloring".
---
--- - **Stackless (JavaScript, Python, Swift, C#, Kotlin):** Most languages
---   implement `async/await` with stackless coroutines. A function that can
---   be suspended must be explicitly marked with a keyword (like `async` or
---   `suspend`). This requirement is "viral"—any function that calls an `async`
---   function must itself be marked `async`, and so on up the call stack. This
---   is the typical "function coloring" problem.
---
--- Because Lua provides stackful coroutines, `async.nvim` allows you to `await`
--- from deeply nested synchronous functions *within an async context* without
--- "coloring" those intermediate callers. This makes concurrent code less
--- intrusive and easier to integrate with existing synchronous code, despite
--- `async.run()` providing an explicit boundary for the async operations.
---
--- ### Key Features
---
--- - **Task Scopes:** Create a new concurrency scope with `vim.async.run()`.
---   The returned [vim.async.Task] object acts as the parent for any other
---   tasks started within its function.
---
--- - **Awaiting:** Suspend execution and wait for an operation to complete using
---   `vim.async.await()`. This can be used on other tasks or on callback-based
---   functions.
---
--- - **Callback Wrapping:** Convert traditional callback-based functions into
---   modern async functions with `vim.async.wrap()`.
---
--- - **Concurrency Utilities:** `await_all` and `iter` provide
---   powerful tools for managing groups of tasks.
---
--- - **Synchronization Primitives:** `event`, `queue`, and `semaphore` are
---   available for more complex coordination patterns.
---
--- ### Example
---
--- ```lua
--- -- Create an async version of vim.system
--- local system = vim.async.wrap(3, vim.system)
---
--- -- vim.async.run() creates a parent task scope.
--- local parent_task = vim.async.run(function()
---   -- These child tasks are launched within the parent's scope.
---   local ls_task = system({ 'ls', '-l' })
---   local date_task = system({ 'date' })
---
---   -- The parent task will not complete until both ls_task and
---   -- date_task have finished, even without an explicit 'await'.
--- end)
---
--- -- Wait for the parent and all its children to complete.
--- parent_task:wait()
--- ```
---
--- ### Structured Concurrency and Task Scopes
---
--- Every call to `vim.async.run(fn)` creates a new [vim.async.Task] that establishes
--- a concurrency scope. Any other tasks started inside `fn` become children of this
--- task.
---
--- ```lua
--- -- t1 is a top-level task with no parent.
--- local t1 = async.run(function() vim.async.sleep(50) end)
---
--- local main = async.run(function()
---   -- 'child' is created within main's scope, so 'main' is its parent.
---   local child = async.run(function() vim.async.sleep(100) end)
---
---   -- Because 'main' is the parent, it implicitly waits for 'child'
---   -- to complete before it can complete itself.
---
---   -- Cancellation is also propagated down the tree.
---   -- Calling main:close() will also call child:close().
---
---   -- t1 created outside of the main async context.
---   -- It has no parent, so 'main' does not implicitly wait for it.
---   async.await(t1)
--- end)
---
--- -- This will wait for ~100ms, as 'main' must wait for 'child'.
--- main:wait()
--- ```
---
--- If a parent task finishes with an error, it will immediately cancel all of its
--- running child tasks. If it finishes normally, it implicitly waits for them to
--- complete normally.
---
--- ### Comparison with Python's Trio
---
--- The design of `async.nvim` is heavily inspired by Python's `trio` library,
--- and it implements the same core philosophy of **Structured Concurrency**.
--- Both libraries guarantee that all tasks are run in a hierarchy, preventing
--- leaked or "orphaned" tasks and ensuring that cancellation and errors
--- propagate predictably.
---
--- Trio uses an explicit `nursery` object. To spawn child tasks, you must
--- create a nursery scope (e.g., `async with trio.open_nursery() as nursery:`),
--- and the nursery block defines the lifetime of the child tasks.
---
--- async.nvim unifies the concepts of a task and a concurrency scope.
--- The [vim.async.Task] object returned by `vim.async.run()` *is* the scope.
--- In essence, `async.nvim` provides the same safety and clarity as `trio` but
--- adapts the concepts idiomatically for Lua and Neovim.
---
--- ### Comparison with JavaScript's Promises
---
--- JavaScript's `async/await` model with Promises is fundamentally **unstructured**.
--- While tools like `Promise.all` can coordinate multiple promises, the language
--- provides no built-in "scope" that automatically manages child tasks.
---
--- An `async` function call in JavaScript returns a Promise
--- that runs independently. If it is not explicitly awaited, it can easily
--- become an "orphaned" task.
---
--- Cancellation is manual and opt-in via the `AbortController`
--- and `AbortSignal` pattern. It does not automatically propagate from a parent
--- scope to child operations.
---
--- `async.nvim`'s structured model contrasts with this by providing automatic
--- cleanup and cancellation, preventing common issues like resource leaks from
--- forgotten background tasks.
---
--- ### Comparison with Swift Concurrency
---
--- Swift's concurrency model maps closely to `async.nvim`.
---
--- Swift's `TaskGroup` is analogous to the concurrency scope
--- created by `vim.async.run()`. The group's scope cannot exit until all
--- child tasks added to it are complete.
---
--- In both Swift and `async.nvim`, cancelling a parent task
--- automatically propagates a cancellation notice down to all of its children.
---
--- ### Comparison with Kotlin Coroutines
---
--- Kotlin's Coroutine framework is another system built on **Structured Concurrency**,
--- and it shares a nearly identical philosophy with `async.nvim`.
---
--- In Kotlin, a `coroutineScope` function creates a new
--- scope. The scope is guaranteed not to complete until all coroutines
--- launched within it have also completed. This is conceptually the same as
--- the scope created by `vim.async.run()`.
---
--- Like `async.nvim`, cancellation and errors
--- propagate automatically through the task hierarchy. Cancelling a parent scope
--- cancels its children, and an exception in a child will cancel the parent.
---
--- ### Comparison with Go Goroutines
---
--- Go's concurrency model, while powerful, is fundamentally **unstructured**.
--- Launching a `go` routine is a "fire-and-forget" operation with no implicit
--- parent-child relationship.
---
--- Programmers must manually track groups of goroutines,
--- typically using a `sync.WaitGroup` to ensure they all complete before
--- proceeding.
---
--- Cancellation and deadlines are handled by
--- explicitly passing a `context` object through the entire call stack. There
--- is no automatic propagation of cancellation or errors up or down a task tree.
---
--- This contrasts with `async.nvim`, where the structured concurrency model
--- automates the lifetime, cancellation, and error management that must be
--- handled explicitly in Go.
---
--- @class vim.async
local M = {}

--- Initialize async runtime for non-Neovim environments.
---
--- In Neovim, initialization happens automatically. Only call this if you're
--- using the library outside of Neovim or you want to override the detected
--- runtime bindings.
---
--- `opts.wait(timeout, predicate)` must run the event loop until `predicate`
--- returns true or the timeout expires. `opts.schedule(callback)` must defer a
--- callback to the next event loop turn. `opts.new_timer()` is only required
--- for timer APIs such as `sleep()` and `timeout()`.
---
--- @param opts vim.async.InitOpts
function M.init(opts)
  validate('opts', opts, 'table')
  validate('opts.wait', opts.wait, 'callable')
  validate('opts.schedule', opts.schedule, 'callable')

  if opts.new_timer ~= nil then
    validate('opts.new_timer', opts.new_timer, 'callable')
  end

  _runtime.wait = opts.wait
  _runtime.schedule = opts.schedule
  _runtime.new_timer = opts.new_timer
end

--- Weak table to keep track of running tasks
--- @type table<thread, vim.async.Task<any>?>
local threads = setmetatable({}, { __mode = 'k' })

--- Returns the currently running task.
--- @return vim.async.Task<any>?
local function running()
  --- @diagnostic disable-next-line: access-invisible, undefined-field
  local task = threads[coroutine.running()]
  if task and not task:completed() then
    return task
  end
end

--- Internal marker used to identify that a yielded value is an asynchronous yielding.
local yield_marker = {}
local resume_marker = {}
local complete_marker = {}

local resume_error = 'Unexpected coroutine.resume()'
local yield_error = 'Unexpected coroutine.yield()'
local nil_error = 'error(nil)'

--- Normalize a failed Lua operation for the async error slot, where `nil`
--- already means success.
--- @param err any
--- @return any
local function normalize_error(err)
  return err == nil and nil_error or err
end

--- @return vim.async.Task<any>
local function current_task()
  return (assert(running(), 'Not in async context'))
end

--- @param marker any
local function check_resume(marker)
  if marker ~= resume_marker then
    current_task():_raise(resume_error)
    -- Return an error to the caller. This will also leave the task in a dead
    -- and unfinished state
    error(resume_error, 0)
  end
end

--- Checks the arguments of a `coroutine.resume`.
--- This is used to ensure that a resume is expected.
--- @generic T
--- @param marker any
--- @param err? any
--- @param ... T...
--- @return T...
local function check_yield(marker, err, ...)
  check_resume(marker)
  if err ~= nil then
    error(err, 0)
  end
  return ...
end

--- Like check_yield(), but reports delivered async errors as data.
--- @generic T
--- @param marker any
--- @param err? any
--- @param ok boolean
--- @param ... T...
--- @return_overload true, T...
--- @return_overload false, any
local function check_pyield(marker, err, ok, ...)
  check_resume(marker)
  if err ~= nil then
    -- Scheduler delivery: cancellation, pending task failure, or awaitable
    -- setup/close failure.
    return false, err
  end
  if ok then
    return true, ...
  end
  -- Protected awaitable result: `false, ...` is already the public pawait()
  -- shape and must not be promoted into the scheduler error slot.
  return false, ...
end

--- @class vim.async.Closable
--- @field close fun(self, callback?: fun())
--- @field is_closing? fun(self): boolean

--- Tasks are used to run coroutines in event loops. If a coroutine needs to
--- wait on the event loop, the Task suspends the execution of the coroutine and
--- waits for event loop to restart it.
---
--- Use the [vim.async.run()] to create Tasks.
---
--- To close a running Task use the `close()` method. Calling it will cause the
--- Task to throw a "closed" error in the wrapped coroutine.
---
--- Note a Task can be waited on via more than one waiter.
---
--- @class vim.async.Task<R>: vim.async.Closable
--- @field package _thread thread
--- @field package _future vim.async.Future<R>
--- @field package _closing boolean
--- @field package _error? any
--- @field package _finalizing_children boolean
--- @field package _started boolean
---
--- Reference to parent to handle attaching/detaching.
--- @field package _parent? vim.async.Task<any>
--- @field package _parent_children_idx? integer
---
--- Name of the task
--- @field name? string
---
--- Hide implementation tasks from user-facing inspection output.
--- @field package _hidden? boolean
---
--- The source line that created this task, used for inspect().
--- @field package _caller? string
---
--- Maintain children as an array to preserve closure order.
--- @field package _children table<integer, vim.async.Task<any>?>
---
--- Pointer to last child in children
--- @field package _children_idx integer
---
--- Tasks can await other async functions (task of callback functions)
--- when we are waiting on a child, we store the handle to it here so we can
--- close it.
--- @field package _awaiting? vim.async.Task<any> | vim.async.Closable
local Task = {}

--- @return_cast x vim.async.Task<any>
local function is_task(x)
  return getmetatable(x) == Task
end

do --- Task
  Task.__index = Task

  --- @package
  --- @param name? string
  --- @param func async fun(...: any)
  --- @return vim.async.Task<any>
  function Task._new(name, func, ...)
    local func_args = pack_len(...) --[[@as any[]? ]]
    local thread = coroutine.create(function(marker, err)
      -- Drop the packed vararg table before user code can suspend; otherwise
      -- the coroutine closure retains it for the task lifetime.
      local args = func_args
      func_args = nil
      check_yield(marker, err)
      return func(unpack_len(args))
    end)

    local self = setmetatable({
      name = name,
      _closing = false,
      _finalizing_children = false,
      _started = false,
      _is_completing = false,
      _thread = thread,
      _future = M._future(),
      _children = {},
      _children_idx = 0,
    }, Task)

    threads[thread] = self

    return self
  end

  --- @package
  --- @param cb fun(err?: any, ...: any)
  function Task:_unwait(cb)
    self._future:_remove_cb(cb)
  end

  --- Returns whether the Task has completed.
  --- @return boolean
  function Task:completed()
    return self._future:completed()
  end

  --- Add a callback to be run when the Task has completed.
  ---
  --- If the Task is already done when this method is called, the callback is
  --- called immediately with the results.
  ---
  --- This only observes completion. It does not start a pending task.
  --- @param callback fun(err?: any, ...: R...)
  function Task:on_complete(callback)
    validate('callback', callback, 'callable')
    self._future:wait(callback)
  end

  --- Synchronously wait for the Task to complete.
  ---
  --- If a timeout is provided, waits for the given time in milliseconds before
  --- failing with `"timeout"`. With no timeout, waits indefinitely.
  ---
  --- ```lua
  --- local result = task:wait(10) -- wait for 10ms or else error
  ---
  --- local result = task:wait() -- wait indefinitely
  --- ```
  --- @param timeout integer?
  --- @return R...
  function Task:wait(timeout)
    validate('timeout', timeout, 'number', true)
    self:_start()

    if not _runtime.wait(timeout or _maxint, function()
      return self:completed()
    end) then
      error('timeout', 2)
    end
    local res = pack_len(self._future:result())

    assert(self:status() == 'completed' or res[2] == yield_error)

    if not res[1] then
      error(res[2], 2)
    end

    return unpack_len(res, 2)
  end

  --- Protected-call version of `wait()`.
  ---
  --- Equivalent to `pcall(task.wait, task, timeout)`.
  --- @param timeout integer?
  --- @return boolean, R...
  function Task:pwait(timeout)
    validate('timeout', timeout, 'number', true)
    return pcall(self.wait, self, timeout)
  end

  --- @package
  --- @param parent? vim.async.Task<any>
  function Task:_attach(parent)
    if parent then
      -- Attach to parent
      parent._children_idx = parent._children_idx + 1
      parent._children[parent._children_idx] = self

      -- Keep track of the parent and this tasks index so we can detach
      self._parent = parent
      self._parent_children_idx = parent._children_idx
    end
  end

  --- Remove this task from its parent without changing execution state.
  --- @private
  --- @return boolean removed
  function Task:_detach()
    if not self._parent then
      return false
    end

    self._parent._children[self._parent_children_idx] = nil
    self._parent = nil
    self._parent_children_idx = nil
    return true
  end

  --- Detach a task from its parent.
  ---
  --- The task becomes a top-level task.
  --- If it was waiting for a parent checkpoint, it is scheduled to start.
  --- @return vim.async.Task<R>
  function Task:detach()
    local should_start = self._parent and not self._started and not self:completed()
    self:_detach()
    if should_start then
      _runtime.schedule(function()
        self:_start()
      end)
    end
    return self
  end

  --- Get the traceback of a task when it is not active.
  --- Will also get the traceback of nested tasks.
  ---
  --- @param msg? string
  --- @param level? integer
  --- @return string traceback
  function Task:traceback(msg, level)
    level = level or 0

    local thread = ('[%s] '):format(self._thread)

    local awaiting = self._awaiting
    if is_task(awaiting) then
      msg = awaiting:traceback(msg, level + 1)
    end

    local tblvl = is_task(awaiting) and 2 or nil
    msg = (tostring(msg) or '')
      .. debug.traceback(self._thread, '', tblvl):gsub('\n\t', '\n\t' .. thread)

    if level == 0 then
      --- @type string
      msg = msg
        :gsub('\nstack traceback:\n', '\nSTACK TRACEBACK:\n', 1)
        :gsub('\nstack traceback:\n', '\n')
        :gsub('\nSTACK TRACEBACK:\n', '\nstack traceback:\n', 1)
    end

    return msg
  end

  --- If a task completes with an error, raise the error
  --- @return vim.async.Task<R> self
  function Task:raise_on_error()
    self:on_complete(function(err)
      if err ~= nil then
        error(self:traceback(err), 0)
      end
    end)
    return self
  end

  --- @package
  function Task:_start()
    if self._started or self:completed() then
      return
    end

    self._started = true
    self:_resume()
  end

  --- Start children whose first resume was deferred by `run()`.
  ---
  --- Deferring child start lets `await()` or `pawait()` claim the task boundary
  --- before child code runs. At await checkpoints and successful parent finish,
  --- any remaining pending children must start so implicit waits, cancellation,
  --- and inspection see the full task tree.
  --- @private
  function Task:_start_pending_children()
    for i = 1, self._children_idx do
      local child = self._children[i]
      if child then
        child:_start()
      end
    end
  end

  --- Keep the first task error. The error can be any non-nil Lua value.
  --- @private
  --- @param err any
  --- @return any
  function Task:_set_error(err)
    if self._error == nil then
      self._error = err
    end
    return self._error
  end

  --- @package
  --- @param err any
  function Task:_raise(err)
    if self:status() == 'running' then
      -- A running coroutine cannot be resumed recursively, so deliver the
      -- error on the next event-loop turn after the current stack unwinds.
      _runtime.schedule(function()
        if not self:completed() then
          self:_resume(err)
        end
      end)
    else
      self:_resume(err)
    end
  end

  --- Close the task and all of its children.
  --- If callback is provided it will run asynchronously,
  --- else it will run synchronously.
  ---
  --- @param callback? fun()
  function Task:close(callback)
    if not self:completed() and not self._closing and not self._is_completing then
      self._closing = true
      self:_raise('closed')
    end
    if callback then
      self:on_complete(function()
        callback()
      end)
    end
  end

  --- Complete a task with the given values, cancelling any remaining work.
  ---
  --- This marks the task as successfully completed and notifies any waiters with
  --- the provided values. It also initiates the cancellation of all
  --- running child tasks.
  ---
  --- A primary use case is for "race" scenarios. A child task can acquire a
  --- reference to its parent task and call `complete()` on it. This signals
  --- that the overall goal of the parent scope has been met, which immediately
  --- triggers the cancellation of all sibling tasks.
  ---
  --- This provides a built-in pattern for "first-to-finish" logic, such as
  --- querying multiple data sources and taking the first response.
  ---
  --- @param ... any The values to complete the task with.
  function Task:complete(...)
    if self:completed() or self._closing or self._is_completing then
      error('Task is already completing or completed', 2)
    end
    self._is_completing = true
    self:_raise({ complete_marker, pack_len(...) })
  end

  --- Record a child failure on this task and deliver it unless this task is
  --- already collecting children during finalization.
  --- @package
  --- @param child vim.async.Task<any>
  --- @param err any
  --- @param child_was_awaited boolean?
  function Task:_child_failed(child, err, child_was_awaited)
    -- A parent close turns child "closed" results into cleanup, not failure.
    if child._closing or child_was_awaited or (self._closing and err == 'closed') then
      return
    end

    local task_err = self:_set_error('child error: ' .. tostring(err))
    if not self._finalizing_children then
      self:_raise(task_err)
    end
  end

  --- Checks if an object is closable, i.e., has a `close` method.
  --- @param obj any
  --- @return boolean
  --- @return_cast obj vim.async.Closable
  local function is_closable(obj)
    local ty = type(obj)
    return (ty == 'table' or ty == 'userdata') and is_callable(obj.close)
  end

  do -- Task:_resume()
    --- Complete this task with an error and propagate it to the parent if the
    --- parent did not explicitly await this task.
    --- @param parent? vim.async.Task<any>
    --- @param err any
    function Task:_finish_error(parent, err)
      if err == nil then
        err = self._error
      end
      err = normalize_error(err)
      if type(err) == 'table' and err[1] == complete_marker then
        self._future:complete(nil, unpack_len(err[2]))
        return
      end

      if parent then
        parent:_child_failed(self, err, parent._awaiting == self)
      end
      self._future:complete(err)
    end

    --- @private
    --- @param stat boolean
    --- @param ... R... result
    function Task:_finish(stat, ...)
      if self:completed() then
        return
      end

      local parent = self._parent
      self:_detach()

      threads[self._thread] = nil

      if not stat then
        self:_finish_error(parent, ...)
      else
        if self._error ~= nil then
          self:_finish_error(parent, self._error)
        else
          self._future:complete(nil, ...)
        end
      end
    end

    --- @private
    --- @param stat boolean
    --- @param ... R... result
    function Task:_finalize(stat, ...)
      if next(self._children) == nil then
        self:_finish(stat, ...)
        return
      end

      local finish_args = pack_len(stat, ...)
      self._finalizing_children = true
      -- Only spawn the helper after the no-child path; an empty helper task
      -- would otherwise finalize by recursively spawning another helper.
      local await_children = Task._new('await_children', function()
        -- TODO(lewis6991): should we collect all errors?
        local close_remaining = not stat

        if not close_remaining then
          self:_start_pending_children()
        end

        for i = 1, self._children_idx do
          local child = self._children[i]
          if child then
            if close_remaining then
              child:close()
            end
            -- Finalization owns child failures here; don't let them re-enter
            -- the dead parent coroutine and complete the future twice.
            local ok, err = pcall(M.await, child)
            -- A close can arrive while normal finalization is awaiting
            -- children; from that point child errors are cleanup results.
            if not close_remaining and not self._closing and not ok and not child._closing then
              self:_set_error('child error: ' .. tostring(err))
              close_remaining = true
            end
          end
        end

        self._finalizing_children = false
        if stat and self._closing and self._error == nil then
          self:_finish(false, 'closed')
        else
          self:_finish(unpack_len(finish_args))
        end
      end)
      await_children._hidden = true
      await_children:_start()
    end

    --- @param thread thread
    --- @param on_finish fun(stat: boolean, ...: any)
    --- @param stat boolean
    --- @return fun(callback: fun(...: any...): vim.async.Closable?)?
    local function handle_co_resume(thread, on_finish, stat, ...)
      if coroutine.status(thread) == 'dead' then
        on_finish(stat, ...)
        return
      end

      local marker, fn = ...

      if marker ~= yield_marker or not is_callable(fn) then
        on_finish(false, yield_error)
        return
      end

      return fn
    end

    --- @param awaitable fun(callback: fun(...: any...): vim.async.Closable?)
    --- @param on_defer fun(awaiting: any, err?: any, ...: any)
    --- @return any[]? next_args
    --- @return vim.async.Closable? closable
    local function handle_awaitable(awaitable, on_defer)
      local ok, closable_or_err
      local settled = false
      local next_args --- @type any[]?
      ok, closable_or_err = pcall(awaitable, function(...)
        if settled then
          -- error here?
          return
        end
        settled = true

        -- If the callback runs before pcall() returns, keep looping in the
        -- current stack. Otherwise the callback resumes the task later.
        if ok == nil then
          next_args = pack_len(...)
        else
          on_defer(closable_or_err, ...)
        end
      end)

      if not ok then
        return pack_len(normalize_error(closable_or_err))
      elseif is_closable(closable_or_err) then
        return next_args, closable_or_err
      else
        return next_args
      end
    end

    --- @param task vim.async.Task<any>
    --- @param awaiting vim.async.Task<any> | vim.async.Closable
    --- @return boolean
    local function can_close_awaiting(task, awaiting)
      if not is_task(awaiting) then
        return true
      end

      for _, child in pairs(task._children) do
        if child == awaiting then
          return true
        end
      end

      return false
    end

    --- Handle closing an awaitable if needed
    --- @param task vim.async.Task<any>
    --- @param awaiting vim.async.Closable?
    --- @param on_continue fun()
    --- @return boolean should_return
    --- @return {[integer]: any, n: integer}? new_args
    local function handle_close_awaiting(task, awaiting, on_continue)
      if not awaiting or not can_close_awaiting(task, awaiting) then
        return false, nil
      end

      -- Check if the awaitable is already closing (if it has an is_closing method)
      local already_closing = false
      if type(awaiting.is_closing) == 'function' then
        already_closing = awaiting:is_closing()
      end

      if already_closing then
        -- Already closing, just continue without calling close
        task._awaiting = nil
        on_continue()
        return true, nil
      end

      -- We must close the closable child before we resume to ensure
      -- all resources are collected.
      --- @diagnostic disable-next-line: param-type-not-match
      local close_ok, close_err = pcall(awaiting.close, awaiting, function()
        task._awaiting = nil
        on_continue()
      end)

      if close_ok then
        -- will call on_continue in close callback
        return true, nil
      end

      -- Close failed (synchronously) raise error
      return false, pack_len(normalize_error(close_err))
    end

    --- @package
    --- @param ... any the first argument is the error, except for when the coroutine begins
    function Task:_resume(...)
      --- @type { [integer]: any, n: integer }?
      local args = pack_len(...)

      -- Run this block in a while loop to run non-deferred continuations
      -- without a new stack frame.
      while args do
        if self._is_completing and args[1] == 'closed' then
          return
        end

        local should_return, close_err_args = handle_close_awaiting(self, self._awaiting, function()
          self:_resume(unpack_len(args))
        end)
        if should_return then
          return
        end

        args = close_err_args or args

        -- Check the coroutine is still alive before trying to resume it
        if coroutine.status(self._thread) == 'dead' then
          -- Can only happen if coroutine.resume() is called outside of this
          -- function. When that happens check_yield() will error the coroutine
          -- which puts it in the 'dead' state.
          self:_finalize(false, unpack_len(args))
          return
        end

        local awaitable = handle_co_resume(self._thread, function(stat2, ...)
          -- If pcall swallowed a child error or close signal, don't let a
          -- later normal return overwrite the pending task failure.
          if self._error ~= nil and stat2 then
            self:_finalize(false, self._error)
          elseif self._closing and stat2 then
            self:_finalize(false, 'closed')
          else
            self:_finalize(stat2, ...)
          end
        end, coroutine.resume(self._thread, resume_marker, unpack_len(args)))

        if not awaitable then
          return
        end

        args, self._awaiting = handle_awaitable(awaitable, function(awaiting, ...)
          if is_task(awaiting) and select(1, ...) ~= nil then
            self:_set_error(select(1, ...))
          end
          if not self:completed() then
            self:_resume(...)
          end
        end)

        if is_task(self._awaiting) then
          self._awaiting:_start()
        end
        self:_start_pending_children()
        if args and is_task(self._awaiting) and args[1] ~= nil then
          self:_set_error(args[1])
        end
      end
    end
  end

  --- @package
  function Task:_log(...)
    print(tostring(self._thread), ...)
  end

  --- Returns the status of the task:
  --- - 'running'    : task is running (that is, is called `status()`).
  --- - 'normal'     : task is active but not running (e.g. it is starting
  ---                  another task).
  --- - 'awaiting'   : if the task is awaiting another task either directly via
  ---                  `await()` or waiting for all children to complete.
  --- - 'completed'  : task and all it's children have completed
  --- @return 'running' | 'awaiting' | 'normal' | 'scheduled' | 'completed'
  function Task:status()
    if self:completed() then
      return 'completed'
    end

    local co_status = coroutine.status(self._thread)
    if co_status == 'dead' then
      return 'awaiting'
    elseif co_status == 'suspended' then
      return 'awaiting'
    elseif co_status == 'normal' then
      -- TODO(lewis6991): This state is a bit ambiguous. If all tasks
      -- are started from the main thread, then we can remove this state.
      -- Though it still may be possible if the user resumes a non-task
      -- coroutine.
      return 'normal'
    end
    assert(co_status == 'running')
    return 'running'
  end
end

do --- M.run
  --- @generic T, R
  --- @param name? string
  --- @param func async fun(...: T...): R... Function to run in an async context
  --- @param ... T... Arguments to pass to the function
  --- @return vim.async.Task<R...>
  local function run(name, func, ...)
    validate('func', func, 'callable')
    local task = Task._new(name, func, ...)
    task:_attach(running())
    local info = debug.getinfo(2, 'Sl')
    if info and info.currentline then
      task._caller = ('%s:%d'):format(info.source, info.currentline)
    end

    -- Top-level tasks have no parent checkpoint to start them, so they start
    -- immediately. Attached children start when their parent next reaches an
    -- await checkpoint, or when the parent finishes successfully and implicitly
    -- waits for its children. If the parent errors or closes, pending children
    -- are closed without running user code.
    if not task._parent then
      task:_start()
    end

    return task
  end

  --- Run a function in an async context, asynchronously.
  ---
  --- Returns an [vim.async.Task] object which can be used to wait or await the result
  --- of the function.
  ---
  --- Child tasks created from inside another task are attached immediately, but
  --- their first resume is deferred until an await checkpoint or successful
  --- parent finish.
  ---
  --- Examples:
  --- ```lua
  --- -- Run a uv function and wait for it
  --- local stat = vim.async.run(function()
  ---     return vim.async.await(2, vim.uv.fs_stat, 'foo.txt')
  --- end):wait()
  ---
  --- -- Since uv functions have sync versions, this is the same as:
  --- local stat = vim.fs_stat('foo.txt')
  --- ```
  --- @generic T, R
  --- @param func async fun(...: T...): R...
  --- @return vim.async.Task<R...>
  --- @overload fun(name: string, func: async fun(...: T...), ...: T...): vim.async.Task<R...>
  function M.run(func, ...)
    if type(func) == 'string' then
      return run(func, ...)
    elseif is_callable(func) then
      return run(nil, func, ...)
    end
    error('Invalid arguments')
  end
end

do --- M.await()
  --- @generic T, R
  --- @param argc integer
  --- @param fun fun(...: T..., callback: fun(...: R...))
  --- @param ... T... func arguments
  --- @return fun(callback: fun(...: R...))
  local function norm_cb_fun(argc, fun, ...)
    local args = pack_len(...)

    --- @param callback fun(...: any)
    --- @return any?
    return function(callback)
      args[argc] = function(...)
        callback(nil, ...)
      end
      args.n = math.max(args.n, argc)
      return fun(unpack_len(args))
    end
  end

  --- Get the current task, failing before `await()` yields if it is closing or
  --- failed. `pawait()` uses `current_task()` directly because it reports
  --- checkpoint errors as data.
  --- @return vim.async.Task<any>
  local function check_current_task()
    local task = current_task()

    if task._closing then
      error('closed', 0)
    elseif task._error ~= nil then
      error(task._error, 0)
    end

    return task
  end

  --- Convert the public await forms into the shape consumed by `_resume()`.
  ---
  --- The scheduler expects an awaitable to call `callback(err, ...)` and may use
  --- its returned closable for cancellation cleanup. Callback-style APIs do not
  --- have an error slot, so `norm_cb_fun()` inserts `nil`; task futures already
  --- use this convention.
  --- @param ... any
  --- @return fun(callback: fun(err?: any, ...: any)): vim.async.Closable?
  local function to_awaitable(...)
    local arg1 = select(1, ...)

    if type(arg1) == 'number' then
      return norm_cb_fun(...)
    elseif type(arg1) == 'function' then
      return norm_cb_fun(1, arg1)
    elseif is_task(arg1) then
      --- @param callback fun(err?: any, ...: any)
      return function(callback)
        arg1._future:wait(callback)
        return arg1
      end
    else
      error('Invalid arguments, expected Task or (argc, func) got: ' .. tostring(arg1), 2)
    end
  end

  --- Asynchronous blocking wait
  ---
  --- Example:
  --- ```lua
  --- local task = vim.async.run(function()
  ---    return 1, 'a'
  --- end)
  ---
  --- local task_fun = vim.async.async(function(arg)
  ---    return 2, 'b', arg
  --- end)
  ---
  --- vim.async.run(function()
  ---   do -- await a callback function
  ---     vim.async.await(1, vim.schedule)
  ---   end
  ---
  ---   do -- await a callback function (if function only has a callback argument)
  ---     vim.async.await(vim.schedule)
  ---   end
  ---
  ---   do -- await a task (new async context)
  ---     local n, s = vim.async.await(task)
  ---     assert(n == 1 and s == 'a')
  ---   end
  ---
  --- end)
  --- ```
  ---
  --- Do not use raw `pcall` to recover from `await()` or any function that may
  --- suspend. Child task failures and cancellation are delivered through Lua
  --- errors too, so `pcall` cannot tell them apart from ordinary local failures.
  --- Catch only synchronous work, use `pcall` only for non-suspending cleanup
  --- before rethrowing, or handle async failures at task boundaries.
  --- @async
  --- @generic T, R
  --- @param ... any see overloads
  --- @overload async fun(func: (fun(callback: fun(...: R...)): vim.async.Closable?)): R...
  --- @overload async fun(argc: integer, func: (fun(...: T..., callback: fun(...: R...)): vim.async.Closable?), ...: T...): R...
  --- @overload async fun(task: vim.async.Task<R>): R...
  --- @return R...
  function M.await(...)
    check_current_task()
    return check_yield(coroutine.yield(yield_marker, to_awaitable(...)))
  end

  --- Await an operation and return checkpoint failure as data.
  ---
  --- `pawait()` accepts the same forms as `await()`, but returns `false, err`
  --- when the await checkpoint receives an error. This includes failure from
  --- the awaited operation, cancellation of the current task, and already
  --- pending task failure. This is the recovery boundary for optional child
  --- work:
  ---
  --- ```lua
  --- vim.async.run(function()
  ---   local ok, data_or_err = vim.async.pawait(vim.async.run(fetch_optional_data))
  ---
  ---   if ok then
  ---     use(data_or_err)
  ---   end
  --- end)
  --- ```
  ---
  --- `pawait()` is not `pcall()` for async code. Returning `false, err` does
  --- not clear cancellation or pending failure from the current task, so cleanup
  --- can run but the task still completes as failed/closed unless the failure
  --- belongs to the awaited operation itself. Use `is_closing()` to distinguish
  --- cancellation from ordinary awaited-operation failure.
  ---
  --- For callback overloads, callback values are treated exactly like `await()`
  --- results and are only prefixed with `ok`; they are not interpreted as
  --- errors.
  ---
  --- When passed a pending child task, `pawait()` starts the task after the
  --- parent is marked as awaiting it, so synchronous child failures are captured
  --- before they can reach the parent. If the child has already failed, that
  --- failure may already be pending on the parent.
  --- @async
  --- @generic T, R
  --- @param ... any see overloads
  --- @overload async fun(func: (fun(callback: fun(...: R...)): vim.async.Closable?)): boolean, R...
  --- @overload async fun(argc: integer, func: (fun(...: T..., callback: fun(...: R...)): vim.async.Closable?), ...: T...): boolean, R...
  --- @overload async fun(task: vim.async.Task<R>): boolean, R...
  --- @return_overload true, R...
  --- @return_overload false, any
  function M.pawait(...)
    local current = current_task()
    if current._closing then
      return false, 'closed'
    elseif current._error ~= nil then
      return false, current._error
    end

    local awaitable = to_awaitable(...)

    --- @param callback fun(err?: any, ok?: boolean, ...: any)
    local function protected_awaitable(callback)
      return awaitable(function(err, ...)
        -- Task-control state wins over the awaited operation result. pawait()
        -- reports that state as data, but it does not clear it.
        if current._closing then
          callback('closed')
        elseif current._error ~= nil then
          callback(current._error)
        elseif err ~= nil then
          callback(nil, false, err)
        else
          callback(nil, true, ...)
        end
      end)
    end

    return check_pyield(coroutine.yield(yield_marker, protected_awaitable))
  end
end

--- Returns true if the current task has been closed.
---
--- Can be used in an async function to do cleanup when a task is closing.
--- @return boolean
function M.is_closing()
  local task = running()
  return task and task._closing or false
end

--- Creates an async function from a callback style function.
---
--- `func` can optionally return an object with a close method to clean up
--- resources. Note this method will be called when the task finishes or
--- interrupted.
---
--- Example:
---
--- ```lua
--- --- Note the callback argument is not present in the return function
--- --- @type async fun(timeout: integer)
--- local sleep = vim.async.wrap(2, function(timeout, callback)
---   local timer = vim.uv.new_timer()
---   timer:start(timeout * 1000, 0, callback)
---   -- uv_timer_t provides a close method so timer will be
---   -- cleaned up when this function finishes
---   return timer
--- end)
---
--- vim.async.run(function()
---   print('hello')
---   sleep(2)
---   print('world')
--- end)
--- ```
---
--- @generic T, R
--- @param argc integer
--- @param func fun(...: T..., callback: fun(...: R...)): vim.async.Closable?
--- @return async fun(...: T...): R...
function M.wrap(argc, func)
  validate('argc', argc, 'number')
  validate('func', func, 'callable')
  --- @async
  return function(...)
    return M.await(argc, func, ...)
  end
end

do --- M.iter(), M.await_all()
  --- @async
  --- @generic R
  --- @param tasks vim.async.Task<R>[] A list of tasks to wait for and iterate over.
  --- @return async fun(): (integer?, R...) iterator that yields the index and results of each task.
  local function iter(tasks)
    validate('tasks', tasks, 'table')

    current_task()

    local remaining = #tasks
    local queue = M._queue()

    -- Keep track of the callbacks so we can remove them when the iterator
    -- is garbage collected.
    --- @type table<vim.async.Task<any>, function>
    local task_cbs = setmetatable({}, { __mode = 'v' })

    -- Observe all the tasks. Keep the callbacks so they can be removed when
    -- the iterator is garbage collected.
    for i, task in ipairs(tasks) do
      --- @param err? any
      --- @param ... R
      local function cb(err, ...)
        remaining = remaining - 1
        queue:put_nowait(pack_len(err, i, ...))
        if remaining == 0 then
          queue:put_nowait()
        end
      end

      task_cbs[task] = cb
      task:on_complete(cb)
    end

    --- @async
    return gc_fun(function()
      local r = queue:get()
      if r then
        local err = r[1]
        if err ~= nil then
          -- -- Note: if the task was a child, then an error should have already been
          -- -- raised in _complete_task(). This should only trigger to detached tasks.
          -- assert(assert(tasks[r[2]])._parent == nil)
          error(('iter error[index:%d]: %s'):format(r[2], tostring(err)), 3)
        end
        return unpack_len(r, 2)
      end
    end, function()
      for t, tcb in pairs(task_cbs) do
        t:_unwait(tcb)
      end
    end)
  end

  --- Waits for multiple tasks to finish and iterates over their results.
  ---
  --- This function allows you to run multiple asynchronous tasks concurrently and
  --- process their results as they complete. It returns an iterator function that
  --- yields the index of the task and the results of the task.
  ---
  --- If a task completes with an error, the iterator raises that error.
  ---
  --- Example:
  --- ```lua
  --- local task1 = vim.async.run(function()
  ---   return 1, 'a'
  --- end)
  ---
  --- local task2 = vim.async.run(function()
  ---   return 2, 'b'
  --- end)
  ---
  --- vim.async.run(function()
  ---   for i, r1, r2 in vim.async.iter({task1, task2}) do
  ---     print(i, r1, r2)
  ---   end
  --- end)
  --- ```
  ---
  --- Prints:
  --- ```
  --- 1 1 'a'
  --- 2 2 'b'
  --- ```
  ---
  --- @async
  --- @generic R
  --- @param tasks vim.async.Task<R>[] A list of tasks to wait for and iterate over.
  --- @return async fun(): (integer?, R...) iterator that yields the index and results of each task.
  function M.iter(tasks)
    return iter(tasks)
  end

  --- Wait for all tasks to finish and return their results.
  ---
  --- Example:
  --- ```lua
  --- local task1 = vim.async.run(function()
  ---   return 1, 'a'
  --- end)
  ---
  --- local task2 = vim.async.run(function()
  ---   return 1, 'a'
  --- end)
  ---
  --- vim.async.run(function()
  ---   local results = vim.async.await_all({task1, task2})
  ---   print(vim.inspect(results))
  --- end)
  --- ```
  ---
  --- Prints:
  --- ```
  --- {
  ---   [1] = { 1, 'a' },
  ---   [2] = { 2, 'b' },
  --- }
  --- ```
  --- @async
  --- @param tasks vim.async.Task<any>[]
  --- @return table<integer, [any?, ...?]>
  function M.await_all(tasks)
    current_task()
    local itr = iter(tasks)
    local results = {} --- @type table<integer, table>

    --- @param i integer?
    --- @param ... any
    --- @return boolean
    local function collect(i, ...)
      if i then
        results[i] = pack_len(...)
      end
      return i ~= nil
    end

    while collect(itr()) do
    end

    return results
  end
end

--- Asynchronously sleep for a given duration.
---
--- Blocks the current task for the given duration, but does not block the main
--- thread.
--- @async
--- @param duration integer ms
function M.sleep(duration)
  validate('duration', duration, 'number')
  M.await(function(callback)
    local timer = _runtime.new_timer()
    timer:start(duration, 0, function()
      timer:close()
      callback()
    end)
  end)
end

--- Run a task with a timeout.
---
--- If the task does not complete within the specified duration, it is closed
--- and an error is thrown.
--- @async
--- @generic R
--- @param duration integer Timeout duration in milliseconds
--- @param task vim.async.Task<R>
--- @return R
function M.timeout(duration, task)
  validate('duration', duration, 'number')
  validate('task', task, 'table')
  local timer = M.run(M.await, function(callback)
    local t = _runtime.new_timer()
    t:start(duration, 0, callback)
    return t
  end)
  if M.iter({ task, timer })() == 2 then
    -- Timer completed first, close the task
    task:close()
    error('timeout')
  end
  timer:close()
  return M.await(task)
end

do --- M._future()
  --- Future objects are used to bridge low-level callback-based code with
  --- high-level async/await code.
  --- @class vim.async.Future<R>
  --- @field private _callbacks table<integer, fun(err?: any, ...: R...)>
  --- @field private _callback_pos integer
  --- Error result of the task is an error occurs.
  --- Must use `await` to get the result.
  --- @field package _err? any
  ---
  --- Result of the task.
  --- Must use `await` to get the result.
  --- @field private _result? R[]
  local Future = {}
  Future.__index = Future

  --- Return `true` if the Future is completed.
  --- @return boolean
  function Future:completed()
    return self._err ~= nil or self._result ~= nil
  end

  --- Return the result of the Future.
  ---
  --- If the Future is done and has a result set by the `complete()` method, the
  --- result is returned.
  ---
  --- If the Future’s result isn’t yet available, this method raises a
  --- "Future has not completed" error.
  --- @return boolean stat true if the Future completed successfully, false otherwise.
  --- @return any ... error or result
  function Future:result()
    if not self:completed() then
      error('Future has not completed', 2)
    end
    if self._err ~= nil then
      return false, self._err
    else
      return true, unpack_len(self._result)
    end
  end

  --- Add a callback to be run when the Future is done.
  ---
  --- The callback is called with the arguments:
  --- - (`err: string`) - if the Future completed with an error.
  --- - (`nil`, `...:any`) - the results of the Future if it completed successfully.
  ---
  --- If the Future is already done when this method is called, the callback is
  --- called immediately with the results.
  --- @param callback fun(err?: any, ...: any)
  function Future:wait(callback)
    if self:completed() then
      -- Already completed or closed
      callback(self._err, unpack_len(self._result))
    else
      self._callbacks[self._callback_pos] = callback
      self._callback_pos = self._callback_pos + 1
    end
  end

  --- Mark the Future as complete and set its result.
  ---
  --- If an error is provided, the Future is marked as failed. Otherwise, it is
  --- marked as successful with the provided result.
  ---
  --- A Future can only be completed once.
  ---
  --- This will trigger any callbacks that are waiting on the Future.
  --- @param err? any
  --- @param ... any result
  function Future:complete(err, ...)
    if self:completed() then
      error('Future is already completed', 2)
    end

    if err ~= nil then
      self._err = err
    else
      self._result = pack_len(...)
    end

    local errs = {} --- @type string[]
    -- Need to use pairs to avoid gaps caused by removed callbacks
    for _, cb in pairs(self._callbacks) do
      local ok, cb_err = pcall(cb, err, ...)
      if not ok then
        errs[#errs + 1] = tostring(normalize_error(cb_err))
      end
    end

    if #errs > 0 then
      error(table.concat(errs, '\n'), 0)
    end
  end

  --- @package
  --- Removes a callback from the Future.
  --- @param cb fun(err?: any, ...: any)
  function Future:_remove_cb(cb)
    for j, fcb in pairs(self._callbacks) do
      if fcb == cb then
        self._callbacks[j] = nil
        break
      end
    end
  end

  --- @package
  --- Create a new future.
  ---
  --- A Future is a low-level awaitable that is not intended to be used in
  --- application-level code.
  --- @return vim.async.Future<any>
  function M._future()
    return setmetatable({
      _callbacks = {},
      _callback_pos = 1,
    }, Future)
  end
end

do --- M._event()
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
    M.await(function(callback)
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

  --- @package
  --- Create a new event.
  ---
  --- An event can signal to multiple listeners to resume execution
  --- The event can be set from a non-async context.
  ---
  --- ```lua
  ---  local event = vim.async._event()
  ---
  ---  local worker = vim.async.run(function()
  ---    vim.async.sleep(1000)
  ---    event.set()
  ---  end)
  ---
  ---  local listeners = {
  ---    vim.async.run(function()
  ---      event:wait()
  ---      print("First listener notified")
  ---    end),
  ---    vim.async.run(function()
  ---      event:wait()
  ---      print("Second listener notified")
  ---    end),
  ---  }
  --- ```
  --- @return vim.async.Event
  function M._event()
    return setmetatable({
      _waiters = {},
      _is_set = false,
    }, Event)
  end
end

do --- M._queue()
  --- @class vim.async.Queue<R>
  --- @field private _non_empty vim.async.Event
  --- @field package _non_full vim.async.Event
  --- @field private _max_size? integer
  --- @field private _items R[]
  --- @field private _right_i integer
  --- @field private _left_i integer
  local Queue = {}
  Queue.__index = Queue

  --- Returns the number of items in the queue.
  --- @return integer
  function Queue:size()
    return self._right_i - self._left_i
  end

  --- Returns the maximum number of items in the queue.
  --- @return integer?
  function Queue:max_size()
    return self._max_size
  end

  --- Put an item into the queue.
  ---
  --- If the queue is full, wait until a free slot is available.
  --- @async
  --- @param value any
  function Queue:put(value)
    self._non_full:wait()
    self:put_nowait(value)
  end

  --- Get an item from the queue.
  ---
  --- If the queue is empty, wait until an item is available.
  --- @async
  --- @return any
  function Queue:get()
    self._non_empty:wait()
    return self:get_nowait()
  end

  --- Get an item from the queue without blocking.
  ---
  --- If the queue is empty, raise an error.
  --- @return any
  function Queue:get_nowait()
    if self:size() == 0 then
      error('Queue is empty', 2)
    end
    -- TODO(lewis6991): For a long_running queue, _left_i might overflow.
    self._left_i = self._left_i + 1
    local item = self._items[self._left_i]
    self._items[self._left_i] = nil
    if self._left_i == self._right_i then
      self._non_empty:clear()
    end
    self._non_full:set(1)
    return item
  end

  --- Put an item into the queue without blocking.
  --- If no free slot is immediately available, raise "Queue is full" error.
  --- @param value any
  function Queue:put_nowait(value)
    if self:size() == self:max_size() then
      error('Queue is full', 2)
    end
    self._right_i = self._right_i + 1
    self._items[self._right_i] = value
    self._non_empty:set(1)
    if self:size() == self:max_size() then
      self._non_full:clear()
    end
  end

  --- @package
  --- Create a new FIFO queue with async support.
  --- ```lua
  ---  local queue = vim.async._queue()
  ---
  ---  local producer = vim.async.run(function()
  ---    for i = 1, 10 do
  ---      vim.async.sleep(100)
  ---      queue:put(i)
  ---    end
  ---    queue:put(nil)
  ---  end)
  ---
  ---  vim.async.run(function()
  ---    while true do
  ---      local value = queue:get()
  ---      if value == nil then
  ---        break
  ---      end
  ---      print(value)
  ---    end
  ---    print("Done")
  ---  end)
  --- ```
  --- @param max_size? integer The maximum number of items in the queue, defaults to no limit
  --- @return vim.async.Queue<any>
  function M._queue(max_size)
    local self = setmetatable({
      _items = {},
      _left_i = 0,
      _right_i = 0,
      _max_size = max_size,
      _non_empty = M._event(),
      _non_full = M._event(),
    }, Queue)

    self._non_full:set()

    return self
  end
end

do --- M.semaphore()
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
    local r = pack_len(pcall(fn))
    self:release()
    local stat = r[1]
    if not stat then
      local err = r[2]
      error(err)
    end
    return unpack_len(r, 2)
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
  ---
  --- ```lua
  --- vim.async.run(function()
  ---   local semaphore = vim.async.semaphore(2)
  ---
  ---   local tasks = {}
  ---
  ---   local value = 0
  ---   for i = 1, 10 do
  ---     tasks[i] = vim.async.run(function()
  ---       semaphore:with(function()
  ---         value = value + 1
  ---         vim.async.sleep(10)
  ---         print(value) -- Never more than 2
  ---         value = value - 1
  ---       end)
  ---     end)
  ---   end
  ---
  ---   vim.async.await_all(tasks)
  ---   assert(value <= 2)
  --- end)
  --- ```
  --- @param permits? integer (default: 1)
  --- @return vim.async.Semaphore
  function M.semaphore(permits)
    validate('permits', permits, 'number', true)
    permits = permits or 1
    local obj = setmetatable({
      _max_permits = permits,
      _permits = permits,
      _event = M._event(),
    }, Semaphore)
    obj._event:set()
    return obj
  end
end

do --- M._inspect_tree()
  --- @private
  --- @param parent? vim.async.Task<any>
  --- @param prefix? string
  --- @return string[]
  local function inspect(parent, prefix)
    local tasks = {} --- @type table<any, vim.async.Task<any>?>
    if parent then
      for _, task in pairs(parent._children) do
        if not task._hidden then
          tasks[#tasks + 1] = task
        end
      end
    else
      -- Gather for all detached tasks
      for _, task in pairs(threads) do
        if not task._parent and not task._hidden then
          tasks[#tasks + 1] = task
        end
      end
    end

    local r = {} --- @type string[]
    for i, task in ipairs(tasks) do
      local last = i == #tasks
      r[#r + 1] = ('%s%s%s%s [%s]'):format(
        prefix or '',
        parent and (last and '└─ ' or '├─ ') or '',
        task.name or '',
        task._caller or '@unknown',
        task:status()
      )
      local child_prefix = (prefix or '') .. (parent and (last and '   ' or '│  ') or '')
      for _, line in ipairs(inspect(task, child_prefix)) do
        r[#r + 1] = line
      end
    end
    return r
  end

  --- Inspect the current async task tree.
  ---
  --- Returns a string representation of the task tree, showing the names and
  --- statuses of each task.
  --- @return string
  function M._inspect_tree()
    -- Inspired by https://docs.python.org/3.14/whatsnew/3.14.html#asyncio-introspection-capabilities
    return table.concat(inspect(), '\n')
  end
end

return M
