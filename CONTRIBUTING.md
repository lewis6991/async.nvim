# Contributing

## Repository Layout

- `CONCURRENCY_MODEL.md` is the specification.
- `lua/async/core.lua` contains the shared concurrency engine.
- `lua/async.lua` is the generic package wrapper that auto-detects Neovim and exposes `async.init()`.
- `lua/async/nvim.lua` is the Neovim-only wrapper with fixed runtime bindings.
- `lua/async/_util.lua` contains shared helpers that remain part of the vendored output.
- `lua/async/_compat.lua` contains generic replacements for helpers that come from the Neovim stdlib when vendored.
- `test/async_spec.lua` contains the test suite.

## Development Workflow

- Run `make test` for the test suite.
- Run `make format` after code changes.
- Run `make doc` after code changes.
- Run `make vendor-nvim` to regenerate the Neovim-bound vendored file at `build/nvim/async.lua`.

## Vendoring into Neovim

When this code is dropped into the Neovim codebase, the intent is to vendor the
shared engine from `lua/async/core.lua` and keep only a small Neovim-specific
wrapper. That keeps `async.init()` and the generic runtime interface out of the
vendored API surface.

`make vendor-nvim` generates a Neovim-bound version of `core.lua` at
`build/nvim/async.lua`.

The vendoring script:

- removes the internal runtime adapter
- rewrites compatibility bindings to Neovim equivalents such as `vim._maxint`, `vim.validate`, and `vim.is_callable`
- rewrites runtime access to `vim` APIs
- inlines the non-stdlib helpers from `lua/async/_util.lua`
- fails if any `_runtime` or internal utility requires are left behind

Do not edit `build/nvim/async.lua` by hand. Treat it as generated output.
