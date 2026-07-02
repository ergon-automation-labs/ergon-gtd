# Mini node configuration (standby with leader election)
# This file is used when deploying GTD to the mini node.
# The mini node monitors heartbeats from the primary (air) node.
# If air becomes unavailable, mini automatically becomes leader.

import Config

# Set mini as standby node (will monitor air for leader election)
config :bot_army_gtd, :node_role, :standby

# Keep other config from main config.exs
