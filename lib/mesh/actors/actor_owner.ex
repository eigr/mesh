defmodule Mesh.Actors.ActorOwner do
  use GenServer
  require Logger

  def start_link(shard_id) do
    GenServer.start_link(__MODULE__, shard_id, name: via(shard_id))
  end

  def call(actor_id, payload, actor_module, capability, init_arg \\ nil) do
    shard = Mesh.Shards.ShardRouter.shard_for(actor_id)
    GenServer.call(via(shard), {:call, actor_id, payload, actor_module, capability, init_arg})
  end

  def cast(actor_id, payload, actor_module, capability, init_arg \\ nil) do
    shard = Mesh.Shards.ShardRouter.shard_for(actor_id)
    GenServer.call(via(shard), {:cast, actor_id, payload, actor_module, capability, init_arg})
  end

  @impl true
  def init(shard_id) do
    Process.flag(:trap_exit, true)
    {:ok, %{shard: shard_id, monitors: %{}}}
  end

  @impl true
  def handle_call({:call, actor_id, payload, actor_module, capability, init_arg}, _from, state) do
    case get_or_create_actor(actor_id, actor_module, capability, init_arg, state) do
      {:ok, pid, new_state} ->
        reply = GenServer.call(pid, payload)
        {:reply, {:ok, pid, reply}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:cast, actor_id, payload, actor_module, capability, init_arg}, _from, state) do
    case get_or_create_actor(actor_id, actor_module, capability, init_arg, state) do
      {:ok, pid, new_state} ->
        GenServer.cast(pid, payload)
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Gets an existing actor or creates a new one.
  # Handles stale PIDs in ActorTable and recovers monitors after restart.
  defp get_or_create_actor(actor_id, actor_module, capability, init_arg, state) do
    actor_key = Mesh.Actors.ActorTable.key(capability, actor_module, actor_id)

    case Mesh.Actors.ActorTable.get(actor_key) do
      {:ok, pid, _node} ->
        if Process.alive?(pid) do
          # Actor exists and is alive - ensure we have a monitor
          new_state = ensure_monitored(actor_key, pid, state)
          {:ok, pid, new_state}
        else
          # Stale PID - clean up and create new actor
          Mesh.Actors.ActorTable.delete(actor_key)
          create_actor(actor_key, actor_id, actor_module, capability, init_arg, state)
        end

      :not_found ->
        create_actor(actor_key, actor_id, actor_module, capability, init_arg, state)
    end
  end

  # Creates a new actor, monitors it, and registers in ActorTable
  defp create_actor(actor_key, actor_id, actor_module, capability, init_arg, state) do
    case start_actor(actor_module, actor_id, capability, init_arg) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Mesh.Actors.ActorTable.put(actor_key, pid, node())
        {:ok, pid, put_in(state.monitors[ref], actor_key)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Ensures we have a monitor for the given actor.
  # This handles the case where ActorOwner restarted and lost its monitors.
  defp ensure_monitored(actor_key, pid, state) do
    already_monitored? =
      Enum.any?(state.monitors, fn {_ref, key} -> key == actor_key end)

    if already_monitored? do
      state
    else
      ref = Process.monitor(pid)
      put_in(state.monitors[ref], actor_key)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {actor_key, monitors} ->
        Mesh.Actors.ActorTable.delete(actor_key)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  # Handle EXIT signals from linked processes (we trap exits for clean shutdown)
  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # When ActorOwner is terminated (e.g., shard ownership changes),
    # terminate all actors we're monitoring and clean up ActorTable.
    for {ref, actor_key} <- state.monitors do
      Process.demonitor(ref, [:flush])

      case Mesh.Actors.ActorTable.get(actor_key) do
        {:ok, pid, _node} ->
          # Kill the actor immediately
          Process.exit(pid, :kill)
          Mesh.Actors.ActorTable.delete(actor_key)

        :not_found ->
          :ok
      end
    end

    :ok
  end

  defp start_actor(actor_module, actor_id, capability, init_arg) do
    Mesh.Actors.ActorSupervisor.start_child(actor_module, actor_id, capability, init_arg)
  end

  defp via(shard_id), do: {:via, Registry, {ActorOwnerRegistry, shard_id}}
end
