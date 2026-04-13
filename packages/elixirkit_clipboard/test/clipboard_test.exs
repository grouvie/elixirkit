defmodule ElixirKit.ClipboardTest do
  use ExUnit.Case, async: false

  alias ElixirKit.Bridge
  alias ElixirKit.Bridge.Protocol
  alias ElixirKit.Clipboard

  setup do
    start_supervised!({Bridge, name: :bridge_server, listen: "tcp://127.0.0.1:0"})

    url = Bridge.url(:bridge_server)
    start_supervised!({Bridge, name: :bridge_client, connect: url})

    Protocol.subscribe(:bridge_server)

    :ok
  end

  test "read_text/1 returns clipboard text on success" do
    task = Task.async(fn -> Clipboard.read_text(:bridge_client) end)

    {request_id, "clipboard.read_text", %{}} = receive_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(
        request_id,
        Protocol.encode_call_result!({:ok, Protocol.encode_json_body!(%{"text" => "copied"})})
      )
    )

    assert {:ok, "copied"} = Task.await(task, 1_000)
  end

  test "write_text/2 returns the broker error when the host reports failure" do
    task = Task.async(fn -> Clipboard.write_text(:bridge_client, "copied") end)

    {request_id, "clipboard.write_text", %{"text" => "copied"}} = receive_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(
        request_id,
        Protocol.encode_call_result!({:error, "clipboard unavailable"})
      )
    )

    assert {:error, "clipboard unavailable"} = Task.await(task, 1_000)
  end

  defp receive_request do
    assert_receive message, 1_000

    assert {:ok, %Protocol.Request{request_id: request_id, body: body}} = Protocol.decode(message)
    assert {:ok, {operation, payload}} = Protocol.decode_call_body(body)
    assert {:ok, decoded} = Protocol.decode_json_body(payload)

    {request_id, operation, decoded}
  end
end
