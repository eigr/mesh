import Config

# Configure libcluster for local development
# This uses Gossip strategy for automatic node discovery
config :libcluster,
  topologies: [
    gossip: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_addr: "230.1.1.251",
        multicast_ttl: 1,
        broadcast_only: true
      ]
    ]
  ]

# Configure Mesh
config :mesh,
  shards: 4096

# Import environment specific config
import_config "#{config_env()}.exs"
