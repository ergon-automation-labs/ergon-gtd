defmodule BotArmyGtd.ReviewEngine do
  @moduledoc """
  GTD review engine: weekly review, inbox aging, project coherence.

  Provides analytical queries over GTD data to surface health issues,
  stale items, and orphaned relationships. Results are returned as
  structured maps suitable for NATS replies or Synapse/Discord rendering.
  """

  require Logger
  alias BotArmyGtd.{InboxItemStore, ProjectStore, TaskStore}
  alias BotArmyRuntime.NATS.Publisher

  @inbox_stale_hours 48
  @active_stale_days 7
  @review_window_days 7

  # -------------------------------------------------------------------
  # Weekly Review
  # -------------------------------------------------------------------

  @doc """
  Generate a weekly review summary.

  Returns completed tasks, stale active tasks, projects without next
  actions, inbox aging, and overall counts for the past week.
  """
  def weekly_review(tenant_id, opts \\ []) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    project_store = Application.get_env(:bot_army_gtd, :project_store, BotArmyGtd.ProjectStore)
    inbox_store = Application.get_env(:bot_army_gtd, :inbox_item_store, BotArmyGtd.InboxItemStore)

    window_days = opts[:window_days] || @review_window_days
    cutoff = DateTime.utc_now() |> DateTime.add(-window_days * 86400, :second)
    now = DateTime.utc_now()

    # Gather data
    all_tasks = safe_list(task_store, :list, [tenant_id, %{}])
    all_projects = safe_list(project_store, :list, [tenant_id])
    pending_inbox = safe_list(inbox_store, :list_pending, [tenant_id])

    # Completed this week
    completed =
      all_tasks
      |> Enum.filter(fn t ->
        t["status"] in ["completed", "done"] and
          recent?(t["updated_at"] || t["completed_at"], cutoff)
      end)

    # Active tasks that haven't been updated in > stale_days
    stale_cutoff = DateTime.utc_now() |> DateTime.add(-@active_stale_days * 86400, :second)

    stale_active =
      all_tasks
      |> Enum.filter(fn t ->
        t["status"] == "active" and not recent?(t["updated_at"], stale_cutoff)
      end)

    # Active projects
    active_projects =
      all_projects
      |> Enum.filter(&(&1["status"] == "active"))

    # Projects with no active tasks (orphaned projects)
    active_task_project_ids =
      all_tasks
      |> Enum.filter(&(&1["status"] == "active"))
      |> Enum.map(& &1["project_id"])
      |> MapSet.new()

    projects_without_next_action =
      active_projects
      |> Enum.reject(fn p -> MapSet.member?(active_task_project_ids, p["id"]) end)

    # Inbox aging
    stale_inbox = find_stale_inbox(pending_inbox, now)

    {:ok,
     %{
       window_days: window_days,
       generated_at: DateTime.to_iso8601(now),
       summary: %{
         total_tasks: length(all_tasks),
         total_projects: length(all_projects),
         active_projects: length(active_projects),
         completed_this_week: length(completed),
         stale_active_tasks: length(stale_active),
         projects_without_next_action: length(projects_without_next_action),
         pending_inbox_items: length(pending_inbox),
         stale_inbox_items: length(stale_inbox)
       },
       completed:
         completed
         |> Enum.take(25)
         |> Enum.map(&task_summary/1),
       stale_active:
         stale_active
         |> Enum.map(&task_summary/1),
       projects_without_next_action:
         projects_without_next_action
         |> Enum.map(&project_summary/1),
       stale_inbox:
         stale_inbox
         |> Enum.map(&inbox_summary/1)
     }}
  end

  # -------------------------------------------------------------------
  # Inbox Aging
  # -------------------------------------------------------------------

  @doc """
  Find inbox items that have been pending longer than the threshold.

  Returns items with age in hours and a nudge severity level.
  """
  def inbox_aging(tenant_id, opts \\ []) do
    inbox_store = Application.get_env(:bot_army_gtd, :inbox_item_store, BotArmyGtd.InboxItemStore)
    threshold_hours = opts[:threshold_hours] || @inbox_stale_hours
    now = DateTime.utc_now()

    pending = safe_list(inbox_store, :list_pending, [tenant_id])
    threshold_cutoff = DateTime.add(now, -threshold_hours * 3600, :second)

    stale =
      pending
      |> Enum.filter(fn item ->
        not recent?(item["created_at"], threshold_cutoff)
      end)
      |> Enum.map(fn item ->
        age_hours = age_in_hours(item["created_at"], now)

        severity =
          cond do
            age_hours > 168 -> "critical"
            age_hours > 72 -> "warning"
            true -> "info"
          end

        item
        |> inbox_summary()
        |> Map.merge(%{"age_hours" => age_hours, "severity" => severity})
      end)
      |> Enum.sort_by(& &1["age_hours"], :desc)

    {:ok,
     %{
       threshold_hours: threshold_hours,
       total_pending: length(pending),
       stale_count: length(stale),
       items: stale
     }}
  end

  # -------------------------------------------------------------------
  # Project–Task Coherence
  # -------------------------------------------------------------------

  @doc """
  Check project–task coherence.

  Finds:
  - Orphaned projects: active projects with zero active tasks
  - Dangling tasks: tasks referencing non-existent or completed projects
  - Empty projects: projects that have never had any tasks
  """
  def project_coherence(tenant_id) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    project_store = Application.get_env(:bot_army_gtd, :project_store, BotArmyGtd.ProjectStore)

    all_tasks = safe_list(task_store, :list, [tenant_id, %{}])
    all_projects = safe_list(project_store, :list, [tenant_id])

    project_map =
      all_projects
      |> Enum.into(%{}, fn p -> {p["id"], p} end)

    active_projects = Enum.filter(all_projects, &(&1["status"] == "active"))

    # Tasks grouped by project
    tasks_by_project =
      all_tasks
      |> Enum.group_by(& &1["project_id"])

    # Orphaned: active projects with no active tasks
    orphaned_projects =
      active_projects
      |> Enum.filter(fn p ->
        project_tasks = Map.get(tasks_by_project, p["id"], [])
        not Enum.any?(project_tasks, &(&1["status"] == "active"))
      end)
      |> Enum.map(fn p ->
        task_count = length(Map.get(tasks_by_project, p["id"], []))
        project_summary(p) |> Map.put("total_task_count", task_count)
      end)

    # Dangling: tasks pointing to non-existent or completed projects
    dangling_tasks =
      all_tasks
      |> Enum.filter(fn t ->
        pid = t["project_id"]

        is_binary(pid) and pid != "" and pid != "_inbox" and
          (not Map.has_key?(project_map, pid) or
             Map.get(project_map, pid, %{})["status"] in ["completed", "done", "archived"])
      end)
      |> Enum.map(fn t ->
        project = Map.get(project_map, t["project_id"])

        reason =
          if project do
            "project_#{project["status"]}"
          else
            "project_not_found"
          end

        task_summary(t) |> Map.put("reason", reason)
      end)

    # Empty: active projects with zero tasks ever
    empty_projects =
      active_projects
      |> Enum.filter(fn p -> not Map.has_key?(tasks_by_project, p["id"]) end)
      |> Enum.map(&project_summary/1)

    {:ok,
     %{
       total_projects: length(all_projects),
       total_tasks: length(all_tasks),
       orphaned_projects: orphaned_projects,
       orphaned_count: length(orphaned_projects),
       dangling_tasks: dangling_tasks,
       dangling_count: length(dangling_tasks),
       empty_projects: empty_projects,
       empty_count: length(empty_projects)
     }}
  end

  # -------------------------------------------------------------------
  # Post-Deploy Verification
  # -------------------------------------------------------------------

  @doc """
  Verify a bot is healthy after deployment.

  Checks the registry for the expected version and confirms the bot
  is responding. Returns a verification result map.
  """
  def verify_deploy(bot_name, expected_version) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Check registry for version match
    registry_check =
      try do
        case Publisher.request(
               "bot_army.registry.bot.get",
               %{"bot_name" => bot_name}
             ) do
          {:ok, %{"data" => %{"version" => version}}} ->
            if version == expected_version do
              %{"status" => "pass", "registry_version" => version}
            else
              %{
                "status" => "version_mismatch",
                "registry_version" => version,
                "expected" => expected_version
              }
            end

          {:ok, response} ->
            %{"status" => "unexpected_response", "response" => inspect(response)}

          {:error, reason} ->
            %{"status" => "registry_unavailable", "error" => inspect(reason)}
        end
      rescue
        e -> %{"status" => "error", "error" => inspect(e)}
      end

    result = %{
      "bot" => bot_name,
      "expected_version" => expected_version,
      "verified_at" => now,
      "registry" => registry_check,
      "healthy" => registry_check["status"] == "pass"
    }

    if result["healthy"] do
      Logger.info(
        "[ReviewEngine] Post-deploy verification passed: #{bot_name} v#{expected_version}"
      )
    else
      Logger.warning(
        "[ReviewEngine] Post-deploy verification issue: #{bot_name} — #{inspect(registry_check)}"
      )
    end

    {:ok, result}
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp safe_list(store, func, args) do
    case apply(store, func, args) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp recent?(nil, _cutoff), do: false

  defp recent?(timestamp, cutoff) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> DateTime.compare(dt, cutoff) == :gt
      _ -> false
    end
  end

  defp recent?(_, _), do: false

  defp age_in_hours(nil, _now), do: 0

  defp age_in_hours(timestamp, now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} ->
        DateTime.diff(now, dt, :second) |> div(3600)

      _ ->
        0
    end
  end

  defp task_summary(task) do
    %{
      "id" => task["id"],
      "title" => task["title"],
      "status" => task["status"],
      "project_id" => task["project_id"],
      "updated_at" => task["updated_at"]
    }
  end

  defp project_summary(project) do
    %{
      "id" => project["id"],
      "name" => project["name"],
      "status" => project["status"]
    }
  end

  defp inbox_summary(item) do
    %{
      "id" => item["id"],
      "title" => item["title"] || item["raw_text"],
      "created_at" => item["created_at"],
      "source" => item["source"]
    }
  end

  defp find_stale_inbox(items, now) do
    cutoff = DateTime.add(now, -@inbox_stale_hours * 3600, :second)

    Enum.filter(items, fn item ->
      not recent?(item["created_at"], cutoff)
    end)
  end
end
