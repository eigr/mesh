defmodule NodeHelper do
  @moduledoc """
  Helper for creating and managing Erlang nodes for distributed tests.
  Based on the Spawn project pattern.
  """

  require Logger

  @doc """
  Starts multiple slave nodes and connects them in a cluster.
  """
  def start_nodes(count, base_name \\ "test_node") do
    # Ensure the main node is named
    ensure_distributed()

    # Start the nodes
    nodes =
      1..count
      |> Enum.map(fn i ->
        node_name = :"#{base_name}_#{i}@127.0.0.1"
        {:ok, node} = start_node(node_name)
        node
      end)

    # Load the application on each node
    Enum.each(nodes, fn node ->
      load_application_on_node(node)
    end)

    # Wait for all nodes to be fully connected and see each other
    wait_for_cluster_sync(nodes)

    Logger.info("Started #{count} nodes: #{inspect(nodes)}")

    nodes
  end
  
  @doc """
  Waits for all nodes to be fully connected and synchronized.
  This ensures all nodes see each other before proceeding.
  """
  def wait_for_cluster_sync(nodes) do
    all_nodes = [node() | nodes]
    expected_count = length(all_nodes) - 1  # Each node should see N-1 other nodes
    
    Logger.info("Waiting for cluster synchronization (#{length(all_nodes)} total nodes)...")
    
    # Check on each node that it sees all other nodes
    Enum.each(all_nodes, fn check_node ->
      wait_for_node_to_see_cluster(check_node, expected_count)
    end)
    
    Logger.info("✅ Cluster fully synchronized - all nodes connected")
  end
  
  defp wait_for_node_to_see_cluster(check_node, expected_count) do
    max_attempts = 50
    
    Enum.reduce_while(1..max_attempts, nil, fn attempt, _ ->
      visible_nodes = 
        if check_node == node() do
          length(Node.list())
        else
          case :rpc.call(check_node, Node, :list, []) do
            nodes when is_list(nodes) -> length(nodes)
            _ -> 0
          end
        end
      
      if visible_nodes >= expected_count do
        Logger.debug("Node #{check_node} sees #{visible_nodes}/#{expected_count} nodes")
        {:halt, :ok}
      else
        if rem(attempt, 10) == 0 do
          Logger.debug("Node #{check_node} waiting... (#{visible_nodes}/#{expected_count} nodes visible)")
        end
        Process.sleep(100)
        {:cont, nil}
      end
    end)
  end

  @doc """
  Stops all specified nodes.
  """
  def stop_nodes(nodes) when is_list(nodes) do
    Enum.each(nodes, fn node ->
      stop_node(node)
    end)

    Logger.info("Stopped #{length(nodes)} nodes")
  end

  @doc """
  Starts a single slave node.

  Note: Uses :slave which is deprecated in OTP 29.
  TODO: Migrate to :peer module when available.
  """
  def start_node(node_name) when is_atom(node_name) do
    [name, host] = node_name |> Atom.to_string() |> String.split("@")

    # Define args to pass the correct cookie
    cookie = Node.get_cookie()
    args = ~c"-setcookie #{cookie}"

    case :slave.start(String.to_charlist(host), String.to_charlist(name), args) do
      {:ok, node} ->
        Logger.debug("Node started: #{node}")
        # Ensure the cookie is correct
        :rpc.call(node, Node, :set_cookie, [cookie])
        {:ok, node}

      {:error, {:already_running, node}} ->
        Logger.debug("Node was already running: #{node}")
        {:ok, node}

      {:error, reason} ->
        Logger.error("Failed to start node #{node_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stops a slave node.
  """
  def stop_node(node) when is_atom(node) do
    case :slave.stop(node) do
      :ok ->
        Logger.debug("Node stopped: #{node}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to stop node #{node}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Connects all nodes to each other forming a complete cluster.
  """
  def connect_nodes(nodes) when is_list(nodes) do
    local_node = node()
    all_nodes = [local_node | nodes]

    for node <- all_nodes,
        other_node <- all_nodes,
        node != other_node do
      Node.connect(other_node)
      :rpc.call(node, Node, :connect, [other_node])
    end

    # Wait for propagation
    Process.sleep(100)

    Logger.info("Cluster connected: #{inspect(Node.list())}")
  end

  @doc """
  Helper function to start the Mesh supervisor.
  This is called remotely via RPC to avoid return value issues.
  """
  def start_mesh_supervisor do
    case Mesh.Supervisor.start_link([]) do
      {:ok, pid} -> {:mesh_started, pid}
      {:error, {:already_started, pid}} -> {:mesh_already_started, pid}
      other -> {:mesh_error, other}
    end
  end

  @doc """
  Loads and starts the mesh application on a remote node.
  
  This mimics what happens when you run `iex --name node@127.0.0.1 -S mix`:
  1. Add all code paths
  2. Load all application dependencies  
  3. Load the mvp_actor_system application (which loads all its modules)
  4. Start the Mesh.Supervisor
  5. Wait for cluster synchronization
  """
  def load_application_on_node(node) do
    # Add code paths from the current node
    for path <- :code.get_path() do
      :rpc.call(node, :code, :add_path, [path])
    end

    # Configure libcluster with empty topology to avoid automatic connection attempts
    :rpc.call(node, Application, :put_env, [:libcluster, :topologies, []])

    # Load all dependencies first
    :rpc.call(node, Application, :ensure_all_started, [:logger])
    :rpc.call(node, Application, :ensure_all_started, [:telemetry])
    :rpc.call(node, Application, :ensure_all_started, [:libcluster])
    
    # Load the application (but don't start it yet) - this loads all modules
    :rpc.call(node, Application, :load, [:mesh])
    
    # Extra delay to ensure all modules are fully loaded BEFORE Mesh.Supervisor starts
    # This prevents :undef errors when nodeup events trigger RPC calls
    Process.sleep(2000)

    # Start Mesh.Supervisor directly via RPC (avoid need to load NodeHelper on remote)
    result = :rpc.call(node, Mesh.Supervisor, :start_link, [[]])

    case result do
      {:ok, _pid} ->
        Logger.info("✅ Started Mesh.Supervisor on node #{node}")

      {:error, {:already_started, _pid}} ->
        Logger.info("✅ Mesh.Supervisor already running on node #{node}")

      {:badrpc, reason} ->
        Logger.warning(
          "RPC failed to start Mesh.Supervisor on node #{node}: #{inspect(reason)}, will retry"
        )

        Process.sleep(500)
        result2 = :rpc.call(node, Mesh.Supervisor, :start_link, [[]])

        case result2 do
          {:ok, _} ->
            Logger.info("✅ Retry succeeded for Mesh.Supervisor on node #{node}")

          {:error, {:already_started, _}} ->
            Logger.info("✅ Mesh.Supervisor running on node #{node}")

          error ->
            raise "Failed to start Mesh.Supervisor after retry: #{inspect(error)}"
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to start Mesh.Supervisor on node #{node}: #{inspect(reason)}, will retry"
        )

        Process.sleep(500)
        result2 = :rpc.call(node, Mesh.Supervisor, :start_link, [[]])

        case result2 do
          {:ok, _} ->
            Logger.info("✅ Retry succeeded for Mesh.Supervisor on node #{node}")

          {:error, {:already_started, _}} ->
            Logger.info("✅ Mesh.Supervisor running on node #{node}")

          error ->
            raise "Failed to start Mesh.Supervisor after retry: #{inspect(error)}"
        end
    end

    # Wait longer for supervisor children to start
    Process.sleep(1000)

    # Verify Registry exists (retry up to 10 times)
    registry_started =
      Enum.reduce_while(1..10, false, fn attempt, _acc ->
        case :rpc.call(node, Process, :whereis, [ActorOwnerRegistry]) do
          nil ->
            if attempt < 10 do
              Logger.debug("Waiting for ActorOwnerRegistry on #{node} (attempt #{attempt}/10)...")
              Process.sleep(300)
              {:cont, false}
            else
              {:halt, false}
            end

          _pid ->
            {:halt, true}
        end
      end)

    if registry_started do
      Logger.info("✅ ActorOwnerRegistry verified on node #{node}")
    else
      Logger.error("❌ ActorOwnerRegistry not found on node #{node} after 10 attempts")
      raise "ActorOwnerRegistry not started"
    end

    Logger.info("✅ Application fully loaded on node #{node}")
  end

  @doc """
  Registers capabilities on a specific node.
  """
  def register_capabilities(node, capabilities) when is_list(capabilities) do
    :rpc.call(node, Mesh.Cluster.Capabilities, :register_capabilities, [node, capabilities])

    # Wait for propagation
    Process.sleep(100)

    Logger.info("Capabilities #{inspect(capabilities)} registered on node #{node}")
  end

  @doc """
  Synchronizes shards on all nodes.
  """
  def sync_all_shards(nodes) do
    all_nodes = [node() | nodes]

    Enum.each(all_nodes, fn node ->
      :rpc.call(node, Mesh.Actors.ActorOwnerSupervisor, :sync_shards, [])
    end)

    # Wait for synchronization
    Process.sleep(200)
  end

  # Ensures that the current node is distributed (has a name).
  defp ensure_distributed do
    case Node.alive?() do
      true ->
        :ok

      false ->
        # Try to start with default name
        base_name = "test_master_#{:erlang.unique_integer([:positive])}"
        {:ok, _} = Node.start(:"#{base_name}@127.0.0.1", :shortnames)
        Node.set_cookie(:mvp_test)
        :ok
    end
  end

  @doc """
  Returns statistics of a node.
  """
  def node_stats(node) do
    %{
      node: node,
      alive: Node.ping(node) == :pong,
      processes: :rpc.call(node, :erlang, :system_info, [:process_count]),
      memory_mb: :rpc.call(node, :erlang, :memory, [:total]) / (1024 * 1024),
      actors: :rpc.call(node, :ets, :info, [Mesh.Actors.ActorTable, :size])
    }
  end

  @doc """
  Waits until all nodes are connected.
  """
  def wait_for_cluster(expected_nodes, timeout \\ 5000) do
    wait_until(
      fn ->
        current_nodes = [node() | Node.list()] |> Enum.sort()
        expected = Enum.sort(expected_nodes)
        current_nodes == expected
      end,
      timeout,
      100
    )
  end

  defp wait_until(fun, timeout, interval) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_until(fun, deadline, interval)
  end

  defp do_wait_until(fun, deadline, interval) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        {:error, :timeout}
      else
        Process.sleep(interval)
        do_wait_until(fun, deadline, interval)
      end
    end
  end
end
