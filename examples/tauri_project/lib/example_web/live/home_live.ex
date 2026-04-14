defmodule ExampleWeb.HomeLive do
  use ExampleWeb, :live_view

  alias Example.BridgeEvents
  alias ElixirKit.{Bridge, Clipboard, Opener, Window}

  @event_limit 12
  @default_clipboard_text "Text from the example app"
  @default_echo_payload "ping"
  @default_open_target ""
  @default_window_title "Example"

  @impl true
  def mount(_params, _session, socket) do
    bridge_server = bridge_server()

    socket =
      socket
      |> assign(
        bridge_server: bridge_server,
        count: 0,
        connection_status:
          status(
            :neutral,
            "Unavailable",
            "Start the example through Tauri to connect the host bridge."
          ),
        capabilities_status:
          status(
            :neutral,
            "Pending",
            "Capabilities load on mount."
          ),
        last_bridge_error: nil,
        capability_rows: [],
        echo_payload: @default_echo_payload,
        echo_response: nil,
        echo_status:
          status(
            :neutral,
            "Idle",
            "Send a payload to bridge.echo."
          ),
        clipboard_text: @default_clipboard_text,
        clipboard_last_read: nil,
        clipboard_status:
          status(
            :neutral,
            "Idle",
            "Read or write clipboard text."
          ),
        windows: [],
        window_label: "",
        window_title: @default_window_title,
        window_status:
          status(
            :neutral,
            "Idle",
            "List windows or set a title."
          ),
        open_target: @default_open_target,
        opener_status:
          status(
            :neutral,
            "Idle",
            "Open a URL with the host."
          ),
        event_log: []
      )
      |> sync_forms()
      |> maybe_start_bridge_events()
      |> refresh_capabilities()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <header class="border-b border-zinc-200 pb-4">
          <h1 class="text-xl font-semibold tracking-tight text-zinc-950">
            ElixirKit reference console
          </h1>
          <p class="mt-1 text-sm text-zinc-600">
            Bridge status, capabilities, calls, and raw events for the Tauri example.
          </p>
        </header>

        <.console_section id="bridge-section" title="Bridge status" divided={false}>
          <dl class="overflow-hidden rounded-md border border-zinc-200">
            <.detail_row label="Connection">
              <div>
                <p id="bridge-connection-status" class={status_text_classes(@connection_status.kind)}>
                  {@connection_status.title}
                </p>
                <p class="mt-1 text-sm text-zinc-600">{@connection_status.detail}</p>
              </div>
            </.detail_row>
            <.detail_row label="Capabilities">
              <div>
                <p
                  id="bridge-capabilities-status"
                  class={status_text_classes(@capabilities_status.kind)}
                >
                  {@capabilities_status.title}
                </p>
                <p class="mt-1 text-sm text-zinc-600">{@capabilities_status.detail}</p>
              </div>
            </.detail_row>
            <.detail_row label="Last bridge error">
              <div id="bridge-last-error" class="break-words font-mono text-sm text-zinc-800">
                {bridge_error_text(@last_bridge_error)}
              </div>
            </.detail_row>
          </dl>
        </.console_section>

        <.console_section
          id="capabilities-section"
          title="Capabilities"
          description="Inspect the current capability registry."
        >
          <:actions>
            <button
              id="capability-refresh"
              phx-click="refresh_capabilities"
              class={secondary_button_classes()}
            >
              Refresh capabilities
            </button>
          </:actions>
          <div :if={@capability_rows == []} id="capabilities-empty" class="text-sm text-zinc-600">
            No capabilities loaded.
          </div>

          <div :if={@capability_rows != []} class="overflow-x-auto">
            <table id="capabilities-table" class="min-w-full border border-zinc-200 text-sm">
              <thead class="bg-zinc-50 text-left text-zinc-700">
                <tr>
                  <th class="p-2 font-medium">Namespace</th>
                  <th class="p-2 font-medium">Backing</th>
                  <th class="p-2 font-medium">Permission</th>
                  <th class="p-2 font-medium">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @capability_rows} class="border-t border-zinc-200 align-top">
                  <td class="p-2 font-mono text-zinc-900">{row.name}</td>
                  <td class="p-2 text-zinc-800">{humanize_atom(row.backing)}</td>
                  <td class="p-2 text-zinc-800">{humanize_atom(row.permission)}</td>
                  <td class="p-2 text-zinc-800">{capability_actions_text(row.actions)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.console_section>

        <.console_section
          id="echo-section"
          title="Echo"
          description="Round-trip a payload through the bridge."
        >
          <p id="echo-status" class={status_text_classes(@echo_status.kind)}>{@echo_status.title}</p>
          <p class="text-sm text-zinc-600">{@echo_status.detail}</p>

          <.form for={@echo_form} id="echo-form" phx-submit="bridge_echo" class="space-y-3">
            <.input field={@echo_form[:payload]} type="text" label="Payload" class="w-full" />
            <button type="submit" class={primary_button_classes()}>Send bridge.echo</button>
          </.form>

          <.output_block id="echo-response" label="Last response">
            <span>
              {echo_response_text(@echo_response)}
            </span>
          </.output_block>
        </.console_section>

        <.console_section
          id="opener-section"
          title="Opener"
          description="Ask the host to open a URL."
        >
          <p id="opener-status" class={status_text_classes(@opener_status.kind)}>
            {@opener_status.title}
          </p>
          <p class="text-sm text-zinc-600">{@opener_status.detail}</p>

          <.form for={@opener_form} id="opener-form" phx-submit="open_target" class="space-y-3">
            <.input
              field={@opener_form[:target]}
              type="url"
              label="Target URL"
              placeholder="https://example.com"
              class="w-full"
            />

            <button type="submit" class={primary_button_classes()}>Open URL</button>
          </.form>
        </.console_section>

        <.console_section
          id="clipboard-section"
          title="Clipboard"
          description="Read and write clipboard text through the host."
        >
          <p id="clipboard-status" class={status_text_classes(@clipboard_status.kind)}>
            {@clipboard_status.title}
          </p>
          <p class="text-sm text-zinc-600">{@clipboard_status.detail}</p>

          <.form
            for={@clipboard_form}
            id="clipboard-form"
            phx-submit="write_clipboard"
            class="space-y-4"
          >
            <.input field={@clipboard_form[:text]} type="textarea" rows="4" label="Clipboard text" />

            <div class="flex flex-wrap gap-3">
              <button type="submit" class={primary_button_classes()}>Write clipboard</button>
              <button
                id="read-clipboard"
                type="button"
                phx-click="read_clipboard"
                class={secondary_button_classes()}
              >
                Read clipboard
              </button>
            </div>
          </.form>

          <.output_block
            id="clipboard-last-read"
            label="Last read value"
            class="whitespace-pre-wrap"
          >
            <span>
              {clipboard_last_read_text(@clipboard_last_read)}
            </span>
          </.output_block>
        </.console_section>

        <.console_section
          id="window-section"
          title="Window"
          description="Inspect host windows and set a title."
        >
          <:actions>
            <button id="window-list" phx-click="list_windows" class={secondary_button_classes()}>
              List windows
            </button>
          </:actions>
          <p id="window-status" class={status_text_classes(@window_status.kind)}>
            {@window_status.title}
          </p>
          <p class="text-sm text-zinc-600">{@window_status.detail}</p>

          <div :if={@windows == []} class="text-sm text-zinc-600">No windows loaded.</div>

          <div :if={@windows != []} class="overflow-x-auto">
            <table id="window-table" class="min-w-full border border-zinc-200 text-sm">
              <thead class="bg-zinc-50 text-left text-zinc-700">
                <tr>
                  <th class="p-2 font-medium">Label</th>
                  <th class="p-2 font-medium">Title</th>
                  <th class="p-2 font-medium">Action</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={window <- @windows} class="border-t border-zinc-200">
                  <td class="p-2 font-mono text-zinc-900">{window.label}</td>
                  <td class="p-2 text-zinc-800">{window.title}</td>
                  <td class="p-2">
                    <button
                      phx-click="choose_window"
                      phx-value-label={window.label}
                      phx-value-title={window.title}
                      class={secondary_button_classes()}
                    >
                      Use
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <.form for={@window_form} id="window-form" phx-submit="set_title" class="space-y-3">
            <.input field={@window_form[:label]} type="text" label="Window label" class="w-full" />
            <.input field={@window_form[:title]} type="text" label="New title" class="w-full" />
            <button type="submit" class={primary_button_classes()}>Set window title</button>
          </.form>
        </.console_section>

        <.console_section
          id="event-log-section"
          title="Event log"
          description={~s(Raw "messages" topic traffic.)}
        >
          <:actions>
            <div class="flex flex-wrap items-center gap-3">
              <p id="count-value" class="text-sm text-zinc-700">
                Count: <span class="font-mono text-zinc-900">{@count}</span>
              </p>
              <button id="counter-inc" phx-click="inc" class={primary_button_classes()}>
                Increment count
              </button>
            </div>
          </:actions>
          <div :if={@event_log == []} class="text-sm text-zinc-600">No events yet.</div>

          <div
            :if={@event_log != []}
            id="event-log"
            class="overflow-hidden rounded-md border border-zinc-200 bg-zinc-50"
          >
            <div
              :for={entry <- @event_log}
              id={"event-#{entry.id}"}
              class="border-t border-zinc-200 px-3 py-2 font-mono text-xs text-zinc-800 first:border-t-0"
            >
              <div class="flex flex-wrap gap-x-3 gap-y-1">
                <span class="text-zinc-500">{event_source_label(entry.source)}</span>
                <span>{entry.topic}</span>
                <span class="break-all">{entry.payload}</span>
              </div>
              <div class="mt-1 text-zinc-500">{entry.note}</div>
            </div>
          </div>
        </.console_section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("inc", _params, socket) do
    count = socket.assigns.count + 1
    payload = "count:#{count}"

    Bridge.broadcast(socket.assigns.bridge_server, "messages", payload)

    socket =
      socket
      |> assign(:count, count)
      |> append_event(:app, "messages", payload, "Raw message from LiveView.")

    {:noreply, socket}
  end

  def handle_event("refresh_capabilities", _params, socket) do
    {:noreply, refresh_capabilities(socket)}
  end

  def handle_event("bridge_echo", %{"echo" => %{"payload" => payload}}, socket) do
    socket = assign_echo_payload(socket, payload)

    socket =
      case Bridge.call(socket.assigns.bridge_server, "bridge.echo", payload, 5_000) do
        {:ok, ^payload} ->
          socket
          |> assign(:echo_response, payload)
          |> assign(
            :echo_status,
            status(
              :success,
              "Response matched",
              "bridge.echo returned the submitted payload."
            )
          )

        {:ok, response} ->
          socket
          |> assign(:echo_response, response)
          |> assign(
            :echo_status,
            status(
              :error,
              "Unexpected response",
              "Expected #{inspect(payload)} but received #{inspect(response)}."
            )
          )

        {:error, reason} ->
          formatted_reason = format_reason(reason)

          socket
          |> assign(:echo_response, nil)
          |> assign(
            :echo_status,
            status(
              :error,
              "bridge.echo failed",
              formatted_reason
            )
          )
          |> assign(:last_bridge_error, formatted_reason)
      end

    {:noreply, socket}
  end

  def handle_event("read_clipboard", _params, socket) do
    socket =
      case Clipboard.read_text(socket.assigns.bridge_server) do
        {:ok, text} ->
          socket
          |> assign(:clipboard_last_read, text)
          |> assign_clipboard_text(text)
          |> assign(
            :clipboard_status,
            status(
              :success,
              "Read succeeded",
              "Read #{byte_size(text)} byte(s)."
            )
          )

        {:error, reason} ->
          formatted_reason = format_reason(reason)

          socket
          |> assign(
            :clipboard_status,
            status(
              :error,
              "Read failed",
              formatted_reason
            )
          )
          |> assign(:last_bridge_error, formatted_reason)
      end

    {:noreply, socket}
  end

  def handle_event("write_clipboard", %{"clipboard" => %{"text" => text}}, socket) do
    socket = assign_clipboard_text(socket, text)

    socket =
      case Clipboard.write_text(socket.assigns.bridge_server, text) do
        :ok ->
          assign(
            socket,
            :clipboard_status,
            status(
              :success,
              "Write succeeded",
              "Wrote #{byte_size(text)} byte(s)."
            )
          )

        {:error, reason} ->
          formatted_reason = format_reason(reason)

          socket
          |> assign(
            :clipboard_status,
            status(
              :error,
              "Write failed",
              formatted_reason
            )
          )
          |> assign(:last_bridge_error, formatted_reason)
      end

    {:noreply, socket}
  end

  def handle_event("list_windows", _params, socket) do
    socket =
      case Window.list(socket.assigns.bridge_server) do
        {:ok, windows} ->
          {label, title} = select_window_defaults(socket, windows)

          socket
          |> assign(:windows, windows)
          |> assign_window_values(label, title)
          |> assign(
            :window_status,
            status(
              :success,
              "List succeeded",
              "Loaded #{length(windows)} window(s)."
            )
          )

        {:error, reason} ->
          formatted_reason = format_reason(reason)

          socket
          |> assign(
            :window_status,
            status(
              :error,
              "List failed",
              formatted_reason
            )
          )
          |> assign(:last_bridge_error, formatted_reason)
      end

    {:noreply, socket}
  end

  def handle_event("choose_window", %{"label" => label, "title" => title}, socket) do
    {:noreply, assign_window_values(socket, label, title)}
  end

  def handle_event("set_title", %{"window" => %{"label" => label, "title" => title}}, socket) do
    socket = assign_window_values(socket, label, title)

    socket =
      case Window.set_title(socket.assigns.bridge_server, label, title) do
        :ok ->
          socket
          |> assign(:windows, update_window_list(socket.assigns.windows, label, title))
          |> assign(
            :window_status,
            status(
              :success,
              "Title updated",
              "Requested #{inspect(label)} -> #{inspect(title)}."
            )
          )

        {:error, reason} ->
          formatted_reason = format_reason(reason)

          socket
          |> assign(
            :window_status,
            status(
              :error,
              "Title update failed",
              formatted_reason
            )
          )
          |> assign(:last_bridge_error, formatted_reason)
      end

    {:noreply, socket}
  end

  def handle_event("open_target", %{"opener" => %{"target" => target}}, socket) do
    socket = assign_open_target(socket, target)

    socket =
      case Opener.open(socket.assigns.bridge_server, target) do
        :ok ->
          assign(
            socket,
            :opener_status,
            status(
              :success,
              "Open request sent",
              "Requested #{target}."
            )
          )

        {:error, reason} ->
          formatted_reason = format_reason(reason)

          socket
          |> assign(
            :opener_status,
            status(
              :error,
              "Open failed",
              formatted_reason
            )
          )
          |> assign(:last_bridge_error, formatted_reason)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:bridge_event, %{topic: _topic, payload: _payload} = entry}, socket) do
    {:noreply, append_event(socket, entry)}
  end

  defp maybe_start_bridge_events(socket) do
    bridge_server = socket.assigns.bridge_server

    if connected?(socket) and bridge_events_available?(bridge_server) do
      {:ok, _pid} = BridgeEvents.start_link(owner: self(), bridge_server: bridge_server)
      socket
    else
      socket
    end
  end

  defp refresh_capabilities(socket) do
    case Bridge.capabilities(socket.assigns.bridge_server) do
      capabilities when is_map(capabilities) ->
        rows = normalize_capabilities(capabilities)

        socket
        |> assign(:capability_rows, rows)
        |> assign(
          :connection_status,
          status(
            :success,
            "Connected",
            "Capability discovery reached the host bridge."
          )
        )
        |> assign(
          :capabilities_status,
          status(
            :success,
            "Loaded #{length(rows)} namespace(s)",
            "Found #{available_action_count(rows)} available action(s)."
          )
        )
        |> assign(:last_bridge_error, nil)

      {:error, reason} ->
        formatted_reason = format_reason(reason)

        socket
        |> assign(:capability_rows, [])
        |> assign(
          :connection_status,
          status(
            :error,
            "Unavailable",
            "Capability discovery could not reach the host bridge."
          )
        )
        |> assign(
          :capabilities_status,
          status(
            :error,
            "Refresh failed",
            "ElixirKit.Bridge.capabilities/0 returned #{formatted_reason}."
          )
        )
        |> assign(:last_bridge_error, formatted_reason)
    end
  end

  defp bridge_server do
    Application.get_env(:example, :elixirkit_bridge_server, Bridge)
  end

  defp bridge_events_available?(server) do
    Process.whereis(server) != nil and Process.whereis(:"#{server}.Registry") != nil
  end

  defp normalize_capabilities(capabilities) do
    capabilities
    |> Enum.sort_by(fn {namespace, _descriptor} -> namespace end)
    |> Enum.map(fn {namespace, descriptor} ->
      %{
        name: namespace,
        backing: descriptor.backing,
        permission: descriptor.permission,
        actions:
          descriptor.actions
          |> Enum.sort_by(fn {action, _availability} -> action end)
          |> Enum.map(fn {action, availability} ->
            %{name: action, availability: availability}
          end)
      }
    end)
  end

  defp available_action_count(rows) do
    rows
    |> Enum.flat_map(& &1.actions)
    |> Enum.count(&(&1.availability == :available))
  end

  defp assign_echo_payload(socket, payload) do
    socket
    |> assign(:echo_payload, payload)
    |> sync_forms()
  end

  defp assign_clipboard_text(socket, text) do
    socket
    |> assign(:clipboard_text, text)
    |> sync_forms()
  end

  defp assign_window_values(socket, label, title) do
    socket
    |> assign(:window_label, label)
    |> assign(:window_title, title)
    |> sync_forms()
  end

  defp assign_open_target(socket, target) do
    socket
    |> assign(:open_target, target)
    |> sync_forms()
  end

  defp sync_forms(socket) do
    socket
    |> assign(:echo_form, to_form(%{"payload" => socket.assigns.echo_payload}, as: :echo))
    |> assign(
      :clipboard_form,
      to_form(%{"text" => socket.assigns.clipboard_text}, as: :clipboard)
    )
    |> assign(
      :window_form,
      to_form(
        %{"label" => socket.assigns.window_label, "title" => socket.assigns.window_title},
        as: :window
      )
    )
    |> assign(:opener_form, to_form(%{"target" => socket.assigns.open_target}, as: :opener))
  end

  defp select_window_defaults(socket, [%{label: label, title: title} | _] = windows) do
    current_label = socket.assigns.window_label

    case Enum.find(windows, &(&1.label == current_label)) do
      %{title: current_title} -> {current_label, current_title}
      nil -> {label, title}
    end
  end

  defp select_window_defaults(socket, []) do
    {socket.assigns.window_label, socket.assigns.window_title}
  end

  defp update_window_list(windows, label, title) do
    Enum.map(windows, fn window ->
      if window.label == label do
        %{window | title: title}
      else
        window
      end
    end)
  end

  defp append_event(socket, source, topic, payload, note) do
    append_event(socket, event_entry(source, topic, payload, note))
  end

  defp append_event(socket, entry) do
    assign(socket, :event_log, [entry | socket.assigns.event_log] |> Enum.take(@event_limit))
  end

  defp event_entry(source, topic, payload, note) do
    %{
      id: System.unique_integer([:positive]),
      source: source,
      topic: topic,
      payload: payload,
      note: note
    }
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :divided, :boolean, default: true
  slot :actions
  slot :inner_block, required: true

  defp console_section(assigns) do
    ~H"""
    <section id={@id} class={["space-y-3", @divided && "border-t border-zinc-200 pt-6"]}>
      <div class={header_classes(@actions)}>
        <div class="space-y-1">
          <h2 class="text-lg font-semibold text-zinc-950">{@title}</h2>
          <p :if={@description} class="text-sm text-zinc-600">{@description}</p>
        </div>

        <div :if={@actions != []} class="flex flex-wrap items-center gap-3">
          {render_slot(@actions)}
        </div>
      </div>

      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail_row(assigns) do
    ~H"""
    <div class="grid gap-1 border-b border-zinc-200 px-3 py-3 last:border-b-0 sm:grid-cols-[10rem_1fr]">
      <dt class="text-sm font-medium text-zinc-700">{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp output_block(assigns) do
    ~H"""
    <div>
      <p class="text-sm font-medium text-zinc-700">{@label}</p>
      <div id={@id} class={[value_box_classes(), @class]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp status(kind, title, detail) do
    %{kind: kind, title: title, detail: detail}
  end

  defp header_classes([]), do: "space-y-1"

  defp header_classes(_actions),
    do: "flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"

  defp primary_button_classes do
    "inline-flex items-center rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800"
  end

  defp secondary_button_classes do
    "inline-flex items-center rounded-md border border-zinc-300 px-3 py-2 text-sm font-medium text-zinc-800 hover:bg-zinc-50"
  end

  defp value_box_classes do
    "mt-1 overflow-x-auto rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 font-mono text-sm text-zinc-800"
  end

  defp status_text_classes(:success), do: "text-sm font-medium text-emerald-700"
  defp status_text_classes(:error), do: "text-sm font-medium text-red-700"
  defp status_text_classes(:warning), do: "text-sm font-medium text-amber-700"
  defp status_text_classes(:neutral), do: "text-sm font-medium text-zinc-800"

  defp capability_actions_text(actions) do
    actions
    |> Enum.map_join(", ", fn action ->
      "#{action.name}: #{humanize_atom(action.availability)}"
    end)
  end

  defp event_source_label(:app), do: "app -> host"
  defp event_source_label(:host), do: "host -> app"

  defp bridge_error_text(nil), do: "none"
  defp bridge_error_text(error), do: error

  defp clipboard_last_read_text(nil), do: "No clipboard read yet."
  defp clipboard_last_read_text(text), do: text

  defp echo_response_text(nil), do: "No response yet."
  defp echo_response_text(text), do: inspect(text)

  defp humanize_atom(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_reason(reason) when is_atom(reason), do: humanize_atom(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason({left, right}), do: "#{format_reason(left)}: #{format_reason(right)}"
  defp format_reason(other), do: inspect(other)
end
