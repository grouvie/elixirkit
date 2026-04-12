defmodule ElixirKit.OpenerTest do
  use ExUnit.Case, async: false

  alias ElixirKit.Bridge
  alias ElixirKit.Bridge.Protocol
  alias ElixirKit.Opener

  setup do
    start_supervised!({Bridge, name: :bridge_server, listen: "tcp://127.0.0.1:0"})

    url = Bridge.url(:bridge_server)
    start_supervised!({Bridge, name: :bridge_client, connect: url})

    Protocol.subscribe(:bridge_server)

    :ok
  end

  test "open/1 returns :ok when the host reports success" do
    task = Task.async(fn -> Opener.open(:bridge_client, "https://example.com") end)

    {request_id, "opener.open", "https://example.com"} = receive_open_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(request_id, Protocol.encode_call_result!({:ok, ""}))
    )

    assert :ok = Task.await(task, 1_000)
  end

  test "open/1 returns the broker error when the host reports failure" do
    task = Task.async(fn -> Opener.open(:bridge_client, "https://example.com") end)

    {request_id, "opener.open", "https://example.com"} = receive_open_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(request_id, Protocol.encode_call_result!({:error, "open failed"}))
    )

    assert {:error, "open failed"} = Task.await(task, 1_000)
  end

  defp receive_open_request do
    assert_receive message, 1_000

    assert {:ok, %Protocol.Request{request_id: request_id, body: body}} = Protocol.decode(message)
    assert {:ok, {operation, payload}} = Protocol.decode_call_body(body)

    {request_id, operation, payload}
  end
end
