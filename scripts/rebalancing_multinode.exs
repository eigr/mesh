Code.require_file("test/support/node_helper.ex")

# Check if the node is distributed
unless Node.alive?() do
  IO.puts("\nERROR: This demo needs to be executed in distributed mode!")
  IO.puts("Run with:")
  IO.puts("  elixir --name demo@127.0.0.1 --cookie mvp -S mix run scripts/demo_rebalancing_multinode.exs\n")
  System.halt(1)
end

IO.puts("\n=== Multi-Node Coordinated Rebalancing Demo ===\n")

req = fn module, id, payload, capability ->
  %Mesh.Request{module: module, id: id, payload: payload, capability: capability}
end

# Start Mesh on main node
{:ok, _pid} = Mesh.Supervisor.start_link()
Process.sleep(1000)

IO.puts("Main node: #{node()}\n")

# Helper to count actors by capability across all nodes
count_actors = fn capability, nodes ->
  Enum.reduce(nodes, 0, fn node, acc ->
    result = :rpc.call(node, :ets, :select_count, [
      Mesh.Actors.ActorTable,
      [{{{capability, :_, :_}, :_, :_}, [], [true]}]
    ])
    count = if is_integer(result), do: result, else: 0
    acc + count
  end)
end

# Helper to count total actors across all nodes
count_total_actors = fn nodes ->
  Enum.reduce(nodes, 0, fn node, acc ->
    size = :rpc.call(node, :ets, :info, [Mesh.Actors.ActorTable, :size])
    acc + size
  end)
end

# Helper to check if actors are alive (check all nodes)
check_actor_health = fn actor_ids, capability, nodes ->
  alive = 
    Enum.count(actor_ids, fn id ->
      key = {capability, Mesh.Actors.VirtualTestActor, id}
      Enum.any?(nodes, fn node ->
        case :rpc.call(node, :ets, :lookup, [Mesh.Actors.ActorTable, key]) do
          [{^key, pid, _node}] -> 
            :rpc.call(node, Process, :alive?, [pid])
          [] -> 
            false
          {:badrpc, _} -> 
            false
        end
      end)
    end)
  {alive, length(actor_ids)}
end

IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
IO.puts("STEP 1: Start Node 1 with capability [:game]")
IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

IO.puts("Starting node1...")
[node1] = NodeHelper.start_nodes(1, "game_node")
IO.puts("  ✓ Node started: #{node1}")

IO.puts("\nStarting Mesh.Supervisor on #{node1}...")
:rpc.call(node1, Mesh.Supervisor, :start_link, [])
Process.sleep(500)
IO.puts("  ✓ Supervisor started")

IO.puts("\nRegistering [:game] on #{node1}...")
NodeHelper.register_capabilities(node1, [:game])
NodeHelper.sync_all_shards([node1])
Process.sleep(500)
IO.puts("  ✓ Capability registered\n")

IO.puts("Creating 20 actors with [:game] capability...")
game_actor_ids = 
  for i <- 1..20 do
    case Mesh.call(req.(Mesh.Actors.VirtualTestActor, "game_#{i}", %{test: true}, :game)) do
      {:ok, pid, _reply} -> 
        IO.write(".")
        "game_#{i}"
      error -> 
        IO.puts("\n  ✗ Failed to create game_#{i}: #{inspect(error)}")
        nil
    end
  end
  |> Enum.reject(&is_nil/1)

IO.puts("\n  ✓ Created #{length(game_actor_ids)} actors\n")

# Show distribution
all_nodes = [node(), node1]
game_count = count_actors.(:game, all_nodes)
total_count = count_total_actors.(all_nodes)
IO.puts("Current state:")
IO.puts("  [:game] actors: #{game_count}")
IO.puts("  Total actors: #{total_count}")
IO.puts("  Rebalancing mode: #{Mesh.Cluster.Rebalancing.mode()}\n")

Process.sleep(1000)

IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
IO.puts("STEP 2: Add Node 2 with capability [:chat]")
IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

IO.puts("Starting node2...")
[node2] = NodeHelper.start_nodes(1, "chat_node")
IO.puts("  ✓ Node started: #{node2}")

IO.puts("\nStarting Mesh.Supervisor on #{node2}...")
:rpc.call(node2, Mesh.Supervisor, :start_link, [])
Process.sleep(500)
IO.puts("  ✓ Supervisor started")

IO.puts("\nRegistering [:chat] on #{node2}...")
IO.puts("  (This should NOT affect [:game] actors)")
NodeHelper.register_capabilities(node2, [:chat])
NodeHelper.sync_all_shards([node1, node2])
Process.sleep(500)
IO.puts("  ✓ Capability registered\n")

# Check if game actors survived
all_nodes = [node(), node1, node2]
{game_alive, game_total} = check_actor_health.(game_actor_ids, :game, all_nodes)
IO.puts("Health check for [:game] actors:")
IO.puts("  Alive: #{game_alive}/#{game_total}")

if game_alive == game_total do
  IO.puts("  ✅ All [:game] actors survived (no ownership change)")
else
  IO.puts("  ⚠️  Some [:game] actors were stopped")
end

IO.puts("\nCreating 15 actors with [:chat] capability...")
chat_actor_ids = 
  for i <- 1..15 do
    case Mesh.call(req.(Mesh.Actors.VirtualTestActor, "chat_#{i}", %{test: true}, :chat)) do
      {:ok, _pid, _reply} -> 
        IO.write(".")
        "chat_#{i}"
      error -> 
        IO.puts("\n  ✗ Failed to create chat_#{i}: #{inspect(error)}")
        nil
    end
  end
  |> Enum.reject(&is_nil/1)

