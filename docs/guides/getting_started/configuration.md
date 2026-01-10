# Configuration

This guide covers Mesh configuration options and how to customize the system for your use case.

## Basic Configuration

Configure Mesh in `config/config.exs`:

```elixir
config :mesh,
  shards: 4096
```

## Hash Strategy

Mesh uses a hash strategy to determine which node owns each shard. The default strategy is **EventualConsistency**, which uses modulo-based routing for simple and fast process placement.

### Default Strategy: EventualConsistency

The default strategy distributes shards using modulo arithmetic:

```elixir
# This is the default, you don't need to configure it
config :mesh,
  shards: 4096,
  hash_strategy: Mesh.Shards.HashStrategy.EventualConsistency
```

**Characteristics:**
- **Simple**: Direct modulo calculation (`shard % node_count`)
- **Fast**: No external dependencies or complex data structures
- **Deterministic**: Same shard always maps to same node (given same topology)
- **Eventually consistent**: During topology changes, processes may temporarily exist on multiple nodes

**When to use:**
- Most production deployments
- When you need predictable performance
- When node count changes infrequently
- When you can tolerate temporary inconsistency during rebalancing

### Custom Hash Strategy

You can implement your own hash strategy by creating a module that implements the `Mesh.Shards.HashStrategy` behavior:

```elixir
defmodule MyApp.CustomHashStrategy do
  @behaviour Mesh.Shards.HashStrategy

  @impl true
  def owner_node(shard, capability, nodes) do
    # Your custom logic here
    # Must return the owner node for the given shard
    
    # Example: weighted distribution
    total_weight = length(nodes) * 10
    weighted_index = rem(shard * 7, total_weight) # Use prime multiplier
    node_index = div(weighted_index, 10)
    
    Enum.at(nodes, node_index)
  end
end
```

Then configure Mesh to use your strategy:

```elixir
config :mesh,
  shards: 4096,
  hash_strategy: MyApp.CustomHashStrategy
```

### Strategy Contract

The `Mesh.Shards.HashStrategy` behavior requires implementing one callback:

```elixir
@callback owner_node(
  shard :: non_neg_integer(),
  capability :: atom(),
  nodes :: [node()]
) :: node()
```

**Parameters:**
- `shard`: The shard number (0 to `shards - 1`)
- `capability`: The capability being requested (e.g., `:game`, `:chat`)
- `nodes`: List of available nodes that support the capability

**Returns:**
- The node that should own this shard

### Example: Region-Aware Strategy

Here's an example that routes shards based on geographic regions:

```elixir
defmodule MyApp.RegionAwareStrategy do
  @behaviour Mesh.Shards.HashStrategy

  @impl true
  def owner_node(shard, capability, nodes) do
    # Get node regions from application config
    regions = Application.get_env(:my_app, :node_regions, %{})
    
    # Determine preferred region based on shard
    preferred_region = case rem(shard, 3) do
      0 -> :us_east
      1 -> :us_west
      2 -> :eu_west
    end
    
    # Filter nodes by preferred region
    regional_nodes = Enum.filter(nodes, fn node ->
      Map.get(regions, node) == preferred_region
    end)
    
    # Fall back to all nodes if no regional nodes available
    available_nodes = if regional_nodes == [], do: nodes, else: regional_nodes
    
    # Use modulo within the filtered nodes
    Enum.at(available_nodes, rem(shard, length(available_nodes)))
  end
end
```

Configuration:

```elixir
config :mesh,
  shards: 4096,
  hash_strategy: MyApp.RegionAwareStrategy

config :my_app,
  node_regions: %{
    :"game1@us-east" => :us_east,
    :"game2@us-west" => :us_west,
    :"game3@eu-west" => :eu_west
  }
```

### Example: Capability-Specific Strategy

Route different capabilities using different strategies:

```elixir
defmodule MyApp.CapabilityBasedStrategy do
  @behaviour Mesh.Shards.HashStrategy

  @impl true
  def owner_node(shard, capability, nodes) do
    case capability do
      # Critical capabilities: use first N nodes for better isolation
      capability when capability in [:payment, :auth] ->
        critical_nodes = Enum.take(nodes, min(2, length(nodes)))
        Enum.at(critical_nodes, rem(shard, length(critical_nodes)))
      
      # Regular capabilities: distribute across all nodes
      _ ->
        Enum.at(nodes, rem(shard, length(nodes)))
    end
  end
end
```

## Shard Count

The number of shards determines the granularity of process distribution:

```elixir
config :mesh,
  shards: 4096  # Default
```

**Guidelines:**

| Cluster Size | Recommended Shards | Distribution |
|--------------|-------------------|--------------|
| 2-4 nodes    | 2048-4096        | Good         |
| 5-10 nodes   | 4096-8192        | Excellent    |
| 10+ nodes    | 8192-16384       | Optimal      |

**Trade-offs:**
- **More shards**: Better distribution, more memory overhead
- **Fewer shards**: Less memory, coarser distribution

⚠️ **Warning**: Changing shard count in production will remap all processes. Plan this during maintenance windows.

## Clustering

Mesh integrates with `libcluster` for automatic node discovery:

```elixir
config :libcluster,
  topologies: [
    gossip: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_if: "0.0.0.0"
      ]
    ]
  ]
```

Pass topologies to Mesh supervisor:

```elixir
children = [
  {Mesh.Supervisor, topologies: Application.get_env(:libcluster, :topologies)}
]
```

### Kubernetes

For Kubernetes deployments:

```elixir
config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: "mesh-headless",
        application_name: "mesh",
        polling_interval: 10_000
      ]
    ]
  ]
```

## Best Practices

1. **Choose strategy based on needs**
   - Default `EventualConsistency` works many use cases
   - Custom strategies for special routing requirements (regions, isolation, strong consistency)

2. **Keep it simple**
   - Complex strategies can introduce performance bottlenecks
   - Test thoroughly before deploying custom strategies

3. **Document your strategy**
   - If using custom strategy, document why and how it works
   - Include expected behavior during topology changes

4. **Monitor distribution**
   - Track process distribution across nodes
   - Watch for hot spots or imbalances

5. **Plan for growth**
   - Choose shard count based on expected cluster size
   - Consider overhead of rebalancing when changing configuration

## Next Steps

- Learn about [Sharding](../advanced/sharding.md) internals
- Explore [Clustering](clustering.md) for multi-node setup
- See [Processes](../advanced/processes.md) for implementing actors
