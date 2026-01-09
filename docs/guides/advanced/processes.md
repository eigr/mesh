# Implementing Processes

This guide explains how to implement processes for Mesh and how they work within the system.

## The Protocol

Mesh expects a simple GenServer that follows these conventions:

1. Implement `start_link/1` - Receives the `actor_id` as parameter
2. Handle messages via `handle_call/3` with your own pattern matching
3. Return `{:reply, result, state}` - Standard GenServer response

That's it. No behaviors, no macros, just a GenServer.

## Basic Example

```elixir
defmodule MyApp.Counter do
  use GenServer

  # Required: accept actor_id
  def start_link(actor_id) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  def init(actor_id) do
    {:ok, %{id: actor_id, count: 0}}
  end

  # Handle any message pattern you want
  def handle_call(payload, _from, state) do
    new_count = state.count + 1
    {:reply, {:ok, new_count}, %{state | count: new_count}}
  end
end
```

## Using with Mesh

To invoke your process:

```elixir
# Register the capability first
Mesh.register_capabilities([:counter])

# Call the process (synchronous)
{:ok, pid, result} = Mesh.call(%Mesh.Request{
  module: MyApp.Counter,
  id: "counter_1",
  payload: %{},
  capability: :counter
})

# Cast to the process (asynchronous, fire-and-forget)
:ok = Mesh.cast(%Mesh.Request{
  module: MyApp.Counter,
  id: "counter_1",
  payload: %{action: :reset},
  capability: :counter
})
```

**What happens on `call`:**
- Mesh determines which node should own this process based on `"counter_1"` and `:counter` capability
- If the process doesn't exist, Mesh starts it using `MyApp.Counter.start_link("counter_1")`
- Mesh sends your payload directly via `GenServer.call(pid, payload)`
- Returns `{:ok, pid, result}` where `pid` is the process identifier and `result` is what your `handle_call` returned

**What happens on `cast`:**
- Same routing logic as `call`
- Mesh sends your payload directly via `GenServer.cast(pid, payload)`
- Returns `:ok` immediately without waiting for a response

## Custom Initialization

You can pass custom arguments to your process when it's first created:

```elixir
defmodule MyApp.GameActor do
  use GenServer

  # Support both arities for flexibility
  def start_link(actor_id), do: start_link(actor_id, nil)

  def start_link(actor_id, init_arg) do
    GenServer.start_link(__MODULE__, {actor_id, init_arg})
  end

  def init({actor_id, nil}) do
    # Default initialization
    {:ok, %{id: actor_id, level: 1, score: 0}}
  end

  def init({actor_id, init_arg}) do
    # Custom initialization with provided argument
    {:ok, %{id: actor_id, level: init_arg.starting_level, score: 0}}
  end

  def handle_call(_payload, _from, state) do
    {:reply, {:ok, state}, state}
  end
end
```

Usage:

```elixir
# Create with custom starting level
{:ok, pid, state} = Mesh.call(%Mesh.Request{
  module: MyApp.GameActor,
  id: "player_123",
  payload: %{action: :get_state},
  capability: :game,
  init_arg: %{starting_level: 10}
})

# state.level == 10
```

**Note:** The `init_arg` is only used when the process is first created. Subsequent calls to the same `id` will reuse the existing process with its current state.

## Supervision

**Important:** Mesh supervises your processes, not you.

When you invoke a process, Mesh:
1. Looks up if a process with that `actor_id` already exists
2. If not, starts it under `Mesh.Actors.ActorSupervisor` (a `DynamicSupervisor`)
3. Caches the PID in an ETS table for fast lookups
4. Routes the call to the process

Your processes live under Mesh's supervision tree:

```
Mesh.Supervisor
  └── Mesh.Actors.ActorSupervisor (DynamicSupervisor)
      ├── YourProcess (actor_id: "counter_1")
      ├── YourProcess (actor_id: "counter_2")
      └── YourProcess (actor_id: "player_123")
```

## Process Lifecycle

### Creation
```elixir
# First call creates the process
{:ok, pid, result} = Mesh.call(%Mesh.Request{
  module: MyApp.Counter,
  id: "counter_1",
  payload: %{},
  capability: :counter
})
```

### Reuse
```elixir
# Subsequent calls reuse the same process
{:ok, ^pid, result} = Mesh.call(%Mesh.Request{
  module: MyApp.Counter,
  id: "counter_1",
  payload: %{},
  capability: :counter
})
```

### Failure & Restart

If your process crashes, Mesh handles it automatically:

```elixir
defmodule MyApp.Crasher do
  use GenServer

  def start_link(actor_id) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  def init(actor_id) do
    {:ok, %{id: actor_id, crashes: 0}}
  end

  def handle_call(%{action: "crash"}, _from, state) do
    # This will crash the process
    raise "boom!"
  end

  def handle_call(_payload, _from, state) do
    {:reply, {:ok, state.crashes}, state}
  end
end
```

