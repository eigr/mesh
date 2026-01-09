IO.puts("\nStarting Mesh STRESS Benchmarks\n")

# Helper for creating requests
req = fn module, id, payload, capability ->
  %Mesh.Request{module: module, id: id, payload: payload, capability: capability}
end

{:ok, _pid} = Mesh.Supervisor.start_link()
Process.sleep(100)

Mesh.register_capabilities([:game, :chat, :payment])

Process.sleep(300)

IO.puts("Capabilities registered: [:game, :chat, :payment]")
IO.puts("System synchronized\n")

# Store benchmark results
results = %{}

IO.write("Running Benchmark 1: Creating 50,000 actors... ")

{time_us, bench_results} =
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

successes = Enum.count(bench_results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)
failures = 50_000 - successes

results =
  Map.put(results, :bench1, %{
    name: "Creating 50,000 actors",
    time: time_us / 1_000_000,
    throughput: 50_000 / (time_us / 1_000_000),
    successes: successes,
    failures: failures
  })

IO.puts("done (#{Float.round(time_us / 1_000_000, 2)}s)")

IO.write("Running Benchmark 2: 10,000 invocations on same actor... ")

{:ok, _pid, _reply} = Mesh.call(req.(Mesh.Actors.VirtualTestActor, "hot_actor", %{init: true}, :game))

{time_us, bench_results} =
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

successes = Enum.count(bench_results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)

results =
  Map.put(results, :bench2, %{
    name: "10,000 invocations on same actor (contention)",
    time: time_us / 1_000_000,
    throughput: 10_000 / (time_us / 1_000_000),
    successes: successes,
    total: 10_000
  })

IO.puts("done (#{Float.round(time_us / 1_000_000, 2)}s)")

IO.write("Running Benchmark 3: Shard distribution analysis... ")

shard_distribution =
  1..100_000
  |> Enum.map(fn i -> Mesh.Shards.ShardRouter.shard_for("dist_actor_#{i}") end)
  |> Enum.frequencies()

unique_shards = map_size(shard_distribution)
max_per_shard = Enum.max(Map.values(shard_distribution))
min_per_shard = Enum.min(Map.values(shard_distribution))
avg_per_shard = 100_000 / unique_shards

IO.write("Running Benchmark 3: Shard distribution analysis... ")

shard_distribution =
  1..100_000
  |> Enum.map(fn i -> Mesh.Shards.ShardRouter.shard_for("dist_actor_#{i}") end)
  |> Enum.frequencies()

unique_shards = map_size(shard_distribution)
max_per_shard = Enum.max(Map.values(shard_distribution))
min_per_shard = Enum.min(Map.values(shard_distribution))
avg_per_shard = 100_000 / unique_shards

results =
  Map.put(results, :bench3, %{
    name: "Shard distribution for 100,000 actors",
    unique_shards: unique_shards,
    max_per_shard: max_per_shard,
    min_per_shard: min_per_shard,
    avg_per_shard: avg_per_shard
  })

IO.puts("done")

IO.write("Running Benchmark 4: 30,000 actors with 3 capabilities... ")

{time_us, bench_results} =
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

successes = Enum.count(bench_results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)

results =
  Map.put(results, :bench4, %{
    name: "30,000 actors with 3 different capabilities",
    time: time_us / 1_000_000,
    throughput: 30_000 / (time_us / 1_000_000),
    successes: successes,
    total: 30_000
  })

IO.puts("done (#{Float.round(time_us / 1_000_000, 2)}s)")

IO.write("Running Benchmark 5: Mixed load (5k actors, 20k invocations)... ")

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

{time_us, bench_results} =
  :timer.tc(fn ->
    1..20_000
    |> Task.async_stream(
      fn i ->
        actor_num = rem(i, 5_000) + 1
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "mixed_actor_#{actor_num}", %{req: i}, :game))
      end,
      max_concurrency: 300,
      timeout: 60_000
    )
    |> Enum.to_list()
  end)

successes = Enum.count(bench_results, fn {:ok, {:ok, _pid, _reply}} -> true; _ -> false end)

results =
  Map.put(results, :bench5, %{
    name: "Mixed load - 20,000 invocations on 5,000 actors",
    create_time: create_time / 1_000_000,
    time: time_us / 1_000_000,
    throughput: 20_000 / (time_us / 1_000_000),
    successes: successes,
    total: 20_000
  })

