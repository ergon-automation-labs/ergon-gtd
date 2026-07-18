defmodule BotArmyGtd.Formatter do
  @moduledoc """
  Message formatting for GTD Bot non-LLM notifications.

  Formats status updates, notifications, and structured messages with
  GTD Bot's personality voice.

  Reference: `/docs/north_star_docs/BOT_ARMY_PERSONALITY_NORTH_STAR.md`
  """

  require Logger
  alias BotArmyLibraryRuntime.Personality.Formatter

  @doc """
  Format inbox cleared notification.

  Used when all tasks in the inbox have been processed.
  """
  def format(:inbox_cleared, %{"added" => added, "deleted" => deleted, "scheduled" => scheduled}) do
    Formatter.with_symbol(
      :gtd_bot,
      "Inbox cleared. #{added} tasks added, #{scheduled} scheduled, #{deleted} deleted because honestly, no."
    )
  end

  @doc """
  Format inbox pending notification.

  Used to alert about uncaptured tasks waiting in inbox.
  """
  def format(:inbox_pending, %{"count" => count}) when count > 0 do
    Formatter.with_symbol(:gtd_bot, "#{count} uncaptured tasks. I'm not saying anything. I'm just saying #{count}.")
  end

  def format(:inbox_pending, %{"count" => 0}) do
    Formatter.with_symbol(:gtd_bot, "Inbox is clear. Well done.")
  end

  @doc """
  Format weekly review overdue notification.

  Used when a weekly review is significantly overdue.
  """
  def format(:weekly_review_overdue, %{"days_overdue" => days}) when days > 0 do
    Formatter.with_symbol(
      :gtd_bot,
      "Weekly review pending for #{days} day#{if days == 1, do: "", else: "s"}. When you're ready, I'm ready. I'll be here."
    )
  end

  @doc """
  Format weekly review due notification.

  Used when a weekly review is coming due.
  """
  def format(:weekly_review_due, %{}) do
    Formatter.with_symbol(:gtd_bot, "Weekly review due tomorrow. Block 30 minutes if you can.")
  end

  @doc """
  Format task created notification.

  Used when a new task is successfully added to the system.
  """
  def format(:task_created, %{"title" => title, "context" => context}) do
    Formatter.with_symbol(:gtd_bot, "Added: #{title}" <> (context && " (#{context})" || ""))
  end

  def format(:task_created, %{"title" => title}) do
    Formatter.with_symbol(:gtd_bot, "Added: #{title}")
  end

  @doc """
  Format task completed notification.

  Used when a task is marked complete.
  """
  def format(:task_completed, %{"title" => title}) do
    Formatter.with_symbol(:gtd_bot, "Done: #{title}. Good work.")
  end

  @doc """
  Format project created notification.

  Used when a new project is created.
  """
  def format(:project_created, %{"title" => title}) do
    Formatter.with_symbol(:gtd_bot, "New project: #{title}")
  end

  @doc """
  Format decomposition request notification.

  Used when a task is being broken down into subtasks.
  """
  def format(:decomposition_started, %{"task_title" => title}) do
    Formatter.with_symbol(:gtd_bot, "Breaking down: #{title}")
  end

  @doc """
  Format decomposition complete notification.

  Used when a task has been successfully decomposed.
  """
  def format(:decomposition_complete, %{"task_title" => title, "subtask_count" => count}) do
    Formatter.with_symbol(:gtd_bot, "#{title} is now #{count} concrete next steps. Much better.")
  end

  @doc """
  Format error notification.

  Used when something goes wrong.
  """
  def format(:error, %{"message" => message}) do
    Formatter.with_symbol(:gtd_bot, "Something went wrong: #{message}")
  end

  def format(_type, _data) do
    Logger.warning("Unknown GTD formatter type")
    Formatter.with_symbol(:gtd_bot, "Something happened.")
  end
end
