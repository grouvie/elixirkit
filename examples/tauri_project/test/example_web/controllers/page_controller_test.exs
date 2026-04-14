defmodule ExampleWeb.PageControllerTest do
  use ExampleWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "ElixirKit reference console"
    assert html =~ "Bridge status"
    refute html =~ "Phoenix Framework"
    refute html =~ "Get Started"
  end
end
