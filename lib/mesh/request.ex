defmodule Mesh.Request do
  @moduledoc """
  Request structure for invoking processes in Mesh.

  ## Fields

    * `:module` - The GenServer module to invoke (required)
    * `:id` - The actor ID that identifies this specific process instance (required)
    * `:payload` - The payload to send to the process (required)
    * `:capability` - The capability that determines routing (required)
    * `:init_arg` - Optional argument passed to the process's `start_link/2` on creation

  ## Examples

      # Simple request
      %Mesh.Request{
        module: MyApp.Counter,
        id: "counter_1",
        payload: %{action: :increment},
        capability: :counter
      }

      # With custom initialization argument
      %Mesh.Request{
        module: MyApp.GameActor,
        id: "player_123",
        payload: %{action: :get_state},
        capability: :game,
        init_arg: %{starting_level: 5}
      }

  """
  @enforce_keys [:module, :id, :payload, :capability]
  defstruct [:module, :id, :payload, :capability, init_arg: nil]

  @type t :: %__MODULE__{
          module: module(),
          id: String.t(),
          payload: any(),
          capability: atom(),
          init_arg: any()
        }

  @doc """
  Creates a new Request struct.

  ## Examples

      iex> Mesh.Request.new(MyApp.Counter, "counter_1", %{action: :increment}, :counter)
      %Mesh.Request{module: MyApp.Counter, id: "counter_1", payload: %{action: :increment}, capability: :counter}

      iex> Mesh.Request.new(MyApp.GameActor, "player_1", %{}, :game, init_arg: %{level: 10})
      %Mesh.Request{module: MyApp.GameActor, id: "player_1", payload: %{}, capability: :game, init_arg: %{level: 10}}

  """
  def new(module, id, payload, capability, opts \\ []) do
    %__MODULE__{
      module: module,
      id: id,
      payload: payload,
      capability: capability,
      init_arg: Keyword.get(opts, :init_arg)
    }
  end
end
