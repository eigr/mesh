defmodule MeshExample.Application do
  @moduledoc """
  Example application demonstrating how to use Mesh in your own application.

  This application:
  1. Starts the Mesh supervisor with cluster configuration
  2. Registers capabilities for this node
  3. Provides a simple API for actor invocation
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      {Cluster.Supervisor, [topologies, [name: MeshExample.ClusterSupervisor]]},
      Mesh.Supervisor,
      MeshExample.CapabilityRegistrar
    ]

    opts = [strategy: :one_for_one, name: MeshExample.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
