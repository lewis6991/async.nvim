
# async

Small async library for Neovim plugins

## Functions

### `running()`

Returns whether the current execution context is async.


---
### `run(func, callback, ...)`

Run a function in an async context.

#### Parameters:

* `func` (`function`):
* `callback` (`function`):
* `...` (`any`):  Arguments for func

---
### `wait(argc, protected, func, ...)`

Wait on a callback style function

#### Parameters:

* `argc` (`integer?`):  The number of arguments of func. Must be included.
* `protected` (`boolean?`):  call the function in protected mode (like pcall)
* `func` (`function`):  callback style function to execute
* `...` (`any`):  Arguments for func

---
### `create(func, argc, strict)`

Use this to create a function which executes in an async context but
 called from a non-async context.  Inherently this cannot return anything
 since it is non-blocking

#### Parameters:

* `func` (`function`):
* `argc` (`number`):  The number of arguments of func. Defaults to 0
* `strict` (`boolean`):  Error when called in non-async context

---
### `void(func, strict)`

Create a function which executes in an async context but
 called from a non-async context.

#### Parameters:

* `func` (`function`):
* `strict` (`boolean`):  Error when called in non-async context

---
### `wrap(func, argc, protected, strict)`

Creates an async function with a callback style function.

 TODO(lewis6991): Remove protected


#### Parameters:

* `func` (`function`):  A callback style function to be converted. The last argument must be the callback.
* `argc` (`integer`):  The number of arguments of func. Must be included.
* `protected` (`boolean`):  call the function in protected mode (like pcall)
* `strict` (`boolean`):  Error when called in non-async context

---
### `join(thunks, n, interrupt_check)`

Run a collection of async functions (`thunks`) concurrently and return when
 all have finished.

#### Parameters:

* `thunks` (`function[]`):
* `n` (`integer`):  Max number of thunks to run concurrently
* `interrupt_check` (`function`):  Function to abort thunks between calls

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
