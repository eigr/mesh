defmodule Mesh.Actors.ActorOwner do
  use GenServer
  require Logger

  def start_link(shard_id) do
    GenServer.start_link(__MODULE__, shard_id, name: via(shard_id))
  end

  def call(actor_id, payload, actor_module, init_arg \\ nil) do
    shard = Mesh.Shards.ShardRouter.shard_for(actor_id)
    GenServer.call(via(shard), {:call, actor_id, payload, actor_module, init_arg})
  end

  def cast(actor_id, payload, actor_module, init_arg \\ nil) do
    shard = Mesh.Shards.ShardRouter.shard_for(actor_id)
    GenServer.call(via(shard), {:cast, actor_id, payload, actor_module, init_arg})
  end

  @impl true
  def init(shard_id), do: {:ok, %{shard: shard_id, monitors: %{}}}

  @impl true
  def handle_call({:call, actor_id, payload, actor_module, init_arg}, _from, state) do
    case Mesh.Actors.ActorTable.get(actor_id) do
      {:ok, pid, _node} ->
        reply = GenServer.call(pid, {:actor_call, payload})
        {:reply, {:ok, pid, reply}, state}

      :not_found ->
        {:ok, pid} = start_actor(actor_module, actor_id, init_arg)

        ref = Process.monitor(pid)
        Mesh.Actors.ActorTable.put(actor_id, pid, node())

        reply = GenServer.call(pid, {:actor_call, payload})
        {:reply, {:ok, pid, reply}, put_in(state.monitors[ref], actor_id)}
    end
  end

  @impl true
  def handle_call({:cast, actor_id, payload, actor_module, init_arg}, _from, state) do
    case Mesh.Actors.ActorTable.get(actor_id) do
      {:ok, pid, _node} ->
        GenServer.cast(pid, {:actor_cast, payload})
        {:reply, :ok, state}

      :not_found ->
        {:ok, pid} = start_actor(actor_module, actor_id, init_arg)

        ref = Process.monitor(pid)
        Mesh.Actors.ActorTable.put(actor_id, pid, node())

        GenServer.cast(pid, {:actor_cast, payload})
        {:reply, :ok, put_in(state.monitors[ref], actor_id)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {actor_id, monitors} ->
        Mesh.Actors.ActorTable.delete(actor_id)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  defp start_actor(actor_module, actor_id, nil) do
    # Legacy path: call start_link/1
    DynamicSupervisor.start_child(Mesh.Actors.ActorSupervisor, {actor_module, actor_id})
  end

  defp start_actor(actor_module, actor_id, init_arg) do
    # New path: call start_link/2 with custom init_arg
    child_spec = %{
      id: {actor_module, actor_id},
      start: {actor_module, :start_link, [actor_id, init_arg]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(Mesh.Actors.ActorSupervisor, child_spec)
  end

  defp via(shard_id), do: {:via, Registry, {ActorOwnerRegistry, shard_id}}
end
