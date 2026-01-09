defmodule MeshExample.ChatActor do
  @moduledoc """
  Example custom actor implementation for a chat room.

  This actor demonstrates managing chat room state including
  participants, message history, and room settings.
  """
  use GenServer
  require Logger

  def start_link(actor_id) do
    GenServer.start_link(__MODULE__, actor_id)
  end

  @impl true
  def init(room_id) do
    Logger.info("ChatActor #{room_id} initialized")

    state = %{
      room_id: room_id,
      participants: [],
      messages: [],
      created_at: System.system_time(:second)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:actor_call, %{action: "join", user: user}}, _from, state) do
    if user in state.participants do
      {:reply, %{status: :already_joined}, state}
    else
      new_participants = [user | state.participants]
      new_state = %{state | participants: new_participants}

      response = %{
        status: :joined,
        room: state.room_id,
        participants: new_participants
      }

      {:reply, response, new_state}
    end
  end

  def handle_call({:actor_call, %{action: "leave", user: user}}, _from, state) do
    new_participants = List.delete(state.participants, user)
    new_state = %{state | participants: new_participants}

    response = %{
      status: :left,
      room: state.room_id,
      participants: new_participants
    }

    {:reply, response, new_state}
  end

  def handle_call(
        {:actor_call, %{action: "send_message", user: user, message: msg}},
        _from,
        state
      ) do
    if user not in state.participants do
      {:reply, %{error: :not_participant}, state}
    else
      new_message = %{
        user: user,
        message: msg,
        timestamp: System.system_time(:second)
      }

      new_messages = [new_message | state.messages] |> Enum.take(100)
      new_state = %{state | messages: new_messages}

      response = %{status: :sent, message: new_message}
      {:reply, response, new_state}
    end
  end

  def handle_call({:actor_call, %{action: "get_messages", limit: limit}}, _from, state) do
    messages = Enum.take(state.messages, limit || 20)
    {:reply, %{messages: messages}, state}
  end

  def handle_call({:actor_call, payload}, _from, state) do
    Logger.warning("ChatActor #{state.room_id} received unknown action: #{inspect(payload)}")
    {:reply, %{error: :unknown_action}, state}
  end
end
