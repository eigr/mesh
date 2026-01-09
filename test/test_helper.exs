ExUnit.start()

# Start Mesh supervisor for testing (no cluster needed for unit tests)
{:ok, _} = Mesh.Supervisor.start_link()

# Wait for system to initialize
Process.sleep(500)
