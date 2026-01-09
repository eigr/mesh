defmodule MeshExample.CapabilityRegistrar do
  @moduledoc """
  Registers capabilities for this node after cluster startup.

  This GenServer waits for the cluster to stabilize and then
  registers the capabilities this node should handle.
  """

  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # Register capabilities after a short delay to allow cluster to form
    Process.send_after(self(), :register_capabilities, 1000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:register_capabilities, state) do
    # Register capabilities for this node
    # In a real application, these would be based on the node's role
    Mesh.register_capabilities([:game, :chat])

    {:noreply, state}
  end
end
