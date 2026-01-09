defmodule Mesh.Actors.VirtualTestActor do
  @moduledoc """
  Simple test actor for benchmarks and testing.

  This is a minimal actor that echoes back the payload it receives.
  Used internally for Mesh's own tests and benchmarks.

  For production use, implement your own actor modules:

  ## Example Custom Actor

      defmodule MyApp.GameActor do
        use GenServer

        def start_link(actor_id) do
          GenServer.start_link(__MODULE__, actor_id)
        end

        @impl true
        def init(actor_id) do
          {:ok, %{id: actor_id, state: :ready}}
        end

        @impl true
        def handle_call({:actor_call, payload}, _from, state) do
          # Your custom logic here
          {:reply, {:ok, :processed}, state}
        end
      end
  """
  use GenServer
  require Logger

  def start_link(actor_name, _initial_state \\ nil) do
    GenServer.start_link(__MODULE__, actor_name)
  end

  @impl true
  def init(actor_name) do
    {:ok, actor_name}
  end

  @impl true
  def handle_call({:actor_call, payload}, _from, state) do
    Logger.info("Actor #{state} received payload: #{inspect(payload)}")
    {:reply, payload, state}
  end
end
