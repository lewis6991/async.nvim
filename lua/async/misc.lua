local async = require('async')

-- Examples of functions built on top of async.lua

local M = {}

--- Like async.join, but with a limit on the number of concurrent tasks.
--- @async
--- @param max_jobs integer
--- @param task_funs async.TaskFun[]
function M.join_n_1(max_jobs, task_funs)
  if #task_funs == 0 then
    return
  end

  max_jobs = math.min(max_jobs, #task_funs)

  local running = {} --- @type async.TaskFun[]

  -- Start the first batch of tasks
  for i = 1, max_jobs do
    running[i] = task_funs[i]()
  end

  -- As tasks finish, add new ones
  for i = max_jobs + 1, #task_funs do
    local finished = async.joinany(running)
    --- @cast finished -?
    running[finished] = task_funs[i]()
  end

  -- Wait for all tasks to finish
  async.join(running)
end

--- Like async.join, but with a limit on the number of concurrent tasks.
--- (different implementation and doesn't use `async.joinany()`)
--- @async
--- @param max_jobs integer
--- @param task_funs async.TaskFun[]
function M.join_n_2(max_jobs, task_funs)
  if #task_funs == 0 then
    return
  end

  max_jobs = math.min(max_jobs, #task_funs)

  local remaining = { select(max_jobs + 1, unpack(task_funs)) }
  local to_go = #task_funs

  async.await(1, function(finish)
    local function cb()
      to_go = to_go - 1
      if to_go == 0 then
        finish()
      elseif #remaining > 0 then
        local next_task = table.remove(remaining)
        next_task():await(cb)
      end
    end

    for i = 1, max_jobs do
      task_funs[i]():await(cb)
    end
  end)
end

return M
