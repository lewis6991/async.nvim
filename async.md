# async

Small async library for Neovim plugins

## Functions

### `async(func)`

Create an async function.

#### Parameters:

* `func` (`function`)

#### Returns:

* `vim.async.Task`: handle to running async function.

---

### `await(argc, func, ...)`

Must be run in an async context.

Asynchronously wait on a callback style function.

#### Parameters:

* `argc` (`integer`):  Position of the callback argument in `func`.
* `func` (`function`):
* `...` (`any[]`): arguments for `func`

#### Returns:

Return values of `func`.

---

### `arun(func)`

#### Parameters:

* `func` (`function`):

#### Returns:

* `vim.async.Task`: handle to running async function.

---

### `awrap(argc, func)`

Wraps callback style function so it asynchronously waits
in an async context.

#### Parameters:

* `argc` (`integer`):  The number of arguments of func. Must be included.
* `func` (`function`):  A callback style function to be converted. The last argument must be the callback.

#### Returns:

Wrapped function of `func`.

Must be run in an async context.

---

### `iter(tasks)`

Must be run in an async context.

#### Returns:

Iterator function that yields the results of each task.

---

### `join(n, thunks, interrupt_check)`

Run a collection of async functions (`thunks`) concurrently and return when
 all have finished.

#### Parameters:

* `n` (`integer`):  Max number of thunks to run concurrently
* `thunks` (`function[]`):
* `interrupt_check` (`function`):  Function to abort thunks between calls

---

### `schedule()`

An async function that when called will yield to the Neovim scheduler to be
 able to call the API.

Must be run in an async context.
