defmodule Loop.Application do
  @moduledoc """
  Supervises the log bus and the Bandit web server. The runner itself is
  not a supervised process: it is kicked off from `Loop.CLI` after the
  release boots and tears the whole VM down when it finishes.
  """

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:loop, :web_port, 7878)

    children = [
      Loop.LogBus,
      {Bandit, plug: Loop.Web.Router, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Loop.Supervisor)
  end
end
