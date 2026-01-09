defmodule Mesh do
  @moduledoc """
  Mesh - A distributed actor system with capability-based routing.

  Mesh provides a simple, unified API for working with distributed actors
  across an Erlang/Elixir cluster. It uses consistent hashing (hash ring)
  to deterministically distribute actors across nodes based on capabilities.

  ## Architecture

  Mesh uses a three-layer architecture:

  1. Hash Ring: Computes shard (0..4095) from actor ID using `:erlang.phash2/2`
  2. Capability Routing: Determines which nodes support a given capability
  3. Actor Placement: Routes actors to owner nodes via RPC

  ## Quick Start

      # Register capabilities this node supports
      Mesh.register_capabilities([:game, :chat])

      # Call a process
      {:ok, pid, response} = Mesh.call(%Mesh.Request{
        module: MyApp.GameActor,
        id: "player_123",
        payload: %{action: "move"},
        capability: :game
      })

      # Query cluster topology
      Mesh.nodes_for(:game)
      #=> [:node1@host, :node2@host]

      Mesh.all_capabilities()
      #=> [:game, :chat, :payment]

  ## Examples

      # Game server node
      Mesh.register_capabilities([:game])

      # Chat server node  
      Mesh.register_capabilities([:chat])

      # Multi-purpose node
      Mesh.register_capabilities([:game, :chat, :payment])

      # Call processes on different capabilities
      {:ok, _pid, _response} = Mesh.call(%Mesh.Request{
        module: MyApp.GameActor, id: "player_123",
        payload: %{hp: 100}, capability: :game
      })
      {:ok, _pid, _response} = Mesh.call(%Mesh.Request{
        module: MyApp.ChatActor, id: "room_456",
        payload: %{msg: "Hello"}, capability: :chat
      })
  """

  @typedoc "Unique identifier for an actor (typically a string)"
  @type actor_id :: String.t()

  @typedoc "Arbitrary data payload sent to an actor"
  @type payload :: map() | term()

  @typedoc "Capability atom identifying actor type"
  @type capability :: atom()

  @typedoc "Shard number (0..4095)"
  @type shard :: non_neg_integer()

  @typedoc "List of capability atoms"
  @type capabilities :: [capability()]

  @doc """
  Synchronously calls a virtual process with the given request.

  This is the primary API for making synchronous calls to processes in the mesh.
  The function:

  1. Computes the shard from the actor ID using the hash ring
  2. Determines which node owns that shard for the given capability
  3. Makes an RPC call to that node's ActorOwner
  4. Lazily creates the process if it doesn't exist (using `init_arg` if provided)
  5. Forwards the payload to the process via `GenServer.call` and returns the response

  ## Parameters

  - `request` - A `%Mesh.Request{}` struct containing:
    - `:module` - The GenServer module (required)
    - `:id` - Unique identifier for the process (required)
    - `:payload` - Data to send (required)
    - `:capability` - The capability type (required)
    - `:init_arg` - Optional argument passed to `start_link/2` on first creation

  ## Returns

  - `{:ok, pid, response}` - Success with process PID and response
  - `{:error, reason}` - Failure (e.g., no nodes support the capability)

  ## Examples

      # Simple call
      {:ok, pid, score} = Mesh.call(%Mesh.Request{
        module: MyApp.Counter,
        id: "counter_1",
        payload: %{action: :increment},
        capability: :counter
      })

      # With custom initialization
      {:ok, pid, _} = Mesh.call(%Mesh.Request{
        module: MyApp.GameActor,
        id: "player_123",
        payload: %{action: :spawn},
        capability: :game,
        init_arg: %{starting_level: 5}
      })

  """
  @spec call(Mesh.Request.t()) :: {:ok, pid(), term()} | {:error, term()}
  def call(%Mesh.Request{} = request) do
    Mesh.Actors.ActorSystem.call(request)
  end

  @doc """
  Asynchronously casts a message to a virtual process.

  Similar to `call/1` but uses `GenServer.cast` instead of `GenServer.call`,
  returning immediately without waiting for a response.

  ## Parameters

  - `request` - A `%Mesh.Request{}` struct (same as `call/1`)

  ## Returns

  - `:ok` - Message was sent successfully
  - `{:error, reason}` - Failure (e.g., no nodes support the capability)

  ## Examples

      # Fire and forget
      :ok = Mesh.cast(%Mesh.Request{
        module: MyApp.Logger,
        id: "system_logger",
        payload: %{event: "user_login", user_id: 123},
        capability: :logging
      })

  """
  @spec cast(Mesh.Request.t()) :: :ok | {:error, term()}
  def cast(%Mesh.Request{} = request) do
    Mesh.Actors.ActorSystem.cast(request)
  end

  @doc """
  Registers capabilities that this node supports.

  Capabilities determine which types of actors this node can host. Once registered,
  the node will participate in the hash ring for those capabilities and may be
  assigned shards to manage.

  This should typically be called during application startup or node initialization.

  ## Parameters

  - `capabilities` - List of capability atoms (e.g., `[:game, :chat]`)

  ## Examples

      # Single capability
      Mesh.register_capabilities([:game])

      # Multiple capabilities
      Mesh.register_capabilities([:game, :chat, :payment])

      # Register all capabilities
      Mesh.register_capabilities([:game, :chat, :payment, :analytics])

  ## Notes

  - Capabilities are propagated to all nodes in the cluster
  - Registering capabilities triggers shard synchronization
  - You can register capabilities at any time (not just at startup)
  - Capabilities are stored in memory and lost on node restart
  """
  @spec register_capabilities(capabilities()) :: :ok
  defdelegate register_capabilities(capabilities), to: Mesh.Cluster.Capabilities

  @doc """
  Returns the list of nodes that support a given capability.

  This is useful for understanding cluster topology and debugging routing issues.

  ## Parameters

  - `capability` - The capability atom to query

  ## Returns

  - List of node atoms that support the capability
  - Empty list if no nodes support the capability

  ## Examples

      Mesh.nodes_for(:game)
      #=> [:node1@host, :node2@host, :node3@host]

      Mesh.nodes_for(:chat)
      #=> [:node2@host]

      Mesh.nodes_for(:unknown)
      #=> []

  ## Notes

  - Only returns nodes currently connected to the cluster
  - Updates automatically when nodes join/leave
  - Results are eventually consistent across the cluster
  """
  @spec nodes_for(capability()) :: [node()]
  defdelegate nodes_for(capability), to: Mesh.Cluster.Capabilities

  @doc """
  Returns all capabilities registered across the entire cluster.

  This aggregates capabilities from all connected nodes and returns a unique list.

  ## Returns

  - List of unique capability atoms registered in the cluster

  ## Examples

      # Node 1 registered [:game]
      # Node 2 registered [:chat]
      # Node 3 registered [:game, :payment]
      Mesh.all_capabilities()
      #=> [:game, :chat, :payment]

      # No nodes registered any capabilities
      Mesh.all_capabilities()
      #=> []

  ## Notes

  - Results include capabilities from all connected nodes
  - Duplicates are automatically removed
  - Updates when nodes join/leave or register new capabilities
  """
  @spec all_capabilities() :: capabilities()
  defdelegate all_capabilities(), to: Mesh.Cluster.Capabilities

  @doc """
  Computes the shard number for a given actor ID.

  Uses `:erlang.phash2/2` to hash the actor ID into a shard number (0..4095).
  The same actor ID always produces the same shard number, ensuring deterministic
  actor placement.

  ## Parameters

  - `actor_id` - The actor identifier (string)

  ## Returns

  - Integer from 0 to 4095 representing the shard number

  ## Examples

      Mesh.shard_for("player_123")
      #=> 2451

      Mesh.shard_for("player_123")
      #=> 2451  # Always the same shard

      Mesh.shard_for("player_456")
      #=> 891   # Different actor, different shard

  ## Notes

  - Shard count is configurable (default: 4096)
  - Hash function is deterministic and uniform
  - Used internally by `invoke/3` for routing
  """
  @spec shard_for(actor_id()) :: shard()
  defdelegate shard_for(actor_id), to: Mesh.Shards.ShardRouter

  @doc """
  Determines which node owns a given shard for a specific capability.

  This combines the hash ring with capability information to determine the
  owner node. Shards are distributed in round-robin fashion across nodes
  that support the capability.

  ## Parameters

  - `shard` - Shard number (0..4095)
  - `capability` - Capability atom

  ## Returns

  - `{:ok, node}` - Success with the owner node atom
  - `{:error, :no_nodes}` - No nodes support the capability

  ## Examples

      Mesh.owner_node(2451, :game)
      #=> {:ok, :node1@host}

      Mesh.owner_node(2451, :game)
      #=> {:ok, :node1@host}  # Always the same owner

      # Error if no nodes support capability
      Mesh.owner_node(2451, :unknown)
      #=> {:error, :no_nodes}

  ## Notes

  - Owner may change when nodes join/leave the cluster
  - Uses modulo operation: `rem(shard, length(nodes))`
  - Ensures even distribution across available nodes
  """
  @spec owner_node(shard(), capability()) :: {:ok, node()} | {:error, :no_nodes}
  defdelegate owner_node(shard, capability), to: Mesh.Shards.ShardRouter
end
