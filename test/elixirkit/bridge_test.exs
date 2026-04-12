defmodule ElixirKit.Bridge.Test do
  use ExUnit.Case, async: true

  test "delegates to PubSub transport with bridge default naming" do
    start_supervised!({ElixirKit.Bridge, listen: "tcp://127.0.0.1:0"})

    url = ElixirKit.Bridge.url(ElixirKit.Bridge)
    start_supervised!({ElixirKit.Bridge, name: :bridge_client, connect: url})

    ElixirKit.Bridge.subscribe("topic")
    ElixirKit.Bridge.subscribe(:bridge_client, "topic")

    ElixirKit.Bridge.broadcast("topic", "message1")
    ElixirKit.Bridge.broadcast(:bridge_client, "topic", "message2")

    assert_receive "message1"
    assert_receive "message2"
    refute_receive _
  end

  test "child_spec delegates to PubSub child_spec with bridge default naming" do
    options = [connect: :ignore, significant: true]

    assert ElixirKit.Bridge.child_spec(options) ==
             ElixirKit.PubSub.child_spec(
               name: ElixirKit.Bridge,
               connect: :ignore,
               significant: true
             )
  end
end
