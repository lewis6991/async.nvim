#!/usr/bin/env -S nvim -l
--- Generate vendored Neovim files from the local async.nvim sources.

--- @param path string
--- @return string
local function read_file(path)
  local file = assert(io.open(path, 'r'))
  local content = assert(file:read('*a'))
  file:close()
  return content
end

--- @param path string
--- @param content string
local function write_file(path, content)
  local dir = path:match('^(.*)/[^/]+$')
  if dir and dir ~= '' then
    vim.fn.mkdir(dir, 'p')
  end

  local file = assert(io.open(path, 'w'))
  file:write(content)
  file:close()
end

--- @param text string
--- @param from string
--- @param to string
--- @return string
--- @return integer
local function replace_all_plain(text, from, to)
  local count = 0
  --- @type string[]
  local parts = {}
  local start = 1

  while true do
    local i, j = text:find(from, start, true)
    if not i then
      break
    end
    --- @cast j integer

    parts[#parts + 1] = text:sub(start, i - 1)
    parts[#parts + 1] = to
    start = j + 1
    count = count + 1
  end

  parts[#parts + 1] = text:sub(start)
  return table.concat(parts), count
end

--- @param text string
--- @param from string
--- @param to string
--- @return string
local function replace_once_plain(text, from, to)
  local replaced, count = replace_all_plain(text, from, to)
  assert(count == 1, ('vendor_nvim: expected exactly 1 %q, found %d'):format(from, count), 2)
  return replaced
end

--- @param text string
--- @param from string
--- @param to string
--- @return string
local function replace_required_plain(text, from, to)
  local replaced, count = replace_all_plain(text, from, to)
  assert(count > 0, ('vendor_nvim: did not find %q'):format(from), 2)
  return replaced
end

--- @param text string
--- @param start_marker string
--- @param end_marker string
--- @param replacement string
--- @return string
local function strip_block(text, start_marker, end_marker, replacement)
  local start_idx = assert(text:find(start_marker, 1, true))
  local end_idx = assert(text:find(end_marker, start_idx, true))
  return text:sub(1, start_idx - 1) .. replacement .. text:sub(end_idx + #end_marker)
end

--- @param source string
--- @return string
local function normalize_luals_diagnostics(source)
  return source
    :gsub('access%-invisible', 'invisible')
    :gsub('param%-type%-not%-match', 'param-type-mismatch')
end

--- @param path string
--- @param transform? fun(source: string): string
--- @param internal? boolean
--- @return string
local function render_source(path, transform, internal)
  local source = read_file(path):gsub('\n$', '')
  if transform then
    source = transform(source)
  end

  source = source:gsub("require%('async%.", "require('vim.async.")
  source = source:gsub('require%("async%.', 'require("vim.async.')
  source = normalize_luals_diagnostics(source)

  if internal then
    source = table.concat({
      '-- LuaLS cannot model the generic annotations used by this vendored implementation.',
      '---@diagnostic disable: no-unknown, undefined-doc-name, luadoc-miss-symbol, missing-return, missing-return-value, param-type-mismatch, return-type-mismatch, redundant-return-value, undefined-field, need-check-nil, await-in-sync',
      '',
      source,
    }, '\n')
  end

  return source .. '\n'
end

--- @param source string
--- @return string
local function strip_doc_comments(source)
  return source:gsub('%-%-%-[^\n]*\n', '')
end

--- @param source string
--- @return string
local function hide_module_functions(source)
  return strip_doc_comments(source):gsub('function M%.', '--- @nodoc\nfunction M.')
end

local coxpcall_pcall = table.concat({
  'local pcall = pcall',
  'do',
  "  local ok, coxpcall = pcall(require, 'coxpcall')",
  "  if ok and type(coxpcall) == 'table' and type(coxpcall.pcall) == 'function' then",
  '    pcall = coxpcall.pcall',
  '  end',
  'end',
}, '\n')

local coxpcall_pcall_running = table.concat({
  'local pcall = pcall',
  'local coroutine_running = coroutine.running',
  'do',
  "  local ok, coxpcall = pcall(require, 'coxpcall')",
  "  if ok and type(coxpcall) == 'table' then",
  "    if type(coxpcall.pcall) == 'function' then",
  '      pcall = coxpcall.pcall',
  '    end',
  "    if type(coxpcall.running) == 'function' then",
  '      coroutine_running = coxpcall.running',
  '    end',
  '  end',
  'end',
}, '\n')

--- @param source string
--- @return string
local function transform_runtime(source)
  source = replace_once_plain(
    source,
    "local validate = require('async._compat').validate\n",
    'local validate = vim.validate\n'
  )
  source = replace_once_plain(
    source,
    '--- @class vim.async.Timer: vim.async.Closable\n',
    '--- @class vim.async.Timer: vim.async.Closable\n--- @nodoc\n'
  )
  source = replace_once_plain(
    source,
    '--- @alias vim.async.TimerFactory fun(): vim.async.Timer\n',
    '--- @alias vim.async.TimerFactory fun(): vim.async.Timer\n--- @nodoc\n'
  )
  source = replace_once_plain(
    source,
    '--- @class vim.async.ConfigOpts\n',
    '--- @class vim.async.ConfigOpts\n--- @nodoc\n'
  )
  source = replace_once_plain(
    source,
    '--- @class vim.async.Runtime\n',
    '--- @class vim.async.Runtime\n--- @nodoc\n'
  )
  source = replace_once_plain(
    source,
    '--- @param opts vim.async.ConfigOpts\nfunction M.config(opts)\n',
    '--- @nodoc\n--- @param opts vim.async.ConfigOpts\nfunction M.config(opts)\n'
  )
  return source
end

--- @param source string
--- @return string
local function transform_core(source)
  source = replace_once_plain(source, "local compat = require('async._compat')\n", '')
  source = replace_once_plain(
    source,
    'local is_callable = compat.is_callable\nlocal pcall = compat.pcall\nlocal validate = compat.validate\n',
    table.concat({
      'local is_callable = vim.is_callable',
      'local validate = vim.validate',
      coxpcall_pcall_running,
      'local maxint = 2 ^ 32 - 1',
      '',
    }, '\n')
  )
  source = replace_required_plain(source, 'compat.running()', 'coroutine_running()')
  source = replace_required_plain(source, 'compat._maxint', 'maxint')
  source = replace_once_plain(source, '--- Core task scheduler implementation.\n', '')
  return replace_once_plain(
    source,
    '--- @class vim.async._core\n',
    '--- @class vim.async._core\n--- @nodoc\n'
  )
end

--- @param source string
--- @return string
local function transform_public_module(source)
  source = replace_once_plain(
    source,
    "local compat = require('async._compat')\n",
    'local validate = vim.validate\n'
  )
  source = replace_required_plain(source, 'compat.validate(', 'validate(')
  source = strip_block(
    source,
    '--- Configure async runtime behavior.\n',
    '--- Create an async function from a callback-style function.\n',
    '--- Create an async function from a callback-style function.\n'
  )
  return replace_once_plain(source, '  M.config({\n', '  runtime.config({\n')
end

--- @param source string
--- @return string
local function transform_semaphore(source)
  source = replace_once_plain(source, "local compat = require('async._compat')\n", '')
  source = replace_once_plain(
    source,
    'local pcall = compat.pcall\n',
    coxpcall_pcall .. '\nlocal validate = vim.validate\n'
  )
  return replace_required_plain(source, 'compat.validate(', 'validate(')
end

local modules = {
  { 'async/_util.lua', 'lua/async/_util.lua', hide_module_functions },
  { 'async/_errors.lua', 'lua/async/_errors.lua', hide_module_functions },
  { 'async/_runtime.lua', 'lua/async/_runtime.lua', transform_runtime },
  { 'async/_future.lua', 'lua/async/_future.lua', strip_doc_comments },
  { 'async/_core.lua', 'lua/async/_core.lua', transform_core },
  { 'async/_event.lua', 'lua/async/_event.lua', strip_doc_comments },
  { 'async/_queue.lua', 'lua/async/_queue.lua', strip_doc_comments },
  { 'async/_semaphore.lua', 'lua/async/_semaphore.lua', transform_semaphore },
}

--- @param output_path string
local function write_module_files(output_path)
  write_file(output_path, render_source('lua/async.lua', transform_public_module))

  local output_dir = assert(output_path:match('^(.*)/[^/]+$'))
  vim.fn.delete(vim.fs.joinpath(output_dir, 'async'), 'rf')
  for _, module in ipairs(modules) do
    write_file(vim.fs.joinpath(output_dir, module[1]), render_source(module[2], module[3], true))
  end
end

--- @return string
local function transform_test()
  local output = read_file('test/async_spec.lua')

  output = replace_once_plain(
    output,
    "--- @diagnostic disable: global-in-non-module\nlocal helpers = require('nvim-test.helpers')\nlocal exec_lua = helpers.exec_lua\n",
    "local n = require('test.functional.testnvim')()\nlocal exec_lua = n.exec_lua\n"
  )

  output = replace_once_plain(output, '    helpers.clear()\n', '    n.clear()\n')
  output = replace_once_plain(
    output,
    "      _G.Async = require('async')\n",
    "      _G.Async = require('vim.async')\n      _G.AsyncRuntime = require('vim.async._runtime')\n"
  )
  output = replace_once_plain(
    output,
    "      _G.pcall = require('async._compat').pcall\n",
    table.concat({
      '      local safe_pcall = pcall',
      "      local ok, coxpcall = pcall(require, 'coxpcall')",
      "      if ok and type(coxpcall) == 'table' and type(coxpcall.pcall) == 'function' then",
      '        safe_pcall = coxpcall.pcall',
      '      end',
      '      _G.pcall = safe_pcall',
      '',
    }, '\n')
  )

  output = strip_block(
    output,
    "  describe('module wrappers', function()\n",
    "  describe('task cancellation and closing', function()\n",
    "  describe('task cancellation and closing', function()\n"
  )

  output = replace_required_plain(output, 'test/async_spec.lua:%d+', '.*async_spec.lua:%d+')
  output = replace_required_plain(output, 'Async.config(', 'AsyncRuntime.config(')
  output = output:gsub("require%('async%.", "require('vim.async.")
  output = output:gsub('require%("async%.', 'require("vim.async.')
  output = normalize_luals_diagnostics(output)

  return output
end

--- @param output_path string?
--- @param test_output_path string?
local function run(output_path, test_output_path)
  assert(output_path, 'output path argument is required')
  write_module_files(output_path)
  if test_output_path then
    write_file(test_output_path, transform_test())
  end
end

run(arg[1], arg[2])
