defmodule Mesh.Cluster.Capabilities do
  use GenServer
  require Logger

  @name __MODULE__

  # API
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def all_capabilities do
    GenServer.call(@name, :all_capabilities)
  end

  def register_capabilities(node \\ node(), capabilities) when is_list(capabilities) do
    GenServer.cast(@name, {:register, node, MapSet.new(capabilities)})
    propagate_capabilities(node, capabilities)
  end

  def nodes_for(actor_type), do: GenServer.call(@name, {:nodes_for, actor_type})

  # Callbacks
  @impl true
  def init(_) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, %{node_capabilities: %{node() => MapSet.new()}}}
  end

  @impl true
  def handle_cast({:register, node, capabilities}, state) do
    Logger.debug(
      "Registering capabilities #{inspect(MapSet.to_list(capabilities))} for node #{node}"
    )

    new_state = put_in(state.node_capabilities[node], capabilities)

    # Synchronize shards asynchronously without linking
    spawn(fn -> Mesh.Actors.ActorOwnerSupervisor.sync_shards() end)

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:nodes_for, actor_type}, _from, state) do
    nodes =
      state.node_capabilities
      |> Enum.filter(fn {_node, caps} -> MapSet.member?(caps, actor_type) end)
      |> Enum.map(fn {node, _} -> node end)

    {:reply, nodes, state}
  end

  @impl true
  def handle_call(:all_capabilities, _from, state) do
    caps =
      state.node_capabilities
      |> Map.values()
      |> Enum.flat_map(& &1)
      |> MapSet.new()
      |> MapSet.to_list()

    {:reply, caps, state}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node up: #{node}, initializing capabilities")

    new_state =
      Map.put(state, :node_capabilities, Map.put(state.node_capabilities, node, MapSet.new()))

    # Send existing capabilities to the newly joined node
    # Use spawn to avoid blocking and prevent linking issues
    for {existing_node, caps} <- state.node_capabilities, existing_node != node do
      spawn(fn ->
        # Silence errors during initialization (module may not be loaded yet)
        try do
          :rpc.cast(node, __MODULE__, :_update_capabilities_from_remote, [
            existing_node,
            MapSet.to_list(caps)
          ])
        catch
          _, _ -> :ok
        end
      end)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    Logger.info("Node down: #{node}, removing capabilities")
    new_state = Map.update!(state, :node_capabilities, &Map.delete(&1, node))
    {:noreply, new_state}
  end

  defp propagate_capabilities(origin_node, capabilities) do
    for n <- Node.list() do
      # Use cast to avoid blocking if the module is not loaded yet
      :rpc.cast(n, __MODULE__, :_update_capabilities_from_remote, [origin_node, capabilities])
    end
  end

  # Called remotely via RPC
  # May fail if the module is not loaded yet (during initialization)
  def _update_capabilities_from_remote(node, capabilities) do
    try do
      GenServer.cast(@name, {:register, node, MapSet.new(capabilities)})
    rescue
      # Ignore if the process does not exist yet
      _ -> :ok
    end
  end
end
