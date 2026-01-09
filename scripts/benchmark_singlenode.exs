IO.puts("\n🚀 Starting Mesh STRESS Benchmarks\n")

# Helper for creating requests
req = fn module, id, payload, capability ->
  %Mesh.Request{module: module, id: id, payload: payload, capability: capability}
end

# Start Mesh supervisor (no cluster setup needed for single node)
{:ok, _pid} = Mesh.Supervisor.start_link()
Process.sleep(100)

Mesh.register_capabilities([:game, :chat, :payment])

# Wait for async shard synchronization
Process.sleep(300)

IO.puts("✅ Capabilities registered: [:game, :chat, :payment]")
IO.puts("✅ System synchronized\n")

IO.puts("📊 Benchmark 1: Creating 50,000 actors")

{time_us, results} =
  :timer.tc(fn ->
    1..50_000
    |> Task.async_stream(
      fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "actor_#{i}", %{test: true}, :game))
      end,
      max_concurrency: 500,
      timeout: 60_000
    )
    |> Enum.to_list()
  end)

successes = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)
failures = 50_000 - successes

IO.puts("   Time: #{Float.round(time_us / 1_000_000, 2)}s")
IO.puts("   Throughput: #{Float.round(50_000 / (time_us / 1_000_000), 2)} actors/s")
IO.puts("   Success: #{successes} | Failures: #{failures}\n")

IO.puts("📊 Benchmark 2: 10,000 invocations on the same actor (contention test)")

{:ok, _pid, _reply} = Mesh.call(req.(Mesh.Actors.VirtualTestActor, "hot_actor", %{init: true}, :game))

{time_us, results} =
  :timer.tc(fn ->
    1..10_000
    |> Task.async_stream(
      fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "hot_actor", %{req: i}, :game))
      end,
      max_concurrency: 200,
      timeout: 60_000
    )
    |> Enum.to_list()
  end)

successes = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)

IO.puts("   Time: #{Float.round(time_us / 1_000_000, 2)}s")
IO.puts("   Throughput: #{Float.round(10_000 / (time_us / 1_000_000), 2)} req/s")
IO.puts("   Success: #{successes}/10000\n")

IO.puts("📊 Benchmark 3: Shard distribution for 100,000 actors")

shard_distribution =
  1..100_000
  |> Enum.map(fn i -> Mesh.Shards.ShardRouter.shard_for("dist_actor_#{i}") end)
  |> Enum.frequencies()

unique_shards = map_size(shard_distribution)
max_per_shard = Enum.max(Map.values(shard_distribution))
min_per_shard = Enum.min(Map.values(shard_distribution))
avg_per_shard = 100_000 / unique_shards

IO.puts("   Unique shards: #{unique_shards}/4096 (#{Float.round(unique_shards / 4096 * 100, 2)}%)")
IO.puts("   Max actors/shard: #{max_per_shard}")
IO.puts("   Min actors/shard: #{min_per_shard}")
IO.puts("   Avg actors/shard: #{Float.round(avg_per_shard, 2)}\n")

IO.puts("📊 Benchmark 4: 30,000 actors with 3 different capabilities")

{time_us, results} =
  :timer.tc(fn ->
    for capability <- [:game, :chat, :payment],
        i <- 1..10_000 do
      {capability, i}
    end
    |> Task.async_stream(
      fn {capability, i} ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "#{capability}_actor_#{i}", %{test: true}, capability))
      end,
      max_concurrency: 500,
      timeout: 60_000
    )
    |> Enum.to_list()
  end)

successes = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)

IO.puts("   Time: #{Float.round(time_us / 1_000_000, 2)}s")
IO.puts("   Throughput: #{Float.round(30_000 / (time_us / 1_000_000), 2)} actors/s")
IO.puts("   Success: #{successes}/30000\n")

IO.puts("📊 Benchmark 5: Mixed load - 20,000 invocations on 5,000 actors")

IO.puts("   Creating 5,000 actors...")

{create_time, _} =
  :timer.tc(fn ->
    1..5_000
    |> Task.async_stream(
      fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "mixed_actor_#{i}", %{init: true}, :game))
      end,
      max_concurrency: 300
    )
    |> Stream.run()
  end)

IO.puts("   Actors created in #{Float.round(create_time / 1_000_000, 2)}s")

IO.puts("   Executing 20,000 random invocations...")

{time_us, results} =
  :timer.tc(fn ->
    1..20_000
    |> Task.async_stream(
      fn i ->
        # Distribute randomly among 5k actors
        actor_num = rem(i, 5_000) + 1
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "mixed_actor_#{actor_num}", %{req: i}, :game))
      end,
      max_concurrency: 300,
      timeout: 60_000
    )
    |> Enum.to_list()
  end)

successes = Enum.count(results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)

IO.puts("   Time: #{Float.round(time_us / 1_000_000, 2)}s")
IO.puts("   Throughput: #{Float.round(20_000 / (time_us / 1_000_000), 2)} req/s")
IO.puts("   Success: #{successes}/20000\n")

IO.puts("📊 Benchmark 6: Latency measurement under load")

latencies =
  1..1_000
  |> Enum.map(fn i ->
    {time_us, _} =
      :timer.tc(fn ->
        actor_num = rem(i, 5_000) + 1
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "mixed_actor_#{actor_num}", %{latency_test: i}, :game))
      end)

    time_us
  end)
  |> Enum.sort()

p50 = Enum.at(latencies, 500)
p95 = Enum.at(latencies, 950)
p99 = Enum.at(latencies, 990)
max = Enum.max(latencies)
avg = Enum.sum(latencies) / 1_000

IO.puts("   Average: #{Float.round(avg, 2)}μs (#{Float.round(avg / 1000, 2)}ms)")
IO.puts("   P50: #{p50}μs (#{Float.round(p50 / 1000, 2)}ms)")
IO.puts("   P95: #{p95}μs (#{Float.round(p95 / 1000, 2)}ms)")
IO.puts("   P99: #{p99}μs (#{Float.round(p99 / 1000, 2)}ms)")
IO.puts("   Max: #{max}μs (#{Float.round(max / 1000, 2)}ms)\n")

IO.puts("📈 Final System Statistics:")

memory = :erlang.memory()
processes = :erlang.system_info(:process_count)
actors_in_table = :ets.info(Mesh.Actors.ActorTable, :size)

IO.puts("   Active processes: #{processes}")
IO.puts("   Actors in table: #{actors_in_table}")
IO.puts("   Total memory: #{Float.round(memory[:total] / (1024 * 1024), 2)} MB")
IO.puts("   Process memory: #{Float.round(memory[:processes] / (1024 * 1024), 2)} MB")
IO.puts("   ETS memory: #{Float.round(memory[:ets] / (1024 * 1024), 2)} MB")
IO.puts("   Memory per actor: #{Float.round(memory[:total] / actors_in_table / 1024, 2)} KB")

IO.puts("\n⚠️  Limit Test:")
IO.puts("   Process limit: #{:erlang.system_info(:process_limit)}")
IO.puts("   Process usage: #{Float.round(processes / :erlang.system_info(:process_limit) * 100, 2)}%")

IO.puts("\n✅ Stress Benchmarks completed!\n")
