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
