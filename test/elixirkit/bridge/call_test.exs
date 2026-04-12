defmodule ElixirKit.Bridge.CallTest do
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

  test "matches a successful response to the pending request" do
    task = Task.async(fn -> Bridge.call(:bridge_client, "bridge.echo", "ping", 1_000) end)

    {request_id, "bridge.echo", "ping"} = receive_call_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(request_id, Protocol.encode_call_result!({:ok, "ping"}))
    )

    assert {:ok, "ping"} = Task.await(task, 1_000)
  end

  test "returns timeout when no matching response arrives" do
    task = Task.async(fn -> Bridge.call(:bridge_client, "bridge.echo", "ping", 50) end)

    {_, "bridge.echo", "ping"} = receive_call_request()

    assert {:error, :timeout} = Task.await(task, 1_000)
  end

  test "matches concurrent responses by request id even when they arrive out of order" do
    task1 = Task.async(fn -> Bridge.call(:bridge_client, "bridge.echo", "one", 1_000) end)
    task2 = Task.async(fn -> Bridge.call(:bridge_client, "bridge.echo", "two", 1_000) end)

    {request_id1, "bridge.echo", payload1} = receive_call_request()
    {request_id2, "bridge.echo", payload2} = receive_call_request()

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(request_id2, Protocol.encode_call_result!({:ok, payload2}))
    )

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(request_id1, Protocol.encode_call_result!({:ok, payload1}))
    )

    assert {:ok, "one"} = Task.await(task1, 1_000)
    assert {:ok, "two"} = Task.await(task2, 1_000)
  end

  test "reuses one shared router process across calls" do
    assert is_nil(ElixirKit.Bridge.Router.whereis(:bridge_client))

    task1 = Task.async(fn -> Bridge.call(:bridge_client, "bridge.echo", "one", 1_000) end)
    {request_id1, "bridge.echo", "one"} = receive_call_request()

    router = ElixirKit.Bridge.Router.whereis(:bridge_client)
    assert is_pid(router)

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(request_id1, Protocol.encode_call_result!({:ok, "one"}))
    )

    assert {:ok, "one"} = Task.await(task1, 1_000)

    task2 = Task.async(fn -> Bridge.call(:bridge_client, "bridge.echo", "two", 1_000) end)
    {request_id2, "bridge.echo", "two"} = receive_call_request()

    assert router == ElixirKit.Bridge.Router.whereis(:bridge_client)

    Protocol.broadcast(
      :bridge_server,
      Protocol.response(request_id2, Protocol.encode_call_result!({:ok, "two"}))
    )

    assert {:ok, "two"} = Task.await(task2, 1_000)
  end

  test "events do not fulfill pending requests" do
    task = Task.async(fn -> Bridge.call(:bridge_client, "bridge.echo", "ping", 50) end)

    {_, "bridge.echo", "ping"} = receive_call_request()

    Protocol.broadcast(:bridge_server, Protocol.event("still waiting"))

    assert {:error, :timeout} = Task.await(task, 1_000)
  end

  defp receive_call_request do
    assert_receive message, 1_000

    assert {:ok, %Protocol.Request{request_id: request_id, body: body}} = Protocol.decode(message)
    assert {:ok, {operation, payload}} = Protocol.decode_call_body(body)

    {request_id, operation, payload}
  end
end
