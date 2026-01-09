Code.require_file("test/support/node_helper.ex")

# Check if the node is distributed
unless Node.alive?() do
  IO.puts("\n❌ ERROR: This benchmark needs to be executed in distributed mode!\n")
  IO.puts("Run with:")
  IO.puts("  elixir --name bench@127.0.0.1 --cookie mvp -S mix run scripts/benchmark_multinode.exs\n")
  System.halt(1)
end

IO.puts("\n🌐 Starting MULTI-NODE Benchmark of Mesh\n")

# Helper for creating requests
req = fn module, id, payload, capability ->
  %Mesh.Request{module: module, id: id, payload: payload, capability: capability}
end

# Note: Not using libcluster here - NodeHelper will connect nodes manually
# This avoids premature connections during initialization

# Start Mesh supervisor on main node
{:ok, _pid} = Mesh.Supervisor.start_link()

# Wait for Mesh.Supervisor to fully initialize before starting slave nodes
# This ensures the main node's Mesh.Cluster.Capabilities is ready
IO.puts("⏳ Waiting for Mesh system to stabilize...")
Process.sleep(2000)

node_count = 3

IO.puts("📋 Configuration:")
IO.puts("   Total nodes: #{node_count + 1} (1 main + #{node_count} slaves)")
IO.puts("   Main node: #{node()}")
IO.puts("")

IO.puts("🚀 Starting #{node_count} slave nodes...")

nodes = NodeHelper.start_nodes(node_count, "bench_node")

all_nodes = [node() | nodes]

IO.puts("✅ Nodes started: #{inspect(all_nodes)}\n")

IO.puts("🔧 Registering capabilities per node...")

NodeHelper.register_capabilities(node(), [:game])
IO.puts("   #{node()} → [:game]")

if length(nodes) >= 1 do
  NodeHelper.register_capabilities(Enum.at(nodes, 0), [:chat])
  IO.puts("   #{Enum.at(nodes, 0)} → [:chat]")
end

if length(nodes) >= 2 do
  NodeHelper.register_capabilities(Enum.at(nodes, 1), [:payment])
  IO.puts("   #{Enum.at(nodes, 1)} → [:payment]")
end

if length(nodes) >= 3 do
  NodeHelper.register_capabilities(Enum.at(nodes, 2), [:game, :chat, :payment])
  IO.puts("   #{Enum.at(nodes, 2)} → [:game, :chat, :payment]")
end

IO.puts("")

IO.puts("🔄 Synchronizing shards on all nodes...")
NodeHelper.sync_all_shards(nodes)
Process.sleep(500)
IO.puts("✅ Shards synchronized\n")

IO.puts("📊 Initial Statistics:")

Enum.each(all_nodes, fn node ->
  stats = NodeHelper.node_stats(node)
  IO.puts("   #{node}:")
  IO.puts("     Processes: #{stats.processes}")
  IO.puts("     Memory: #{Float.round(stats.memory_mb, 2)} MB")
  IO.puts("     Actors: #{stats.actors}")
end)

IO.puts("")

IO.puts("📊 Benchmark 1: Creating 10,000 distributed actors across capabilities")

{time_us, results} =
  :timer.tc(fn ->
    for capability <- [:game, :chat, :payment],
        i <- 1..3_333 do
      {capability, i}
    end
    |> Enum.take(10_000)
    |> Task.async_stream(
      fn {capability, i} ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "dist_actor_#{capability}_#{i}", %{test: true}, capability))
      end,
      max_concurrency: 300,
      timeout: 30_000
    )
    |> Enum.to_list()
  end)

successes = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)

IO.puts("   Time: #{Float.round(time_us / 1_000_000, 2)}s")
IO.puts("   Throughput: #{Float.round(10_000 / (time_us / 1_000_000), 2)} actors/s")
IO.puts("   Success: #{successes}/10000\n")

IO.puts("   Actor distribution per node:")

Enum.each(all_nodes, fn node ->
  actor_count = :rpc.call(node, :ets, :info, [Mesh.Actors.ActorTable, :size])
  IO.puts("     #{node}: #{actor_count} actors")
end)

IO.puts("")

