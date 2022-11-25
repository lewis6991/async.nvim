
# async

Small async library for Neovim plugins

## Functions

### `sync(func, argc)`

Use this to create a function which executes in an async context but
 called from a non-async context.  Inherently this cannot return anything
 since it is non-blocking

#### Parameters:

* `func` (`function`):
* `argc` (`number`):  The number of arguments of func. Defaults to 0

---
### `void(func)`

Create a function which executes in an async context but
 called from a non-async context.

#### Parameters:

* `func` (`function`):

---
### `wrap(func, argc, protected)`

Creates an async function with a callback style function.

#### Parameters:

* `func` (`function`):  A callback style function to be converted. The last argument must be the callback.
* `argc` (`integer`):  The number of arguments of func. Must be included.
* `protected` (`boolean`):  call the function in protected mode (like pcall)

---
### `join(n, interrupt_check, thunks)`

Run a collection of async functions (`thunks`) concurrently and return when
 all have finished.

#### Parameters:

* `n` (`integer`):  Max number of thunks to run concurrently
* `interrupt_check` (`function`):  Function to abort thunks between calls
* `thunks` (`function[]`):

---
### `curry(fn, ...)`

Partially applying arguments to an async function

#### Parameters:

* `fn` (`function`):
* `...`:  arguments to apply to `fn`

---
## Fields

### `scheduler`

An async function that when called will yield to the Neovim scheduler to be
 able to call the API.


---
