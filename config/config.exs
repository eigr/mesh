import Config

config :mesh,
  shards: 4096

# Disable Logger output
config :logger,
  level: :warning,
  backends: []

import_config "#{config_env()}.exs"
