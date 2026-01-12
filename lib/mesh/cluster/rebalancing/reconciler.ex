defmodule Mesh.Cluster.Rebalancing.Reconciler do
  @moduledoc """
  Background reconciliation process that periodically checks and fixes
  inconsistencies in the cluster.

  This module embraces the eventual consistency model by:
  - Detecting orphaned actors on wrong nodes
  - Cleaning up actors that should have been moved during rebalancing
  - Detecting nodes stuck in rebalancing mode
  - Ensuring convergence without distributed locks

  The reconciler runs independently on each node, allowing the cluster
  to self-heal without coordination overhead.
  """

  use GenServer
  require Logger

  @reconcile_interval 60_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    schedule_reconciliation()
    {:ok, %{last_reconciliation: nil, reconciliation_count: 0}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    perform_reconciliation()
    schedule_reconciliation()

    {:noreply,
     %{
       state
       | last_reconciliation: System.system_time(:millisecond),
         reconciliation_count: state.reconciliation_count + 1
     }}
  end

  defp schedule_reconciliation do
    Process.send_after(self(), :reconcile, @reconcile_interval)
  end

  defp perform_reconciliation do
    capabilities = Mesh.Cluster.Capabilities.all_capabilities()

    Logger.debug("Running reconciliation for #{length(capabilities)} capabilities")

    # Check each capability independently
    Enum.each(capabilities, fn capability ->
      check_capability_consistency(capability)
    end)
  end

  defp check_capability_consistency(capability) do
    # Check if we're stuck in rebalancing mode
    if stuck_in_rebalancing?(capability) do
      Logger.warning("Capability #{capability} stuck in rebalancing, forcing recovery")
      force_exit_rebalancing_local(capability)
    end

    # Check for orphaned actors
    cleanup_orphaned_actors_for_capability(capability)
  end

  defp stuck_in_rebalancing?(capability) do
    # Check if capability has been in rebalancing mode for too long
    # This is a simple check - could be enhanced with timestamp tracking
    Mesh.Cluster.Rebalancing.rebalancing?(capability)
  end

  defp force_exit_rebalancing_local(capability) do
    Mesh.Cluster.Rebalancing.exit_rebalancing_mode_local([capability])
  end

  defp cleanup_orphaned_actors_for_capability(capability) do
    local_node = node()
    shard_count = Mesh.Shards.ShardConfig.shard_count()

    # Check each shard for this capability
    Enum.each(0..(shard_count - 1), fn shard ->
      case Mesh.Shards.ShardRouter.owner_node(shard, capability) do
        {:ok, owner} when owner != local_node ->
          # We are NOT the owner, check if we have orphaned actors
          orphaned_actors = get_local_actors_for_shard(shard, capability)

          if length(orphaned_actors) > 0 do
            Logger.info(
              "Reconciliation: cleaning up #{length(orphaned_actors)} orphaned actors " <>
                "from shard #{shard}/#{capability} (owner is #{owner})"
            )

            cleanup_actors(orphaned_actors)
          end

        {:ok, ^local_node} ->
          # We are the owner, this is fine
          :ok

        {:error, :no_nodes} ->
          # No owner available yet, keep actors
          :ok
      end
    end)
  end

  defp get_local_actors_for_shard(shard, capability) do
    Mesh.Actors.ActorTable.entries()
    |> Enum.filter(fn {{cap, _module, actor_id}, _pid, actor_node} ->
      actor_node == node() and
        cap == capability and
        Mesh.Shards.ShardRouter.shard_for(actor_id) == shard
    end)
  end

  defp cleanup_actors(actors) do
    Enum.each(actors, fn {actor_key, pid, _node} ->
      if Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :reconciliation)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          3_000 -> Process.exit(pid, :kill)
        end
      end

      Mesh.Actors.ActorTable.delete(actor_key)
    end)
  end
end
