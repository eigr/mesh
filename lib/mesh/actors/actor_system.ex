defmodule Mesh.Actors.ActorSystem do
  @moduledoc """
  Core actor invocation system.
  """

  @doc """
  Makes a synchronous call to a virtual process.

  Returns `{:ok, pid, response}` on success, or `{:error, reason}` on failure.
  """
  @spec call(Mesh.Request.t()) :: {:ok, pid(), term()} | {:error, term()}
  def call(%Mesh.Request{} = request) do
    # Check if capability is rebalancing
    if Mesh.Cluster.Rebalancing.rebalancing?(request.capability) do
      {:error, {:rebalancing, request.capability}}
    else
      shard = Mesh.Shards.ShardRouter.shard_for(request.id)

      case Mesh.Shards.ShardRouter.owner_node(shard, request.capability) do
        {:ok, owner} ->
          case :rpc.call(
                 owner,
                 Mesh.Actors.ActorOwner,
                 :call,
                 [
                   request.id,
                   request.payload,
                   request.module,
                   request.capability,
                   request.init_arg
                 ],
                 5000
               ) do
            {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
            result -> result
          end

        {:error, :no_nodes} ->
          {:error, {:no_nodes_for_capability, request.capability}}
      end
    end
  end

  @doc """
  Makes an asynchronous cast to a virtual process.

  Returns `:ok` on success, or `{:error, reason}` on failure.
  """
  @spec cast(Mesh.Request.t()) :: :ok | {:error, term()}
  def cast(%Mesh.Request{} = request) do
    # Check if capability is rebalancing
    if Mesh.Cluster.Rebalancing.rebalancing?(request.capability) do
      {:error, {:rebalancing, request.capability}}
    else
      shard = Mesh.Shards.ShardRouter.shard_for(request.id)

      case Mesh.Shards.ShardRouter.owner_node(shard, request.capability) do
        {:ok, owner} ->
          case :rpc.call(
                 owner,
                 Mesh.Actors.ActorOwner,
                 :cast,
                 [
                   request.id,
                   request.payload,
                   request.module,
                   request.capability,
                   request.init_arg
                 ],
                 5000
               ) do
            {:badrpc, reason} -> {:error, {:rpc_failed, reason}}
            :ok -> :ok
          end

        {:error, :no_nodes} ->
          {:error, {:no_nodes_for_capability, request.capability}}
      end
    end
  end
end
