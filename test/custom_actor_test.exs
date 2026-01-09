defmodule CustomActorTest do
  use ExUnit.Case

  defmodule TestActor do
    @moduledoc "Test actor for validation"
    use GenServer

    def start_link(actor_id) do
      GenServer.start_link(__MODULE__, actor_id)
    end

    @impl true
    def init(actor_id) do
      {:ok, %{id: actor_id, counter: 0}}
    end

    @impl true
    def handle_call({:actor_call, %{action: "increment"}}, _from, state) do
      new_state = %{state | counter: state.counter + 1}
      {:reply, %{counter: new_state.counter}, new_state}
    end

    def handle_call({:actor_call, %{action: "get_counter"}}, _from, state) do
      {:reply, %{counter: state.counter}, state}
    end
  end

  setup do
    Mesh.register_capabilities([:custom])
    Process.sleep(100)
    :ok
  end

  describe "custom actor module" do
    test "can be passed explicitly to call" do
      actor_id = "test_actor_#{:rand.uniform(1_000_000)}"

      assert {:ok, pid, response} =
               Mesh.call(%Mesh.Request{
                 module: TestActor,
                 id: actor_id,
                 payload: %{action: "increment"},
                 capability: :custom
               })

      assert is_pid(pid)
      assert %{counter: 1} = response
    end

    test "maintains state across invocations" do
      actor_id = "test_actor_#{:rand.uniform(1_000_000)}"

      {:ok, pid1, response1} =
        Mesh.call(%Mesh.Request{
          module: TestActor,
          id: actor_id,
          payload: %{action: "increment"},
          capability: :custom
        })

      assert %{counter: 1} = response1

      {:ok, pid2, response2} =
        Mesh.call(%Mesh.Request{
          module: TestActor,
          id: actor_id,
          payload: %{action: "increment"},
          capability: :custom
        })

      assert %{counter: 2} = response2

      assert pid1 == pid2

      {:ok, ^pid1, response3} =
        Mesh.call(%Mesh.Request{
          module: TestActor,
          id: actor_id,
          payload: %{action: "get_counter"},
          capability: :custom
        })

      assert %{counter: 2} = response3
    end

    test "different actors have independent state" do
      actor1 = "actor_#{:rand.uniform(1_000_000)}"
      actor2 = "actor_#{:rand.uniform(1_000_000)}"

      {:ok, _pid1, _} =
        Mesh.call(%Mesh.Request{
          module: TestActor,
          id: actor1,
          payload: %{action: "increment"},
          capability: :custom
        })

      {:ok, pid1, _} =
        Mesh.call(%Mesh.Request{
          module: TestActor,
          id: actor1,
          payload: %{action: "increment"},
          capability: :custom
        })

      {:ok, pid2, _} =
        Mesh.call(%Mesh.Request{
          module: TestActor,
          id: actor2,
          payload: %{action: "increment"},
          capability: :custom
        })

      assert pid1 != pid2

      {:ok, ^pid1, response1} =
        Mesh.call(%Mesh.Request{
          module: TestActor,
          id: actor1,
          payload: %{action: "get_counter"},
          capability: :custom
        })

      assert %{counter: 2} = response1

      {:ok, ^pid2, response2} =
        Mesh.call(%Mesh.Request{
          module: TestActor,
          id: actor2,
          payload: %{action: "get_counter"},
          capability: :custom
        })

      assert %{counter: 1} = response2
    end
  end
end