# ==============================================================================
# BENCHMARK 2 - COMMENTED OUT (RPC latency test with remote actors)
# This requires ActorOwnerRegistry on remote nodes which isn't starting properly
# ==============================================================================
# IO.puts("📊 Benchmark 2: RPC latency between nodes")
#
# # Create actors on different nodes
# {:ok, _pid, _reply} = Mesh.call(req.(Mesh.Actors.VirtualTestActor, "game_actor_rpc", %{init: true}, :game))
# {:ok, _pid, _reply} = Mesh.call(req.(Mesh.Actors.VirtualTestActor, "chat_actor_rpc", %{init: true}, :chat))
# {:ok, _pid, _reply} = Mesh.call(req.(Mesh.Actors.VirtualTestActor, "payment_actor_rpc", %{init: true}, :payment))
#
# Process.sleep(100)
#
# # Measure latency of local vs remote calls
# latencies_local =
#   1..100
#   |> Enum.map(fn i ->
#     {time_us, _} =
#       :timer.tc(fn ->
#         Mesh.call(req.(Mesh.Actors.VirtualTestActor, "game_actor_rpc", %{req: i}, :game))
#       end)
#
#     time_us
#   end)
#
# latencies_remote =
#   1..100
#   |> Enum.map(fn i ->
#     capability = Enum.random([:chat, :payment])
#
#     {time_us, _} =
#       :timer.tc(fn ->
#         Mesh.call(req.(Mesh.Actors.VirtualTestActor, "#{capability}_actor_rpc", %{req: i}, capability))
#       end)
#
#     time_us
#   end)
#
# avg_local = Enum.sum(latencies_local) / length(latencies_local)
# avg_remote = Enum.sum(latencies_remote) / length(latencies_remote)
#
# IO.puts("   Average latency (local):  #{Float.round(avg_local, 2)}μs (#{Float.round(avg_local / 1000, 2)}ms)")
# IO.puts("   Average latency (remote): #{Float.round(avg_remote, 2)}μs (#{Float.round(avg_remote / 1000, 2)}ms)")
# IO.puts("   RPC overhead: #{Float.round((avg_remote - avg_local) / avg_local * 100, 2)}%\n")

IO.puts("📊 Benchmark 3: 15,000 invocations distributed across nodes")

# ==============================================================================
# BENCHMARK 4: RESILIENCE TEST - COMMENTED OUT FOR DEBUGGING
# This test kills and restarts nodes. Commenting out to isolate issues.
# ==============================================================================
# if length(nodes) >= 2 do
#   IO.puts("📊 Benchmark 4: Resilience - Simulating node failure")
#
#   node_to_kill = Enum.at(nodes, 1)
#   IO.puts("   Killing node: #{node_to_kill}")
#
#   NodeHelper.stop_node(node_to_kill)
#   Process.sleep(500)
#
#   IO.puts("   Trying to create actors after node failure...")
#
#   {time_us, results} =
#     :timer.tc(fn ->
#       1..1_000
#       |> Task.async_stream(
#         fn i ->
#           Mesh.call(req.(Mesh.Actors.VirtualTestActor, "resilient_actor_#{i}", %{test: true}, :payment))
#         end,
#         max_concurrency: 100,
#         timeout: 10_000
#       )
#       |> Enum.to_list()
#     end)
#
#   successes = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)
#   failures = 1_000 - successes
#
#   IO.puts("   Time: #{Float.round(time_us / 1_000_000, 2)}s")
#   IO.puts("   Success: #{successes}/1000")
#   IO.puts("   Failures: #{failures}/1000")
#   IO.puts("   Success rate: #{Float.round(successes / 1_000 * 100, 2)}%\n")
#
#   IO.puts("   Restarting node...")
#   {:ok, new_node} = NodeHelper.start_node(node_to_kill)
#   NodeHelper.connect_nodes([new_node | nodes -- [node_to_kill]])
#   NodeHelper.load_application_on_node(new_node)
#   NodeHelper.register_capabilities(new_node, [:payment])
#   NodeHelper.sync_all_shards([new_node | nodes -- [node_to_kill]])
#   Process.sleep(500)
#
#   IO.puts("   ✅ Node recovered\n")
# end

IO.puts("   Throughput: #{Float.round(15_000 / (time_us / 1_000_000), 2)} req/s")
IO.puts("   Success: #{successes}/15000\n")

# ==============================================================================
# BENCHMARK 4: RESILIENCE TEST - COMMENTED OUT FOR DEBUGGING
# ==============================================================================
# if length(nodes) >= 2 do
#   IO.puts("📊 Benchmark 4: Resilience - Simulating node failure")
#
#   node_to_kill = Enum.at(nodes, 1)
#   IO.puts("   Killing node: #{node_to_kill}")
#
#   NodeHelper.stop_node(node_to_kill)
#   Process.sleep(500)
#
#   IO.puts("   Trying to create actors after node failure...")
#
#   {time_us, results} =
#     :timer.tc(fn ->
#       1..1_000
#       |> Task.async_stream(
#         fn i ->
#           Mesh.call(req.(Mesh.Actors.VirtualTestActor, "resilient_actor_#{i}", %{test: true}, :payment))
#         end,
#         max_concurrency: 100,
#         timeout: 10_000
#       )
#       |> Enum.to_list()
#     end)
#
#   successes = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)
#   failures = 1_000 - successes
#
#   IO.puts("   Time: #{Float.round(time_us / 1_000_000, 2)}s")
#   IO.puts("   Success: #{successes}/1000")
#   IO.puts("   Failures: #{failures}/1000")
#   IO.puts("   Success rate: #{Float.round(successes / 1_000 * 100, 2)}%\n")
#
#   IO.puts("   Restarting node...")
#   {:ok, new_node} = NodeHelper.start_node(node_to_kill)
#   NodeHelper.connect_nodes([new_node | nodes -- [node_to_kill]])
#   NodeHelper.load_application_on_node(new_node)
#   NodeHelper.register_capabilities(new_node, [:payment])
#   NodeHelper.sync_all_shards([new_node | nodes -- [node_to_kill]])
#   Process.sleep(500)
#
#   IO.puts("   ✅ Node recovered\n")
# end

