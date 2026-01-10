import Config

config :mesh,
  shards: 4096

# Set default log level (can be overridden per environment)
config :logger,
  level: :warning

import_config "#{config_env()}.exs"
