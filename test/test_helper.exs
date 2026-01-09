ExUnit.start(exclude: [:stress, :destructive])

{:ok, _} = Mesh.Supervisor.start_link()

Mesh.Cluster.Capabilities.register_capabilities([:test, :custom, :game, :logging])
Mesh.Actors.ActorOwnerSupervisor.sync_shards()

Process.sleep(500)
