defmodule BotArmyGtd.ParaExporter do
  @moduledoc """
  Exports GTD lifecycle events to PARA projects via NATS.

  ## Project scaffolding (new projects)

  When a GTD project is created, scaffolds the PARA project folder
  via `para.fs.write` — README.md (with project_id), NEXT_ACTION.md,
  WEEKLY_LOG.md, DECISIONS.md. This pre-links the two systems so the
  reconcile and export flows work from day one.

  ## Task lifecycle (existing links)

  When a task is completed or changes status, checks whether it has
  `## PARA refs` in its description. If so, extracts the PARA project
  slug and publishes a note to `para.note.route`, which the PARA bot
  routes into the project's WEEKLY_LOG.md.

  The PARA → GTD reconcile script (`para_gtd_reconcile.py`) stamps task
  descriptions with a block like:

      ## PARA refs
      - docs/personal_os/projects/fractional_contractor_readiness/NEXT_ACTION.md
      - docs/personal_os/projects/fractional_contractor_readiness/WEEKLY_LOG.md

  This module reads that block to find the PARA project slug and publish
  back to it — closing the bidirectional sync loop.
  """

  require Logger
  alias BotArmyGtd.{ProjectStore, TaskStore}
  alias BotArmyLibraryRuntime.NATS.Publisher

  @para_refs_marker "## PARA refs"
  @project_path_regex ~r{docs/personal_os/projects/([^/]+)/}

  @doc """
  Notify PARA about a task completion.

  Extracts the PARA project slug from the task's description, then
  publishes a note via `para.note.route` so it lands in the project's
  WEEKLY_LOG.md.

  Returns `:ok` (best-effort; failures are logged, not propagated).
  """
  def notify_completed(task) when is_map(task) do
    case extract_para_project(task) do
      {:ok, project_slug} ->
        publish_completion_note(project_slug, task)

      :no_link ->
        :ok
    end
  end

  @doc """
  Notify PARA about a task status change (e.g., inbox → active).

  Only publishes if the task is PARA-linked.
  """
  def notify_status_change(task, old_status, new_status) when is_map(task) do
    if old_status == new_status do
      :ok
    else
      case extract_para_project(task) do
        {:ok, project_slug} ->
          publish_status_note(project_slug, task, old_status, new_status)

        :no_link ->
          :ok
      end
    end
  end

  # -------------------------------------------------------------------
  # Project scaffolding
  # -------------------------------------------------------------------

  @doc """
  Scaffold a PARA project folder for a newly created GTD project.

  Creates four files via `para.fs.write`:
  - `projects/{slug}/README.md` — with GTD project_id embedded
  - `projects/{slug}/NEXT_ACTION.md` — empty template
  - `projects/{slug}/WEEKLY_LOG.md` — empty template
  - `projects/{slug}/DECISIONS.md` — empty template

  Returns `:ok` (best-effort).
  """
  def scaffold_project(project) when is_map(project) do
    name = project["name"] || "Untitled"
    project_id = project["id"]
    slug = slugify(name)
    today = Date.utc_today() |> Date.to_iso8601()

    files = [
      {"README.md", readme_content(name, project_id)},
      {"NEXT_ACTION.md", "# Next action\n\n_No tasks yet — create one in GTD._\n"},
      {"WEEKLY_LOG.md", "# Weekly log\n\n## #{today}\n\n- Project created from GTD\n"},
      {"DECISIONS.md",
       "# Decisions\n\n| Date | Decision | Rationale |\n|------|----------|-----------|\n"}
    ]

    Enum.each(files, fn {filename, content} ->
      publish_to_para_fs("projects/#{slug}/#{filename}", content, "write")
    end)

    Logger.info("[ParaExporter] Scaffolded PARA project: #{slug} (project_id=#{project_id})")
    :ok
  end

  @doc """
  Notify PARA that a new task was created under a project.

  Publishes a note to `para.note.route` so it appears in the
  project's WEEKLY_LOG.md. Also updates NEXT_ACTION.md if the
  task is active.
  """
  def notify_task_created(task, project_name) when is_map(task) and is_binary(project_name) do
    slug = slugify(project_name)
    title = task["title"] || "Untitled"
    status = task["status"] || "inbox"
    today = Date.utc_today() |> Date.to_iso8601()

    # Log the new task in WEEKLY_LOG via note routing
    note_payload = %{
      "schema_version" => "1.0",
      "summary" => "📋 New task: #{title} (#{status})",
      "source_bot" => "gtd",
      "project_ref" => slug,
      "task_id" => task["id"]
    }

    do_publish("para.note.route", note_payload)

    # If active, also update NEXT_ACTION
    if status == "active" do
      content = "# Next action\n\n**#{title}**\n\n_Synced from GTD on #{today}_\n"
      publish_to_para_fs("projects/#{slug}/NEXT_ACTION.md", content, "write")
    end

    :ok
  end

  def notify_task_created(_task, _project_name), do: :ok

  # -------------------------------------------------------------------
  # Backfill existing projects
  # -------------------------------------------------------------------

  @doc """
  Backfill PARA folders for existing GTD projects.

  Lists all GTD projects, deduplicates by slug, filters out junk
  (smoke tests, duplicates), skips slugs in `skip_slugs`, and
  scaffolds the rest.

  Options:
  - `skip_slugs` — list of PARA slugs that already exist (don't overwrite)
  - `apply` — if false, returns a dry-run plan without writing

  Returns `{:ok, %{planned: [...], skipped: [...], applied: [...]}}`.
  """
  def backfill_projects(tenant_id, opts \\ []) do
    skip_slugs = MapSet.new(opts[:skip_slugs] || [])
    apply? = Keyword.get(opts, :apply, false)

    project_store = Application.get_env(:bot_army_gtd, :project_store, BotArmyGtd.ProjectStore)

    projects =
      case project_store.list(tenant_id) do
        {:ok, list} -> list
        _ -> []
      end

    {unique, _seen} = deduplicate_projects(projects)
    reversed_unique = Enum.reverse(unique)

    planned = Enum.reject(reversed_unique, fn {slug, _} -> MapSet.member?(skip_slugs, slug) end)

    skipped =
      Enum.filter(reversed_unique, fn {slug, _} -> MapSet.member?(skip_slugs, slug) end)
      |> Enum.map(fn {slug, _} -> slug end)

    applied = if apply?, do: apply_planned_projects(planned), else: []
    plan_slugs = build_plan_slugs(planned)

    {:ok,
     %{
       total_gtd_projects: length(projects),
       unique_after_dedup: length(unique),
       planned: plan_slugs,
       skipped: skipped,
       applied: applied,
       mode: if(apply?, do: "apply", else: "dry-run")
     }}
  end

  defp deduplicate_projects(projects) do
    projects
    |> Enum.filter(&real_project?/1)
    |> Enum.reduce({[], MapSet.new()}, fn project, {acc, seen} ->
      slug = slugify(project["name"] || "")

      if slug == "" or slug == "untitled" or MapSet.member?(seen, slug) do
        {acc, seen}
      else
        {[{slug, project} | acc], MapSet.put(seen, slug)}
      end
    end)
  end

  defp apply_planned_projects(planned) do
    Enum.map(planned, fn {slug, project} ->
      scaffold_project(project)
      slug
    end)
  end

  defp build_plan_slugs(planned) do
    Enum.map(planned, fn {slug, project} ->
      %{"slug" => slug, "name" => project["name"], "project_id" => project["id"]}
    end)
  end

  # -------------------------------------------------------------------
  # Cleanup: archive, rotate, sweep
  # -------------------------------------------------------------------

  @doc """
  Archive a PARA project folder when the GTD project is completed.

  Copies key files into `archive/{slug}/`, stamps README with archive
  date, and overwrites the `projects/{slug}/README.md` with a tombstone
  pointing to the archive. Best-effort.
  """
  def archive_project(project) when is_map(project) do
    name = project["name"] || "Untitled"
    project_id = project["id"]
    slug = slugify(name)
    today = Date.utc_today() |> Date.to_iso8601()

    archived_readme = """
    # #{name} (archived)

    | Field | Value |
    |-------|--------|
    | **GTD project** | #{name} |
    | **project_id** | `#{project_id}` |
    | **Archived** | #{today} |
    | **Status** | completed |

    _This project was archived automatically when marked complete in GTD._
    """

    tombstone = """
    # #{name}

    > ⚠️ **Archived #{today}** — see `archive/#{slug}/`
    """

    # Write archived copies
    for filename <- ["README.md", "NEXT_ACTION.md", "WEEKLY_LOG.md", "DECISIONS.md"] do
      content =
        if filename == "README.md" do
          archived_readme
        else
          nil
        end

      if content do
        do_publish("para.fs.write", %{
          "schema_version" => "1.0",
          "relative_path" => "archive/#{slug}/#{filename}",
          "content" => content,
          "mode" => "write"
        })
      end
    end

    # Leave tombstone in projects/
    do_publish("para.fs.write", %{
      "schema_version" => "1.0",
      "relative_path" => "projects/#{slug}/README.md",
      "content" => tombstone,
      "mode" => "write"
    })

    Logger.info("[ParaExporter] Archived PARA project: #{slug}")
    :ok
  end

  @doc """
  Rotate NEXT_ACTION.md after a task completes.

  Looks up the project for this task, finds the next active task,
  and writes it to NEXT_ACTION.md. If no active tasks remain,
  writes a "clear" marker.

  Best-effort — won't crash the caller.
  """
  def rotate_next_action(task, tenant_id) when is_map(task) do
    project_id = task["project_id"]

    if is_binary(project_id) and project_id != "" and project_id != "_inbox" do
      project_store =
        Application.get_env(:bot_army_gtd, :project_store, BotArmyGtd.ProjectStore)

      task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

      with {:ok, project} <- project_store.get(tenant_id, project_id),
           slug when slug != "" <- slugify(project["name"] || ""),
           {:ok, tasks} <- task_store.list(tenant_id, %{"project_id" => project_id}) do
        active_tasks =
          tasks
          |> Enum.filter(&(&1["status"] == "active" and &1["id"] != task["id"]))
          |> Enum.sort_by(& &1["updated_at"], :desc)

        today = Date.utc_today() |> Date.to_iso8601()
        content = build_next_action_content(active_tasks, today)

        do_publish("para.fs.write", %{
          "schema_version" => "1.0",
          "relative_path" => "projects/#{slug}/NEXT_ACTION.md",
          "content" => content,
          "mode" => "write"
        })

        Logger.info(
          "[ParaExporter] Rotated NEXT_ACTION for #{slug}: #{length(active_tasks)} active tasks remaining"
        )
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("[ParaExporter] rotate_next_action failed: #{inspect(e)}")
      :ok
  end

  defp build_next_action_content(active_tasks, today) do
    case active_tasks do
      [next | _rest] ->
        title = next["title"] || "Untitled"
        "# Next action\n\n**#{title}**\n\n_Rotated automatically on #{today}_\n"

      [] ->
        "# Next action\n\n_All tasks complete — no active next action._\n\n_Updated #{today}_\n"
    end
  end

  defp get_completed_projects(all_projects) do
    all_projects
    |> Enum.filter(&completed_project?/1)
    |> Enum.map(fn p -> {slugify(p["name"] || ""), p} end)
    |> Enum.reject(fn {slug, _} -> slug == "" or slug == "untitled" end)
    |> Enum.uniq_by(fn {slug, _} -> slug end)
  end

  defp completed_project?(p) do
    status = p["status"]
    name = p["name"] || ""
    slug_lower = String.downcase(name)

    status in ["completed", "done", "archived"] and
      String.length(name) >= 3 and
      not String.starts_with?(slug_lower, "smoke_") and
      not String.starts_with?(slug_lower, "[smoke]") and
      not String.contains?(slug_lower, "smoke_bridge")
  end

  defp get_to_archive(completed, already_archived) do
    Enum.reject(completed, fn {slug, _} -> MapSet.member?(already_archived, slug) end)
  end

  defp get_skipped(completed, already_archived) do
    Enum.filter(completed, fn {slug, _} -> MapSet.member?(already_archived, slug) end)
    |> Enum.map(fn {slug, _} -> slug end)
  end

  @doc """
  Sweep stale PARA projects: find GTD projects that are completed
  but not yet archived in PARA, and archive them.

  Options:
  - `apply` — if false, returns dry-run plan
  - `existing_archive_slugs` — PARA archive slugs that already exist (skip)

  Returns `{:ok, %{archived: [...], already_archived: [...], ...}}`.
  """
  def sweep_stale(tenant_id, opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    already_archived = MapSet.new(opts[:existing_archive_slugs] || [])

    project_store = Application.get_env(:bot_army_gtd, :project_store, BotArmyGtd.ProjectStore)

    all_projects =
      case project_store.list(tenant_id) do
        {:ok, list} -> list
        _ -> []
      end

    completed = get_completed_projects(all_projects)
    to_archive = get_to_archive(completed, already_archived)
    skipped = get_skipped(completed, already_archived)

    archived =
      if apply? do
        Enum.map(to_archive, fn {slug, project} ->
          archive_project(project)
          slug
        end)
      else
        []
      end

    plan =
      Enum.map(to_archive, fn {slug, project} ->
        %{"slug" => slug, "name" => project["name"], "project_id" => project["id"]}
      end)

    {:ok,
     %{
       total_projects: length(all_projects),
       completed_count: length(completed),
       to_archive: plan,
       already_archived: skipped,
       archived: archived,
       mode: if(apply?, do: "apply", else: "dry-run")
     }}
  end

  defp real_project?(project) do
    name = project["name"] || ""
    status = project["status"]

    slug = String.downcase(name)

    cond do
      status != "active" -> false
      String.starts_with?(slug, "smoke_") -> false
      String.starts_with?(slug, "[smoke]") -> false
      String.contains?(slug, "smoke_bridge") -> false
      String.starts_with?(slug, "project-debug") -> false
      String.length(name) < 3 -> false
      true -> true
    end
  end

  # -------------------------------------------------------------------
  # Slugify
  # -------------------------------------------------------------------

  @doc """
  Convert a project name to a PARA folder slug.

  "Fractional Contractor Readiness" → "fractional_contractor_readiness"
  """
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s_-]/, "")
    |> String.replace(~r/[\s-]+/, "_")
    |> String.trim("_")
  end

  def slugify(_), do: "untitled"

  # -------------------------------------------------------------------
  # Extraction
  # -------------------------------------------------------------------

  @doc false
  def extract_para_project(task) do
    description = task["description"] || ""

    if String.contains?(description, @para_refs_marker) do
      case Regex.run(@project_path_regex, description) do
        [_, slug] -> {:ok, slug}
        _ -> :no_link
      end
    else
      :no_link
    end
  end

  # -------------------------------------------------------------------
  # NATS publishing
  # -------------------------------------------------------------------

  defp readme_content(name, project_id) do
    """
    # #{name}

    | Field | Value |
    |-------|--------|
    | **GTD project** | #{name} |
    | **project_id** | `#{project_id}` |

    ## Files (minimal contract)

    - `NEXT_ACTION.md` — single next physical action
    - `DECISIONS.md` — decisions + rationale
    - `WEEKLY_LOG.md` — week-by-week adjustments
    """
  end

  defp publish_completion_note(project_slug, task) do
    title = task["title"] || "Untitled task"
    today = Date.utc_today() |> Date.to_iso8601()

    payload = %{
      "schema_version" => "1.0",
      "summary" => "✅ #{title} — completed #{today}",
      "source_bot" => "gtd",
      "project_ref" => project_slug,
      "task_id" => task["id"],
      "details" => "Task completed in GTD. Status: done."
    }

    do_publish("para.note.route", payload)
  end

  defp publish_status_note(project_slug, task, old_status, new_status) do
    title = task["title"] || "Untitled task"
    today = Date.utc_today() |> Date.to_iso8601()

    payload = %{
      "schema_version" => "1.0",
      "summary" => "🔄 #{title} — #{old_status} → #{new_status} (#{today})",
      "source_bot" => "gtd",
      "project_ref" => project_slug,
      "task_id" => task["id"]
    }

    do_publish("para.note.route", payload)
  end

  defp do_publish(subject, payload) do
    case Publisher.publish(subject, payload) do
      {:ok, _} ->
        Logger.info("[ParaExporter] Published to #{subject}: #{payload["summary"]}")
        :ok

      {:error, reason} ->
        Logger.warning("[ParaExporter] Failed to publish to #{subject}: #{inspect(reason)}")
        :ok
    end
  end

  defp publish_to_para_fs(relative_path, content, mode \\ "write") do
    with {:ok, token} <- fetch_para_write_token() do
      payload = %{
        "schema_version" => "1.0",
        "relative_path" => relative_path,
        "content" => content,
        "mode" => mode,
        "auth_token" => token
      }

      do_publish("para.fs.write", payload)
    else
      {:error, reason} ->
        Logger.warning("[ParaExporter] Failed to get PARA token: #{inspect(reason)}")
        :ok
    end
  end

  defp fetch_para_write_token do
    case Publisher.request("para.auth.get_write_token", %{}, 5_000) do
      {:ok, response} ->
        if response["ok"] do
          token = get_in(response, ["data", "write_token"])

          if token do
            {:ok, token}
          else
            {:error, "No write_token in response"}
          end
        else
          {:error, response["error"] || "Failed to get write token"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
end
