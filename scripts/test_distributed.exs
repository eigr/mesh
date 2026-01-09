# Test distributed setup manually
# Run this in terminal 1:
# iex --name node1@127.0.0.1 --cookie test -S mix
#
# Then in terminal 2:
# iex --name node2@127.0.0.1 --cookie test -S mix
#
# In node1, run:
# {:ok, _} = Mesh.Supervisor.start_link()
# Mesh.register_capabilities([:game])
#
# In node2, run:
# {:ok, _} = Mesh.Supervisor.start_link()
# Mesh.register_capabilities([:chat])
# Node.connect(:"node1@127.0.0.1")
#
# Check:
# Mesh.Cluster.Capabilities.all_capabilities()
# Mesh.Cluster.Capabilities.nodes_for(:game)
# Mesh.Cluster.Capabilities.nodes_for(:chat)

IO.puts("""

🧪 Manual Distributed Test Guide
================================

Terminal 1:
  $ iex --name node1@127.0.0.1 --cookie test -S mix
  
  iex> {:ok, _} = Mesh.Supervisor.start_link()
  iex> Mesh.register_capabilities([:game])
  iex> node()

Terminal 2:
  $ iex --name node2@127.0.0.1 --cookie test -S mix
  
  iex> {:ok, _} = Mesh.Supervisor.start_link()
  iex> Mesh.register_capabilities([:chat])
  iex> Node.connect(:"node1@127.0.0.1")
  iex> Node.list()
  
Verify in either terminal:
  iex> Mesh.Cluster.Capabilities.all_capabilities()
  # Should show [:game, :chat]
  
  iex> Mesh.Cluster.Capabilities.nodes_for(:game)
  # Should show [:"node1@127.0.0.1"]
  
  iex> Mesh.Cluster.Capabilities.nodes_for(:chat)
  # Should show [:"node2@127.0.0.1"]

""")
