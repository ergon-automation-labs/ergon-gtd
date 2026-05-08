defmodule BotArmyGtd.ParaExporterTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyGtd.ParaExporter

  describe "extract_para_project/1" do
    test "extracts project slug from PARA refs block" do
      task = %{
        "id" => "abc-123",
        "title" => "Do the thing",
        "description" => """
        Some description here.

        ## PARA refs
        - docs/personal_os/projects/fractional_contractor_readiness/NEXT_ACTION.md
        - docs/personal_os/projects/fractional_contractor_readiness/WEEKLY_LOG.md
        """
      }

      assert {:ok, "fractional_contractor_readiness"} = ParaExporter.extract_para_project(task)
    end

    test "returns :no_link when no PARA refs block" do
      task = %{
        "id" => "abc-123",
        "title" => "Regular task",
        "description" => "Just a normal task description."
      }

      assert :no_link = ParaExporter.extract_para_project(task)
    end

    test "returns :no_link when description is nil" do
      task = %{"id" => "abc-123", "title" => "No desc", "description" => nil}
      assert :no_link = ParaExporter.extract_para_project(task)
    end

    test "returns :no_link when description is empty" do
      task = %{"id" => "abc-123", "title" => "Empty", "description" => ""}
      assert :no_link = ParaExporter.extract_para_project(task)
    end

    test "extracts slug with spaces in project name" do
      task = %{
        "id" => "abc-123",
        "title" => "Bot army task",
        "description" => """
        ## PARA refs
        - docs/personal_os/projects/Bot Army/NEXT_ACTION.md
        """
      }

      assert {:ok, "Bot Army"} = ParaExporter.extract_para_project(task)
    end
  end

  describe "slugify/1" do
    test "converts spaces to underscores and lowercases" do
      assert "fractional_contractor_readiness" =
               ParaExporter.slugify("Fractional Contractor Readiness")
    end

    test "strips special characters" do
      assert "sre_infrastructure" = ParaExporter.slugify("SRE & Infrastructure")
    end

    test "collapses multiple spaces and hyphens" do
      assert "some_project" = ParaExporter.slugify("Some  --  Project")
    end

    test "handles already-slugified input" do
      assert "my_project" = ParaExporter.slugify("my_project")
    end

    test "returns untitled for nil" do
      assert "untitled" = ParaExporter.slugify(nil)
    end
  end

  describe "backfill_projects/2" do
    test "dry-run returns planned projects and skips existing slugs" do
      projects = [
        %{"id" => "aaa", "name" => "SRE & Infrastructure", "status" => "active"},
        %{"id" => "bbb", "name" => "GTD Productivity System", "status" => "active"},
        %{"id" => "ccc", "name" => "Fractional Contractor Readiness", "status" => "active"}
      ]

      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tenant_id ->
        {:ok, projects}
      end)

      {:ok, result} =
        ParaExporter.backfill_projects("default",
          skip_slugs: ["fractional_contractor_readiness"],
          apply: false
        )

      assert result.mode == "dry-run"
      assert result.total_gtd_projects == 3
      assert length(result.planned) == 2
      assert result.skipped == ["fractional_contractor_readiness"]
      assert result.applied == []

      slugs = Enum.map(result.planned, & &1["slug"])
      assert "sre_infrastructure" in slugs
      assert "gtd_productivity_system" in slugs
    end

    test "filters out smoke test and debug projects" do
      projects = [
        %{"id" => "aaa", "name" => "Real Project", "status" => "active"},
        %{"id" => "bbb", "name" => "smoke_bridge_test_123", "status" => "active"},
        %{"id" => "ccc", "name" => "project-debug-probe", "status" => "active"}
      ]

      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tenant_id ->
        {:ok, projects}
      end)

      {:ok, result} = ParaExporter.backfill_projects("default", apply: false)

      assert length(result.planned) == 1
      assert hd(result.planned)["slug"] == "real_project"
    end

    test "deduplicates projects by slug" do
      projects = [
        %{"id" => "aaa", "name" => "Handle PostgreSQL errors", "status" => "active"},
        %{"id" => "bbb", "name" => "Handle PostgreSQL errors", "status" => "active"},
        %{"id" => "ccc", "name" => "Handle PostgreSQL errors", "status" => "active"}
      ]

      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tenant_id ->
        {:ok, projects}
      end)

      {:ok, result} = ParaExporter.backfill_projects("default", apply: false)

      assert result.total_gtd_projects == 3
      assert result.unique_after_dedup == 1
      assert length(result.planned) == 1
    end
  end

  describe "sweep_stale/2" do
    test "dry-run finds completed projects to archive" do
      projects = [
        %{"id" => "aaa", "name" => "Active Project", "status" => "active"},
        %{"id" => "bbb", "name" => "Finished Work", "status" => "completed"},
        %{"id" => "ccc", "name" => "Old Sprint", "status" => "done"},
        %{"id" => "ddd", "name" => "Still Going", "status" => "active"}
      ]

      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tenant_id ->
        {:ok, projects}
      end)

      {:ok, result} = ParaExporter.sweep_stale("default", apply: false)

      assert result.mode == "dry-run"
      assert result.total_projects == 4
      assert result.completed_count == 2
      assert length(result.to_archive) == 2
      assert result.archived == []

      slugs = Enum.map(result.to_archive, & &1["slug"])
      assert "finished_work" in slugs
      assert "old_sprint" in slugs
    end

    test "skips already-archived slugs" do
      projects = [
        %{"id" => "aaa", "name" => "Done Project", "status" => "completed"},
        %{"id" => "bbb", "name" => "Also Done", "status" => "completed"}
      ]

      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tenant_id ->
        {:ok, projects}
      end)

      {:ok, result} =
        ParaExporter.sweep_stale("default",
          existing_archive_slugs: ["done_project"],
          apply: false
        )

      assert length(result.to_archive) == 1
      assert hd(result.to_archive)["slug"] == "also_done"
      assert result.already_archived == ["done_project"]
    end

    test "filters smoke tests from sweep" do
      projects = [
        %{"id" => "aaa", "name" => "Real Done", "status" => "completed"},
        %{"id" => "bbb", "name" => "[SMOKE] Bridge test", "status" => "completed"},
        %{"id" => "ccc", "name" => "smoke_test_123", "status" => "completed"}
      ]

      Mox.expect(BotArmyGtd.ProjectStoreMock, :list, fn _tenant_id ->
        {:ok, projects}
      end)

      {:ok, result} = ParaExporter.sweep_stale("default", apply: false)

      assert length(result.to_archive) == 1
      assert hd(result.to_archive)["slug"] == "real_done"
    end
  end
end
