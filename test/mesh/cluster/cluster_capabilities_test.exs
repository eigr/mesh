defmodule Mesh.Cluster.CapabilitiesTest do
  use ExUnit.Case, async: false

  setup_all do
    if Process.whereis(Mesh.Cluster.Capabilities),
      do: Process.exit(Process.whereis(Mesh.Cluster.Capabilities), :kill)

    if Process.whereis(Mesh.Cluster.Rebalancing),
      do: Process.exit(Process.whereis(Mesh.Cluster.Rebalancing), :kill)

    Process.sleep(100)
    Mesh.Cluster.Capabilities.start_link([])
    Mesh.Cluster.Rebalancing.start_link([])
    Process.sleep(200)
    :ok
  end

  setup do
    Mesh.Cluster.Capabilities.reset_state()
    :ok
  end

  alias Mesh.Cluster.Capabilities

  describe "register_capabilities/1" do
    test "registers single capability for node" do
      Capabilities.register_capabilities([:test_single])

      assert Capabilities.nodes_for(:test_single) == [node()]
    end

    test "registers multiple capabilities for node" do
      Capabilities.register_capabilities([:test_multi_1, :test_multi_2, :test_multi_3])

      assert Capabilities.nodes_for(:test_multi_1) == [node()]
      assert Capabilities.nodes_for(:test_multi_2) == [node()]
      assert Capabilities.nodes_for(:test_multi_3) == [node()]
    end

    test "handles empty list" do
      Capabilities.register_capabilities([])

      all_caps = Capabilities.all_capabilities()
      assert is_list(all_caps)
    end
  end

  describe "nodes_for/1" do
    test "returns empty list for unregistered capability" do
      assert Capabilities.nodes_for(:completely_unknown_capability_xyz) == []
    end

    test "returns nodes sorted" do
      Capabilities.register_capabilities([:test_sorted])

      nodes = Capabilities.nodes_for(:test_sorted)
      assert nodes == Enum.sort(nodes)
    end
  end

  describe "all_capabilities/0" do
    test "returns list of capabilities" do
      Capabilities.register_capabilities([:test_all_1, :test_all_2])

      capabilities = Capabilities.all_capabilities()
      assert is_list(capabilities)
      assert :test_all_1 in capabilities
      assert :test_all_2 in capabilities
    end

    test "returns sorted capabilities" do
      capabilities = Capabilities.all_capabilities()
      assert capabilities == Enum.sort(capabilities)
    end
  end
end
