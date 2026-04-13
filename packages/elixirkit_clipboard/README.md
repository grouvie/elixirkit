# ElixirKit.Clipboard

`ElixirKit.Clipboard` is the extracted Elixir wrapper for the `clipboard`
capability package.

It keeps the public API focused on the host clipboard actions already proven by
the bridge:

```elixir
{:ok, text} = ElixirKit.Clipboard.read_text()
:ok = ElixirKit.Clipboard.write_text("Copied from LiveView")
```

## Local Development

In this repo, depend on the bridge/core package plus this capability package:

```elixir
{:elixirkit, path: "../.."},
{:elixirkit_clipboard, path: "../../packages/elixirkit_clipboard"}
```

The backing host capability is still registered explicitly on the Rust side
through the matching `tauri-plugin-elixir-clipboard` crate.

## Docs

Generate just this package's docs:

```sh
mix docs
```

That writes the site to `packages/elixirkit_clipboard/doc`.

From the repo root, `mix docs` now also regenerates the root docs, Rust docs,
and copies this package's docs into `doc/packages/elixirkit_clipboard`.
