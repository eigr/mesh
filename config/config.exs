import Config

# Configure Mesh library
config :mesh,
  shards: 4096

# Note: This is the library config.
# For running a complete application with cluster configuration,
# see the example application in example/

import_config "#{config_env()}.exs"
