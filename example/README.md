# Mesh Example

Example application demonstrating how to use the Mesh distributed actor system library.

## Structure

```
example/
├── config/          # Application configuration
│   ├── config.exs   # Main config with libcluster topology and default actor
│   ├── dev.exs      # Development config
│   └── runtime.exs  # Runtime config
├── lib/
│   ├── mesh_example/
│   │   ├── application.ex          # Application entry point
│   │   ├── capability_registrar.ex # Auto-registers node capabilities
│   │   ├── game_actor.ex           # Custom GameActor implementation
│   │   └── chat_actor.ex           # Custom ChatActor implementation
│   └── mesh_example.ex             # Documentation and examples
└── mix.exs          # Project definition with Mesh dependency
```

## Custom Actors

This example includes two custom actor implementations:

### GameActor

Manages player state including position, health, and inventory:

```elixir
# Spawn a player
{:ok, pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "spawn", capability: name: "Alice"}, :game})

# Move player
{:ok, pid, _} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "move", capability: x: 10, y: 20}, :game})

# Take damage
{:ok, pid, _} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "take_damage", capability: amount: 25}, :game})

# Add item
{:ok, pid, _} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "add_item", capability: item: "sword"}, :game})
```

### ChatActor

Manages chat room state with participants and message history:

```elixir
# Join room
{:ok, pid, _} = Mesh.call(%Mesh.Request{module: MeshExample.ChatActor, id: "room_general", payload: %{action: "join", capability: user: "Alice"}, :chat})

# Send message
{:ok, pid, _} = Mesh.call(%Mesh.Request{module: MeshExample.ChatActor, id: "room_general", payload: %{action: "send_message", capability: user: "Alice", message: "Hello!"}, :chat})

# Get messages
{:ok, pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.ChatActor, id: "room_general", payload: %{action: "get_messages", capability: limit: 10}, :chat})
```

## Running the Example

### Single Node

```bash
cd example
mix deps.get
iex --sname node1 --cookie mesh -S mix
```

### Multi-Node Cluster

Open multiple terminals and run:

```bash
# Terminal 1
cd example
iex --sname node1 --cookie mesh -S mix

# Terminal 2
cd example
iex --sname node2 --cookie mesh -S mix

# Terminal 3
cd example
iex --sname node3 --cookie mesh -S mix
```

The nodes will automatically discover each other using libcluster's Gossip strategy.

## Usage Examples

### Using GameActor

```elixir
# Spawn a player
{:ok, pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "spawn", capability: name: "Alice"}, :game})
# => %{status: :spawned, player: "Alice", position: {0, 0}}

# Move player
{:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "move", capability: x: 10, y: 20}, :game})
# => %{status: :moved, position: {10, 20}}

# Player takes damage
{:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "take_damage", capability: amount: 25}, :game})
# => %{status: :alive, health: 75}

# Add item to inventory
{:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "add_item", capability: item: "sword"}, :game})
# => %{status: :item_added, inventory: ["sword"]}

# Get full player state
{:ok, ^pid, state} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "get_state"}, capability: :game})
```

### Using ChatActor

```elixir
# Join a chat room
{:ok, pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.ChatActor, id: "room_general", payload: %{action: "join", capability: user: "Alice"}, :chat})
# => %{status: :joined, room: "room_general", participants: ["Alice"]}

# Send a message
{:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: 
  MeshExample.ChatActor, id: "room_general", payload: %{action: "send_message", capability: user: "Alice", message: "Hello!"},
  :chat
})

# Get message history
{:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: 
  MeshExample.ChatActor, id: "room_general", payload: %{action: "get_messages", capability: limit: 10},
  :chat
})

# Another user joins
{:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.ChatActor, id: "room_general", payload: %{action: "join", capability: user: "Bob"}, :chat})
```

### Cluster Operations

```elixir
# Check cluster status
Node.list()
Mesh.all_capabilities()
Mesh.nodes_for(:game)

# Check actor placement
shard = Mesh.shard_for("player_123")
{:ok, owner} = Mesh.owner_node(shard, :game)
IO.puts("Actor player_123 is on #{owner}")
```

## Customization

### Create Your Own Actor

```elixir
defmodule MyApp.CustomActor do
  use GenServer

  # Must implement start_link/1 that accepts actor_id
  def start_link(actor_id) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  def init(actor_id) do
    # Your initialization logic
    {:ok, %{id: actor_id, custom_state: :initial}}
  end

  # Must handle {:actor_call, payload} messages
  def handle_call({:actor_call, payload}, _from, state) do
    # Your business logic here
    {:reply, {:ok, :processed}, state}
  end
end
```

### Change Capabilities

Edit `lib/mesh_example/capability_registrar.ex`:

```elixir
capabilities = [:game, :chat, :payment]  # Add your capabilities
```

### Configure Cluster Strategy

Edit `config/config.exs` to use different libcluster strategies:

```elixir
# For Kubernetes
config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes,
      config: [
        kubernetes_selector: "app=mesh",
        kubernetes_node_basename: "mesh"
      ]
    ]
  ]

# For EPMD
config :libcluster,
  topologies: [
    epmd: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:node1@host, :node2@host]]
    ]
  ]
```

### Adjust Shard Count

Edit `config/config.exs`:

```elixir
config :mesh,
  shards: 8192  # Increase for larger clusters
```

## Integration into Your Application

To use Mesh in your own application:

1. Add Mesh as a dependency in `mix.exs`:

```elixir
defp deps do
  [
    {:mesh, "~> 0.1.0"},
    {:libcluster, "~> 3.3"}
  ]
end
```

2. Start Mesh in your supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      {Mesh.Supervisor, topologies: topologies},
      # Your other workers...
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

3. Register capabilities:

```elixir
Mesh.register_capabilities([:game, :chat])
```

4. Invoke actors:

```elixir
{:ok, pid, response} = Mesh.call(%Mesh.Request{module: MyApp.CustomActor, id: "actor_id", payload: %{data: "payload"}, capability: :game})
```

## See Also

- [Mesh Documentation](../README.md)
- [Benchmarks](../scripts/README.md)
