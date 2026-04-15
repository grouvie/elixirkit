# ElixirKit Tauri Example

This example is the current end-to-end desktop showcase for the repo.

It keeps the original raw PubSub handshake and counter flow:

- Phoenix broadcasts `"ready"` once the Elixir side starts under Tauri
- the LiveView counter still broadcasts raw `"count:N"` messages on the unchanged `messages` topic

It also now demonstrates the richer bridge surface that sits on top of that
same transport:

- bridge status and handshake summary
- `ElixirKit.Bridge.capabilities/0`
- `bridge.echo` over the brokered request/response path
- `ElixirKit.Clipboard`
- `ElixirKit.Window`
- `ElixirKit.Opener`
- a raw `messages` topic event log driven by an example-local forwarder

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

The preferred host setup pattern now lives in
`src-tauri/src/lib.rs` through `elixirkit::Bridge::builder()`. `PubSub`
remains available underneath for low-level use, but the example now uses the
builder to keep topic hooks, explicit capability registration, and Elixir
launch wiring in one place without introducing a wrapper CLI or startup
negotiation layer.

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
