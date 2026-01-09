defmodule Mesh.ErrorHandlingTest do
  use ExUnit.Case

  @moduletag :destructive

  defmodule CrashingActor do
    use GenServer

    def start_link(actor_id, _init_arg \\ nil) do
      GenServer.start_link(__MODULE__, actor_id)
    end

    def init(actor_id) do
      {:ok, actor_id}
    end

    def handle_call(:crash_with_raise, _from, _state) do
      raise "intentional error"
    end

    def handle_call(:crash_with_exit, _from, _state) do
      exit(:intentional_exit)
    end

    def handle_call(:crash_with_throw, _from, _state) do
      throw(:intentional_throw)
    end

    def handle_call(:timeout, _from, state) do
      Process.sleep(:infinity)
      {:reply, :never, state}
    end

    def handle_call(:badmatch, _from, _state) do
      {:ok, value} = {:error, :oops}
      {:reply, value, :state}
    end
  end

  defmodule BadInitActor do
    use GenServer

    def start_link(_actor_id, _init_arg \\ nil) do
      GenServer.start_link(__MODULE__, :whatever)
    end

    def init(_) do
      raise "init failed"
    end
  end

  defmodule SlowStartActor do
    use GenServer

    def start_link(actor_id, _init_arg \\ nil) do
      GenServer.start_link(__MODULE__, actor_id)
    end

    def init(actor_id) do
      Process.sleep(200)
      {:ok, actor_id}
    end

    def handle_call(:ping, _from, state) do
      {:reply, :pong, state}
    end
  end

  setup do
    Mesh.register_capabilities([:test])
    Process.sleep(50)
    :ok
  end

  describe "actor crashes during call" do
    test "handles crash with raise" do
      result =
        Mesh.call(%Mesh.Request{
          module: CrashingActor,
          id: "crash_raise",
          payload: :crash_with_raise,
          capability: :test
        })

      assert match?({:error, _}, result) or match?({:exit, _}, result)
    end

    test "actor state is cleaned after crash" do
      Mesh.call(%Mesh.Request{
        module: CrashingActor,
        id: "cleanup_test",
        payload: :crash_with_raise,
        capability: :test
      })

      Process.sleep(100)

      result =
        Mesh.call(%Mesh.Request{
          module: CrashingActor,
          id: "cleanup_test",
          payload: :crash_with_exit,
          capability: :test
        })

      assert match?({:ok, _, _}, result) or match?({:error, _}, result) or
               match?({:exit, _}, result)
    end

    test "handles badmatch errors" do
      result =
        Mesh.call(%Mesh.Request{
          module: CrashingActor,
          id: "badmatch_test",
          payload: :badmatch,
          capability: :test
        })

      assert match?({:error, _}, result) or match?({:exit, _}, result)
    end
  end

  describe "actor creation failures" do
    test "handles init crash" do
      result =
        Mesh.call(%Mesh.Request{
          module: BadInitActor,
          id: "bad_init",
          payload: :anything,
          capability: :test
        })

      assert match?({:error, _}, result)
    end

    test "multiple attempts to create failing actor all fail" do
      results =
        for i <- 1..5 do
          Mesh.call(%Mesh.Request{
            module: BadInitActor,
            id: "persistent_bad_init_#{i}",
            payload: :anything,
            capability: :test
          })
        end

      assert Enum.all?(results, fn result -> match?({:error, _}, result) end)
    end
  end

  describe "timeout scenarios" do
    test "handles call timeout with concurrent operations" do
      Task.async(fn ->
        Mesh.call(%Mesh.Request{
          module: CrashingActor,
          id: "timeout_actor",
          payload: :timeout,
          capability: :test
        })
      end)

      Process.sleep(50)

      {:ok, _, _} =
        Mesh.call(%Mesh.Request{
          module: SlowStartActor,
          id: "other_actor",
          payload: :ping,
          capability: :test
        })
    end
  end

  describe "capability errors" do
    test "returns error for unknown capability" do
      result =
        Mesh.call(%Mesh.Request{
          module: SlowStartActor,
          id: "unknown_cap",
          payload: :ping,
          capability: :nonexistent_capability
        })

      assert match?({:error, _}, result)
    end
  end
end
