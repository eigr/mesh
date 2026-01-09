# Clustering

Mesh uses capabilities to route processes to appropriate nodes in a cluster.

## Setup libcluster

For multi-node setups, configure libcluster in your application:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    topologies = [
      gossip: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: 45892,
          if_addr: "0.0.0.0",
          multicast_addr: "230.1.1.251",
          multicast_ttl: 1
        ]
      ]
    ]

    children = [
      # Start libcluster for node discovery
      {Cluster.Supervisor, [topologies, [name: MyApp.ClusterSupervisor]]},
      # Start Mesh
      Mesh.Supervisor,
      # Your workers...
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Capabilities

Capabilities identify what types of processes a node can handle. Examples:

- `:game` - Game-related processes
- `:chat` - Chat/messaging processes
- `:payment` - Payment processing processes

### Register Capabilities

Tell Mesh what this node can handle:

```elixir
Mesh.register_capabilities([:game, :chat])
```

You can do this in your application start or in a dedicated worker:

```elixir
defmodule MyApp.CapabilityRegistrar do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    # Register capabilities when the node starts
    Mesh.register_capabilities([:game, :chat])
    {:ok, nil}
  end
end
```

## Routing

Mesh automatically routes process invocations to nodes that support the requested capability:

```elixir
# This will be routed to a node with :game capability
{:ok, pid, _} = Mesh.call(%Mesh.Request{module: GameActor, id: "player_1", payload: payload, capability: :game})

# This will be routed to a node with :chat capability
{:ok, pid, _} = Mesh.call(%Mesh.Request{module: ChatActor, id: "room_1", payload: payload, capability: :chat})
```

## Multi-Node Example

### Node 1 - Game Server

```elixir
# On node1@host
Mesh.register_capabilities([:game])
```

### Node 2 - Chat Server

```elixir
# On node2@host
Mesh.register_capabilities([:chat])
```

### Node 3 - Universal

```elixir
# On node3@host
Mesh.register_capabilities([:game, :chat, :payment])
```

Now processes will be automatically distributed:
- Game processes go to node1 or node3
- Chat processes go to node2 or node3
- Payment processes only go to node3

## Node Discovery Strategies

Mesh is agnostic about how nodes discover each other. Use libcluster strategies:

- **Gossip**: Local network multicast
- **Kubernetes**: K8s service discovery
- **EPMD**: Static node list
- **DNS**: DNS-based discovery

See [libcluster documentation](https://hexdocs.pm/libcluster) for more strategies.
