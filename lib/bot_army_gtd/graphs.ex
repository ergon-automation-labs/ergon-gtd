defmodule BotArmyGtd.Graphs do
  @moduledoc """
  The graphs this bot can draw from the task log: the menu, and the numbers behind it.

  A graph is a question about her work with a shape attached, and both halves of that
  belong to this bot rather than to the page that draws it. Which weeks a series covers,
  what one bar counts, and whether a count is of tasks or of projects are facts about this
  store; the page's job is to turn a list of points into a path and print the words it was
  handed. Nothing here knows about pixels, and nothing on the page knows what a week is.

  ## Four questions, and why these four

  - **Tasks opened** — how much arrived. Counted by the day the row was written, which is
    the day it was captured; this store has no "planned start" to count instead.
  - **Tasks closed** — how much left. Counted by `completed_at`, the day she finished it,
    not the day the row was created.
  - **Times worked** — how many times a task was checked out to be worked on. This is the
    one series that counts *sessions* rather than tasks, and it is the closest thing to
    effort this store holds: a checkout is a person sitting down with one thing.
  - **Projects started** — how many projects were opened, by calendar month. Monthly
    because a project is a longer unit than a task, and twelve weekly bars for a handful of
    rows would be a chart of zeros with two spikes.

  ## Every series is always here, drawn or not

  This answers with the whole menu every time, including the series that cannot be filled
  yet, each carrying its own points — an empty list is a fact the page can say out loud
  ("nothing here yet"), and a series that vanished until it had data would be a graph she
  could only discover by accident. The page picks one to show; the menu is this bot's.

  ## The day the buckets are cut on

  Weeks start on Monday and days are the house's days (`HouseholdDay`), not Greenwich's, so
  a task closed at nine in the evening is in the week she closed it in. The window is twelve
  weeks for the weekly series and twelve calendar months for the monthly one, both ending
  with the week or month today falls in.
  """

  @weeks 12
  @months 12

  @doc """
  How many days of log the weekly series are built from — the twelve weeks
  `week_buckets/2` names.

  The handler reads exactly this window, so a graph cannot quietly mean a different window
  than the one its labels describe.
  """
  @spec window_days() :: pos_integer()
  def window_days, do: @weeks * 7

  @doc """
  The Monday twelve weeks back — the first day of the window, inclusive.

  A reader that starts here and ends at today covers every bucket, and the same day is
  asked of all three weekly reads so the three bars in one week describe the same week.
  """
  @spec window_start(Date.t()) :: Date.t()
  def window_start(today), do: hd(week_buckets(today, @weeks)).start

  @doc "The first day of the first month bucket — the window the monthly series reads."
  @spec month_window_start(Date.t()) :: Date.t()
  def month_window_start(today), do: hd(month_buckets(today, @months)).start

  @doc """
  The weeks a series is drawn over, oldest first — Monday-started, ending with the week
  today is in.

  The label is the Monday, because an unlabelled axis is a chart nobody can read and a
  label on every bar is a chart nobody can read either; the page prints the first and the
  last and leaves the rest off.
  """
  @spec week_buckets(Date.t(), pos_integer()) :: [%{start: Date.t(), label: String.t()}]
  def week_buckets(today, count \\ @weeks) do
    this_monday = Date.add(today, -(Date.day_of_week(today, :monday) - 1))

    for i <- 0..(count - 1) do
      start = Date.add(this_monday, -(count - 1 - i) * 7)
      %{start: start, label: Calendar.strftime(start, "%b %-d")}
    end
  end

  @doc """
  The calendar months a series is drawn over, oldest first, ending with the month today is
  in.
  """
  @spec month_buckets(Date.t(), pos_integer()) :: [%{start: Date.t(), label: String.t()}]
  def month_buckets(today, count \\ @months) do
    first = %Date{year: today.year, month: today.month, day: 1}

    for i <- 0..(count - 1) do
      start = shift_months(first, -(count - 1 - i))
      %{start: start, label: Calendar.strftime(start, "%b %Y")}
    end
  end

  @doc """
  Build every series, in the order they are offered.

  `data` is what the handler read: `:opened`, `:closed`, `:worked` (each a list of days)
  and `:projects` (a list of days). Anything missing is read as "none", which is the same
  answer this module gives for an empty store, so a caller does not have to spell out the
  empty case.

  Every series is a `%{"id", "title", "unit", "kind", "note", "points"}` map. `"kind"` is
  `"bars"` when each point stands alone (a count per week) and `"line"` when the points are
  a path through time; that is a fact about the numbers rather than a style, which is why
  it is chosen here.
  """
  @spec build(map(), Date.t()) :: [map()]
  def build(data, %Date{} = today) when is_map(data) do
    weeks = week_buckets(today, @weeks)
    months = month_buckets(today, @months)

    [
      weekly(
        data,
        weeks,
        :opened,
        "gtd.tasks.opened.week",
        "Tasks opened",
        "tasks",
        "each bar is one week, the last twelve"
      ),
      weekly(
        data,
        weeks,
        :closed,
        "gtd.tasks.closed.week",
        "Tasks closed",
        "tasks",
        "each bar is one week, the last twelve"
      ),
      weekly(
        data,
        weeks,
        :worked,
        "gtd.tasks.worked.week",
        "Times worked",
        "times",
        "each bar is one week, the last twelve — one for each time a task was picked up"
      ),
      monthly(
        data,
        months,
        :projects,
        "gtd.projects.started.month",
        "Projects started",
        "projects",
        "each bar is one calendar month, the last twelve"
      )
    ]
  end

  defp weekly(data, weeks, key, id, title, unit, note) do
    series(
      id,
      title,
      unit,
      "bars",
      note,
      points(weeks, count_weeks(Map.get(data, key, []), weeks))
    )
  end

  defp monthly(data, months, key, id, title, unit, note) do
    counts = count_months(Map.get(data, key, []), months)
    series(id, title, unit, "bars", note, points(months, counts))
  end

  # ── the buckets ───────────────────────────────────────────────────────────────

  defp count_weeks(dates, weeks) do
    Enum.reduce(dates, List.duplicate(0, length(weeks)), fn date, acc ->
      case bucket_index(date, hd(weeks).start, 7, length(weeks)) do
        nil -> acc
        index -> bump(acc, index)
      end
    end)
  end

  defp count_months(dates, months) do
    first = hd(months).start

    Enum.reduce(dates, List.duplicate(0, length(months)), fn date, acc ->
      index = (date.year - first.year) * 12 + (date.month - first.month)

      if index >= 0 and index < length(months) do
        bump(acc, index)
      else
        acc
      end
    end)
  end

  # Which week a day falls in, or nil for a day outside the window. Weeks are a fixed
  # stride from the first Monday, so the arithmetic is one division, and the bound is the
  # *count* rather than the last bucket's start: a day later in the current week is inside
  # the last bucket, and comparing it against that bucket's Monday would drop everything
  # that happened this week. `Integer.floor_div/2` rather than `div/2` for a day before the
  # window, whose negative offset `div/2` rounds up into the first bar.
  defp bucket_index(%Date{} = date, first_monday, step_days, count) do
    index = Integer.floor_div(Date.diff(date, first_monday), step_days)

    if index >= 0 and index < count, do: index, else: nil
  end

  defp bump(counts, index), do: List.update_at(counts, index, &(&1 + 1))

  defp points(buckets, counts) do
    buckets
    |> Enum.zip(counts)
    |> Enum.map(fn {bucket, value} -> %{"label" => bucket.label, "value" => value} end)
  end

  defp series(id, title, unit, kind, note, points) do
    %{
      "id" => id,
      "title" => title,
      "unit" => unit,
      "kind" => kind,
      "note" => note,
      "points" => points
    }
  end

  defp shift_months(%Date{year: year, month: month}, delta) do
    total = year * 12 + (month - 1) + delta

    %Date{year: div(total, 12), month: Integer.mod(total, 12) + 1, day: 1}
  end
end
