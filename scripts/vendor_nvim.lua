#!/usr/bin/env -S nvim -l
--- Generate a vendored `vim.async` module from the local `async.nvim` sources.
---
--- The transformer preserves the public docs and types from `lua/async/core.lua`,
--- inlines helpers from `lua/async/_util.lua`, and rewrites runtime bindings so
--- the result can be dropped into Neovim's codebase as a single file.

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

  assert(count > 0, ('vendor_nvim: did not find %q'):format(from), 2)

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
--- @param marker string
--- @param replacement string
--- @return string
local function replace_prefix_before(text, marker, replacement)
  local idx = assert(text:find(marker, 1, true))

  return replacement .. text:sub(idx)
end

--- @param text string
--- @param start_marker string
--- @param end_marker string
--- @return string
local function extract_block(text, start_marker, end_marker)
  local start_idx = assert(text:find(start_marker, 1, true))
  local end_idx = assert(text:find(end_marker, start_idx, true))
  return text:sub(start_idx, end_idx - 1)
end

--- @param text string
--- @param start_marker string
--- @param end_marker string
--- @param replacement string
--- @return string
local function strip_block(text, start_marker, end_marker, replacement)
  local start_idx = assert(text:find(start_marker, 1, true))
  local end_idx = assert(text:find(end_marker, start_idx, true))

  local after_end = end_idx + #end_marker
  return text:sub(1, start_idx - 1) .. replacement .. text:sub(after_end)
end

--- @param source string
--- @return string
local function render_util_inline(source)
  local output = source

  output = replace_once_plain(output, 'local M = {}\n\n', '')
  output = replace_all_plain(output, 'function M.', 'local function ')
  output = replace_once_plain(output, '\nreturn M\n', '\n')

  if output:find('M%.') then
    error('vendor_nvim: unhandled util module residue remains in transformed output', 2)
  end

  return output
end

--- @param source string
--- @return string
local function render_compat_alias_block(source)
  --- @type string[]
  local lines = {}

  for local_name, field_name in source:gmatch('local%s+([%a_][%w_]*)%s*=%s*compat%.([%a_][%w_]*)\n') do
    assert(
      vim[field_name] ~= nil,
      ('vendor_nvim: vim.%s is missing for compat alias %s'):format(field_name, local_name)
    )
    lines[#lines + 1] = ('local %s = vim.%s'):format(local_name, field_name)
  end
  if #lines == 0 then
    error('vendor_nvim: did not find compat aliases', 2)
  end

  lines[#lines + 1] = ''
  return table.concat(lines, '\n')
end

--- @param core_source string
--- @param util_source string
--- @return string
local function transform(core_source, util_source)
  local output = core_source

  local type_block = extract_block(
    core_source,
    '--- @class vim.async.Timer: vim.async.Closable\n',
    '--- @class vim.async.Runtime\n'
  )

  local module_block = extract_block(
    core_source,
    '--- This module implements an asynchronous programming library for Lua,\n',
    '--- Weak table to keep track of running tasks\n'
  )

  local vendored_module_block = replace_once_plain(module_block, 'M._runtime = _runtime\n', '')

  local preamble = table.concat({
    vendored_module_block,
    '',
    render_compat_alias_block(core_source),
    type_block,
    render_util_inline(util_source),
    '',
  }, '\n')

  output = replace_prefix_before(output, '--- @class vim.async.Timer: vim.async.Closable\n', '')

  output = strip_block(output, '--- @class vim.async.Runtime\n', 'local _runtime = {}\n', '')

  output = replace_once_plain(output, 'M._runtime = _runtime\n', '')
  output = replace_once_plain(output, vendored_module_block, '')

  output = replace_once_plain(output, type_block, preamble)

  output = replace_all_plain(output, '_runtime.', 'vim.')
  output = replace_all_plain(output, 'vim.new_timer', 'vim.uv.new_timer')

  if output:find('_runtime', 1, true) then
    error('vendor_nvim: unhandled _runtime residue remains in transformed output', 2)
  end

  if
    output:find("require('async._util')", 1, true)
    or output:find("require('async._compat')", 1, true)
  then
    error('vendor_nvim: utility requires remain in transformed output', 2)
  end

  return table.concat({
    '-- Generated from lua/async/core.lua by scripts/vendor_nvim.lua.',
    '-- This file is intended for vendoring into the Neovim codebase.',
    '',
    output,
  }, '\n')
end

--- @param output_path? string
local function run(output_path)
  assert(output_path, 'output path argument is required')
  local input = 'lua/async/core.lua'
  local util_path = 'lua/async/_util.lua'
  local output = transform(read_file(input), read_file(util_path))
  write_file(output_path, output)
end

run(arg[1])
