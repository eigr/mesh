defmodule Mesh.Supervisor do
  @moduledoc """
  Main supervisor for the Mesh actor system.

  This supervisor manages all core components of the distributed actor system:
  - Capability registry for node routing
  - Actor registry and lifecycle management
  - Shard ownership distribution
  - Cluster membership tracking

  ## Usage

  To start Mesh in your application, add it to your supervision tree:

      children = [
        Mesh.Supervisor
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ## Cluster Setup

  Mesh does not include cluster discovery. For multi-node setups, configure
  libcluster in your application:

      children = [
        {Cluster.Supervisor, [topologies, [name: MyApp.ClusterSupervisor]]},
        Mesh.Supervisor
      ]

  Example topology configuration:

      topologies = [
        gossip: [
          strategy: Cluster.Strategy.Gossip,
          config: [
            port: 45892,
            if_addr: "0.0.0.0",
            multicast_addr: "230.1.1.251",
            multicast_ttl: 1
          ]
        ]
      ]

  ## Configuration

  Configure the number of shards (default: 4096) in your config.exs:

      config :mesh, shards: 4096
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Core tables and registries first
      Mesh.Actors.ActorTable,
      {Registry, keys: :unique, name: ActorRegistry},
      {Registry, keys: :unique, name: ActorOwnerRegistry},
      # Cluster components that depend on registries
      Mesh.Cluster.Capabilities,
      Mesh.Cluster.Membership,
      # Supervisors last
      Mesh.Actors.ActorSupervisor,
      Mesh.Actors.ActorOwnerSupervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
