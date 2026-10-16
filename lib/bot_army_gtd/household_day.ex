defmodule BotArmyGtd.HouseholdDay do
  @moduledoc """
  The day this bot files a thing under, and the day "today" means everywhere in it.

  A bot that answers "today" with `Date.utc_today/0` is a bot whose day changes at 18:00
  for a house in Denver. That is not a cosmetic difference here: a task finished at seven
  in the evening is counted against *tomorrow*, and a weekly report or a graph bucket near
  midnight lands in the wrong week. The day a person is living in is the house's day, not
  Greenwich's, and this is the one place this bot answers that question.

  The same module exists in `bot_army_fitness`, for the same reason and with the same
  seam, because the two bots are read side by side by the same page: a week is the same
  week in both or a bar chart of "the last twelve weeks" means two different things on one
  screen.

  ## Why not a time zone database

  There is no IANA database anywhere in this fleet, and adding one for a subtraction is a
  bad trade: a new dependency plus a compile-time download to learn an offset the runtime
  already knows. `:calendar.local_time/0` asks the host the same question — the host the
  bot is running on is the host whose clock the household lives by — and this module
  carries no state to keep in step with it. `offset_hours/0` exists so a host in the wrong
  zone can be *seen* to be in the wrong zone rather than suspected: it is logged at boot.

  ## The seam, and why it is an application environment key

  Tests must not change meaning at midnight, and neither must a suite run on a machine in
  another zone. Set `:household_today` to a zero-arity function in the application
  environment and every caller of `today/0` answers the pinned day:

      Application.put_env(:bot_army_gtd, :household_today, fn -> ~D[2026-01-01] end)
  """

  @doc """
  Today, in the house's own day.

  Every day this bot writes down, counts from, or buckets into a week comes from here.
  `Date.utc_today/0` is not the same question and must not be used to answer this one.
  """
  @spec today() :: Date.t()
  def today, do: clock().()

  @doc """
  How many hours this host's clock stands from UTC right now.

  Not used to compute a day — `today/0` is the host's own answer and is not derived from
  an offset. It exists to be logged and read, so that a host whose zone is not the
  household's is visible in the log instead of hiding as a wrong answer that only shows up
  after six in the evening.
  """
  @spec offset_hours() :: integer()
  def offset_hours, do: div(offset_seconds(), 3_600)

  @doc """
  How many seconds this host's clock stands from UTC right now.

  The offset `local_date/1` applies. It is the offset *now*, applied to a timestamp that
  may be weeks old, and that is a deliberate approximation: the house's zone has one
  daylight-saving step inside the graph window, so a row written within an hour of midnight
  on the far side of that step can be counted in the day before it. Every other row in the
  window is exact, and the alternative — an IANA database — is the dependency this module
  refuses.
  """
  @spec offset_seconds() :: integer()
  def offset_seconds do
    local = :calendar.datetime_to_gregorian_seconds(:calendar.local_time())
    utc = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())

    local - utc
  end

  @doc """
  The house's day a stored timestamp happened on.

  Rows are written with UTC wall times (`naive_datetime` columns) and a graph counts them
  by the day she lived them in, so the offset is added before the date is taken. A
  `DateTime` is accepted as well, because checkouts are written with one.
  """
  @spec local_date(NaiveDateTime.t() | DateTime.t()) :: Date.t()
  def local_date(%NaiveDateTime{} = naive) do
    naive
    |> NaiveDateTime.add(offset_seconds(), :second)
    |> NaiveDateTime.to_date()
  end

  def local_date(%DateTime{} = datetime) do
    datetime |> DateTime.to_naive() |> local_date()
  end

  defp clock, do: Application.get_env(:bot_army_gtd, :household_today, &local_today/0)

  defp local_today do
    {date, _time} = :calendar.local_time()
    Date.from_erl!(date)
  end
end
