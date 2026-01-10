defmodule NodeHelper do
  @moduledoc """
  Helper for creating and managing distributed Erlang nodes for tests.
  Uses the :peer module (OTP 25+) for spawning distributed nodes.
  """

  require Logger

  # Store peer PIDs for cleanup
  @peer_table :node_helper_peers
  @peer_owner :node_helper_peers_owner

  @doc """
  Spawns a peer node and loads the application.
  Returns the node name.
  """
  def spawn_peer(node_name, options \\ []) do
    ensure_peer_table()
    ensure_distributed()

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
    case :ets.lookup(@peer_table, node) do
      [{^node, peer_pid}] ->
        :peer.stop(peer_pid)
        :ets.delete(@peer_table, node)

      [] ->
        :ok
    end
  end

  @doc """
  Stops all nodes.
  """
  def stop_nodes(nodes) when is_list(nodes) do
    Enum.each(nodes, &stop_node/1)
  end

  defp ensure_peer_table do
    case :ets.whereis(@peer_table) do
      :undefined ->
        owner = ensure_peer_owner()
        :ets.new(@peer_table, [:named_table, :public, :set, {:heir, owner, :peer_table}])

      _ ->
        :ok
    end
  end

  defp ensure_peer_owner do
    case Process.whereis(@peer_owner) do
      nil ->
        pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        try do
          Process.register(pid, @peer_owner)
          pid
        rescue
          ArgumentError ->
            Process.exit(pid, :kill)
            Process.whereis(@peer_owner)
        end

      pid ->
        pid
    end
  end

  defp ensure_distributed do
    case node() do
      :nonode@nohost ->
        {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])

      _ ->
        :ok
    end
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
    # Use :peer module (OTP 25+) instead of deprecated :slave
    peer_opts = %{
      name: node_name(node_host),
      host: ~c"127.0.0.1",
      longnames: true,
      args: [
        ~c"-setcookie",
        ~c"#{:erlang.get_cookie()}"
      ]
    }

    {:ok, peer_pid, node} = :peer.start(peer_opts)

    # Store peer PID for later cleanup
    :ets.insert(@peer_table, {node, peer_pid})

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

    preload_modules =
      Application.get_env(:mesh, :test_preload_modules, [])

    for module <- preload_modules do
      case :code.get_object_code(module) do
        {^module, binary, filename} ->
          rpc(node, :code, :load_binary, [module, filename, binary])

        _ ->
          :ok
      end
    end

    preload_files =
      Application.get_env(:mesh, :test_preload_files, [])

    for file <- preload_files do
      rpc(node, Code, :require_file, [file])
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

  defp node_name(node_host) do
    node_host
    |> to_string()
    |> String.split("@")
    |> Enum.at(0)
    |> String.to_atom()
  end
end
