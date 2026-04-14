defmodule Example.TestSupport.ShowcaseHost do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias ElixirKit.Bridge
  alias ElixirKit.Bridge.Protocol

  def setup_host_bridge do
    previous_bridge_server = Application.get_env(:example, :elixirkit_bridge_server)

    on_exit(fn ->
      if previous_bridge_server do
        Application.put_env(:example, :elixirkit_bridge_server, previous_bridge_server)
      else
        Application.delete_env(:example, :elixirkit_bridge_server)
      end
    end)

    start_supervised!({Bridge, name: :showcase_host, listen: "tcp://127.0.0.1:0"})

    url = Bridge.url(:showcase_host)
    start_supervised!({Bridge, name: :showcase_client, connect: url})
    Application.put_env(:example, :elixirkit_bridge_server, :showcase_client)

    parent = self()

    start_supervised!(
      {Task,
       fn ->
         Bridge.subscribe(:showcase_host, "messages")
         Protocol.subscribe(:showcase_host)
         send(parent, :showcase_host_ready)

         host_loop(%{
           owner: parent,
           clipboard: "copied from host",
           windows: [%{label: "window-1", title: "Example"}]
         })
       end}
    )

    assert_receive :showcase_host_ready

    {:ok, bridge_server: :showcase_client}
  end

  defp host_loop(state) do
    receive do
      message when is_binary(message) ->
        case Protocol.decode(message) do
          {:ok, %Protocol.Request{request_id: request_id, body: body}} ->
            assert {:ok, {operation, payload}} = Protocol.decode_call_body(body)

            {result, next_state} = respond_to_request(operation, payload, state)

            Protocol.broadcast(
              :showcase_host,
              Protocol.response(request_id, Protocol.encode_call_result!(result))
            )

            host_loop(next_state)

          {:error, _reason} ->
            host_loop(handle_raw_message(message, state))
        end
    end
  end

  defp handle_raw_message("count:" <> _rest = message, state) do
    send(state.owner, {:raw_count_seen, message})
    Bridge.broadcast(:showcase_host, "messages", "host:observed #{message}")
    state
  end

  defp handle_raw_message(_message, state), do: state

  defp respond_to_request("bridge.echo", payload, state) do
    {{:ok, payload}, state}
  end

  defp respond_to_request("bridge.capabilities", _payload, state) do
    {{:ok, Protocol.encode_capabilities!(capabilities_payload())}, state}
  end

  defp respond_to_request("clipboard.read_text", payload, state) do
    assert {:ok, %{}} = Protocol.decode_json_body(payload)
    send(state.owner, {:clipboard_read, state.clipboard})
    {{:ok, Protocol.encode_json_body!(%{"text" => state.clipboard})}, state}
  end

  defp respond_to_request("clipboard.write_text", payload, state) do
    assert {:ok, %{"text" => text}} = Protocol.decode_json_body(payload)
    send(state.owner, {:clipboard_written, text})
    {{:ok, Protocol.encode_json_body!(%{})}, %{state | clipboard: text}}
  end

  defp respond_to_request("window.list", payload, state) do
    assert {:ok, %{}} = Protocol.decode_json_body(payload)

    windows =
      Enum.map(state.windows, fn %{label: label, title: title} ->
        %{"label" => label, "title" => title}
      end)

    {{:ok, Protocol.encode_json_body!(%{"windows" => windows})}, state}
  end

  defp respond_to_request("window.set_title", payload, state) do
    assert {:ok, %{"label" => label, "title" => title}} = Protocol.decode_json_body(payload)
    send(state.owner, {:window_title_set, label, title})

    next_windows =
      Enum.map(state.windows, fn window ->
        if window.label == label do
          %{window | title: title}
        else
          window
        end
      end)

    {{:ok, Protocol.encode_json_body!(%{})}, %{state | windows: next_windows}}
  end

  defp respond_to_request("opener.open", payload, state) do
    assert {:ok, %{"target" => "https://example.com"}} = Protocol.decode_json_body(payload)
    send(state.owner, {:opener_opened, "https://example.com"})
    {{:ok, Protocol.encode_json_body!(%{})}, state}
  end

  defp respond_to_request(operation, _payload, state) do
    {{:error, "unsupported operation: #{operation}"}, state}
  end

  defp capabilities_payload do
    %{
      "bridge" => %{
        backing: :core,
        permission: :not_applicable,
        actions: %{
          "capabilities" => :available,
          "echo" => :available
        }
      },
      "clipboard" => %{
        backing: :tauri_plugin,
        permission: :not_applicable,
        actions: %{
          "read_text" => :available,
          "write_text" => :available
        }
      },
      "opener" => %{
        backing: :tauri_plugin,
        permission: :not_applicable,
        actions: %{
          "open" => :available
        }
      },
      "window" => %{
        backing: :tauri_core,
        permission: :not_applicable,
        actions: %{
          "list" => :available,
          "set_title" => :available
        }
      }
    }
  end
end
