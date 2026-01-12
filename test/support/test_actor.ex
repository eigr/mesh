defmodule Mesh.TestActor do
  use GenServer

  def start_link(actor_id, _init_arg \\ nil) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  def init(actor_id) do
    {:ok, %{id: actor_id, counter: 0}}
  end

  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
end
