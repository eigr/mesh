defmodule Mesh.ShardRebalancingTest.TestActor do
  use GenServer

  def start_link(actor_id, _init_arg \\ nil) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  def init(actor_id) do
    {:ok, actor_id}
  end

  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end
end
