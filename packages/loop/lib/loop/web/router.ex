defmodule Loop.Web.Router do
  @moduledoc false

  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_resp(200, Loop.Web.Page.render())
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(Loop.Web.Socket, [], timeout: :infinity)
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "")
  end
end
