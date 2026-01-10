defmodule Mesh.Actors.ActorOwnerTest do
  use ExUnit.Case

  alias Mesh.Actors.ActorOwner

  defmodule TestActor do
    use GenServer

    def start_link(actor_id, _init_arg \\ nil) do
      GenServer.start_link(__MODULE__, actor_id)
    end

    def init(actor_id) do
      {:ok, %{id: actor_id, counter: 0}}
    end

    def handle_call(:increment, _from, state) do
      new_state = %{state | counter: state.counter + 1}
      {:reply, new_state.counter, new_state}
    end

    def handle_call(:get_counter, _from, state) do
      {:reply, state.counter, state}
    end

    def handle_call(:crash, _from, _state) do
      raise "intentional crash"
    end

    def handle_cast(:increment, state) do
      new_state = %{state | counter: state.counter + 1}
      {:noreply, new_state}
    end
  end

  defmodule SlowActor do
    use GenServer

    def start_link(actor_id, _init_arg \\ nil) do
      GenServer.start_link(__MODULE__, actor_id)
    end

    def init(actor_id) do
      {:ok, actor_id}
    end

    def handle_call(:slow_operation, _from, state) do
      Process.sleep(100)
      {:reply, :done, state}
    end
  end

  setup do
    Mesh.register_capabilities([:test])
    Process.sleep(50)
    :ok
  end

  describe "call/4" do
    test "creates actor on first call" do
      {:ok, pid, result} = ActorOwner.call("new_actor", :increment, TestActor, :test)

      assert is_pid(pid)
      assert result == 1
    end

    test "reuses existing actor on subsequent calls" do
      {:ok, pid1, _} = ActorOwner.call("persistent_actor", :increment, TestActor, :test)
      {:ok, pid2, result} = ActorOwner.call("persistent_actor", :increment, TestActor, :test)

      assert pid1 == pid2
      assert result == 2
    end

    test "isolates state between different actor_ids" do
      {:ok, _, result1} = ActorOwner.call("actor_a", :increment, TestActor, :test)
      {:ok, _, result2} = ActorOwner.call("actor_b", :increment, TestActor, :test)
      {:ok, _, result3} = ActorOwner.call("actor_a", :increment, TestActor, :test)

      assert result1 == 1
      assert result2 == 1
      assert result3 == 2
    end

    test "handles concurrent calls to same actor" do
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            ActorOwner.call("concurrent_actor", :increment, TestActor, :test)
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert length(results) == 10
      assert Enum.all?(results, fn {:ok, _pid, _result} -> true end)

      {:ok, _, final_count} = ActorOwner.call("concurrent_actor", :get_counter, TestActor, :test)
      assert final_count == 10
    end

    test "handles concurrent calls to different actors" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            ActorOwner.call("actor_#{i}", :increment, TestActor, :test)
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert length(results) == 50
      assert Enum.all?(results, fn {:ok, _pid, result} -> result == 1 end)
    end

    test "cleans up actor entry when process crashes" do
      {:ok, pid, _} = ActorOwner.call("crash_test", :get_counter, TestActor, :test)

      Process.exit(pid, :kill)
      Process.sleep(100)

      {:ok, new_pid, _} = ActorOwner.call("crash_test", :get_counter, TestActor, :test)
      assert new_pid != pid
    end

    test "handles slow operations without blocking other actors" do
      Task.async(fn ->
        ActorOwner.call("slow_actor", :slow_operation, SlowActor, :test)
      end)

      Process.sleep(10)

      start_time = System.monotonic_time(:millisecond)
      {:ok, _, _} = ActorOwner.call("fast_actor", :increment, TestActor, :test)
      duration = System.monotonic_time(:millisecond) - start_time

      assert duration < 50
    end
  end

  describe "cast/4" do
    test "sends message without waiting for response" do
      {:ok, _pid, 0} = ActorOwner.call("cast_test_unique", :get_counter, TestActor, :test)

      result = ActorOwner.cast("cast_test_unique", :increment, TestActor, :test)
      assert result == :ok
    end
  end

  describe "actor lifecycle" do
    test "actor process is supervised" do
      {:ok, pid, _} = ActorOwner.call("supervised_actor", :increment, TestActor, :test)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    end

    test "new actor created after crash with clean state" do
      {:ok, _, _} = ActorOwner.call("lifecycle_test", :increment, TestActor, :test)
      {:ok, _, result} = ActorOwner.call("lifecycle_test", :increment, TestActor, :test)
      assert result == 2

      {:ok, pid, _} = ActorOwner.call("lifecycle_test", :get_counter, TestActor, :test)
      Process.exit(pid, :kill)
      Process.sleep(100)

      {:ok, _, new_result} = ActorOwner.call("lifecycle_test", :increment, TestActor, :test)
      assert new_result == 1
    end
  end
end
