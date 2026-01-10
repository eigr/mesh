defmodule Mesh.Shards.ShardRouter do
  @moduledoc """
  Routes processes to nodes based on hashing (hash ring).

  The hashing strategy is configurable via application config:

      config :mesh, :hash_strategy, Mesh.Shards.HashStrategy.EventualConsistency

  The default strategy uses modulo-based distribution for deterministic routing.
  """

  @doc """
  Computes the shard number for a given actor ID.
  """
  @spec shard_for(String.t()) :: non_neg_integer()
  def shard_for(actor_id) do
    :erlang.phash2(actor_id, Mesh.Shards.ShardConfig.shard_count())
  end

  @doc """
  Determines which node owns a given shard for a specific capability.

  Returns `{:ok, node}` if nodes are available for the capability,
  or `{:error, :no_nodes}` if no nodes support the capability.

  The specific distribution algorithm is determined by the configured hash strategy.
  """
  @spec owner_node(non_neg_integer(), atom()) :: {:ok, node()} | {:error, :no_nodes}
  def owner_node(shard, capability) do
    nodes = Mesh.Cluster.Capabilities.nodes_for(capability)
    nodes = Enum.sort(nodes)

    if nodes == [] do
      {:error, :no_nodes}
    else
      strategy =
        Application.get_env(:mesh, :hash_strategy, Mesh.Shards.HashStrategy.EventualConsistency)

      node = strategy.owner_node(shard, capability, nodes)
      {:ok, node}
    end
  end
end
