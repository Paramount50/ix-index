defmodule Loop.LogBus do
  @moduledoc """
  Pub/sub for iteration output. The runner publishes one line at a time;
  every connected WebSocket subscribes and receives `{:line, text}` messages.
  Retains the last #{500} lines so a fresh subscriber sees recent context
  before the live stream starts.
  """

  use GenServer

  @buffer_limit 500

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def publish(line), do: GenServer.cast(__MODULE__, {:publish, line})
  def subscribe(pid \\ self()), do: GenServer.call(__MODULE__, {:subscribe, pid})
  def unsubscribe(pid \\ self()), do: GenServer.cast(__MODULE__, {:unsubscribe, pid})
  def tail, do: GenServer.call(__MODULE__, :tail)

  @impl true
  def init(:ok), do: {:ok, %{subscribers: MapSet.new(), buffer: []}}

  @impl true
  def handle_cast({:publish, line}, state) do
    Enum.each(state.subscribers, &send(&1, {:line, line}))
    {:noreply, %{state | buffer: Enum.take([line | state.buffer], @buffer_limit)}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_call(:tail, _from, state) do
    {:reply, Enum.reverse(state.buffer), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end
end
