# Mesh

Capability-based distributed process management for Elixir.

Mesh distributes GenServer processes across BEAM nodes using consistent hashing and capability-based routing. Processes are lazily activated on-demand and automatically placed on the correct node based on their ID and capability type.

## What is Mesh?

Mesh solves the distributed process placement problem. Instead of manually managing where processes run, you define capabilities (like `:game`, `:chat`, `:payment`) and let Mesh handle the routing using a hash ring with 4096 shards.

Key characteristics:

- Deterministic placement: Same ID always routes to same node
- Lazy activation: Processes created on first invocation
- Zero coordination: No distributed locks or consensus
- High throughput: 16,000+ process creations/s, 30,000+ requests/s
- Library design: You control your supervision tree

Use cases: game servers with regional routing, multi-tenant systems with workload isolation, microservice patterns where different node types handle different request types.

## Core Concepts

Capabilities are labels that identify what type of processes a node handles. Examples: `:game`, `:chat`, `:payment`. Nodes register supported capabilities, and Mesh routes requests accordingly.

```elixir
Mesh.register_capabilities([:game, :chat])
```

The hash ring uses consistent hashing with 4096 shards to distribute processes:

```
process_id → hash(process_id) → shard (0..4095) → owner_node
```

Same ID always maps to the same shard. Shards are distributed round-robin across nodes supporting the capability. When topology changes, only affected shards remap.

Processes are created lazily on first invocation. When you call a non-existent process, Mesh:
1. Determines target node via hash ring
2. Starts the process on that node
3. Caches the PID for fast subsequent lookups
4. Forwards the message and returns the response

This eliminates manual lifecycle management.

## Quick Start

Add to `mix.exs`:

```elixir
def deps do
  [
    {:mesh, "~> 0.1.0"},
    {:libcluster, "~> 3.3"}
  ]
end
```

Start Mesh in your application:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    topologies = [
      gossip: [
        strategy: Cluster.Strategy.Gossip,
        config: [port: 45892, if_addr: "0.0.0.0"]
      ]
    ]

    children = [
      {Mesh.Supervisor, topologies: topologies}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Define a GenServer:

```elixir
defmodule MyApp.Counter do
  use GenServer

  def start_link(process_id) do
    GenServer.start_link(__MODULE__, process_id)
  end

  def init(process_id) do
    {:ok, %{id: process_id, count: 0}}
  end

  def handle_call({:actor_call, _payload}, _from, state) do
    new_count = state.count + 1
    {:reply, {:ok, new_count}, %{state | count: new_count}}
  end
end
```

Register capabilities and invoke:

```elixir
Mesh.register_capabilities([:counter])

{:ok, pid, result} = Mesh.call(%Mesh.Request{
  module: MyApp.Counter,
  id: "counter_1",
  payload: %{},
  capability: :counter
})
```

## API

`Mesh.call/1` - Synchronous invocation

```elixir
{:ok, pid, response} = Mesh.call(%Mesh.Request{
  module: MyApp.Counter,
  id: "counter_1",
  payload: %{action: :increment},
  capability: :counter
})
```

`Mesh.cast/1` - Fire-and-forget invocation

```elixir
:ok = Mesh.cast(%Mesh.Request{
  module: MyApp.Counter,
  id: "counter_1",
  payload: %{action: :reset},
  capability: :counter
})
```

`Mesh.register_capabilities/1` - Register supported capabilities

```elixir
Mesh.register_capabilities([:game, :chat, :payment])
```

## Cluster Setup

Single-node development:

```elixir
iex -S mix
iex> Mesh.register_capabilities([:game, :chat])
```

Multi-node with Gossip:

```bash
# Terminal 1
iex --sname game@localhost --cookie mesh -S mix
iex> Mesh.register_capabilities([:game])

# Terminal 2
iex --sname chat@localhost --cookie mesh -S mix
iex> Mesh.register_capabilities([:chat])
```

Kubernetes deployment:

```elixir
config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: "mesh-headless",
        application_name: "mesh"
      ]
    ]
  ]
```

## Performance

Run benchmarks:

```bash
mix run scripts/benchmark_singlenode.exs
elixir --name bench@127.0.0.1 --cookie mesh -S mix run scripts/benchmark_multinode.exs
```

## Development

Using Make:

```bash
make help          # Show all commands
make all           # Install, compile, test
make dev           # Start IEx session
make test          # Run tests
make benchmark     # Run single-node benchmark
```