defmodule Mesh.Actors.ActorTableTest do
  use ExUnit.Case

  alias Mesh.Actors.ActorTable

  setup do
    on_exit(fn ->
      :ets.delete_all_objects(ActorTable)
    end)
  end

  describe "put/3" do
    test "stores actor pid and node" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      ActorTable.put("actor_1", pid, node())

      assert {:ok, ^pid, node} = ActorTable.get("actor_1")
      assert node == node()

      Process.exit(pid, :kill)
    end

    test "overwrites existing entry" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      ActorTable.put("actor_1", pid1, node())
      ActorTable.put("actor_1", pid2, node())

      assert {:ok, ^pid2, _} = ActorTable.get("actor_1")

      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
    end

    test "handles multiple actors" do
      pids =
        for i <- 1..100 do
          pid = spawn(fn -> Process.sleep(:infinity) end)
          ActorTable.put("actor_#{i}", pid, node())
          {i, pid}
        end

      for {i, pid} <- pids do
        assert {:ok, ^pid, _} = ActorTable.get("actor_#{i}")
        Process.exit(pid, :kill)
      end
    end
  end

  describe "get/1" do
    test "returns not_found for non-existent actor" do
      assert ActorTable.get("non_existent") == :not_found
    end

    test "returns actor info after put" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      ActorTable.put("test", pid, :some_node@host)

      assert {:ok, ^pid, :some_node@host} = ActorTable.get("test")

      Process.exit(pid, :kill)
    end
  end

  describe "delete/1" do
    test "removes actor from table" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      ActorTable.put("actor_1", pid, node())

      ActorTable.delete("actor_1")

      assert ActorTable.get("actor_1") == :not_found

      Process.exit(pid, :kill)
    end

    test "handles deleting non-existent actor" do
      ActorTable.delete("non_existent")
      assert ActorTable.get("non_existent") == :not_found
    end

    test "can re-add after delete" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      ActorTable.put("actor_1", pid1, node())
      ActorTable.delete("actor_1")
      ActorTable.put("actor_1", pid2, node())

      assert {:ok, ^pid2, _} = ActorTable.get("actor_1")

      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
    end
  end

  describe "concurrent operations" do
    test "handles concurrent puts" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            pid = spawn(fn -> Process.sleep(:infinity) end)
            ActorTable.put("actor_#{i}", pid, node())
            {i, pid}
          end)
        end

      results = Task.await_many(tasks, 5000)

      for {i, pid} <- results do
        assert {:ok, ^pid, _} = ActorTable.get("actor_#{i}")
        Process.exit(pid, :kill)
      end
    end

    test "handles concurrent gets" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      ActorTable.put("shared_actor", pid, node())

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            ActorTable.get("shared_actor")
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, fn
               {:ok, ^pid, _} -> true
               _ -> false
             end)

      Process.exit(pid, :kill)
    end
  end
end
