# async

Small async library for Neovim plugins

## Functions

### `sync(argc, func)`

Use this to create a function which executes in an async context but
 called from a non-async context.  Inherently this cannot return anything
 since it is non-blocking

#### Parameters:

* `argc` (`integer`):  The number of arguments of func. Defaults to 0
* `func` (`function`):

---

### `wait(argc, func, ...)`

#### Parameters:

* `argc` (`integer`):  The number of arguments of func. Defaults to 0
* `func` (`function`):
* `...` (`any[]`): arguments for `func`

---

### `run(func)`

#### Parameters:

* `func` (`function`):

---

### `wrap(argc, func, argc)`

Creates an async function with a callback style function.

#### Parameters:

* `argc` (`integer`):  The number of arguments of func. Must be included.
* `func` (`function`):  A callback style function to be converted. The last argument must be the callback.

---

### `join(n, thunks, interrupt_check)`

Run a collection of async functions (`thunks`) concurrently and return when
 all have finished.

#### Parameters:

* `n` (`integer`):  Max number of thunks to run concurrently
* `thunks` (`function[]`):
* `interrupt_check` (`function`):  Function to abort thunks between calls

---

### `curry(fn, ...)`

Partially applying arguments to an async function

#### Parameters:

* `fn` (`function`):
* `...`:  arguments to apply to `fn`

---

### `scheduler()`

An async function that when called will yield to the Neovim scheduler to be
 able to call the API.
