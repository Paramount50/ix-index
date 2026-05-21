defmodule Loop.Web.Router do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: method, path_info: []} = conn, _opts) when method in ["GET", "HEAD"] do
    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_resp(200, Loop.Web.Page.render())
  end

  def call(%Plug.Conn{method: "GET", path_info: ["ws"]} = conn, _opts) do
    conn
    |> WebSockAdapter.upgrade(Loop.Web.Socket, [], timeout: :infinity)
    |> halt()
  end

  def call(conn, _opts) do
    send_resp(conn, 404, "")
  end
end
