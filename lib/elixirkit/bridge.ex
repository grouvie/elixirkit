defmodule ElixirKit.Bridge do
  @moduledoc """
  Thin Elixir-side entrypoint for the current ElixirKit bridge.

  Today this module delegates to `ElixirKit.PubSub`, so the public transport is
  still the existing local TCP `PubSub` connection. This is an incremental seam
  for Elixir application code, not a rewrite of transport or lifecycle.

  Structured bridge envelopes now layer over one reserved internal topic via
  `ElixirKit.Bridge.Protocol`, but raw topic/message PubSub usage remains fully
  backward compatible.

  Brokered request/response calls now reuse one shared internal router per
  bridge connection. That router, implemented internally as
  `ElixirKit.Bridge.Router`, subscribes to the reserved bridge topic once and
  matches responses by `request_id`, while ordinary PubSub traffic stays
  unchanged.

  No NIF-backed bridge, mobile runtime, or wrapper CLI is introduced here.
  `ElixirKit.PubSub` remains fully supported and backward compatible;
  `ElixirKit.Bridge` simply gives Elixir code a forward-compatible module to
  depend on while the transport stays the same.

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
  @type operation() :: String.t()
  @type call_result() :: {:ok, binary()} | {:error, term()}
  @type capabilities_map() :: ElixirKit.Bridge.Protocol.capabilities_map()
  @type capabilities_result() :: capabilities_map() | {:error, term()}

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

  @doc """
  Returns capability truth for the current bridge connection.

  This reports action-level availability and permission state separately. It is
  feature discovery, not authorization. It includes the small built-in
  bridge-core registry plus any host capability namespaces that were explicitly
  registered on the Rust side for this connection. Registration is still
  intentional and app-owned at this stage; this is not the later plugin
  rollout yet.
  """
  @spec capabilities() :: capabilities_result()
  def capabilities do
    capabilities(__MODULE__)
  end

  @doc false
  @spec capabilities(atom()) :: capabilities_result()
  def capabilities(server) when is_atom(server) do
    with {:ok, body} <- call(server, "bridge.capabilities", "", 5_000),
         {:ok, capabilities} <- ElixirKit.Bridge.Protocol.decode_capabilities(body) do
      capabilities
    end
  end

  @doc """
  Performs a brokered bridge call over the current structured bridge topic.

  This keeps using the same TCP `PubSub` transport underneath. For now the
  built-in Rust broker handles bridge-core operations such as `bridge.echo`
  and `bridge.capabilities`, and explicitly registered host handlers can serve
  additional operations such as `opener.open`. A shared internal router process
  per bridge server keeps track of pending requests and matches responses by
  `request_id`.
  """
  @spec call(operation(), binary()) :: call_result()
  def call(operation, body) do
    call(operation, body, 5_000)
  end

  @doc """
  Performs a brokered bridge call with the given timeout in milliseconds.
  """
  @spec call(operation(), binary(), non_neg_integer()) :: call_result()
  def call(operation, body, timeout) do
    call(__MODULE__, operation, body, timeout)
  end

  @doc false
  @spec call(atom(), operation(), binary(), non_neg_integer()) :: call_result()
  def call(server, operation, body, timeout)
      when is_atom(server) and is_binary(operation) and is_binary(body) and is_integer(timeout) and
             timeout >= 0 do
    request_id = new_request_id()
    reply_ref = make_ref()

    with {:ok, request_body} <- ElixirKit.Bridge.Protocol.encode_call_body(operation, body),
         :ok <- ElixirKit.Bridge.Router.register(server, request_id, self(), reply_ref) do
      ElixirKit.Bridge.Protocol.broadcast(
        server,
        ElixirKit.Bridge.Protocol.request(request_id, request_body)
      )

      await_call_reply(server, request_id, reply_ref, timeout)
    end
  end

  @doc false
  @spec url(atom()) :: String.t()
  def url(server) do
    ElixirKit.PubSub.url(server)
  end

  defp await_call_reply(server, request_id, reply_ref, timeout) do
    receive do
      {^reply_ref, {:ok, _body} = result} ->
        result

      {^reply_ref, {:error, _reason} = result} ->
        result
    after
      timeout ->
        ElixirKit.Bridge.Router.cancel(server, request_id, reply_ref)
        flush_call_reply(reply_ref)
        {:error, :timeout}
    end
  end

  defp flush_call_reply(reply_ref) do
    receive do
      {^reply_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp new_request_id do
    <<System.unique_integer([:monotonic, :positive])::unsigned-big-integer-size(64)>>
  end
end
