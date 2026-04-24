defmodule BotArmyGtd.Handlers.ProjectHandlerTest do
  use ExUnit.Case
  @moduletag :handlers
  import Mox

  setup :verify_on_exit!

  describe "handle_create/1" do
    test "successfully creates a project" do
      expected_project = %{
        "id" => "project-1",
        "name" => "Learn Elixir",
        "description" => "Master the fundamentals",
        "status" => "active",
        "created_at" => "2024-01-01T00:00:00"
      }

      expect(BotArmyGtd.ProjectStoreMock, :create, fn payload when is_map(payload) ->
        {:ok, expected_project}
      end)

      message = valid_create_message()
      BotArmyGtd.Handlers.ProjectHandler.handle_create(message)
    end

    test "returns error for missing required field" do
      message =
        valid_create_message()
        |> put_in(["payload", "name"], nil)

      BotArmyGtd.Handlers.ProjectHandler.handle_create(message)
    end

    test "supports labels on project creation" do
      expected_project = %{
        "id" => "project-1",
        "name" => "Learning Projects",
        "labels" => ["elixir", "learning"],
        "status" => "active"
      }

      expect(BotArmyGtd.ProjectStoreMock, :create, fn payload when is_map(payload) ->
        assert payload["labels"] == ["elixir", "learning"]
        {:ok, expected_project}
      end)

      message =
        valid_create_message()
        |> put_in(["payload", "labels"], ["elixir", "learning"])

      BotArmyGtd.Handlers.ProjectHandler.handle_create(message)
    end
  end

  describe "handle_update/1" do
    test "successfully updates a project" do
      project_id = "project-1"

      payload = %{
        "project_id" => project_id,
        "name" => "Updated Project Name",
        "status" => "archived"
      }

      expected_project = %{
        "id" => project_id,
        "name" => "Updated Project Name",
        "status" => "archived"
      }

      expect(BotArmyGtd.ProjectStoreMock, :update, fn ^project_id, ^payload ->
        {:ok, expected_project}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.project.update",
        "payload" => payload,
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      BotArmyGtd.Handlers.ProjectHandler.handle_update(update_msg)
    end

    test "returns error when updating non-existent project" do
      project_id = "non-existent-id"

      payload = %{
        "project_id" => project_id,
        "name" => "Updated Name"
      }

      expect(BotArmyGtd.ProjectStoreMock, :update, fn ^project_id, ^payload ->
        {:error, :not_found}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.project.update",
        "payload" => payload,
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      BotArmyGtd.Handlers.ProjectHandler.handle_update(update_msg)
    end

    test "supports updating labels on project" do
      project_id = "project-1"

      payload = %{
        "project_id" => project_id,
        "labels" => ["updated", "labels"]
      }

      expected_project = %{
        "id" => project_id,
        "labels" => ["updated", "labels"]
      }

      expect(BotArmyGtd.ProjectStoreMock, :update, fn ^project_id, ^payload ->
        {:ok, expected_project}
      end)

      update_msg = %{
        "event_id" => UUID.uuid4(),
        "event" => "gtd.project.update",
        "payload" => payload,
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }

      BotArmyGtd.Handlers.ProjectHandler.handle_update(update_msg)
    end
  end

  defp valid_create_message do
    %{
      "event_id" => UUID.uuid4(),
      "event" => "gtd.project.create",
      "tenant_id" => "00000000-0000-0000-0000-000000000001",
      "user_id" => "00000000-0000-0000-0000-000000000002",
      "payload" => %{
        "name" => "New Project",
        "description" => "Test project",
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => "00000000-0000-0000-0000-000000000002"
      }
    }
  end
end
