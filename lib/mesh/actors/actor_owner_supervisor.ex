defmodule Mesh.Actors.ActorOwnerSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Synchronizes local shards based on registered capabilities.
  """
  def sync_shards do
    local_node = node()
    shard_count = Mesh.Shards.ShardConfig.shard_count()
    capabilities = Mesh.Cluster.Capabilities.all_capabilities()

    # For each shard, check if the local node is owner for ANY capability
    Enum.each(0..(shard_count - 1), fn shard ->
      is_owner_for_any_capability? =
        Enum.any?(capabilities, fn capability ->
          case Mesh.Shards.ShardRouter.owner_node(shard, capability) do
            {:ok, owner} -> owner == local_node
            {:error, _} -> false
          end
        end)

      if is_owner_for_any_capability? do
        ensure_owner_started(shard)
      else
        ensure_owner_stopped(shard)
      end
    end)
  end

  defp ensure_owner_started(shard) do
    case Registry.lookup(ActorOwnerRegistry, shard) do
      [] ->
        spec = {Mesh.Actors.ActorOwner, shard}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          err -> Logger.error("Failed to start ActorOwner for shard #{shard}: #{inspect(err)}")
        end

      _ ->
        :ok
    end
  end

  defp ensure_owner_stopped(shard) do
    case Registry.lookup(ActorOwnerRegistry, shard) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end
end
