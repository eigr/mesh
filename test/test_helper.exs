if System.find_executable("epmd") do
  # Ensure epmd is running for tests that spawn distributed nodes.
  System.cmd("epmd", ["-daemon"])
end

Application.put_env(
  :mesh,
  :test_preload_files,
  [Path.expand("support/rebalancing_test_actor.ex", __DIR__)]
)

ExUnit.start(exclude: [:stress, :destructive])

{:ok, _} = Mesh.Supervisor.start_link()

Mesh.Cluster.Capabilities.register_capabilities([:custom, :game, :logging, :test])
Mesh.Actors.ActorOwnerSupervisor.sync_shards()

Process.sleep(500)
