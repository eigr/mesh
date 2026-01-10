# Sharding

Mesh uses hashing to distribute processes across nodes in a cluster.

## Hash Ring

Mesh divides the actor ID space into 4096 shards (configurable) using a hash ring:

```
actor_id → hash(actor_id) → shard (0..4095) → owner_node
```

The hash strategy determines how shards map to nodes. The default strategy uses modulo-based routing for simplicity and performance.

### How It Works

1. **Hash the actor ID**:
   ```elixir
   shard = :erlang.phash2(actor_id, 4096)
   # "player_123" → 2451
   ```

2. **Get nodes for capability**:
   ```elixir
   nodes = Mesh.Cluster.Capabilities.nodes_for(:game)
   # [:node1@host, :node2@host, :node3@host]
   ```

3. **Determine owner** (using default EventualConsistency strategy):
   ```elixir
   owner = Enum.at(nodes, rem(shard, length(nodes)))
   # Enum.at(nodes, rem(2451, 3)) → node1@host
   ```

> **Note**: You can customize the hash strategy to implement different routing algorithms. See [Configuration](../getting_started/configuration.md) for details.

## Benefits

### Deterministic Placement

The same `actor_id` always maps to the same node (until topology changes):

```elixir
# These will always go to the same node
Mesh.call(%Mesh.Request{module: GameActor, id: "player_123", payload: payload, capability: :game})  # → node1
Mesh.call(%Mesh.Request{module: GameActor, id: "player_123", payload: payload, capability: :game})  # → node1
Mesh.call(%Mesh.Request{module: GameActor, id: "player_123", payload: payload, capability: :game})  # → node1
```

### Load Distribution

Processes are evenly distributed across available nodes:

```elixir
# 100,000 processes distributed across 3 nodes
for i <- 1..100_000 do
  Mesh.call(%Mesh.Request{module: GameActor, id: "actor_#{i}", payload: payload, capability: :game})
end

# Result: ~33,333 processes per node
```

### Minimal Disruption

When nodes join or leave, only affected shards are remapped:

- **3 nodes → 4 nodes**: ~25% of processes move
- **4 nodes → 3 nodes**: ~25% of processes move
- **2 nodes → 3 nodes**: ~33% of processes move

## Configuration

Configure the number of shards in `config/config.exs`:

```elixir
config :mesh, shards: 4096
```

### Choosing Shard Count

- **Default: 4096** - Good for most use cases
- **Higher (8192+)**: Better distribution with many nodes (10+)
- **Lower (2048)**: Less memory overhead for small clusters (2-4 nodes)

## Shard Distribution

Check how processes are distributed:

```elixir
# Get shard for a process
shard = Mesh.shard_for("player_123")

# Get owner node for a shard
{:ok, node} = Mesh.owner_node(shard, :game)
```

## Monitoring Distribution

Track shard distribution in production:

```elixir
defmodule MyApp.ShardMonitor do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check, state) do
    # Get all shards owned by this node
    local_node = node()
    shard_count = Mesh.Shards.ShardConfig.shard_count()
    capabilities = Mesh.all_capabilities()
    
    owned_shards = 
      for shard <- 0..(shard_count - 1),
          capability <- capabilities,
          {:ok, owner} = Mesh.owner_node(shard, capability),
          owner == local_node do
        {shard, capability}
      end
    
    IO.puts("Node #{local_node} owns #{length(owned_shards)} shards")
    
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check, 60_000)  # Every minute
  end
end
```

## Best Practices

1. **Don't change shard count in production**: Changing it remaps all processes
2. **Monitor distribution**: Track processes per node to detect imbalances
3. **Plan for growth**: Choose shard count based on expected cluster size
4. **Use capabilities wisely**: Group related processes under same capability
5. **Test rebalancing**: Verify behavior when nodes join/leave

## Example Distribution

With 3 nodes and 4096 shards:

```
Node 1: Shards 0, 3, 6, 9, ...     (~1365 shards)
Node 2: Shards 1, 4, 7, 10, ...    (~1365 shards)
Node 3: Shards 2, 5, 8, 11, ...    (~1366 shards)
```

When creating 100k processes:

```
Node 1: ~33,333 processes
Node 2: ~33,333 processes
Node 3: ~33,334 processes
```

## Troubleshooting

### Uneven Distribution

If you see uneven distribution:

1. **Check actor ID patterns**: Avoid sequential IDs, use UUIDs or hashed values
2. **Increase shard count**: More shards = better distribution
3. **Verify node availability**: Ensure all nodes are properly connected

### Hot Spots

If specific processes get too many requests:

1. **Split the process**: Divide state across multiple processes
2. **Use caching**: Cache read-heavy data outside processes
3. **Add read replicas**: Create read-only copies for popular processes
