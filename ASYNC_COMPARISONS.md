# Async Model Comparisons

This guide compares async.nvim with common async models in other languages.
The framing owes a lot to Nathaniel J. Smith's
[Notes on structured concurrency, or: Go statement considered harmful](https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/),
which argues for nursery-style task ownership as a replacement for unstructured
spawn-and-forget primitives.

The useful questions are:

- Is concurrency structured by default?
- What owns child work?
- Are tasks stackful green threads, stackless async frames, or real threads?
- How do failure and cancellation move through the system?

## High-Level Map

| Ecosystem | Structured concurrency | Execution model | Child ownership |
| --- | --- | --- | --- |
| async.nvim | Yes, inside tasks | Stackful Lua coroutines | The running task |
| Trio | Yes | Stackless Python coroutines | Nursery |
| Python asyncio | Opt-in with `TaskGroup` | Stackless Python coroutines | `TaskGroup`; otherwise caller/event loop |
| Kotlin | Yes, through scopes | Stackless suspend functions | `CoroutineScope` / `Job` |
| Swift | Yes, through language constructs | Runtime async tasks | Lexical scope / task group |
| Go | No by default | Stackful goroutines | `errgroup` / `context` by convention |
| JavaScript | No by default | Promise jobs on the event loop | Caller-held promises |
| Rust Tokio | No by default for spawned tasks | Stackless futures on runtime tasks | `JoinSet` or custom scope if used |
| C# | No by default | Stackless async state machines | Caller-held `Task`s |
| Java | Yes, with structured scopes | Stackful virtual threads | `StructuredTaskScope` |

## async.nvim

async.nvim uses Lua coroutines as stackful tasks. A task can suspend from deep in
ordinary Lua calls, so helper functions do not need to be marked async.

`async.run()` creates both a task handle and a child scope. Tasks created while a
task is running are attached children. The parent waits for attached children,
unhandled child failures propagate upward, and closing the parent closes the
children.

```lua
local async = require('async')

async.run(function()
  local user = async.run(fetch_user)
  local prefs = async.run(fetch_preferences)

  render(async.await(user), async.await(prefs))
end)
```

There is no separate nursery object. The currently running task is the scope.

## Trio

Trio is a close reference point for structured concurrency. Work is started
inside a nursery, and the nursery does not exit until its child tasks finish.
Child failures leave the nursery through the parent.

```python
import trio

async def main():
    async with trio.open_nursery() as nursery:
        nursery.start_soon(fetch_user)
        nursery.start_soon(fetch_preferences)

trio.run(main)
```

Compared with async.nvim:

- Trio has explicit nursery blocks.
- async.nvim uses the current task as the scope.
- Trio starts child tasks immediately; async.nvim attached children start when
  the parent reaches a checkpoint.

## Python asyncio

asyncio has both structured and unstructured styles. `asyncio.create_task()`
starts a task owned by the event loop. `asyncio.TaskGroup` gives related tasks a
scope that waits for them and cancels siblings on failure.

```python
import asyncio

async def main():
    async with asyncio.TaskGroup() as group:
        user = group.create_task(fetch_user())
        prefs = group.create_task(fetch_preferences())

    render(user.result(), prefs.result())

asyncio.run(main())
```

Compared with async.nvim:

- `TaskGroup` is close to async.nvim's parent task scope.
- Bare `create_task()` is closer to async.nvim `run(...):detach()`.
- asyncio groups aggregate exceptions; async.nvim keeps the first unhandled
  child failure.

## Kotlin Coroutines

Kotlin coroutines are structured around `CoroutineScope`. Coroutines launched
inside a scope become children of that scope, and cancellation flows through the
scope hierarchy.

```kotlin
import kotlinx.coroutines.*

suspend fun load() = coroutineScope {
    val user = async { fetchUser() }
    val prefs = async { fetchPreferences() }

    render(user.await(), prefs.await())
}
```

Compared with async.nvim:

- Kotlin has an explicit coroutine scope.
- async.nvim derives the scope from the currently running task.
- Kotlin separates `async` for result-producing work and `launch` for jobs;
  async.nvim uses `run()` for both.

## Swift

Swift has structured concurrency in the language. `async let` starts lexical
child tasks for a fixed set of work. Task groups handle dynamic child sets.

```swift
func load() async throws {
    async let user = fetchUser()
    async let prefs = fetchPreferences()

    let (u, p) = try await (user, prefs)
    render(u, p)
}
```

Dynamic groups look more like async.nvim's `iter()` loops:

