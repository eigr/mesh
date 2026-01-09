defmodule Mesh.StressTest do
  use ExUnit.Case

  @moduletag :stress

  defmodule CrashingActor do
    use GenServer

    def start_link(actor_id, _init_arg) do
      GenServer.start_link(__MODULE__, actor_id)
    end

    @impl true
    def init(actor_id), do: {:ok, actor_id}

    @impl true
    def handle_call(:crash_with_raise, _from, state) do
      raise "intentional error"
      {:reply, :ok, state}
    end
  end

  describe "concurrent stress scenarios" do
    test "handles rapid actor creation and destruction" do
      Mesh.Cluster.Capabilities.register_capabilities([:stress_test])

      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            Mesh.call(%Mesh.Request{
              module: CrashingActor,
              id: "stress_actor_#{i}",
              payload: :crash_with_raise,
              capability: :stress_test
            })
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, fn result ->
               match?({:error, _}, result) or match?({:exit, _}, result)
             end)
    end

    test "handles mixed successful and failing operations" do
      Mesh.Cluster.Capabilities.register_capabilities([:stress_test])

      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              Mesh.call(%Mesh.Request{
                module: CrashingActor,
                id: "mixed_#{i}",
                payload: :crash_with_raise,
                capability: :stress_test
              })
            else
              {:ok, "success_#{i}"}
            end
          end)
        end

      results = Task.await_many(tasks, 5000)

      successes = Enum.count(results, fn r -> match?({:ok, _}, r) end)
      failures = Enum.count(results, fn r -> match?({:error, _}, r) or match?({:exit, _}, r) end)

      assert successes > 0
      assert failures > 0
    end
  end
end
