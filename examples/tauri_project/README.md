# ElixirKit Tauri Example

This example is the current end-to-end desktop showcase for the repo.

It keeps the original raw PubSub handshake and counter flow:

- Phoenix broadcasts `"ready"` once the Elixir side starts under Tauri
- the LiveView counter still broadcasts raw `"count:N"` messages on the unchanged `messages` topic

It also now demonstrates the richer bridge surface that sits on top of that
same transport:

- `ElixirKit.Bridge.capabilities/0`
- `bridge.echo` over the brokered request/response path
- `ElixirKit.Clipboard`
- `ElixirKit.Window`
- `ElixirKit.Opener`

## Run It

Install dependencies and build the Phoenix assets:

```sh
mix setup
```

For the plain Phoenix experience:

```sh
mix phx.server
```

For the full desktop flow with the host bridge and extracted capability crates:

```sh
cargo tauri dev
```

## Local Dependencies

The example depends on the root bridge/core package plus the extracted local
capability packages:

```elixir
{:elixirkit, path: "../.."},
{:elixirkit_opener, path: "../../packages/elixirkit_opener"},
{:elixirkit_clipboard, path: "../../packages/elixirkit_clipboard"},
{:elixirkit_window, path: "../../packages/elixirkit_window"}
```

Its Tauri host depends on the matching extracted Rust crates by local path from
`src-tauri/Cargo.toml`.