IO.puts("done (#{Float.round(time_us / 1_000_000, 2)}s)")

IO.write("Running Benchmark 6: Latency measurement... ")

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

results =
  Map.put(results, :bench6, %{
    name: "Latency measurement under load (1,000 samples)",
    avg: avg,
    p50: p50,
    p95: p95,
    p99: p99,
    max: max
  })

IO.puts("done")

IO.puts("\n" <> String.duplicate("-", 80))
IO.puts("BENCHMARK RESULTS SUMMARY")
IO.puts(String.duplicate("-", 80) <> "\n")

# Benchmark 1
b1 = results[:bench1]
IO.puts("1. #{b1.name}")
IO.puts("   Time: #{Float.round(b1.time, 2)}s")
IO.puts("   Throughput: #{Float.round(b1.throughput, 2)} actors/s")
IO.puts("   Success: #{b1.successes} | Failures: #{b1.failures}\n")

# Benchmark 2
b2 = results[:bench2]
IO.puts("2. #{b2.name}")
IO.puts("   Time: #{Float.round(b2.time, 2)}s")
IO.puts("   Throughput: #{Float.round(b2.throughput, 2)} req/s")
IO.puts("   Success: #{b2.successes}/#{b2.total}\n")

# Benchmark 3
b3 = results[:bench3]
IO.puts("3. #{b3.name}")
IO.puts("   Unique shards: #{b3.unique_shards}/4096 (#{Float.round(b3.unique_shards / 4096 * 100, 2)}%)")
IO.puts("   Max actors/shard: #{b3.max_per_shard}")
IO.puts("   Min actors/shard: #{b3.min_per_shard}")
IO.puts("   Avg actors/shard: #{Float.round(b3.avg_per_shard, 2)}\n")

# Benchmark 4
b4 = results[:bench4]
IO.puts("4. #{b4.name}")
IO.puts("   Time: #{Float.round(b4.time, 2)}s")
IO.puts("   Throughput: #{Float.round(b4.throughput, 2)} actors/s")
IO.puts("   Success: #{b4.successes}/#{b4.total}\n")

# Benchmark 5
b5 = results[:bench5]
IO.puts("5. #{b5.name}")
IO.puts("   Actor creation: #{Float.round(b5.create_time, 2)}s")
IO.puts("   Invocation time: #{Float.round(b5.time, 2)}s")
IO.puts("   Throughput: #{Float.round(b5.throughput, 2)} req/s")
IO.puts("   Success: #{b5.successes}/#{b5.total}\n")

# Benchmark 6
b6 = results[:bench6]
IO.puts("6. #{b6.name}")
IO.puts("   Average: #{Float.round(b6.avg, 2)}μs (#{Float.round(b6.avg / 1000, 2)}ms)")
IO.puts("   P50: #{b6.p50}μs (#{Float.round(b6.p50 / 1000, 2)}ms)")
IO.puts("   P95: #{b6.p95}μs (#{Float.round(b6.p95 / 1000, 2)}ms)")
IO.puts("   P99: #{b6.p99}μs (#{Float.round(b6.p99 / 1000, 2)}ms)")
IO.puts("   Max: #{b6.max}μs (#{Float.round(b6.max / 1000, 2)}ms)\n")

IO.puts("\nSYSTEM STATISTICS")
IO.puts(String.duplicate("-", 40) <> "\n")

memory = :erlang.memory()
processes = :erlang.system_info(:process_count)
actors_in_table = :ets.info(Mesh.Actors.ActorTable, :size)

IO.puts("Active processes: #{processes}")
IO.puts("Actors in table: #{actors_in_table}")
IO.puts("Total memory: #{Float.round(memory[:total] / (1024 * 1024), 2)} MB")
IO.puts("Process memory: #{Float.round(memory[:processes] / (1024 * 1024), 2)} MB")
IO.puts("ETS memory: #{Float.round(memory[:ets] / (1024 * 1024), 2)} MB")
IO.puts("Memory per actor: #{Float.round(memory[:total] / actors_in_table / 1024, 2)} KB")

IO.puts("\nProcess Limits:")
IO.puts("Process limit: #{:erlang.system_info(:process_limit)}")
IO.puts("Process usage: #{Float.round(processes / :erlang.system_info(:process_limit) * 100, 2)}%")

IO.puts("\n" <> String.duplicate("-", 80))
IO.puts("Benchmarks completed successfully!")
IO.puts(String.duplicate("-", 80) <> "\n")