IO.puts("\n  ✓ Created #{length(chat_actor_ids)} actors\n")

# Show distribution
game_count = count_actors.(:game, all_nodes)
chat_count = count_actors.(:chat, all_nodes)
total_count = count_total_actors.(all_nodes)
IO.puts("Current state:")
IO.puts("  [:game] actors: #{game_count}")
IO.puts("  [:chat] actors: #{chat_count}")
IO.puts("  Total actors: #{total_count}")
IO.puts("  Rebalancing mode: #{Mesh.Cluster.Rebalancing.mode()}\n")

Process.sleep(1000)

IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
IO.puts("STEP 3: Add Node 3 with capability [:game]")
IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

IO.puts("Starting node3...")
[node3] = NodeHelper.start_nodes(1, "game_node2")
IO.puts("  ✓ Node started: #{node3}")

IO.puts("\nStarting Mesh.Supervisor on #{node3}...")
:rpc.call(node3, Mesh.Supervisor, :start_link, [])
Process.sleep(500)
IO.puts("  ✓ Supervisor started")

IO.puts("\n⚠️  CRITICAL: Registering [:game] on #{node3}...")
IO.puts("  This WILL trigger rebalancing!")
IO.puts("  Shards will be redistributed between node1 and node3")
IO.puts("  Some [:game] actors WILL be stopped and moved\n")

all_nodes = [node(), node1, node2, node3]
IO.puts("Before registration - checking actor health:")
{game_alive_before, _} = check_actor_health.(game_actor_ids, :game, all_nodes)
{chat_alive_before, _} = check_actor_health.(chat_actor_ids, :chat, all_nodes)
IO.puts("  [:game] actors alive: #{game_alive_before}/#{length(game_actor_ids)}")
IO.puts("  [:chat] actors alive: #{chat_alive_before}/#{length(chat_actor_ids)}\n")

IO.puts("Registering capability...")
NodeHelper.register_capabilities(node3, [:game])
NodeHelper.sync_all_shards([node1, node2, node3])
Process.sleep(1000)
IO.puts("  ✓ Registration complete\n")

IO.puts("After registration - checking actor health:")
{game_alive_after, game_total} = check_actor_health.(game_actor_ids, :game, all_nodes)
{chat_alive_after, chat_total} = check_actor_health.(chat_actor_ids, :chat, all_nodes)
IO.puts("  [:game] actors alive: #{game_alive_after}/#{game_total}")
IO.puts("  [:chat] actors alive: #{chat_alive_after}/#{chat_total}\n")

game_stopped = game_alive_before - game_alive_after
chat_stopped = chat_alive_before - chat_alive_after

if game_stopped > 0 do
  IO.puts("  ✅ Rebalancing worked correctly!")
  IO.puts("     #{game_stopped} [:game] actors were stopped (ownership changed)")
  IO.puts("     #{game_alive_after} [:game] actors stayed alive (ownership unchanged)")
else
  IO.puts("  ⚠️  No [:game] actors were stopped (unexpected in multi-node)")
end

if chat_stopped == 0 do
  IO.puts("  ✅ All [:chat] actors survived (no ownership change)")
else
  IO.puts("  ⚠️  Some [:chat] actors were stopped (unexpected)")
end

IO.puts("\nCreating 10 more [:game] actors (will be distributed)...")
new_game_actor_ids = 
  for i <- 21..30 do
    case Mesh.call(req.(Mesh.Actors.VirtualTestActor, "game_#{i}", %{test: true}, :game)) do
      {:ok, _pid, _reply} -> 
        IO.write(".")
        "game_#{i}"
      error -> 
        IO.puts("\n  ✗ Failed to create game_#{i}: #{inspect(error)}")
        nil
    end
  end
  |> Enum.reject(&is_nil/1)

IO.puts("\n  ✓ Created #{length(new_game_actor_ids)} actors\n")

# Final stats
game_count = count_actors.(:game, all_nodes)
chat_count = count_actors.(:chat, all_nodes)
total_count = count_total_actors.(all_nodes)

IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
IO.puts("FINAL STATE")
IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

IO.puts("Nodes:")
IO.puts("  #{node1} - [:game]")
IO.puts("  #{node2} - [:chat]")
IO.puts("  #{node3} - [:game]\n")

IO.puts("Actors:")
IO.puts("  [:game] actors: #{game_count}")
IO.puts("  [:chat] actors: #{chat_count}")
IO.puts("  Total: #{total_count}\n")

IO.puts("Rebalancing Statistics:")
IO.puts("  [:game] actors stopped during rebalancing: #{game_stopped}")
IO.puts("  [:game] actors that survived: #{game_alive_after}")
IO.puts("  [:chat] actors stopped during rebalancing: #{chat_stopped}")
IO.puts("  Rebalancing mode: #{Mesh.Cluster.Rebalancing.mode()}\n")

if game_stopped > 0 and chat_stopped == 0 do
  IO.puts("✅ SUCCESS: Coordinated rebalancing working perfectly!")
  IO.puts("   - Only affected actors were stopped")
  IO.puts("   - Unaffected capabilities remained stable")
  IO.puts("   - Actors redistributed correctly between nodes")
else
  IO.puts("⚠️  Review rebalancing behavior")
end

IO.puts("\n" <> String.duplicate("━", 44) <> "\n")

# Cleanup
NodeHelper.stop_nodes([node1, node2, node3])
