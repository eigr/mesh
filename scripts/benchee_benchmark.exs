{:ok, _pid} = Mesh.Supervisor.start_link()
Process.sleep(100)

# Helper for creating requests
req = fn module, id, payload, capability ->
  %Mesh.Request{module: module, id: id, payload: payload, capability: capability}
end

Logger.configure(level: :warning)

IO.puts("\nStarting Benchee Benchmarks for Mesh\n")

:ets.delete_all_objects(Mesh.Actors.ActorTable)
IO.puts("Actor table cleaned\n")

require Mesh.Cluster.Capabilities
Mesh.Cluster.Capabilities.register_capabilities([:game, :chat, :payment])
IO.puts("Capabilities registered: [:game, :chat, :payment]\n")

actor_counts = [100, 1_000, 5_000]

IO.puts("Configuration:")
IO.puts("   Node: #{node()}")
IO.puts("   Actor counts to test: #{inspect(actor_counts)}")
IO.puts("")

IO.puts("Benchmark 1: Actor Creation Performance\n")

Benchee.run(
  %{
    "Create 100 actors" => fn ->
      Enum.each(1..100, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "bench_create_100_#{i}", %{init: true}, :game))
      end)
    end,
    "Create 1,000 actors" => fn ->
      Enum.each(1..1_000, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "bench_create_1k_#{i}", %{init: true}, :game))
      end)
    end,
    "Create 5,000 actors" => fn ->
      Enum.each(1..5_000, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "bench_create_5k_#{i}", %{init: true}, :game))
      end)
    end
  },
  time: 5,
  warmup: 2,
  memory_time: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true}
  ]
)

IO.puts("\n" <> String.duplicate("=", 80) <> "\n")

IO.puts("Benchmark 2: Actor Invocation Performance\n")

IO.puts("Setting up actors for invocation test...")
Enum.each(1..1_000, fn i ->
  Mesh.call(req.(Mesh.Actors.VirtualTestActor, "bench_invoke_#{i}", %{init: true}, :game))
end)
Process.sleep(500)
IO.puts("Setup complete\n")

Benchee.run(
  %{
    "Invoke single actor (1 req)" => fn ->
      Mesh.call(req.(Mesh.Actors.VirtualTestActor, "bench_invoke_1", %{req: 1}, :game))
    end,
    "Invoke 10 actors sequentially" => fn ->
      Enum.each(1..10, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "bench_invoke_#{i}", %{req: i}, :game))
      end)
    end,
    "Invoke 100 actors sequentially" => fn ->
      Enum.each(1..100, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "bench_invoke_#{i}", %{req: i}, :game))
      end)
    end,
    "Invoke 100 actors in parallel" => fn ->
      1..100
      |> Task.async_stream(
        fn i ->
          Mesh.call(req.(Mesh.Actors.VirtualTestActor, "bench_invoke_#{i}", %{req: i}, :game))
        end,
        max_concurrency: 100,
        timeout: 10_000
      )
      |> Enum.to_list()
    end
  },
  time: 5,
  warmup: 2,
  memory_time: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true}
  ]
)

IO.puts("\n" <> String.duplicate("=", 80) <> "\n")

IO.puts("Benchmark 3: Multi-Capability Performance\n")

Benchee.run(
  %{
    "Game capability actors" => fn ->
      Enum.each(1..100, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "game_#{i}", %{action: "play"}, :game))
      end)
    end,
    "Chat capability actors" => fn ->
      Enum.each(1..100, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "chat_#{i}", %{msg: "hello"}, :chat))
      end)
    end,
    "Payment capability actors" => fn ->
      Enum.each(1..100, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "payment_#{i}", %{amount: 100}, :payment))
      end)
    end,
    "Mixed capabilities" => fn ->
      Enum.each(1..100, fn i ->
        capability = Enum.at([:game, :chat, :payment], rem(i, 3))
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "mixed_#{i}", %{data: i}, capability))
      end)
    end
  },
  time: 5,
  warmup: 2,
  memory_time: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true}
  ]
)

IO.puts("\n" <> String.duplicate("=", 80) <> "\n")

IO.puts("Benchmark 4: Hot Spot Contention (Same Actor)\n")

Mesh.call(req.(Mesh.Actors.VirtualTestActor, "hot_actor", %{init: true}, :game))
Process.sleep(100)

Benchee.run(
  %{
    "Sequential access (10 reqs)" => fn ->
      Enum.each(1..10, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "hot_actor", %{req: i}, :game))
      end)
    end,
    "Sequential access (100 reqs)" => fn ->
      Enum.each(1..100, fn i ->
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, "hot_actor", %{req: i}, :game))
      end)
    end,
    "Parallel access (10 tasks)" => fn ->
      1..10
      |> Task.async_stream(
        fn i ->
          Mesh.call(req.(Mesh.Actors.VirtualTestActor, "hot_actor", %{req: i}, :game))
        end,
        max_concurrency: 10,
        timeout: 10_000
      )
      |> Enum.to_list()
    end,
    "Parallel access (100 tasks)" => fn ->
      1..100
      |> Task.async_stream(
        fn i ->
          Mesh.call(req.(Mesh.Actors.VirtualTestActor, "hot_actor", %{req: i}, :game))
        end,
        max_concurrency: 100,
        timeout: 10_000
      )
      |> Enum.to_list()
    end
  },
  time: 5,
  warmup: 2,
  memory_time: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true}
  ]
)

IO.puts("\n" <> String.duplicate("=", 80) <> "\n")

IO.puts("Benchmark 5: Hash Ring Distribution Pattern\n")

Benchee.run(
  %{
    "Random actor IDs" => fn ->
      Enum.each(1..1_000, fn i ->
        actor_id = "random_#{:rand.uniform(100_000)}"
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, actor_id, %{req: i}, :game))
      end)
    end,
    "Sequential actor IDs" => fn ->
      Enum.each(1..1_000, fn i ->
        actor_id = "sequential_#{i}"
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, actor_id, %{req: i}, :game))
      end)
    end,
    "UUID-like actor IDs" => fn ->
      Enum.each(1..1_000, fn i ->
        actor_id = "uuid_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, actor_id, %{req: i}, :game))
      end)
    end,
    "Prefixed sequential IDs" => fn ->
      Enum.each(1..1_000, fn i ->
        prefix = Enum.at(["user", "session", "game", "room"], rem(i, 4))
        actor_id = "#{prefix}_#{i}"
        Mesh.call(req.(Mesh.Actors.VirtualTestActor, actor_id, %{req: i}, :game))
      end)
    end
  },
  time: 5,
  warmup: 2,
  memory_time: 2,
  formatters: [
    {Benchee.Formatters.Console, extended_statistics: true}
  ]
)

IO.puts("\n" <> String.duplicate("=", 80) <> "\n")

IO.puts("Final System Statistics:\n")

total_actors = :ets.info(Mesh.Actors.ActorTable, :size)
total_processes = :erlang.system_info(:process_count)
memory = :erlang.memory()

IO.puts("   Total actors: #{total_actors}")
IO.puts("   Active processes: #{total_processes}")
IO.puts("   Total memory: #{Float.round(memory[:total] / 1_048_576, 2)} MB")
IO.puts("   Processes memory: #{Float.round(memory[:processes] / 1_048_576, 2)} MB")
IO.puts("   ETS memory: #{Float.round(memory[:ets] / 1_048_576, 2)} MB")
IO.puts("   Memory per actor: #{if total_actors > 0, do: Float.round(memory[:total] / total_actors / 1024, 2), else: 0} KB")

IO.puts("\nBenchee Benchmarks completed!\n")
