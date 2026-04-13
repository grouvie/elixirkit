defmodule ElixirKit.WindowTest do
  use ExUnit.Case, async: false

  alias ElixirKit.Bridge
  alias ElixirKit.Bridge.Protocol
  alias ElixirKit.Window

  setup do
    start_supervised!({Bridge, name: :bridge_server, listen: "tcp://127.0.0.1:0"})

    url = Bridge.url(:bridge_server)
    start_supervised!({Bridge, name: :bridge_client, connect: url})

    Protocol.subscribe(:bridge_server)

    :ok
  end

  test "list/1 returns normalized window information on success" do
    task = Task.async(fn -> Window.list(:bridge_client) end)

    {request_id, "window.list", %{}} = receive_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(
        request_id,
        Protocol.encode_call_result!(
          {:ok,
           Protocol.encode_json_body!(%{
             "windows" => [
               %{"label" => "main", "title" => "Example"},
               %{"label" => "secondary", "title" => "Inspector"}
             ]
           })}
        )
      )
    )

    assert {:ok,
            [
              %{label: "main", title: "Example"},
              %{label: "secondary", title: "Inspector"}
            ]} = Task.await(task, 1_000)
  end

  test "set_title/3 returns the broker error when the host reports failure" do
    task = Task.async(fn -> Window.set_title(:bridge_client, "main", "Renamed") end)

    {request_id, "window.set_title", %{"label" => "main", "title" => "Renamed"}} =
      receive_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(request_id, Protocol.encode_call_result!({:error, "window not found"}))
    )

    assert {:error, "window not found"} = Task.await(task, 1_000)
  end

  defp receive_request do
    assert_receive message, 1_000

    assert {:ok, %Protocol.Request{request_id: request_id, body: body}} = Protocol.decode(message)
    assert {:ok, {operation, payload}} = Protocol.decode_call_body(body)
    assert {:ok, decoded} = Protocol.decode_json_body(payload)

    {request_id, operation, decoded}
  end
end
