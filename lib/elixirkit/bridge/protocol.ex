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
  @capability_backing_core 0
  @capability_backing_tauri_plugin 1
  @capability_backing_tauri_core 2
  @permission_not_applicable 0
  @permission_granted 1
  @permission_denied 2
  @permission_prompt 3
  @availability_available 0
  @availability_unavailable 1
  @availability_unsupported 2
  @availability_unsupported_platform 3

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
  @type backing_kind() :: :core | :tauri_plugin | :tauri_core
  @type permission_state() :: :not_applicable | :granted | :denied | :prompt
  @type action_availability() ::
          :available | :unavailable | :unsupported | :unsupported_platform

  @type capability_descriptor() :: %{
          required(:backing) => backing_kind(),
          required(:permission) => permission_state(),
          required(:actions) => %{required(binary()) => action_availability()}
        }

  @type capabilities_map() :: %{required(binary()) => capability_descriptor()}

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

  @doc false
  @spec encode_json_body(term()) :: {:ok, binary()} | {:error, term()}
  def encode_json_body(term) do
    Jason.encode(term)
  end

  @doc false
  @spec encode_json_body!(term()) :: binary()
  def encode_json_body!(term) do
    case encode_json_body(term) do
      {:ok, body} -> body
      {:error, reason} -> raise ArgumentError, "invalid JSON body: #{inspect(reason)}"
    end
  end

  @doc false
  @spec decode_json_body(binary()) :: {:ok, term()} | {:error, term()}
  def decode_json_body(body) when is_binary(body) do
    Jason.decode(body)
  end

  @doc false
  @spec decode_json_body!(binary()) :: term()
  def decode_json_body!(body) do
    case decode_json_body(body) do
      {:ok, decoded} -> decoded
      {:error, reason} -> raise ArgumentError, "invalid JSON body: #{inspect(reason)}"
    end
  end

  @doc false
  @spec encode_capabilities(capabilities_map()) :: {:ok, binary()} | {:error, term()}
  def encode_capabilities(capabilities) when is_map(capabilities) do
    with :ok <- validate_namespace_count(map_size(capabilities)),
         {:ok, iodata} <-
           Enum.reduce_while(
             Enum.sort_by(capabilities, fn {namespace, _descriptor} -> namespace end),
             {:ok, [<<map_size(capabilities)::16>>]},
             fn {namespace, descriptor}, {:ok, acc} ->
               case encode_capability_namespace(namespace, descriptor) do
                 {:ok, chunk} -> {:cont, {:ok, [acc, chunk]}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end
           ) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  def encode_capabilities(_capabilities), do: {:error, :invalid_capabilities}

  @doc false
  @spec encode_capabilities!(capabilities_map()) :: binary()
  def encode_capabilities!(capabilities) do
    case encode_capabilities(capabilities) do
      {:ok, body} -> body
      {:error, reason} -> raise ArgumentError, "invalid capabilities body: #{inspect(reason)}"
    end
  end

  @doc false
  @spec decode_capabilities(binary()) :: {:ok, capabilities_map()} | {:error, term()}
  def decode_capabilities(<<namespace_count::16, rest::binary>>) do
    decode_capability_namespaces(rest, namespace_count, %{})
  end

  def decode_capabilities(_body), do: {:error, :truncated_capabilities}

  @doc false
  @spec decode_capabilities!(binary()) :: capabilities_map()
  def decode_capabilities!(body) do
    case decode_capabilities(body) do
      {:ok, capabilities} -> capabilities
      {:error, reason} -> raise ArgumentError, "invalid capabilities body: #{inspect(reason)}"
    end
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

  defp validate_non_empty_namespace(<<>>), do: {:error, :missing_namespace}
  defp validate_non_empty_namespace(_namespace), do: :ok

  defp validate_non_empty_action(<<>>), do: {:error, :missing_action}
  defp validate_non_empty_action(_action), do: :ok

  defp validate_operation_length(operation) when byte_size(operation) <= 255, do: :ok
  defp validate_operation_length(_operation), do: {:error, :operation_too_large}

  defp validate_name_length(name) when byte_size(name) <= 255, do: :ok
  defp validate_name_length(_name), do: {:error, :name_too_large}

  defp validate_request_id_length(request_id) when byte_size(request_id) <= 65_535, do: :ok
  defp validate_request_id_length(_request_id), do: {:error, :request_id_too_large}

  defp validate_namespace_count(count) when count <= 65_535, do: :ok
  defp validate_namespace_count(_count), do: {:error, :too_many_namespaces}

  defp validate_action_count(count) when count <= 65_535, do: :ok
  defp validate_action_count(_count), do: {:error, :too_many_actions}

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

  defp encode_capability_namespace(
         namespace,
         %{backing: backing, permission: permission, actions: actions}
       )
       when is_binary(namespace) and is_map(actions) do
    with :ok <- validate_non_empty_namespace(namespace),
         :ok <- validate_name_length(namespace),
         :ok <- validate_action_count(map_size(actions)),
         {:ok, actions_iodata} <- encode_capability_actions(actions),
         {:ok, backing} <- encode_backing(backing),
         {:ok, permission} <- encode_permission(permission) do
      {:ok,
       [
         <<byte_size(namespace)>>,
         namespace,
         <<backing, permission, map_size(actions)::16>>,
         actions_iodata
       ]}
    end
  end

  defp encode_capability_namespace(_namespace, _descriptor) do
    {:error, :invalid_capability_descriptor}
  end

  defp encode_capability_actions(actions) do
    Enum.reduce_while(
      Enum.sort_by(actions, fn {action, _availability} -> action end),
      {:ok, []},
      fn {action, availability}, {:ok, acc} ->
        case encode_capability_action(action, availability) do
          {:ok, chunk} -> {:cont, {:ok, [acc, chunk]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  defp encode_capability_action(action, availability) when is_binary(action) do
    with :ok <- validate_non_empty_action(action),
         :ok <- validate_name_length(action),
         {:ok, availability} <- encode_availability(availability) do
      {:ok, [<<byte_size(action)>>, action, <<availability>>]}
    end
  end

  defp encode_capability_action(_action, _availability), do: {:error, :invalid_capability_action}

  defp decode_capability_namespaces(<<>>, 0, capabilities), do: {:ok, capabilities}

  defp decode_capability_namespaces(_rest, 0, _capabilities),
    do: {:error, :invalid_capability_lengths}

  defp decode_capability_namespaces(rest, count, capabilities) do
    with {:ok, namespace, rest} <- take_name(rest, :missing_namespace),
         {:ok, backing, rest} <- take_backing(rest),
         {:ok, permission, rest} <- take_permission(rest),
         {:ok, action_count, rest} <- take_u16(rest),
         {:ok, actions, rest} <- decode_capability_actions(rest, action_count, %{}) do
      decode_capability_namespaces(
        rest,
        count - 1,
        Map.put(capabilities, namespace, %{
          backing: backing,
          permission: permission,
          actions: actions
        })
      )
    end
  end

  defp decode_capability_actions(rest, 0, actions), do: {:ok, actions, rest}

  defp decode_capability_actions(rest, count, actions) do
    with {:ok, action, rest} <- take_name(rest, :missing_action),
         {:ok, availability, rest} <- take_availability(rest) do
      decode_capability_actions(rest, count - 1, Map.put(actions, action, availability))
    end
  end

  defp take_name(<<length, rest::binary>>, _empty_error)
       when byte_size(rest) >= length and length > 0 do
    <<name::binary-size(length), rest::binary>> = rest
    {:ok, name, rest}
  end

  defp take_name(<<0, _rest::binary>>, empty_error), do: {:error, empty_error}
  defp take_name(_rest, _empty_error), do: {:error, :truncated_capabilities}

  defp take_backing(<<backing, rest::binary>>) do
    with {:ok, backing} <- decode_backing(backing) do
      {:ok, backing, rest}
    end
  end

  defp take_backing(_rest), do: {:error, :truncated_capabilities}

  defp take_permission(<<permission, rest::binary>>) do
    with {:ok, permission} <- decode_permission(permission) do
      {:ok, permission, rest}
    end
  end

  defp take_permission(_rest), do: {:error, :truncated_capabilities}

  defp take_availability(<<availability, rest::binary>>) do
    with {:ok, availability} <- decode_availability(availability) do
      {:ok, availability, rest}
    end
  end

  defp take_availability(_rest), do: {:error, :truncated_capabilities}

  defp take_u16(<<value::16, rest::binary>>), do: {:ok, value, rest}
  defp take_u16(_rest), do: {:error, :truncated_capabilities}

  defp encode_backing(:core), do: {:ok, @capability_backing_core}
  defp encode_backing(:tauri_plugin), do: {:ok, @capability_backing_tauri_plugin}
  defp encode_backing(:tauri_core), do: {:ok, @capability_backing_tauri_core}
  defp encode_backing(backing), do: {:error, {:invalid_capability_backing, backing}}

  defp decode_backing(@capability_backing_core), do: {:ok, :core}
  defp decode_backing(@capability_backing_tauri_plugin), do: {:ok, :tauri_plugin}
  defp decode_backing(@capability_backing_tauri_core), do: {:ok, :tauri_core}
  defp decode_backing(backing), do: {:error, {:invalid_capability_backing, backing}}

  defp encode_permission(:not_applicable), do: {:ok, @permission_not_applicable}
  defp encode_permission(:granted), do: {:ok, @permission_granted}
  defp encode_permission(:denied), do: {:ok, @permission_denied}
  defp encode_permission(:prompt), do: {:ok, @permission_prompt}
  defp encode_permission(permission), do: {:error, {:invalid_permission_state, permission}}

  defp decode_permission(@permission_not_applicable), do: {:ok, :not_applicable}
  defp decode_permission(@permission_granted), do: {:ok, :granted}
  defp decode_permission(@permission_denied), do: {:ok, :denied}
  defp decode_permission(@permission_prompt), do: {:ok, :prompt}
  defp decode_permission(permission), do: {:error, {:invalid_permission_state, permission}}

  defp encode_availability(:available), do: {:ok, @availability_available}
  defp encode_availability(:unavailable), do: {:ok, @availability_unavailable}
  defp encode_availability(:unsupported), do: {:ok, @availability_unsupported}
  defp encode_availability(:unsupported_platform), do: {:ok, @availability_unsupported_platform}

  defp encode_availability(availability),
    do: {:error, {:invalid_action_availability, availability}}

  defp decode_availability(@availability_available), do: {:ok, :available}
  defp decode_availability(@availability_unavailable), do: {:ok, :unavailable}
  defp decode_availability(@availability_unsupported), do: {:ok, :unsupported}
  defp decode_availability(@availability_unsupported_platform), do: {:ok, :unsupported_platform}

  defp decode_availability(availability),
    do: {:error, {:invalid_action_availability, availability}}
end
