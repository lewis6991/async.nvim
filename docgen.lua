#!/usr/bin/env -S nvim -l

--- @class EmmyDoc.Type
--- @field name string
--- @field description? string
--- @field type 'class'|'alias'
--- @field members EmmyDoc.Module.Member[]

--- @class EmmyDoc.Global
--- @field name string

--- @class EmmyDoc.Fun.Param
--- @field name string
--- @field typ string
--- @field desc? string

--- @class EmmyDoc.Fun: EmmyDoc.Module.Member
--- @field params EmmyDoc.Fun.Param[]
--- @field returns EmmyDoc.Fun.Param[]
--- @field is_meth boolean
--- @field is_async boolean
--- @field overloads string[]
--- @field type 'fn'

--- @class EmmyDoc.Module.Member
--- @field name string
--- @field description? string
--- @field type string

--- @class EmmyDoc.Module
--- @field name string
--- @field description? string
--- @field file string
--- @field members EmmyDoc.Module.Member[]

--- @class EmmyDoc
--- @field types EmmyDoc.Type[]
--- @field globals EmmyDoc.Global[]
--- @field modules EmmyDoc.Module[]

local function denil(x)
  if x == vim.NIL then
    return nil
  end
  return x
end

local function indent(s, n)
  local pad = string.rep(' ', n)
  return s:gsub('([^\n]+)', pad .. '%1')
end

