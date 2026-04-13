# ElixirKit

[![Test](https://github.com/livebook-dev/elixirkit/actions/workflows/test.yml/badge.svg)](https://github.com/livebook-dev/elixirkit/actions/workflows/test.yml)

Run Elixir from Rust/Tauri apps and exchange messages over the current TCP [PubSub] transport.

See ["Building Desktop Apps with Tauri"](guides/tauri.md) for a step-by-step guide for using ElixirKit with Phoenix LiveView and [Tauri](https://tauri.app).

Also, see:

  * [`examples/cli_script.rs`](https://github.com/livebook-dev/elixirkit/blob/main/examples/cli_script.rs)
  * [`examples/tauri_project`](https://github.com/livebook-dev/elixirkit/blob/main/examples/tauri_project)
  * [`examples/tauri_script.rs`](https://github.com/livebook-dev/elixirkit/blob/main/examples/tauri_script.rs)

## Usage

On the Rust side, use [`elixirkit::elixir`] to start Elixir and
[`elixirkit::PubSub`] to exchange messages. Subscribe before starting Elixir so
no messages are missed:

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
mobile runtime, or capability/plugin architecture is being introduced yet, and
`ElixirKit.PubSub` remains fully supported for direct use.

Structured bridge envelopes now layer over one reserved internal topic on top
of the same TCP PubSub transport. Existing raw topic/message broadcasts remain
unchanged and fully backward compatible.

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

Registration is still explicit in `src-tauri/src/lib.rs`. The preferred host
seam is `PubSub::register_capability_handlers`, which registers capability
metadata together with the handlers for its available actions so metadata and
dispatch cannot drift silently. Capability request and success-response bodies
use JSON only inside the existing broker payload bytes; the outer bridge
envelope stays the same binary protocol.

For example, the Tauri app registers `clipboard` like this, using small local
request/response structs for the JSON body shape:

```rust
use elixirkit::{
    ActionAvailability, CapabilityAction, CapabilityBacking, CapabilityHandler,
    CapabilityNamespace, CapabilityPermission,
};
use tauri_plugin_clipboard_manager::ClipboardExt;

pubsub.register_capability_handlers(
    CapabilityNamespace::new(
        "clipboard",
        CapabilityBacking::TauriPlugin,
        CapabilityPermission::NotApplicable,
        vec![
            CapabilityAction::new("read_text", ActionAvailability::Available),
            CapabilityAction::new("write_text", ActionAvailability::Available),
        ],
    ),
    vec![
        CapabilityHandler::json("read_text", move |_request: EmptyRequest| {
            let text = app_handle.clipboard().read_text()
                .map_err(|error| error.to_string())?;
            Ok(ReadTextResponse { text })
        }),
        CapabilityHandler::json("write_text", move |request: WriteTextRequest| {
            app_handle.clipboard().write_text(&request.text)
                .map_err(|error| error.to_string())?;
            Ok(EmptyResponse {})
        }),
    ],
)?;
```

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

The matching Elixir wrappers stay tiny and capability-specific:

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
at the app layer, this is still not the later package/crate split, and there
is still no omnibus enable-all plugin.

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
