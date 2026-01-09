defmodule MeshExample do
  @moduledoc """
  Example application demonstrating Mesh usage with custom actors.

  ## Quick Start

  Start multiple nodes in different terminals:

      # Terminal 1
      iex --sname node1 --cookie mesh -S mix

      # Terminal 2
      iex --sname node2 --cookie mesh -S mix

  ## Usage Examples with GameActor

      # Spawn a player
      {:ok, pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "spawn", capability: name: "Alice"}, :game})
      # => %{status: :spawned, player: "Alice", position: {0, 0}}

      # Move the player
      {:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "move", capability: x: 10, y: 20}, :game})
      # => %{status: :moved, position: {10, 20}}

      # Player takes damage
      {:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "take_damage", capability: amount: 25}, :game})
      # => %{status: :alive, health: 75}

      # Add item to inventory
      {:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "add_item", capability: item: "sword"}, :game})
      # => %{status: :item_added, inventory: ["sword"]}

      # Get full state
      {:ok, ^pid, state} = Mesh.call(%Mesh.Request{module: MeshExample.GameActor, id: "player_123", payload: %{action: "get_state"}, capability: :game})

  ## Usage Examples with ChatActor

      # Join a room
      {:ok, pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.ChatActor, id: "room_general", payload: %{action: "join", capability: user: "Alice"}, :chat})
      # => %{status: :joined, room: "room_general", participants: ["Alice"]}

      # Send a message
      {:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.ChatActor, id: "room_general", payload: %{action: "send_message", capability: user: "Alice", message: "Hello!"}, :chat})
      # => %{status: :sent, message: %{user: "Alice", message: "Hello!", timestamp: ...}}

      # Get message history
      {:ok, ^pid, response} = Mesh.call(%Mesh.Request{module: MeshExample.ChatActor, id: "room_general", payload: %{action: "get_messages", capability: limit: 10}, :chat})

  ## Cluster Status

      # Check cluster status
      Node.list()
      Mesh.all_capabilities()
      Mesh.nodes_for(:game)

      # Check actor placement
      shard = Mesh.shard_for("player_123")
      {:ok, owner} = Mesh.owner_node(shard, :game)
      IO.puts("Actor player_123 is on \#{owner}")
  """
end