```swift
func loadAll(_ ids: [ID]) async throws -> [User] {
    try await withThrowingTaskGroup(of: User.self) { group in
        for id in ids {
            group.addTask {
                try await fetchUser(id)
            }
        }

        var users: [User] = []
        for try await user in group {
            users.append(user)
        }
        return users
    }
}
```

Compared with async.nvim:

- Swift encodes the model in syntax and type checking.
- async.nvim implements the model as library code over Lua coroutines.
- Swift scope is lexical; async.nvim scope follows the task currently executing
  Lua code.

## Go

Goroutines are stackful lightweight threads managed by the Go runtime. They are
unstructured by default: `go f()` starts work without a parent handle. Structure
is usually added with `context.Context` and `errgroup`.

```go
func Load(ctx context.Context) error {
	g, ctx := errgroup.WithContext(ctx)

	g.Go(func() error {
		return fetchUser(ctx)
	})
	g.Go(func() error {
		return fetchPreferences(ctx)
	})

	return g.Wait()
}
```

Compared with async.nvim:

- Go's base primitive is more like detached work.
- `errgroup` adds parent-like waiting and first-error propagation.
- Go cancellation is passed through `context`; async.nvim cancellation is on the
  task handle.

## JavaScript

JavaScript promises are unstructured by default. Creating a promise starts or
represents work, but it does not make that work a child of the current async
function. `Promise.all()` waits for promises; it does not own or cancel them.

```js
async function load() {
  const controller = new AbortController()

  const user = fetchUser({ signal: controller.signal })
  const prefs = fetchPreferences({ signal: controller.signal })

  try {
    const [u, p] = await Promise.all([user, prefs])
    render(u, p)
  } catch (err) {
    controller.abort()
    throw err
  }
}
```

Compared with async.nvim:

- `Promise.all()` is closest to `iter()` or repeated `await()`: coordination
  over existing work.
- Cancellation is conventionally passed with `AbortSignal`.
- There is no implicit parent-child task tree.

## Rust Tokio

Rust futures are stackless state machines. Tokio schedules futures as lightweight
runtime tasks. `tokio::spawn()` returns a `JoinHandle` that can be awaited, but
spawned tasks are not automatically children of the current task.

```rust
use tokio::task;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let user = task::spawn(fetch_user());
    let prefs = task::spawn(fetch_preferences());

    render(user.await??, prefs.await??);
    Ok(())
}
```

Compared with async.nvim:

- Tokio tasks are independent unless you add structure around them.
- `JoinHandle` observes the result; it is not a parent scope.
- Cancellation is explicit with abort handles or cooperative cancellation
  primitives.

## C#

C# `async` methods compile into stackless state machines that return `Task` or
`Task<T>`. `Task.WhenAll()` coordinates multiple tasks, while cancellation is
passed explicitly with `CancellationToken`.

```csharp
using var cts = new CancellationTokenSource();

Task<User> user = FetchUserAsync(cts.Token);
Task<Prefs> prefs = FetchPreferencesAsync(cts.Token);

await Task.WhenAll(user, prefs);
Render(await user, await prefs);
```

Compared with async.nvim:

- `Task.WhenAll()` waits for tasks but does not create ownership.
- Cancellation must be accepted by each async operation.
- async.nvim creates child ownership from where `run()` is called.

## Java

Java has both unstructured and structured async styles. `CompletableFuture`
resembles JavaScript promises. Structured concurrency APIs pair well with
virtual threads: forked subtasks belong to a scope, and the scope joins them
before leaving.

```java
try (var scope = new StructuredTaskScope.ShutdownOnFailure()) {
    var user = scope.fork(() -> fetchUser());
    var prefs = scope.fork(() -> fetchPreferences());

    scope.join();
    scope.throwIfFailed();
    render(user.get(), prefs.get());
}
```

Compared with async.nvim:

- Java virtual threads are stackful lightweight threads.
- Structured scopes are explicit objects.
- async.nvim has stackful tasks too, but they are cooperative Lua coroutines on
  the event loop, not JVM threads.

## What This Means for async.nvim

async.nvim is closest to Trio nurseries, Python `TaskGroup`, Kotlin
`CoroutineScope`, Swift task groups, and Java structured scopes:

- child work has an owner
- parents wait for children
- unhandled child failure propagates upward
- cancellation propagates downward

Its distinctive choice is using Lua's stackful coroutines as the task execution
model. That gives Lua code a structured task tree without adding async syntax or
forcing every helper function to be colored.
