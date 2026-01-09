defmodule MeshExample.GameActor do
  @moduledoc """
  Example custom actor implementation for a game server.

  This actor demonstrates how to implement custom business logic
  for your actors. It maintains player state including position,
  health, and inventory.
  """
  use GenServer
  require Logger

  def start_link(actor_id) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  @impl true
  def init(actor_id) do
    Logger.info("GameActor #{actor_id} initialized")

    state = %{
      id: actor_id,
      position: {0, 0},
      health: 100,
      inventory: [],
      created_at: System.system_time(:second)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:actor_call, %{action: "spawn", name: name}}, _from, state) do
    new_state = Map.put(state, :name, name)
    response = %{status: :spawned, player: name, position: state.position}
    {:reply, response, new_state}
  end

  def handle_call({:actor_call, %{action: "move", x: x, y: y}}, _from, state) do
    new_state = %{state | position: {x, y}}
    response = %{status: :moved, position: {x, y}}
    {:reply, response, new_state}
  end

  def handle_call({:actor_call, %{action: "take_damage", amount: amount}}, _from, state) do
    new_health = max(0, state.health - amount)
    new_state = %{state | health: new_health}

    status = if new_health == 0, do: :dead, else: :alive
    response = %{status: status, health: new_health}

    {:reply, response, new_state}
  end

  def handle_call({:actor_call, %{action: "add_item", item: item}}, _from, state) do
    new_inventory = [item | state.inventory]
    new_state = %{state | inventory: new_inventory}
    response = %{status: :item_added, inventory: new_inventory}
    {:reply, response, new_state}
  end

  def handle_call({:actor_call, %{action: "get_state"}}, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:actor_call, payload}, _from, state) do
    Logger.warning("GameActor #{state.id} received unknown action: #{inspect(payload)}")
    {:reply, %{error: :unknown_action}, state}
  end
end
