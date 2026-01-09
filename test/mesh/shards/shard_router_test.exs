defmodule Mesh.Shards.ShardRouterTest do
  use ExUnit.Case

  alias Mesh.Shards.ShardRouter

  describe "shard_for/1" do
    test "returns consistent shard for same actor_id" do
      actor_id = "test_actor_123"
      shard1 = ShardRouter.shard_for(actor_id)
      shard2 = ShardRouter.shard_for(actor_id)

      assert shard1 == shard2
    end

    test "returns shard within valid range" do
      shard_count = Mesh.Shards.ShardConfig.shard_count()

      for i <- 1..1000 do
        shard = ShardRouter.shard_for("actor_#{i}")
        assert shard >= 0
        assert shard < shard_count
      end
    end

    test "distributes different actor_ids across different shards" do
      shards =
        1..1000
        |> Enum.map(&ShardRouter.shard_for("actor_#{&1}"))
        |> Enum.uniq()

      assert length(shards) > 100
    end

    test "handles empty string" do
      shard = ShardRouter.shard_for("")
      assert is_integer(shard)
    end

    test "handles unicode characters" do
      shard = ShardRouter.shard_for("测试_actor_🎮")
      assert is_integer(shard)
    end

    test "handles very long actor_ids" do
      long_id = String.duplicate("a", 10_000)
      shard = ShardRouter.shard_for(long_id)
      assert is_integer(shard)
    end
  end

  describe "owner_node/2" do
    setup do
      Mesh.register_capabilities([:test_cap])
      Process.sleep(50)
      :ok
    end

    test "returns current node for single node cluster" do
      shard = ShardRouter.shard_for("test_actor")
      {:ok, node} = ShardRouter.owner_node(shard, :test_cap)

      assert node == node()
    end

    test "returns error for unknown capability" do
      shard = ShardRouter.shard_for("test_actor")
      result = ShardRouter.owner_node(shard, :unknown_capability)

      assert {:error, :no_nodes} = result
    end

    test "deterministic node selection across multiple calls" do
      shard = ShardRouter.shard_for("test_actor")

      {:ok, node1} = ShardRouter.owner_node(shard, :test_cap)
      {:ok, node2} = ShardRouter.owner_node(shard, :test_cap)
      {:ok, node3} = ShardRouter.owner_node(shard, :test_cap)

      assert node1 == node2
      assert node2 == node3
    end
  end
end
