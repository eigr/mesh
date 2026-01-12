defmodule MeshTest do
  use ExUnit.Case
  doctest Mesh

  setup do
    if Process.whereis(Mesh.Cluster.Rebalancing), do: Mesh.Cluster.Rebalancing.reset_state()
    if Process.whereis(Mesh.Cluster.Capabilities), do: Mesh.Cluster.Capabilities.reset_state()
    Mesh.register_capabilities([:test])
    :ok
  end

  describe "call/1" do
    test "creates process on first invocation" do
      actor_id = "test_actor_#{:rand.uniform(1_000_000)}"

      assert {:ok, pid, response} =
               Mesh.call(%Mesh.Request{
                 module: Mesh.Actors.VirtualTestActor,
                 id: actor_id,
                 payload: %{action: "test"},
                 capability: :test
               })

      assert is_pid(pid)
      assert is_map(response)
    end

    test "reuses same process on subsequent invocations" do
      actor_id = "test_actor_#{:rand.uniform(1_000_000)}"

      assert {:ok, pid1, _} =
               Mesh.call(%Mesh.Request{
                 module: Mesh.Actors.VirtualTestActor,
                 id: actor_id,
                 payload: %{action: "first"},
                 capability: :test
               })

      assert {:ok, pid2, _} =
               Mesh.call(%Mesh.Request{
                 module: Mesh.Actors.VirtualTestActor,
                 id: actor_id,
                 payload: %{action: "second"},
                 capability: :test
               })

      assert pid1 == pid2
    end

    test "returns error when no nodes support capability" do
      actor_id = "test_actor_#{:rand.uniform(1_000_000)}"

      assert {:error, _reason} =
               Mesh.call(%Mesh.Request{
                 module: Mesh.Actors.VirtualTestActor,
                 id: actor_id,
                 payload: %{action: "test"},
                 capability: :unknown_capability
               })
    end
  end

  describe "register_capabilities/1" do
    test "registers capabilities for current node" do
      Mesh.register_capabilities([:test, :game])
      Process.sleep(50)

      capabilities = Mesh.all_capabilities()
      assert :test in capabilities
      assert :game in capabilities
    end
  end

  describe "nodes_for/1" do
    test "returns nodes that support capability" do
      Mesh.register_capabilities([:test])
      Process.sleep(50)

      nodes = Mesh.nodes_for(:test)
      assert node() in nodes
    end

    test "returns empty list for unsupported capability" do
      nodes = Mesh.nodes_for(:nonexistent)
      assert nodes == []
    end
  end

  describe "shard_for/1" do
    test "returns consistent shard for same actor_id" do
      shard1 = Mesh.shard_for("player_123")
      shard2 = Mesh.shard_for("player_123")

      assert shard1 == shard2
      assert is_integer(shard1)
      assert shard1 >= 0
      assert shard1 < 4096
    end

    test "returns different shards for different actor_ids" do
      shard1 = Mesh.shard_for("player_123")
      shard2 = Mesh.shard_for("player_456")

      # Very unlikely to be same with 4096 shards
      assert shard1 != shard2
    end
  end

  describe "owner_node/2" do
    test "returns ok tuple with owner node" do
      Mesh.register_capabilities([:test])
      Process.sleep(50)

      shard = Mesh.shard_for("test_actor")
      assert {:ok, owner} = Mesh.owner_node(shard, :test)
      assert is_atom(owner)
    end

    test "returns error for unsupported capability" do
      shard = Mesh.shard_for("test_actor")
      assert {:error, :no_nodes} = Mesh.owner_node(shard, :nonexistent)
    end
  end
end