---@param file file*
---@param desc string
local function write_desc(file, desc)
  desc = desc:gsub('```lua', '>lua')
  desc = desc:gsub('[ ]*```', '<')

  desc = desc:gsub('%[([^]]+)%]', '|%1|')

  desc = desc:gsub('### ([^\n]*)', function(s)
    local pad = string.rep(' ', 78 - #s)
    return ('%s*%s*'):format(pad, s)
  end)
  file:write('\n', desc, '\n\n')
end

local function write_param(file, param, typ_names)
  local name = denil(param.name)
  local typ = denil(param.typ)
  local desc = denil(param.desc)
  file:write('    - ')
  if name then
    file:write('{', name, '} ')
  end
  file:write('(`', typ or '???', '`)')
  if typ and typ_names[typ] then
    file:write(' (See |', typ, '|)')
  end
  if desc then
    file:write(': ', desc)
  end
  file:write('\n')
end

local function write_header(file, nm, tag)
  local pad = string.rep(' ', 78 - #tag - #nm)
  file:write(nm, pad, tag, '\n')
end

---@param file file*
---@param mod_name string
---@param member EmmyDoc.Module.Member
--- @param typ_names table<string, boolean>
local function write_member(file, mod_name, member, typ_names)
  if vim.startswith(member.name, '_') then
    return
  end

  file:write(string.rep('-', 78), '\n')
  local desc = denil(member.description)

  if member.type == 'field' then
    file:write('*', mod_name, '.', member.name, '*\n')
    file:write('    Type: `', member.typ, '\n\n')
    if desc then
      write_desc(file, indent(desc, 4))
    end
  elseif member.type == 'fn' then
    --- @cast member EmmyDoc.Fun

    local param_names = {} --- @type string[]
    for _, param in ipairs(member.params) do
      param_names[#param_names + 1] = ('{%s}'):format(param.name)
    end

    local sig, tag = nil, nil
    if member.name == '__call' then
      sig = ('%s(%s)'):format(mod_name, table.concat(param_names, ', '))
      tag = ('*%s()*'):format(mod_name)
    else
      local sep = member.is_meth and ':' or '.'
      sig = ('%s%s%s(%s)'):format(mod_name, sep, member.name, table.concat(param_names, ', '))
      
      -- Strip 'vim.' prefix from tags for generic module namespace
      local tag_name = mod_name:gsub('^vim%.', '')
      tag = ('*%s%s%s()*'):format(tag_name, sep, member.name)
    end
    write_header(file, sig, tag)

    if desc then
      write_desc(file, indent(desc, 4))
    end

    if member.is_async then
      file:write('    Attributes: ~\n')
      file:write('    - `async`\n')
      file:write('\n')
    end

    if #member.generics > 0 then
      file:write('    Generics: ~\n')
      file:write('    - ')
      for i, generic in ipairs(member.generics) do
        file:write('`', generic.name, '`')
        if i < #member.generics then
          file:write(', ')
        end
      end
      file:write('\n\n')
    end

    if #member.overloads > 0 then
      file:write('    Overloads: ~\n')
      for _, overload in ipairs(member.overloads) do
        file:write('    - `', overload, '`\n')
      end
      file:write('\n')
    end

    if #member.params > 0 then
      file:write('    Parameters: ~\n')
      for _, param in ipairs(member.params) do
        write_param(file, param, typ_names)
      end
      file:write('\n')
    end

    if #member.returns > 0 and not (#member.returns == 1 and member.returns[1].typ == 'nil') then
      file:write('    Returns: ~\n')
      for _, ret in ipairs(member.returns) do
        write_param(file, ret, typ_names)
      end
    end
  else
    file:write(mod_name, '.', member.name, '\n')
    if desc then
      write_desc(file, indent(desc, 4))
    end
  end

  file:write('\n')
end

-- ---@param file file*
-- ---@param module EmmyDoc.Module
-- local function write_module(file, module)
--   local mod_name = module.name
--   file:write(string.rep('=', 78), '\n')
--   file:write(mod_name, '\n')
--   local desc = denil(module.description)
--   if desc then
--     write_desc(file, desc)
--   end
--
--   for _, member in ipairs(module.members) do
--     write_member(file, module.name, member)
--   end
-- end

--- @param file file*
--- @param typ EmmyDoc.Type
--- @param typ_names table<string, boolean>
local function write_type(file, typ, typ_names)
  local mod_name = typ.name
  file:write(string.rep('=', 78), '\n')
  file:write('*', mod_name, '*\n')
  local desc = denil(typ.description)
  if desc and desc ~= '' then
    write_desc(file, desc)
  end

  if typ.type == 'alias' then
    file:write('    Type: `', typ.typ, '\n\n')
  end

  for _, member in ipairs(typ.members) do
    write_member(file, typ.name, member, typ_names)
  end
end

local function add_type_member(typ, member)
  local desc = denil(member.description)
  for i, existing in ipairs(typ.members) do
    if existing.name == member.name and existing.type == member.type then
      if desc or not denil(existing.description) then
        typ.members[i] = member
      end
      return
    end
  end

  typ.members[#typ.members + 1] = member
end

local function type_map(o)
  local types = {} --- @type table<string, EmmyDoc.Type>
  for _, typ in ipairs(o.types) do
    types[typ.name] = typ
  end
  return types
end

local function merge_parent_type_members(o)
  local types = type_map(o)
  local parent = types['vim.async._core']
  local child = types['vim.async']
  if not parent or not child then
    return
  end

  local child_desc = denil(child.description)
  if not child_desc or child_desc == '' then
    child.description = parent.description
  end

  local members = child.members
  child.members = {}
  for _, member in ipairs(parent.members) do
    add_type_member(child, member)
  end
  for _, member in ipairs(members) do
    add_type_member(child, member)
  end
end

local function merge_public_module_members(o)
  local exported = {
    ['async._semaphore'] = 'vim.async',
  }

  local constructors = {
    ['async._semaphore'] = {
      name = 'semaphore',
      params = {
        { name = 'permits', typ = 'integer?', desc = '(default: 1)' },
      },
      returns = {
        { typ = 'vim.async.Semaphore' },
      },
    },
  }

  local types = type_map(o)

  for _, module in ipairs(o.modules) do
    local type_name = exported[module.name]
    local typ = type_name and types[type_name]
    if typ then
      for _, member in ipairs(module.members) do
        add_type_member(typ, member)
      end

      local constructor = constructors[module.name]
      if constructor then
        add_type_member(typ, {
          type = 'fn',
          name = constructor.name,
          description = module.description,
          generics = {},
          params = constructor.params,
          returns = constructor.returns,
          overloads = {},
          is_async = false,
          is_meth = false,
        })
      end
    end
  end
end

local function remove_private_types(o)
  local private = {
    ['vim.async.Event'] = true,
    ['vim.async.Future'] = true,
    ['vim.async.Queue'] = true,
    ['vim.async.Runtime'] = true,
    ['vim.async._core'] = true,
  }

  local types = {} --- @type EmmyDoc.Type[]
  for _, typ in ipairs(o.types) do
    if not private[typ.name] then
      types[#types + 1] = typ
    end
  end
  o.types = types
end

local function main()
  local json_path = arg[1]
  local output = arg[2]

  local d = assert(io.open(json_path, 'r'))

  --- @type EmmyDoc
  local o = vim.json.decode(d:read('*a'))
  d:close()

  local file = assert(io.open(output, 'w'))

  table.sort(o.modules, function(a, b)
    return a.name < b.name
  end)

  merge_parent_type_members(o)
  merge_public_module_members(o)
  remove_private_types(o)

  -- for _, module in ipairs(o.modules) do
  --   if module.name == 'async' then
  --     write_module(file, module)
  --   end
  -- end

  table.sort(o.types, function(a, b)
    return a.name < b.name
  end)

  local typ_names = {} --- @type table<string, boolean>

  for _, typ in ipairs(o.types) do
    typ_names[typ.name] = true
  end

  for _, typ in ipairs(o.types) do
    write_type(file, typ, typ_names)
  end

  file:write('vim:tw=78:ts=8:sw=4:sts=4:et:ft=help:norl:\n')
  file:close()
  vim.cmd.helptags('doc')
end

main()
