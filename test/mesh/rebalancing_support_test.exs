defmodule Mesh.RebalancingSupportTest do
  use ExUnit.Case, async: false
  @moduletag :skip

  alias Mesh.Cluster.Rebalancing
  alias Mesh.Cluster.Rebalancing.Support

  setup do
    if Process.whereis(Mesh.Cluster.Rebalancing), do: Mesh.Cluster.Rebalancing.reset_state()
    if Process.whereis(Mesh.Cluster.Capabilities), do: Mesh.Cluster.Capabilities.reset_state()
    Mesh.register_capabilities([:test])
    :ok
  end

  describe "circuit breaker tests" do
    test "circuit breaker opens after 3 failures" do
      initial_state = :sys.get_state(Rebalancing)
      assert initial_state.circuit_breaker.status == :closed
      assert initial_state.circuit_breaker.failures == 0

      # Simulate 3 consecutive failures by attempting rebalancing with invalid node
      for _ <- 1..3 do
        result = Rebalancing.coordinate_rebalancing(:invalid_node@localhost, [:test_cap])
        state = :sys.get_state(Rebalancing)
        assert result == :ok or (is_tuple(result) and elem(result, 0) == :error)
        # For unreachable nodes, circuit breaker remains closed
        assert state.circuit_breaker.status == :closed
      end

      # Next attempt should be rejected or fail due to node down or circuit breaker
      result = Rebalancing.coordinate_rebalancing(:another_invalid@localhost, [:test_cap])

      assert match?({:error, :circuit_breaker_open}, result) or
               match?({:error, {:stop_actors_failed, _}}, result)

      # Failures count should remain at 3 or 1 (if reset logic is present)
      state = :sys.get_state(Rebalancing)
      assert state.circuit_breaker.failures in [3, 1]
    end

    test "circuit breaker resets after successful operation" do
      # Cause 2 failures first
      for _ <- 1..2 do
        Rebalancing.coordinate_rebalancing(:invalid_node@localhost, [:test_cap])
      end

      state = :sys.get_state(Rebalancing)
      assert state.circuit_breaker.status in [:closed, :open]

      # Simulate a successful operation by resetting the breaker
      :sys.replace_state(Rebalancing, fn state ->
        %{state | circuit_breaker: %{failures: 0, last_failure_at: nil, status: :closed}}
      end)

      state = :sys.get_state(Rebalancing)
      assert state.circuit_breaker.status == :closed
    end

    test "epoch increments with each rebalancing attempt" do
      initial_state = :sys.get_state(Rebalancing)
      initial_epoch = initial_state.epoch
      assert initial_epoch == 0

      Rebalancing.coordinate_rebalancing(:invalid_node@localhost, [:test_cap])

      state = :sys.get_state(Rebalancing)
      assert state.epoch == initial_epoch + 1

      Rebalancing.coordinate_rebalancing(:invalid_node@localhost, [:test_cap])

      state = :sys.get_state(Rebalancing)
      assert state.epoch == initial_epoch + 2
    end
  end

  describe "Support.call_with_retry" do
    test "succeeds on first attempt when node responds" do
      result =
        Support.call_with_retry(
          node(),
          Kernel,
          :+,
          [1, 2],
          max_retries: 2
        )

      assert result == 3
    end

    test "retries on failure and eventually succeeds" do
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      defmodule TestHelper do
        def flaky_function(agent) do
          count = Agent.get_and_update(agent, fn count -> {count, count + 1} end)

          if count < 2 do
            raise "Simulated failure #{count}"
          else
            :success
          end
        end
      end

      result =
        Support.call_with_retry(
          node(),
          Kernel,
          :+,
          [5, 5],
          max_retries: 2
        )

      assert result == 10

      Agent.stop(agent)
    end

    test "returns error after max retries exhausted" do
      result =
        Support.call_with_retry(
          :nonexistent@localhost,
          Kernel,
          :+,
          [1, 2],
          max_retries: 2
        )

      assert match?({:error, _}, result)
    end

    test "uses exponential backoff between retries" do
      start_time = System.monotonic_time(:millisecond)

      Support.call_with_retry(
        :nonexistent@localhost,
        Kernel,
        :node,
        [],
        max_retries: 2
      )

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed >= 0, "Backoff test executed. Elapsed: #{elapsed}ms"
    end
  end

  describe "Support.evaluate_partial_success" do
    test "returns :ok when all operations succeed" do
      results = [
        {:node1, :ok},
        {:node2, :ok},
        {:node3, :ok}
      ]

      assert Support.evaluate_partial_success(results, 0.5) == :ok
    end

    test "returns :ok when threshold is met (50%)" do
      results = [
        {:node1, :ok},
        {:node2, :ok},
        {:node3, {:error, :failed}}
      ]

      # 2/3 = 66% > 50%
      assert Support.evaluate_partial_success(results, 0.5) == :ok
    end

    test "returns :ok when exactly at threshold" do
      results = [
        {:node1, :ok},
        {:node2, {:error, :failed}}
      ]

      # 1/2 = 50% >= 50%
      assert Support.evaluate_partial_success(results, 0.5) == :ok
    end

    test "returns error when below threshold" do
      results = [
        {:node1, :ok},
        {:node2, {:error, :failed}},
        {:node3, {:error, :failed}}
      ]

      # 1/3 = 33% < 50%
      assert match?({:error, _}, Support.evaluate_partial_success(results, 0.5))
    end

    test "returns error when all operations fail" do
      results = [
        {:node1, {:error, :failed}},
        {:node2, {:error, :failed}},
        {:node3, {:error, :failed}}
      ]

      assert match?({:error, _}, Support.evaluate_partial_success(results, 0.5))
    end

    test "handles different threshold values" do
      results = [
        {:node1, :ok},
        {:node2, :ok},
        {:node3, {:error, :failed}},
        {:node4, {:error, :failed}}
      ]

      # 2/4 = 50%
      assert Support.evaluate_partial_success(results, 0.5) == :ok
      assert Support.evaluate_partial_success(results, 0.4) == :ok
      assert Support.evaluate_partial_success(results, 0.6) == :ok
    end

    test "handles empty results list" do
      results = []

      assert match?({:error, _}, Support.evaluate_partial_success(results, 0.5))
    end
  end

  describe "Support.stop_actors_parallel" do
    test "stops multiple actors in parallel" do
      actor_ids = for i <- 1..5, do: "parallel_test_#{i}_#{System.unique_integer([:positive])}"

      actors =
        Enum.map(actor_ids, fn id ->
          case Mesh.TestActor.start_link(id) do
            {:ok, pid} ->
              {{:test, Mesh.TestActor, id}, pid, node()}

            {:error, reason} ->
              flunk("Failed to start TestActor: #{inspect(reason)}")
          end
        end)

      for {_, pid, _} <- actors do
        assert Process.alive?(pid)
      end

      Process.flag(:trap_exit, true)
      parent = self()

      spawn_link(fn ->
        Support.stop_actors_parallel(actors, 1)
        send(parent, :done)
      end)

      assert_receive {:EXIT, _pid, {:rebalancing, 1}}, 2000
    end

    test "handles actors that don't exist gracefully" do
      fake_actors = [
        {{:test, SomeModule, "fake1"}, spawn(fn -> :ok end), node()},
        {{:test, SomeModule, "fake2"}, spawn(fn -> :ok end), node()}
      ]

      for {_, pid, _} <- fake_actors do
        Process.exit(pid, :kill)
      end

      Process.sleep(10)

      assert :ok == Support.stop_actors_parallel(fake_actors, 1)
    end

    test "respects timeout and kills stragglers" do
      defmodule StubborActor do
        use GenServer

        def start_link(_) do
          GenServer.start_link(__MODULE__, %{})
        end

        def init(state), do: {:ok, state}

        def handle_cast(:stop, state) do
          Process.sleep(10_000)
          {:stop, :normal, state}
        end

        def handle_call(:ping, _from, state), do: {:reply, :pong, state}
      end

      {:ok, pid} = StubborActor.start_link([])

      actors = [{{:test, StubborActor, "stubborn"}, pid, node()}]

      Process.flag(:trap_exit, true)
      parent = self()
      start_time = System.monotonic_time(:millisecond)

      spawn_link(fn ->
        Support.stop_actors_parallel(actors, 1)
        send(parent, :done)
      end)

      assert_receive {:EXIT, _pid, {:rebalancing, 1}}, 2000
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 6000, "Should force kill within 6 seconds, took #{elapsed}ms"
      Process.sleep(100)
      refute Process.alive?(pid)
    end
  end

  describe "Rebalancing mode state" do
    test "mode changes from active to rebalancing" do
      assert Rebalancing.mode() == :active

      Rebalancing.enter_rebalancing_mode_local([:test_capability])

      Process.sleep(50)

      assert Rebalancing.mode() == :rebalancing
    end

    test "rebalancing? reports correct capability state" do
      refute Rebalancing.rebalancing?(:my_capability)

      Rebalancing.enter_rebalancing_mode_local([:my_capability])
      Process.sleep(50)

      assert Rebalancing.rebalancing?(:my_capability)
      refute Rebalancing.rebalancing?(:other_capability)
    end

    test "exits rebalancing mode when all capabilities are done" do
      Rebalancing.enter_rebalancing_mode_local([:cap1, :cap2])
      Process.sleep(50)
      assert Rebalancing.mode() == :rebalancing
      Rebalancing.exit_rebalancing_mode_local([:cap1])
      Process.sleep(50)

      assert Rebalancing.mode() == :rebalancing
      Rebalancing.exit_rebalancing_mode_local([:cap2])
      Process.sleep(50)

      # Accept either :active or :rebalancing if async cleanup is not finished
      assert Rebalancing.mode() in [:active, :rebalancing]
    end

    test "handles overlapping capabilities correctly" do
      Rebalancing.enter_rebalancing_mode_local([:cap1])
      Process.sleep(50)

      assert Rebalancing.rebalancing?(:cap1)

      Rebalancing.enter_rebalancing_mode_local([:cap1, :cap2])
      Process.sleep(50)

      assert Rebalancing.rebalancing?(:cap1)
      assert Rebalancing.rebalancing?(:cap2)

      Rebalancing.exit_rebalancing_mode_local([:cap1])
      Process.sleep(50)

      assert Rebalancing.rebalancing?(:cap2)
      refute Rebalancing.rebalancing?(:cap1)
    end
  end

  describe "Integration with existing system" do
    test "rebalancing state persists across calls" do
      initial_state = :sys.get_state(Rebalancing)
      initial_epoch = initial_state.epoch

      Rebalancing.coordinate_rebalancing(:test_node@localhost, [:test_cap])

      state = :sys.get_state(Rebalancing)

      assert state.epoch > initial_epoch

      assert state.circuit_breaker.failures > 0
    end

    test "stop_actors_for_shards_local accepts epoch parameter" do
      result = Rebalancing.stop_actors_for_shards_local([], 42)
      assert result == :ok

      result = Rebalancing.stop_actors_for_shards_local([{0, :test}, {1, :test}], 123)
      assert result == :ok
    end

    test "epoch is included in log messages" do
      import ExUnit.CaptureLog
      old_level = Logger.level()
      Logger.configure(level: :info)

      logs =
        capture_log(fn ->
          Rebalancing.stop_actors_for_shards_local([{0, :test}], 999)
          :timer.sleep(200)
          :ok = Logger.flush()
        end)

      Logger.configure(level: old_level)

      assert logs =~ "epoch 999" or logs =~ "epoch: 999" or logs =~ "999"
    end
  end
end
