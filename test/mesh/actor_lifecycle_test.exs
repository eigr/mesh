defmodule Mesh.ActorLifecycleTest do
  @moduledoc """
  Tests for actor lifecycle scenarios including voluntary shutdown.
  """
  use ExUnit.Case

  defmodule SelfShutdownActor do
    @moduledoc """
    Actor that self-terminates after idle period.
    Simulates resource cleanup when unused.
    """
    use GenServer

    @idle_timeout 500

    def start_link(actor_id, init_arg) do
      GenServer.start_link(__MODULE__, {actor_id, init_arg})
    end

    @impl true
    def init({actor_id, init_arg}) do
      state = %{
        id: actor_id,
        counter: init_arg[:counter] || 0,
        created_at: System.monotonic_time(:millisecond)
      }

      {:ok, state, @idle_timeout}
    end

    @impl true
    def handle_call(:get_counter, _from, state) do
      {:reply, state.counter, state, @idle_timeout}
    end

    @impl true
    def handle_call(:increment, _from, state) do
      new_state = %{state | counter: state.counter + 1}
      {:reply, new_state.counter, new_state, @idle_timeout}
    end

    @impl true
    def handle_call(:get_created_at, _from, state) do
      {:reply, state.created_at, state, @idle_timeout}
    end

    @impl true
    def handle_info(:timeout, state) do
      {:stop, :normal, state}
    end
  end

  setup do
    Mesh.Cluster.Capabilities.register_capabilities([:lifecycle_test])
    Mesh.Actors.ActorOwnerSupervisor.sync_shards()
    :ok
  end

  describe "voluntary actor shutdown" do
    test "actor shuts down after idle timeout and is recreated on next call" do
      actor_id = "shutdown_test_#{System.unique_integer([:positive])}"

      {:ok, pid1, 1} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :increment,
          capability: :lifecycle_test,
          init_arg: [counter: 0]
        })

      assert Process.alive?(pid1)

      {:ok, ^pid1, created_at1} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :get_created_at,
          capability: :lifecycle_test
        })

      {:ok, ^pid1, 2} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :increment,
          capability: :lifecycle_test
        })

      {:ok, ^pid1, 2} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :get_counter,
          capability: :lifecycle_test
        })

      # Wait for self-shutdown (500ms timeout + margin)
      Process.sleep(700)

      refute Process.alive?(pid1)

      # Actor should be recreated on next call
      {:ok, pid2, 1} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :increment,
          capability: :lifecycle_test,
          init_arg: [counter: 0]
        })

      assert pid2 != pid1
      assert Process.alive?(pid2)

      {:ok, ^pid2, 1} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :get_counter,
          capability: :lifecycle_test
        })

      {:ok, ^pid2, created_at2} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :get_created_at,
          capability: :lifecycle_test
        })

      assert created_at2 > created_at1
    end

    test "multiple actors can shutdown independently" do
      actor_ids =
        for i <- 1..5 do
          "multi_shutdown_#{System.unique_integer([:positive])}_#{i}"
        end

      pids =
        Enum.map(actor_ids, fn id ->
          {:ok, pid, _} =
            Mesh.call(%Mesh.Request{
              module: SelfShutdownActor,
              id: id,
              payload: :increment,
              capability: :lifecycle_test
            })

          {id, pid}
        end)

      Enum.each(pids, fn {_id, pid} ->
        assert Process.alive?(pid)
      end)

      Process.sleep(700)

      Enum.each(pids, fn {_id, pid} ->
        refute Process.alive?(pid)
      end)

      [id1, id2 | _rest] = actor_ids

      {:ok, new_pid1, _} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: id1,
          payload: :get_counter,
          capability: :lifecycle_test
        })

      {:ok, new_pid2, _} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: id2,
          payload: :get_counter,
          capability: :lifecycle_test
        })

      assert Process.alive?(new_pid1)
      assert Process.alive?(new_pid2)

      {^id1, old_pid1} = Enum.find(pids, fn {id, _} -> id == id1 end)
      {^id2, old_pid2} = Enum.find(pids, fn {id, _} -> id == id2 end)

      assert new_pid1 != old_pid1
      assert new_pid2 != old_pid2
    end

    test "rapid calls prevent shutdown by resetting timeout" do
      actor_id = "no_shutdown_#{System.unique_integer([:positive])}"

      {:ok, pid, _} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :increment,
          capability: :lifecycle_test
        })

      # Call every 300ms (before 500ms timeout) for 1.5s
      for _ <- 1..5 do
        Process.sleep(300)

        {:ok, ^pid, _} =
          Mesh.call(%Mesh.Request{
            module: SelfShutdownActor,
            id: actor_id,
            payload: :increment,
            capability: :lifecycle_test
          })

        assert Process.alive?(pid)
      end

      assert Process.alive?(pid)

      Process.sleep(700)
      refute Process.alive?(pid)
    end
  end

  describe "actor table cleanup after voluntary shutdown" do
    test "actor is removed from table after shutdown" do
      actor_id = "table_cleanup_#{System.unique_integer([:positive])}"

      {:ok, pid, _} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :increment,
          capability: :lifecycle_test
        })

      assert {:ok, ^pid, _node} = Mesh.Actors.ActorTable.get(actor_id)

      Process.sleep(700)
      refute Process.alive?(pid)

      # Allow time for ActorOwner to process DOWN message
      Process.sleep(100)

      assert :not_found = Mesh.Actors.ActorTable.get(actor_id)

      {:ok, new_pid, _} =
        Mesh.call(%Mesh.Request{
          module: SelfShutdownActor,
          id: actor_id,
          payload: :get_counter,
          capability: :lifecycle_test
        })

      assert new_pid != pid
      assert {:ok, ^new_pid, _node} = Mesh.Actors.ActorTable.get(actor_id)
    end
  end
end
