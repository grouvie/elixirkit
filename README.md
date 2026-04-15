# ElixirKit

[![Test](https://github.com/livebook-dev/elixirkit/actions/workflows/test.yml/badge.svg)](https://github.com/livebook-dev/elixirkit/actions/workflows/test.yml)

Run Elixir from Rust/Tauri apps over the current TCP [PubSub] transport, with
an ergonomic host-side [`Bridge`] layer for Tauri setup.

See ["Building Desktop Apps with Tauri"](guides/tauri.md) for a step-by-step guide for using ElixirKit with Phoenix LiveView and [Tauri](https://tauri.app).

Also, see:

  * [`examples/cli_script.rs`](https://github.com/livebook-dev/elixirkit/blob/main/examples/cli_script.rs)
  * [`examples/tauri_project`](https://github.com/livebook-dev/elixirkit/blob/main/examples/tauri_project)
  * [`examples/tauri_script.rs`](https://github.com/livebook-dev/elixirkit/blob/main/examples/tauri_script.rs)

`examples/tauri_project` is now the primary migration/reference app for the
current bridge architecture. It is intentionally example-focused: it shows the
handshake, capability discovery, brokered request/response, multiple
capabilities, and raw topic events while still using the same underlying
transport, broker, protocol, and desktop startup flow.

## Usage

### Low-level transport

[`elixirkit::PubSub`] remains the public low-level transport API. Use it
directly when you want full control over topics, launching, and lifecycle:

```rust
// main.rs
let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0")
    .expect("failed to listen");

let pubsub_for_topic = pubsub.clone();
pubsub.subscribe("topic", move |msg| {
    if msg == b"ping" {
        pubsub_for_topic.broadcast("topic", b"pong").unwrap();
    }
});

let status = elixirkit::elixir(&["script.exs"])
    .env("ELIXIRKIT_PUBSUB", pubsub.url())
    .status()
    .expect("failed to start Elixir");

std::process::exit(status.code().unwrap_or(1));
```

### Tauri host setup

For Tauri hosts, enable the crate's `tauri` feature and prefer
[`elixirkit::Bridge`] and [`elixirkit::BridgeBuilder`] for setup ergonomics.
They still use the same underlying `PubSub` transport, but they own the
common host chores: listening, explicit capability registration, topic hooks,
and Elixir process launch wiring.

```rust
use elixirkit::{Bridge, BridgeContext, BridgeLaunchContext};

tauri::Builder::default().setup(|app| {
    Bridge::builder()
        .listen_url("tcp://127.0.0.1:0")
        .capability(tauri_plugin_elixir_opener::register)
        .capability(tauri_plugin_elixir_clipboard::register)
        .capability(tauri_plugin_elixir_window::register)
        .on_topic("messages", |context: BridgeContext, message| {
            if message == b"ready" {
                let _ = context.broadcast("messages", b"host:ready acknowledged");
                let _ = context.broadcast("messages", b"host:window created");
            }
        })
        .launch(|context: &BridgeLaunchContext| {
            if cfg!(debug_assertions) {
                Ok(elixirkit::mix("phx.server", &[]))
            } else {
                Ok(elixirkit::release(context.resource_dir()?.join("rel"), "example"))
            }
        })
        .attach(app)
        .expect("failed to attach ElixirKit bridge");

    Ok(())
});
```

This is still not the wrapper CLI or the final bootstrap negotiation model.
`Bridge` is only a thin host-side ergonomic layer over the current transport.

On the Elixir side, prefer [`ElixirKit.Bridge`] as the application-facing entrypoint.
Today it is a thin delegation layer over [`ElixirKit.PubSub`], so the public
transport is still the same TCP PubSub connection:

```elixir
# script.exs
Mix.install([{:elixirkit, github: "livebook-dev/elixirkit"}])

children = [
  {ElixirKit.Bridge,
   connect: System.get_env("ELIXIRKIT_PUBSUB") || :ignore,
   on_exit: &System.stop/0}
]

{:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

ElixirKit.Bridge.subscribe("topic")
ElixirKit.Bridge.broadcast("topic", "ping")

receive do
  message ->
    IO.puts(["[elixir] ", inspect(message)])
end
```

This is an incremental bridge seam, not a rewrite. No NIF-backed bridge,
mobile runtime, or wrapper CLI is being introduced here, and
`ElixirKit.PubSub` remains fully supported for direct use.

Structured bridge envelopes now layer over one reserved internal topic on top
of the same TCP PubSub transport. Existing raw topic/message broadcasts remain
unchanged and fully backward compatible.

The current extraction layout is now:

- `elixirkit_rs/` for the bridge/core Rust crate
- `crates/tauri-plugin-elixir-opener`
- `crates/tauri-plugin-elixir-clipboard`
- `crates/tauri-plugin-elixir-window`
- `packages/elixirkit_opener`
- `packages/elixirkit_clipboard`
- `packages/elixirkit_window`

For brokered request/response over that same connection, use
`ElixirKit.Bridge.call/2` or `call/3`. The Elixir side keeps one shared
internal router per bridge connection, implemented internally as
`ElixirKit.Bridge.Router`. It subscribes to the reserved bridge topic once and
matches responses by opaque request id for all brokered calls, including
capability lookup. Today the built-in core-owned operations are still narrow:
`bridge.echo` exists as a small end-to-end proof path for later capability
work, and `bridge.capabilities` reports feature truth from the core registry
plus any host capabilities explicitly registered on this bridge connection:

```elixir
case ElixirKit.Bridge.call("bridge.echo", "ping") do
  {:ok, "ping"} -> :ok
  {:error, reason} -> IO.inspect(reason, label: "bridge call failed")
end
```

This brokered call path still rides over the current TCP PubSub transport. It
does not replace raw PubSub topics, and it does not introduce any WebView-based
bridge layer.

The example Tauri app now proves multiple real host capability slices without
changing the transport or outer bridge framing:

- `opener` uses Tauri's official opener plugin
- `clipboard` uses Tauri's official clipboard plugin
- `window` uses direct Tauri core APIs

Registration is still explicit in `src-tauri/src/lib.rs`, but the
capability-specific host code now lives in separate local crates. The
low-level capability seam remains `PubSub::register_capability_handlers`,
which registers capability metadata together with the handlers for its
available actions so metadata and dispatch cannot drift silently. The new
Rust-side `Bridge` builder simply layers host setup ergonomics on top of that
same contract. Capability request and success-response bodies still use JSON
only inside the existing broker payload bytes; the outer bridge envelope stays
the same binary protocol. The current example keeps those handlers on the
existing broker callback path and does not add a separate main-thread handoff
layer or any broker redesign.

The example Tauri app now stays explicit and small:

```rust
Bridge::builder()
    .capability(tauri_plugin_elixir_opener::register)
    .capability(tauri_plugin_elixir_clipboard::register)
    .capability(tauri_plugin_elixir_window::register);
```

The LiveView home screen in that example is now a small reference console
instead of only a counter. It still keeps the raw `"ready"` and `"count"`
flow intact, and it now also shows:

- bridge status and handshake context
- capability discovery from `ElixirKit.Bridge.capabilities/0`
- a brokered `bridge.echo` request/response form
- opener, clipboard, and window demos through the extracted packages
- an example-local event log fed by the unchanged raw `messages` topic

That event log is still just raw topic traffic. The brokered calls above it are
separate demos of the existing request/response path over the same transport.

Capability discovery reflects that explicit registration:

```elixir
%{
  "bridge" => %{
    backing: :core,
    permission: :not_applicable,
    actions: %{
      "capabilities" => :available,
      "echo" => :available
    }
  },
  "opener" => %{
    backing: :tauri_plugin,
    permission: :not_applicable,
    actions: %{
      "open" => :available
    }
  },
  "clipboard" => %{
    backing: :tauri_plugin,
    permission: :not_applicable,
    actions: %{
      "read_text" => :available,
      "write_text" => :available
    }
  },
  "window" => %{
    backing: :tauri_core,
    permission: :not_applicable,
    actions: %{
      "list" => :available,
      "set_title" => :available
    }
  }
} = ElixirKit.Bridge.capabilities()
```

The matching Elixir wrappers now live in separate local packages. In this repo
the example app depends on:

```elixir
{:elixirkit, path: "../.."},
{:elixirkit_opener, path: "../../packages/elixirkit_opener"},
{:elixirkit_clipboard, path: "../../packages/elixirkit_clipboard"},
{:elixirkit_window, path: "../../packages/elixirkit_window"}
```

The public wrapper APIs stay tiny and capability-specific:

```elixir
case ElixirKit.Opener.open("https://elixir-lang.org") do
  :ok -> :ok
  {:error, reason} -> IO.inspect(reason, label: "open failed")
end

{:ok, text} = ElixirKit.Clipboard.read_text()
{:ok, [%{label: "main", title: "Example"}]} = ElixirKit.Window.list()
```

This is feature discovery, not authorization. Availability is reported per
action, while permission state stays separate. Registration is still explicit
at the app layer, this is now the first package/crate extraction pass, and
there is still no omnibus enable-all plugin or wrapper CLI.

## Docs

Run `mix docs` from the repo root to generate:

- the root Elixir bridge/core docs in `doc/`
- the Rust docs in `doc/rs/`
- the extracted Elixir capability package docs in:
  - `doc/packages/elixirkit_opener`
  - `doc/packages/elixirkit_clipboard`
  - `doc/packages/elixirkit_window`

Each extracted Elixir capability package also has its own local docs flow, so
you can run `mix docs` inside `packages/elixirkit_opener`,
`packages/elixirkit_clipboard`, or `packages/elixirkit_window` to build only
that package's docs.

## License

Copyright (C) 2026 Dashbit

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

[PubSub]:                         https://hexdocs.pm/elixirkit/ElixirKit.PubSub.html
[`ElixirKit.Bridge`]:             https://hexdocs.pm/elixirkit/ElixirKit.Bridge.html
[`ElixirKit.PubSub`]:             https://hexdocs.pm/elixirkit/ElixirKit.PubSub.html

[`elixirkit_rs`]:                 https://hexdocs.pm/elixirkit/rs/elixirkit/index.html
[`elixirkit::elixir`]:            https://hexdocs.pm/elixirkit/rs/elixirkit/fn.elixir.html
[`elixirkit::PubSub`]:            https://hexdocs.pm/elixirkit/rs/elixirkit/struct.PubSub.html
