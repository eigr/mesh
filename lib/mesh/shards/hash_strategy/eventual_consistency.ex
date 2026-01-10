defmodule Mesh.Shards.HashStrategy.EventualConsistency do
  @moduledoc """
  Eventual consistency hash strategy using modulo distribution.

  Distributes shards across nodes using `rem(shard, node_count)`. When nodes are added
  or removed, ownership changes cause the same process ID to temporarily exist on multiple
  nodes until the system converges (eventual consistency).

  This is the default strategy.
  """

  @behaviour Mesh.Shards.HashStrategy

  @impl true
  def owner_node(shard, _capability, nodes) do
    idx = rem(shard, length(nodes))
    Enum.at(nodes, idx)
  end
end
