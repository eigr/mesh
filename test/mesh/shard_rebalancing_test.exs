defmodule Mesh.ShardRebalancingTest do
  use ExUnit.Case, async: false

  alias Mesh.Shards.ShardRouter
  alias Mesh.TestActor

  @tag :rebalancing
  test "rebalancing clears actor entries on the previous owner" do
    {node_a, node_b} = spawn_rebalance_nodes()

    on_exit(fn -> NodeHelper.stop_nodes([node_a, node_b]) end)

    NodeHelper.register_capabilities(node_a, [:rebalancing_test])
    NodeHelper.sync_all_shards([node_a])

    actor_id = find_actor_id_for_owner(Enum.sort([node_a, node_b]), node_b)

    {:ok, pid_a, :pong} =
      NodeHelper.rpc(node_a, Mesh.Actors.ActorOwner, :call, [
        actor_id,
        :ping,
        TestActor,
        :rebalancing_test
      ])

    NodeHelper.register_capabilities(node_b, [:rebalancing_test])
    await_nodes(node_a, :rebalancing_test, [node_a, node_b])
    NodeHelper.sync_all_shards([node_a, node_b])

    {:ok, pid_b, :pong} =
      NodeHelper.rpc(node_b, Mesh.Actors.ActorOwner, :call, [
        actor_id,
        :ping,
        TestActor,
        :rebalancing_test
      ])

    assert pid_a != pid_b

    # Old owner should drop its entry once ownership changes.
    actor_key = Mesh.Actors.ActorTable.key(:rebalancing_test, TestActor, actor_id)

    assert :not_found == NodeHelper.rpc(node_a, Mesh.Actors.ActorTable, :get, [actor_key])
  end

  @tag :rebalancing
  test "actors terminate when shard ownership moves to another node" do
    {node_a, node_b} = spawn_rebalance_nodes()

    on_exit(fn -> NodeHelper.stop_nodes([node_a, node_b]) end)

    NodeHelper.register_capabilities(node_a, [:rebalancing_test])
    NodeHelper.sync_all_shards([node_a])

    actor_id = find_actor_id_for_owner(Enum.sort([node_a, node_b]), node_b)

    {:ok, pid_a, :pong} =
      NodeHelper.rpc(node_a, Mesh.Actors.ActorOwner, :call, [
        actor_id,
        :ping,
        TestActor,
        :rebalancing_test
      ])

    assert NodeHelper.rpc(node_a, Process, :alive?, [pid_a])

    NodeHelper.register_capabilities(node_b, [:rebalancing_test])
    await_nodes(node_a, :rebalancing_test, [node_a, node_b])
    NodeHelper.sync_all_shards([node_a, node_b])

    shard = ShardRouter.shard_for(actor_id)
    {:ok, owner} = NodeHelper.rpc(node_a, ShardRouter, :owner_node, [shard, :rebalancing_test])

    assert owner == node_b

    # Old owner should terminate the actor once ownership changes.
    refute NodeHelper.rpc(node_a, Process, :alive?, [pid_a])
  end

  defp spawn_rebalance_nodes do
    unique = System.unique_integer([:positive])
    node_a = NodeHelper.spawn_peer("rebalance_a_#{unique}", applications: [:mesh])
    node_b = NodeHelper.spawn_peer("rebalance_b_#{unique}", applications: [:mesh])

    {node_a, node_b}
  end

  defp find_actor_id_for_owner(nodes, owner) do
    Enum.find_value(1..50_000, fn i ->
      actor_id = "rebalance_actor_#{i}"
      shard = ShardRouter.shard_for(actor_id)
      selected = Enum.at(nodes, rem(shard, length(nodes)))

      if selected == owner do
        actor_id
      else
        nil
      end
    end) ||
      flunk("Could not find actor_id mapping to #{inspect(owner)}")
  end

  defp await_nodes(node, capability, expected_nodes, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    expected = Enum.sort(expected_nodes)

    await_nodes_until(node, capability, expected, deadline)
  end

  defp await_nodes_until(node, capability, expected, deadline) do
    current =
      NodeHelper.rpc(node, Mesh.Cluster.Capabilities, :nodes_for, [capability])
      |> Enum.sort()

    cond do
      current == expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "Timed out waiting for #{inspect(capability)} nodes on #{inspect(node)}. " <>
            "Expected #{inspect(expected)}, got #{inspect(current)}"
        )

      true ->
        Process.sleep(50)
        await_nodes_until(node, capability, expected, deadline)
    end
  end
end
