defmodule Mesh.Shards.ShardRouter do
  @moduledoc """
  Routes actors to nodes based on consistent hashing (hash ring).
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
  """
  @spec owner_node(non_neg_integer(), atom()) :: {:ok, node()} | {:error, :no_nodes}
  def owner_node(shard, capability) do
    nodes = Mesh.Cluster.Capabilities.nodes_for(capability)
    nodes = Enum.sort(nodes)

    if nodes == [] do
      {:error, :no_nodes}
    else
      idx = rem(shard, length(nodes))
      {:ok, Enum.at(nodes, idx)}
    end
  end
end
