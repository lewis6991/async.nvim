local helpers = require('nvim-test.helpers')
local exec_lua = helpers.exec_lua
local eq = helpers.eq

local function wait(f)
  for _ = 1, 100 do
    helpers.sleep(10)
    local r = f() --[[@as any]]
    if r and r ~= vim.NIL then
      return
    end
  end
  error('Timeout')
end

local function exec(f)
  return exec_lua([[
    return loadstring(...)()
  ]], string.dump(f))
end

local function exec_wait(f)
  wait(function()
    return exec(f)
  end)
end


describe('async', function()
  before_each(function()
    helpers.clear()
    exec_lua('package.path = ...', package.path)
  end)

  it('works', function()
    exec(function()
      local async = require('async')

      --- @type fun(cmd: string, opts: table): code: integer, signal: integer
      local spawn = async.wrap(3, vim.uv.spawn)

      async.run(function()
        local code1 = spawn('echo', { args = {'foo'} })
        if code1 ~= 0 then
          return
        end

        local code2 = spawn('echo', { args = {'bar'} })
        if code2 ~= 0 then
          return
        end

        spawn('echo', { args = { 'baz' } })
        _G.DONE = true
      end)
    end)

    exec_wait(function()
      return _G.DONE
    end)

  end)

  it('can run join()', function()
    exec(function()
      local async = require('async')

      local function gen_task(i)
        return async.sync(0, function()
          async.schedule()
          return i
        end)
      end

      local tasks = {}
      for i = 1, 10 do
        tasks[i] = gen_task(i)
      end

      async.run(function()
        _G.RESULT = async.join(2, tasks)
      end)
    end)

    exec_wait(function()
      return _G.RESULT
    end)

    local exp = {}
    for i = 1, 10 do
      exp[i] = { i }
    end

    eq(exp, exec(function()
      return _G.RESULT
    end))
  end)

end)
