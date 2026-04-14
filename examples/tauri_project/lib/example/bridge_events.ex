defmodule Example.BridgeEvents do
  @moduledoc """
  Example-local forwarder for raw bridge topic messages.

  This module keeps the event demo scoped to the Tauri example. It subscribes
  to the unchanged raw `messages` topic and forwards host-originated payloads
  into the LiveView process so the UI can show raw topic traffic without
  widening the public bridge API.
  """

  use GenServer

  alias ElixirKit.Bridge

  @topic "messages"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    bridge_server = Keyword.fetch!(opts, :bridge_server)

    Bridge.subscribe(bridge_server, @topic)
    owner_ref = Process.monitor(owner)

    {:ok, %{owner: owner, owner_ref: owner_ref}}
  end

  @impl true
  def handle_info({:DOWN, owner_ref, :process, _pid, _reason}, %{owner_ref: owner_ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(payload, state) when is_binary(payload) do
    send(
      state.owner,
      {:bridge_event,
       %{
         id: System.unique_integer([:positive]),
         source: :host,
         topic: @topic,
         payload: payload,
         note: "Raw message from the host bridge."
       }}
    )

    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end
end
