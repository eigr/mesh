defmodule Mesh.Cluster.Capabilities do
  use GenServer
  require Logger

  @name __MODULE__
  @propagation_wait_ms 2000
  @propagation_check_ms 50
  @propagation_rpc_timeout_ms 1000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def all_capabilities do
    GenServer.call(@name, :all_capabilities)
  end

  def register_capabilities(node \\ node(), capabilities) when is_list(capabilities) do
    :ok = GenServer.call(@name, {:register, node, MapSet.new(capabilities)})
    Mesh.Actors.ActorOwnerSupervisor.sync_shards()
    propagate_capabilities(node, capabilities)
  end

  def nodes_for(actor_type), do: GenServer.call(@name, {:nodes_for, actor_type})

  @impl true
  def init(_) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, %{node_capabilities: %{node() => MapSet.new()}}}
  end

  @impl true
  def handle_cast({:register, node, capabilities}, state) do
    new_state = register_in_state(state, node, capabilities)
    spawn(fn -> Mesh.Actors.ActorOwnerSupervisor.sync_shards() end)
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:register, node, capabilities}, _from, state) do
    new_state = register_in_state(state, node, capabilities)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:nodes_for, actor_type}, _from, state) do
    nodes =
      state.node_capabilities
      |> Enum.filter(fn {_node, caps} -> MapSet.member?(caps, actor_type) end)
      |> Enum.map(fn {node, _} -> node end)
      |> Enum.sort()

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
      |> Enum.sort()

    {:reply, caps, state}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node up: #{node}, initializing capabilities")

    new_state =
      Map.put(state, :node_capabilities, Map.put(state.node_capabilities, node, MapSet.new()))

    for {existing_node, caps} <- state.node_capabilities, existing_node != node do
      spawn(fn ->
        propagate_to_node(node, existing_node, MapSet.to_list(caps))
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
      spawn(fn ->
        propagate_to_node(n, origin_node, capabilities)
      end)
    end
  end

  defp propagate_to_node(remote_node, origin_node, capabilities) do
    if await_remote_capabilities(remote_node) do
      :rpc.cast(remote_node, __MODULE__, :update_capabilities_from_remote, [
        origin_node,
        capabilities
      ])
    else
      Logger.debug("Skipping capability propagation to #{remote_node}: remote not ready")
    end
  end

  defp await_remote_capabilities(remote_node) do
    deadline = System.monotonic_time(:millisecond) + @propagation_wait_ms
    await_remote_capabilities(remote_node, deadline)
  end

  defp await_remote_capabilities(remote_node, deadline) do
    case :rpc.call(remote_node, Process, :whereis, [@name], @propagation_rpc_timeout_ms) do
      pid when is_pid(pid) ->
        true

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          false
        else
          Process.sleep(@propagation_check_ms)
          await_remote_capabilities(remote_node, deadline)
        end
    end
  end

  def update_capabilities_from_remote(node, capabilities) do
    try do
      GenServer.cast(@name, {:register, node, MapSet.new(capabilities)})
    rescue
      # Ignore if the process does not exist yet
      _ -> :ok
    end
  end

  defp register_in_state(state, node, capabilities) do
    Logger.debug(
      "Registering capabilities #{inspect(MapSet.to_list(capabilities))} for node #{node}"
    )

    put_in(state.node_capabilities[node], capabilities)
  end
end
