defmodule NodeHelper do
  @moduledoc """
  Helper for creating and managing distributed Erlang nodes for tests.
  Based on Spawn project pattern.
  """

  require Logger

  @doc """
  Spawns a peer node and loads the application.
  Returns the node name.
  """
  def spawn_peer(node_name, options \\ []) do
    # Ensure we're distributed
    :net_kernel.start([:"primary@127.0.0.1"])

    # Allow spawned nodes to fetch code from this node
    :erl_boot_server.start([])
    allow_boot(~c"127.0.0.1")

    spawn_node(:"#{node_name}@127.0.0.1", options)
  end

  @doc """
  Execute RPC on remote node.
  """
  def rpc(node, module, function, args) do
    :rpc.block_call(node, module, function, args)
  end

  @doc """
  Starts multiple nodes for benchmarking.
  """
  def start_nodes(count, base_name \\ "test_node") do
    nodes =
      for i <- 1..count do
        node_name = "#{base_name}_#{i}"
        spawn_peer(node_name, applications: [:mesh])
      end

    Logger.info("Started #{count} nodes: #{inspect(nodes)}")
    nodes
  end

  @doc """
  Stops a peer node.
  """
  def stop_node(node) do
    :slave.stop(node)
  end

  @doc """
  Stops all nodes.
  """
  def stop_nodes(nodes) when is_list(nodes) do
    Enum.each(nodes, &stop_node/1)
  end

  @doc """
  Registers capabilities on a node.
  """
  def register_capabilities(node, capabilities) when is_list(capabilities) do
    rpc(node, Mesh.Cluster.Capabilities, :register_capabilities, [node, capabilities])
    Process.sleep(100)
    Logger.info("Registered #{inspect(capabilities)} on #{node}")
  end

  @doc """
  Synchronizes shards on all nodes.
  """
  def sync_all_shards(nodes) do
    all_nodes = [node() | nodes]

    for n <- all_nodes do
      rpc(n, Mesh.Actors.ActorOwnerSupervisor, :sync_shards, [])
    end

    Process.sleep(200)
  end

  @doc """
  Gets node statistics.
  """
  def node_stats(node) do
    %{
      node: node,
      alive: Node.ping(node) == :pong,
      processes: rpc(node, :erlang, :system_info, [:process_count]),
      memory_mb: rpc(node, :erlang, :memory, [:total]) / (1024 * 1024),
      actors: rpc(node, :ets, :info, [Mesh.Actors.ActorTable, :size])
    }
  end

  ## Private Functions

  defp spawn_node(node_host, options) do
    {:ok, node} = :slave.start(~c"127.0.0.1", node_name(node_host), inet_loader_args())

    # Add code paths from current node
    rpc(node, :code, :add_paths, [:code.get_path()])

    # Start essential applications first
    rpc(node, Application, :ensure_all_started, [:mix])
    rpc(node, Application, :ensure_all_started, [:logger])
    rpc(node, Logger, :configure, [[level: Logger.level()]])
    rpc(node, Mix, :env, [Mix.env()])

    # Load application environment from main node
    loaded_apps =
      for {app_name, _, _} <- Application.loaded_applications() do
        base = Application.get_all_env(app_name)

        environment =
          options
          |> Keyword.get(:environment, [])
          |> Keyword.get(app_name, [])
          |> Keyword.merge(base, fn _, v, _ -> v end)

        for {key, val} <- environment do
          rpc(node, Application, :put_env, [app_name, key, val])
        end

        app_name
      end

    # Start applications in order
    ordered_apps = Keyword.get(options, :applications, loaded_apps)

    for app_name <- ordered_apps, app_name in loaded_apps do
      result = rpc(node, Application, :ensure_all_started, [app_name])
      Logger.debug("Started #{app_name} on #{node}: #{inspect(result)}")
    end

    # Start Mesh.Supervisor explicitly on the remote node
    # (Mesh is a library, not an application, so it doesn't have mod: in mix.exs)
    if :mesh in ordered_apps do
      Logger.debug("Starting Mesh.Supervisor on #{node}")
      {:ok, _pid} = rpc(node, Mesh.Supervisor, :start_link, [])
      Logger.debug("Mesh.Supervisor started successfully on #{node}")
    end

    # Wait a bit for supervisors to fully initialize
    Process.sleep(1000)

    # Load additional files if specified
    for file <- Keyword.get(options, :files, []) do
      rpc(node, Code, :require_file, [file])
    end

    node
  end

  defp inet_loader_args do
    ~c"-loader inet -hosts 127.0.0.1 -setcookie #{:erlang.get_cookie()}"
  end

  defp allow_boot(host) do
    {:ok, ipv4} = :inet.parse_ipv4_address(host)
    :erl_boot_server.add_slave(ipv4)
  end

  defp node_name(node_host) do
    node_host
    |> to_string()
    |> String.split("@")
    |> Enum.at(0)
    |> String.to_atom()
  end
end
