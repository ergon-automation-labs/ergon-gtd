defmodule BotArmyGtd.ReviewEngineTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyGtd.ReviewEngine

  describe "weekly_review/1" do
    test "returns summary with completed, stale, and orphaned projects" do
      now = DateTime.utc_now()
      recent = DateTime.to_iso8601(DateTime.add(now, -2 * 86400, :second))
      stale = DateTime.to_iso8601(DateTime.add(now, -10 * 86400, :second))

      tasks = [
        %{
          "id" => "t1",
          "title" => "Done task",
          "status" => "completed",
          "project_id" => "p1",
          "updated_at" => recent
        },
        %{
          "id" => "t2",
          "title" => "Active fresh",
          "status" => "active",
          "project_id" => "p1",
          "updated_at" => recent
        },
        %{
          "id" => "t3",
          "title" => "Active stale",
          "status" => "active",
          "project_id" => "p2",
          "updated_at" => stale
        }
      ]

      projects = [
        %{"id" => "p1", "name" => "Active With Tasks", "status" => "active"},
        %{"id" => "p2", "name" => "Active Stale Tasks", "status" => "active"},
        %{"id" => "p3", "name" => "No Tasks Project", "status" => "active"}
      ]

      Mox.expect(BotArmyGtd.TaskStoreMock, :list, fn _tid, %{} -> {:ok, tasks} end)
      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tid -> {:ok, projects} end)
      Mox.expect(BotArmyGtd.InboxItemStoreMock, :list_pending, fn _tid -> {:ok, []} end)

      {:ok, result} = ReviewEngine.weekly_review("default")

      assert result.summary.completed_this_week == 1
      assert result.summary.stale_active_tasks == 1
      assert result.summary.projects_without_next_action == 1
      assert result.summary.active_projects == 3
      assert length(result.completed) == 1
      assert hd(result.completed)["title"] == "Done task"
      assert length(result.stale_active) == 1
      assert hd(result.stale_active)["title"] == "Active stale"

      orphaned_names = Enum.map(result.projects_without_next_action, & &1["name"])
      assert "No Tasks Project" in orphaned_names
    end

    test "handles empty data gracefully" do
      Mox.expect(BotArmyGtd.TaskStoreMock, :list, fn _tid, %{} -> {:ok, []} end)
      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tid -> {:ok, []} end)
      Mox.expect(BotArmyGtd.InboxItemStoreMock, :list_pending, fn _tid -> {:ok, []} end)

      {:ok, result} = ReviewEngine.weekly_review("default")

      assert result.summary.total_tasks == 0
      assert result.summary.total_projects == 0
      assert result.completed == []
      assert result.stale_active == []
    end

    test "includes stale inbox items in review" do
      old_ts = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -72 * 3600, :second))

      inbox_items = [
        %{"id" => "i1", "title" => "Old item", "created_at" => old_ts, "source" => "discord"}
      ]

      Mox.expect(BotArmyGtd.TaskStoreMock, :list, fn _tid, %{} -> {:ok, []} end)
      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tid -> {:ok, []} end)
      Mox.expect(BotArmyGtd.InboxItemStoreMock, :list_pending, fn _tid -> {:ok, inbox_items} end)

      {:ok, result} = ReviewEngine.weekly_review("default")

      assert result.summary.stale_inbox_items == 1
      assert length(result.stale_inbox) == 1
    end
  end

  describe "inbox_aging/2" do
    test "finds stale inbox items with severity levels" do
      now = DateTime.utc_now()

      items = [
        %{
          "id" => "i1",
          "title" => "Fresh",
          "created_at" => DateTime.to_iso8601(DateTime.add(now, -1 * 3600, :second)),
          "source" => "nats"
        },
        %{
          "id" => "i2",
          "title" => "Stale 3 days",
          "created_at" => DateTime.to_iso8601(DateTime.add(now, -73 * 3600, :second)),
          "source" => "discord"
        },
        %{
          "id" => "i3",
          "title" => "Critical 8 days",
          "created_at" => DateTime.to_iso8601(DateTime.add(now, -192 * 3600, :second)),
          "source" => "email"
        }
      ]

      Mox.expect(BotArmyGtd.InboxItemStoreMock, :list_pending, fn _tid -> {:ok, items} end)

      {:ok, result} = ReviewEngine.inbox_aging("default")

      assert result.total_pending == 3
      assert result.stale_count == 2

      severities = Enum.map(result.items, & &1["severity"])
      assert "critical" in severities
      assert "warning" in severities
    end

    test "respects custom threshold" do
      now = DateTime.utc_now()

      items = [
        %{
          "id" => "i1",
          "title" => "25h old",
          "created_at" => DateTime.to_iso8601(DateTime.add(now, -25 * 3600, :second)),
          "source" => "nats"
        }
      ]

      Mox.expect(BotArmyGtd.InboxItemStoreMock, :list_pending, fn _tid -> {:ok, items} end)

      {:ok, result} = ReviewEngine.inbox_aging("default", threshold_hours: 24)
      assert result.stale_count == 1

      Mox.expect(BotArmyGtd.InboxItemStoreMock, :list_pending, fn _tid -> {:ok, items} end)

      {:ok, result2} = ReviewEngine.inbox_aging("default", threshold_hours: 48)
      assert result2.stale_count == 0
    end
  end

  describe "project_coherence/1" do
    test "finds orphaned projects and dangling tasks" do
      projects = [
        %{"id" => "p1", "name" => "Active OK", "status" => "active"},
        %{"id" => "p2", "name" => "Active No Tasks", "status" => "active"},
        %{"id" => "p3", "name" => "Completed", "status" => "completed"}
      ]

      tasks = [
        %{
          "id" => "t1",
          "title" => "Active in p1",
          "status" => "active",
          "project_id" => "p1",
          "updated_at" => "2026-05-01"
        },
        %{
          "id" => "t2",
          "title" => "Points to completed",
          "status" => "active",
          "project_id" => "p3",
          "updated_at" => "2026-05-01"
        },
        %{
          "id" => "t3",
          "title" => "Points to deleted",
          "status" => "active",
          "project_id" => "p-gone",
          "updated_at" => "2026-05-01"
        }
      ]

      Mox.expect(BotArmyGtd.TaskStoreMock, :list, fn _tid, %{} -> {:ok, tasks} end)
      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tid -> {:ok, projects} end)

      {:ok, result} = ReviewEngine.project_coherence("default")

      # p2 is active with no active tasks
      assert result.orphaned_count == 1
      assert hd(result.orphaned_projects)["name"] == "Active No Tasks"

      # t2 points to completed project, t3 points to missing project
      assert result.dangling_count == 2
      reasons = Enum.map(result.dangling_tasks, & &1["reason"])
      assert "project_completed" in reasons
      assert "project_not_found" in reasons

      # p2 has no tasks at all
      assert result.empty_count == 1
      assert hd(result.empty_projects)["name"] == "Active No Tasks"
    end

    test "clean state returns no issues" do
      projects = [
        %{"id" => "p1", "name" => "Good Project", "status" => "active"}
      ]

      tasks = [
        %{
          "id" => "t1",
          "title" => "Active task",
          "status" => "active",
          "project_id" => "p1",
          "updated_at" => "2026-05-08"
        }
      ]

      Mox.expect(BotArmyGtd.TaskStoreMock, :list, fn _tid, %{} -> {:ok, tasks} end)
      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tid -> {:ok, projects} end)

      {:ok, result} = ReviewEngine.project_coherence("default")

      assert result.orphaned_count == 0
      assert result.dangling_count == 0
      assert result.empty_count == 0
    end
  end
end
