defmodule BotArmyGtd.GraphSource do
  @moduledoc """
  The four reads a graph is made of, and the one place a stored timestamp becomes a day.

  Timestamps are written with UTC wall times (`naive_datetime` columns, and one
  `utc_datetime_usec`), and a graph counts rows by the day *she* lived them in, so every
  read here hands back a `Date` already shifted into the house's day. That conversion
  belongs next to the query rather than in the graph module: the graph module's job is to
  put days into weeks, and a module that both buckets weeks and translates timestamps is a
  module with two reasons to change.

  Everything is read from a `since` day rather than from a count of rows. A card draws ten
  rows; a chart draws **twelve weeks**, and the difference matters — this store holds a
  thousand tasks, and a reader bounded by "the newest two hundred" would silently redraw
  the same six weeks forever as the log grows.

  ## This module is the seam a test replaces

  It is read through `Application.get_env(:bot_army_gtd, :graph_source, __MODULE__)`, so a
  handler test can hand in days instead of rows and assert on the weeks they land in
  without a database. Nothing else in this bot reaches through that key.
  """

  import Ecto.Query

  alias BotArmyGtd.HouseholdDay
  alias BotArmyGtd.Repo
  alias BotArmyGtd.Schemas.Project
  alias BotArmyGtd.Schemas.Task
  alias BotArmyGtd.Schemas.TaskCheckout

  @doc """
  The days tasks were created, on or after `since`.

  A task has no "planned start" in this store, so the day it arrived is the day it was
  written down.
  """
  @spec tasks_opened(binary(), Date.t()) :: {:ok, [Date.t()]}
  def tasks_opened(tenant_id, %Date{} = since) do
    Task
    |> where([t], t.tenant_id == ^tenant_id and t.inserted_at >= ^utc_from(since))
    |> select([t], t.inserted_at)
    |> Repo.all()
    |> Enum.map(&HouseholdDay.local_date/1)
    |> then(&{:ok, &1})
  end

  @doc """
  The days tasks were completed, on or after `since`.

  By `completed_at` and not by `inserted_at`: a task she captured a month ago and finished
  this morning belongs on this morning's bar. A task completed before this column was
  written has a null here, and a null day is not a day this graph can count — it is left
  out rather than dated to the row's creation, which would move it into a week it did not
  happen in.
  """
  @spec tasks_closed(binary(), Date.t()) :: {:ok, [Date.t()]}
  def tasks_closed(tenant_id, %Date{} = since) do
    Task
    |> where([t], t.tenant_id == ^tenant_id and not is_nil(t.completed_at))
    |> where([t], t.completed_at >= ^utc_from(since))
    |> select([t], t.completed_at)
    |> Repo.all()
    |> Enum.map(&HouseholdDay.local_date/1)
    |> then(&{:ok, &1})
  end

  @doc """
  The days tasks were checked out to be worked on, on or after `since`.

  One checkout is one sitting-down-with-one-thing, so this series counts sessions and says
  so. Checkouts are written with a `utc_datetime_usec`, which is the one column here that
  is not a naive wall time.
  """
  @spec task_checkouts(binary(), Date.t()) :: {:ok, [Date.t()]}
  def task_checkouts(tenant_id, %Date{} = since) do
    TaskCheckout
    |> join(:inner, [c], t in Task, on: t.id == c.task_id)
    |> where([c, t], t.tenant_id == ^tenant_id and c.checked_out_at >= ^instant_from(since))
    |> select([c, _t], c.checked_out_at)
    |> Repo.all()
    |> Enum.map(&HouseholdDay.local_date/1)
    |> then(&{:ok, &1})
  end

  @doc """
  The days projects were created, on or after `since`.

  A project has no completion timestamp in this store, so "finished" is not a question
  this graph can answer honestly and is not offered; "started" is the day the row was
  written.
  """
  @spec projects_started(binary(), Date.t()) :: {:ok, [Date.t()]}
  def projects_started(tenant_id, %Date{} = since) do
    Project
    |> where([p], p.tenant_id == ^tenant_id and p.inserted_at >= ^utc_from(since))
    |> select([p], p.inserted_at)
    |> Repo.all()
    |> Enum.map(&HouseholdDay.local_date/1)
    |> then(&{:ok, &1})
  end

  # A day is compared against UTC wall times as the instant the house's day begins, minus
  # a day of slack. The slack is free — the graph buckets by local day and drops what falls
  # outside the window — and it covers a row written within the offset of local midnight,
  # which is exactly where a strict comparison would silently lose the day's earliest rows.
  # The alternative, computing the UTC instant of local midnight, would need the offset of
  # a past date, and this fleet has no zone database to ask (see `HouseholdDay`).
  defp utc_from(%Date{} = since) do
    since
    |> Date.add(-1)
    |> NaiveDateTime.new!(~T[00:00:00])
  end

  defp instant_from(%Date{} = since) do
    since |> utc_from() |> DateTime.from_naive!("Etc/UTC")
  end
end
