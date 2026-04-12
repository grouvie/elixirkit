defmodule ElixirKit.Bridge.Protocol.Test do
  use ExUnit.Case, async: true

  alias ElixirKit.Bridge.Protocol
  alias ElixirKit.Bridge.Protocol.{Event, Request, Response}

  test "request envelopes round trip" do
    envelope = Protocol.request("req-1", <<0, 1, 2, 3>>)

    assert {:ok, encoded} = Protocol.encode(envelope)

    assert {:ok,
            %Request{
              version: 1,
              kind: :request,
              request_id: "req-1",
              body: <<0, 1, 2, 3>>
            }} = Protocol.decode(encoded)
  end

  test "response envelopes round trip" do
    envelope = Protocol.response("req-1", "pong")

    assert {:ok, encoded} = Protocol.encode(envelope)

    assert {:ok,
            %Response{
              version: 1,
              kind: :response,
              request_id: "req-1",
              body: "pong"
            }} = Protocol.decode(encoded)
  end

  test "event envelopes round trip" do
    envelope = Protocol.event("ready")

    assert {:ok, encoded} = Protocol.encode(envelope)

    assert {:ok, %Event{version: 1, kind: :event, body: "ready"}} = Protocol.decode(encoded)
  end

  test "decode reports truncated payloads against the declared payload size" do
    envelope = Protocol.request("req-1", "ping")
    encoded = Protocol.encode!(envelope)
    truncated = binary_part(encoded, 0, byte_size(encoded) - 1)

    assert {:error, :truncated_envelope} = Protocol.decode(truncated)
  end

  test "decode reports extra payload bytes as invalid lengths" do
    envelope = Protocol.response("req-1", "pong")
    encoded = Protocol.encode!(envelope)

    assert {:error, :invalid_lengths} = Protocol.decode(encoded <> <<0>>)
  end

  test "call bodies round trip an operation and opaque payload" do
    assert {:ok, body} = Protocol.encode_call_body("bridge.echo", <<1, 2, 3>>)
    assert {:ok, {"bridge.echo", <<1, 2, 3>>}} = Protocol.decode_call_body(body)
  end

  test "call results round trip success payloads" do
    assert {:ok, body} = Protocol.encode_call_result({:ok, "pong"})
    assert {:ok, {:ok, "pong"}} = Protocol.decode_call_result(body)
  end

  test "call results round trip error payloads" do
    assert {:ok, body} = Protocol.encode_call_result({:error, "unsupported operation"})
    assert {:ok, {:error, "unsupported operation"}} = Protocol.decode_call_result(body)
  end

  test "capability bodies round trip normalized capability truth" do
    capabilities = %{
      "bridge" => %{
        backing: :core,
        permission: :not_applicable,
        actions: %{
          "capabilities" => :available,
          "echo" => :available
        }
      },
      "clipboard" => %{
        backing: :tauri_plugin,
        permission: :prompt,
        actions: %{
          "read_text" => :unsupported_platform
        }
      }
    }

    assert {:ok, body} = Protocol.encode_capabilities(capabilities)
    assert {:ok, ^capabilities} = Protocol.decode_capabilities(body)
  end

  test "capability bodies keep permission separate from availability" do
    capabilities = %{
      "clipboard" => %{
        backing: :tauri_plugin,
        permission: :denied,
        actions: %{
          "read_text" => :available,
          "write_text" => :unsupported
        }
      }
    }

    assert {:ok, body} = Protocol.encode_capabilities(capabilities)
    assert {:ok, decoded} = Protocol.decode_capabilities(body)

    assert decoded["clipboard"].permission == :denied
    assert decoded["clipboard"].actions["read_text"] == :available
    assert decoded["clipboard"].actions["write_text"] == :unsupported
  end
end
