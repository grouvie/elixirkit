defmodule ExampleWeb.PageControllerTest do
  use ExampleWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "ElixirKit Bridge Showcase"
    assert html =~ "Increment Counter"
  end
end
