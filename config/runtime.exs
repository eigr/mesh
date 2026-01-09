import Config

config :libcluster,
  topologies: [
    mvp_cluster: [
      strategy: Application.get_env(:mesh, :cluster_strategy, Cluster.Strategy.Epmd),
      config: Application.get_env(:mesh, :cluster_config, [])
    ]
  ]
