defmodule Mesh.Actors.ActorSupervisor do
  @moduledoc """
  DynamicSupervisor for user-defined actors.

  Multiple instances run under PartitionSupervisor (one per scheduler)
  to reduce contention during concurrent actor creation.
  """
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts an actor under the partitioned supervisor.
  Routes to appropriate partition based on actor_id hash.
  """
  def start_child(actor_module, actor_id, init_arg) do
    spec = %{
      id: {actor_module, actor_id},
      start: {actor_module, :start_link, [actor_id, init_arg]},
      restart: :temporary
    }

    partition = :erlang.phash2(actor_id, System.schedulers_online())

    DynamicSupervisor.start_child(
      {:via, PartitionSupervisor, {__MODULE__, partition}},
      spec
    )
  end
end
