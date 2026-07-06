# PUC Lua async.iter notes

PUC Lua 5.1 cannot yield from a generic-for iterator call. This means this
shape is not supportable for `async.iter()` on PUC Lua:

```lua
for task in async.iter(tasks) do
  async.await(task)
end
```

The iterator function itself may need to suspend while waiting for the next
completed task. In Lua 5.1, the VM calls generic-for iterators through a boundary
that cannot yield, so it fails with:

```text
attempt to yield across metamethod/C-call boundary
```

`coxpcall` does not fix this. It can make protected calls yieldable by relaying
through another coroutine, but it does not make Lua 5.1 generic-for iterator
calls yieldable.

Use the direct-call form for PUC Lua:

```lua
local next_task = async.iter(tasks)

while true do
  local task = next_task()
  if task == nil then
    break
  end
  async.await(task)
end
```

That direct call can yield because it is an ordinary Lua function call from
inside the task coroutine.

Suggested docs/tests direction:

- Document the while-loop form as the portable `async.iter()` pattern.
- Treat `for task in async.iter(tasks) do ... end` as LuaJIT/Lua 5.2+ syntax.
- Keep PUC Lua tests for `async.iter()` using the direct-call loop.
- Avoid redesigning `async.iter()` to block or pump the event loop just to make
  generic-for syntax work on Lua 5.1; that would change the scheduler semantics.
