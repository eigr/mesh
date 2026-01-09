defmodule Mesh.RequestTest do
  use ExUnit.Case

  alias Mesh.Request

  describe "struct creation" do
    test "creates request with all fields" do
      request = %Request{
        module: MyApp.Actor,
        id: "test_123",
        payload: %{data: "value"},
        capability: :game
      }

      assert request.module == MyApp.Actor
      assert request.id == "test_123"
      assert request.payload == %{data: "value"}
      assert request.capability == :game
      assert request.init_arg == nil
    end

    test "creates request with init_arg" do
      request = %Request{
        module: MyApp.Actor,
        id: "test_123",
        payload: %{},
        capability: :game,
        init_arg: %{config: "value"}
      }

      assert request.init_arg == %{config: "value"}
    end

    test "handles nil payload" do
      request = %Request{
        module: MyApp.Actor,
        id: "test",
        payload: nil,
        capability: :game
      }

      assert request.payload == nil
    end

    test "handles empty map payload" do
      request = %Request{
        module: MyApp.Actor,
        id: "test",
        payload: %{},
        capability: :game
      }

      assert request.payload == %{}
    end

    test "handles complex nested payload" do
      payload = %{
        level1: %{
          level2: %{
            level3: [1, 2, 3]
          }
        }
      }

      request = %Request{
        module: MyApp.Actor,
        id: "test",
        payload: payload,
        capability: :game
      }

      assert request.payload == payload
    end

    test "handles atom id" do
      request = %Request{
        module: MyApp.Actor,
        id: :atom_id,
        payload: %{},
        capability: :game
      }

      assert request.id == :atom_id
    end

    test "handles integer id" do
      request = %Request{
        module: MyApp.Actor,
        id: 12345,
        payload: %{},
        capability: :game
      }

      assert request.id == 12345
    end
  end

  describe "pattern matching" do
    test "can pattern match on capability" do
      request = %Request{
        module: MyApp.Actor,
        id: "test",
        payload: %{},
        capability: :game
      }

      result =
        case request do
          %Request{capability: :game} -> :matched_game
          %Request{capability: :chat} -> :matched_chat
          _ -> :no_match
        end

      assert result == :matched_game
    end

    test "can pattern match on module" do
      request = %Request{
        module: MyApp.GameActor,
        id: "test",
        payload: %{},
        capability: :game
      }

      result =
        case request do
          %Request{module: MyApp.GameActor} -> :game_actor
          _ -> :other
        end

      assert result == :game_actor
    end

    test "can destructure in function head" do
      process_request = fn %Request{id: id, capability: cap} ->
        {id, cap}
      end

      request = %Request{
        module: MyApp.Actor,
        id: "test_123",
        payload: %{},
        capability: :game
      }

      assert process_request.(request) == {"test_123", :game}
    end
  end

  describe "updates" do
    test "can update payload" do
      request = %Request{
        module: MyApp.Actor,
        id: "test",
        payload: %{old: "data"},
        capability: :game
      }

      updated = %{request | payload: %{new: "data"}}

      assert updated.payload == %{new: "data"}
      assert updated.id == "test"
    end

    test "can update init_arg" do
      request = %Request{
        module: MyApp.Actor,
        id: "test",
        payload: %{},
        capability: :game
      }

      updated = %{request | init_arg: %{config: "value"}}

      assert updated.init_arg == %{config: "value"}
    end

    test "preserves other fields when updating" do
      request = %Request{
        module: MyApp.Actor,
        id: "test",
        payload: %{data: "value"},
        capability: :game,
        init_arg: %{config: "old"}
      }

      updated = %{request | payload: %{data: "new"}}

      assert updated.module == MyApp.Actor
      assert updated.id == "test"
      assert updated.capability == :game
      assert updated.init_arg == %{config: "old"}
      assert updated.payload == %{data: "new"}
    end
  end
end
