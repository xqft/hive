defmodule HiveWeb.PageControllerTest do
  use HiveWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Hive"
  end
end
