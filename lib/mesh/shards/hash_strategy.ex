defmodule Mesh.Shards.HashStrategy do
  @moduledoc """
  Behavior for shard hashing strategies.

  Allows different implementations of hashing algorithms to be used for
  distributing actors across nodes.

  The default implementation uses modulo-based distribution (EventualConsistency).
  You can implement your own strategy by implementing this behavior.

  ## Configuration

      config :mesh, :hash_strategy, Mesh.Shards.HashStrategy.EventualConsistency

  ## Custom Implementation

  To create a custom strategy:

      defmodule MyApp.CustomHashStrategy do
        @behaviour Mesh.Shards.HashStrategy

        @impl true
        def owner_node(shard, _capability, nodes) do
          # Your custom logic here
          Enum.at(nodes, rem(shard, length(nodes)))
        end
      end

  Then configure it:

      config :mesh, :hash_strategy, MyApp.CustomHashStrategy
  """

  @doc """
  Determines which node should own a given shard for a specific capability.

  ## Parameters
  - `shard` - The shard number (0 to shard_count - 1)
  - `capability` - The capability atom
  - `nodes` - Sorted list of nodes that support this capability

  ## Returns
  - `node()` - The node that should own this shard
  """
  @callback owner_node(shard :: non_neg_integer(), capability :: atom(), nodes :: [node()]) ::
              node()
end
