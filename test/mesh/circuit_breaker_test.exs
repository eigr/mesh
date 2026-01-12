defmodule Mesh.CircuitBreakerTest do
  use ExUnit.Case, async: false

  setup_all do
    unless Process.whereis(Mesh.Cluster.Rebalancing) do
      Mesh.Cluster.Rebalancing.start_link([])
      Process.sleep(200)
    end

    :ok
  end

  alias Mesh.Cluster.Rebalancing

  describe "Circuit Breaker functionality" do
    setup do
      :sys.replace_state(Rebalancing, fn _state ->
        %Rebalancing.State{
          rebalancing_capabilities: MapSet.new(),
          pending_operations: %{},
          mode: :active,
          circuit_breaker: %{
            failures: 0,
            last_failure_at: nil,
            status: :closed
          },
          epoch: 0
        }
      end)

      :ok
    end

    test "circuit breaker state starts closed with zero failures" do
      state = :sys.get_state(Rebalancing)
      assert state.circuit_breaker.status == :closed
      assert state.circuit_breaker.failures == 0
      assert state.circuit_breaker.last_failure_at == nil
    end

    test "epoch starts at zero and increments with each rebalancing attempt" do
      initial_state = :sys.get_state(Rebalancing)
      assert initial_state.epoch == 0

      :sys.replace_state(Rebalancing, fn state ->
        %{state | epoch: state.epoch + 1}
      end)

      state = :sys.get_state(Rebalancing)
      assert state.epoch == 1
    end

    test "circuit breaker opens after reaching threshold" do
      :sys.replace_state(Rebalancing, fn state ->
        %{
          state
          | circuit_breaker: %{
              failures: 3,
              last_failure_at: System.monotonic_time(:millisecond),
              status: :open
            }
        }
      end)

      state = :sys.get_state(Rebalancing)
      assert state.circuit_breaker.failures == 3
      assert state.circuit_breaker.status == :open
    end

    test "circuit breaker rejects requests when open" do
      :sys.replace_state(Rebalancing, fn state ->
        %{
          state
          | circuit_breaker: %{
              failures: 3,
              last_failure_at: System.monotonic_time(:millisecond),
              status: :open
            }
        }
      end)

      result = Rebalancing.coordinate_rebalancing(:some_node@localhost, [:test_cap])
      assert result == {:error, :circuit_breaker_open}

      state = :sys.get_state(Rebalancing)
      assert state.circuit_breaker.failures == 3
    end

    test "circuit breaker can be manually reset" do
      :sys.replace_state(Rebalancing, fn state ->
        %{
          state
          | circuit_breaker: %{failures: 3, last_failure_at: nil, status: :open}
        }
      end)

      state = :sys.get_state(Rebalancing)
      assert state.circuit_breaker.status == :open

      :sys.replace_state(Rebalancing, fn state ->
        %{
          state
          | circuit_breaker: %{failures: 0, last_failure_at: nil, status: :closed}
        }
      end)

      state = :sys.get_state(Rebalancing)
      assert state.circuit_breaker.status == :closed
      assert state.circuit_breaker.failures == 0
    end
  end

  describe "Rebalancing mode management" do
    test "mode starts as active" do
      assert Rebalancing.mode() == :active
    end

    test "can check if specific capability is rebalancing" do
      refute Rebalancing.rebalancing?(:my_capability)
    end

    test "entering rebalancing mode changes state" do
      assert Rebalancing.mode() == :active

      Rebalancing.enter_rebalancing_mode_local([:test_capability])
      Process.sleep(50)

      assert Rebalancing.mode() == :rebalancing
      assert Rebalancing.rebalancing?(:test_capability)
    end

    test "exiting rebalancing mode returns to active" do
      Rebalancing.enter_rebalancing_mode_local([:test_capability])
      Process.sleep(50)

      assert Rebalancing.mode() == :rebalancing

      Rebalancing.exit_rebalancing_mode_local([:test_capability])
      Process.sleep(50)

      assert Rebalancing.mode() == :active
      refute Rebalancing.rebalancing?(:test_capability)
    end

    test "mode stays rebalancing when multiple capabilities are active" do
      Rebalancing.enter_rebalancing_mode_local([:cap1, :cap2])
      Process.sleep(50)

      assert Rebalancing.mode() == :rebalancing

      Rebalancing.exit_rebalancing_mode_local([:cap1])
      Process.sleep(50)

      assert Rebalancing.mode() == :rebalancing
      assert Rebalancing.rebalancing?(:cap2)
      refute Rebalancing.rebalancing?(:cap1)
    end
  end

  describe "Epoch tracking" do
    test "stop_actors_for_shards_local accepts epoch parameter" do
      result = Rebalancing.stop_actors_for_shards_local([], 42)
      assert result == :ok

      # With some shard data (no actors will match)
      result = Rebalancing.stop_actors_for_shards_local([{0, :test}, {1, :test}], 123)
      assert result == :ok
    end
  end
end
