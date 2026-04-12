defmodule ElixirKit.Bridge.CapabilitiesTest do
  use ExUnit.Case, async: false

  alias ElixirKit.Bridge
  alias ElixirKit.Bridge.Protocol

  setup do
    start_supervised!({Bridge, name: :bridge_server, listen: "tcp://127.0.0.1:0"})

    url = Bridge.url(:bridge_server)
    start_supervised!({Bridge, name: :bridge_client, connect: url})

    Protocol.subscribe(:bridge_server)

    :ok
  end

  test "returns a normalized capability map from the broker response" do
    capabilities = %{
      "bridge" => %{
        backing: :core,
        permission: :not_applicable,
        actions: %{
          "capabilities" => :available,
          "echo" => :available
        }
      }
    }

    task = Task.async(fn -> Bridge.capabilities(:bridge_client) end)

    {request_id, "bridge.capabilities", ""} = receive_capabilities_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(
        request_id,
        Protocol.encode_call_result!({:ok, Protocol.encode_capabilities!(capabilities)})
      )
    )

    assert ^capabilities = Task.await(task, 1_000)
  end

  test "keeps permission separate from action availability in the public result" do
    capabilities = %{
      "clipboard" => %{
        backing: :tauri_plugin,
        permission: :prompt,
        actions: %{
          "read_text" => :unsupported_platform,
          "write_text" => :available
        }
      }
    }

    task = Task.async(fn -> Bridge.capabilities(:bridge_client) end)

    {request_id, "bridge.capabilities", ""} = receive_capabilities_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(
        request_id,
        Protocol.encode_call_result!({:ok, Protocol.encode_capabilities!(capabilities)})
      )
    )

    assert result = Task.await(task, 1_000)
    assert result["clipboard"].permission == :prompt
    assert result["clipboard"].actions["read_text"] == :unsupported_platform
    assert result["clipboard"].actions["write_text"] == :available
  end

  defp receive_capabilities_request do
    assert_receive message, 1_000

    assert {:ok, %Protocol.Request{request_id: request_id, body: body}} = Protocol.decode(message)
    assert {:ok, {operation, payload}} = Protocol.decode_call_body(body)

    {request_id, operation, payload}
  end
end
