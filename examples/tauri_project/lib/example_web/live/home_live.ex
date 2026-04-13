defmodule ExampleWeb.HomeLive do
  use ExampleWeb, :live_view

  alias ElixirKit.{Bridge, Clipboard, Opener, Window}

  @activity_limit 8
  @default_clipboard_text "ElixirKit capability demo from LiveView"
  @default_open_target "https://hexdocs.pm/elixirkit"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        count: 0,
        bridge_server: bridge_server(),
        bridge_status:
          status(
            :neutral,
            "Waiting for host bridge",
            "The page works in plain Phoenix too, but the richer capability calls only light up when the Tauri host is attached."
          ),
        echo_status:
          status(
            :neutral,
            "No bridge.echo round trip yet",
            "Use the broker controls below to prove the request/response path independently from any capability plugin."
          ),
        clipboard_status:
          status(
            :neutral,
            "Clipboard idle",
            "Read or write through the extracted clipboard package once the host bridge is connected."
          ),
        window_status:
          status(
            :neutral,
            "Window controls idle",
            "List host windows or rename one without adding any capability logic back into the LiveView."
          ),
        opener_status:
          status(
            :neutral,
            "Opener idle",
            "Launch a URL through the extracted opener package when the desktop host is available."
          ),
        capability_rows: [],
        windows: [],
        clipboard_text: @default_clipboard_text,
        window_label: "",
        window_title: "Example",
        open_target: @default_open_target,
        activity: [
          activity(
            :info,
            "Showcase loaded",
            "The raw \"ready\" and \"count\" PubSub path stays intact while the cards below exercise the brokered bridge and extracted capability packages."
          )
        ]
      )
      |> sync_forms()
      |> refresh_capabilities()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="relative overflow-hidden rounded-[2rem] border border-base-300/80 bg-base-100 shadow-[0_28px_80px_rgba(15,23,42,0.10)]">
        <div class="absolute inset-x-0 top-0 h-48 bg-[radial-gradient(circle_at_top_left,rgba(244,114,33,0.18),transparent_58%),radial-gradient(circle_at_top_right,rgba(37,99,235,0.16),transparent_46%)]" />

        <div class="relative grid gap-8 px-6 py-8 lg:grid-cols-[minmax(0,1.25fr)_minmax(0,0.9fr)] lg:px-10 lg:py-10">
          <div class="space-y-5">
            <div class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100/90 px-4 py-2 text-xs font-semibold uppercase tracking-[0.24em] text-base-content/65 backdrop-blur">
              <span class="size-2 rounded-full bg-primary" /> ElixirKit Bridge Showcase
            </div>

            <div class="space-y-4">
              <h1 class="max-w-3xl text-4xl font-semibold tracking-tight text-base-content sm:text-5xl">
                The example now shows the bridge and extracted capability packages in action.
              </h1>
              <p class="max-w-2xl text-base leading-7 text-base-content/72">
                The counter still emits raw
                <code class="rounded bg-base-200 px-2 py-1 text-sm">count:N</code>
                messages over <code class="rounded bg-base-200 px-2 py-1 text-sm">messages</code>, but the rest of the
                screen now exercises the brokered request/response path and the extracted <code class="rounded bg-base-200 px-2 py-1 text-sm">opener</code>, <code class="rounded bg-base-200 px-2 py-1 text-sm">clipboard</code>, and
                <code class="rounded bg-base-200 px-2 py-1 text-sm">window</code>
                packages.
              </p>
            </div>

            <div class="flex flex-wrap gap-3 text-sm text-base-content/70">
              <span class="rounded-full border border-base-300 bg-base-100 px-3 py-1.5">
                Core bridge stays in the root packages
              </span>
              <span class="rounded-full border border-base-300 bg-base-100 px-3 py-1.5">
                Capability registration stays explicit in Rust
              </span>
              <span class="rounded-full border border-base-300 bg-base-100 px-3 py-1.5">
                Transport and outer envelope stay unchanged
              </span>
            </div>
          </div>

          <aside class="grid gap-4 rounded-[1.5rem] border border-base-300/80 bg-base-100/90 p-5 backdrop-blur">
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/55">
                  Host bridge
                </p>
                <p class="mt-2 text-xl font-semibold text-base-content">{@bridge_status.title}</p>
              </div>
              <span class={badge_classes(@bridge_status.kind)}>{@bridge_status.tag}</span>
            </div>

            <p class="text-sm leading-6 text-base-content/68">{@bridge_status.detail}</p>

            <dl class="grid gap-3 sm:grid-cols-3">
              <div class="rounded-2xl border border-base-300/80 bg-base-200/60 p-4">
                <dt class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/55">
                  Namespaces
                </dt>
                <dd class="mt-2 text-3xl font-semibold text-base-content">
                  {length(@capability_rows)}
                </dd>
              </div>
              <div class="rounded-2xl border border-base-300/80 bg-base-200/60 p-4">
                <dt class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/55">
                  Actions
                </dt>
                <dd class="mt-2 text-3xl font-semibold text-base-content">
                  {available_action_count(@capability_rows)}
                </dd>
              </div>
              <div class="rounded-2xl border border-base-300/80 bg-base-200/60 p-4">
                <dt class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/55">
                  Windows
                </dt>
                <dd class="mt-2 text-3xl font-semibold text-base-content">
                  {length(@windows)}
                </dd>
              </div>
            </dl>
          </aside>
        </div>
      </section>

      <section class="grid gap-6 xl:grid-cols-[minmax(0,1.3fr)_minmax(0,0.95fr)]">
        <div class="space-y-6">
          <article class="rounded-[1.75rem] border border-base-300/80 bg-base-100 p-6 shadow-[0_18px_40px_rgba(15,23,42,0.08)]">
            <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
              <div class="space-y-2">
                <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/55">
                  Raw PubSub compatibility
                </p>
                <h2 class="text-2xl font-semibold text-base-content">
                  The original count demo still drives the raw topic flow.
                </h2>
                <p class="max-w-2xl text-sm leading-6 text-base-content/68">
                  Every increment still broadcasts a
                  <code class="rounded bg-base-200 px-2 py-1 text-xs">count:N</code>
                  message on the unchanged
                  <code class="rounded bg-base-200 px-2 py-1 text-xs">messages</code>
                  topic.
                  The Rust side keeps logging those events exactly like before.
                </p>
              </div>

              <button
                id="counter-inc"
                phx-click="inc"
                class="inline-flex items-center justify-center rounded-full border border-base-content/10 bg-base-content px-5 py-3 text-sm font-semibold text-base-100 transition hover:-translate-y-0.5 hover:bg-base-content/92 focus:outline-none focus:ring-2 focus:ring-base-content/25 phx-click-loading:opacity-70"
              >
                Increment Counter
              </button>
            </div>

            <div class="mt-6 grid gap-4 md:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
              <div class="rounded-[1.5rem] border border-base-300 bg-base-200/60 p-5">
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/55">
                  Current count
                </p>
                <div class="mt-3 flex items-baseline gap-3">
                  <span class="text-5xl font-semibold tracking-tight text-base-content">
                    {@count}
                  </span>
                  <span class="rounded-full bg-primary/10 px-3 py-1 text-sm font-medium text-primary">
                    Raw topic broadcast
                  </span>
                </div>
              </div>

              <div class="rounded-[1.5rem] border border-base-300 bg-base-200/40 p-5">
                <p class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/55">
                  What changed in this milestone
                </p>
                <div class="mt-4 grid gap-3 text-sm leading-6 text-base-content/72">
                  <p>Capability-specific host code lives in extracted Rust crates.</p>
                  <p>Capability-specific Elixir wrappers live in extracted local packages.</p>
                  <p>The example UI now proves those slices without redesigning the bridge core.</p>
                </div>
              </div>
            </div>
          </article>

          <article class="rounded-[1.75rem] border border-base-300/80 bg-base-100 p-6 shadow-[0_18px_40px_rgba(15,23,42,0.08)]">
            <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
              <div class="space-y-2">
                <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/55">
                  Bridge core
                </p>
                <h2 class="text-2xl font-semibold text-base-content">
                  Brokered calls and capability discovery
                </h2>
                <p class="max-w-2xl text-sm leading-6 text-base-content/68">
                  These controls hit the existing bridge broker, not a new transport. The capability
                  snapshot is the same data returned by <code class="rounded bg-base-200 px-2 py-1 text-xs">ElixirKit.Bridge.capabilities/0</code>.
                </p>
              </div>

              <div class="flex flex-wrap gap-3">
                <button
                  id="capability-refresh"
                  phx-click="refresh_capabilities"
                  class="inline-flex items-center justify-center rounded-full border border-base-300 bg-base-100 px-4 py-2 text-sm font-semibold text-base-content transition hover:-translate-y-0.5 hover:border-base-content/25 hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-base-content/15"
                >
                  Refresh Capabilities
                </button>
                <button
                  id="bridge-echo"
                  phx-click="bridge_echo"
                  class="inline-flex items-center justify-center rounded-full border border-primary/25 bg-primary/10 px-4 py-2 text-sm font-semibold text-primary transition hover:-translate-y-0.5 hover:bg-primary/15 focus:outline-none focus:ring-2 focus:ring-primary/20"
                >
                  Ping bridge.echo
                </button>
              </div>
            </div>

            <div class="mt-5 rounded-[1.5rem] border border-base-300 bg-base-200/40 p-5">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <p class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/55">
                    Last broker result
                  </p>
                  <p class="mt-2 text-lg font-semibold text-base-content">{@echo_status.title}</p>
                </div>
                <span class={badge_classes(@echo_status.kind)}>{@echo_status.tag}</span>
              </div>
              <p class="mt-3 text-sm leading-6 text-base-content/68">{@echo_status.detail}</p>
            </div>

            <div class="mt-6 space-y-4">
              <div class="flex items-center justify-between gap-3">
                <h3 class="text-lg font-semibold text-base-content">Capability snapshot</h3>
                <span class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/50">
                  {length(@capability_rows)} namespaces discovered
                </span>
              </div>

              <div
                :if={@capability_rows == []}
                class="rounded-[1.5rem] border border-dashed border-base-300 bg-base-200/30 p-6 text-sm leading-6 text-base-content/65"
              >
                Start the example through Tauri to see the host-reported namespaces and actions.
              </div>

              <div
                :for={row <- @capability_rows}
                class="rounded-[1.5rem] border border-base-300 bg-base-200/35 p-5"
              >
                <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                  <div>
                    <div class="flex flex-wrap items-center gap-3">
                      <h4 class="text-lg font-semibold text-base-content">{row.name}</h4>
                      <span class={capability_backing_classes(row.backing)}>
                        {humanize_atom(row.backing)}
                      </span>
                      <span class="rounded-full border border-base-300 bg-base-100 px-3 py-1 text-xs font-medium text-base-content/70">
                        {humanize_atom(row.permission)}
                      </span>
                    </div>
                    <p class="mt-2 text-sm leading-6 text-base-content/68">
                      Available actions stay separate from permission state. This mirrors the bridge capability truth model without changing the transport.
                    </p>
                  </div>
                </div>

                <div class="mt-4 flex flex-wrap gap-2">
                  <span
                    :for={action <- row.actions}
                    class={capability_action_classes(action.availability)}
                  >
                    {action.name} · {humanize_atom(action.availability)}
                  </span>
                </div>
              </div>
            </div>
          </article>
        </div>

        <div class="space-y-6">
          <article class="rounded-[1.75rem] border border-base-300/80 bg-base-100 p-6 shadow-[0_18px_40px_rgba(15,23,42,0.08)]">
            <div class="flex items-start justify-between gap-4">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/55">
                  Clipboard capability
                </p>
                <h2 class="mt-2 text-xl font-semibold text-base-content">
                  Read and write through the extracted package
                </h2>
              </div>
              <span class={badge_classes(@clipboard_status.kind)}>{@clipboard_status.tag}</span>
            </div>

            <p class="mt-3 text-sm leading-6 text-base-content/68">{@clipboard_status.detail}</p>

            <.form
              for={@clipboard_form}
              id="clipboard-form"
              phx-submit="write_clipboard"
              class="mt-5 space-y-4"
            >
              <.input
                field={@clipboard_form[:text]}
                type="textarea"
                label="Clipboard text"
                rows="4"
                class="w-full rounded-[1.25rem] border border-base-300 bg-base-200/60 px-4 py-3 text-sm leading-6 text-base-content shadow-none focus:border-primary/35 focus:outline-none"
              />

              <div class="flex flex-wrap gap-3">
                <button
                  type="submit"
                  class="inline-flex items-center justify-center rounded-full border border-base-content/10 bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:-translate-y-0.5 hover:bg-base-content/92 focus:outline-none focus:ring-2 focus:ring-base-content/20"
                >
                  Write Clipboard
                </button>
                <button
                  id="read-clipboard"
                  type="button"
                  phx-click="read_clipboard"
                  class="inline-flex items-center justify-center rounded-full border border-base-300 bg-base-100 px-4 py-2 text-sm font-semibold text-base-content transition hover:-translate-y-0.5 hover:border-base-content/20 hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-base-content/15"
                >
                  Read Clipboard
                </button>
              </div>
            </.form>
          </article>

          <article class="rounded-[1.75rem] border border-base-300/80 bg-base-100 p-6 shadow-[0_18px_40px_rgba(15,23,42,0.08)]">
            <div class="flex items-start justify-between gap-4">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/55">
                  Window capability
                </p>
                <h2 class="mt-2 text-xl font-semibold text-base-content">
                  Inspect and rename host windows
                </h2>
              </div>
              <span class={badge_classes(@window_status.kind)}>{@window_status.tag}</span>
            </div>

            <p class="mt-3 text-sm leading-6 text-base-content/68">{@window_status.detail}</p>

            <div class="mt-5 rounded-[1.5rem] border border-base-300 bg-base-200/35 p-4">
              <div class="flex items-center justify-between gap-3">
                <p class="text-sm font-semibold text-base-content">Known host windows</p>
                <button
                  id="window-list"
                  phx-click="list_windows"
                  class="inline-flex items-center justify-center rounded-full border border-base-300 bg-base-100 px-4 py-2 text-sm font-semibold text-base-content transition hover:-translate-y-0.5 hover:border-base-content/20 hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-base-content/15"
                >
                  List Windows
                </button>
              </div>

              <div :if={@windows == []} class="mt-3 text-sm leading-6 text-base-content/62">
                No host windows loaded yet.
              </div>

              <div
                :for={window <- @windows}
                class="mt-3 rounded-2xl border border-base-300 bg-base-100 px-4 py-3"
              >
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <p class="text-sm font-semibold text-base-content">{window.title}</p>
                    <p class="text-xs uppercase tracking-[0.18em] text-base-content/48">
                      {window.label}
                    </p>
                  </div>
                  <span class="rounded-full bg-base-200 px-3 py-1 text-xs font-medium text-base-content/70">
                    Live Tauri window
                  </span>
                </div>
              </div>
            </div>

            <.form for={@window_form} id="window-form" phx-submit="set_title" class="mt-5 grid gap-4">
              <div class="grid gap-4 md:grid-cols-2">
                <.input
                  field={@window_form[:label]}
                  type="text"
                  label="Window label"
                  class="w-full rounded-[1.25rem] border border-base-300 bg-base-200/60 px-4 py-3 text-sm text-base-content shadow-none focus:border-primary/35 focus:outline-none"
                />
                <.input
                  field={@window_form[:title]}
                  type="text"
                  label="New title"
                  class="w-full rounded-[1.25rem] border border-base-300 bg-base-200/60 px-4 py-3 text-sm text-base-content shadow-none focus:border-primary/35 focus:outline-none"
                />
              </div>

              <button
                type="submit"
                class="inline-flex items-center justify-center rounded-full border border-base-content/10 bg-base-content px-4 py-2 text-sm font-semibold text-base-100 transition hover:-translate-y-0.5 hover:bg-base-content/92 focus:outline-none focus:ring-2 focus:ring-base-content/20"
              >
                Set Window Title
              </button>
            </.form>
          </article>

          <article class="rounded-[1.75rem] border border-base-300/80 bg-base-100 p-6 shadow-[0_18px_40px_rgba(15,23,42,0.08)]">
            <div class="flex items-start justify-between gap-4">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/55">
                  Opener capability
                </p>
                <h2 class="mt-2 text-xl font-semibold text-base-content">
                  Launch a URL with the host shell
                </h2>
              </div>
              <span class={badge_classes(@opener_status.kind)}>{@opener_status.tag}</span>
            </div>

            <p class="mt-3 text-sm leading-6 text-base-content/68">{@opener_status.detail}</p>

            <.form
              for={@opener_form}
              id="opener-form"
              phx-submit="open_target"
              class="mt-5 grid gap-4"
            >
              <.input
                field={@opener_form[:target]}
                type="url"
                label="Target URL"
                class="w-full rounded-[1.25rem] border border-base-300 bg-base-200/60 px-4 py-3 text-sm text-base-content shadow-none focus:border-primary/35 focus:outline-none"
              />

              <button
                type="submit"
                class="inline-flex items-center justify-center rounded-full border border-primary/25 bg-primary/10 px-4 py-2 text-sm font-semibold text-primary transition hover:-translate-y-0.5 hover:bg-primary/15 focus:outline-none focus:ring-2 focus:ring-primary/20"
              >
                Open URL
              </button>
            </.form>
          </article>

          <article class="rounded-[1.75rem] border border-base-300/80 bg-base-100 p-6 shadow-[0_18px_40px_rgba(15,23,42,0.08)]">
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.22em] text-base-content/55">
                  Activity feed
                </p>
                <h2 class="mt-2 text-xl font-semibold text-base-content">
                  What the example just exercised
                </h2>
              </div>
              <span class="rounded-full border border-base-300 bg-base-100 px-3 py-1 text-xs font-medium text-base-content/70">
                {length(@activity)} latest events
              </span>
            </div>

            <div class="mt-5 space-y-3">
              <div
                :for={item <- @activity}
                class="rounded-[1.25rem] border border-base-300 bg-base-200/35 p-4"
              >
                <div class="flex items-center justify-between gap-3">
                  <p class="text-sm font-semibold text-base-content">{item.title}</p>
                  <span class={badge_classes(item.kind)}>{item.tag}</span>
                </div>
                <p class="mt-2 text-sm leading-6 text-base-content/68">{item.detail}</p>
              </div>
            </div>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("inc", _params, socket) do
    count = socket.assigns.count + 1
    Bridge.broadcast("messages", "count:#{count}")

    socket =
      socket
      |> assign(:count, count)
      |> record_activity(
        :info,
        "Raw topic broadcast",
        "Sent count:#{count} on the unchanged messages topic for the Rust side to log."
      )

    {:noreply, socket}
  end

  def handle_event("refresh_capabilities", _params, socket) do
    {:noreply, refresh_capabilities(socket)}
  end

  def handle_event("bridge_echo", _params, socket) do
    payload = "ping from LiveView"

    socket =
      case Bridge.call(socket.assigns.bridge_server, "bridge.echo", payload, 5_000) do
        {:ok, ^payload} ->
          socket
          |> assign(
            :echo_status,
            status(
              :success,
              "bridge.echo responded with #{inspect(payload)}",
              "This is the built-in broker path in the bridge core, not a capability plugin."
            )
          )
          |> record_activity(
            :success,
            "Bridge core round trip",
            "bridge.echo completed through the brokered bridge path."
          )

        {:ok, response} ->
          socket
          |> assign(
            :echo_status,
            status(
              :error,
              "bridge.echo returned an unexpected payload",
              "Expected #{inspect(payload)} but received #{inspect(response)}."
            )
          )
          |> record_activity(
            :error,
            "Bridge core round trip failed",
            "bridge.echo returned #{inspect(response)} instead of the original payload."
          )

        {:error, reason} ->
          socket
          |> assign(
            :echo_status,
            status(
              :error,
              "bridge.echo failed",
              "The bridge core returned #{format_reason(reason)}."
            )
          )
          |> record_activity(
            :error,
            "Bridge core round trip failed",
            format_reason(reason)
          )
      end

    {:noreply, socket}
  end

  def handle_event("read_clipboard", _params, socket) do
    socket =
      case Clipboard.read_text(socket.assigns.bridge_server) do
        {:ok, text} ->
          socket
          |> assign(
            :clipboard_status,
            status(
              :success,
              "Clipboard text loaded",
              "Read #{byte_size(text)} bytes from the host clipboard through the extracted clipboard package."
            )
          )
          |> assign_clipboard_text(text)
          |> record_activity(
            :success,
            "Clipboard read",
            "Loaded clipboard contents from the host bridge."
          )

        {:error, reason} ->
          socket
          |> assign(
            :clipboard_status,
            status(
              :error,
              "Clipboard read failed",
              "The clipboard capability returned #{format_reason(reason)}."
            )
          )
          |> record_activity(
            :error,
            "Clipboard read failed",
            format_reason(reason)
          )
      end

    {:noreply, socket}
  end

  def handle_event("write_clipboard", %{"clipboard" => %{"text" => text}}, socket) do
    socket =
      socket
      |> assign_clipboard_text(text)
      |> case do
        socket ->
          case Clipboard.write_text(socket.assigns.bridge_server, text) do
            :ok ->
              socket
              |> assign(
                :clipboard_status,
                status(
                  :success,
                  "Clipboard updated",
                  "Wrote #{byte_size(text)} bytes to the host clipboard through the extracted clipboard package."
                )
              )
              |> record_activity(
                :success,
                "Clipboard write",
                "Sent clipboard contents to the host bridge."
              )

            {:error, reason} ->
              socket
              |> assign(
                :clipboard_status,
                status(
                  :error,
                  "Clipboard write failed",
                  "The clipboard capability returned #{format_reason(reason)}."
                )
              )
              |> record_activity(
                :error,
                "Clipboard write failed",
                format_reason(reason)
              )
          end
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
              "Window list refreshed",
              "Loaded #{length(windows)} host window(s) through the extracted window package."
            )
          )
          |> record_activity(
            :success,
            "Window list refreshed",
            "Loaded #{length(windows)} host window(s) from the bridge."
          )

        {:error, reason} ->
          socket
          |> assign(
            :window_status,
            status(
              :error,
              "Window listing failed",
              "The window capability returned #{format_reason(reason)}."
            )
          )
          |> record_activity(
            :error,
            "Window listing failed",
            format_reason(reason)
          )
      end

    {:noreply, socket}
  end

  def handle_event("set_title", %{"window" => %{"label" => label, "title" => title}}, socket) do
    socket =
      socket
      |> assign_window_values(label, title)
      |> case do
        socket ->
          case Window.set_title(socket.assigns.bridge_server, label, title) do
            :ok ->
              socket
              |> assign(:windows, update_window_list(socket.assigns.windows, label, title))
              |> assign(
                :window_status,
                status(
                  :success,
                  "Window title updated",
                  "Asked the host to rename #{inspect(label)} to #{inspect(title)}."
                )
              )
              |> record_activity(
                :success,
                "Window title update",
                "Requested a title change for #{inspect(label)}."
              )

            {:error, reason} ->
              socket
              |> assign(
                :window_status,
                status(
                  :error,
                  "Window title update failed",
                  "The window capability returned #{format_reason(reason)}."
                )
              )
              |> record_activity(
                :error,
                "Window title update failed",
                format_reason(reason)
              )
          end
      end

    {:noreply, socket}
  end

  def handle_event("open_target", %{"opener" => %{"target" => target}}, socket) do
    socket =
      socket
      |> assign_open_target(target)
      |> case do
        socket ->
          case Opener.open(socket.assigns.bridge_server, target) do
            :ok ->
              socket
              |> assign(
                :opener_status,
                status(
                  :success,
                  "Host opener dispatched",
                  "Requested that the host shell open #{target}."
                )
              )
              |> record_activity(
                :success,
                "Opener call dispatched",
                "Sent #{target} through the extracted opener package."
              )

            {:error, reason} ->
              socket
              |> assign(
                :opener_status,
                status(
                  :error,
                  "Opener call failed",
                  "The opener capability returned #{format_reason(reason)}."
                )
              )
              |> record_activity(
                :error,
                "Opener call failed",
                format_reason(reason)
              )
          end
      end

    {:noreply, socket}
  end

  defp refresh_capabilities(socket) do
    case Bridge.capabilities(socket.assigns.bridge_server) do
      capabilities when is_map(capabilities) ->
        rows = normalize_capabilities(capabilities)

        socket
        |> assign(:capability_rows, rows)
        |> assign(
          :bridge_status,
          status(
            :success,
            "Bridge connected",
            "The host reported #{length(rows)} namespace(s) and #{available_action_count(rows)} available action(s) through the existing capability registry."
          )
        )
        |> record_activity(
          :success,
          "Capabilities refreshed",
          "Loaded #{length(rows)} namespace(s) from ElixirKit.Bridge.capabilities/0."
        )

      {:error, reason} ->
        socket
        |> assign(:capability_rows, [])
        |> assign(
          :bridge_status,
          status(
            :error,
            "Bridge unavailable",
            "Capability discovery failed with #{format_reason(reason)}."
          )
        )
        |> record_activity(
          :warning,
          "Capabilities unavailable",
          format_reason(reason)
        )
    end
  end

  defp bridge_server do
    Application.get_env(:example, :elixirkit_bridge_server, Bridge)
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
      nil when current_label in [nil, ""] ->
        {label, title}

      nil ->
        {label, title}

      %{title: current_title} ->
        {current_label, current_title}
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

  defp record_activity(socket, kind, title, detail) do
    assign(
      socket,
      :activity,
      [activity(kind, title, detail) | socket.assigns.activity] |> Enum.take(@activity_limit)
    )
  end

  defp status(kind, title, detail) do
    %{
      kind: kind,
      tag: humanize_atom(kind),
      title: title,
      detail: detail
    }
  end

  defp activity(kind, title, detail) do
    %{
      kind: kind,
      tag: humanize_atom(kind),
      title: title,
      detail: detail
    }
  end

  defp badge_classes(:success) do
    "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-emerald-700 dark:text-emerald-200"
  end

  defp badge_classes(:warning) do
    "rounded-full border border-amber-500/25 bg-amber-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-amber-700 dark:text-amber-200"
  end

  defp badge_classes(:error) do
    "rounded-full border border-rose-500/25 bg-rose-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-rose-700 dark:text-rose-200"
  end

  defp badge_classes(:info) do
    "rounded-full border border-sky-500/25 bg-sky-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-sky-700 dark:text-sky-200"
  end

  defp badge_classes(:neutral) do
    "rounded-full border border-base-300 bg-base-100 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-base-content/70"
  end

  defp capability_backing_classes(:core) do
    "rounded-full border border-base-content/10 bg-base-content px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-base-100"
  end

  defp capability_backing_classes(:tauri_plugin) do
    "rounded-full border border-primary/25 bg-primary/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-primary"
  end

  defp capability_backing_classes(:tauri_core) do
    "rounded-full border border-secondary/25 bg-secondary/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-secondary"
  end

  defp capability_action_classes(:available) do
    "rounded-full border border-emerald-500/25 bg-emerald-500/10 px-3 py-1 text-xs font-medium text-emerald-700 dark:text-emerald-200"
  end

  defp capability_action_classes(:unavailable) do
    "rounded-full border border-amber-500/25 bg-amber-500/10 px-3 py-1 text-xs font-medium text-amber-700 dark:text-amber-200"
  end

  defp capability_action_classes(:unsupported) do
    "rounded-full border border-base-300 bg-base-100 px-3 py-1 text-xs font-medium text-base-content/70"
  end

  defp capability_action_classes(:unsupported_platform) do
    "rounded-full border border-rose-500/20 bg-rose-500/10 px-3 py-1 text-xs font-medium text-rose-700 dark:text-rose-200"
  end

  defp humanize_atom(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_reason(reason) when is_atom(reason), do: humanize_atom(reason)
  defp format_reason(reason) when is_binary(reason), do: reason

  defp format_reason({left, right}) do
    "#{format_reason(left)}: #{format_reason(right)}"
  end

  defp format_reason(other), do: inspect(other)
end
