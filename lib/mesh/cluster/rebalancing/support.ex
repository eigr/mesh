defmodule Mesh.Cluster.Rebalancing.Support do
  @moduledoc """
  Support functions for resilient rebalancing operations.

  This module provides fault-tolerant versions of RPC calls and actor
  shutdowns that embrace eventual consistency and graceful degradation.
  """

  require Logger

  @coordination_timeout 10_000

  @doc """
  Calls an RPC with retry logic and exponential backoff.

  Accepts partial failures and uses adaptive timeouts to handle
  network delays and temporary unavailability.
  """
  def call_with_retry(node, module, function, args, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 2)
    do_call_with_retry(node, module, function, args, max_retries, 1)
  end

  defp do_call_with_retry(node, module, function, args, retries_left, attempt) do
    timeout = @coordination_timeout * attempt

    case :rpc.call(node, module, function, args, timeout) do
      {:badrpc, :timeout} when retries_left > 0 ->
        Logger.debug("RPC timeout to #{node}, retrying (#{retries_left} left)")
        backoff = :rand.uniform(1000) + attempt * 500
        Process.sleep(backoff)
        do_call_with_retry(node, module, function, args, retries_left - 1, attempt + 1)

      {:badrpc, :nodedown} ->
        {:error, {:node_down, node}}

      {:badrpc, reason} when retries_left > 0 ->
        Logger.debug("RPC error to #{node}: #{inspect(reason)}, retrying")
        Process.sleep(1000)
        do_call_with_retry(node, module, function, args, retries_left - 1, attempt + 1)

      {:badrpc, reason} ->
        {:error, {:rpc_failed, reason}}

      result ->
        result
    end
  end

  @doc """
  Gracefully stops an actor with timeout and monitoring.

  Gives the actor time to clean up before forcing termination.
  Tags the shutdown reason with the rebalancing epoch for debugging.
  """
  def stop_actor_gracefully(actor_key, pid, epoch) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, {:rebalancing, epoch})

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          Mesh.Actors.ActorTable.delete(actor_key)
          :ok
      after
        3_000 ->
          Process.exit(pid, :kill)
          Mesh.Actors.ActorTable.delete(actor_key)
          {:error, :timeout}
      end
    else
      Mesh.Actors.ActorTable.delete(actor_key)
      :ok
    end
  end

  @doc """
  Stops actors in parallel with timeout.

  Uses Task-based parallelism to stop multiple actors efficiently,
  with a global timeout to prevent indefinite blocking.
  """
  def stop_actors_parallel(actors_to_stop, epoch) do
    tasks =
      Enum.map(actors_to_stop, fn {actor_key, pid, _node} ->
        Task.async(fn -> stop_actor_gracefully(actor_key, pid, epoch) end)
      end)

    results = Task.yield_many(tasks, 5_000)

    Enum.each(results, fn {task, result} ->
      case result do
        nil -> Task.shutdown(task, :brutal_kill)
        _ -> :ok
      end
    end)

    :ok
  end

  @doc """
  Evaluates success rate and determines if operation succeeded.

  Accepts partial success for eventual consistency:
  - >= 80% success: Operation considered successful
  - >= 50% success: Degraded but acceptable
  - < 50% success: Critical failure

  The system relies on self-healing to converge to correct state.
  """
  def evaluate_partial_success(results, operation_name) do
    {successful, failed} =
      Enum.split_with(results, fn {_node, result} -> result == :ok end)

    success_rate = length(successful) / max(length(results), 1)

    cond do
      success_rate >= 0.8 ->
        if length(failed) > 0 do
          Logger.warning(
            "Partial #{operation_name} success (#{length(successful)}/#{length(results)}): " <>
              "#{inspect(failed)} will self-heal"
          )
        end

        :ok

      success_rate >= 0.5 ->
        Logger.warning(
          "Degraded #{operation_name}: #{length(failed)}/#{length(results)} failed, will self-heal"
        )

        :ok

      true ->
        Logger.error(
          "Critical: #{operation_name} mostly failed (#{length(successful)}/#{length(results)})"
        )

        {:error, {:critical_failure, failed}}
    end
  end
end