**What happens when it crashes:**
1. The process terminates
2. Mesh's supervisor restarts it automatically
3. Next invocation gets a **new PID** with fresh state

```elixir
# First call - process created
{:ok, pid1, _} = Mesh.call(%Mesh.Request{
  module: MyApp.Crasher,
  id: "crasher_1",
  payload: %{},
  capability: :crasher
})

# Crash it (this will raise an error, use try/catch if needed)
try do
  Mesh.call(%Mesh.Request{
    module: MyApp.Crasher,
    id: "crasher_1",
    payload: %{action: "crash"},
    capability: :crasher
  })
rescue
  _ -> :ok
end

# Next call gets a new process with fresh state
{:ok, pid2, _} = Mesh.call(%Mesh.Request{
  module: MyApp.Crasher,
  id: "crasher_1",
  payload: %{},
  capability: :crasher
})

# Different PIDs
pid1 != pid2  # true
```

## Architecture

Understanding how Mesh routes and manages processes:

When you invoke a process via `Mesh.call`, the system executes a multi-step pipeline to ensure the process exists on the correct node and receives your message.

The routing layer first computes a shard number by hashing the process ID. With 4096 shards distributed across available nodes, the hash ring determines which node should own this particular process. This deterministic approach ensures the same ID always routes to the same node unless the cluster topology changes.

Once the target node is identified, Mesh checks if this is a local or remote call. For local calls, it proceeds directly to the owner. For remote calls, it uses RPC to invoke the owner on the target node.

The owner component manages all processes for its assigned shards. It maintains an ETS table for fast PID lookups. When a call arrives, it first checks if the process already exists in the table. If found, the message is forwarded immediately. If not found, the owner starts a new process under its DynamicSupervisor, caches the PID in ETS, and then forwards the message.

Finally, your GenServer receives your payload directly via `handle_call/3`. You have complete freedom to pattern match on the payload structure. You process the business logic and return a response, which flows back through the owner, potentially through RPC, and returns to the original caller.

This architecture provides several benefits: processes are evenly distributed across nodes via consistent hashing, PID caching eliminates repeated lookups, dynamic supervision handles failures automatically, and the entire system operates without coordination overhead between nodes.


## Key Takeaways

1. **Just use GenServer** - No special behaviors or macros needed
2. **Mesh supervises everything** - Don't add your processes to your own supervision tree
3. **Call vs Cast** - Use `Mesh.call` for synchronous requests, `Mesh.cast` for fire-and-forget
4. **Custom initialization** - Pass `init_arg` in the Request struct for custom setup
5. **Stateful by default** - Each `actor_id` maintains its own state
6. **Automatic restart** - Crashes are handled, but state is lost (use persistence if needed)
7. **Location transparent** - Process might be local or remote, Mesh handles routing
8. **ETS caching** - Fast PID lookups after first invocation

## Testing

```elixir
defmodule MyApp.GameActorTest do
  use ExUnit.Case

  setup do
    # Mesh is already started by test_helper
    Mesh.register_capabilities([:game])
    Process.sleep(50)  # Let capabilities sync
    :ok
  end

  test "increments score" do
    {:ok, _pid, {:ok, score}} = Mesh.call(%Mesh.Request{
      module: MyApp.GameActor,
      id: "test_game_1",
      payload: %{action: :increment},
      capability: :game
    })

    assert score == 1
  end

  test "maintains state across calls" do
    id = "test_game_2"

    req = fn payload ->
      %Mesh.Request{
        module: MyApp.GameActor,
        id: id,
        payload: payload,
        capability: :game
      }
    end

    {:ok, pid1, _} = Mesh.call(req.(%{action: :increment}))
    {:ok, pid2, {:ok, score}} = Mesh.call(req.(%{action: :increment}))

    assert pid1 == pid2  # Same process
    assert score == 2    # State maintained
  end

  test "custom initialization" do
    {:ok, _pid, {:ok, state}} = Mesh.call(%Mesh.Request{
      module: MyApp.GameActor,
      id: "test_game_3",
      payload: %{action: :get_state},
      capability: :game,
      init_arg: %{starting_level: 10}
    })

    assert state.level == 10
  end

  test "async cast" do
    # Create the process first
    {:ok, _pid, _} = Mesh.call(%Mesh.Request{
      module: MyApp.GameActor,
      id: "test_game_4",
      payload: %{action: :get_state},
      capability: :game
    })

    # Send async message
    :ok = Mesh.cast(%Mesh.Request{
      module: MyApp.GameActor,
      id: "test_game_4",
      payload: %{action: :log},
      capability: :game
    })
  end
end
```

