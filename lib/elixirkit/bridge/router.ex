defmodule ElixirKit.Bridge.Router do
  @moduledoc false

  use GenServer

  alias ElixirKit.Bridge.Protocol

  @type pending_entry() :: %{
          caller: pid(),
          reply_ref: reference(),
          monitor_ref: reference()
        }

  @spec register(atom(), binary(), pid(), reference()) :: :ok | {:error, term()}
  def register(server, request_id, caller, reply_ref)
      when is_atom(server) and is_binary(request_id) and is_pid(caller) and
             is_reference(reply_ref) do
    with {:ok, router} <- ensure_started(server) do
      safe_call(router, {:register, request_id, caller, reply_ref})
    end
  end

  @spec cancel(atom(), binary(), reference()) :: :ok
  def cancel(server, request_id, reply_ref)
      when is_atom(server) and is_binary(request_id) and is_reference(reply_ref) do
    case whereis(server) do
      nil ->
        :ok

      router ->
        GenServer.cast(router, {:cancel, request_id, reply_ref})
    end
  end

  @spec whereis(atom()) :: pid() | nil
  def whereis(server) when is_atom(server) do
    Process.whereis(name(server))
  end

  @impl true
  def init(server) do
    case Process.whereis(server) do
      nil ->
        {:stop, :bridge_not_started}

      bridge_pid ->
        Protocol.subscribe(server)

        {:ok,
         %{
           bridge_ref: Process.monitor(bridge_pid),
           pending: %{},
           monitors: %{}
         }}
    end
  end

  @impl true
  def handle_call({:register, request_id, caller, reply_ref}, _from, state) do
    monitor_ref = Process.monitor(caller)

    pending =
      Map.put(state.pending, request_id, %{
        caller: caller,
        reply_ref: reply_ref,
        monitor_ref: monitor_ref
      })

    {:reply, :ok,
     %{state | pending: pending, monitors: Map.put(state.monitors, monitor_ref, request_id)}}
  end

  @impl true
  def handle_cast({:cancel, request_id, reply_ref}, state) do
    {:noreply, drop_pending_request(state, request_id, reply_ref)}
  end

  @impl true
  def handle_info({:DOWN, bridge_ref, :process, _pid, _reason}, %{bridge_ref: bridge_ref} = state) do
    Enum.each(state.pending, fn {_request_id, %{caller: caller, reply_ref: reply_ref}} ->
      send(caller, {reply_ref, {:error, :bridge_closed}})
    end)

    {:stop, :normal, %{state | pending: %{}, monitors: %{}}}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {request_id, monitors} ->
        pending =
          case Map.pop(state.pending, request_id) do
            {nil, pending} -> pending
            {_entry, pending} -> pending
          end

        {:noreply, %{state | pending: pending, monitors: monitors}}
    end
  end

  def handle_info(message, state) do
    case Protocol.decode(message) do
      {:ok, %Protocol.Response{request_id: request_id, body: body}} ->
        {:noreply, reply_to_pending_request(state, request_id, body)}

      {:ok, _envelope} ->
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  defp ensure_started(server) do
    case whereis(server) do
      nil ->
        case GenServer.start(__MODULE__, server, name: name(server)) do
          {:ok, router} -> {:ok, router}
          {:error, {:already_started, router}} -> {:ok, router}
          {:error, {:shutdown, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      router ->
        {:ok, router}
    end
  end

  defp safe_call(router, message) do
    GenServer.call(router, message)
  catch
    :exit, _reason -> {:error, :bridge_call_router_unavailable}
  end

  defp reply_to_pending_request(state, request_id, body) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        state

      {%{caller: caller, reply_ref: reply_ref, monitor_ref: monitor_ref}, pending} ->
        Process.demonitor(monitor_ref, [:flush])

        result =
          case Protocol.decode_call_result(body) do
            {:ok, result} -> result
            {:error, reason} -> {:error, {:invalid_response, reason}}
          end

        send(caller, {reply_ref, result})

        %{state | pending: pending, monitors: Map.delete(state.monitors, monitor_ref)}
    end
  end

  defp drop_pending_request(state, request_id, reply_ref) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        state

      {%{reply_ref: ^reply_ref, monitor_ref: monitor_ref}, pending} ->
        Process.demonitor(monitor_ref, [:flush])
        %{state | pending: pending, monitors: Map.delete(state.monitors, monitor_ref)}

      {entry, pending} ->
        %{state | pending: Map.put(pending, request_id, entry)}
    end
  end

  defp name(server) when is_atom(server) do
    :"#{server}.BridgeRouter"
  end
end
