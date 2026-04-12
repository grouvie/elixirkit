defmodule ElixirKit.Bridge do
  @moduledoc """
  Thin Elixir-side entrypoint for the current ElixirKit bridge.

  Today this module delegates to `ElixirKit.PubSub`, so the public transport is
  still the existing local TCP `PubSub` connection. This is an incremental seam
  for Elixir application code, not a rewrite of transport or lifecycle.

  Structured bridge envelopes now layer over one reserved internal topic via
  `ElixirKit.Bridge.Protocol`, but raw topic/message PubSub usage remains fully
  backward compatible.

  No NIF-backed bridge, mobile runtime, or capability/plugin architecture is
  introduced here yet. `ElixirKit.PubSub` remains fully supported and backward
  compatible; `ElixirKit.Bridge` simply gives Elixir code a forward-compatible
  module to depend on while the transport stays the same.

  ## Examples

      children = [
        {ElixirKit.Bridge,
         connect: System.get_env("ELIXIRKIT_PUBSUB") || :ignore,
         on_exit: &System.stop/0}
      ]

      {:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)

      ElixirKit.Bridge.subscribe("messages")
      ElixirKit.Bridge.broadcast("messages", "ready")
  """

  @type topic() :: ElixirKit.PubSub.topic()
  @type message() :: ElixirKit.PubSub.message()

  @doc """
  Starts the bridge and links it to the current process.

  This is a thin delegation layer over `ElixirKit.PubSub.start_link/1`. It
  preserves the current TCP `PubSub` transport and uses `ElixirKit.Bridge` as
  the default registered server name.

  Remaining options are the same as in `ElixirKit.PubSub.start_link/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    options
    |> Keyword.put_new(:name, __MODULE__)
    |> ElixirKit.PubSub.start_link()
  end

  @doc """
  Returns a specification to start the bridge under a supervisor.

  This delegates to `ElixirKit.PubSub.child_spec/1` while defaulting the
  registered server name to `ElixirKit.Bridge`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    options
    |> Keyword.put_new(:name, __MODULE__)
    |> ElixirKit.PubSub.child_spec()
  end

  @doc """
  Subscribes the caller to messages on the given topic from the Rust side.
  """
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) do
    subscribe(__MODULE__, topic)
  end

  @doc false
  @spec subscribe(atom(), topic()) :: :ok
  def subscribe(server, topic) do
    ElixirKit.PubSub.subscribe(server, topic)
  end

  @doc """
  Broadcasts a message on the given topic to the Rust side.
  """
  @spec broadcast(topic(), message()) :: :ok
  def broadcast(topic, message) do
    broadcast(__MODULE__, topic, message)
  end

  @doc false
  @spec broadcast(atom(), topic(), message()) :: :ok
  def broadcast(server, topic, message) do
    ElixirKit.PubSub.broadcast(server, topic, message)
  end

  @doc false
  @spec url(atom()) :: String.t()
  def url(server) do
    ElixirKit.PubSub.url(server)
  end
end
