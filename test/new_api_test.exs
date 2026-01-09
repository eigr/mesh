defmodule NewAPITest do
  use ExUnit.Case

  setup do
    Mesh.register_capabilities([:game, :logging])
    Process.sleep(100)
    :ok
  end

  defmodule GameActor do
    use GenServer

    # Support both start_link/1 (legacy) and start_link/2 (with init_arg)
    def start_link(actor_id), do: start_link(actor_id, nil)

    def start_link(actor_id, init_arg) do
      GenServer.start_link(__MODULE__, {actor_id, init_arg})
    end

    def init({actor_id, nil}) do
      {:ok, %{id: actor_id, level: 1, score: 0}}
    end

    def init({actor_id, init_arg}) do
      {:ok, %{id: actor_id, level: init_arg.starting_level, score: 0}}
    end

    def handle_call({:actor_call, %{action: :get_state}}, _from, state) do
      {:reply, state, state}
    end

    def handle_call({:actor_call, %{action: :increment}}, _from, state) do
      new_state = %{state | score: state.score + 1}
      {:reply, new_state.score, new_state}
    end

    def handle_cast({:actor_cast, %{action: :log}}, state) do
      IO.puts("GameActor #{state.id}: score is #{state.score}")
      {:noreply, state}
    end
  end

  test "call/1 with basic request" do
    {:ok, pid, state} =
      Mesh.call(%Mesh.Request{
        module: GameActor,
        id: "player_1",
        payload: %{action: :get_state},
        capability: :game
      })

    assert is_pid(pid)
    assert state.level == 1
    assert state.score == 0
  end

  test "call/1 with custom init_arg" do
    {:ok, pid, state} =
      Mesh.call(%Mesh.Request{
        module: GameActor,
        id: "player_2",
        payload: %{action: :get_state},
        capability: :game,
        init_arg: %{starting_level: 10}
      })

    assert is_pid(pid)
    assert state.level == 10
    assert state.score == 0
  end

  test "call/1 maintains state across invocations" do
    id = "player_3"

    req = %Mesh.Request{
      module: GameActor,
      id: id,
      payload: %{action: :increment},
      capability: :game
    }

    {:ok, pid1, score1} = Mesh.call(req)
    assert score1 == 1

    {:ok, pid2, score2} = Mesh.call(req)
    assert pid1 == pid2
    assert score2 == 2
  end

  test "cast/1 sends async message" do
    # First create the actor
    {:ok, _pid, _state} =
      Mesh.call(%Mesh.Request{
        module: GameActor,
        id: "player_4",
        payload: %{action: :get_state},
        capability: :game
      })

    # Then cast a message
    :ok =
      Mesh.cast(%Mesh.Request{
        module: GameActor,
        id: "player_4",
        payload: %{action: :log},
        capability: :game
      })

    Process.sleep(50)
  end
end
