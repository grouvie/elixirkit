# ElixirKit.Opener

`ElixirKit.Opener` is the small Elixir wrapper for the extracted `opener`
capability package.

It depends on the root `elixirkit` bridge/core package and keeps the public API
intentionally narrow:

```elixir
case ElixirKit.Opener.open("https://elixir-lang.org") do
  :ok -> :ok
  {:error, reason} -> IO.inspect(reason, label: "open failed")
end
```

## Local Development

In this repo, depend on the bridge/core package plus this capability package:

```elixir
{:elixirkit, path: "../.."},
{:elixirkit_opener, path: "../../packages/elixirkit_opener"}
```

The Rust side still registers the backing host capability explicitly through the
matching `tauri-plugin-elixir-opener` crate.

## Docs

Generate just this package's docs:

```sh
mix docs
```

That writes the site to `packages/elixirkit_opener/doc`.

From the repo root, `mix docs` now also regenerates the root docs, Rust docs,
and copies this package's docs into `doc/packages/elixirkit_opener`.