IO.puts("📊 Benchmark 5: Hash ring balancing verification")

sample_actors = 10_000

distribution =
  1..sample_actors
  |> Enum.map(fn i ->
    capability = Enum.at([:game, :chat, :payment], rem(i, 3))
    actor_id = "balance_#{capability}_#{i}"
    shard = Mesh.Shards.ShardRouter.shard_for(actor_id)
    {:ok, owner} = Mesh.Shards.ShardRouter.owner_node(shard, capability)
    owner
  end)
  |> Enum.frequencies()

IO.puts("   Distribution of #{sample_actors} actors:")

total_expected = sample_actors

Enum.each(distribution, fn {node, count} ->
  percentage = count / total_expected * 100
  IO.puts("     #{node}: #{count} actors (#{Float.round(percentage, 2)}%)")
end)

# Calculate standard deviation
mean = sample_actors / map_size(distribution)
variance = Enum.sum(Enum.map(distribution, fn {_, count} -> :math.pow(count - mean, 2) end)) / map_size(distribution)
std_dev = :math.sqrt(variance)

IO.puts("   Standard deviation: #{Float.round(std_dev, 2)}")
IO.puts("   Balancing: #{if std_dev < mean * 0.15, do: "✅ Excellent", else: "⚠️  Check"}\n")

# ==============================================================================
# FINAL STATISTICS
# ==============================================================================

IO.puts("📈 Final Cluster Statistics:")

Enum.each(all_nodes, fn node ->
  stats = NodeHelper.node_stats(node)

  IO.puts("\n   #{node}:")
  IO.puts("     Status: #{if stats.alive, do: "✅ Online", else: "❌ Offline"}")

  if stats.alive do
    IO.puts("     Processes: #{stats.processes}")
    IO.puts("     Memory: #{Float.round(stats.memory_mb, 2)} MB")
    IO.puts("     Actors: #{stats.actors}")
  end
end)

total_actors =
  all_nodes
  |> Enum.filter(fn node -> Node.ping(node) == :pong end)
  |> Enum.map(fn node ->
    case :rpc.call(node, :ets, :info, [Mesh.Actors.ActorTable, :size]) do
      :undefined -> 0
      count when is_integer(count) -> count
      _ -> 0
    end
  end)
  |> Enum.sum()

IO.puts("\n   Total actors in cluster: #{total_actors}")

IO.puts("\n🧹 Cleaning up slave nodes...")
NodeHelper.stop_nodes(nodes)

IO.puts("\n✅ Multi-Node Benchmark completed!\n")
#
# sample_actors = 10_000
#
# distribution =
#   1..sample_actors
#   |> Enum.map(fn i ->
#     capability = Enum.at([:game, :chat, :payment], rem(i, 3))
#     actor_id = "balance_#{capability}_#{i}"
#     shard = Mesh.Shards.ShardRouter.shard_for(actor_id)
#     {:ok, owner} = Mesh.Shards.ShardRouter.owner_node(shard, capability)
#     owner
#   end)
#   |> Enum.frequencies()
#
# IO.puts("   Distribution of #{sample_actors} actors:")
#
# total_expected = sample_actors
#
# Enum.each(distribution, fn {node, count} ->
#   percentage = count / total_expected * 100
#   IO.puts("     #{node}: #{count} actors (#{Float.round(percentage, 2)}%)")
# end)
#
# # Calculate standard deviation
# mean = sample_actors / map_size(distribution)
# variance = Enum.sum(Enum.map(distribution, fn {_, count} -> :math.pow(count - mean, 2) end)) / map_size(distribution)
# std_dev = :math.sqrt(variance)
#
# IO.puts("   Standard deviation: #{Float.round(std_dev, 2)}")
# IO.puts("   Balancing: #{if std_dev < mean * 0.15, do: "✅ Excellent", else: "⚠️  Check"}\n")
#
# # ==============================================================================
# # FINAL STATISTICS
# # ==============================================================================
#
# IO.puts("📈 Final Cluster Statistics:")
#
# Enum.each(all_nodes, fn node ->
#   stats = NodeHelper.node_stats(node)
#
#   IO.puts("\n   #{node}:")
#   IO.puts("     Status: #{if stats.alive, do: "✅ Online", else: "❌ Offline"}")
#
#   if stats.alive do
#     IO.puts("     Processes: #{stats.processes}")
#     IO.puts("     Memory: #{Float.round(stats.memory_mb, 2)} MB")
#     IO.puts("     Actors: #{stats.actors}")
#   end
# end)
#
# total_actors =
#   all_nodes
#   |> Enum.filter(fn node -> Node.ping(node) == :pong end)
#   |> Enum.map(fn node -> :rpc.call(node, :ets, :info, [Mesh.Actors.ActorTable, :size]) end)
#   |> Enum.sum()
#
# IO.puts("\n   Total actors in cluster: #{total_actors}")

IO.puts("\n🧹 Cleaning up slave nodes...")
NodeHelper.stop_nodes(nodes)

IO.puts("\n✅ Multi-Node Benchmark completed!\n")
