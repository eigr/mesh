# Mesh

**Capability-based distributed actor system for Elixir**

Mesh is a distributed actor system library that enables building scalable, fault-tolerant applications by routing virtual actors across Erlang/Elixir nodes based on capabilities. It uses consistent hashing (hash ring) to deterministically distribute actors across the cluster.

## Table of Contents

- [What is Mesh?](#what-is-mesh)
- [Core Concepts](#core-concepts)
- [Architecture](#architecture)
- [Getting Started](#getting-started)
- [Creating Custom Actors](#creating-custom-actors)
- [API Reference](#api-reference)
- [Cluster Setup](#cluster-setup)
- [Performance](#performance)
- [Development](#development)

## What is Mesh?

Mesh is a lightweight actor framework library that solves the distributed actor placement problem using **capability-based routing**. Unlike traditional actor systems that require manual placement logic or use distributed consensus, Mesh uses a deterministic hash ring to automatically route actors to the correct node.

### Key Features

- **Capability-based routing**: Nodes declare which actor types (capabilities) they can handle, and actors are automatically routed to appropriate nodes
- **Consistent hashing**: Uses a hash ring with 4096 shards for deterministic, balanced actor distribution
- **Virtual actors**: Actors are lazily activated on first invocation (Orleans-style pattern)
- **High performance**: Tested at 16,000+ actors/second creation rate, 30,000+ requests/second
- **Automatic failover**: When nodes fail, their shards are automatically redistributed via the hash ring
- **Zero coordination overhead**: No distributed locks, no leader election, no consensus protocols
- **Library design**: Mesh is a library, not a framework - you control your application's supervision tree

### Use Cases

- **Game servers**: Route players to different game server nodes based on regions or game types
- **Chat systems**: Distribute chat rooms across nodes by capability (public rooms, private messages, group chats)
- **Payment processing**: Separate payment processing from other business logic on dedicated nodes
- **Multi-tenant systems**: Isolate tenants by routing their actors to specific node pools

## Core Concepts

### Capabilities

A **capability** is a label that identifies what type of actors a node can handle. Examples:

```elixir
:game      # Handles game-related actors
:chat      # Handles chat/messaging actors
:payment   # Handles payment processing actors
:analytics # Handles analytics/reporting actors
```

Nodes register the capabilities they support:

```elixir
Mesh.Cluster.Capabilities.register_capabilities([:game, :chat])
```

### Virtual Actors

Virtual actors are actor instances that are **lazily created on demand**. When you invoke an actor that doesn't exist yet, Mesh automatically:

1. Determines which node should own this actor (based on capability and hash ring)
2. Creates the actor on that node
3. Caches the actor's PID in an ETS table for fast lookup
4. Forwards the message and returns the response

This pattern eliminates the need to pre-create actors or manage actor lifecycles manually.

### Hash Ring

Mesh uses a **consistent hash ring** with 4096 shards to distribute actors deterministically:

```
actor_id → hash(actor_id) → shard (0..4095) → owner_node
```

The same `actor_id` always maps to the same shard number. Shards are then distributed across available nodes in a round-robin fashion:

```elixir
shard = :erlang.phash2(actor_id, 4096)
nodes = Mesh.Cluster.Capabilities.nodes_for(capability)
owner_node = Enum.at(nodes, rem(shard, length(nodes)))
```

This ensures:
- **Determinism**: Same actor always goes to same node (until topology changes)
- **Balance**: Actors are evenly distributed across available nodes
- **Minimal disruption**: When nodes join/leave, only affected shards are remapped

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Mesh.Actors.ActorSystem                     │
│                    (Public API)                         │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│               Mesh.Shards.ShardRouter                          │
│  - Computes shard from actor_id                         │
│  - Determines owner node from capability                │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│          Mesh.Cluster.Capabilities                       │
│  - Tracks which nodes support which capabilities        │
│  - Provides node lists for routing decisions            │
└─────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│            :rpc.call(owner_node)                        │
│            Mesh.Actors.ActorOwner.invoke/2                     │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│              Mesh.Actors.ActorOwner                            │
│  - Manages actors for assigned shards                   │
│  - Lazily creates actors on first invocation            │
│  - Caches actor PIDs in Mesh.Actors.ActorTable (ETS)          │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│            Your Custom Actor Module                     │
│  - Custom actor implementation (GenServer)              │
│  - Handles actual business logic                        │
└─────────────────────────────────────────────────────────┘
```

### Data Flow

**Actor Invocation Flow:**

1. **Client calls** `Mesh.Actors.ActorSystem.invoke("player_123", payload, :game)`

2. **ShardRouter** computes the shard:
   ```elixir
   shard = :erlang.phash2("player_123", 4096)  # e.g., shard = 2451
   ```

3. **ShardRouter** determines owner node:
   ```elixir
   nodes = [:node1@host, :node2@host, :node3@host]
   owner = Enum.at(nodes, rem(2451, 3))  # node1@host
   ```

4. **RPC call** to owner node:
   ```elixir
   :rpc.call(:node1@host, Mesh.Actors.ActorOwner, :invoke, ["player_123", payload])
   ```

5. **ActorOwner** checks ETS table:
   - If actor exists → forward message to existing PID
   - If actor doesn't exist → create it under `Mesh.Actors.ActorSupervisor`

6. **Your custom actor** processes message and returns response

7. **Response** flows back through RPC to original caller

### Fault Tolerance

**Actor Failure:**
- Actors are supervised by `DynamicSupervisor`
- When an actor crashes, it's cleaned up from the ETS table
- Next invocation will recreate the actor

**Node Failure:**
- Cluster membership detects node down
- `ActorActorOwnerSupervisor.sync_shards()` is called
- Shards are redistributed to remaining nodes via hash ring
- Actors on failed node are lost (stateless or need persistence)

**Network Partition:**
- System continues operating with available nodes
- When partition heals, shards may be redistributed

## Getting Started

### Installation

Add `mesh` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:mesh, "~> 0.1.0"},
    {:libcluster, "~> 3.3"}  # For cluster discovery
  ]
end
```

### Quick Start

1. **Add Mesh to your supervision tree:**

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    # Configure libcluster topology
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
      # Start Mesh supervisor with cluster config
      {Mesh.Supervisor, topologies: topologies},
      # Your other workers...
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

2. **Define your custom actor:**

```elixir
defmodule MyApp.GameActor do
  use GenServer

  # Your actor must implement start_link/1 that accepts the actor_id
  def start_link(actor_id) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  def init(actor_id) do
    # Initialize your actor state
    {:ok, %{id: actor_id, position: {0, 0}, health: 100}}
  end

  # Handle actor calls via {:actor_call, payload} messages
  def handle_call({:actor_call, %{action: "move", x: x, y: y}}, _from, state) do
    new_state = %{state | position: {x, y}}
    {:reply, {:ok, new_state.position}, new_state}
  end

  def handle_call({:actor_call, payload}, _from, state) do
    # Handle other actions
    {:reply, {:ok, :processed}, state}
  end
end
```

3. **Register capabilities:**

```elixir
# Register what this node can handle
Mesh.register_capabilities([:game, :chat])
```

4. **Invoke actors:**

```elixir
# Invoke with actor module as first parameter
{:ok, pid, response} = Mesh.call(%Mesh.Request{module: MyApp.GameActor, id: "player_123", payload: %{action: "spawn"}, capability: :game})

# Subsequent calls to same actor reuse the PID
{:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MyApp.GameActor, id: "player_123", payload: %{action: "move", capability: x: 10, y: 20}, :game})
```

### Actor Protocol

All actors MUST:
1. Implement `start_link/1` that accepts `actor_id` as the only parameter
2. Handle the `{:actor_call, payload}` message via `GenServer.handle_call/3`
3. Return `{:reply, response, state}` from handle_call (response can be any term)

### Complete Example

See the [example/](example/) directory for a complete working application that demonstrates:
- Custom GameActor and ChatActor implementations
- How to structure your application with Mesh
- Cluster configuration with libcluster
- Automatic capability registration
- Multi-node setup and testing

To run the example:

```bash
cd example
mix deps.get

# Terminal 1
iex --sname node1 --cookie mesh -S mix

# Terminal 2
iex --sname node2 --cookie mesh -S mix
```

## Creating Custom Actors

Mesh allows you to define your own actor implementations with custom business logic.
See the [Custom Actors Guide](docs/CUSTOM_ACTORS.md) for detailed examples including:

- Minimal actor implementation
- Stateful actors with business logic (BankAccount example)
- Actors with persistence (database integration)
- Actors with timers and cleanup (Session management)
- Testing strategies
- Best practices

Quick example:

```elixir
defmodule MyApp.GameActor do
  use GenServer

  def start_link(actor_id) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  def init(actor_id) do
    {:ok, %{id: actor_id, position: {0, 0}, health: 100}}
  end

  def handle_call({:actor_call, %{action: "move", x: x, y: y}}, _from, state) do
    new_state = %{state | position: {x, y}}
    {:reply, {:ok, new_state.position}, new_state}
  end
end
```

Then invoke it:

```elixir
# Actor module is required as first parameter
{:ok, pid, response} = Mesh.call(%Mesh.Request{module: MyApp.GameActor, id: "player_1", payload: %{action: "move", capability: x: 10, y: 20}, :game})
```
- How to structure your application with Mesh
- Cluster configuration with libcluster
- Automatic capability registration
- Multi-node setup and testing

To run the example:

```bash
cd example
mix deps.get

# Terminal 1
iex --sname node1 --cookie mesh -S mix

# Terminal 2
iex --sname node2 --cookie mesh -S mix
```

### Basic Usage (Continued)
iex -S mix

# Register capabilities this node can handle
Mesh.Cluster.Capabilities.register_capabilities([:game, :chat])

# Invoke an actor with your custom actor module
{:ok, actor_pid, response} = 
  Mesh.Actors.ActorSystem.invoke(MyApp.GameActor, "player_123", %{action: "move", x: 10, y: 20}, :game)

# The actor is now cached and subsequent calls are fast
{:ok, ^actor_pid, response2} = 
  Mesh.Actors.ActorSystem.invoke(MyApp.GameActor, "player_123", %{action: "attack"}, :game)
```

### Custom Actor Implementation

Actors are simple GenServer modules that implement a specific protocol:

```elixir
defmodule MyApp.GameActor do
  use GenServer
  require Logger

  def start_link(actor_id) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  def init(actor_id) do
    Logger.info("GameActor #{actor_id} activated")
    {:ok, %{actor_id: actor_id, position: {0, 0}, health: 100}}
  end

  def handle_call({:actor_call, payload}, _from, state) do
    case payload do
      %{action: "move", x: x, y: y} ->
        new_state = %{state | position: {x, y}}
        {:reply, %{status: :ok, position: {x, y}}, new_state}

      %{action: "attack"} ->
        new_state = %{state | health: state.health - 10}
        {:reply, %{status: :ok, health: new_state.health}, new_state}

      _ ->
        {:reply, %{error: :unknown_action}, state}
    end
  end
end
```

Then use it when invoking actors:

```elixir
{:ok, pid, response} = Mesh.call(%Mesh.Request{module: MyApp.GameActor, id: "player_123", payload: %{action: "move", capability: x: 10, y: 20}, :game})
```

## API Reference

### Mesh.Actors.ActorSystem

**`invoke(actor_module, actor_id, payload, capability)`**

Invokes an actor with the given ID on the specified capability.

- **actor_module** (module): The actor module to use (e.g., `MyApp.GameActor`)
- **actor_id** (string): Unique identifier for the actor
- **payload** (map): Data to send to the actor
- **capability** (atom): The capability type (e.g., `:game`, `:chat`)
- **Returns**: `{:ok, pid, response}` or `{:error, reason}`

### Mesh.Cluster.Capabilities

**`register_capabilities(capabilities)`**

Registers capabilities that this node supports.

- **capabilities** (list of atoms): List of capabilities (e.g., `[:game, :chat]`)

**`nodes_for(capability)`**

Returns list of nodes that support the given capability.

**`all_capabilities()`**

Returns all unique capabilities registered across the cluster.

### Mesh.Shards.ShardRouter

**`shard_for(actor_id)`**

Computes the shard number for an actor ID.

- **actor_id** (string): Actor identifier
- **Returns**: Integer from 0 to 4095

**`owner_node(shard, capability)`**

Determines which node owns the given shard for a capability.

- **shard** (integer): Shard number
- **capability** (atom): Capability type
- **Returns**: Node atom

## Cluster Setup

### Single-Node Development

```elixir
# config/dev.exs
import Config

config :libcluster,
  topologies: []

# Start node
iex -S mix
iex> Mesh.Cluster.Capabilities.register_capabilities([:game, :chat, :payment])
```

### Multi-Node Cluster (Gossip)

```elixir
# config/runtime.exs
import Config

config :libcluster,
  topologies: [
    gossip: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_addr: "230.1.1.251",
        multicast_ttl: 1,
        secret: "mesh_cluster_secret"
      ]
    ]
  ]
```

Start multiple nodes:

```bash
# Terminal 1 - Game server
iex --sname game@localhost --cookie mesh -S mix
iex> Mesh.Cluster.Capabilities.register_capabilities([:game])

# Terminal 2 - Chat server
iex --sname chat@localhost --cookie mesh -S mix
iex> Mesh.Cluster.Capabilities.register_capabilities([:chat])

# Terminal 3 - Payment server
iex --sname payment@localhost --cookie mesh -S mix
iex> Mesh.Cluster.Capabilities.register_capabilities([:payment])

# Terminal 4 - All-purpose server
iex --sname mixed@localhost --cookie mesh -S mix
iex> Mesh.Cluster.Capabilities.register_capabilities([:game, :chat, :payment])
```

Verify cluster:

```elixir
iex> Node.list()
[:chat@localhost, :payment@localhost, :mixed@localhost]

iex> Mesh.Cluster.Capabilities.nodes_for(:game)
[:game@localhost, :mixed@localhost]
```

### Production Deployment (Kubernetes)

```elixir
# config/runtime.exs
config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: "mesh-headless",
        application_name: "mesh",
        kubernetes_namespace: "default"
      ]
    ]
  ]
```

## Performance

### Benchmarks

See [scripts/README.md](scripts/README.md) for detailed benchmark documentation.

**Single-Node Performance:**
- **Actor creation rate**: 16,428 actors/second
- **Invocation throughput**: 30,558 requests/second
- **Hot spot (same actor)**: 10,000 requests in 0.84s (11,904 req/s)
- **P50 latency**: 15-30 microseconds
- **P95 latency**: 60-95 microseconds
- **P99 latency**: 100-150 microseconds
- **Memory per actor**: ~11 KB
- **Tested scale**: 85,000 concurrent actors (943 MB total memory)

**Multi-Node Performance (4 nodes):**
- **Distributed creation**: 9,645 actors/second
- **Cross-node RPC latency**: ~150 microseconds
- **Hash ring distribution**: 99-100% balanced across nodes
- **Resilience**: 100% success rate after node failure

### Running Benchmarks

```bash
# Single-node stress test (50k actors)
mix run scripts/benchmark_singlenode.exs

# Multi-node distributed test (requires named node)
elixir --name bench@127.0.0.1 --cookie mesh -S mix run scripts/benchmark_multinode.exs

# Statistical analysis with Benchee
mix run scripts/benchee_benchmark.exs
```

### Performance Tuning

**ETS Table Configuration:**
- Uses `:set` type with `:public` access
- `:read_concurrency` enabled for fast lookups
- Local to each node (not replicated)

**RPC Timeout:**
- Default: 5000ms
- Configurable per call
- Consider network latency in distributed deployments

**Shard Count:**
- Default: 4096 shards
- Higher count = better balance, more memory
- Lower count = less memory, potential hotspots
- Configured in `Mesh.Shards.ShardConfig.shard_count/0`

## Development

### Using Make (Recommended)

The project includes a comprehensive Makefile for easy development:

```bash
# Show all available commands
make help

# Quick start
make all          # Install deps, compile, and test
make dev          # Start development with IEx
make test         # Run tests
make format       # Format code
make check        # Run format check + tests

# Benchmarks
make benchmark              # Run single-node benchmark
make benchmark-benchee      # Run detailed Benchee benchmark
make benchmark-multi        # Run multi-node benchmark

# Example application
make example-shell          # Start example in IEx
make example-node1          # Start example node 1
make example-node2          # Start example node 2 (in another terminal)

# Documentation
make docs                   # Generate docs
make docs-open              # Generate and open docs

# Code quality
make format-check           # Check formatting
make lint                   # Run static analysis (requires credo)
make dialyzer              # Run dialyzer (requires dialyxir)

# Project info
make info                   # Show project information
```

### Project Structure

```
mesh/
├── lib/
│   └── mesh/
│       ├── application.ex          # Application supervisor
│       ├── actor_system.ex         # Public API
│       ├── shard_router.ex         # Hash ring routing
│       ├── cluster_capabilities.ex # Capability tracking
│       ├── actor_owner.ex          # Shard owner (manages actors)
│       ├── actor_owner_supervisor.ex # Dynamic supervisor for owners
│       ├── actor_supervisor.ex     # Dynamic supervisor for actors
│       ├── virtual_actor.ex        # Default actor implementation
│       ├── actor_table.ex          # ETS table wrapper
│       ├── cluster_membership.ex   # Node up/down tracking
│       ├── shard_config.ex         # Configuration
│       └── shard.ex                # Shard utilities
├── scripts/
│   ├── benchmark_singlenode.exs    # Single-node benchmarks
│   ├── benchmark_multinode.exs     # Multi-node benchmarks
│   ├── benchee_benchmark.exs       # Statistical benchmarks
│   └── README.md                   # Benchmark documentation
├── test/
│   ├── scalability_test.exs        # Performance tests
│   └── distributed_scalability_test.exs # Hash ring tests
└── mix.exs
```

### Manual Commands (Alternative to Make)

If you prefer not to use Make:

```bash
# Get dependencies
mix deps.get

# Compile
mix compile

# Run tests
mix test

# Format code
mix format

# Check code quality (if credo is installed)
mix credo
```

### Debug Mode

```elixir
# Enable verbose logging
Logger.configure(level: :debug)

# Inspect cluster state
iex> Mesh.Cluster.Capabilities.all_capabilities()
[:game, :chat, :payment]

iex> Mesh.Cluster.Capabilities.nodes_for(:game)
[:node1@host, :node2@host]

# Inspect actor table
iex> :ets.info(Mesh.Actors.ActorTable)
[size: 12500, memory: 487500, ...]

# List all actors
iex> :ets.tab2list(Mesh.Actors.ActorTable)
[{"actor_1", #PID<0.123.0>, :node1@host}, ...]
```

### Troubleshooting

**Actors not being created:**
- Check that capabilities are registered: `Mesh.Cluster.Capabilities.nodes_for(:game)`
- Verify node connectivity: `Node.list()`
- Check logs for RPC errors

**Unbalanced distribution:**
- Verify all nodes have same shard count configuration
- Check that nodes are registered with correct capabilities
- Monitor shard ownership: look for nodes claiming too many/few shards

**High latency:**
- Check network latency between nodes
- Monitor ETS table size (millions of entries may impact performance)
- Consider actor caching strategies

**Memory usage:**
- Each actor consumes ~11 KB
- Monitor with `:erlang.memory()` and `:observer.start()`
- Consider actor garbage collection/passivation for long-lived systems

## License

MIT

## Credits

Built by [Eigr Labs](https://github.com/eigr-labs)

Inspired by:
- [Microsoft Orleans](https://github.com/dotnet/orleans) - Virtual actor model
- [Akka Cluster Sharding](https://doc.akka.io/docs/akka/current/typed/cluster-sharding.html) - Shard distribution
- [Dapr Actors](https://docs.dapr.io/developing-applications/building-blocks/actors/) - Actor abstraction
