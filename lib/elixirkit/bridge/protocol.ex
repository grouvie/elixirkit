defmodule ElixirKit.Bridge.Protocol do
  @moduledoc """
  Internal structured envelope layer for the current ElixirKit bridge.

  These envelopes ride over the same TCP `ElixirKit.PubSub` transport used
  today, on one reserved internal bridge topic. This is an additive protocol
  seam for later bridge-core work, not a transport replacement and not a public
  capability API yet.

  `request_id` and `body` are opaque binaries for now.
  """

  alias __MODULE__.{Event, Request, Response}

  @bridge_topic "__elixirkit_bridge__"
  @magic "EKBP"
  @version 1
  @request_kind 1
  @response_kind 2
  @event_kind 3
  @call_result_ok 0
  @call_result_error 1

  defmodule Request do
    @moduledoc false

    @enforce_keys [:request_id, :body]
    defstruct [:request_id, :body, version: 1, kind: :request]

    @type t :: %__MODULE__{
            version: pos_integer(),
            kind: :request,
            request_id: binary(),
            body: binary()
          }
  end

  defmodule Response do
    @moduledoc false

    @enforce_keys [:request_id, :body]
    defstruct [:request_id, :body, version: 1, kind: :response]

    @type t :: %__MODULE__{
            version: pos_integer(),
            kind: :response,
            request_id: binary(),
            body: binary()
          }
  end

  defmodule Event do
    @moduledoc false

    @enforce_keys [:body]
    defstruct [:body, version: 1, kind: :event]

    @type t :: %__MODULE__{
            version: pos_integer(),
            kind: :event,
            body: binary()
          }
  end

  @type envelope() :: Request.t() | Response.t() | Event.t()

  @doc """
  Returns the current bridge envelope protocol version.
  """
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Returns the reserved internal bridge topic for structured envelopes.
  """
  @spec topic() :: String.t()
  def topic, do: @bridge_topic

  @doc """
  Builds a request envelope with opaque `request_id` and `body` bytes.
  """
  @spec request(binary(), binary()) :: Request.t()
  def request(request_id, body) when is_binary(request_id) and is_binary(body) do
    %Request{request_id: request_id, body: body}
  end

  @doc """
  Builds a response envelope with opaque `request_id` and `body` bytes.
  """
  @spec response(binary(), binary()) :: Response.t()
  def response(request_id, body) when is_binary(request_id) and is_binary(body) do
    %Response{request_id: request_id, body: body}
  end

  @doc """
  Builds an event envelope with opaque `body` bytes.
  """
  @spec event(binary()) :: Event.t()
  def event(body) when is_binary(body) do
    %Event{body: body}
  end

  @doc """
  Encodes a structured bridge envelope into bytes.
  """
  @spec encode(envelope()) :: {:ok, binary()} | {:error, term()}
  def encode(%Request{} = request) do
    encode_with_request_id(request.version, @request_kind, request.request_id, request.body)
  end

  def encode(%Response{} = response) do
    encode_with_request_id(
      response.version,
      @response_kind,
      response.request_id,
      response.body
    )
  end

  def encode(%Event{} = event) do
    with :ok <- validate_version(event.version),
         :ok <- validate_body_length(event.body) do
      {:ok,
       <<@magic::binary, event.version, @event_kind, 0::16, byte_size(event.body)::32,
         event.body::binary>>}
    end
  end

  def encode(_envelope), do: {:error, :invalid_envelope}

  @doc """
  Encodes a structured bridge envelope into bytes and raises on errors.
  """
  @spec encode!(envelope()) :: binary()
  def encode!(envelope) do
    case encode(envelope) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise ArgumentError, "invalid bridge envelope: #{inspect(reason)}"
    end
  end

  @doc """
  Decodes bytes into a structured bridge envelope.
  """
  @spec decode(binary()) :: {:ok, envelope()} | {:error, term()}
  def decode(<<@magic::binary, version, kind, request_id_len::16, body_len::32, rest::binary>>) do
    with :ok <- validate_version(version),
         {:ok, kind_atom} <- decode_kind(kind),
         :ok <- validate_rest_size(rest, request_id_len, body_len) do
      <<request_id::binary-size(request_id_len), body::binary-size(body_len)>> = rest
      build_envelope(version, kind_atom, request_id, body)
    end
  end

  def decode(<<@magic::binary, _rest::binary>>) do
    {:error, :truncated_envelope}
  end

  def decode(_bytes) do
    {:error, :invalid_magic}
  end

  @doc """
  Decodes bytes into a structured bridge envelope and raises on errors.
  """
  @spec decode!(binary()) :: envelope()
  def decode!(bytes) do
    case decode(bytes) do
      {:ok, envelope} -> envelope
      {:error, reason} -> raise ArgumentError, "invalid bridge envelope bytes: #{inspect(reason)}"
    end
  end

  @doc false
  @spec subscribe() :: :ok
  def subscribe do
    ElixirKit.Bridge.subscribe(topic())
  end

  @doc false
  @spec subscribe(atom()) :: :ok
  def subscribe(server) when is_atom(server) do
    ElixirKit.Bridge.subscribe(server, topic())
  end

  @doc false
  @spec broadcast(envelope()) :: :ok
  def broadcast(envelope) do
    broadcast(ElixirKit.Bridge, envelope)
  end

  @doc false
  @spec broadcast(atom(), envelope()) :: :ok
  def broadcast(server, envelope) when is_atom(server) do
    ElixirKit.Bridge.broadcast(server, topic(), encode!(envelope))
  end

  @doc false
  @spec encode_call_body(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def encode_call_body(operation, payload)
      when is_binary(operation) and is_binary(payload) do
    with :ok <- validate_non_empty_operation(operation),
         :ok <- validate_operation_length(operation) do
      {:ok, <<byte_size(operation), operation::binary, payload::binary>>}
    end
  end

  @doc false
  @spec encode_call_body!(binary(), binary()) :: binary()
  def encode_call_body!(operation, payload) do
    case encode_call_body(operation, payload) do
      {:ok, body} -> body
      {:error, reason} -> raise ArgumentError, "invalid bridge call body: #{inspect(reason)}"
    end
  end

  @doc false
  @spec decode_call_body(binary()) :: {:ok, {binary(), binary()}} | {:error, term()}
  def decode_call_body(<<operation_len, rest::binary>>) when byte_size(rest) >= operation_len do
    <<operation::binary-size(operation_len), payload::binary>> = rest

    with :ok <- validate_non_empty_operation(operation) do
      {:ok, {operation, payload}}
    end
  end

  def decode_call_body(<<>>), do: {:error, :missing_operation}
  def decode_call_body(_body), do: {:error, :truncated_operation}

  @doc false
  @spec encode_call_result({:ok, binary()} | {:error, binary()}) ::
          {:ok, binary()} | {:error, term()}
  def encode_call_result({:ok, body}) when is_binary(body) do
    {:ok, <<@call_result_ok, body::binary>>}
  end

  def encode_call_result({:error, reason}) when is_binary(reason) do
    {:ok, <<@call_result_error, reason::binary>>}
  end

  def encode_call_result(_result), do: {:error, :invalid_call_result}

  @doc false
  @spec encode_call_result!({:ok, binary()} | {:error, binary()}) :: binary()
  def encode_call_result!(result) do
    case encode_call_result(result) do
      {:ok, body} -> body
      {:error, reason} -> raise ArgumentError, "invalid bridge call result: #{inspect(reason)}"
    end
  end

  @doc false
  @spec decode_call_result(binary()) ::
          {:ok, {:ok, binary()} | {:error, binary()}} | {:error, term()}
  def decode_call_result(<<@call_result_ok, body::binary>>) do
    {:ok, {:ok, body}}
  end

  def decode_call_result(<<@call_result_error, reason::binary>>) do
    {:ok, {:error, reason}}
  end

  def decode_call_result(<<status, _payload::binary>>) do
    {:error, {:invalid_result_status, status}}
  end

  def decode_call_result(<<>>) do
    {:error, :missing_result_status}
  end

  defp encode_with_request_id(version, kind, request_id, body)
       when is_binary(request_id) and is_binary(body) do
    with :ok <- validate_version(version),
         :ok <- validate_non_empty_request_id(request_id),
         :ok <- validate_request_id_length(request_id),
         :ok <- validate_body_length(body) do
      {:ok,
       <<@magic::binary, version, kind, byte_size(request_id)::16, byte_size(body)::32,
         request_id::binary, body::binary>>}
    end
  end

  defp build_envelope(version, :request, request_id, body) do
    with :ok <- validate_non_empty_request_id(request_id) do
      {:ok, %Request{version: version, request_id: request_id, body: body}}
    end
  end

  defp build_envelope(version, :response, request_id, body) do
    with :ok <- validate_non_empty_request_id(request_id) do
      {:ok, %Response{version: version, request_id: request_id, body: body}}
    end
  end

  defp build_envelope(version, :event, <<>>, body) do
    {:ok, %Event{version: version, body: body}}
  end

  defp build_envelope(_version, :event, _request_id, _body) do
    {:error, :event_request_id_not_allowed}
  end

  defp validate_version(@version), do: :ok
  defp validate_version(version), do: {:error, {:unsupported_version, version}}

  defp validate_non_empty_request_id(<<>>), do: {:error, :missing_request_id}
  defp validate_non_empty_request_id(_request_id), do: :ok

  defp validate_non_empty_operation(<<>>), do: {:error, :missing_operation}
  defp validate_non_empty_operation(_operation), do: :ok

  defp validate_operation_length(operation) when byte_size(operation) <= 255, do: :ok
  defp validate_operation_length(_operation), do: {:error, :operation_too_large}

  defp validate_request_id_length(request_id) when byte_size(request_id) <= 65_535, do: :ok
  defp validate_request_id_length(_request_id), do: {:error, :request_id_too_large}

  defp validate_body_length(body) when byte_size(body) <= 4_294_967_295, do: :ok
  defp validate_body_length(_body), do: {:error, :body_too_large}

  defp validate_rest_size(rest, request_id_len, body_len)
       when byte_size(rest) == request_id_len + body_len do
    :ok
  end

  defp validate_rest_size(rest, request_id_len, body_len)
       when byte_size(rest) < request_id_len + body_len do
    {:error, :truncated_envelope}
  end

  defp validate_rest_size(_rest, _request_id_len, _body_len) do
    {:error, :invalid_lengths}
  end

  defp decode_kind(@request_kind), do: {:ok, :request}
  defp decode_kind(@response_kind), do: {:ok, :response}
  defp decode_kind(@event_kind), do: {:ok, :event}
  defp decode_kind(kind), do: {:error, {:invalid_kind, kind}}
end
