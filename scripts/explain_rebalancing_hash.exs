#!/usr/bin/env elixir
# Script to explain why only some actors change nodes during rebalancing

IO.puts("\n=== Understanding Rebalancing: Why Only Some Actors Move ===\n")

# Simular a configuração
shard_count = 4096
total_shards = shard_count

IO.puts("Configuration:")
IO.puts("  Total shards: #{total_shards}")
IO.puts("  Hash strategy: EventualConsistency (modulo-based)\n")

# Criar 20 actor IDs do teste
actor_ids = for i <- 1..20, do: "game_#{i}"

IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
IO.puts("STEP 1: Mapping actors to shards")
IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

# Mapear cada ator para seu shard (isso NUNCA muda!)
actor_to_shard = 
  for actor_id <- actor_ids do
    shard = :erlang.phash2(actor_id, total_shards)
    {actor_id, shard}
  end

IO.puts("Actor ID -> Shard mapping (NEVER changes):")
Enum.each(actor_to_shard, fn {actor_id, shard} ->
  IO.puts("  #{String.pad_trailing(actor_id, 10)} -> shard #{shard}")
end)

IO.puts("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
IO.puts("STEP 2: Before adding node3 (1 node with :game capability)")
IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

nodes_before = ["game_node_1@127.0.0.1"] |> Enum.sort()
IO.puts("Nodes: #{inspect(nodes_before)}")
IO.puts("Node count: #{length(nodes_before)}\n")

# Calcular ownership ANTES (1 node)
ownership_before =
  Enum.map(actor_to_shard, fn {actor_id, shard} ->
    # EventualConsistency: rem(shard, node_count)
    node_idx = rem(shard, length(nodes_before))
    owner = Enum.at(nodes_before, node_idx)
    {actor_id, shard, owner}
  end)

IO.puts("Shard -> Node ownership (with 1 node):")
unique_shards_before = 
  ownership_before
  |> Enum.map(fn {_actor_id, shard, owner} -> {shard, owner} end)
  |> Enum.uniq()
  |> Enum.sort()

Enum.each(unique_shards_before, fn {shard, owner} ->
  actors_in_shard = Enum.filter(ownership_before, fn {_, s, _} -> s == shard end)
  IO.puts("  shard #{String.pad_leading("#{shard}", 4)} -> #{owner} (#{length(actors_in_shard)} actors)")
end)

IO.puts("\nAll actors on: #{Enum.at(nodes_before, 0)}")

IO.puts("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
IO.puts("STEP 3: After adding node3 (2 nodes with :game capability)")
IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

nodes_after = ["game_node2_1@127.0.0.1", "game_node_1@127.0.0.1"] |> Enum.sort()
IO.puts("Nodes: #{inspect(nodes_after)}")
IO.puts("Node count: #{length(nodes_after)}\n")

# Calcular ownership DEPOIS (2 nodes)
ownership_after =
  Enum.map(actor_to_shard, fn {actor_id, shard} ->
    # EventualConsistency: rem(shard, node_count)
    node_idx = rem(shard, length(nodes_after))
    owner = Enum.at(nodes_after, node_idx)
    {actor_id, shard, owner}
  end)

IO.puts("Shard -> Node ownership (with 2 nodes):")
unique_shards_after = 
  ownership_after
  |> Enum.map(fn {_actor_id, shard, owner} -> {shard, owner} end)
  |> Enum.uniq()
  |> Enum.sort()

Enum.each(unique_shards_after, fn {shard, owner} ->
  actors_in_shard = Enum.filter(ownership_after, fn {_, s, _} -> s == shard end)
  IO.puts("  shard #{String.pad_leading("#{shard}", 4)} -> #{owner} (#{length(actors_in_shard)} actors)")
end)

node1_count = Enum.count(ownership_after, fn {_, _, owner} -> owner == Enum.at(nodes_after, 0) end)
node2_count = Enum.count(ownership_after, fn {_, _, owner} -> owner == Enum.at(nodes_after, 1) end)

IO.puts("\nDistribution:")
IO.puts("  #{Enum.at(nodes_after, 0)}: #{node1_count} actors")
IO.puts("  #{Enum.at(nodes_after, 1)}: #{node2_count} actors")

IO.puts("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
IO.puts("STEP 4: Calculating ownership changes (what rebalancing does)")
IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

# Comparar ownership
changes = 
  Enum.zip(ownership_before, ownership_after)
  |> Enum.filter(fn {{_, _, owner_before}, {_, _, owner_after}} ->
    owner_before != owner_after
  end)

IO.puts("Actors that changed ownership:")
Enum.each(changes, fn {{actor_id, shard, owner_before}, {_, _, owner_after}} ->
  IO.puts("  #{String.pad_trailing(actor_id, 10)} (shard #{String.pad_leading("#{shard}", 4)}): #{owner_before} -> #{owner_after}")
end)

stayed = 20 - length(changes)

IO.puts("\n" <> String.duplicate("━", 58))
IO.puts("SUMMARY")
IO.puts(String.duplicate("━", 58) <> "\n")

IO.puts("Why only #{length(changes)} of 20 actors changed?")
IO.puts("")
IO.puts("1. **Actor -> Shard mapping NEVER changes**")
IO.puts("   Each actor is always mapped to the same shard number via")
IO.puts("   phash2(actor_id, 4096)")
IO.puts("")
IO.puts("2. **Shard -> Node ownership DOES change**")
IO.puts("   With 1 node:  owner = nodes[rem(shard, 1)] = nodes[0]")
IO.puts("   With 2 nodes: owner = nodes[rem(shard, 2)] = nodes[0 or 1]")
IO.puts("")
IO.puts("3. **Only shards with CHANGED ownership affect actors**")
IO.puts("   Before: all shards point to node1 (rem(shard, 1) always = 0)")
IO.puts("   After:  some shards point to node1 (rem(shard, 2) = 0)")
IO.puts("           some shards point to node2 (rem(shard, 2) = 1)")
IO.puts("")
IO.puts("4. **Distribution is based on shard number, not actor count**")
IO.puts("   Shards are evenly distributed: ~50% stay, ~50% move")
IO.puts("   But actors per shard vary, so actor distribution may differ")
IO.puts("")

IO.puts("Result:")
IO.puts("  Actors that changed: #{length(changes)} (#{Float.round(length(changes) / 20 * 100, 1)}%)")
IO.puts("  Actors that stayed:  #{stayed} (#{Float.round(stayed / 20 * 100, 1)}%)")
IO.puts("")

# Análise de shards
shards_used = Enum.map(actor_to_shard, fn {_, shard} -> shard end) |> Enum.uniq()
shards_changed = 
  Enum.count(shards_used, fn shard ->
    owner_before = Enum.at(nodes_before, rem(shard, length(nodes_before)))
    owner_after = Enum.at(nodes_after, rem(shard, length(nodes_after)))
    owner_before != owner_after
  end)

IO.puts("Shard analysis:")
IO.puts("  Unique shards used: #{length(shards_used)}")
IO.puts("  Shards that changed: #{shards_changed} (#{Float.round(shards_changed / length(shards_used) * 100, 1)}%)")
IO.puts("  Shards that stayed:  #{length(shards_used) - shards_changed} (#{Float.round((length(shards_used) - shards_changed) / length(shards_used) * 100, 1)}%)")
IO.puts("")

IO.puts("✅ This is CORRECT behavior!")
IO.puts("   The rebalancing system correctly identifies which shards")
IO.puts("   changed ownership and only stops actors on those shards.")
IO.puts("")
