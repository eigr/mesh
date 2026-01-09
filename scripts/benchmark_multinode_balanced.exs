Code.require_file("test/support/node_helper.ex")

# Check if the node is distributed
unless Node.alive?() do
  IO.puts("\nERROR: This Benchmark needs to be executed in distributed mode!")
  IO.puts("Run with:")
  IO.puts("  elixir --name bench@127.0.0.1 --cookie mvp -S mix run scripts/Benchmark_multinode_balanced.exs\n")
  System.halt(1)
end

IO.puts("\nMULTI-NODE BALANCED Benchmark\n")

req = fn module, id, payload, capability ->
  %Mesh.Request{module: module, id: id, payload: payload, capability: capability}
end

{:ok, _pid} = Mesh.Supervisor.start_link()
Process.sleep(2000)

IO.puts("Configuration:")
IO.puts("  4 nodes total (1 main + 3 slaves)")
IO.puts("  Each node with 1 unique capability (balanced)")
IO.puts("  Main node: #{node()}\n")

IO.puts("Starting slave nodes...")
nodes = NodeHelper.start_nodes(3, "balanced_node")
all_nodes = [node() | nodes]
IO.puts("Nodes: #{inspect(all_nodes)}\n")

IO.puts("Registering capabilities (1 per node):")
NodeHelper.register_capabilities(node(), [:game])
IO.puts("  #{node()} -> [:game]")

NodeHelper.register_capabilities(Enum.at(nodes, 0), [:chat])
IO.puts("  #{Enum.at(nodes, 0)} -> [:chat]")

NodeHelper.register_capabilities(Enum.at(nodes, 1), [:payment])
IO.puts("  #{Enum.at(nodes, 1)} -> [:payment]")

NodeHelper.register_capabilities(Enum.at(nodes, 2), [:inventory])
IO.puts("  #{Enum.at(nodes, 2)} -> [:inventory]\n")

IO.puts("Synchronizing shards...")
NodeHelper.sync_all_shards(nodes)
Process.sleep(500)
IO.puts("Done\n")

IO.puts("Initial Cluster State")
Enum.each(all_nodes, fn node ->
  stats = NodeHelper.node_stats(node)
  IO.puts("#{node}:")
  IO.puts("  Processes: #{stats.processes}")
  IO.puts("  Memory: #{Float.round(stats.memory_mb, 2)} MB")
  IO.puts("  Actors: #{stats.actors}")
end)
IO.puts("")

IO.puts("Benchmark 1: Creating 12,000 actors (3000 per capability)")

{time_us, results} =
  :timer.tc(fn ->
    for capability <- [:game, :chat, :payment, :inventory],
        i <- 1..3_000 do
      {capability, i}
    end
    |> Task.async_stream(
      fn {capability, i} ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "actor_#{capability}_#{i}", %{test: true}, capability))
      end,
      max_concurrency: 300,
      timeout: 30_000
    )
    |> Enum.to_list()
  end)

successes = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)
time_s = time_us / 1_000_000

IO.puts("Time: #{Float.round(time_s, 2)}s")
IO.puts("Throughput: #{Float.round(12_000 / time_s, 2)} actors/s")
IO.puts("Success: #{successes}/12000")

if successes < 12_000 do
  failures = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> false; _ -> true end)
  IO.puts("Failures: #{failures}")
end

IO.puts("\nActor distribution per node:")
Enum.each(all_nodes, fn node ->
  actor_count = case :rpc.call(node, :ets, :info, [Mesh.Actors.ActorTable, :size]) do
    :undefined -> 0
    count when is_integer(count) -> count
    _ -> 0
  end
  IO.puts("  #{node}: #{actor_count} actors")
end)

IO.puts("")
IO.puts("Benchmark 2: 20,000 invocations on existing actors")

{time_us, results} =
  :timer.tc(fn ->
    1..20_000
    |> Task.async_stream(
      fn i ->
        capability = Enum.at([:game, :chat, :payment, :inventory], rem(i, 4))
        actor_id = "actor_#{capability}_#{rem(i, 3000) + 1}"
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, actor_id, %{invoke: i}, capability))
      end,
      max_concurrency: 400,
      timeout: 30_000
    )
    |> Enum.to_list()
  end)

successes = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)
time_s = time_us / 1_000_000

IO.puts("Time: #{Float.round(time_s, 2)}s")
IO.puts("Throughput: #{Float.round(20_000 / time_s, 2)} req/s")
IO.puts("Success: #{successes}/20000\n")

IO.puts("Benchmark 3: Hash ring distribution (10,000 sample)")

distribution =
  1..10_000
  |> Enum.map(fn i ->
    capability = Enum.at([:game, :chat, :payment, :inventory], rem(i, 4))
    actor_id = "sample_#{capability}_#{i}"
    shard = Mesh.Shards.ShardRouter.shard_for(actor_id)
    {:ok, owner} = Mesh.Shards.ShardRouter.owner_node(shard, capability)
    owner
  end)
  |> Enum.frequencies()

IO.puts("Expected distribution per node:")
total = 10_000
Enum.each(distribution, fn {node, count} ->
  percentage = count / total * 100
  IO.puts("  #{node}: #{count} actors (#{Float.round(percentage, 2)}%)")
end)

# Calculate standard deviation
mean = total / map_size(distribution)
variance = Enum.sum(Enum.map(distribution, fn {_, count} -> :math.pow(count - mean, 2) end)) / map_size(distribution)
std_dev = :math.sqrt(variance)

IO.puts("\nStandard deviation: #{Float.round(std_dev, 2)}")
balance_quality = if std_dev < mean * 0.1, do: "Excellent (<10%)", else: if std_dev < mean * 0.15, do: "Good (<15%)", else: "Needs improvement"
IO.puts("Balance quality: #{balance_quality}\n")


IO.puts("Final Cluster State")

Enum.each(all_nodes, fn node ->
  stats = NodeHelper.node_stats(node)
  
  IO.puts("\n#{node}:")
  IO.puts("  Status: #{if stats.alive, do: "Online", else: "Offline"}")
  
  if stats.alive do
    IO.puts("  Processes: #{stats.processes}")
    IO.puts("  Memory: #{Float.round(stats.memory_mb, 2)} MB")
    IO.puts("  Actors: #{stats.actors}")
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

IO.puts("\nTotal actors in cluster: #{total_actors}")

IO.puts("\Cleanup")
IO.puts("Stopping slave nodes...")
NodeHelper.stop_nodes(nodes)
IO.puts("Benchmark completed!\n")
