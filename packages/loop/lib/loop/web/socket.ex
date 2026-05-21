defmodule Loop.Web.Socket do
  @moduledoc false

  @behaviour WebSock

  alias Loop.LogBus

  @impl true
  def init(_opts) do
    LogBus.subscribe()
    backlog = LogBus.tail() |> Enum.map(&{:text, &1})
    {:push, backlog, %{}}
  end

  @impl true
  def handle_in(_msg, state), do: {:ok, state}

  @impl true
  def handle_info({:line, text}, state), do: {:push, {:text, text}, state}

  @impl true
  def terminate(_reason, state) do
    LogBus.unsubscribe()
    {:ok, state}
  end
end
