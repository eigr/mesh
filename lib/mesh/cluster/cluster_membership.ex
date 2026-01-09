defmodule Mesh.Cluster.Membership do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Schedule monitoring after a delay to allow other components to initialize
    # Increased to 3s to handle distributed initialization where nodes connect during setup
    Process.send_after(self(), :start_monitoring, 3000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:start_monitoring, state) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node, info}, state) do
    Logger.debug("Node up: #{node}. Info: #{inspect(info)}")
    Mesh.Actors.ActorOwnerSupervisor.sync_shards()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node, info}, state) do
    Logger.debug("Node down: #{node}. Info: #{inspect(info)}")
    Mesh.Actors.ActorOwnerSupervisor.sync_shards()
    {:noreply, state}
  end
end
