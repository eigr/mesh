defmodule Mesh.Cluster.Rebalancing do
  @moduledoc """
  Coordinates rebalancing when capabilities are registered or removed.

  When a node registers capabilities, this module ensures a coordinated
  rebalancing process across all nodes with the same capabilities:

  1. Enter rebalancing mode (pause new actor creation)
  2. Gracefully stop actors for affected capabilities
  3. Synchronize shards across all participating nodes
  4. Exit rebalancing mode (resume normal operation)

  This prevents race conditions and ensures consistent actor placement
  during topology changes.
  """

  use GenServer
  require Logger

  @name __MODULE__
  @rebalancing_timeout 30_000
  @coordination_timeout 10_000
  @circuit_breaker_threshold 3
  @circuit_breaker_reset_timeout 60_000

  defmodule State do
    @moduledoc false
    defstruct rebalancing_capabilities: MapSet.new(),
              pending_operations: %{},
              mode: :active,
              circuit_breaker: %{
                failures: 0,
                last_failure_at: nil,
                status: :closed
              },
              epoch: 0
  end

  defmodule RebalancingPlan do
    @moduledoc false
    defstruct [
      :epoch,
      :node,
      :capabilities,
      :old_ownership,
      :new_ownership,
      :ownership_changes,
      :affected_nodes,
      started_at: nil,
      status: :pending
    ]
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  @doc """
  Initiates coordinated rebalancing for the given capabilities.

  This function will:
  1. Calculate current shard ownership (before registration)
  2. Register capabilities (changes topology)
  3. Calculate new shard ownership (after registration)
  4. Put affected nodes into rebalancing mode
  5. Stop only actors on shards that changed ownership
  6. Sync shards
  7. Resume normal operation

  Returns `:ok` or `{:error, reason}`
  """
  def coordinate_rebalancing(node, capabilities) when is_list(capabilities) do
    GenServer.call(
      @name,
      {:coordinate_rebalancing, node, capabilities},
      @rebalancing_timeout
    )
  end

  @doc """
  Checks if a capability is currently rebalancing.
  """
  def rebalancing?(capability) do
    GenServer.call(@name, {:rebalancing?, capability})
  end

  def reset_state do
    GenServer.call(@name, :reset_state)
  end

  @doc """
  Returns current rebalancing mode: `:active` or `:rebalancing`
  """
  def mode do
    GenServer.call(@name, :mode)
  end

  @impl true
  def init(_) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:coordinate_rebalancing, node, capabilities}, _from, state) do
    Logger.info(
      "Starting coordinated rebalancing for node #{node} with capabilities: #{inspect(capabilities)}"
    )

    case check_circuit_breaker(state.circuit_breaker) do
      {:ok, :closed} ->
        execute_with_circuit_breaker(node, capabilities, state)

      {:ok, :half_open} ->
        Logger.info("Circuit breaker is HALF-OPEN, attempting recovery")
        execute_with_circuit_breaker(node, capabilities, state)

      {:error, :open} ->
        Logger.warning("Circuit breaker is OPEN, rejecting rebalancing request")
        {:reply, {:error, :circuit_breaker_open}, state}
    end
  end

  @impl true
  def handle_call({:rebalancing?, capability}, _from, state) do
    is_rebalancing = MapSet.member?(state.rebalancing_capabilities, capability)
    {:reply, is_rebalancing, state}
  end

  def handle_call(:reset_state, _from, _state) do
    {:reply, :ok, %Mesh.Cluster.Rebalancing.State{}}
  end

  def handle_call(:mode, _from, state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_cast({:enter_rebalancing_mode, capabilities}, state) do
    Logger.debug("Node #{node()} entering rebalancing mode for: #{inspect(capabilities)}")

    new_capabilities = MapSet.union(state.rebalancing_capabilities, MapSet.new(capabilities))
    new_state = %{state | rebalancing_capabilities: new_capabilities, mode: :rebalancing}

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:exit_rebalancing_mode, capabilities}, state) do
    Logger.debug("Node #{node()} exiting rebalancing mode for: #{inspect(capabilities)}")

    new_capabilities = MapSet.difference(state.rebalancing_capabilities, MapSet.new(capabilities))

    new_mode =
      if MapSet.size(new_capabilities) == 0 do
        :active
      else
        :rebalancing
      end

    new_state = %{state | rebalancing_capabilities: new_capabilities, mode: new_mode}

    {:noreply, new_state}
  end

  defp check_circuit_breaker(breaker) do
    case breaker.status do
      :closed ->
        {:ok, :closed}

      :open ->
        if breaker.last_failure_at != nil do
          time_since_failure = System.monotonic_time(:millisecond) - breaker.last_failure_at

          if time_since_failure >= @circuit_breaker_reset_timeout do
            {:ok, :half_open}
          else
            {:error, :open}
          end
        else
          {:error, :open}
        end
    end
  end

  defp execute_with_circuit_breaker(node, capabilities, state) do
    new_epoch = state.epoch + 1

    case do_coordinate_rebalancing(node, capabilities, new_epoch, state) do
      {:ok, new_state} ->
        Logger.info(
          "Completed coordinated rebalancing (epoch #{new_epoch}) for node #{node} with capabilities: #{inspect(capabilities)}"
        )

        updated_state = %{
          new_state
          | circuit_breaker: %{failures: 0, last_failure_at: nil, status: :closed},
            epoch: new_epoch
        }

        {:reply, :ok, updated_state}

      {:error, reason} = error ->
        Logger.error(
          "Failed coordinated rebalancing (epoch #{new_epoch}) for #{node}/#{inspect(capabilities)}: #{inspect(reason)}"
        )

        updated_breaker = record_failure(state.circuit_breaker)

        updated_state = %{state | circuit_breaker: updated_breaker, epoch: new_epoch}

        {:reply, error, updated_state}
    end
  end

  defp record_failure(breaker) do
    new_failures = breaker.failures + 1
    now = System.monotonic_time(:millisecond)

    if new_failures >= @circuit_breaker_threshold do
      Logger.warning(
        "Circuit breaker OPENED after #{new_failures} failures (threshold: #{@circuit_breaker_threshold})"
      )

      %{failures: new_failures, last_failure_at: now, status: :open}
    else
      Logger.debug(
        "Circuit breaker recorded failure #{new_failures}/#{@circuit_breaker_threshold}"
      )

      %{failures: new_failures, last_failure_at: now, status: :closed}
    end
  end

  defp do_coordinate_rebalancing(node, capabilities, epoch, state) do
    Logger.debug("Capturing current shard ownership before registration (epoch #{epoch})")
    old_ownership = capture_shard_ownership(capabilities)

    Logger.debug("Registering capabilities in state (epoch #{epoch})")
    :ok = register_capabilities_internal(node, capabilities)

    Logger.debug("Calculating new shard ownership after registration (epoch #{epoch})")
    new_ownership = capture_shard_ownership(capabilities)

    Logger.debug("Calculating shard ownership changes (epoch #{epoch})")
    ownership_changes = calculate_ownership_changes(old_ownership, new_ownership)

    Logger.info(
      "Ownership changes (epoch #{epoch}): #{map_size(ownership_changes)} shards will be rebalanced"
    )

    with :ok <- enter_rebalancing_mode(capabilities),
         :ok <- stop_actors_for_shard_changes(ownership_changes, epoch),
         :ok <- sync_shards_cluster_wide(capabilities),
         :ok <- exit_rebalancing_mode(capabilities) do
      {:ok, state}
    end
  end

  defp register_capabilities_internal(node, capabilities) do
    GenServer.call(
      Mesh.Cluster.Capabilities,
      {:register, node, MapSet.new(capabilities)}
    )
  end

  defp capture_shard_ownership(capabilities) do
    shard_count = Mesh.Shards.ShardConfig.shard_count()

    # For each shard and capability, determine the current owner
    for shard <- 0..(shard_count - 1),
        capability <- capabilities,
        into: %{} do
      owner =
        case Mesh.Shards.ShardRouter.owner_node(shard, capability) do
          {:ok, node} -> node
          {:error, _} -> nil
        end

      {{shard, capability}, owner}
    end
  end

  defp calculate_ownership_changes(old_ownership, new_ownership) do
    old_ownership
    |> Enum.filter(fn {{_shard, _capability} = key, old_owner} ->
      new_owner = Map.get(new_ownership, key)
      old_owner != nil and new_owner != nil and old_owner != new_owner
    end)
    |> Map.new()
  end

  defp stop_actors_for_shard_changes(ownership_changes, epoch) do
    if map_size(ownership_changes) == 0 do
      Logger.info("No shard ownership changes detected, skipping actor shutdown")
      :ok
    else
      # Group changes by node (the old owner who needs to stop actors)
      changes_by_node =
        ownership_changes
        |> Enum.group_by(fn {{_shard, _capability}, old_owner} -> old_owner end)

      Logger.info(
        "Stopping actors on #{map_size(changes_by_node)} nodes due to ownership changes (epoch #{epoch})"
      )

      results =
        Enum.map(changes_by_node, fn {node, changes} ->
          shards_and_caps =
            Enum.map(changes, fn {{shard, capability}, _old_owner} ->
              {shard, capability}
            end)

          result =
            Mesh.Cluster.Rebalancing.Support.call_with_retry(
              node,
              __MODULE__,
              :stop_actors_for_shards_local,
              [shards_and_caps, epoch],
              max_retries: 2
            )

          {node, result}
        end)

      case Mesh.Cluster.Rebalancing.Support.evaluate_partial_success(results, 0.5) do
        :ok ->
          :ok

        {:error, _reason} ->
          failed = Enum.filter(results, fn {_node, result} -> result != :ok end)
          {:error, {:stop_actors_failed, failed}}
      end
    end
  end

  defp enter_rebalancing_mode(capabilities) do
    affected_nodes = get_affected_nodes(capabilities)
    Logger.info("Entering rebalancing mode on nodes: #{inspect(affected_nodes)}")

    results =
      Enum.map(affected_nodes, fn node ->
        {node,
         :rpc.call(
           node,
           __MODULE__,
           :enter_rebalancing_mode_local,
           [capabilities],
           @coordination_timeout
         )}
      end)

    if Enum.all?(results, fn {_node, result} -> result == :ok end) do
      :ok
    else
      failed = Enum.filter(results, fn {_node, result} -> result != :ok end)
      {:error, {:rebalancing_mode_failed, failed}}
    end
  end

  defp exit_rebalancing_mode(capabilities) do
    affected_nodes = get_affected_nodes(capabilities)
    Logger.info("Exiting rebalancing mode on nodes: #{inspect(affected_nodes)}")

    results =
      Enum.map(affected_nodes, fn node ->
        {node,
         :rpc.call(
           node,
           __MODULE__,
           :exit_rebalancing_mode_local,
           [capabilities],
           @coordination_timeout
         )}
      end)

    if Enum.all?(results, fn {_node, result} -> result == :ok end) do
      :ok
    else
      failed = Enum.filter(results, fn {_node, result} -> result != :ok end)
      Logger.warning("Some nodes failed to exit rebalancing mode: #{inspect(failed)}")
      :ok
    end
  end

  defp sync_shards_cluster_wide(capabilities) do
    affected_nodes = get_affected_nodes(capabilities)
    Logger.info("Syncing shards on nodes: #{inspect(affected_nodes)}")

    results =
      Enum.map(affected_nodes, fn node ->
        {node,
         :rpc.call(
           node,
           Mesh.Actors.ActorOwnerSupervisor,
           :sync_shards,
           [],
           @coordination_timeout
         )}
      end)

    if Enum.all?(results, fn {_node, result} -> result == :ok end) do
      :ok
    else
      failed = Enum.filter(results, fn {_node, result} -> result != :ok end)
      {:error, {:sync_shards_failed, failed}}
    end
  end

  defp get_affected_nodes(capabilities) do
    capabilities
    |> Enum.flat_map(&Mesh.Cluster.Capabilities.nodes_for/1)
    |> Enum.uniq()
    |> Enum.filter(fn node ->
      node == node() or Node.ping(node) == :pong
    end)
    |> Enum.sort()
  end

  @doc false
  def enter_rebalancing_mode_local(capabilities) do
    GenServer.cast(@name, {:enter_rebalancing_mode, capabilities})
    :ok
  end

  @doc false
  def exit_rebalancing_mode_local(capabilities) do
    GenServer.cast(@name, {:exit_rebalancing_mode, capabilities})
    :ok
  end

  @doc false
  def stop_actors_for_shards_local(shards_and_capabilities, epoch \\ 0) do
    Logger.info("stop_actors_for_shards_local called with epoch #{epoch}")

    Logger.debug(
      "Stopping actors for #{length(shards_and_capabilities)} shard/capability pairs (epoch #{epoch})"
    )

    affected_set = MapSet.new(shards_and_capabilities)

    # Get all actors and filter by those in affected shards
    actors_to_stop =
      Mesh.Actors.ActorTable.entries()
      |> Enum.filter(fn {{capability, _module, actor_id}, _pid, actor_node} ->
        if actor_node == node() do
          shard = Mesh.Shards.ShardRouter.shard_for(actor_id)
          MapSet.member?(affected_set, {shard, capability})
        else
          false
        end
      end)

    Logger.info(
      "Found #{length(actors_to_stop)} actors to stop for shard ownership changes (epoch #{epoch})"
    )

    Mesh.Cluster.Rebalancing.Support.stop_actors_parallel(actors_to_stop, epoch)

    Logger.debug("Completed stopping actors for shard ownership changes (epoch #{epoch})")
    :ok
  end
end
