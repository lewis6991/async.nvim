---@meta

---@class vim.uv.Timer: vim.async.Timer
---@field start fun(self, timeout: integer, repeat_interval: integer, callback: fun())
---@field close fun(self, callback?: fun())

---@class vim.uv
---@field new_timer fun(): vim.uv.Timer
---@field fs_stat fun(path: string, callback: fun(...))

---@class vim.fn
---@field mkdir fun(path: string, flags: string): integer

---@class vim
---@field _maxint integer
---@field fn vim.fn
---@field uv vim.uv
vim = {}

---@param timeout integer
---@param predicate fun(): boolean
---@param interval? integer
---@param fast_only? boolean
---@return boolean
function vim.wait(timeout, predicate, interval, fast_only) end

---@param callback fun()
function vim.schedule(callback) end

---@param callback fun()
---@param timeout integer
function vim.defer_fn(callback, timeout) end

---@param name string
---@param value any
---@param expected_type string
---@param optional? boolean
function vim.validate(name, value, expected_type, optional) end

---@param obj any
---@return boolean
---@return_cast obj function
function vim.is_callable(obj) end

---@param value any
---@return string
function vim.inspect(value) end

---@generic T
---@param dst T[]
---@param src T[]
---@return T[]
function vim.list_extend(dst, src) end

---@param path string
---@return any
function vim.fs_stat(path) end

---@param argv string[]
---@param opts? table
---@param on_exit? fun(result: table)
---@return any
function vim.system(argv, opts, on_exit) end
