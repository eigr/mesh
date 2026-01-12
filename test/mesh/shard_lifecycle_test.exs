defmodule Mesh.ShardLifecycleTest do
  @moduledoc """
  Tests for shard lifecycle: monitor recovery, orphaned actor cleanup,
  and race condition handling during shard synchronization.
  """
  use ExUnit.Case

  alias Mesh.Actors.{ActorOwner, ActorTable}
  alias Mesh.Shards.ShardRouter

  defmodule TestActor do
    use GenServer

    def start_link(actor_id, _init_arg \\ nil) do
      GenServer.start_link(__MODULE__, actor_id)
    end

    def init(actor_id) do
      {:ok, %{id: actor_id, counter: 0}}
    end

    def handle_call(:ping, _from, state) do
      {:reply, :pong, state}
    end

    def handle_call(:get_state, _from, state) do
      {:reply, state, state}
    end
  end

  defmodule CapabilityActorA do
    use GenServer

    def start_link(actor_id, _init_arg \\ nil) do
      GenServer.start_link(__MODULE__, actor_id)
    end

    def init(actor_id) do
      {:ok, actor_id}
    end

    def handle_call(:who, _from, state) do
      {:reply, :cap_a, state}
    end
  end

  defmodule CapabilityActorB do
    use GenServer

    def start_link(actor_id, _init_arg \\ nil) do
      GenServer.start_link(__MODULE__, actor_id)
    end

    def init(actor_id) do
      {:ok, actor_id}
    end

    def handle_call(:who, _from, state) do
      {:reply, :cap_b, state}
    end
  end

  setup do
    Mesh.register_capabilities([:test])
    Process.sleep(50)
    :ok
  end

  defp actor_key(actor_id) do
    ActorTable.key(:test, TestActor, actor_id)
  end

  describe "Capability isolation" do
    test "same actor id in different capabilities should not collide" do
      Mesh.register_capabilities([:test, :cap_a, :cap_b])
      Mesh.Actors.ActorOwnerSupervisor.sync_shards()
      Process.sleep(100)

      actor_id = "cap_collision_#{System.unique_integer([:positive])}"

      {:ok, pid_a, :cap_a} =
        Mesh.call(%Mesh.Request{
          module: CapabilityActorA,
          id: actor_id,
          payload: :who,
          capability: :cap_a
        })

      {:ok, pid_b, :cap_b} =
        Mesh.call(%Mesh.Request{
          module: CapabilityActorB,
          id: actor_id,
          payload: :who,
          capability: :cap_b
        })

      assert pid_a != pid_b
    end
  end

  describe "Lost monitors when ActorOwner restarts" do
    test "stale entries are cleaned up on next access after ActorOwner restart" do
      actor_id = "monitor_loss_test_#{System.unique_integer([:positive])}"

      # Step 1: Create an actor through ActorOwner
      {:ok, actor_pid, :pong} = ActorOwner.call(actor_id, :ping, TestActor, :test)

      # Verify actor is in the table
      assert {:ok, ^actor_pid, _node} = ActorTable.get(actor_key(actor_id))

      # Step 2: Find the ActorOwner for this actor's shard
      shard = ShardRouter.shard_for(actor_id)
      [{owner_pid, _}] = Registry.lookup(ActorOwnerRegistry, shard)

      # Step 3: Kill the ActorOwner (simulating a crash)
      # It should restart via DynamicSupervisor
      Process.exit(owner_pid, :kill)

      # Wait for ActorOwner to restart
      Process.sleep(100)

      # Verify ActorOwner restarted (different PID)
      [{new_owner_pid, _}] = Registry.lookup(ActorOwnerRegistry, shard)
      assert new_owner_pid != owner_pid, "ActorOwner should have restarted with new PID"

      # Step 4: The actor is still alive (it's under ActorSupervisor, not ActorOwner)
      assert Process.alive?(actor_pid), "Actor should still be alive"

      # Step 5: Now kill the actor
      Process.exit(actor_pid, :kill)

      # Wait for actor to die
      Process.sleep(100)
      refute Process.alive?(actor_pid), "Actor should be dead"

      # Step 6: ActorTable still has stale entry (lazy cleanup)
      # This is expected - cleanup happens on next access
      assert {:ok, ^actor_pid, _} = ActorTable.get(actor_key(actor_id))

      # Step 7: Next access should detect stale PID, clean up, and create new actor
      {:ok, new_actor_pid, :pong} = ActorOwner.call(actor_id, :ping, TestActor, :test)

      # New actor should have different PID
      assert new_actor_pid != actor_pid, "Should have created a new actor"

      # ActorTable should now have the new PID
      assert {:ok, ^new_actor_pid, _} = ActorTable.get(actor_key(actor_id))
    end

    test "new ActorOwner should recover monitors for existing actors" do
      actor_id = "monitor_recovery_test_#{System.unique_integer([:positive])}"

      # Create an actor
      {:ok, actor_pid, :pong} = ActorOwner.call(actor_id, :ping, TestActor, :test)

      # Get the ActorOwner
      shard = ShardRouter.shard_for(actor_id)
      [{owner_pid, _}] = Registry.lookup(ActorOwnerRegistry, shard)

      # Kill ActorOwner
      Process.exit(owner_pid, :kill)
      Process.sleep(100)

      # Wait for new ActorOwner to be registered
      :ok = wait_for_actor_owner(shard)

      # Get new ActorOwner
      [{new_owner_pid, _}] = Registry.lookup(ActorOwnerRegistry, shard)
      assert new_owner_pid != owner_pid

      # The actor should still be usable through the new ActorOwner
      # This works because ActorTable has the PID cached
      {:ok, same_pid, :pong} = ActorOwner.call(actor_id, :ping, TestActor, :test)
      assert same_pid == actor_pid, "Should reuse existing actor"

      # But the monitor is NOT re-established
      # Kill the actor - the new ActorOwner won't know
      Process.exit(actor_pid, :kill)
      Process.sleep(100)

      # BUG: Calling the actor now will fail because ActorTable has stale PID
      # and new ActorOwner didn't re-establish monitor
      result = ActorOwner.call(actor_id, :ping, TestActor, :test)

      # When fixed, this should create a new actor and succeed
      # Currently it will fail with an error because it tries to call dead PID
      assert match?({:ok, _pid, :pong}, result),
             "Should handle stale PID gracefully, got: #{inspect(result)}"
    end
  end

  describe "Orphaned actors after shard rebalancing" do
    test "actors should be terminated when shard ownership is lost" do
      actor_id = "orphan_test_#{System.unique_integer([:positive])}"

      # Create an actor
      {:ok, actor_pid, :pong} = ActorOwner.call(actor_id, :ping, TestActor, :test)
      assert Process.alive?(actor_pid)
      assert {:ok, ^actor_pid, _} = ActorTable.get(actor_key(actor_id))

      # Get the ActorOwner for this shard
      shard = ShardRouter.shard_for(actor_id)
      [{owner_pid, _}] = Registry.lookup(ActorOwnerRegistry, shard)

      # Simulate losing shard ownership by terminating ActorOwner
      :ok = DynamicSupervisor.terminate_child(Mesh.Actors.ActorOwnerSupervisor, owner_pid)

      # Verify ActorOwner is gone
      Process.sleep(50)
      assert Registry.lookup(ActorOwnerRegistry, shard) == []

      # Actor should be terminated when shard ownership is lost
      refute Process.alive?(actor_pid),
             "Actor should be terminated when shard ownership is lost"
    end

    test "ActorTable should be cleaned when shard ownership is lost" do
      actor_id = "orphan_table_test_#{System.unique_integer([:positive])}"

      # Create an actor
      {:ok, actor_pid, :pong} = ActorOwner.call(actor_id, :ping, TestActor, :test)
      assert {:ok, ^actor_pid, _} = ActorTable.get(actor_key(actor_id))

      # Get the ActorOwner and terminate it (simulating ownership loss)
      shard = ShardRouter.shard_for(actor_id)
      [{owner_pid, _}] = Registry.lookup(ActorOwnerRegistry, shard)
      :ok = DynamicSupervisor.terminate_child(Mesh.Actors.ActorOwnerSupervisor, owner_pid)

      Process.sleep(50)

      # BUG - ActorTable still has the entry pointing to (possibly dead) actor
      #
      # EXPECTED: ActorTable.get(actor_id) should return :not_found
      # ACTUAL (BUG): ActorTable still has the entry
      assert ActorTable.get(actor_key(actor_id)) == :not_found,
             "ActorTable should be cleaned when shard ownership is lost, but got: #{inspect(ActorTable.get(actor_key(actor_id)))}"
    end

    test "multiple actors in same shard should all be terminated" do
      # Create multiple actors that hash to the same shard
      # We'll create actors until we find 3 that share a shard
      shard_actors = find_actors_in_same_shard(3)

      # Verify all actors are alive
      for {_id, pid} <- shard_actors do
        assert Process.alive?(pid)
      end

      # Get the shared shard
      [{first_id, _} | _] = shard_actors
      shard = ShardRouter.shard_for(first_id)

      # Terminate the ActorOwner
      [{owner_pid, _}] = Registry.lookup(ActorOwnerRegistry, shard)
      :ok = DynamicSupervisor.terminate_child(Mesh.Actors.ActorOwnerSupervisor, owner_pid)

      Process.sleep(50)

      # BUG - All actors should be terminated, but they're not
      alive_count = Enum.count(shard_actors, fn {_id, pid} -> Process.alive?(pid) end)

      assert alive_count == 0,
             "All #{length(shard_actors)} actors should be terminated, but #{alive_count} are still alive"
    end
  end

  describe "sync_shards race condition" do
    test "concurrent sync_shards calls should not cause errors" do
      # Simulate concurrent sync_shards calls (as happens when nodeup triggers
      # both ClusterMembership and ClusterCapabilities)
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Mesh.Actors.ActorOwnerSupervisor.sync_shards()
          end)
        end

      # All should complete without errors
      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "concurrent sync_shards should not start duplicate ActorOwners" do
      # Get a shard we own
      shard = 0

      # Kill any existing owner for this shard
      case Registry.lookup(ActorOwnerRegistry, shard) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(Mesh.Actors.ActorOwnerSupervisor, pid)
          Process.sleep(50)

        [] ->
          :ok
      end

      # Concurrently try to sync shards - this could cause race where
      # multiple processes try to start the same ActorOwner
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            Mesh.Actors.ActorOwnerSupervisor.sync_shards()
          end)
        end

      Task.await_many(tasks, 5000)
      Process.sleep(100)

      # Wait for ActorOwner to stabilize
      :ok = wait_for_actor_owner(shard)

      # Should have exactly ONE ActorOwner for the shard, not duplicates
      owners = Registry.lookup(ActorOwnerRegistry, shard)

      assert length(owners) == 1,
             "Expected 1 ActorOwner for shard #{shard}, got #{length(owners)}"
    end
  end

  describe "Duplicate node monitoring" do
    test "ClusterCapabilities and ClusterMembership both monitor nodes" do
      # This test documents that both modules independently monitor nodes,
      # which can cause ordering issues during topology changes.
      #
      # We verify both are running and would receive node events.

      # Both should be alive and running
      caps_pid = Process.whereis(Mesh.Cluster.Capabilities)
      membership_pid = Process.whereis(Mesh.Cluster.Membership)

      assert caps_pid != nil, "ClusterCapabilities should be running"
      assert membership_pid != nil, "ClusterMembership should be running"

      # Both are GenServers that call :net_kernel.monitor_nodes/2 in init
      # This means both will independently receive :nodeup/:nodedown messages
      #
      # The architectural issue: when a node joins/leaves, both processes
      # handle it independently and may process events in different order.
      # ClusterCapabilities updates capability state, ClusterMembership calls sync_shards.
      # If sync_shards runs before capabilities are updated, routing is wrong.

      # Verify both are alive (the duplication exists)
      assert Process.alive?(caps_pid)
      assert Process.alive?(membership_pid)
    end

    test "capability registration and sync_shards can race" do
      # When capabilities are registered, sync_shards is called via spawn.
      # This can race with sync_shards called from ClusterMembership.

      capability = :"race_test_#{System.unique_integer([:positive])}"

      # Concurrently register capability (which spawns sync_shards)
      # and call sync_shards directly
      task1 =
        Task.async(fn ->
          Mesh.Cluster.Capabilities.register_capabilities(node(), [capability])
        end)

      task2 =
        Task.async(fn ->
          Mesh.Actors.ActorOwnerSupervisor.sync_shards()
        end)

      task3 =
        Task.async(fn ->
          Mesh.Cluster.Capabilities.register_capabilities(node(), [capability])
        end)

      # All should complete without deadlock or crash
      Task.await_many([task1, task2, task3], 5000)

      # Verify capability was registered
      caps = Mesh.Cluster.Capabilities.all_capabilities()
      assert capability in caps
    end
  end

  # Helper to wait for ActorOwner to be available for a shard
  defp wait_for_actor_owner(shard, retries \\ 20) do
    case Registry.lookup(ActorOwnerRegistry, shard) do
      [{_pid, _}] ->
        :ok

      [] when retries > 0 ->
        Process.sleep(100)
        wait_for_actor_owner(shard, retries - 1)

      [] ->
        # If not available after retries, trigger sync_shards and try once more
        Mesh.Actors.ActorOwnerSupervisor.sync_shards()
        Process.sleep(200)

        case Registry.lookup(ActorOwnerRegistry, shard) do
          [{_pid, _}] -> :ok
          [] -> {:error, :timeout}
        end
    end
  end

  # Helper to find N actors that hash to the same shard
  defp find_actors_in_same_shard(n) do
    find_actors_in_same_shard(n, %{}, 0)
  end

  defp find_actors_in_same_shard(n, shard_map, counter) when counter < 1000 do
    actor_id = "shard_test_#{counter}_#{System.unique_integer([:positive])}"
    shard = ShardRouter.shard_for(actor_id)

    # Ensure ActorOwner is available for this shard
    case wait_for_actor_owner(shard) do
      :ok ->
        {:ok, pid, :pong} = ActorOwner.call(actor_id, :ping, TestActor, :test)

        updated_map = Map.update(shard_map, shard, [{actor_id, pid}], &[{actor_id, pid} | &1])

        case Map.get(updated_map, shard) do
          actors when length(actors) >= n ->
            Enum.take(actors, n)

          _ ->
            find_actors_in_same_shard(n, updated_map, counter + 1)
        end

      {:error, :timeout} ->
        # Skip this shard and try next actor
        find_actors_in_same_shard(n, shard_map, counter + 1)
    end
  end

  defp find_actors_in_same_shard(_n, _shard_map, _counter) do
    raise "Could not find enough actors in the same shard"
  end
end
