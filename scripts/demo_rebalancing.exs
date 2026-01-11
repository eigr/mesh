#!/usr/bin/env elixir

# Script to demonstrate coordinated rebalancing
# Run with: mix run scripts/demo_rebalancing.exs
IO.puts("\n=== Mesh Coordinated Rebalancing Demo ===\n")

{:ok, _pid} = Mesh.Supervisor.start_link()
Process.sleep(100)

req = fn module, id, payload, capability ->
  %Mesh.Request{module: module, id: id, payload: payload, capability: capability}
end

IO.puts("Step 1: Register initial capability [:game]")
Mesh.register_capabilities([:game])
Process.sleep(500)

IO.puts("\nStep 2: Create 10 actors")
actors_created = 
  for i <- 1..10 do
    case Mesh.call(req.(Mesh.Actors.VirtualTestActor, "actor_#{i}", %{test: true}, :game)) do
      {:ok, pid, _reply} -> 
        IO.puts("  ✓ Created actor_#{i} (PID: #{inspect(pid)})")
        {i, pid}
      error -> 
        IO.puts("  ✗ Failed to create actor_#{i}: #{inspect(error)}")
        nil
    end
  end
  |> Enum.reject(&is_nil/1)

IO.puts("\nStep 3: Verify actors are in table")
actor_count = :ets.info(Mesh.Actors.ActorTable, :size)
IO.puts("  Actors in table: #{actor_count}")

IO.puts("\nStep 4: Register additional capability [:chat] (triggers rebalancing)")
IO.puts("  Note: Since we're single-node, no shards should change ownership")
Mesh.register_capabilities([:chat])
Process.sleep(500)

IO.puts("\nStep 5: Check if actors are still alive")
alive_count = 
  Enum.count(actors_created, fn {i, pid} ->
    if Process.alive?(pid) do
      IO.puts("  ✓ actor_#{i} still alive (PID: #{inspect(pid)})")
      true
    else
      IO.puts("  ✗ actor_#{i} is dead (PID: #{inspect(pid)})")
      false
    end
  end)

IO.puts("\nStep 6: Create new actors with [:chat] capability")
for i <- 11..15 do
  case Mesh.call(req.(Mesh.Actors.VirtualTestActor, "chat_#{i}", %{test: true}, :chat)) do
    {:ok, pid, _reply} -> 
      IO.puts("  ✓ Created chat_#{i} (PID: #{inspect(pid)})")
    error -> 
      IO.puts("  ✗ Failed to create chat_#{i}: #{inspect(error)}")
  end
end

IO.puts("\n=== Summary ===")
IO.puts("Initial actors created: #{length(actors_created)}")
IO.puts("Actors still alive after rebalancing: #{alive_count}")
IO.puts("Total actors in table: #{:ets.info(Mesh.Actors.ActorTable, :size)}")
IO.puts("Rebalancing mode: #{Mesh.Cluster.Rebalancing.mode()}")

if alive_count == length(actors_created) do
  IO.puts("\n✅ SUCCESS: All actors survived rebalancing!")
else
  IO.puts("\n⚠️  WARNING: Some actors were stopped during rebalancing")
end

IO.puts("")
