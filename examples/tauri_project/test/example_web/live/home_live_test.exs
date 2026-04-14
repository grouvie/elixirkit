defmodule ExampleWeb.HomeLiveTest do
  use ExampleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Example.TestSupport.ShowcaseHost

  test "renders the simplified reference console without a host bridge", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "ElixirKit reference console"
    assert html =~ "Bridge status"
    assert html =~ "Capabilities"
    assert html =~ "Echo"
    assert html =~ "Opener"
    assert html =~ "Clipboard"
    assert html =~ "Window"
    assert html =~ "Event log"
    assert html =~ "Unavailable"
    refute html =~ "Phoenix Framework"
    refute html =~ "Get Started"
    refute html =~ "https://hexdocs.pm/elixirkit"
  end

  describe "with a local bridge host" do
    setup %{conn: conn} do
      ShowcaseHost.setup_host_bridge()
      {:ok, view, _html} = live(conn, ~p"/")
      %{view: view}
    end

    test "shows capability discovery", %{view: view} do
      html = render(view)

      assert html =~ "Connected"
      assert html =~ "clipboard"
      assert html =~ "opener"
      assert html =~ "window"
      assert html =~ "bridge"
    end

    test "round trips bridge.echo", %{view: view} do
      render_submit(form(view, "#echo-form", echo: %{"payload" => "echo me"}))

      html = wait_for_html(view, "\"echo me\"")
      assert html =~ "Response matched"
      assert html =~ "\"echo me\""
    end

    test "writes and reads clipboard text", %{view: view} do
      render_submit(form(view, "#clipboard-form", clipboard: %{"text" => "LiveView -> host"}))
      assert_receive {:clipboard_written, "LiveView -> host"}
      assert wait_for_html(view, "Wrote 16 byte(s).") =~ "Write succeeded"

      render_click(element(view, "#read-clipboard"))
      assert_receive {:clipboard_read, "LiveView -> host"}

      html = wait_for_html(view, "LiveView -&gt; host")
      assert html =~ "Read succeeded"
      assert html =~ "Read 16 byte(s)."
      assert html =~ "LiveView -&gt; host"
    end

    test "submits opener requests", %{view: view} do
      render_submit(form(view, "#opener-form", opener: %{"target" => "https://example.com"}))

      assert_receive {:opener_opened, "https://example.com"}

      html = wait_for_html(view, "Open request sent")
      assert html =~ "Requested https://example.com."
    end

    test "lists windows and updates titles", %{view: view} do
      render_click(element(view, "#window-list"))
      assert wait_for_html(view, "window-1") =~ "List succeeded"

      render_submit(
        form(
          view,
          "#window-form",
          window: %{"label" => "window-1", "title" => "Bridge Showcase"}
        )
      )

      assert_receive {:window_title_set, "window-1", "Bridge Showcase"}

      html = wait_for_html(view, "Bridge Showcase")
      assert html =~ "Title updated"
      assert html =~ "Requested &quot;window-1&quot; -&gt; &quot;Bridge Showcase&quot;."
    end

    test "updates the raw event log", %{view: view} do
      render_click(element(view, "#counter-inc"))

      assert_receive {:raw_count_seen, "count:1"}

      html = wait_for_html(view, "host:observed count:1")
      assert html =~ "count:1"
      assert html =~ "host -&gt; app"
      assert html =~ "app -&gt; host"
    end
  end

  defp wait_for_html(view, fragment, attempts \\ 20)

  defp wait_for_html(_view, fragment, 0) do
    flunk("expected LiveView HTML to include #{inspect(fragment)}")
  end

  defp wait_for_html(view, fragment, attempts) do
    html = render(view)

    if html =~ fragment do
      html
    else
      Process.sleep(25)
      wait_for_html(view, fragment, attempts - 1)
    end
  end
end
