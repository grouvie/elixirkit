defmodule ElixirKit.PubSub.Test do
  use ExUnit.Case, async: true

  setup_all do
    # Pre-cache Mix.install so that Elixir spawned from Rust tests
    # doesn't print install output, which we test against.
    {_output, 0} =
      System.cmd("elixir", [
        "-e",
        """
        Mix.install([{:elixirkit, path: "#{__DIR__}/../.."}])
        """
      ])

    :ok
  end

  test "bidirectional messaging" do
    start_supervised!({ElixirKit.PubSub, name: :pubsub1, listen: "tcp://127.0.0.1:0"})

    url = ElixirKit.PubSub.url(:pubsub1)
    start_supervised!({ElixirKit.PubSub, name: :pubsub2, connect: url})

    ElixirKit.PubSub.subscribe(:pubsub1, "topic")
    ElixirKit.PubSub.subscribe(:pubsub2, "topic")

    ElixirKit.PubSub.broadcast(:pubsub1, "topic", "message1")
    ElixirKit.PubSub.broadcast(:pubsub2, "topic", "message2")

    assert_receive "message1"
    assert_receive "message2"
    refute_receive _
  end

  test "bidirectional messaging (rust)" do
    port =
      rust(~s"""
      fn main() {
          let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0")
              .expect("failed to listen");

          let pubsub_for_topic1 = pubsub.clone();
          pubsub.subscribe("topic1", move |msg| {
              if msg == b"ping1" {
                  pubsub_for_topic1.broadcast("topic1", b"pong1").unwrap();
              }
          });

          let pubsub_for_topic2 = pubsub.clone();
          pubsub.subscribe("topic2", move |msg| {
              if msg == b"ping2" {
                  pubsub_for_topic2.broadcast("topic2", b"pong2").unwrap();
              }
          });

          let code = r#"
              Mix.install([{:elixirkit, path: "#{__DIR__}/../.."}])

              {:ok, _} =
                ElixirKit.PubSub.start_link(
                  connect: System.fetch_env!("ELIXIRKIT_PUBSUB"),
                  on_exit: fn -> System.stop() end
                )

              ElixirKit.PubSub.subscribe("topic1")
              ElixirKit.PubSub.broadcast("topic1", "ping1")

              ElixirKit.PubSub.subscribe("topic2")
              ElixirKit.PubSub.broadcast("topic2", "ping2")

              receive do
                "pong1" ->
                  IO.puts("got: pong1")
              end

              receive do
                "pong2" ->
                  IO.puts("got: pong2")
              end
          "#;

          let status = elixirkit::elixir(&["-e", code])
              .env("ELIXIRKIT_PUBSUB", pubsub.url())
              .status()
              .expect("failed to start Elixir");

          std::process::exit(status.code().unwrap_or(1));
      }
      """)

    assert_receive {^port, {:data, {:eol, "got: pong1"}}}, 10_000
    assert_receive {^port, {:data, {:eol, "got: pong2"}}}, 10_000
    assert_receive {^port, {:exit_status, 0}}, 10_000
  end

  test "structured bridge envelope traverses the existing transport (rust)" do
    port =
      rust(~s"""
      const BRIDGE_TOPIC: &str = "__elixirkit_bridge__";
      const MAGIC: [u8; 4] = *b"EKBP";
      const VERSION: u8 = 1;
      const KIND_EVENT: u8 = 3;

      fn encode(kind: u8, request_id: &[u8], body: &[u8]) -> Vec<u8> {
          let request_id_len = u16::try_from(request_id.len()).expect("request id should fit in u16");
          let body_len = u32::try_from(body.len()).expect("body should fit in u32");
          let mut bytes = Vec::with_capacity(12 + request_id.len() + body.len());
          bytes.extend_from_slice(&MAGIC);
          bytes.push(VERSION);
          bytes.push(kind);
          bytes.extend_from_slice(&request_id_len.to_be_bytes());
          bytes.extend_from_slice(&body_len.to_be_bytes());
          bytes.extend_from_slice(request_id);
          bytes.extend_from_slice(body);
          bytes
      }

      fn decode(bytes: &[u8]) -> Result<(u8, Vec<u8>, Vec<u8>), &'static str> {
          if bytes.len() < 12 {
              return Err("truncated");
          }
          if bytes[..4] != MAGIC {
              return Err("invalid magic");
          }
          if bytes[4] != VERSION {
              return Err("invalid version");
          }

          let kind = bytes[5];
          let request_id_len = usize::from(u16::from_be_bytes([bytes[6], bytes[7]]));
          let body_len = usize::try_from(u32::from_be_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]))
              .expect("body length should fit in usize");
          let expected_len = 12 + request_id_len + body_len;

          if bytes.len() != expected_len {
              return Err("invalid lengths");
          }

          let request_id = bytes[12..12 + request_id_len].to_vec();
          let body = bytes[12 + request_id_len..].to_vec();
          Ok((kind, request_id, body))
      }

      fn main() {
          let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0")
              .expect("failed to listen");

          let pubsub_for_bridge = pubsub.clone();
          pubsub.subscribe(BRIDGE_TOPIC, move |msg| {
              let (kind, request_id, body) = decode(msg).expect("bridge envelope should decode");
              assert_eq!(kind, KIND_EVENT, "expected event envelope");
              assert!(request_id.is_empty(), "event envelopes should not carry a request id");
              assert_eq!(body, b"ping", "expected event body");

              let response = encode(KIND_EVENT, b"", b"pong");
              pubsub_for_bridge.broadcast(BRIDGE_TOPIC, &response).unwrap();
          });

          let code = r#"
              Mix.install([{:elixirkit, path: "#{__DIR__}/../.."}])

              {:ok, _} =
                ElixirKit.Bridge.start_link(
                  connect: System.fetch_env!("ELIXIRKIT_PUBSUB"),
                  on_exit: fn -> System.stop() end
                )

              ElixirKit.Bridge.Protocol.subscribe()
              ElixirKit.Bridge.Protocol.broadcast(ElixirKit.Bridge.Protocol.event("ping"))

              receive do
                message ->
                  case ElixirKit.Bridge.Protocol.decode(message) do
                    {:ok, envelope} ->
                      if envelope.__struct__ == ElixirKit.Bridge.Protocol.Event and
                           envelope.body == "pong" do
                        IO.puts("got: pong")
                      else
                        IO.puts("unexpected: \#{inspect(envelope)}")
                        System.halt(1)
                      end

                    other ->
                      IO.puts("unexpected: \#{inspect(other)}")
                      System.halt(1)
                  end
              end
          "#;

          let status = elixirkit::elixir(&["-e", code])
              .env("ELIXIRKIT_PUBSUB", pubsub.url())
              .status()
              .expect("failed to start Elixir");

          std::process::exit(status.code().unwrap_or(1));
      }
      """)

    assert_receive {^port, {:data, {:eol, "got: pong"}}}, 10_000
    assert_receive {^port, {:exit_status, 0}}, 10_000
  end

  test "bridge.echo performs a brokered round trip against the rust side" do
    port =
      rust(~s"""
      fn main() {
          let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0")
              .expect("failed to listen");

          let code = r#"
              Mix.install([{:elixirkit, path: "#{__DIR__}/../.."}])

              {:ok, _} =
                ElixirKit.Bridge.start_link(
                  connect: System.fetch_env!("ELIXIRKIT_PUBSUB"),
                  on_exit: fn -> System.stop() end
                )

              case ElixirKit.Bridge.call("bridge.echo", "ping") do
                {:ok, "ping"} ->
                  IO.puts("got: ping")

                other ->
                  IO.puts("unexpected: \#{inspect(other)}")
                  System.halt(1)
              end
          "#;

          let status = elixirkit::elixir(&["-e", code])
              .env("ELIXIRKIT_PUBSUB", pubsub.url())
              .status()
              .expect("failed to start Elixir");

          pubsub.wait();
          std::process::exit(status.code().unwrap_or(1));
      }
      """)

    assert_receive {^port, {:data, {:eol, "got: ping"}}}, 10_000
    assert_receive {^port, {:exit_status, 0}}, 10_000
  end

  test "bridge.capabilities returns built-in capability truth against the rust side" do
    port =
      rust(~s"""
      fn main() {
          let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0")
              .expect("failed to listen");

          let code = r#"
              Mix.install([{:elixirkit, path: "#{__DIR__}/../.."}])

              {:ok, _} =
                ElixirKit.Bridge.start_link(
                  connect: System.fetch_env!("ELIXIRKIT_PUBSUB"),
                  on_exit: fn -> System.stop() end
                )

              case ElixirKit.Bridge.capabilities() do
                %{
                  "bridge" => %{
                    backing: :core,
                    permission: :not_applicable,
                    actions: actions
                  }
                } ->
                  if actions["echo"] == :available and actions["capabilities"] == :available do
                    IO.puts("got: capabilities")
                  else
                    IO.puts("unexpected: \#{inspect(actions)}")
                    System.halt(1)
                  end

                other ->
                  IO.puts("unexpected: \#{inspect(other)}")
                  System.halt(1)
              end
          "#;

          let status = elixirkit::elixir(&["-e", code])
              .env("ELIXIRKIT_PUBSUB", pubsub.url())
              .status()
              .expect("failed to start Elixir");

          pubsub.wait();
          std::process::exit(status.code().unwrap_or(1));
      }
      """)

    assert_receive {^port, {:data, {:eol, "got: capabilities"}}}, 10_000
    assert_receive {^port, {:exit_status, 0}}, 10_000
  end

  test "exit status propagates" do
    port =
      rust(~s"""
      fn main() {
          let code = r#"
              System.halt(2)
          "#;

          let status = std::process::Command::new("elixir")
              .args(&["-e", code])
              .status()
              .expect("failed to start Elixir");

          std::process::exit(status.code().unwrap());
      }
      """)

    assert_receive {^port, {:exit_status, 2}}, 10_000
  end

  @tag :tmp_dir
  test "elixir exception", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "test.rs")

    File.write!(path, ~s"""
    #!/usr/bin/env -S cargo +nightly -Zscript
    ---cargo
    [package]
    edition = "2024"

    [dependencies]
    elixirkit = { path = "#{__DIR__}/../../elixirkit_rs" }
    ---

    fn main() {
        let code = r#"
            raise "foo"
        "#;

        let status = std::process::Command::new("elixir")
            .args(&["-e", code])
            .status()
            .expect("failed to start Elixir");

        std::process::exit(status.code().unwrap());
    }
    """)

    {output, 1} = System.cmd("cargo", ["+nightly", "-Zscript", path], stderr_to_stdout: true)
    assert output =~ "** (RuntimeError) foo"
  end

  @tag :tmp_dir
  test "beam exits when rust dies", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "test.rs")
    elixir_exited_path = Path.join(tmp_dir, "elixir_exited")

    File.write!(path, ~s"""
    #!/usr/bin/env -S cargo +nightly -Zscript
    ---cargo
    [package]
    edition = "2024"

    [dependencies]
    elixirkit = { path = "#{__DIR__}/../../elixirkit_rs" }
    ---

    fn main() {
        let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0")
            .expect("failed to listen");

        pubsub.subscribe("messages", move |msg| {
            if msg == b"ready" {
                println!("ready");
            }
        });

        let code = r#"
            Mix.install([{:elixirkit, path: "#{__DIR__}/../.."}])

            {:ok, _} = ElixirKit.PubSub.start_link(connect: System.fetch_env!("ELIXIRKIT_PUBSUB"), on_exit: fn ->
              File.touch!("#{elixir_exited_path}")
            end)

            ElixirKit.PubSub.subscribe("messages")
            ElixirKit.PubSub.broadcast("messages", "ready")

            Process.sleep(:infinity)
        "#;

        let mut child = std::process::Command::new("elixir")
            .args(&["-e", code])
            .env("ELIXIRKIT_PUBSUB", pubsub.url())
            .env("MIX_ENV", "test")
            .spawn()
            .expect("failed to start Elixir");

        child.wait().expect("failed to wait for child");
    }
    """)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("cargo")},
        [:binary, :use_stdio, :exit_status, args: ["+nightly", "-Zscript", path]]
      )

    assert_receive {^port, {:data, "ready\n"}}, 10_000

    {:os_pid, rust_pid} = Port.info(port, :os_pid)
    System.cmd("kill", [to_string(rust_pid)])
    assert_until(fn -> File.exists?(elixir_exited_path) end, 5000, "BEAM did not exit cleanly")
    assert_receive {^port, {:exit_status, _}}
  end

  defp assert_until(check, timeout, message) do
    if check.() do
      :ok
    else
      if timeout > 0 do
        Process.sleep(100)
        assert_until(check, timeout - 100, message)
      else
        flunk(message)
      end
    end
  end

  defp rust(code) do
    hash = :crypto.hash(:md5, code) |> Base.encode16(case: :lower)
    path = Path.join("/tmp", hash)

    File.write!(path, """
    #!/usr/bin/env -S cargo +nightly -Zscript
    ---cargo
    [package]
    edition = "2024"

    [dependencies]
    elixirkit = { path = "#{__DIR__}/../../elixirkit_rs" }
    ---

    #{code}
    """)

    Port.open(
      {:spawn_executable, System.find_executable("cargo")},
      [:binary, :use_stdio, :exit_status, {:line, 4096}, args: ["+nightly", "-Zscript", path]]
    )
  end
end
