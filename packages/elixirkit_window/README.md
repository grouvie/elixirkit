# ElixirKit.Window

`ElixirKit.Window` is the extracted Elixir wrapper for the `window` capability
package.

It exposes the small public API already proven by the bridge:

```elixir
{:ok, windows} = ElixirKit.Window.list()
:ok = ElixirKit.Window.set_title("window-1", "Renamed from Elixir")
```

## Local Development

In this repo, depend on the bridge/core package plus this capability package:

```elixir
{:elixirkit, path: "../.."},
{:elixirkit_window, path: "../../packages/elixirkit_window"}
```

The backing host capability is still registered explicitly on the Rust side
through the matching `tauri-plugin-elixir-window` crate.

## Docs

Generate just this package's docs:

```sh
mix docs
```

That writes the site to `packages/elixirkit_window/doc`.

From the repo root, `mix docs` now also regenerates the root docs, Rust docs,
and copies this package's docs into `doc/packages/elixirkit_window`.
