defmodule Mesh.Actors.ActorTable do
  use GenServer

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def key(capability, actor_module, actor_id) do
    {capability, actor_module, actor_id}
  end

  def get(actor_name) do
    case :ets.lookup(@table, actor_name) do
      [{^actor_name, pid, node}] -> {:ok, pid, node}
      [] -> :not_found
    end
  end

  def put(actor_name, pid, node) do
    :ets.insert(@table, {actor_name, pid, node})
    :ok
  end

  def delete(actor_name) do
    :ets.delete(@table, actor_name)
    :ok
  end

  def entries do
    :ets.tab2list(@table)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
